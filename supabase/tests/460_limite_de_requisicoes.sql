-- 460_limite_de_requisicoes.sql
-- Limite de requisições de escrita por conta (RNF07). Cartão kT7NhMGV.
--
-- O que este arquivo NÃO prova: que o PostgREST chama `privado.limitar_requisicoes` antes
-- de cada requisição. Isso é configuração do PostgREST e só aparece por HTTP — está no
-- `./scripts/limite-de-requisicoes.sh`, que mede a rajada de verdade. Aqui fica o que
-- sobrevive dentro do banco: a decisão, o parâmetro, a janela e o privilégio.

begin;
select plan(19);

-- ── 1. A estrutura ─────────────────────────────────────────────────────────────
select has_table('privado', 'limite_requisicao', 'privado.limite_requisicao existe');
select has_table('privado', 'contador_requisicao', 'privado.contador_requisicao existe');

select is(
  (select count(*)::int from privado.limite_requisicao where escopo = 'escrita'),
  1,
  'O parâmetro do escopo escrita está semeado');

select ok(
  (select teto from privado.limite_requisicao where escopo = 'escrita') > 0
  and (select janela from privado.limite_requisicao where escopo = 'escrita') > interval '0',
  'RNF07: o teto e a janela são positivos');

-- RN15: o contador conta, e não guarda o que foi pedido. Uma coluna a mais aqui — caminho,
-- corpo, IP — seria registro de tráfego com dado pessoal, que é o que a regra proíbe.
select set_eq(
  $$select column_name::text from information_schema.columns
     where table_schema = 'privado' and table_name = 'contador_requisicao'$$,
  array['usuario_id', 'escopo', 'janela_em', 'contagem'],
  'RN15: o contador tem só conta, escopo, janela e contagem — nada do que foi pedido');

select ok(
  (select relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relname = 'contador_requisicao'),
  'RLS ligada em privado.contador_requisicao');

-- ── 2. O privilégio ────────────────────────────────────────────────────────────
select ok(
  not has_function_privilege('anon', 'privado.limitar_requisicoes()', 'execute'),
  'privado.limitar_requisicoes não é executável por anon');

select ok(
  has_function_privilege('authenticated', 'privado.limitar_requisicoes()', 'execute'),
  'privado.limitar_requisicoes é executável por authenticated, que é quem o PostgREST usa');

select is(
  (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'limitar_requisicoes'),
  true,
  'privado.limitar_requisicoes é security definer');

-- ── 2b. As restrições, uma asserção por CHECK ──────────────────────────────────
-- O mutacao.sh derruba cada CHECK e exige que a suíte fique vermelha. Sem estas três, um
-- teto zero, uma janela de duração nula ou uma contagem negativa entrariam sem ninguém
-- reclamar — e teto zero recusaria a primeira escrita de toda conta.

select throws_ok(
  $$insert into privado.limite_requisicao (escopo, teto, janela, descricao)
    values ('teste_teto_zero', 0, interval '1 minute', 'x')$$,
  '23514',
  null,
  'teto_positivo: teto zero é recusado');

select throws_ok(
  $$insert into privado.limite_requisicao (escopo, teto, janela, descricao)
    values ('teste_janela_zero', 10, interval '0', 'x')$$,
  '23514',
  null,
  'janela_positiva: janela de duração nula é recusada');

select throws_ok(
  $$insert into privado.contador_requisicao (usuario_id, escopo, janela_em, contagem)
    values ('e0000000-0000-4000-8000-000000000001', 'escrita', privado.agora(), -1)$$,
  '23514',
  null,
  'contagem_positiva: contagem negativa é recusada');

-- ── 3. A decisão, exercida sem HTTP ────────────────────────────────────────────
-- Simula o que o PostgREST põe no ambiente e chama a função, uma vez por requisição.
create function pg_temp.requisitar(p_uid uuid, p_metodo text, p_caminho text)
returns text language plpgsql as $$
begin
  perform set_config('request.method', p_metodo, true);
  perform set_config('request.path', p_caminho, true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform privado.limitar_requisicoes();
  return 'ok';
exception when others then
  return sqlerrm;
end $$;

-- Teto baixo, para o teste não precisar de 60 chamadas.
update privado.limite_requisicao set teto = 3 where escopo = 'escrita';

select is(pg_temp.requisitar('e0000000-0000-4000-8000-000000000001', 'POST', '/rpc/candidatar'),
          'ok', 'A 1ª escrita passa');
select is(pg_temp.requisitar('e0000000-0000-4000-8000-000000000001', 'POST', '/rpc/candidatar'),
          'ok', 'A 2ª escrita passa');
select is(pg_temp.requisitar('e0000000-0000-4000-8000-000000000001', 'POST', '/rpc/candidatar'),
          'ok', 'A 3ª escrita passa, no teto');

select ok(
  pg_temp.requisitar('e0000000-0000-4000-8000-000000000001', 'POST', '/rpc/candidatar')
    like '%limite_excedido%',
  'RNF07: a 4ª escrita, acima do teto, recusa com limite_excedido');

-- Outra conta não herda o teto da primeira: o limite é por conta, não global.
select is(pg_temp.requisitar('e0000000-0000-4000-8000-000000000002', 'POST', '/rpc/candidatar'),
          'ok', 'A conta vizinha continua escrevendo: o teto é por conta');

-- Leitura não gasta o teto. GET é como o PostgREST chama função stable, e toda leitura
-- aqui é stable — é o que o lint-conhecido.sh cobra.
select is(pg_temp.requisitar('e0000000-0000-4000-8000-000000000002', 'GET', '/rpc/vagas_abertas'),
          'ok', 'Leitura por GET não conta no teto de escrita');

-- A janela fecha e o teto recomeça: sem isto, a conta ficaria recusada para sempre.
update privado.contador_requisicao
   set janela_em = janela_em - interval '1 hour'
 where usuario_id = 'e0000000-0000-4000-8000-000000000001';

select is(pg_temp.requisitar('e0000000-0000-4000-8000-000000000001', 'POST', '/rpc/candidatar'),
          'ok', 'Passada a janela, a mesma conta volta a escrever');

select * from finish();
rollback;
