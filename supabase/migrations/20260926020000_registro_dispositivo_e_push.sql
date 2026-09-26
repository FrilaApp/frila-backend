-- Registro do aparelho, estado de entrega do push FCM e métricas RNF02/RNF03.
-- Cartão 36fU0CEO: Envio de push pelo FCM, registro do aparelho e estado de entrega.
--
-- 1. RPC public.registrar_dispositivo(token_fcm, plataforma) com idempotência e troca de dono.
-- 2. Auxiliares privados para aceite (HTTP 200), erro/retentativa com teto e expiração pós-início.
-- 3. Métrica RNF02 de taxa de aceite em até 60 s nos últimos 7 dias.

-- ── 1. RPC registrar_dispositivo ──────────────────────────────────────────────

create or replace function
  public.registrar_dispositivo(
  token_fcm  text default null,
  plataforma text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid        uuid := (select auth.uid());
  v_agora      timestamptz := privado.agora();
  v_plataforma public.plataforma;
  v_token      text;
  v_disp       public.dispositivo%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if registrar_dispositivo.token_fcm is null
     or pg_catalog.btrim(registrar_dispositivo.token_fcm) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'token_fcm');
  end if;

  v_token := pg_catalog.btrim(registrar_dispositivo.token_fcm);

  if pg_catalog.length(v_token) < 20 then
    perform public.erro(422, 'campo_invalido', 'token_fcm');
  end if;

  if registrar_dispositivo.plataforma is null
     or pg_catalog.btrim(registrar_dispositivo.plataforma) = '' then
    perform public.erro(422, 'campo_obrigatorio', 'plataforma');
  end if;

  if not registrar_dispositivo.plataforma
         = any (pg_catalog.enum_range(null::public.plataforma)::text[]) then
    perform public.erro(422, 'campo_invalido', 'plataforma');
  end if;

  v_plataforma := registrar_dispositivo.plataforma::public.plataforma;

  -- Grava ou atualiza mantendo unicidade pelo token_fcm.
  -- Se o aparelho já estava registrado para outra conta, troca o dono (RN25 / ciclo de vida do token).
  insert into public.dispositivo (usuario_id, token_fcm, plataforma, atualizado_em)
  values (v_uid, v_token, v_plataforma, v_agora)
  on conflict (token_fcm) do update
    set usuario_id    = excluded.usuario_id,
        plataforma    = excluded.plataforma,
        atualizado_em = excluded.atualizado_em
  returning * into v_disp;

  return pg_catalog.jsonb_build_object(
    'plataforma',    v_disp.plataforma,
    'atualizado_em', v_disp.atualizado_em
  );
end $$;

comment on function public.registrar_dispositivo(text, text) is
  'Registra ou atualiza o token de push do aparelho (RF06, RNF02). Idempotente: mesmo token atualiza a data e transfere de conta em caso de troca de dono no mesmo aparelho. Retorna {plataforma, atualizado_em} conforme o contrato Dispositivo.';

revoke execute on function public.registrar_dispositivo(text, text) from public, anon;
grant  execute on function public.registrar_dispositivo(text, text) to authenticated;

-- ── 1.1 Coluna e índice para retentativa com backoff exponencial ──────────────

alter table public.notificacao
  add column if not exists proxima_tentativa_em timestamptz;

comment on column public.notificacao.proxima_tentativa_em is
  'Instante a partir do qual uma nova tentativa de envio pode ser feita após erro transitório (backoff exponencial).';

create index if not exists notificacao_fila_pendente
  on public.notificacao (estado_entrega, proxima_tentativa_em, enviada_em)
  where estado_entrega = 'pendente';

-- ── 2. Auxiliares privados do ciclo de entrega do push ────────────────────────

create or replace function privado.gravar_aceite_push(
  p_notificacao_id uuid,
  p_aceita_em      timestamptz default null,
  p_enviada_em     timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_enviada timestamptz := coalesce(p_enviada_em, v_agora);
  v_aceita  timestamptz := coalesce(p_aceita_em, v_agora);
begin
  update public.notificacao
     set estado_entrega       = 'enviada',
         enviada_em           = v_enviada,
         aceita_em            = v_aceita,
         motivo_falha         = null,
         tentativas           = tentativas + 1,
         proxima_tentativa_em = null
   where id = p_notificacao_id;
end $$;

comment on function privado.gravar_aceite_push(uuid, timestamptz, timestamptz) is
  'Grava o aceite da notificação pelo FCM (HTTP 200). estado_entrega passa a enviada, enviada_em grava o instante real do envio, aceita_em é preenchido e proxima_tentativa_em é limpo. Privada, usada pela Edge Function enviar-push.';

revoke execute on function privado.gravar_aceite_push(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant  execute on function privado.gravar_aceite_push(uuid, timestamptz, timestamptz) to service_role;

create or replace function privado.gravar_falha_push(
  p_notificacao_id       uuid,
  p_motivo               text,
  p_permanente           boolean default false,
  p_teto                 int default 5,
  p_proxima_tentativa_em timestamptz default null,
  p_enviada_em           timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tentativas int;
  v_agora      timestamptz := privado.agora();
  v_proxima    timestamptz := p_proxima_tentativa_em;
begin
  update public.notificacao
     set tentativas   = tentativas + 1,
         motivo_falha = p_motivo,
         enviada_em   = coalesce(p_enviada_em, enviada_em)
   where id = p_notificacao_id
  returning tentativas into v_tentativas;

  if p_permanente or v_tentativas >= p_teto then
    update public.notificacao
       set estado_entrega       = 'falhou',
           proxima_tentativa_em = null
     where id = p_notificacao_id;
  else
    if v_proxima is null then
      v_proxima := v_agora + (interval '10 seconds' * power(2, greatest(0, v_tentativas - 1)));
    end if;

    update public.notificacao
       set estado_entrega       = 'pendente',
           proxima_tentativa_em = v_proxima
     where id = p_notificacao_id;
  end if;
end $$;

comment on function privado.gravar_falha_push(uuid, text, boolean, int, timestamptz, timestamptz) is
  'Registra falha de envio ao FCM. Erro permanente ou tentativas >= teto marcam falhou e limpam proxima_tentativa_em; erro transitório abaixo do teto mantém pendente com backoff exponencial em proxima_tentativa_em para retry.';

revoke execute on function privado.gravar_falha_push(uuid, text, boolean, int, timestamptz, timestamptz) from public, anon, authenticated;
grant  execute on function privado.gravar_falha_push(uuid, text, boolean, int, timestamptz, timestamptz) to service_role;


create or replace function privado.remover_token_fcm(p_token text)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_removidos int;
begin
  delete from public.dispositivo
   where token_fcm = p_token;
  get diagnostics v_removidos = row_count;
  return v_removidos;
end $$;

comment on function privado.remover_token_fcm(text) is
  'Remove token inválido/UNREGISTERED da tabela public.dispositivo. Privada, usada pela Edge Function enviar-push.';

revoke execute on function privado.remover_token_fcm(text) from public, anon, authenticated;
grant  execute on function privado.remover_token_fcm(text) to service_role;

create or replace function privado.notificacao_expirada(p_notificacao_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notif  public.notificacao%rowtype;
  v_inicio timestamptz;
  v_agora  timestamptz := privado.agora();
begin
  select * into v_notif from public.notificacao where id = p_notificacao_id;
  if not found then
    return true;
  end if;

  if v_notif.tipo in ('vaga', 'vagas_agrupadas', 'vaga_sem_elegiveis', 'vaga_vazia') then
    select g.inicio_em into v_inicio from public.vaga g where g.id = v_notif.referencia_id;
  elsif v_notif.tipo in ('confirmacao', 'cancelamento') then
    select g.inicio_em into v_inicio
      from public.posicao p
      join public.vaga g on g.id = p.vaga_id
     where p.id = v_notif.referencia_id;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.turno t
        join public.posicao p on p.id = t.posicao_id
        join public.vaga g on g.id = p.vaga_id
       where t.id = v_notif.referencia_id;
    end if;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.vaga g
       where g.id = v_notif.referencia_id;
    end if;
  elsif v_notif.tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin',
                         'atraso_15min', 'fim_sem_checkout', 'checkin',
                         'checkin_manual_pendente') then
    select g.inicio_em into v_inicio
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga g on g.id = p.vaga_id
     where t.id = v_notif.referencia_id;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.posicao p
        join public.vaga g on g.id = p.vaga_id
       where p.id = v_notif.referencia_id;
    end if;
  end if;

  if v_inicio is not null and v_inicio <= v_agora then
    return true;
  end if;

  return false;
end $$;

comment on function privado.notificacao_expirada(uuid) is
  'Verifica se o início do turno ou da vaga associada à notificação já passou, impedindo reenvio após o início.';

revoke execute on function privado.notificacao_expirada(uuid) from public, anon, authenticated;
grant  execute on function privado.notificacao_expirada(uuid) to service_role;

-- ── 3. Métrica RNF02: Taxa de notificações aceitas em até 60 s nos últimos 7 d ─

create or replace function privado.taxa_aceite_notificacoes_7d()
returns table (
  total_despachadas bigint,
  aceitas_em_60s     bigint,
  taxa_aceite_pct   numeric
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    pg_catalog.count(*)::bigint,
    pg_catalog.count(*) filter (where aceita_em is not null and aceita_em - enviada_em <= interval '60 seconds')::bigint,
    case
      when pg_catalog.count(*) = 0 then 0.0
      else pg_catalog.round(
        100.0 * pg_catalog.count(*) filter (where aceita_em is not null and aceita_em - enviada_em <= interval '60 seconds')
        / pg_catalog.count(*),
        2
      )
    end
  from public.notificacao
 where enviada_em >= privado.agora() - interval '7 days';
$$;

comment on function privado.taxa_aceite_notificacoes_7d() is
  'Métrica RNF02: taxa de notificações aceitas pelo provedor em até 60 s na janela móvel dos últimos 7 dias.';

revoke execute on function privado.taxa_aceite_notificacoes_7d() from public, anon;
grant  execute on function privado.taxa_aceite_notificacoes_7d() to authenticated, service_role;
