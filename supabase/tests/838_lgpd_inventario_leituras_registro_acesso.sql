-- 838_lgpd_inventario_leituras_registro_acesso.sql · B-T2c, filho do LGPD-J6 R11 (migração 20261109130000).
-- Decreto 8.771/2016, art. 13, III: toda leitura de privado.registro_acesso passa por privado.ler_registros_acesso,
-- que grava no inventário o momento, a duração, quem leu e o "arquivo acessado" (mais o motivo, decisão nossa).
-- Nenhum papel de API lê direto o registro, a deduplicação, o inventário nem o slot lógico.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-09 12:00:00+00', true);
select plan(45);

delete from privado.registro_acesso;
delete from privado.registro_acesso_leitura;

-- Lê pela função com o papel pedido (o SET ROLE do PostgREST, aqui à mão).
create function pg_temp.ler_como(papel text, conta uuid, desde timestamptz, ate timestamptz, resp text, motivo text)
returns table (usuario_id uuid, ip text, acessado_em timestamptz) language plpgsql as $$
begin
  execute format('set local role %I', papel);
  return query select l.usuario_id, host(l.ip), l.acessado_em
                 from privado.ler_registros_acesso(conta, desde, ate, resp, motivo) l;
  reset role;
end $$;
-- 'ok', o "status code" de public.erro, ou o SQLSTATE de qualquer outro erro.
create function pg_temp.recusa(papel text, sql text) returns text language plpgsql as $$
declare m text; d text; s text;
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text, d = pg_exception_detail, s = returned_sqlstate;
  reset role;
  return case when s = 'PGRST' then concat_ws(' ', d::jsonb->>'status', m::jsonb->>'code') else s end;
end $$;
create function pg_temp.inventario() returns integer language sql as $$
  select count(*)::int from privado.registro_acesso_leitura $$;

-- ─── 1. Ninguém da API toca direto: registro, deduplicação e inventário ───
select ok(not has_table_privilege('anon', 'privado.registro_acesso', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'),
  'anon não lê nem escreve direto em privado.registro_acesso');
select ok(not has_table_privilege('authenticated', 'privado.registro_acesso', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'),
  'authenticated não lê nem escreve direto em privado.registro_acesso');
select ok(not has_table_privilege('service_role', 'privado.registro_acesso', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'),
  'service_role não lê nem escreve direto em privado.registro_acesso (a leitura é só pela função)');
select ok(not has_table_privilege('anon', 'privado.registro_acesso_recente', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'),
  'anon não lê privado.registro_acesso_recente');
select ok(not has_table_privilege('authenticated', 'privado.registro_acesso_recente', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'),
  'authenticated não lê privado.registro_acesso_recente');
select ok(not has_table_privilege('service_role', 'privado.registro_acesso_recente', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'),
  'service_role não lê privado.registro_acesso_recente');
select ok(not has_table_privilege('anon', 'privado.registro_acesso_leitura', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'),
  'anon não lê nem escreve no inventário');
select ok(not has_table_privilege('authenticated', 'privado.registro_acesso_leitura', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'),
  'authenticated não lê nem escreve no inventário');
select ok(not has_table_privilege('service_role', 'privado.registro_acesso_leitura', 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE'),
  'service_role não lê nem escreve no inventário: só a função escreve');
-- O catálogo diz; a consulta prova.
select is(pg_temp.recusa('service_role', 'select 1 from privado.registro_acesso'), '42501',
  'service_role que tenta ler o registro direto leva 42501');
select is(pg_temp.recusa('service_role', 'select 1 from privado.registro_acesso_recente'), '42501',
  'service_role que tenta ler a deduplicação direto leva 42501');
select is(pg_temp.recusa('service_role', 'insert into privado.registro_acesso_leitura (papel_sessao, responsavel, arquivo, conta, desde, ate, motivo, linhas, inicio, fim) values (''x'', ''x'', ''privado.registro_acesso'', gen_random_uuid(), now(), now() + interval ''1 h'', ''x'', 0, now(), now())'),
  '42501', 'service_role não forja linha no inventário');

-- ─── 2. Nem o slot lógico ───
select ok(not exists (select 1 from pg_catalog.pg_roles
                       where rolname in ('anon', 'authenticated', 'service_role') and (rolsuper or rolreplication)),
  'nenhum papel de API é superusuário nem tem REPLICATION');
select is(pg_temp.recusa('service_role', $$ select * from pg_logical_slot_peek_changes('frila_registro_acesso', null, 1) $$),
  '42501', 'service_role não espia o slot lógico (pg_logical_slot_peek_changes)');
select is(pg_temp.recusa('service_role', $$ select * from pg_logical_slot_get_changes('frila_registro_acesso', null, 1) $$),
  '42501', 'service_role não consome o slot lógico (pg_logical_slot_get_changes)');

-- ─── 3. Quem chama a função (art. 13, I) ───
select ok(has_function_privilege('service_role', 'privado.ler_registros_acesso(uuid, timestamptz, timestamptz, text, text)', 'EXECUTE'),
  'service_role executa privado.ler_registros_acesso');
select ok(not has_function_privilege('anon', 'privado.ler_registros_acesso(uuid, timestamptz, timestamptz, text, text)', 'EXECUTE')
      and not has_function_privilege('authenticated', 'privado.ler_registros_acesso(uuid, timestamptz, timestamptz, text, text)', 'EXECUTE'),
  'anon e authenticated não executam privado.ler_registros_acesso');
select ok(not coalesce((select bool_or(a.grantee = 0) from pg_catalog.pg_proc p, aclexplode(p.proacl) a
                         where p.oid = 'privado.ler_registros_acesso(uuid, timestamptz, timestamptz, text, text)'::regprocedure
                           and a.privilege_type = 'EXECUTE'), true),
  'PUBLIC não executa privado.ler_registros_acesso');
select is(pg_temp.recusa('authenticated', $$ select * from privado.ler_registros_acesso(gen_random_uuid(), now(), now() + interval '1 h', 'cauecarneiro', 'teste') $$),
  '42501', 'authenticated que chama a função leva 42501');
select is((select p.prosecdef::text || ' ' || array_to_string(p.proconfig, ',') from pg_catalog.pg_proc p
            where p.oid = 'privado.ler_registros_acesso(uuid, timestamptz, timestamptz, text, text)'::regprocedure),
  'true search_path=""', 'a função é security definer com search_path vazio');

-- ─── 4. O inventário guarda referência e motivo, nunca cópia (RN15) ───
select columns_are('privado', 'registro_acesso_leitura',
  array['id', 'papel_sessao', 'papel_chamada', 'responsavel', 'arquivo', 'conta', 'desde', 'ate', 'motivo',
        'linhas', 'inicio', 'fim'],
  'o inventário não tem IP nem data do acesso lido: guarda referência, não cópia');

-- ─── 5. A leitura devolve só a conta no período e grava 1 linha no inventário ───
insert into privado.registro_acesso (usuario_id, ip, acessado_em) values
  ('c8380000-0000-4000-8000-0000000000a1', '203.0.113.10', '2026-10-31 23:59:59+00'),  -- antes do período
  ('c8380000-0000-4000-8000-0000000000a1', '203.0.113.11', '2026-11-01 10:00:00+00'),
  ('c8380000-0000-4000-8000-0000000000a1', '203.0.113.12', '2026-11-01 11:30:00+00'),
  ('c8380000-0000-4000-8000-0000000000a1', '203.0.113.13', '2026-11-01 12:00:00+00'),  -- o fim é exclusivo
  ('c8380000-0000-4000-8000-0000000000b2', '203.0.113.20', '2026-11-01 11:00:00+00');  -- outra conta

select results_eq(
  $$ select usuario_id::text, ip, acessado_em from pg_temp.ler_como('service_role', 'c8380000-0000-4000-8000-0000000000a1',
       '2026-11-01 00:00:00+00', '2026-11-01 12:00:00+00', 'cauecarneiro', 'Ofício 123/2026') $$,
  $$ values ('c8380000-0000-4000-8000-0000000000a1', '203.0.113.11', '2026-11-01 10:00:00+00'::timestamptz),
            ('c8380000-0000-4000-8000-0000000000a1', '203.0.113.12', '2026-11-01 11:30:00+00'::timestamptz) $$,
  'a leitura devolve só as linhas da conta no período [desde, ate), em ordem');
select is(pg_temp.inventario(), 1, 'a leitura grava exatamente 1 linha no inventário');
select results_eq(
  $$ select papel_sessao, papel_chamada, responsavel, arquivo, conta::text, desde, ate, motivo, linhas
       from privado.registro_acesso_leitura $$,
  $$ values (session_user::text, 'service_role'::text, 'cauecarneiro'::text, 'privado.registro_acesso'::text,
             'c8380000-0000-4000-8000-0000000000a1'::text, '2026-11-01 00:00:00+00'::timestamptz,
             '2026-11-01 12:00:00+00'::timestamptz, 'Ofício 123/2026'::text, 2) $$,
  'o inventário guarda o papel da sessão e o da chamada, o responsável, o arquivo acessado, a conta, o período, o motivo e quantas linhas');
select ok((select inicio > now() and fim >= inicio from privado.registro_acesso_leitura),
  'início e fim vêm do relógio real (clock_timestamp), não do começo da transação, e o fim não vem antes do início');

-- ─── 6. Leitura vazia também fica no inventário ───
select is_empty(
  $$ select * from pg_temp.ler_como('service_role', 'c8380000-0000-4000-8000-0000000000a1',
       '2026-12-01 00:00:00+00', '2026-12-02 00:00:00+00', '  cauecarneiro  ', 'Apuração de fraude, chamado 42') $$,
  'leitura num período sem registros volta vazia');
select results_eq(
  $$ select count(*)::int, max(responsavel) from privado.registro_acesso_leitura where linhas = 0 $$,
  $$ values (1, 'cauecarneiro'::text) $$,
  'a leitura vazia ganha a linha dela no inventário, com o responsável sem espaços nas pontas');

-- ─── 7. Sem quem, sem por quê, sem conta ou sem período: recusa sem ler e sem inventário ───
create function pg_temp.chamada(conta text, desde text, ate text, resp text, motivo text) returns text language sql as $$
  select format('select * from privado.ler_registros_acesso(%s::uuid, %s::timestamptz, %s::timestamptz, %s, %s)',
                coalesce(quote_literal(conta), 'null'), coalesce(quote_literal(desde), 'null'),
                coalesce(quote_literal(ate), 'null'), coalesce(quote_literal(resp), 'null'),
                coalesce(quote_literal(motivo), 'null')) $$;

select is(pg_temp.recusa('service_role', pg_temp.chamada('c8380000-0000-4000-8000-0000000000a1', '2026-11-01', '2026-11-02', null, 'Ofício 1')),
  '422 responsavel_obrigatorio', 'sem responsável: 422 responsavel_obrigatorio');
select is(pg_temp.recusa('service_role', pg_temp.chamada('c8380000-0000-4000-8000-0000000000a1', '2026-11-01', '2026-11-02', '   ', 'Ofício 1')),
  '422 responsavel_obrigatorio', 'responsável em branco: 422 responsavel_obrigatorio');
select is(pg_temp.recusa('service_role', pg_temp.chamada('c8380000-0000-4000-8000-0000000000a1', '2026-11-01', '2026-11-02', 'Service_Role', 'Ofício 1')),
  '422 responsavel_invalido', 'responsável com nome de papel do banco: 422 responsavel_invalido (a pessoa, não a conta técnica)');
select is(pg_temp.recusa('service_role', pg_temp.chamada('c8380000-0000-4000-8000-0000000000a1', '2026-11-01', '2026-11-02', repeat('x', 81), 'Ofício 1')),
  '422 responsavel_invalido', 'responsável acima de 80 caracteres: 422 responsavel_invalido');
select is(pg_temp.recusa('service_role', pg_temp.chamada('c8380000-0000-4000-8000-0000000000a1', '2026-11-01', '2026-11-02', 'cauecarneiro', ' ')),
  '422 motivo_obrigatorio', 'sem motivo: 422 motivo_obrigatorio');
select is(pg_temp.recusa('service_role', pg_temp.chamada('c8380000-0000-4000-8000-0000000000a1', '2026-11-01', '2026-11-02', 'cauecarneiro', repeat('x', 201))),
  '422 motivo_invalido', 'motivo acima de 200 caracteres: 422 motivo_invalido (a referência, não o conteúdo)');
select is(pg_temp.recusa('service_role', pg_temp.chamada(null, '2026-11-01', '2026-11-02', 'cauecarneiro', 'Ofício 1')),
  '422 conta_obrigatoria', 'sem conta: 422 conta_obrigatoria');
select is(pg_temp.recusa('service_role', pg_temp.chamada('c8380000-0000-4000-8000-0000000000a1', '2026-11-02', '2026-11-02', 'cauecarneiro', 'Ofício 1')),
  '422 periodo_invalido', 'fim igual ao início: 422 periodo_invalido');
select is(pg_temp.recusa('service_role', pg_temp.chamada('c8380000-0000-4000-8000-0000000000a1', null, '2026-11-02', 'cauecarneiro', 'Ofício 1')),
  '422 periodo_invalido', 'sem início: 422 periodo_invalido');
select is(pg_temp.inventario(), 2, 'nenhuma recusa gravou linha no inventário');

-- ─── 8. A limpeza do inventário: 5 anos contados do fim da leitura, com piso ───
insert into privado.registro_acesso_leitura (papel_sessao, responsavel, arquivo, conta, desde, ate, motivo, linhas, inicio, fim) values
  ('postgres', 'zz838_velha', 'privado.registro_acesso', 'c8380000-0000-4000-8000-0000000000a1',
   '2021-01-01', '2021-01-02', 'Ofício antigo', 1, '2021-11-08 11:59:00+00', '2021-11-08 11:59:59+00'),
  ('postgres', 'zz838_recente', 'privado.registro_acesso', 'c8380000-0000-4000-8000-0000000000a1',
   '2021-01-01', '2021-01-02', 'Ofício antigo', 1, '2021-11-09 12:00:01+00', '2021-11-09 12:00:01+00');
select is(privado.limpar_inventario_leituras_registro_acesso(1), 1,
  'a limpeza apaga só a leitura que terminou há mais de 5 anos, mesmo pedindo 1 ano (piso de 5)');
select results_eq(
  $$ select responsavel from privado.registro_acesso_leitura where responsavel like 'zz838%' $$,
  $$ values ('zz838_recente'::text) $$,
  'a leitura com menos de 5 anos fica no inventário');

-- ─── 9. Um teste por CHECK do inventário, com o nome da regra ───
create function pg_temp.linha(resp text default 'cauecarneiro', arq text default 'privado.registro_acesso',
                              mot text default 'Ofício 1', lin integer default 0,
                              de text default '2026-11-01', a text default '2026-11-02',
                              ini text default '2026-11-09 10:00', fi text default '2026-11-09 10:00:01') returns text
language sql as $$
  select format('insert into privado.registro_acesso_leitura (papel_sessao, responsavel, arquivo, conta, desde, ate, motivo, linhas, inicio, fim) values (''postgres'', %L, %L, gen_random_uuid(), %L, %L, %L, %s, %L, %L)',
                resp, arq, de, a, mot, lin, ini, fi) $$;
select throws_ok(pg_temp.linha(resp => ' cauecarneiro'), '23514', null,
  'registro_acesso_leitura_responsavel: o responsável é gravado sem espaços nas pontas e com até 80 caracteres');
select throws_ok(pg_temp.linha(arq => 'privado.registro_acesso_recente'), '23514', null,
  'registro_acesso_leitura_arquivo: o arquivo acessado é privado.registro_acesso');
select throws_ok(pg_temp.linha(mot => repeat('x', 201)), '23514', null,
  'registro_acesso_leitura_motivo: o motivo tem de 1 a 200 caracteres, sem espaços nas pontas');
select throws_ok(pg_temp.linha(lin => -1), '23514', null,
  'registro_acesso_leitura_linhas: a contagem de linhas lidas não é negativa');
select throws_ok(pg_temp.linha(de => '2026-11-02', a => '2026-11-02'), '23514', null,
  'registro_acesso_leitura_periodo: o fim do período vem depois do início');
select throws_ok(pg_temp.linha(ini => '2026-11-09 10:00:01', fi => '2026-11-09 10:00'), '23514', null,
  'registro_acesso_leitura_duracao: o fim da leitura não vem antes do início');

select * from finish();
rollback;
