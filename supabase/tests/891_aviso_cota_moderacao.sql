-- 891_aviso_cota_moderacao.sql
--
-- Aviso de cota mensal da moderação de mídia (cartão yPhXgTCY). A reserva da chamada ao provedor
-- passa a ser a função privado.reservar_chamada_moderacao, que decide, na mesma transação e sob a mesma
-- trava, se esta reserva deve avisar que o consumo chegou a 80% do teto. A marca
-- (provedor, mes, limiar) em privado.moderacao_aviso_cota é o que impede o segundo aviso.
-- Cobre:
--   1. Estrutura e privilégios: só o service_role executa a função; a tabela de marcas não tem acesso direto;
--   2. Abaixo do limiar não avisa; ao chegar nele avisa uma vez; acima e no teto não repete;
--   3. O teto reduzido no meio do mês (10 para 5, consumo 4) avisa uma vez (achado do ANBU Genma no #577);
--   4. Devolver a reserva e cruzar de novo não repete o aviso (a marca é persistente);
--   5. Mês novo e provedor novo têm marca própria; o limiar arredonda para cima;
--   6. O limite por foto e o teto zero continuam valendo e não gravam marca.
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
select plan(35);

create temp table ids as
select 'c8910000-0000-4000-8000-000000000001'::uuid as usuario;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select usuario, 'profissional'::public.perfil_conta, 'Conta 891', '+556199998910', 'c891@test.invalid',
       '1990-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids;

-- 40 mídias removidas: a chamada a cada uma delas conta uma vez no limite por foto, e 'removida' não
-- entra no índice de foto única por dono.
create function pg_temp.m(n integer) returns uuid language sql immutable as
$$ select ('c8910000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid $$;

insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
select pg_temp.m(n), (select usuario from ids), 'profissional', 'foto_perfil',
       'perfil/891-' || n || '.jpg', 'image/jpeg', 1000, 'removida'
  from generate_series(1, 40) n;

-- Consumo já feito no mês, cada linha numa mídia diferente do intervalo 21..40 (a chamada testada usa 1..20).
create function pg_temp.gastar(p_provedor text, p_mes text, p_quantas integer) returns void language sql as
$$ insert into privado.moderacao_chamada (midia_id, provedor, mes)
   select pg_temp.m(21 + (n % 20)), p_provedor, p_mes from generate_series(1, p_quantas) n $$;

create function pg_temp.reservar(p_midia integer, p_provedor text, p_mes text, p_teto integer, p_max integer default 1)
returns text language sql as
$$ select resultado || '/' || consumo_mes || '/' || avisar_cota
     from privado.reservar_chamada_moderacao(pg_temp.m(p_midia), p_provedor, p_mes, p_teto, p_max) $$;

-- 1. Estrutura e privilégios
select has_table('privado', 'moderacao_aviso_cota', 'a tabela de marcas existe');
select col_is_pk('privado', 'moderacao_aviso_cota', array['provedor', 'mes', 'limiar_percentual'],
  'a marca é única por provedor, mês e limiar');
select ok(not has_table_privilege('service_role', 'privado.moderacao_aviso_cota', 'select'),
  'service_role não lê a tabela de marcas direto');
select ok(not has_table_privilege('authenticated', 'privado.moderacao_aviso_cota', 'insert'),
  'authenticated não escreve na tabela de marcas');
select ok(has_function_privilege('service_role',
  'privado.reservar_chamada_moderacao(uuid,text,text,integer,integer,integer)', 'execute'),
  'service_role executa a reserva');
select ok(not has_function_privilege('authenticated',
  'privado.reservar_chamada_moderacao(uuid,text,text,integer,integer,integer)', 'execute'),
  'authenticated não executa a reserva');
select ok(not has_function_privilege('anon',
  'privado.reservar_chamada_moderacao(uuid,text,text,integer,integer,integer)', 'execute'),
  'anon não executa a reserva');
select is((select prosecdef from pg_proc where oid = 'privado.reservar_chamada_moderacao(uuid,text,text,integer,integer,integer)'::regprocedure),
  true, 'a reserva é security definer');
select ok((select proconfig from pg_proc where oid = 'privado.reservar_chamada_moderacao(uuid,text,text,integer,integer,integer)'::regprocedure)
  @> array['search_path=""'], 'a reserva fixa search_path vazio');

-- 2. Teto 10, limiar 8: abaixo não avisa; em 8 avisa; depois não repete; no teto continua o bloqueio
select pg_temp.gastar('azure', '2026-11', 6);
select is(pg_temp.reservar(1, 'azure', '2026-11', 10), 'ok/7/false', 'abaixo de 80% (7 de 10) não avisa');
select is(pg_temp.reservar(2, 'azure', '2026-11', 10), 'ok/8/true', 'em 80% (8 de 10) avisa');
select is(pg_temp.reservar(3, 'azure', '2026-11', 10), 'ok/9/false', 'acima de 80% (9 de 10) não repete');
select is(pg_temp.reservar(4, 'azure', '2026-11', 10), 'ok/10/false', 'a última chamada permitida (10 de 10) não repete');
select is(pg_temp.reservar(5, 'azure', '2026-11', 10), 'teto_mensal/10/false', 'no teto a reserva é recusada e não avisa');
select is((select count(*)::int from privado.moderacao_aviso_cota where provedor = 'azure' and mes = '2026-11' and limiar_percentual = 80),
  1, 'uma única marca gravada para azure em 2026-11');
select is((select count(*)::int from privado.moderacao_chamada where provedor = 'azure' and mes = '2026-11'),
  10, 'a chamada recusada no teto não consome cota');

-- 3. Teto reduzido no meio do mês: 10 para 5 com consumo 4 (achado do Genma)
select pg_temp.gastar('openai', '2026-11', 3);
select is(pg_temp.reservar(6, 'openai', '2026-11', 10), 'ok/4/false', 'teto 10, consumo 4: ainda não avisa');
select is(pg_temp.reservar(7, 'openai', '2026-11', 5), 'ok/5/true',
  'teto reduzido para 5: o pedido que chega a 5 de 5 avisa, mesmo sem igualdade exata com o limiar 4');
select is(pg_temp.reservar(8, 'openai', '2026-11', 5), 'teto_mensal/5/false', 'e o seguinte já encontra o teto, sem novo aviso de 80%');

-- 3b. Teto reduzido para um valor que o consumo já passou: o primeiro pedido que ainda reserva avisa
select pg_temp.gastar('baixo', '2026-11', 7);
select is(pg_temp.reservar(9, 'baixo', '2026-11', 12), 'ok/8/false', 'teto 12 (limiar 10), consumo 8: não avisa');
select is(pg_temp.reservar(10, 'baixo', '2026-11', 9), 'ok/9/true',
  'teto reduzido para 9 (limiar 8), consumo já em 8: o próximo pedido avisa uma vez');
select is(pg_temp.reservar(11, 'baixo', '2026-11', 20), 'ok/10/false', 'e o teto voltando a subir não repete');

-- 4. Devolver a reserva e cruzar de novo não repete (a marca persiste)
select pg_temp.gastar('mock', '2026-11', 7);
select is(pg_temp.reservar(12, 'mock', '2026-11', 10), 'ok/8/true', 'mock em 8 de 10 avisa');
delete from privado.moderacao_chamada
 where id = (select max(id) from privado.moderacao_chamada where provedor = 'mock' and mes = '2026-11');
select is(pg_temp.reservar(13, 'mock', '2026-11', 10), 'ok/8/false', 'cruzar o 80% de novo depois de devolver a reserva não avisa outra vez');

-- 5. Mês novo e provedor novo têm marca própria; o limiar arredonda para cima
select pg_temp.gastar('azure', '2026-12', 7);
select is(pg_temp.reservar(14, 'azure', '2026-12', 10), 'ok/8/true', 'o mês novo zera a conta e o aviso volta a valer');
select pg_temp.gastar('azure2', '2026-11', 5);
select is(pg_temp.reservar(15, 'azure2', '2026-11', 7), 'ok/6/true', 'teto 7: limiar é 6 (5,6 sobe para 6)');
select is(pg_temp.reservar(16, 'azure3', '2026-11', 1), 'ok/1/true', 'teto 1: a única chamada permitida avisa');

-- 6. Limite por foto e teto zero continuam valendo e não gravam marca
select is(pg_temp.reservar(17, 'foto', '2026-11', 100), 'ok/1/false', 'primeira chamada da foto');
select is(pg_temp.reservar(17, 'foto', '2026-11', 100), 'limite_foto/1/false', 'a segunda chamada da mesma foto bate no limite por foto');
select is(pg_temp.reservar(18, 'zero', '2026-11', 0), 'teto_mensal/0/false', 'teto zero bloqueia sem avisar');
select is((select count(*)::int from privado.moderacao_aviso_cota where provedor in ('foto', 'zero')),
  0, 'limite por foto e teto zero não gravam marca');

-- 7. O limiar fora de 1..100 não passa
select throws_ok(
  $$ select * from privado.reservar_chamada_moderacao(pg_temp.m(19), 'invalido', '2026-11', 10, 1, 0) $$,
  '22023', 'limiar_invalido', 'limiar 0% é recusado na entrada');
select throws_ok(
  $$ select * from privado.reservar_chamada_moderacao(pg_temp.m(19), 'invalido', '2026-11', 10, 1, 101) $$,
  '22023', 'limiar_invalido', 'limiar 101% é recusado na entrada');
select throws_ok(
  $$ select * from privado.reservar_chamada_moderacao(pg_temp.m(19), 'invalido', '2026-11', 10, 1, -1) $$,
  '22023', 'limiar_invalido', 'limiar -1% é recusado na entrada');

select throws_ok(
  $$ select * from privado.reservar_chamada_moderacao(pg_temp.m(19), 'nulo', '2026-11', null, 1) $$,
  '22004', 'parametro_nulo', 'teto nulo falha fechado, sem reservar');

select * from finish();
rollback;
