-- 893_disparar_email_fallback.sql
--
-- Cobertura de testes pgTAP para privado.disparar_email() e fallback de URLs (B-083).
--
-- Afere:
--   1. Estrutura, catálogo e controle de privilégios estrito (service_role permitida,
--      anon/authenticated/public proibidos, SECURITY DEFINER e search_path="" fixados);
--   2. Precedência de resolução de URL:
--      (a) email_function_url no Vault tem precedência máxima;
--      (b) na ausência de email_function_url no Vault, parâmetro GUC frila.email_function_url
--          vence o fallback derivado;
--      (c) na ausência de Vault email e GUC, edge_function_url terminando em '/despachar'
--          deriva a URL substituindo por '/enviar-email';
--      (d) edge_function_url que NÃO termina em '/despachar' é ignorada, caindo no padrão local;
--      (e) sem nenhuma configuração no Vault ou GUC, cai no padrão local;
--   3. Comportamento defensivo com fila vazia: retorna null sem enfileirar requisição;
--   4. Comportamento defensivo com segredo ausente: retorna null sem quebrar transação nem enfileirar requisição.

begin;

select plan(30);

-- ── 1. Privilégios e catálogo ────────────────────────────────────────────────

select has_function(
  'privado',
  'disparar_email',
  array[]::text[],
  'privado.disparar_email() existe no schema privado'
);

select function_returns(
  'privado',
  'disparar_email',
  array[]::text[],
  'bigint',
  'privado.disparar_email() retorna bigint'
);

select function_lang_is(
  'privado',
  'disparar_email',
  array[]::text[],
  'plpgsql',
  'privado.disparar_email() é em plpgsql'
);

select is_definer(
  'privado',
  'disparar_email',
  array[]::text[],
  'privado.disparar_email() é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc
    where proname = 'disparar_email' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'privado.disparar_email() opera com search_path="" fixado'
);

select is(
  has_function_privilege('anon', 'privado.disparar_email()', 'execute'),
  false,
  'anon NÃO tem permissão de execute em privado.disparar_email()'
);

select is(
  has_function_privilege('authenticated', 'privado.disparar_email()', 'execute'),
  false,
  'authenticated NÃO tem permissão de execute em privado.disparar_email()'
);

select is(
  has_function_privilege('public', 'privado.disparar_email()', 'execute'),
  false,
  'public NÃO tem permissão de execute em privado.disparar_email()'
);

select is(
  has_function_privilege('service_role', 'privado.disparar_email()', 'execute'),
  true,
  'service_role pode executar privado.disparar_email()'
);

-- ── 2. Cenários de resolução de URL ──────────────────────────────────────────

-- Configura segredo do agendador para os testes de disparo
set local frila.agendador_secret = 'segredo-de-teste';

-- (a) email_function_url no Vault vence tudo
delete from vault.secrets where name in ('email_function_url', 'edge_function_url');
delete from pgmq.q_email;
delete from net.http_request_queue;

select vault.create_secret('https://vault-email.frila.test/functions/v1/enviar-email', 'email_function_url');
select vault.create_secret('https://vault-edge.frila.test/functions/v1/despachar', 'edge_function_url');
set local frila.email_function_url = 'https://guc-email.frila.test/functions/v1/enviar-email';

select lives_ok(
  $$ select pgmq.send('email', '{"teste": "cenario_a"}'::jsonb) $$,
  'cenário (a): send executa com sucesso'
);

select is(
  (select count(*)::int from net.http_request_queue),
  1,
  'cenário (a): gera exatamente 1 requisição em net.http_request_queue'
);

select is(
  (select url from net.http_request_queue order by id desc limit 1),
  'https://vault-email.frila.test/functions/v1/enviar-email',
  'cenário (a): email_function_url no Vault vence todas as outras opções'
);

-- (b) sem Vault de e-mail, o GUC vence o derivado
delete from vault.secrets where name = 'email_function_url';
delete from pgmq.q_email;
delete from net.http_request_queue;

select lives_ok(
  $$ select pgmq.send('email', '{"teste": "cenario_b"}'::jsonb) $$,
  'cenário (b): send executa com sucesso'
);

select is(
  (select count(*)::int from net.http_request_queue),
  1,
  'cenário (b): gera exatamente 1 requisição em net.http_request_queue'
);

select is(
  (select url from net.http_request_queue order by id desc limit 1),
  'https://guc-email.frila.test/functions/v1/enviar-email',
  'cenário (b): sem Vault de email, GUC vence edge_function_url derivada'
);

-- (c) só edge_function_url terminando em '/despachar' -> deriva com '/enviar-email'
delete from vault.secrets where name in ('email_function_url', 'edge_function_url');
delete from pgmq.q_email;
delete from net.http_request_queue;
set local frila.email_function_url = '';

select vault.create_secret('https://vault-edge.frila.test/functions/v1/despachar', 'edge_function_url');

select lives_ok(
  $$ select pgmq.send('email', '{"teste": "cenario_c"}'::jsonb) $$,
  'cenário (c): send executa com sucesso'
);

select is(
  (select count(*)::int from net.http_request_queue),
  1,
  'cenário (c): gera exatamente 1 requisição em net.http_request_queue'
);

select is(
  (select url from net.http_request_queue order by id desc limit 1),
  'https://vault-edge.frila.test/functions/v1/enviar-email',
  'cenário (c): edge_function_url com /despachar deriva corretamente para /enviar-email'
);

-- (d) edge_function_url SEM '/despachar' no fim é ignorada -> URL = padrão local
delete from vault.secrets where name in ('email_function_url', 'edge_function_url');
delete from pgmq.q_email;
delete from net.http_request_queue;
set local frila.email_function_url = '';

select vault.create_secret('https://vault-edge.frila.test/functions/v1/outro-endpoint', 'edge_function_url');

select lives_ok(
  $$ select pgmq.send('email', '{"teste": "cenario_d"}'::jsonb) $$,
  'cenário (d): send executa com sucesso'
);

select is(
  (select count(*)::int from net.http_request_queue),
  1,
  'cenário (d): gera exatamente 1 requisição em net.http_request_queue'
);

select is(
  (select url from net.http_request_queue order by id desc limit 1),
  'http://127.0.0.1:54321/functions/v1/enviar-email',
  'cenário (d): edge_function_url sem /despachar é ignorada e chamada usa endereço local padrão'
);

-- (e) nada configurado -> padrão local
delete from vault.secrets where name in ('email_function_url', 'edge_function_url');
delete from pgmq.q_email;
delete from net.http_request_queue;
set local frila.email_function_url = '';

select lives_ok(
  $$ select pgmq.send('email', '{"teste": "cenario_e"}'::jsonb) $$,
  'cenário (e): send executa com sucesso'
);

select is(
  (select count(*)::int from net.http_request_queue),
  1,
  'cenário (e): gera exatamente 1 requisição em net.http_request_queue'
);

select is(
  (select url from net.http_request_queue order by id desc limit 1),
  'http://127.0.0.1:54321/functions/v1/enviar-email',
  'cenário (e): sem Vault e sem GUC, chamada usa endereço local padrão'
);

-- ── 3. Fila vazia ────────────────────────────────────────────────────────────

-- (f) fila vazia -> devolve null e NENHUMA requisição
delete from pgmq.q_email;
delete from net.http_request_queue;
set local frila.agendador_secret = 'segredo-de-teste';

select is(
  privado.disparar_email(),
  null::bigint,
  'cenário (f): fila vazia retorna null'
);

select is(
  (select count(*)::int from net.http_request_queue),
  0,
  'cenário (f): fila vazia não enfileira requisição HTTP'
);

-- ── 4. Segredo ausente ───────────────────────────────────────────────────────

-- (g) segredo do agendador ausente -> null, nenhuma requisição
delete from pgmq.q_email;
delete from net.http_request_queue;
delete from vault.secrets where name = 'agendador_secret';
set local frila.agendador_secret = '';

select lives_ok(
  $$ select pgmq.send('email', '{"teste": "cenario_g"}'::jsonb) $$,
  'cenário (g): send com segredo ausente executa sem quebrar transação'
);

select is(
  (select count(*)::int from net.http_request_queue),
  0,
  'cenário (g): sem segredo, gatilho não enfileira requisição HTTP'
);

select is(
  privado.disparar_email(),
  null::bigint,
  'cenário (g): disparar_email() direto com segredo ausente retorna null'
);

select is(
  (select count(*)::int from net.http_request_queue),
  0,
  'cenário (g): continua sem requisição HTTP enfileirada'
);

rollback;
