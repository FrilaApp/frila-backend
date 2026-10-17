begin;
select plan(12);

-- Teste 741: Segurança do schema `net` (extensão pg_net) contra acesso de anon e authenticated
-- Achado do Item 0e / 10c: os cabeçalhos de requisição em net.http_request_queue contêm
-- frila.agendador_secret e Bearer token. anon e authenticated NÃO podem ter USAGE no schema net,
-- NÃO podem ter SELECT/ALL nas tabelas de net e NÃO podem executar net.http_post / net.http_get.

-- 1 a 4. Verificação de privilégios de schema
select ok(
  not has_schema_privilege('anon', 'net', 'USAGE'),
  'anon nao tem USAGE no schema net'
);

select ok(
  not has_schema_privilege('authenticated', 'net', 'USAGE'),
  'authenticated nao tem USAGE no schema net'
);

select ok(
  not has_schema_privilege('anon', 'net', 'CREATE'),
  'anon nao tem CREATE no schema net'
);

select ok(
  not has_schema_privilege('authenticated', 'net', 'CREATE'),
  'authenticated nao tem CREATE no schema net'
);

-- 5 e 6. Verificação dinâmica em todas as tabelas do schema net
select is(
  (select count(*) from information_schema.tables t
    where t.table_schema = 'net'
      and (has_table_privilege('anon', format('%I.%I', t.table_schema, t.table_name), 'SELECT')
        or has_table_privilege('anon', format('%I.%I', t.table_schema, t.table_name), 'INSERT'))),
  0::bigint,
  'nenhuma tabela de net permite SELECT ou INSERT para anon'
);

select is(
  (select count(*) from information_schema.tables t
    where t.table_schema = 'net'
      and (has_table_privilege('authenticated', format('%I.%I', t.table_schema, t.table_name), 'SELECT')
        or has_table_privilege('authenticated', format('%I.%I', t.table_schema, t.table_name), 'INSERT'))),
  0::bigint,
  'nenhuma tabela de net permite SELECT ou INSERT para authenticated'
);

-- 7 e 8. Verificação dinâmica em todas as rotinas do schema net
select is(
  (select count(*) from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'net'
     and has_function_privilege('anon', p.oid, 'EXECUTE')),
  0::bigint,
  'nenhuma rotina de net permite EXECUTE para anon'
);

select is(
  (select count(*) from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'net'
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  0::bigint,
  'nenhuma rotina de net permite EXECUTE para authenticated'
);

-- 9 e 10. Prova prática com SET ROLE anon
select throws_matching(
  $$
    set local role anon;
    select * from net.http_request_queue;
  $$,
  'permission denied|insufficient_privilege|permiss|42501',
  'anon recebe permission denied ao tentar ler net.http_request_queue'
);

select throws_matching(
  $$
    set local role anon;
    select net.http_post(url := 'http://localhost/teste', body := '{}'::jsonb);
  $$,
  'permission denied|insufficient_privilege|permiss|42501',
  'anon recebe permission denied ao tentar executar net.http_post'
);

-- 11 e 12. Prova prática com SET ROLE authenticated
select throws_matching(
  $$
    set local role authenticated;
    select * from net.http_request_queue;
  $$,
  'permission denied|insufficient_privilege|permiss|42501',
  'authenticated recebe permission denied ao tentar ler net.http_request_queue'
);

select throws_matching(
  $$
    set local role authenticated;
    select net.http_post(url := 'http://localhost/teste', body := '{}'::jsonb);
  $$,
  'permission denied|insufficient_privilege|permiss|42501',
  'authenticated recebe permission denied ao tentar executar net.http_post'
);

select * from finish();
rollback;
