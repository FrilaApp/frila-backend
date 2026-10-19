-- 470_limite_de_escrita.sql
--
-- Cartão kT7NhMGV (RNF07, RN15): limite por conta nas escritas, com 429 limite_excedido.
--
-- O PostgREST chama `requisicao.conferir_limite()` antes de cada requisição (a opção
-- `pgrst.db_pre_request` do papel `authenticator`). A função conta as escritas de cada
-- conta autenticada numa janela de um minuto e, passado o teto, recusa com o código do
-- contrato. Leitura, anônimo e service_role não contam.
--
--   1. Estrutura: o esquema, a função, a tabela do contador e a opção do PostgREST.
--   2. Privilégios: a função é chamável por quem o PostgREST encarna; a tabela, por ninguém.
--   3. Regra: até o teto passa, o seguinte recebe 429 limite_excedido; outra conta e
--      outra janela começam do zero; GET, anônimo e service_role não contam.

begin;
select plan(25);

-- Chama a função como o PostgREST chamaria: com o papel, as claims e o método da
-- requisição. Devolve null quando passou, ou o `message` e o `detail` da recusa.
create function pg_temp.requisicao(conta uuid, papel text, metodo text) returns jsonb
language plpgsql as $$
declare
  v_msg text;
  v_detalhe text;
  v_estado text;
begin
  execute format('set local role %I', papel);
  if conta is not null then
    perform set_config('request.jwt.claims',
                       json_build_object('sub', conta, 'role', papel)::text, true);
  else
    perform set_config('request.jwt.claims', json_build_object('role', papel)::text, true);
  end if;
  perform set_config('request.method', metodo, true);
  perform set_config('request.path', '/rpc/qualquer', true);
  begin
    perform requisicao.conferir_limite();
  exception when others then
    get stacked diagnostics v_msg = message_text, v_detalhe = pg_exception_detail,
                            v_estado = returned_sqlstate;
    reset role;
    return jsonb_build_object('sqlstate', v_estado, 'message', v_msg::jsonb,
                              'detail', v_detalhe::jsonb);
  end;
  reset role;
  return null;
end $$;

-- Faz `n` escritas seguidas e devolve a primeira recusa, ou null se todas passaram.
create function pg_temp.escritas(conta uuid, n int) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  for i in 1..n loop
    r := pg_temp.requisicao(conta, 'authenticated', 'POST');
    if r is not null then return r; end if;
  end loop;
  return null;
end $$;

-- ── 1. Estrutura ────────────────────────────────────────────────────────────────

select has_schema('requisicao', 'o esquema requisicao existe');
select has_function('requisicao', 'conferir_limite', '{}'::name[],
  'requisicao.conferir_limite() existe');
select ok((select prosecdef from pg_proc where oid = 'requisicao.conferir_limite()'::regprocedure),
  'requisicao.conferir_limite é security definer');
select ok((select proconfig @> array['search_path=""']
             from pg_proc where oid = 'requisicao.conferir_limite()'::regprocedure),
  'requisicao.conferir_limite fixa search_path vazio');
select has_table('privado', 'escrita_por_conta', 'o contador mora em privado');
select ok((select relrowsecurity from pg_class where oid = 'privado.escrita_por_conta'::regclass),
  'privado.escrita_por_conta tem RLS ligado');
select is((select count(*)::int from pg_policies
            where schemaname = 'privado' and tablename = 'escrita_por_conta'), 0,
  'privado.escrita_por_conta não tem política nenhuma');
select ok(exists (
    select 1 from pg_db_role_setting s join pg_roles r on r.oid = s.setrole
     where r.rolname = 'authenticator'
       and 'pgrst.db_pre_request=requisicao.conferir_limite' = any (s.setconfig)),
  'o PostgREST chama requisicao.conferir_limite antes de cada requisição');
select throws_ok(
  $$ insert into privado.escrita_por_conta (usuario_id, janela, contagem)
     values ('c8000000-0000-4000-8000-0000000000ff', '2026-11-05 15:00+00', 0) $$,
  '23514', null,
  'contador sem escrita não existe: a linha nasce com 1 (escrita_por_conta_contagem_check)');
select is(privado.limite_de_escrita_por_minuto(), 60,
  'o teto é de 60 escritas por conta por minuto');

-- ── 2. Privilégios ──────────────────────────────────────────────────────────────

select ok(has_schema_privilege('anon', 'requisicao', 'usage')
          and has_schema_privilege('authenticated', 'requisicao', 'usage')
          and has_schema_privilege('service_role', 'requisicao', 'usage'),
  'anon, authenticated e service_role enxergam o esquema requisicao');
select ok(has_function_privilege('anon', 'requisicao.conferir_limite()', 'execute')
          and has_function_privilege('authenticated', 'requisicao.conferir_limite()', 'execute')
          and has_function_privilege('service_role', 'requisicao.conferir_limite()', 'execute'),
  'os três papéis que o PostgREST encarna executam a função');
select ok(not has_table_privilege('authenticated', 'privado.escrita_por_conta', 'select')
          and not has_table_privilege('anon', 'privado.escrita_por_conta', 'select'),
  'nenhum cliente lê o contador');
select ok(not has_function_privilege('authenticated', 'privado.limite_de_escrita_por_minuto()', 'execute')
          and not has_function_privilege('anon', 'privado.limite_de_escrita_por_minuto()', 'execute'),
  'o teto não é chamável por cliente');

-- ── 3. A regra ──────────────────────────────────────────────────────────────────
--
-- Prefixo `c8`:
--   c80001: Ana, que faz a rajada
--   c80002: Beto, que escreve no mesmo minuto
insert into privado.ambiente (id, eh_teste) values (true, true);
select set_config('frila.agora', '2026-11-05 15:00:10+00', true);

select is(pg_temp.escritas('c8000000-0000-4000-8000-000000000001', 60), null,
  'as 60 primeiras escritas da conta no minuto passam');

select is(pg_temp.escritas('c8000000-0000-4000-8000-000000000001', 1) -> 'sqlstate', '"PGRST"',
  'a 61ª escrita é recusada pelo envelope do PostgREST');
select is(pg_temp.escritas('c8000000-0000-4000-8000-000000000001', 1) -> 'message',
  '{"code": "limite_excedido", "message": "limite_excedido", "details": null, "hint": null}'::jsonb,
  'a recusa usa o código do contrato, limite_excedido');
select is(pg_temp.escritas('c8000000-0000-4000-8000-000000000001', 1) -> 'detail' -> 'status',
  '429',
  'a recusa sai como HTTP 429');

select is((select contagem from privado.escrita_por_conta
            where usuario_id = 'c8000000-0000-4000-8000-000000000001'), 60,
  'a recusa não soma no contador: a conta volta a escrever quando a janela vira');

select is(pg_temp.escritas('c8000000-0000-4000-8000-000000000002', 1), null,
  'outra conta no mesmo minuto não herda o limite');

select is(pg_temp.requisicao('c8000000-0000-4000-8000-000000000001', 'authenticated', 'GET'), null,
  'leitura por GET não conta nem é recusada');
select is(pg_temp.requisicao(null, 'anon', 'POST'), null,
  'requisição anônima não conta (o limite do Auth cuida dela)');
select is(pg_temp.requisicao(null, 'service_role', 'POST'), null,
  'service_role (Edge Functions e agendador) não conta');

select set_config('frila.agora', '2026-11-05 15:01:00+00', true);
select is(pg_temp.escritas('c8000000-0000-4000-8000-000000000001', 60), null,
  'no minuto seguinte a conta tem as 60 escritas de novo');
select is((select contagem from privado.escrita_por_conta
            where usuario_id = 'c8000000-0000-4000-8000-000000000001'), 60,
  'uma linha por conta: a janela nova reescreve a antiga');

select * from finish();
rollback;
