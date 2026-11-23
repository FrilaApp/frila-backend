-- `expirar_notificacoes_pendentes_antigas`: o acúmulo legado não sai em massa (hQDlvpHi).
--
-- No Prod nenhum job chamava `enviar-push` e 54 notificações ficaram pendentes. Antes do
-- agendador ligar, as antigas viram `falhou` com motivo `expirada_sem_agendador`; as recentes
-- seguem na fila. `estado_entrega` não tem `expirada`, por isso `falhou`.

begin;
select plan(11);

insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'f0000000-0000-4000-8000-000000000794', 'authenticated', 'authenticated',
  'push_legado@teste.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
on conflict do nothing;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('f0000000-0000-4000-8000-000000000794', 'profissional', 'Push Legado', '+5561999990794', 'push_legado@teste.com', '1992-05-10'::date,
  '2026-09-22', privado.agora())
on conflict do nothing;

-- Isola o resultado de pendentes residuais de outros testes.
update public.notificacao set estado_entrega = 'enviada' where estado_entrega = 'pendente';

insert into public.notificacao (id, usuario_id, tipo, referencia_id, payload, tentativas, estado_entrega, proxima_tentativa_em, enviada_em)
values
  ('79400000-0000-4000-8000-000000000001', 'f0000000-0000-4000-8000-000000000794', 'suspensao', gen_random_uuid(), '{}'::jsonb, 0, 'pendente', null, privado.agora() - interval '3 hours'),
  ('79400000-0000-4000-8000-000000000002', 'f0000000-0000-4000-8000-000000000794', 'suspensao', gen_random_uuid(), '{}'::jsonb, 0, 'pendente', null, privado.agora() - interval '10 minutes'),
  ('79400000-0000-4000-8000-000000000003', 'f0000000-0000-4000-8000-000000000794', 'suspensao', gen_random_uuid(), '{}'::jsonb, 0, 'enviada',  null, privado.agora() - interval '3 hours'),
  ('79400000-0000-4000-8000-000000000004', 'f0000000-0000-4000-8000-000000000794', 'suspensao', gen_random_uuid(), '{}'::jsonb, 1, 'pendente', privado.agora() + interval '5 minutes', privado.agora() - interval '2 days');

select has_function('privado', 'expirar_notificacoes_pendentes_antigas', array['interval'],
  'privado.expirar_notificacoes_pendentes_antigas(interval) existe');

select ok(not has_function_privilege('authenticated', 'privado.expirar_notificacoes_pendentes_antigas(interval)', 'execute'),
  'authenticated não executa a expiração');

select ok(not has_function_privilege('anon', 'privado.expirar_notificacoes_pendentes_antigas(interval)', 'execute'),
  'anon não executa a expiração');

select is(privado.expirar_notificacoes_pendentes_antigas(), 2,
  'expira as duas pendentes com mais de 1 hora (a de 3 h e a de 2 dias, mesmo com lease no futuro)');

select is((select estado_entrega::text from public.notificacao where id = '79400000-0000-4000-8000-000000000001'), 'falhou',
  'a pendente antiga vira falhou');

select is((select motivo_falha from public.notificacao where id = '79400000-0000-4000-8000-000000000001'), 'expirada_sem_agendador',
  'o motivo deixa o caso separável de falha de envio');

select is((select proxima_tentativa_em from public.notificacao where id = '79400000-0000-4000-8000-000000000004'), null::timestamptz,
  'a expirada sai da fila: proxima_tentativa_em fica nula');

select is((select estado_entrega::text from public.notificacao where id = '79400000-0000-4000-8000-000000000002'), 'pendente',
  'a pendente de 10 minutos segue na fila');

select is((select estado_entrega::text from public.notificacao where id = '79400000-0000-4000-8000-000000000003'), 'enviada',
  'a já enviada não é tocada');

select is(privado.expirar_notificacoes_pendentes_antigas(), 0,
  'chamar de novo não expira nada: idempotente');

select is(privado.expirar_notificacoes_pendentes_antigas(interval '1 minute'), 1,
  'com idade menor, a pendente de 10 minutos também expira');

select * from finish();
rollback;
