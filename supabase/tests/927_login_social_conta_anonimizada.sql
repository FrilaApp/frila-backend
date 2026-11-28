-- pgTAP: concluir_login_social recusa conta anonimizada (cartão 4Sq6Jrjx, LGPD/RF25).
--
-- A exclusão de conta roda privado.excluir_conta (anonimiza public.usuario) e só depois a Edge Function
-- apaga auth.users pela Admin API. Se esse segundo passo falhar, ou no intervalo entre os dois, a conta
-- anonimizada ainda tem a identidade Apple/Google em auth.identities. concluir_login_social
-- (20261125210000_login_social_apple_google.sql:282-285) tem de recusar com conta_anonimizada sem gravar
-- sessão nem consumir o id_token.
--
-- Controle: a conta ativa com a mesma forma (identidade válida, id_token inédito) conclui.

begin;
select plan(10);

-- Liga o enforcement só nesta transação (como o 902): sem ele, verificar_sessao_dispositivo_online aceita qualquer sessão.
update privado.config_auth
   set exigir_dispositivo_verificado = true,
       corte_sessoes_anteriores_em = '2026-01-01 00:00:00+00'::timestamptz
 where unica = true;

-- Duas contas sintéticas, cada uma com identidade Apple válida:
-- 927...01: será excluída pelo caminho real (privado.excluir_conta).
-- 927...02: controle, continua ativa.
insert into auth.users (id, email, encrypted_password, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
values
  ('92700000-0000-4000-8000-000000000001'::uuid, 'excluida-apple@frila.test', '', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('92700000-0000-4000-8000-000000000002'::uuid, 'ativa-apple@frila.test',    '', now(), now(), '{}'::jsonb, '{}'::jsonb);

insert into auth.identities (id, user_id, provider_id, identity_data, provider, created_at, updated_at)
values
  ('92700000-0000-4000-8000-000000000011'::uuid, '92700000-0000-4000-8000-000000000001'::uuid, 'apple-excluida-1', jsonb_build_object('sub', 'apple-excluida-1'), 'apple', now(), now()),
  ('92700000-0000-4000-8000-000000000012'::uuid, '92700000-0000-4000-8000-000000000002'::uuid, 'apple-ativa-1',    jsonb_build_object('sub', 'apple-ativa-1'),    'apple', now(), now());

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ('92700000-0000-4000-8000-000000000001'::uuid, 'profissional', 'Conta Excluída', '+5561999990001', 'excluida-apple@frila.test', '1990-01-01', '2026-09-22', now()),
  ('92700000-0000-4000-8000-000000000002'::uuid, 'profissional', 'Conta Ativa',    '+5561999990002', 'ativa-apple@frila.test',    '1990-01-01', '2026-09-22', now());

-- Exclusão pelo caminho real: anonimiza public.usuario e não toca em auth.identities.
select privado.excluir_conta('92700000-0000-4000-8000-000000000001'::uuid);

select is(
  (select estado::text from public.usuario where id = '92700000-0000-4000-8000-000000000001'::uuid),
  'anonimizada',
  'excluir_conta deixa a conta anonimizada'
);

select ok(
  exists (select 1 from auth.identities where user_id = '92700000-0000-4000-8000-000000000001'::uuid and provider = 'apple'),
  'a identidade Apple da conta excluída continua em auth.identities (o cenário que o bloqueio cobre)'
);

-- 1. Conta anonimizada com identidade válida e id_token inédito: recusa.
select is(
  privado.concluir_login_social(
    '92700000-0000-4000-8000-000000000001'::uuid,
    '92700000-0000-4000-8000-000000000101'::uuid,
    'apple',
    repeat('c', 64)
  ),
  jsonb_build_object('ok', false, 'motivo', 'conta_anonimizada'),
  'concluir_login_social recusa conta anonimizada com conta_anonimizada'
);

select ok(
  not exists (select 1 from privado.sessoes_verificadas where session_id = '92700000-0000-4000-8000-000000000101'::uuid),
  'a recusa não grava sessoes_verificadas para a conta anonimizada'
);

select ok(
  not exists (select 1 from privado.tokens_sociais_consumidos where token_hash = repeat('c', 64)),
  'a recusa não consome o id_token (nada gravado em tokens_sociais_consumidos)'
);

select is(
  privado.verificar_sessao_dispositivo_online('92700000-0000-4000-8000-000000000001'::uuid, '92700000-0000-4000-8000-000000000101'::uuid),
  false,
  'a sessão da conta anonimizada não fica verificada'
);

select is(
  (select count(*)::int from auth.identities where user_id = '92700000-0000-4000-8000-000000000001'::uuid),
  1,
  'a recusa não cria vínculo novo em auth.identities'
);

-- 2. Controle: a conta ativa com a mesma forma conclui.
select is(
  (privado.concluir_login_social(
    '92700000-0000-4000-8000-000000000002'::uuid,
    '92700000-0000-4000-8000-000000000102'::uuid,
    'apple',
    repeat('d', 64)
  ) ->> 'ok')::boolean,
  true,
  'controle: a conta ativa com identidade Apple válida conclui o login social'
);

select ok(
  exists (select 1 from privado.sessoes_verificadas where session_id = '92700000-0000-4000-8000-000000000102'::uuid),
  'controle: a sessão da conta ativa fica gravada em sessoes_verificadas'
);

select ok(
  exists (select 1 from privado.tokens_sociais_consumidos where token_hash = repeat('d', 64)),
  'controle: o id_token da conta ativa é consumido'
);

select * from finish();
rollback;
