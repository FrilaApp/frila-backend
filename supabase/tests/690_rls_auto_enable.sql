-- RLS ligado automaticamente em qualquer tabela nova (RNF11).
--
-- Cobertura do gatilho de evento `ensure_rls` e da função `public.rls_auto_enable()`
-- (migração 20260922220000_search_path_e_rls_automatico.sql).
--
-- Em banco exposto via PostgREST, uma tabela criada sem RLS fica aberta para consulta
-- ou mutação por papéis anônimos ou autenticados caso um endpoint seja mapeado.
-- O gatilho de evento `ensure_rls` intercepta comandos DDL ao final de sua execução
-- (`ddl_command_end`), inspeciona os comandos que criam tabelas (`CREATE TABLE` e
-- `CREATE TABLE AS`) e aplica imediatamente `ALTER TABLE ... ENABLE ROW LEVEL SECURITY`
-- nas tabelas de esquemas de aplicação (fora de `pg_catalog`, `information_schema` e
-- extensões). Tabelas temporárias não sofrem essa imposição.
--
-- Este teste valida:
--   1. Existência e permissões de `public.rls_auto_enable()` (SECURITY DEFINER, sem EXECUTE para anon/authenticated).
--   2. Presença e estado ativo do event trigger `ensure_rls`.
--   3. Ativação automática de RLS em tabela criada via `CREATE TABLE`.
--   4. Ativação automática de RLS em tabela criada via `CREATE TABLE AS`.
--   5. Não interferência em tabelas temporárias (`pg_temp`).

begin;

select plan(10);

-- ── 1. Estrutura, permissões e event trigger ─────────────────────────────────

select has_function('public', 'rls_auto_enable', array[]::text[],
  'public.rls_auto_enable() existe');

select function_lang_is('public', 'rls_auto_enable', array[]::text[], 'plpgsql',
  'rls_auto_enable é em plpgsql');

select is_definer('public', 'rls_auto_enable', array[]::text[],
  'rls_auto_enable é SECURITY DEFINER');

select ok(exists (select 1 from pg_event_trigger where evtname = 'ensure_rls'),
  'event trigger ensure_rls existe');

select is((select evtenabled from pg_event_trigger where evtname = 'ensure_rls'), 'O',
  'event trigger ensure_rls está ativo (enabled)');

select is(has_function_privilege('anon', 'public.rls_auto_enable()', 'execute'), false,
  'anon não executa public.rls_auto_enable()');

select is(has_function_privilege('authenticated', 'public.rls_auto_enable()', 'execute'), false,
  'authenticated não executa public.rls_auto_enable()');

-- ── 2. Ativação automática de RLS em tabelas novas ───────────────────────────

create table public.t_teste_rls_auto (id int);

select is(
  (select relrowsecurity from pg_class where oid = 'public.t_teste_rls_auto'::regclass),
  true,
  'RNF11: CREATE TABLE ativa RLS automaticamente via ensure_rls'
);

create table public.t_teste_rls_as as select 1 as x;

select is(
  (select relrowsecurity from pg_class where oid = 'public.t_teste_rls_as'::regclass),
  true,
  'RNF11: CREATE TABLE AS ativa RLS automaticamente via ensure_rls'
);

-- ── 3. Tabelas temporárias ───────────────────────────────────────────────────

create temp table t_temp_sem_rls (id int);

select is(
  (select relrowsecurity from pg_class where relname = 't_temp_sem_rls'),
  false,
  'tabela temporária (pg_temp) permanece sem RLS'
);

select * from finish();

rollback;
