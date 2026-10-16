-- Privilégios mínimos nas tabelas do schema privado (defesa em profundidade).
--
-- Validação da auditoria de segurança da develop (16/10, Oráculo):
-- O schema `privado` contém tabelas internas de infraestrutura, ciclo, controle e
-- moderação sem RLS ativada (ambiente, auditoria_ciclo, conta_equipe, divergencia_reputacao,
-- parametro_notificacao, termo_bloqueado, texto_da_vaga_ocultado, tipo_no_teto, vaga_ocultada, etc.).
--
-- A segurança dessas tabelas depende de:
-- 1. O schema `privado` não ser exposto na API do PostgREST (somente `public` e `graphql_public`);
-- 2. Revogação de acesso a `public` e `anon`;
-- 3. Inexistência absoluta de privilégios de tabela (SELECT, INSERT, UPDATE, DELETE, etc.)
--    concedidos ao papel `authenticated` ou `anon`, mesmo que `authenticated` possua USAGE
--    no schema para execução de RPCs/funções internas.
--
-- Este teste garante que:
-- - Nenhuma tabela existente em `privado` concede qualquer privilégio a `authenticated` ou `anon`;
-- - As 9 tabelas sem RLS estão totalmente vedadas;
-- - Tabelas futuras criadas em `privado` não herdam privilégios indevidos;
-- - `authenticated` tem USAGE estrito em `privado` (sem CREATE); `anon` e `public` não têm nem USAGE nem CREATE;
-- - Qualquer concessão acidental de privilégio a `authenticated` quebra o teste imediatamente.

begin;
select plan(30);

-- ── 1. Tabelas existentes em privado não concedem privilégios a authenticated ──

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'select')),
  0,
  'authenticated não tem privilégio SELECT em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'insert')),
  0,
  'authenticated não tem privilégio INSERT em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'update')),
  0,
  'authenticated não tem privilégio UPDATE em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'delete')),
  0,
  'authenticated não tem privilégio DELETE em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'truncate')),
  0,
  'authenticated não tem privilégio TRUNCATE em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'references')),
  0,
  'authenticated não tem privilégio REFERENCES em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'trigger')),
  0,
  'authenticated não tem privilégio TRIGGER em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('authenticated', c.oid, 'maintain')),
  0,
  'authenticated não tem privilégio MAINTAIN em nenhuma tabela de privado');

-- ── 2. Tabelas existentes em privado não concedem privilégios a anon ───────────

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'select')),
  0,
  'anon não tem privilégio SELECT em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'insert')),
  0,
  'anon não tem privilégio INSERT em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'update')),
  0,
  'anon não tem privilégio UPDATE em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'delete')),
  0,
  'anon não tem privilégio DELETE em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'truncate')),
  0,
  'anon não tem privilégio TRUNCATE em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'references')),
  0,
  'anon não tem privilégio REFERENCES em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'trigger')),
  0,
  'anon não tem privilégio TRIGGER em nenhuma tabela de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p')
      and has_table_privilege('anon', c.oid, 'maintain')),
  0,
  'anon não tem privilégio MAINTAIN em nenhuma tabela de privado');

-- ── 3. As 9 tabelas sem RLS estão totalmente vedadas para authenticated ────────

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado'
      and c.relname in ('ambiente', 'auditoria_ciclo', 'conta_equipe', 'divergencia_reputacao',
                        'parametro_notificacao', 'termo_bloqueado', 'texto_da_vaga_ocultado',
                        'tipo_no_teto', 'vaga_ocultada')
      and (has_table_privilege('authenticated', c.oid, 'select')
           or has_table_privilege('authenticated', c.oid, 'insert')
           or has_table_privilege('authenticated', c.oid, 'update')
           or has_table_privilege('authenticated', c.oid, 'delete'))),
  0,
  'nenhuma das 9 tabelas sem RLS de privado concede select, insert, update ou delete a authenticated');

-- ── 4. Privilégios no próprio schema privado ───────────────────────────────────

select ok(
  has_schema_privilege('authenticated', 'privado', 'usage'),
  'authenticated possui USAGE no schema privado (necessario para RPCs)');

select ok(
  not has_schema_privilege('authenticated', 'privado', 'create'),
  'authenticated não possui privilégio CREATE no schema privado');

select ok(
  not has_schema_privilege('anon', 'privado', 'usage'),
  'anon não possui privilégio USAGE no schema privado');

select ok(
  not has_schema_privilege('anon', 'privado', 'create'),
  'anon não possui privilégio CREATE no schema privado');

select ok(
  not has_schema_privilege('public', 'privado', 'usage'),
  'public não possui privilégio USAGE no schema privado');

select ok(
  not has_schema_privilege('public', 'privado', 'create'),
  'public não possui privilégio CREATE no schema privado');

-- ── 5. Tabelas futuras criadas em privado não herdam privilégios indevidos ─────

create table privado.tabela_futura_teste (id int);

select ok(
  not has_table_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'select'),
  'tabela criada no futuro em privado não herda SELECT para authenticated');

select ok(
  not has_table_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'insert'),
  'tabela criada no futuro em privado não herda INSERT para authenticated');

select ok(
  not has_table_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'update'),
  'tabela criada no futuro em privado não herda UPDATE para authenticated');

select ok(
  not has_table_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'delete'),
  'tabela criada no futuro em privado não herda DELETE para authenticated');

select ok(
  not has_table_privilege('anon', 'privado.tabela_futura_teste'::regclass, 'select'),
  'tabela criada no futuro em privado não herda SELECT para anon');

drop table privado.tabela_futura_teste;

-- ── 6. Sensibilidade do teste a mutação (falha imediata se conceder) ───────────

grant select on privado.ambiente to authenticated;

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'ambiente'
      and has_table_privilege('authenticated', c.oid, 'select')),
  1,
  'mutação controlada: detector acusa imediatamente se GRANT for concedido a authenticated');

revoke select on privado.ambiente from authenticated;

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'ambiente'
      and has_table_privilege('authenticated', c.oid, 'select')),
  0,
  'privilégio em privado.ambiente retorna a zero após REVOKE');

select * from finish();
rollback;
