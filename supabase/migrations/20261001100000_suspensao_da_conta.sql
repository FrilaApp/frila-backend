-- 20261001100000_suspensao_da_conta.sql
--
-- Cartão BsXIZHOw (Épico 7 · US23 · RF24, RN13, UC15):
-- Suspensão, situacao_da_conta e contestar_suspensao.
--
-- 1. Ponto único de bloqueio: privado.exigir_conta_ativa()
--    rejeita contas suspensas com 403 sem_permissao (details: conta_suspensa).
-- 2. Exceção para contestar, excluir a conta e gerenciar o aparelho, por nome qualificado
--    da função na pilha de chamada (ou pelo GUC frila.permitir_suspensa).
-- 3. privado.suspender(conta, motivo, operador_id) e privado.reativar(conta, motivo, operador_id)
--    com notificações push sem o motivo (RN15) e validação de motivo obrigatório.
-- 4. public.situacao_da_conta() -> SituacaoDaConta (RF24, RN13).
-- 5. public.contestar_suspensao(relato) -> Protocolo (RF24, RN13, Diretriz 1.2 da App Store),
--    com envio para a fila pgmq 'email' e bloqueio de contestação repetida (409 contestacao_ja_aberta).

-- ── 1. privado.exigir_conta_ativa ──────────────────────────────────────────────

create or replace function privado.exigir_conta_ativa()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_estado  public.estado_conta;
  v_context text;
begin
  if v_uid is null then
    return;
  end if;

  select u.estado into v_estado
    from public.usuario u
   where u.id = v_uid;

  if v_estado is null or v_estado = 'anonimizada' then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if v_estado = 'suspensa' then
    if nullif(current_setting('frila.permitir_suspensa', true), '') = 'on' then
      return;
    end if;

    get diagnostics v_context = pg_context;
    -- Casa só o nome qualificado de uma função da lista, nunca substring. candidatar fica de fora do 403
    -- para o contrato vigente (RN13: 422 inelegivel/perfil_suspenso, teste 130) seguir valendo.
    if v_context ~ 'PL/pgSQL function (public\.(contestar_suspensao|registrar_dispositivo|remover_dispositivo|candidatar)|privado\.excluir_conta)\(' then
      return;
    end if;

    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;
end $$;

comment on function privado.exigir_conta_ativa() is
  'Ponto único de extensão para impedir escrita com token de conta anonimizada ou inexistente (RF25) e conta suspensa (RF24, RN13). Exceções contratuais: contestar_suspensao, excluir_conta, registrar_dispositivo, remover_dispositivo e candidatar (esta devolve 422 inelegivel, não 403).';

revoke execute on function privado.exigir_conta_ativa() from public, anon, authenticated;
grant  execute on function privado.exigir_conta_ativa() to service_role;

-- ── 3. Operação de suspensão e reativação com notificações ─────────────────────

create or replace function privado.operacao_suspender_conta(
  usuario_id  uuid,
  motivo      text,
  operador_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid         uuid := operacao_suspender_conta.usuario_id;
  v_motivo      text := pg_catalog.btrim(operacao_suspender_conta.motivo);
  v_operador    uuid := operacao_suspender_conta.operador_id;
  v_usuario     public.usuario%rowtype;
  v_agora       timestamptz := privado.agora();
  v_pos         public.posicao%rowtype;
  v_cand        record;
  v_vagas       uuid[];
  v_cancelados  integer := 0;
  v_oc_id       uuid;
begin
  if v_uid is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_uid);

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_usuario.estado = 'anonimizada' then
    perform public.erro(409, 'conta_ja_anonimizada');
  end if;

  if v_usuario.estado = 'suspensa' then
    return jsonb_build_object(
      'usuario_id',         v_uid,
      'estado_anterior',    'suspensa',
      'estado_atual',       'suspensa',
      'ja_estava_suspensa', true,
      'turnos_cancelados',  0
    );
  end if;

  -- 1. Se for profissional: reabre cada turno futuro através de privado.cancelar_uma_posicao
  -- (RN13), sem falta (decisão de 29/09).
  if v_usuario.perfil = 'profissional' then
    perform set_config('frila.exclusao_de_conta', 'on', true);
    for v_pos in
      select p.*
        from public.posicao p
       where p.estado = 'confirmada'
         and p.inicio_em > v_agora
         and p.profissional_id = (select x.id from public.profissional x where x.usuario_id = v_uid)
    loop
      perform privado.cancelar_uma_posicao(v_pos.id, v_uid, 'suspensão de conta', true);
      v_cancelados := v_cancelados + 1;
    end loop;
    perform set_config('frila.exclusao_de_conta', 'off', true);
  end if;

  -- 2. Se for contratante: nas casas onde for o único membro, recolhe as vagas futuras.
  if v_usuario.perfil = 'contratante' then
    perform set_config('frila.autor_da_exclusao', v_operador::text, true);

    select coalesce(array_agg(x.id order by x.id), '{}') into v_vagas
      from (select g.id
              from public.vaga g
             where g.inicio_em > v_agora
               and g.estado in ('publicada', 'preenchida')
               and g.estabelecimento_id in (
                 select m.estabelecimento_id from public.membro_estabelecimento m
                  where m.usuario_id = v_uid
                    and not exists (
                      select 1 from public.membro_estabelecimento x
                       where x.estabelecimento_id = m.estabelecimento_id
                         and x.usuario_id <> v_uid))
             order by g.id
               for update) x;

    for v_pos in
      select p.*
        from public.posicao p
       where p.vaga_id = any (v_vagas)
         and p.estado = 'confirmada'
         and p.inicio_em > v_agora
       order by p.id
    loop
      perform privado.cancelar_uma_posicao(v_pos.id, v_operador, 'suspensão de conta', false);
      v_cancelados := v_cancelados + 1;
    end loop;

    for v_cand in
      select c.id, c.profissional_id, p.vaga_id
        from public.candidatura c
        join public.posicao p on p.id = c.posicao_id
       where p.vaga_id = any (v_vagas)
         and c.estado = 'pendente'
    loop
      update public.candidatura set estado = 'retirada' where id = v_cand.id;
      perform privado.notificar(
        privado.usuario_do_profissional(v_cand.profissional_id),
        'cancelamento',
        v_cand.vaga_id,
        jsonb_build_object('vaga_id', v_cand.vaga_id, 'reaberta', false)
      );
    end loop;

    update public.posicao p
       set estado = 'cancelada'
     where p.vaga_id = any (v_vagas)
       and p.estado = 'aberta';

    update public.vaga g
       set estado = 'cancelada'
     where g.id = any (v_vagas);

    perform set_config('frila.autor_da_exclusao', '', true);
  end if;

  -- Atualiza o estado da conta para suspensa
  update public.usuario
     set estado = 'suspensa'
   where id = v_uid;

  -- Registra ocorrência de suspensão
  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    criada_em,
    resolvido_em,
    resultado
  ) values (
    'suspensao',
    v_uid,
    v_operador,
    v_motivo,
    v_agora,
    v_agora,
    'Conta suspensa pela Equipe Frila via procedimento operacional.'
  ) returning id into v_oc_id;

  -- RN15 / Card BsXIZHOw: notificação sem motivo no push
  perform privado.notificar(
    v_uid,
    'suspensao'::public.tipo_notificacao,
    v_oc_id,
    '{}'::jsonb
  );

  return jsonb_build_object(
    'usuario_id',        v_uid,
    'estado_anterior',   'ativa',
    'estado_atual',      'suspensa',
    'ocorrencia_id',     v_oc_id,
    'turnos_cancelados', v_cancelados,
    'suspenso_em',       v_agora
  );
end $$;

comment on function privado.operacao_suspender_conta(uuid, text, uuid) is
  'Suspende conta de usuário (RN13) com registro de ocorrência assinada pelo operador da Equipe Frila, cancelamento de turnos futuros e notificação push sem motivo. Restrito a service_role.';

revoke execute on function privado.operacao_suspender_conta(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_suspender_conta(uuid, text, uuid) to service_role;

create or replace function privado.operacao_reativar_conta(
  usuario_id    uuid,
  justificativa text,
  operador_id   uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid      uuid := operacao_reativar_conta.usuario_id;
  v_just     text := pg_catalog.btrim(operacao_reativar_conta.justificativa);
  v_operador uuid := operacao_reativar_conta.operador_id;
  v_usuario  public.usuario%rowtype;
  v_agora    timestamptz := privado.agora();
  v_oc_id    uuid;
begin
  if v_uid is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if v_just is null or v_just = '' then
    perform public.erro(422, 'campo_obrigatorio', 'justificativa');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_uid);

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_usuario.estado = 'anonimizada' then
    perform public.erro(409, 'conta_ja_anonimizada');
  end if;

  if v_usuario.estado = 'ativa' then
    return jsonb_build_object(
      'usuario_id',      v_uid,
      'estado_anterior', 'ativa',
      'estado_atual',    'ativa',
      'ja_estava_ativa', true
    );
  end if;

  update public.usuario
     set estado = 'ativa'
   where id = v_uid;

  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    criada_em,
    resolvido_em,
    resultado
  ) values (
    'suporte',
    v_uid,
    v_operador,
    'Reativação de conta: ' || v_just,
    v_agora,
    v_agora,
    'Conta reativada pela Equipe Frila via procedimento operacional.'
  ) returning id into v_oc_id;

  -- RN15 / Card BsXIZHOw: notificação sem motivo no push
  perform privado.notificar(
    v_uid,
    'reativacao'::public.tipo_notificacao,
    v_oc_id,
    '{}'::jsonb
  );

  return jsonb_build_object(
    'usuario_id',      v_uid,
    'estado_anterior', 'suspensa',
    'estado_atual',    'ativa',
    'ocorrencia_id',   v_oc_id,
    'reativado_em',    v_agora
  );
end $$;

comment on function privado.operacao_reativar_conta(uuid, text, uuid) is
  'Reativa conta suspensa com registro de ocorrência assinada pelo operador da Equipe Frila e notificação push sem motivo. Restrito a service_role.';

revoke execute on function privado.operacao_reativar_conta(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_reativar_conta(uuid, text, uuid) to service_role;

-- ── 4. Funções auxiliares privado.suspender e privado.reativar ─────────────────

create or replace function privado.suspender(
  conta       uuid,
  motivo      text,
  operador_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_operador uuid := operador_id;
begin
  if conta is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if motivo is null or pg_catalog.btrim(motivo) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  if v_operador is null then
    v_operador := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
  end if;

  -- Autoria nunca é adivinhada: sem operador identificado, recusa.
  if v_operador is null then
    perform public.erro(422, 'campo_obrigatorio', 'operador_id');
  end if;

  return privado.operacao_suspender_conta(conta, motivo, v_operador);
end $$;

comment on function privado.suspender(uuid, text, uuid) is
  'Suspende conta de usuário (RN13) com registro de ocorrência, cancelamento de turnos futuros e notificação push sem motivo. Restrito a service_role.';

revoke execute on function privado.suspender(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.suspender(uuid, text, uuid) to service_role;

create or replace function privado.reativar(
  conta       uuid,
  motivo      text default 'Reativação operacional',
  operador_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_operador uuid := operador_id;
begin
  if conta is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if motivo is null or pg_catalog.btrim(motivo) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'justificativa');
  end if;

  if v_operador is null then
    v_operador := nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
  end if;

  -- Autoria nunca é adivinhada: sem operador identificado, recusa.
  if v_operador is null then
    perform public.erro(422, 'campo_obrigatorio', 'operador_id');
  end if;

  return privado.operacao_reativar_conta(conta, motivo, v_operador);
end $$;

comment on function privado.reativar(uuid, text, uuid) is
  'Reativa conta de usuário (RN13) com registro de ocorrência e notificação push sem motivo. Restrito a service_role.';

revoke execute on function privado.reativar(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.reativar(uuid, text, uuid) to service_role;

-- ── 5. public.situacao_da_conta ────────────────────────────────────────────────

create or replace function public.situacao_da_conta()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_usuario  public.usuario%rowtype;
  v_susp     public.ocorrencia%rowtype;
  v_cont     public.ocorrencia%rowtype;
  v_cont_obj jsonb := null;
  v_susp_obj jsonb := null;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid;

  if not found or v_usuario.estado = 'anonimizada' then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if v_usuario.estado = 'suspensa' then
    select * into v_susp
      from public.ocorrencia o
     where o.usuario_id = v_uid
       and o.tipo = 'suspensao'
     order by o.criada_em desc
     limit 1;

    select * into v_cont
      from public.ocorrencia c
     where c.usuario_id = v_uid
       and c.tipo = 'contestacao'
       and c.criada_em >= coalesce(v_susp.criada_em, '-infinity'::timestamptz)
       and c.resolvido_em is null
     order by c.criada_em desc
     limit 1;

    if v_cont.id is not null then
      v_cont_obj := jsonb_build_object(
        'ocorrencia_id',      v_cont.id,
        'tipo',               'contestacao',
        'criada_em',          v_cont.criada_em,
        'prazo_resposta_ate', privado.prazo_de_resposta(v_cont.criada_em)
      );
    end if;

    v_susp_obj := jsonb_build_object(
      'motivo',      coalesce(v_susp.motivo, 'Suspensão de conta pela Equipe Frila'),
      'desde',       coalesce(v_susp.criada_em, v_usuario.criado_em),
      'contestacao', v_cont_obj
    );
  end if;

  return jsonb_build_object(
    'estado',    v_usuario.estado,
    'suspensao', v_susp_obj
  );
end $$;

comment on function public.situacao_da_conta() is
  'Situação da conta e da suspensão, se houver (RF24, RN13, UC15).';

revoke execute on function public.situacao_da_conta() from public, anon;
grant  execute on function public.situacao_da_conta() to authenticated;

-- ── 6. public.contestar_suspensao ──────────────────────────────────────────────

create or replace function public.contestar_suspensao(relato text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid      uuid := (select auth.uid());
  v_usuario  public.usuario%rowtype;
  v_relato   text := pg_catalog.btrim(contestar_suspensao.relato);
  v_agora    timestamptz := privado.agora();
  v_susp     public.ocorrencia%rowtype;
  v_oc       public.ocorrencia%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid;

  if not found or v_usuario.estado = 'anonimizada' then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if v_usuario.estado <> 'suspensa' then
    perform public.erro(422, 'sem_suspensao_ativa');
  end if;

  if v_relato is null or v_relato = '' then
    perform public.erro(422, 'campo_obrigatorio', 'relato');
  end if;

  if pg_catalog.length(v_relato) < 10 then
    perform public.erro(422, 'campo_invalido', 'relato');
  end if;

  -- Diretriz 1.2 da App Store nos campos livres
  perform privado.exigir_texto_aceitavel(jsonb_build_object('relato', v_relato));

  select * into v_susp
    from public.ocorrencia o
   where o.usuario_id = v_uid
     and o.tipo = 'suspensao'
   order by o.criada_em desc
   limit 1;

  if exists (
    select 1
      from public.ocorrencia c
     where c.usuario_id = v_uid
       and c.tipo = 'contestacao'
       and c.criada_em >= coalesce(v_susp.criada_em, '-infinity'::timestamptz)
  ) then
    perform public.erro(409, 'contestacao_ja_aberta');
  end if;

  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    relato,
    criada_em
  ) values (
    'contestacao',
    v_uid,
    v_uid,
    'Contestação de suspensão',
    v_relato,
    v_agora
  ) returning * into v_oc;

  -- Enfileira o aviso de e-mail à Equipe Frila, só com o ID (RN15: sem relato nem dado pessoal na fila)
  perform pgmq.send('email', jsonb_build_object(
    'tipo',          'contestacao',
    'ocorrencia_id', v_oc.id
  ));

  return jsonb_build_object(
    'ocorrencia_id',      v_oc.id,
    'tipo',               'contestacao',
    'criada_em',          v_oc.criada_em,
    'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em)
  );
end $$;

comment on function public.contestar_suspensao(text) is
  'Contestar a suspensão com envio de protocolo à Equipe Frila e prazo de 5 dias úteis (RF24, RN13, UC15).';

revoke execute on function public.contestar_suspensao(text) from public, anon;
grant  execute on function public.contestar_suspensao(text) to authenticated;
