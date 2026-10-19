-- Monitoramento e alertas do backend desde o TestFlight (cartão 5bPJvMIo).
--
-- RNF02 · RNF03 · RNF12 · RN15.
--
-- 1. Tabela privado.falha_execucao para registro de falhas de Edge Functions e rotinas,
--    sem qualquer dado pessoal (RN15).
-- 2. Tabela privado.alerta_emitido para controle de teto de alertas (máximo 1/hora por tipo).
-- 3. Função privado.emitir_alerta(codigo, valor) que enfileira na fila pgmq `email` com
--    tipo 'alerta' para consumo da Edge Function `enviar-email`.
-- 4. Função privado.verificar_saude() executada via pg_cron a cada 5 minutos:
--    - Idade da mensagem mais velha nas filas pgmq (despacho, email)
--    - Falhas em cron.job_run_details
--    - Notificações em estado 'falhou'
--    - Despachos esperando além do teto da RN23
--    - Job de despacho parado ou desativado (alerta em até 10 minutos)
--    - Falhas recentes em privado.falha_execucao

-- ── 1. Registro de falhas de execução (sem dados pessoais, RN15) ─────────────

create table if not exists privado.falha_execucao (
  id        uuid primary key default gen_random_uuid(),
  origem    text not null,
  codigo    text not null,
  detalhes  jsonb,
  criada_em timestamptz not null default privado.agora(),
  constraint origem_valida check (length(btrim(origem)) > 0 and length(origem) <= 60),
  constraint codigo_valido check (codigo ~ '^[a-z0-9_]{1,60}$')
);

comment on table privado.falha_execucao is
  'Registro operacional de falhas em Edge Functions e rotinas de backend. Estritamente sem dados pessoais (RN15).';

alter table privado.falha_execucao enable row level security;
revoke all on table privado.falha_execucao from public, anon, authenticated;
grant select, insert on table privado.falha_execucao to service_role;

create or replace function privado.registrar_falha_execucao(
  p_origem   text,
  p_codigo   text,
  p_detalhes jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id    uuid;
  v_chave text;
begin
  if p_origem is null or btrim(p_origem) = '' then
    raise exception 'origem_obrigatoria' using errcode = '22023';
  end if;
  if p_codigo is null or p_codigo !~ '^[a-z0-9_]{1,60}$' then
    raise exception 'codigo_invalido' using errcode = '22023';
  end if;

  -- RN15: Nenhum dado pessoal entra em log ou registro operacional.
  -- Rejeita chaves conhecidas que possam carregar dados pessoais ou credenciais.
  if p_detalhes is not null then
    for v_chave in select jsonb_object_keys(p_detalhes) loop
      if lower(v_chave) in (
        'email', 'telefone', 'nome', 'relato', 'documento', 'cpf',
        'chave_pix', 'pix', 'endereco', 'authorization', 'bearer',
        'senha', 'token', 'secret', 'jwt'
      ) then
        raise exception 'dado_pessoal_rejeitado' using errcode = '22023', detail = v_chave;
      end if;
    end loop;
  end if;

  insert into privado.falha_execucao (origem, codigo, detalhes, criada_em)
  values (btrim(p_origem), btrim(p_codigo), p_detalhes, privado.agora())
  returning id into v_id;

  return v_id;
end $$;

comment on function privado.registrar_falha_execucao(text, text, jsonb) is
  'Grava falha operacional com proteção estrita contra vazamento de dados pessoais (RN15).';

revoke execute on function privado.registrar_falha_execucao(text, text, jsonb) from public, anon, authenticated;
grant  execute on function privado.registrar_falha_execucao(text, text, jsonb) to service_role;

-- ── 2. Controle de alertas e emissão com rate limit ──────────────────────────

create table if not exists privado.alerta_emitido (
  codigo     text primary key,
  ultimo_em  timestamptz not null default privado.agora(),
  suprimidos int not null default 0,
  constraint codigo_alerta_valido check (codigo ~ '^[a-z0-9_]{1,60}$')
);

comment on table privado.alerta_emitido is
  'Controle do teto de envio de alertas por e-mail à equipe (no máximo 1 por hora por tipo).';

alter table privado.alerta_emitido enable row level security;
revoke all on table privado.alerta_emitido from public, anon, authenticated;
grant select, insert, update on table privado.alerta_emitido to service_role;

create or replace function privado.emitir_alerta(
  p_codigo text,
  p_valor  numeric default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ultimo timestamptz;
  v_agora  timestamptz := privado.agora();
begin
  if p_codigo is null or p_codigo !~ '^[a-z0-9_]{1,60}$' then
    raise exception 'codigo_de_alerta_invalido' using errcode = '22023';
  end if;

  select ultimo_em into v_ultimo
    from privado.alerta_emitido
   where codigo = p_codigo;

  -- Respeita o teto: no máximo um por hora por tipo
  if v_ultimo is not null and v_ultimo > v_agora - interval '1 hour' then
    update privado.alerta_emitido
       set suprimidos = suprimidos + 1
     where codigo = p_codigo;
    return false;
  end if;

  insert into privado.alerta_emitido (codigo, ultimo_em, suprimidos)
  values (p_codigo, v_agora, 0)
  on conflict (codigo) do update
    set ultimo_em = v_agora,
        suprimidos = 0;

  perform pgmq.send('email', jsonb_build_object(
    'tipo', 'alerta',
    'codigo', p_codigo,
    'valor', p_valor
  ));

  return true;
end $$;

comment on function privado.emitir_alerta(text, numeric) is
  'Enfileira alerta à equipe na fila email respeitando teto de 1 por hora por tipo (cartão 5bPJvMIo).';

revoke execute on function privado.emitir_alerta(text, numeric) from public, anon, authenticated;
grant  execute on function privado.emitir_alerta(text, numeric) to service_role;

-- ── 3. Rotina de verificação de saúde operacional ─────────────────────────────

create or replace function privado.verificar_saude()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alertas            int := 0;
  v_idade_despacho     interval;
  v_idade_email        interval;
  v_falhas_cron        int;
  v_notif_falhas       int;
  v_despachos_travados int;
  v_falhas_exec        int;
  v_agora              timestamptz := privado.agora();
  v_teto_janela        interval;
begin
  -- 1. Job de despacho ativo (RNF12)
  -- Se o job reprocessar_despacho foi desativado ou removido, alerta imediato (em até 10 min)
  if not exists (
    select 1 from cron.job
     where jobname = 'reprocessar_despacho' and active = true
  ) then
    if privado.emitir_alerta('job_despacho_parado', 1) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 2. Idade da mensagem mais velha nas filas pgmq (teto de 15 minutos)
  if exists (select 1 from pg_tables where schemaname = 'pgmq' and tablename = 'q_despacho') then
    select v_agora - min(enqueued_at) into v_idade_despacho from pgmq.q_despacho;
    if v_idade_despacho is not null and v_idade_despacho > interval '15 minutes' then
      if privado.emitir_alerta('fila_despacho_antiga', extract(epoch from v_idade_despacho)::numeric) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  end if;

  if exists (select 1 from pg_tables where schemaname = 'pgmq' and tablename = 'q_email') then
    select v_agora - min(enqueued_at) into v_idade_email from pgmq.q_email;
    if v_idade_email is not null and v_idade_email > interval '15 minutes' then
      if privado.emitir_alerta('fila_email_antiga', extract(epoch from v_idade_email)::numeric) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  end if;

  -- 3. Falhas recentes em cron.job_run_details (últimos 15 minutos)
  if exists (select 1 from pg_tables where schemaname = 'cron' and tablename = 'job_run_details') then
    select count(*) into v_falhas_cron
      from cron.job_run_details
     where status = 'failed'
       and end_time > v_agora - interval '15 minutes';
    if v_falhas_cron > 0 then
      if privado.emitir_alerta('job_cron_falhou', v_falhas_cron) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  end if;

  -- 4. Notificações com estado 'falhou' na última hora
  select count(*) into v_notif_falhas
    from public.notificacao
   where estado_entrega = 'falhou'
     and enviada_em > v_agora - interval '1 hour';
  if v_notif_falhas > 0 then
    if privado.emitir_alerta('notificacao_push_falhou', v_notif_falhas) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 5. Despachos esperando além do teto de RN23
  v_teto_janela := coalesce(privado.parametro_de_notificacao('teto_janela'), interval '30 minutes');
  select count(*) into v_despachos_travados
    from public.despacho
   where notificacao_id is null
     and criado_em < v_agora - (v_teto_janela + interval '15 minutes');
  if v_despachos_travados > 0 then
    if privado.emitir_alerta('despacho_esperando_alem_do_teto', v_despachos_travados) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 6. Falhas de execução registradas por Edge Functions nos últimos 15 minutos
  select count(*) into v_falhas_exec
    from privado.falha_execucao
   where criada_em > v_agora - interval '15 minutes';
  if v_falhas_exec > 0 then
    if privado.emitir_alerta('falha_execucao_edge_function', v_falhas_exec) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  return v_alertas;
end $$;

comment on function privado.verificar_saude() is
  'Varre filas pgmq, falhas de jobs do pg_cron, notificações com erro e despachos retidos. Emite alertas à equipe por e-mail com limite de 1/hora por tipo (cartão 5bPJvMIo).';

revoke execute on function privado.verificar_saude() from public, anon, authenticated;
grant  execute on function privado.verificar_saude() to service_role;

-- ── 4. Agendamento periódico do job no pg_cron ────────────────────────────────

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('verificar_saude')
      where exists (select 1 from cron.job where jobname = 'verificar_saude');
    perform cron.schedule(
      'verificar_saude',
      '*/5 * * * *',
      'select privado.verificar_saude()'
    );
  end if;
end $$;
