-- Telemetria do piloto: eventos do funil e tabela evento_app (Cartão 3zsjXW60 · T-0017 · RNF02, RNF03, RNF13).
--
-- O funil sai quase todo das tabelas do ciclo (vaga, posicao, candidatura, turno, avaliacao).
-- Eventos do aparelho servem para o que não passa pelo servidor (abrir a notificação, ver o detalhe,
-- tela exibida, permissão de push negada, fila offline).
--
-- ── Regras duras deste módulo ──────────────────────────────────────────────────
--
-- 1. Lista fechada de eventos (enum public.evento_de_telemetria):
--    Exatamente os 14 eventos declarados em EventoDeTelemetria no contrato/openapi.yaml (0.2.27).
--    Evento fora da lista é recusado com 422 campo_invalido (details: evento).
--
-- 2. RN15 estrita (sem dado pessoal em log ou telemetria):
--    A tabela evento_app só guarda usuario_id, evento, vaga_id, turno_id, ocorrido_em e criado_em.
--    Nenhum campo livre de texto, nenhum telefone, nenhum e-mail, nenhuma coordenada geográfica.
--
-- 3. Sem leitura para clientes:
--    A tabela public.evento_app tem RLS ativado e permissões revogadas de public, anon e authenticated.
--    Apenas o service_role e o schema metrica leem os dados.
--
-- 4. Retenção de 90 dias:
--    Eventos com mais de 90 dias são removidos pela rotina diária de retenção (privado.executar_retencao_diaria).
--
-- 5. Exclusão de demonstração e equipe Frila:
--    A view metrica.eventos_app_por_dia exclui contas de teste/demonstração e contas da Equipe Frila.

-- ── 1. Enum public.evento_de_telemetria ─────────────────────────────────────────

create type public.evento_de_telemetria as enum (
  'app_aberto',
  'cadastro_concluido',
  'permissao_push_negada',
  'vaga_vista',
  'vaga_detalhe_aberto',
  'candidatura_enviada',
  'candidatura_retirada',
  'checkin_tentado',
  'checkin_concluido',
  'checkout_concluido',
  'avaliacao_enviada',
  'contato_aberto',
  'acao_enfileirada_offline',
  'atualizacao_obrigatoria_exibida'
);

comment on type public.evento_de_telemetria is
  'Dicionário fechado de eventos de telemetria do aplicativo (T-0017, RN15).';

-- ── 2. Tabela public.evento_app ────────────────────────────────────────────────

create table public.evento_app (
  id          uuid primary key default gen_random_uuid(),
  usuario_id  uuid not null references public.usuario(id) on delete cascade,
  evento      public.evento_de_telemetria not null,
  vaga_id     uuid references public.vaga(id) on delete set null,
  turno_id    uuid references public.turno(id) on delete set null,
  ocorrido_em timestamptz not null default now(),
  criado_em   timestamptz not null default now()
);

comment on table public.evento_app is
  'Registro de eventos de telemetria do app (cartão 3zsjXW60, T-0017). Sem campos de texto livre (RN15). Retenção de 90 dias. Sem leitura para clientes.';

comment on column public.evento_app.usuario_id is 'Conta autenticada que emitiu o evento.';
comment on column public.evento_app.evento is 'Identificador do evento do dicionário fechado.';
comment on column public.evento_app.vaga_id is 'Vaga relacionada ao evento, se houver.';
comment on column public.evento_app.turno_id is 'Turno relacionado ao evento, se houver.';
comment on column public.evento_app.ocorrido_em is 'Instante em que o evento ocorreu no cliente (preserva histórico de fila offline).';
comment on column public.evento_app.criado_em is 'Instante em que o evento foi recebido no servidor.';

create index evento_app_usuario_id_idx on public.evento_app (usuario_id);
create index evento_app_evento_idx on public.evento_app (evento);
create index evento_app_criado_em_idx on public.evento_app (criado_em);
create index evento_app_vaga_id_idx on public.evento_app (vaga_id) where vaga_id is not null;
create index evento_app_turno_id_idx on public.evento_app (turno_id) where turno_id is not null;

-- RLS: clientes não leem nem escrevem diretamente na tabela
alter table public.evento_app enable row level security;

revoke all on table public.evento_app from public, anon, authenticated;
grant all on table public.evento_app to service_role;

-- ── 3. RPC public.registrar_evento ─────────────────────────────────────────────

create or replace function public.registrar_evento(
  evento      text,
  vaga_id     uuid default null,
  turno_id    uuid default null,
  ocorrido_em timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_usuario_id  uuid := auth.uid();
  v_agora       timestamptz := privado.agora();
  v_ocorrido    timestamptz;
  v_evento_enum public.evento_de_telemetria;
begin
  if v_usuario_id is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if evento is null or pg_catalog.btrim(evento) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'evento');
  end if;

  begin
    v_evento_enum := evento::public.evento_de_telemetria;
  exception when invalid_text_representation then
    perform public.erro(422, 'campo_invalido', 'evento');
  end;

  if ocorrido_em is not null then
    if ocorrido_em > v_agora then
      perform public.erro(422, 'registro_no_futuro');
    end if;
    v_ocorrido := ocorrido_em;
  else
    v_ocorrido := v_agora;
  end if;

  if vaga_id is not null and not exists (select 1 from public.vaga where id = vaga_id) then
    perform public.erro(422, 'campo_invalido', 'vaga_id');
  end if;

  if turno_id is not null and not exists (select 1 from public.turno where id = turno_id) then
    perform public.erro(422, 'campo_invalido', 'turno_id');
  end if;

  insert into public.evento_app (
    usuario_id, evento, vaga_id, turno_id, ocorrido_em, criado_em
  ) values (
    v_usuario_id, v_evento_enum, vaga_id, turno_id, v_ocorrido, v_agora
  );

  return jsonb_build_object('registrado', true);
end $$;

comment on function public.registrar_evento(text, uuid, uuid, timestamptz) is
  'Registra um evento de telemetria do aplicativo a partir do dicionário fechado (EventoDeTelemetria). Sem campos livres (RN15). Recusa evento inválido com 422 campo_invalido e evento no futuro com 422 registro_no_futuro.';

revoke execute on function public.registrar_evento(text, uuid, uuid, timestamptz) from public, anon;
grant  execute on function public.registrar_evento(text, uuid, uuid, timestamptz) to authenticated;
grant  execute on function public.registrar_evento(text, uuid, uuid, timestamptz) to service_role;

-- ── 4. Retenção de 90 dias ─────────────────────────────────────────────────────

create or replace function privado.limpar_eventos_app(dias integer default 90)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_removidos integer;
begin
  delete from public.evento_app
   where criado_em < privado.agora() - (dias || ' days')::interval;
  get diagnostics v_removidos = row_count;
  return v_removidos;
end $$;

comment on function privado.limpar_eventos_app(integer) is
  'Exclui eventos de telemetria mais antigos que a janela de retenção (padrão 90 dias). Restrito a service_role.';

revoke execute on function privado.limpar_eventos_app(integer) from public, anon, authenticated;
grant  execute on function privado.limpar_eventos_app(integer) to service_role;

-- Atualiza rotina consolidada diária para incluir a higienização dos eventos de telemetria
create or replace function privado.executar_retencao_diaria()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anonimizadas integer;
  v_higiene      jsonb;
  v_eventos_app  integer;
begin
  v_anonimizadas := privado.limpar_contas_anonimizadas(15);
  v_higiene      := privado.higienizar_tabelas();
  v_eventos_app  := privado.limpar_eventos_app(90);

  return jsonb_build_object(
    'executado_em',               privado.agora(),
    'contas_anonimizadas_limpas', v_anonimizadas,
    'higiene',                    v_higiene,
    'eventos_app_limpos',         v_eventos_app
  );
end $$;

comment on function privado.executar_retencao_diaria() is
  'Rotina consolidada de retenção de 15 dias de contas, 90 dias de telemetria e higienização de tabelas operacionais. Rodada diariamente pelo pg_cron.';

revoke execute on function privado.executar_retencao_diaria() from public, anon, authenticated;
grant  execute on function privado.executar_retencao_diaria() to service_role;

-- ── 5. View no schema metrica (sem demo e sem equipe) ─────────────────────────

create or replace view metrica.eventos_app_por_dia as
select
  (ea.criado_em at time zone 'America/Sao_Paulo')::date as dia,
  ea.evento::text as evento,
  count(*)::bigint as total
from public.evento_app ea
join public.usuario u on u.id = ea.usuario_id
where not coalesce(u.demonstracao, false)
  and not exists (select 1 from privado.conta_equipe ce where ce.usuario_id = u.id)
group by (ea.criado_em at time zone 'America/Sao_Paulo')::date, ea.evento
order by dia desc, total desc;

comment on view metrica.eventos_app_por_dia is
  'Consolidado diário de eventos de telemetria do app por tipo de evento. Exclui contas de demonstração e da equipe Frila.';

grant select on metrica.eventos_app_por_dia to service_role;
