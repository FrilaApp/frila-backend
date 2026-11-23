-- 897_disparar_email_sufixo_e_header_new01.sql · NEW-01
--
-- Prova:
--   1. Fallback derivado de edge_function_url substitui APENAS o sufixo '/despachar' por '/enviar-email',
--      preservando ocorrências anteriores de '/despachar' no host ou prefixo do caminho.
--   2. Cabeçalhos enviados por privado.disparar_email() contêm Content-Type e x-agendador-secret,
--      e NÃO contêm o cabeçalho redundante Authorization (removido após o #587 / BE-03).
--   3. Segurança: SECURITY DEFINER, search_path="" e execução restrita a service_role.
begin;

select plan(7);

set local frila.agendador_secret = 'segredo-new01-teste';
set local frila.email_function_url = '';
delete from vault.secrets where name in ('email_function_url', 'edge_function_url', 'agendador_secret');
delete from pgmq.q_email;
delete from net.http_request_queue;

-- URL com '/despachar' tanto no caminho intermediário quanto no sufixo final
select vault.create_secret(
  'https://despachar.frila.test/despachar/functions/v1/despachar',
  'edge_function_url'
);

select lives_ok(
  $$ select pgmq.send('email', '{"teste": "new01_sufixo"}'::jsonb) $$,
  '1. pgmq.send dispara privado.disparar_email() sem erro'
);

select is(
  (select url from net.http_request_queue order by id desc limit 1),
  'https://despachar.frila.test/despachar/functions/v1/enviar-email',
  '2. fallback substitui apenas o sufixo /despachar, preservando ocorrências anteriores na URL'
);

select is(
  (select headers->>'x-agendador-secret' from net.http_request_queue order by id desc limit 1),
  'segredo-new01-teste',
  '3. cabeçalho x-agendador-secret é enviado com o segredo configurado'
);

select is(
  (select headers->>'Content-Type' from net.http_request_queue order by id desc limit 1),
  'application/json',
  '4. cabeçalho Content-Type é application/json'
);

select is(
  (select headers ? 'Authorization' from net.http_request_queue order by id desc limit 1),
  false,
  '5. cabeçalho Authorization redundante não está presente na requisição'
);

select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
     from pg_proc p
    where p.oid = 'privado.disparar_email()'::regprocedure),
  '6. privado.disparar_email() mantém SECURITY DEFINER e search_path=""'
);

select ok(
  has_function_privilege('service_role', 'privado.disparar_email()', 'execute')
  and not has_function_privilege('authenticated', 'privado.disparar_email()', 'execute')
  and not has_function_privilege('anon', 'privado.disparar_email()', 'execute'),
  '7. privado.disparar_email() restrita a service_role'
);

select * from finish();
rollback;
