-- Privilégios mínimos nas tabelas, visões e sequências do schema privado (defesa em profundidade).
--
-- Validação da auditoria de segurança da develop (16/10, Oráculo):
-- O schema `privado` contém tabelas internas de infraestrutura, ciclo, controle e
-- moderação sem RLS ativada (ambiente, auditoria_ciclo, conta_equipe, divergencia_reputacao,
-- parametro_notificacao, termo_bloqueado, texto_da_vaga_ocultado, tipo_no_teto, vaga_ocultada, etc.).
--
-- A segurança dessas tabelas depende de:
-- 1. O schema `privado` não ser exposto na API do PostgREST (somente `public` e `graphql_public`);
-- 2. Revogação de acesso a `public` e `anon`;
-- 3. Inexistência absoluta de privilégios de tabela (em nível de relação ou de coluna)
--    concedidos ao papel `authenticated` ou `anon`, mesmo que `authenticated` possua USAGE
--    no schema para execução de RPCs/funções internas;
-- 4. Inexistência de privilégios em sequências ou visões de `privado`.
--
-- Este teste garante que:
-- - Nenhuma tabela, visão ou tabela estrangeira em `privado` concede privilégios a `authenticated` ou `anon`
--   (incluindo checagem estrita de colunas via has_any_column_privilege);
-- - Nenhuma sequência em `privado` concede USAGE/SELECT/UPDATE a `authenticated` ou `anon`;
-- - As 9 tabelas sem RLS do relatório existem comprovadamente e estão totalmente vedadas;
-- - Tabelas futuras criadas pelo papel postgres em `privado` não herdam privilégios indevidos;
-- - `authenticated` tem USAGE estrito em `privado` (sem CREATE); `anon` e `public` não têm nem USAGE nem CREATE;
-- - O detector acusa imediatamente qualquer concessão indevida (em nível de tabela ou coluna).

begin;
select plan(35);

-- ── 1. Relações em privado não concedem privilégios a authenticated ────────────

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and (has_table_privilege('authenticated', c.oid, 'select')
           or has_any_column_privilege('authenticated', c.oid, 'select'))),
  0,
  'authenticated não tem privilégio SELECT (tabela ou coluna) em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and (has_table_privilege('authenticated', c.oid, 'insert')
           or has_any_column_privilege('authenticated', c.oid, 'insert'))),
  0,
  'authenticated não tem privilégio INSERT (tabela ou coluna) em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and (has_table_privilege('authenticated', c.oid, 'update')
           or has_any_column_privilege('authenticated', c.oid, 'update'))),
  0,
  'authenticated não tem privilégio UPDATE (tabela ou coluna) em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and has_table_privilege('authenticated', c.oid, 'delete')),
  0,
  'authenticated não tem privilégio DELETE em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and has_table_privilege('authenticated', c.oid, 'truncate')),
  0,
  'authenticated não tem privilégio TRUNCATE em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and (has_table_privilege('authenticated', c.oid, 'references')
           or has_any_column_privilege('authenticated', c.oid, 'references'))),
  0,
  'authenticated não tem privilégio REFERENCES (tabela ou coluna) em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and has_table_privilege('authenticated', c.oid, 'trigger')),
  0,
  'authenticated não tem privilégio TRIGGER em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and has_table_privilege('authenticated', c.oid, 'maintain')),
  0,
  'authenticated não tem privilégio MAINTAIN em nenhuma relação de privado');

-- ── 2. Relações em privado não concedem privilégios a anon ─────────────────────

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and (has_table_privilege('anon', c.oid, 'select')
           or has_any_column_privilege('anon', c.oid, 'select'))),
  0,
  'anon não tem privilégio SELECT (tabela ou coluna) em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and (has_table_privilege('anon', c.oid, 'insert')
           or has_any_column_privilege('anon', c.oid, 'insert'))),
  0,
  'anon não tem privilégio INSERT (tabela ou coluna) em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and (has_table_privilege('anon', c.oid, 'update')
           or has_any_column_privilege('anon', c.oid, 'update'))),
  0,
  'anon não tem privilégio UPDATE (tabela ou coluna) em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and has_table_privilege('anon', c.oid, 'delete')),
  0,
  'anon não tem privilégio DELETE em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and has_table_privilege('anon', c.oid, 'truncate')),
  0,
  'anon não tem privilégio TRUNCATE em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and (has_table_privilege('anon', c.oid, 'references')
           or has_any_column_privilege('anon', c.oid, 'references'))),
  0,
  'anon não tem privilégio REFERENCES (tabela ou coluna) em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and has_table_privilege('anon', c.oid, 'trigger')),
  0,
  'anon não tem privilégio TRIGGER em nenhuma relação de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p', 'v', 'm', 'f')
      and has_table_privilege('anon', c.oid, 'maintain')),
  0,
  'anon não tem privilégio MAINTAIN em nenhuma relação de privado');

-- ── 3. Sequências em privado não concedem privilégios a authenticated ou anon ──

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind = 'S'
      and (has_sequence_privilege('authenticated', c.oid, 'usage')
           or has_sequence_privilege('authenticated', c.oid, 'select')
           or has_sequence_privilege('authenticated', c.oid, 'update'))),
  0,
  'authenticated não tem privilégio (USAGE, SELECT, UPDATE) em nenhuma sequência de privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind = 'S'
      and (has_sequence_privilege('anon', c.oid, 'usage')
           or has_sequence_privilege('anon', c.oid, 'select')
           or has_sequence_privilege('anon', c.oid, 'update'))),
  0,
  'anon não tem privilégio (USAGE, SELECT, UPDATE) em nenhuma sequência de privado');

-- ── 4. As 9 tabelas sem RLS existem e estão totalmente vedadas ─────────────────

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado'
      and c.relname in ('ambiente', 'auditoria_ciclo', 'conta_equipe', 'divergencia_reputacao',
                        'parametro_notificacao', 'termo_bloqueado', 'texto_da_vaga_ocultado',
                        'tipo_no_teto', 'vaga_ocultada')),
  9,
  'todas as 9 tabelas sem RLS do achado da auditoria existem no schema privado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado'
      and c.relname in ('ambiente', 'auditoria_ciclo', 'conta_equipe', 'divergencia_reputacao',
                        'parametro_notificacao', 'termo_bloqueado', 'texto_da_vaga_ocultado',
                        'tipo_no_teto', 'vaga_ocultada')
      and (has_table_privilege('authenticated', c.oid, 'select')
           or has_any_column_privilege('authenticated', c.oid, 'select')
           or has_table_privilege('authenticated', c.oid, 'insert')
           or has_any_column_privilege('authenticated', c.oid, 'insert')
           or has_table_privilege('authenticated', c.oid, 'update')
           or has_any_column_privilege('authenticated', c.oid, 'update')
           or has_table_privilege('authenticated', c.oid, 'delete'))),
  0,
  'nenhuma das 9 tabelas sem RLS de privado concede select, insert, update ou delete a authenticated');

-- ── 5. Privilégios no próprio schema privado ───────────────────────────────────

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

-- ── 6. Tabelas futuras criadas pelo papel postgres não herdam privilégios ──────

create table privado.tabela_futura_teste (id int);

select ok(
  not (has_table_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'select')
       or has_any_column_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'select')),
  'tabela criada no futuro em privado por postgres não herda SELECT para authenticated');

select ok(
  not (has_table_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'insert')
       or has_any_column_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'insert')),
  'tabela criada no futuro em privado por postgres não herda INSERT para authenticated');

select ok(
  not (has_table_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'update')
       or has_any_column_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'update')),
  'tabela criada no futuro em privado por postgres não herda UPDATE para authenticated');

select ok(
  not has_table_privilege('authenticated', 'privado.tabela_futura_teste'::regclass, 'delete'),
  'tabela criada no futuro em privado por postgres não herda DELETE para authenticated');

select ok(
  not (has_table_privilege('anon', 'privado.tabela_futura_teste'::regclass, 'select')
       or has_any_column_privilege('anon', 'privado.tabela_futura_teste'::regclass, 'select')),
  'tabela criada no futuro em privado por postgres não herda SELECT para anon');

drop table privado.tabela_futura_teste;

-- ── 7. Sensibilidade do teste a mutação (tabela inteira e coluna) ──────────────

-- 7.1 Mutação em nível de tabela inteira
grant select on privado.ambiente to authenticated;

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'ambiente'
      and has_table_privilege('authenticated', c.oid, 'select')),
  1,
  'mutação tabela: detector acusa imediatamente se GRANT SELECT for concedido na tabela inteira');

revoke select on privado.ambiente from authenticated;

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'ambiente'
      and has_table_privilege('authenticated', c.oid, 'select')),
  0,
  'privilégio de tabela em privado.ambiente retorna a zero após REVOKE');

-- 7.2 Mutação em nível de coluna específica (has_any_column_privilege)
grant select (eh_teste) on privado.ambiente to authenticated;

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'ambiente'
      and has_any_column_privilege('authenticated', c.oid, 'select')),
  1,
  'mutação coluna: detector acusa imediatamente se GRANT SELECT for concedido em coluna especifica');

revoke select (eh_teste) on privado.ambiente from authenticated;

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'ambiente'
      and has_any_column_privilege('authenticated', c.oid, 'select')),
  0,
  'privilégio de coluna em privado.ambiente retorna a zero após REVOKE');

select * from finish();
rollback;
