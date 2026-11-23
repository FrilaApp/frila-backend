-- Disparo por pg_cron + pg_net de limpar-contas-orfas e expurgar-midias (bebr4VIE).
--
-- Cobre as duas funções de disparo, os dois jobs diários e a URL derivada do Vault. O POST é
-- pós-commit (pg_net), então o que se prova aqui é o pedido enfileirado: URL, cabeçalhos e a
-- ausência de chamada quando falta o segredo do agendador.

begin;
select plan(20);

-- Isola de segredos do ambiente e de pedidos anteriores.
delete from vault.secrets
 where name in ('limpar_contas_function_url', 'expurgar_midias_function_url', 'edge_function_url', 'agendador_secret');
delete from net.http_request_queue;

select has_function('privado', 'disparar_limpeza_contas_orfas', array[]::text[],
  'privado.disparar_limpeza_contas_orfas() existe');
select has_function('privado', 'disparar_expurgo_midias', array[]::text[],
  'privado.disparar_expurgo_midias() existe');

select ok(has_function_privilege('service_role', 'privado.disparar_limpeza_contas_orfas()', 'execute'),
  'service_role executa disparar_limpeza_contas_orfas');
select ok(not has_function_privilege('authenticated', 'privado.disparar_limpeza_contas_orfas()', 'execute'),
  'authenticated não executa disparar_limpeza_contas_orfas');
select ok(not has_function_privilege('anon', 'privado.disparar_limpeza_contas_orfas()', 'execute'),
  'anon não executa disparar_limpeza_contas_orfas');

select ok(has_function_privilege('service_role', 'privado.disparar_expurgo_midias()', 'execute'),
  'service_role executa disparar_expurgo_midias');
select ok(not has_function_privilege('authenticated', 'privado.disparar_expurgo_midias()', 'execute'),
  'authenticated não executa disparar_expurgo_midias');
select ok(not has_function_privilege('anon', 'privado.disparar_expurgo_midias()', 'execute'),
  'anon não executa disparar_expurgo_midias');

select ok(exists (select 1 from cron.job
                   where jobname = 'limpar_contas_orfas_diaria' and schedule = '45 6 * * *'
                     and command = 'select privado.disparar_limpeza_contas_orfas()' and active),
  'o job limpar_contas_orfas_diaria roda às 06:45 UTC');
select ok(exists (select 1 from cron.job
                   where jobname = 'expurgar_midias_diaria' and schedule = '0 7 * * *'
                     and command = 'select privado.disparar_expurgo_midias()' and active),
  'o job expurgar_midias_diaria roda às 07:00 UTC');

-- Sem segredo do agendador, não aborta e não envia.
set local frila.agendador_secret = '';
select is(privado.disparar_limpeza_contas_orfas(), null::bigint,
  'sem segredo do agendador, disparar_limpeza_contas_orfas devolve nulo em vez de abortar');
select is(privado.disparar_expurgo_midias(), null::bigint,
  'sem segredo do agendador, disparar_expurgo_midias devolve nulo em vez de abortar');

-- Com segredo e URL por GUC.
set local frila.agendador_secret = 'segredo-de-teste';
set local frila.limpar_contas_function_url = 'http://exemplo.invalido/functions/v1/limpar-contas-orfas';
set local frila.expurgar_midias_function_url = 'http://exemplo.invalido/functions/v1/expurgar-midias';

select privado.disparar_limpeza_contas_orfas();
select is((select url from net.http_request_queue order by id desc limit 1),
  'http://exemplo.invalido/functions/v1/limpar-contas-orfas',
  'a limpeza vai para a URL de limpar-contas-orfas');
select is((select headers->>'x-agendador-secret' from net.http_request_queue order by id desc limit 1),
  'segredo-de-teste', 'a limpeza leva x-agendador-secret');
select is((select headers->>'Authorization' from net.http_request_queue order by id desc limit 1),
  'Bearer segredo-de-teste', 'a limpeza leva o Bearer');

select privado.disparar_expurgo_midias();
select is((select url from net.http_request_queue order by id desc limit 1),
  'http://exemplo.invalido/functions/v1/expurgar-midias',
  'o expurgo vai para a URL de expurgar-midias');
select is((select headers->>'x-agendador-secret' from net.http_request_queue order by id desc limit 1),
  'segredo-de-teste', 'o expurgo leva x-agendador-secret');
select is((select headers->>'Authorization' from net.http_request_queue order by id desc limit 1),
  'Bearer segredo-de-teste', 'o expurgo leva o Bearer');

-- URL derivada de edge_function_url do Vault, sem GUC próprio.
set local frila.limpar_contas_function_url = '';
set local frila.expurgar_midias_function_url = '';
select vault.create_secret('https://ref.supabase.co/functions/v1/despachar', 'edge_function_url');

select privado.disparar_limpeza_contas_orfas();
select is((select url from net.http_request_queue order by id desc limit 1),
  'https://ref.supabase.co/functions/v1/limpar-contas-orfas',
  'sem segredo próprio, a URL da limpeza deriva de edge_function_url');

select privado.disparar_expurgo_midias();
select is((select url from net.http_request_queue order by id desc limit 1),
  'https://ref.supabase.co/functions/v1/expurgar-midias',
  'sem segredo próprio, a URL do expurgo deriva de edge_function_url');

select * from finish();
rollback;
