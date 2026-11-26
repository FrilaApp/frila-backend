-- pgTAP: Hardening da fundação de login social (delta pós-#635 79bfa627).
-- Cobre:
-- 1. Compatibilidade estrutural real de auth.flow_state na imagem GoTrue em execução (colunas e tipos).
-- 2. Agendamento pg_cron de limpar_artefatos_login_social_expirados (quando extensão pg_cron está ativa).
-- 3. Comentários de catálogo com referência primária GoTrue e ownership operacional.

begin;
select plan(6);

-- 1. Verifica colunas obrigatórias de auth.flow_state no banco real do GoTrue em execução.
select ok(
  exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'flow_state' and column_name = 'auth_code'
  ),
  'auth.flow_state possui coluna auth_code na instancia GoTrue ativa'
);

select ok(
  exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'flow_state' and column_name = 'provider_type'
  ),
  'auth.flow_state possui coluna provider_type na instancia GoTrue ativa'
);

select ok(
  exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'flow_state' and column_name = 'code_challenge'
  )
  and exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'flow_state' and column_name = 'code_challenge_method'
  ),
  'auth.flow_state possui colunas code_challenge e code_challenge_method na instancia GoTrue ativa'
);

-- 2. Verifica job pg_cron quando a extensão pg_cron existe no ambiente.
select ok(
  not exists (select 1 from pg_extension where extname = 'pg_cron')
  or exists (
    select 1
      from cron.job
     where jobname = 'limpar_artefatos_login_social_expirados'
       and schedule = '17 * * * *'
       and command = 'select privado.limpar_artefatos_login_social_expirados(500)'
  ),
  'job pg_cron limpar_artefatos_login_social_expirados agendado em 17 * * * * quando pg_cron esta ativo'
);

-- 3. Comentários de referência primária GoTrue e ownership presentes no catálogo.
select ok(
  obj_description('privado.consumir_transacao_oauth_social(uuid, text, text, text, text)'::regprocedure, 'pg_proc')
    like '%20230322519590_add_flow_state_table%',
  'consumir_transacao_oauth_social registra referencia primaria da migracao auth.flow_state do GoTrue'
);

select ok(
  obj_description('privado.limpar_artefatos_login_social_expirados(integer)'::regprocedure, 'pg_proc')
    like '%17 * * * *%',
  'limpar_artefatos_login_social_expirados registra frequencia e ownership operacional no catalogo'
);

select * from finish();
rollback;
