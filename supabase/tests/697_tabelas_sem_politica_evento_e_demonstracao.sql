-- Isolamento de dados de telemetria e revisão (RN15, LGPD).
--
-- Cobertura das tabelas operacionais sem leitura pública:
--   - `public.evento_app` (migração 20261002090000_eventos_do_app.sql)
--   - `public.entrada_demonstracao` (migração 20260925230000_janela_da_demonstracao.sql)
--
-- Ambas as tabelas aplicam a estratégia de contenção em duas camadas:
--   1. RLS ativada sem nenhuma política permissiva para clientes (`anon` e `authenticated`).
--   2. Revogação explícita de privilégios de tabela para papéis não privilegiados,
--      garantindo que nem mesmo PostgREST direto consiga ler ou forjar registros.
--   3. Concessão estrita para `service_role`.
--
-- Este teste valida:
--   1. RLS habilitada em `pg_class` para ambas as tabelas.
--   2. Ausência de políticas RLS para clientes em `pg_policies`.
--   3. Bloqueio completo de privilégios (SELECT, INSERT, UPDATE, DELETE) para `anon`.
--   4. Bloqueio completo de privilégios (SELECT, INSERT, UPDATE, DELETE) para `authenticated`.
--   5. Concessão estrita para `service_role` (SELECT e INSERT).

begin;

select plan(18);

-- ── 1. RLS habilitada ────────────────────────────────────────────────────────

select is(
  (select relrowsecurity from pg_class where relname = 'evento_app' and relnamespace = 'public'::regnamespace),
  true,
  'public.evento_app tem Row Level Security habilitada'
);

select is(
  (select relrowsecurity from pg_class where relname = 'entrada_demonstracao' and relnamespace = 'public'::regnamespace),
  true,
  'public.entrada_demonstracao tem Row Level Security habilitada'
);

-- ── 2. Ausência de políticas permissivas ───────────────────────────────────────

select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'evento_app'),
  0::bigint,
  'public.evento_app não possui políticas RLS (bloqueio por omissão)'
);

select is(
  (select count(*) from pg_policies where schemaname = 'public' and tablename = 'entrada_demonstracao'),
  0::bigint,
  'public.entrada_demonstracao não possui políticas RLS (bloqueio por omissão)'
);

-- ── 3. Bloqueio para anon ─────────────────────────────────────────────────────

select is(has_table_privilege('anon', 'public.evento_app', 'select'), false,
  'anon não tem SELECT em public.evento_app');

select is(has_table_privilege('anon', 'public.evento_app', 'insert'), false,
  'anon não tem INSERT em public.evento_app');

select is(has_table_privilege('anon', 'public.entrada_demonstracao', 'select'), false,
  'anon não tem SELECT em public.entrada_demonstracao');

select is(has_table_privilege('anon', 'public.entrada_demonstracao', 'insert'), false,
  'anon não tem INSERT em public.entrada_demonstracao');

-- ── 4. Bloqueio para authenticated ────────────────────────────────────────────

select is(has_table_privilege('authenticated', 'public.evento_app', 'select'), false,
  'authenticated não tem SELECT em public.evento_app');

select is(has_table_privilege('authenticated', 'public.evento_app', 'insert'), false,
  'authenticated não tem INSERT em public.evento_app');

select is(has_table_privilege('authenticated', 'public.evento_app', 'update'), false,
  'authenticated não tem UPDATE em public.evento_app');

select is(has_table_privilege('authenticated', 'public.evento_app', 'delete'), false,
  'authenticated não tem DELETE em public.evento_app');

select is(has_table_privilege('authenticated', 'public.entrada_demonstracao', 'select'), false,
  'authenticated não tem SELECT em public.entrada_demonstracao');

select is(has_table_privilege('authenticated', 'public.entrada_demonstracao', 'insert'), false,
  'authenticated não tem INSERT em public.entrada_demonstracao');

select is(has_table_privilege('authenticated', 'public.entrada_demonstracao', 'update'), false,
  'authenticated não tem UPDATE em public.entrada_demonstracao');

select is(has_table_privilege('authenticated', 'public.entrada_demonstracao', 'delete'), false,
  'authenticated não tem DELETE em public.entrada_demonstracao');

-- ── 5. Permissões de service_role ─────────────────────────────────────────────

select is(has_table_privilege('service_role', 'public.evento_app', 'select'), true,
  'service_role pode ler public.evento_app');

select is(has_table_privilege('service_role', 'public.entrada_demonstracao', 'insert'), true,
  'service_role pode gravar public.entrada_demonstracao');

select * from finish();

rollback;
