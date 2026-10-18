begin;
select plan(15);

insert into privado.ambiente (eh_teste) values (true)
on conflict do nothing;

-- 1. Estrutura e privilégios da função
select has_function(
  'privado',
  'reivindicar_lote_push',
  ARRAY['integer'],
  'privado.reivindicar_lote_push(int) existe'
);

select ok(
  has_function_privilege('service_role', 'privado.reivindicar_lote_push(integer)', 'EXECUTE'),
  'privado.reivindicar_lote_push(int) é executável por service_role'
);

select ok(
  not has_function_privilege('anon', 'privado.reivindicar_lote_push(integer)', 'EXECUTE'),
  'privado.reivindicar_lote_push(int) NÃO é executável por anon'
);

select ok(
  not has_function_privilege('authenticated', 'privado.reivindicar_lote_push(integer)', 'EXECUTE'),
  'privado.reivindicar_lote_push(int) NÃO é executável por authenticated'
);

-- 2. Prepara usuário e 3 notificações pendentes
insert into auth.users (
  instance_id, id, aud, role, email, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous
) values (
  '00000000-0000-0000-0000-000000000000',
  'f0000000-0000-4000-8000-000000000747',
  'authenticated', 'authenticated', 'push_lock@teste.com', now(),
  '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
) on conflict do nothing;

insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em
) values (
  'f0000000-0000-4000-8000-000000000747',
  'profissional', 'Push Lock', '+5561999990747',
  'push_lock@teste.com', '1992-05-10'::date, '2026-09-22', privado.agora()
) on conflict do nothing;

-- Limpa notificações pendentes anteriores do teste se houver
delete from public.notificacao where usuario_id = 'f0000000-0000-4000-8000-000000000747';

insert into public.notificacao (
  id, usuario_id, tipo, referencia_id, payload,
  tentativas, estado_entrega, proxima_tentativa_em, enviada_em
) values
  ('74700000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000747', 'suspensao', gen_random_uuid(), '{}'::jsonb, 0, 'pendente', null, privado.agora() - interval '30 seconds'),
  ('74700000-0000-4000-8000-000000000002', 'f0000000-0000-4000-8000-000000000747', 'suspensao', gen_random_uuid(), '{}'::jsonb, 0, 'pendente', null, privado.agora() - interval '20 seconds'),
  ('74700000-0000-4000-8000-000000000003', 'f0000000-0000-4000-8000-000000000747', 'suspensao', gen_random_uuid(), '{}'::jsonb, 0, 'pendente', null, privado.agora() - interval '10 seconds');

-- 3. Primeira chamada de lote: reivindica até 2 notificações
create temp table lote1 as
select * from privado.reivindicar_lote_push(2);

select is(
  (select count(*)::int from lote1),
  2,
  'Primeira reivindicação retorna exatamente 2 notificações do lote'
);

select is(
  (select count(*)::int from public.notificacao
    where id in ('74700000-0000-4000-8000-000000000001', '74700000-0000-4000-8000-000000000002')
      and proxima_tentativa_em > privado.agora()),
  2,
  'Notificações reivindicadas tiveram proxima_tentativa_em avançado (visibility timeout)'
);

-- Validação estrita de colunas e tipos do RETURNS TABLE
select is(
  (select tipo from lote1 where id = '74700000-0000-4000-8000-000000000001'),
  'suspensao'::public.tipo_notificacao,
  'Coluna tipo retornada preserva o tipo enum public.tipo_notificacao'
);

select is(
  (select estado_entrega from lote1 where id = '74700000-0000-4000-8000-000000000001'),
  'pendente'::public.estado_entrega,
  'Coluna estado_entrega retornada preserva o tipo enum public.estado_entrega'
);

select is(
  (select usuario_id from lote1 where id = '74700000-0000-4000-8000-000000000001'),
  'f0000000-0000-4000-8000-000000000747'::uuid,
  'Coluna usuario_id retornada corresponde ao uuid correto'
);

select is(
  (select urgente from lote1 where id = '74700000-0000-4000-8000-000000000001'),
  false,
  'Coluna urgente retornada corresponde ao boolean esperado'
);

select ok(
  (select proxima_tentativa_em from lote1 where id = '74700000-0000-4000-8000-000000000001') > privado.agora(),
  'Coluna proxima_tentativa_em retornada reflete o visibility timeout aplicado'
);

-- 4. Segunda chamada concorrente/imediata: deve ignorar as 2 reivindicadas e retornar apenas a 3ª restante
create temp table lote2 as
select * from privado.reivindicar_lote_push(2);

select is(
  (select count(*)::int from lote2),
  1,
  'Segunda reivindicação com SKIP LOCKED ignora as em processamento e retorna a 3ª restante'
);

select is(
  (select id from lote2),
  '74700000-0000-4000-8000-000000000003'::uuid,
  'A notificação retornada no segundo lote é estritamente a 3ª notificação pendente'
);

-- 5. Terceira chamada: todas as 3 estão em voo (visibility timeout ativo), retorna 0
select is(
  (select count(*)::int from privado.reivindicar_lote_push(2)),
  0,
  'Terceira reivindicação retorna 0 porque todas as notificações da fila já foram reivindicadas'
);

-- 6. Gravação de aceite libera notificação para enviada
perform privado.gravar_aceite_push('74700000-0000-4000-8000-000000000001');

select is(
  (select estado_entrega from public.notificacao where id = '74700000-0000-4000-8000-000000000001'),
  'enviada'::public.estado_entrega,
  'Após entrega pelo FCM, gravar_aceite_push define estado_entrega como enviada'
);

select finish();
rollback;
