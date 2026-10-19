-- Isolamento de dados de telemetria e revisão (RN15, LGPD).
--
-- Cobertura das tabelas operacionais sem leitura pública:
--   - `public.evento_app` (migração 20260930180000_telemetria_evento_app.sql)
--   - `public.entrada_demonstracao` (migração 20260925140000_entrada_de_demonstracao.sql)
--
-- Ambas as tabelas aplicam a estratégia de contenção em duas camadas:
--   1. RLS ativada sem nenhuma política permissiva para clientes (`anon` e `authenticated`).
--   2. Revogação explícita de privilégios de tabela para papéis não privilegiados,
--      garantindo que chamadas via PostgREST direto recebam 42501 (permission denied).
--   3. Concessão para `service_role` (privilégio padrão de tabelas administrativas do Supabase).
--
-- Este teste valida:
--   1. RLS habilitada em `pg_class` para ambas as tabelas.
--   2. Ausência de políticas RLS para clientes em `pg_policies`.
--   3. Bloqueio de privilégios (SELECT, INSERT) no catálogo para anon e authenticated.
--   4. Execução real como `anon` e `authenticated` disparando erro 42501 (permission denied)
--      em tentativas de SELECT e INSERT.
--   5. Defesa em profundidade: mesmo se um GRANT SELECT for concedido por acidente a `authenticated`,
--      o RLS ativado sem políticas oculta 100% das linhas existentes.
--   6. Concessão para `service_role` (SELECT e INSERT).

begin;

select plan(25);

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

-- ── 3. Bloqueio no catálogo para anon e authenticated ─────────────────────────

select is(has_table_privilege('anon', 'public.evento_app', 'select'), false,
  'anon não tem SELECT em public.evento_app');

select is(has_table_privilege('anon', 'public.evento_app', 'insert'), false,
  'anon não tem INSERT em public.evento_app');

select is(has_table_privilege('anon', 'public.entrada_demonstracao', 'select'), false,
  'anon não tem SELECT em public.entrada_demonstracao');

select is(has_table_privilege('anon', 'public.entrada_demonstracao', 'insert'), false,
  'anon não tem INSERT em public.entrada_demonstracao');

select is(has_table_privilege('authenticated', 'public.evento_app', 'select'), false,
  'authenticated não tem SELECT em public.evento_app');

select is(has_table_privilege('authenticated', 'public.evento_app', 'insert'), false,
  'authenticated não tem INSERT em public.evento_app');

select is(has_table_privilege('authenticated', 'public.entrada_demonstracao', 'select'), false,
  'authenticated não tem SELECT em public.entrada_demonstracao');

select is(has_table_privilege('authenticated', 'public.entrada_demonstracao', 'insert'), false,
  'authenticated não tem INSERT em public.entrada_demonstracao');

-- ── 4. Execução real com papéis do cliente (permissão negada 42501) ──────────

set local role anon;

select throws_ok(
  'select count(*) from public.evento_app',
  '42501',
  'permission denied for table evento_app',
  'anon sofre 42501 ao tentar selecionar evento_app'
);

select throws_ok(
  $$ insert into public.evento_app (id, usuario_id, evento, ocorrido_em, criado_em) values (gen_random_uuid(), gen_random_uuid(), 'app_aberto', now(), now()) $$,
  '42501',
  'permission denied for table evento_app',
  'anon sofre 42501 ao tentar inserir em evento_app'
);

select throws_ok(
  'select count(*) from public.entrada_demonstracao',
  '42501',
  'permission denied for table entrada_demonstracao',
  'anon sofre 42501 ao tentar selecionar entrada_demonstracao'
);

select throws_ok(
  $$ insert into public.entrada_demonstracao (email, aceita) values ('anon@frila.app', false) $$,
  '42501',
  'permission denied for table entrada_demonstracao',
  'anon sofre 42501 ao tentar inserir em entrada_demonstracao'
);

reset role;

set local role authenticated;

select throws_ok(
  'select count(*) from public.evento_app',
  '42501',
  'permission denied for table evento_app',
  'authenticated sofre 42501 ao tentar selecionar evento_app'
);

select throws_ok(
  $$ insert into public.evento_app (id, usuario_id, evento, ocorrido_em, criado_em) values (gen_random_uuid(), gen_random_uuid(), 'app_aberto', now(), now()) $$,
  '42501',
  'permission denied for table evento_app',
  'authenticated sofre 42501 ao tentar inserir em evento_app'
);

select throws_ok(
  'select count(*) from public.entrada_demonstracao',
  '42501',
  'permission denied for table entrada_demonstracao',
  'authenticated sofre 42501 ao tentar selecionar entrada_demonstracao'
);

select throws_ok(
  $$ insert into public.entrada_demonstracao (email, aceita) values ('auth@frila.app', false) $$,
  '42501',
  'permission denied for table entrada_demonstracao',
  'authenticated sofre 42501 ao tentar inserir em entrada_demonstracao'
);

reset role;

-- ── 5. Defesa em profundidade: RLS sem políticas bloqueia mesmo com GRANT ─────

-- Insere linha de teste como administrador
insert into public.entrada_demonstracao (email, aceita)
values ('isolamento_rls_697@frila.app', false);

-- Simula falha operacional de concessão indevida de permissão de leitura
grant select on public.entrada_demonstracao to authenticated;

set local role authenticated;

select is(
  (select count(*) from public.entrada_demonstracao),
  0::bigint,
  'mesmo com GRANT SELECT concedido a authenticated, RLS sem políticas oculta 100% das linhas'
);

reset role;

-- ── 6. Permissões de service_role ─────────────────────────────────────────────

select is(has_table_privilege('service_role', 'public.evento_app', 'select'), true,
  'service_role pode ler public.evento_app');

select is(has_table_privilege('service_role', 'public.evento_app', 'insert'), true,
  'service_role pode gravar public.evento_app');

select is(has_table_privilege('service_role', 'public.entrada_demonstracao', 'select'), true,
  'service_role pode ler public.entrada_demonstracao');

select is(has_table_privilege('service_role', 'public.entrada_demonstracao', 'insert'), true,
  'service_role pode gravar public.entrada_demonstracao');

select * from finish();

rollback;
