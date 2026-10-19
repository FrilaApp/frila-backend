-- Privilégios mínimos nas tabelas dos schemas expostos (public e graphql_public).
--
-- Garante que authenticated e anon não possuem privilégios desnecessários
-- (REFERENCES, TRIGGER e MAINTAIN) em nenhuma tabela do schema public nem graphql_public,
-- mantendo para authenticated estritamente o SELECT necessário para a leitura sob RLS,
-- e garantindo que tabelas futuras criadas por postgres não herdem privilégios excessivos.

begin;
select plan(14);

-- ── 1. Tabelas existentes em public não possuem REFERENCES, TRIGGER ou MAINTAIN ──

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'references')),
  0,
  'authenticated não tem privilégio REFERENCES em nenhuma tabela de public');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'trigger')),
  0,
  'authenticated não tem privilégio TRIGGER em nenhuma tabela de public');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'maintain')),
  0,
  'authenticated não tem privilégio MAINTAIN em nenhuma tabela de public');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'references')),
  0,
  'anon não tem privilégio REFERENCES em nenhuma tabela de public');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'trigger')),
  0,
  'anon não tem privilégio TRIGGER em nenhuma tabela de public');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'maintain')),
  0,
  'anon não tem privilégio MAINTAIN em nenhuma tabela de public');

-- ── 2. Authenticated mantém SELECT sob RLS nas 19 tabelas de produto ───────────

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'select')),
  19,
  'authenticated mantém SELECT nas 19 tabelas de produto de public');

-- ── 3. graphql_public não tem tabelas com privilégios excessivos ───────────────

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'graphql_public' and c.relkind in ('r', 'p')
      and (has_table_privilege('authenticated', c.oid, 'references')
           or has_table_privilege('authenticated', c.oid, 'trigger')
           or has_table_privilege('authenticated', c.oid, 'maintain')
           or has_table_privilege('anon', c.oid, 'references')
           or has_table_privilege('anon', c.oid, 'trigger')
           or has_table_privilege('anon', c.oid, 'maintain'))),
  0,
  'graphql_public não tem tabelas com privilégios excessivos para authenticated ou anon');

-- ── 4. Tabelas futuras criadas por postgres não herdam privilégios excessivos ──

create table public.tabela_futura_teste (id int);

select ok(
  not has_table_privilege('authenticated', 'public.tabela_futura_teste'::regclass, 'references'),
  'tabela criada no futuro não herda REFERENCES para authenticated');

select ok(
  not has_table_privilege('authenticated', 'public.tabela_futura_teste'::regclass, 'trigger'),
  'tabela criada no futuro não herda TRIGGER para authenticated');

select ok(
  not has_table_privilege('authenticated', 'public.tabela_futura_teste'::regclass, 'maintain'),
  'tabela criada no futuro não herda MAINTAIN para authenticated');

select ok(
  not has_table_privilege('anon', 'public.tabela_futura_teste'::regclass, 'references'),
  'tabela criada no futuro não herda REFERENCES para anon');

select ok(
  not has_table_privilege('anon', 'public.tabela_futura_teste'::regclass, 'trigger'),
  'tabela criada no futuro não herda TRIGGER para anon');

select ok(
  not has_table_privilege('anon', 'public.tabela_futura_teste'::regclass, 'maintain'),
  'tabela criada no futuro não herda MAINTAIN para anon');

drop table public.tabela_futura_teste;

select * from finish();
rollback;
