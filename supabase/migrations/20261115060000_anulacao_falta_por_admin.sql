-- Anulação de falta operacional por administrador (Equipe Frila)
--
-- Permite que um operador da Equipe Frila anule administrativamente uma falta (RN12)
-- associada a uma posição cancelada (ex: por reabrir_por_atraso ou cancelamento tardio),
-- após contestação via suporte.
--
-- Efeitos:
--   1. Altera public.posicao.falta para false (sem novas colunas em public.posicao, evitando vazamento a authenticated).
--   2. Registra auditoria na tabela privada privado.anulacao_falta (quem, quando, motivo, ocorrência de origem e auditoria).
--   3. Recalcula taxa_comparecimento e turnos_realizados do profissional (privado.recalcular_comparecimento).
--   4. Registra ocorrência de auditoria em public.ocorrencia (tipo 'suporte', autor_id = operador).
--   5. Se informada ocorrencia_origem_id, marca o chamado de suporte como resolvido.
--   6. Chamada idempotente: se já estiver anulada, não falha nem duplica efeitos.
--   7. Restrito a service_role (sem grant para anon ou authenticated).

-- ── 1. Tabela de auditoria em privado.anulacao_falta ────────────────────────────

create table if not exists privado.anulacao_falta (
  posicao_id               uuid primary key references public.posicao(id) on delete cascade,
  operador_id              uuid not null references public.usuario(id),
  motivo                   text not null,
  ocorrencia_origem_id     uuid references public.ocorrencia(id),
  ocorrencia_auditoria_id  uuid references public.ocorrencia(id),
  anulada_em               timestamptz not null default now()
);

comment on table privado.anulacao_falta is
  'Registro de auditoria de anulação operacional de falta pela Equipe Frila (RN12). Schema privado sem acesso para clientes.';

comment on column privado.anulacao_falta.posicao_id is
  'Posição cancelada cuja falta foi anulada.';

comment on column privado.anulacao_falta.operador_id is
  'Conta (public.usuario) do operador da Equipe Frila que autorizou a anulação da falta.';

comment on column privado.anulacao_falta.motivo is
  'Motivação registrada pelo operador da Equipe Frila para anulação da falta.';

comment on column privado.anulacao_falta.ocorrencia_origem_id is
  'Ocorrência de suporte/contestação que originou a anulação da falta, quando houver.';

comment on column privado.anulacao_falta.ocorrencia_auditoria_id is
  'Ocorrência interna de auditoria criada durante a anulação.';

comment on column privado.anulacao_falta.anulada_em is
  'Instante em que a falta foi anulada.';

alter table privado.anulacao_falta enable row level security;

revoke all on table privado.anulacao_falta from public, anon, authenticated;
grant select, insert, update on table privado.anulacao_falta to service_role;

-- ── 2. Função privado.anular_falta ──────────────────────────────────────────────

create or replace function privado.anular_falta(
  posicao_id           uuid,
  motivo               text,
  operador_id          uuid default null,
  ocorrencia_origem_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos                  public.posicao%rowtype;
  v_anulacao             privado.anulacao_falta%rowtype;
  v_operador             uuid := operador_id;
  v_turno_id             uuid;
  v_ocorrencia_audit_id  uuid;
  v_agora                timestamptz := privado.agora();
  v_motivo_limpo         text;
begin
  if posicao_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'posicao_id');
  end if;

  if motivo is null or pg_catalog.btrim(motivo) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  v_motivo_limpo := pg_catalog.btrim(motivo);
  if pg_catalog.length(v_motivo_limpo) < 10 then
    perform public.erro(422, 'justificativa_insuficiente');
  end if;

  if v_operador is null then
    v_operador := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
  end if;

  if v_operador is null then
    perform public.erro(422, 'campo_obrigatorio', 'operador_id');
  end if;

  if not exists (select 1 from public.usuario u where u.id = v_operador) then
    perform public.erro(404, 'nao_encontrado', 'operador_id');
  end if;

  -- Blindagem contra atribuição a usuários comuns: operador deve pertencer à Equipe Frila
  if not exists (select 1 from privado.conta_equipe ce where ce.usuario_id = v_operador) then
    perform public.erro(403, 'sem_permissao', 'operador_id');
  end if;

  if ocorrencia_origem_id is not null and not exists (
    select 1 from public.ocorrencia o where o.id = ocorrencia_origem_id
  ) then
    perform public.erro(404, 'nao_encontrado', 'ocorrencia_origem_id');
  end if;

  select * into v_pos
    from public.posicao p
   where p.id = posicao_id
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado', 'posicao_id');
  end if;

  if v_pos.estado <> 'cancelada' then
    perform public.erro(422, 'posicao_nao_cancelada');
  end if;

  -- Idempotência: se a anulação já foi gravada em privado.anulacao_falta, retorna sem duplicar efeitos
  select * into v_anulacao
    from privado.anulacao_falta af
   where af.posicao_id = v_pos.id;

  if found then
    return jsonb_build_object(
      'posicao_id',               v_pos.id,
      'profissional_id',          v_pos.profissional_id,
      'falta_anulada',            true,
      'ja_estava_anulada',        true,
      'anulada_em',               v_anulacao.anulada_em,
      'anulada_por',              v_anulacao.operador_id,
      'ocorrencia_id',            coalesce(v_anulacao.ocorrencia_auditoria_id, v_anulacao.ocorrencia_origem_id),
      'ocorrencia_auditoria_id',  v_anulacao.ocorrencia_auditoria_id,
      'ocorrencia_origem_id',     v_anulacao.ocorrencia_origem_id
    );
  end if;

  -- Só posição com falta=true pode ser anulada
  if not v_pos.falta then
    perform public.erro(409, 'falta_inexistente');
  end if;

  -- 1. Atualiza public.posicao (apenas desmarca falta, sem colunas adicionais na tabela pública)
  update public.posicao
     set falta = false
   where id = v_pos.id;

  -- 2. Recalcula taxa_comparecimento do profissional
  if v_pos.profissional_id is not null then
    perform privado.recalcular_comparecimento(v_pos.profissional_id);
  end if;

  -- 3. Registra ocorrência de auditoria em public.ocorrencia
  select t.id into v_turno_id
    from public.turno t
   where t.posicao_id = v_pos.id;

  insert into public.ocorrencia (
    tipo,
    posicao_id,
    turno_id,
    usuario_id,
    autor_id,
    motivo,
    criada_em,
    resolvido_em,
    resultado
  ) values (
    'suporte',
    v_pos.id,
    v_turno_id,
    case when v_pos.profissional_id is not null
         then privado.usuario_do_profissional(v_pos.profissional_id)
         else null end,
    v_operador,
    'Anulação de falta operacional: ' || v_motivo_limpo,
    v_agora,
    v_agora,
    'Falta anulada pela Equipe Frila. Comparecimento recalculado.'
  ) returning id into v_ocorrencia_audit_id;

  -- 4. Se houver chamado de suporte de origem, resolve-o
  if ocorrencia_origem_id is not null then
    update public.ocorrencia
       set resolvido_em = v_agora,
           resultado    = 'Falta anulada pela Equipe Frila: ' || v_motivo_limpo
     where id = ocorrencia_origem_id
       and resolvido_em is null;
  end if;

  -- 5. Grava auditoria em privado.anulacao_falta (inacessível para clientes)
  insert into privado.anulacao_falta (
    posicao_id,
    operador_id,
    motivo,
    ocorrencia_origem_id,
    ocorrencia_auditoria_id,
    anulada_em
  ) values (
    v_pos.id,
    v_operador,
    v_motivo_limpo,
    ocorrencia_origem_id,
    v_ocorrencia_audit_id,
    v_agora
  );

  return jsonb_build_object(
    'posicao_id',               v_pos.id,
    'profissional_id',          v_pos.profissional_id,
    'falta_anulada',            true,
    'ja_estava_anulada',        false,
    'anulada_em',               v_agora,
    'anulada_por',              v_operador,
    'ocorrencia_id',            v_ocorrencia_audit_id,
    'ocorrencia_auditoria_id',  v_ocorrencia_audit_id,
    'ocorrencia_origem_id',     ocorrencia_origem_id
  );
end $$;

comment on function privado.anular_falta(uuid, text, uuid, uuid) is
  'Anula falta de posição cancelada (RN12), registra auditoria no schema privado (privado.anulacao_falta), recalcula taxa de comparecimento do profissional e registra ocorrência. Restrito a service_role.';

revoke execute on function privado.anular_falta(uuid, text, uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.anular_falta(uuid, text, uuid, uuid) to service_role;
