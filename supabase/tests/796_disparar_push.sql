-- `disparar_push`: o agendador que faltava no Prod (hQDlvpHi).
--
-- Cobre a função, o gatilho por comando e o job de um minuto. O POST em si é pós-commit
-- (pg_net), então o que se prova aqui é o pedido enfileirado: URL, cabeçalhos e a ausência
-- de chamada quando não há o que enviar.

begin;
select plan(13);

insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000795', 'authenticated', 'authenticated',
  'push_agendador@teste.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
on conflict do nothing;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('f0000000-0000-4000-8000-000000000795', 'profissional', 'Push Agendador', '+5561999990795', 'push_agendador@teste.com', '1992-05-10'::date,
  '2026-09-22', privado.agora())
on conflict do nothing;

-- Isola de pendentes residuais e de segredos do ambiente.
update public.notificacao set estado_entrega = 'enviada' where estado_entrega = 'pendente';
set local frila.agendador_secret = 'segredo-de-teste';
set local frila.push_function_url = 'http://exemplo.invalido/functions/v1/enviar-push';
delete from net.http_request_queue;

select has_function('privado', 'disparar_push', array[]::text[], 'privado.disparar_push() existe');

select ok(not has_function_privilege('authenticated', 'privado.disparar_push()', 'execute'),
  'authenticated não executa disparar_push');

select ok(not has_function_privilege('anon', 'privado.disparar_push()', 'execute'),
  'anon não executa disparar_push');

select is(privado.disparar_push(), null::bigint,
  'sem notificação pendente, não acorda a Edge Function');

select is((select count(*)::int from net.http_request_queue), 0,
  'sem notificação pendente, nenhum pedido fica na fila do pg_net');

insert into public.notificacao (id, usuario_id, tipo, referencia_id, payload, estado_entrega, proxima_tentativa_em, enviada_em)
values ('79500000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000795', 'suspensao', gen_random_uuid(), '{}'::jsonb, 'pendente', null, privado.agora());

select is((select count(*)::int from net.http_request_queue), 1,
  'o INSERT em notificacao acorda a Edge Function (gatilho pós-insert)');

select is((select url from net.http_request_queue limit 1), 'http://exemplo.invalido/functions/v1/enviar-push',
  'o pedido vai para a URL de enviar-push');

select is((select (headers->>'x-agendador-secret') from net.http_request_queue limit 1), 'segredo-de-teste',
  'o pedido leva x-agendador-secret');

select is((select (headers->>'Authorization') from net.http_request_queue limit 1), 'Bearer segredo-de-teste',
  'o pedido leva o Bearer');

select is((select tgtype & 1 from pg_trigger where tgname = 'trg_notificacao_disparar_push' and tgrelid = 'public.notificacao'::regclass), 0,
  'o gatilho é por comando (statement), e não por linha');

-- Fila elegível só com backoff no futuro: não acorda.
update public.notificacao set proxima_tentativa_em = privado.agora() + interval '1 hour' where estado_entrega = 'pendente';
delete from net.http_request_queue;
select privado.disparar_push();
select is((select count(*)::int from net.http_request_queue), 0,
  'pendente com backoff no futuro não acorda a Edge Function');

-- Sem segredo, não aborta e não envia.
update public.notificacao set proxima_tentativa_em = null where estado_entrega = 'pendente';
set local frila.agendador_secret = '';
select is(privado.disparar_push(), null::bigint,
  'sem segredo do agendador, devolve nulo em vez de abortar');

select ok(exists (select 1 from cron.job where jobname = 'processar_fila_push' and schedule = '* * * * *'
                     and command = 'select privado.disparar_push()' and active),
  'o job processar_fila_push roda a cada minuto');

select * from finish();
rollback;
