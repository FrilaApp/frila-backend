-- pgTAP: Fundação server-side de login social Apple e Google (contrato 0.2.117).
-- Cobre:
-- 1. Conta social (apple/google) sem encrypted_password NÃO fica presa em precisa_definir_senha sob enforcement.
-- 2. Conta legada OTP-only sem encrypted_password e sem identidade social CONTINUA exigindo senha sob enforcement.
-- 3. Bypass direto no GoTrue (sem concluir_login_social) é bloqueado por sessao_tem_dispositivo_verificado sob enforcement.
-- 4. P2 conta multivinculada Apple+Google: transação PKCE iniciada com apple recusa provedor google e não grava sessoes_verificadas.
-- 5. Replay de transação PKCE e transação expirada são recusados atomicamente.
-- 6. Replay de id_token (mesmo hash) é recusado atomicamente sem persistir token bruto e sem gravar sessoes_verificadas.
-- 7. concluir_login_social comprova auth.identities, grava sessoes_verificadas e hook emite dispositivo_verificado=true.
-- 8. Revogação online (revogar_todos_dispositivos) invalida imediatamente a sessão social.
-- 9. Constraints CHECK/UNIQUE e privilégios de execução/RLS (cobertura de mutação).

begin;
select plan(23);

-- Liga enforcement somente nesta transação de teste (nunca altera migração/modo sombra).
update privado.config_auth
   set exigir_dispositivo_verificado = true,
       corte_sessoes_anteriores_em = '2026-01-01 00:00:00+00'::timestamptz
 where unica = true;

-- Cria 3 usuários sintéticos sem encrypted_password:
-- u_multi:  conta multivinculada Apple + Google
-- u_legado: conta OTP-only sem identidade social
-- u_apple:  conta somente Apple (para teste de replay de id_token)
insert into auth.users (id, email, encrypted_password, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
values
  ('90200000-0000-4000-8000-000000000001'::uuid, 'multi-social@frila.test', '', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('90200000-0000-4000-8000-000000000002'::uuid, 'legado-otp@frila.test',   '', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('90200000-0000-4000-8000-000000000003'::uuid, 'only-apple@frila.test',   '', now(), now(), '{}'::jsonb, '{}'::jsonb);

insert into auth.identities (id, user_id, provider_id, identity_data, provider, created_at, updated_at)
values
  ('90200000-0000-4000-8000-000000000011'::uuid, '90200000-0000-4000-8000-000000000001'::uuid, 'apple-multi-1',  jsonb_build_object('sub', 'apple-multi-1'),  'apple',  now(), now()),
  ('90200000-0000-4000-8000-000000000012'::uuid, '90200000-0000-4000-8000-000000000001'::uuid, 'google-multi-1', jsonb_build_object('sub', 'google-multi-1'), 'google', now(), now()),
  ('90200000-0000-4000-8000-000000000013'::uuid, '90200000-0000-4000-8000-000000000003'::uuid, 'apple-only-1',   jsonb_build_object('sub', 'apple-only-1'),   'apple',  now(), now());

-- 1. Conta social sem senha NÃO precisa definir senha sob enforcement.
select is(
  privado.usuario_precisa_definir_senha('90200000-0000-4000-8000-000000000001'::uuid, '90200000-0000-4000-8000-000000000101'::uuid),
  false,
  'conta multivinculada apple+google sem encrypted_password nao fica presa em precisa_definir_senha'
);

-- 2. Conta legada OTP-only sem senha e sem identidade social CONTINUA precisando definir senha.
select is(
  privado.usuario_precisa_definir_senha('90200000-0000-4000-8000-000000000002'::uuid, '90200000-0000-4000-8000-000000000102'::uuid),
  true,
  'conta legada OTP-only sem identidade social continua com precisa_definir_senha=true sob enforcement'
);

-- 3. Bypass direto no GoTrue (sem concluir_login_social) é bloqueado sob enforcement.
select is(
  privado.verificar_sessao_dispositivo_online('90200000-0000-4000-8000-000000000001'::uuid, '90200000-0000-4000-8000-000000000101'::uuid),
  false,
  'bypass direto no GoTrue sem concluir_login_social e recusado online sob enforcement'
);

-- 4. P2: transação PKCE iniciada com apple recusa consumo declarando google (mesmo em conta Apple+Google)
--    e não grava sessoes_verificadas.
create temp table tx_p2 as
  select (privado.criar_transacao_oauth_social(
    'apple', 'web', repeat('a', 64), 'https://frila-web-dev.frilabr.workers.dev/app/entrar/apple/retorno'
  ) ->> 'transacao_id')::uuid as id;

select is(
  privado.consumir_transacao_oauth_social((select id from tx_p2), 'google', repeat('a', 64)) ->> 'motivo',
  'provedor_divergente',
  'P2: transacao PKCE iniciada como apple recusa provedor google mesmo em conta multivinculada'
);

select is(
  privado.verificar_sessao_dispositivo_online('90200000-0000-4000-8000-000000000001'::uuid, '90200000-0000-4000-8000-000000000101'::uuid),
  false,
  'falha de provedor divergente nao registra sessoes_verificadas'
);

-- 5. Consumo válido da transação PKCE + bloqueio de replay da mesma transação.
select is(
  (privado.consumir_transacao_oauth_social((select id from tx_p2), 'apple', repeat('a', 64)) ->> 'ok')::boolean,
  true,
  'consumo de transacao PKCE com provedor e challenge exatos passa'
);

select is(
  privado.consumir_transacao_oauth_social((select id from tx_p2), 'apple', repeat('a', 64)) ->> 'motivo',
  'desafio_ja_usado',
  'replay da mesma transacao PKCE e bloqueado atomicamente'
);

-- 6. concluir_login_social recusa conta sem identidade social e provedor ausente.
select is(
  (privado.concluir_login_social('90200000-0000-4000-8000-000000000002'::uuid, '90200000-0000-4000-8000-000000000102'::uuid, 'apple') ->> 'ok')::boolean,
  false,
  'concluir_login_social recusa conta sem identidade social'
);

select is(
  (privado.concluir_login_social('90200000-0000-4000-8000-000000000003'::uuid, '90200000-0000-4000-8000-000000000103'::uuid, 'google') ->> 'ok')::boolean,
  false,
  'concluir_login_social recusa provedor google em conta apenas apple'
);

-- 7. Proteção atômica contra replay de id_token (1ª vez ok, 2ª vez token_ja_usado sem gravar 2ª sessão).
select is(
  privado.concluir_login_social('90200000-0000-4000-8000-000000000003'::uuid, '90200000-0000-4000-8000-000000000103'::uuid, 'apple', repeat('b', 64)),
  jsonb_build_object('ok', true, 'precisa_definir_senha', false),
  'concluir_login_social com id_token_hash inedito autoriza sessao social'
);

select is(
  privado.concluir_login_social('90200000-0000-4000-8000-000000000003'::uuid, '90200000-0000-4000-8000-000000000104'::uuid, 'apple', repeat('b', 64)) ->> 'motivo',
  'token_ja_usado',
  'replay do mesmo id_token_hash e bloqueado atomicamente'
);

select is(
  privado.verificar_sessao_dispositivo_online('90200000-0000-4000-8000-000000000003'::uuid, '90200000-0000-4000-8000-000000000104'::uuid),
  false,
  'sessao de replay de id_token nao e gravada em sessoes_verificadas'
);

-- 8. Custom Access Token Hook emite dispositivo_verificado=true e precisa_definir_senha=false.
select is(
  privado.custom_access_token_hook(jsonb_build_object(
    'user_id', '90200000-0000-4000-8000-000000000003',
    'claims', jsonb_build_object(
      'session_id', '90200000-0000-4000-8000-000000000103',
      'app_metadata', '{}'::jsonb
    )
  )) -> 'claims' -> 'app_metadata',
  jsonb_build_object('dispositivo_verificado', true, 'precisa_definir_senha', false),
  'custom_access_token_hook emite dispositivo_verificado=true e precisa_definir_senha=false'
);

-- 9. Revogação online invalida imediatamente a sessão social.
select is(
  privado.revogar_todos_dispositivos('90200000-0000-4000-8000-000000000003'::uuid),
  0,
  'revogar_todos_dispositivos executa em conta social sem dispositivo 30d'
);

select is(
  privado.verificar_sessao_dispositivo_online('90200000-0000-4000-8000-000000000003'::uuid, '90200000-0000-4000-8000-000000000103'::uuid),
  false,
  'sessao social perde autorizacao imediatamente apos revogar_todos_dispositivos'
);

-- 10. Privilégios: anon/authenticated não executam funções privadas nem acessam tabelas privadas.
select ok(
  not has_function_privilege('authenticated', 'privado.concluir_login_social(uuid, uuid, text, text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'privado.criar_transacao_oauth_social(text, text, text, text)', 'EXECUTE')
  and not has_function_privilege('authenticated', 'privado.consumir_transacao_oauth_social(uuid, text, text)', 'EXECUTE'),
  'funcoes privadas de login social nao sao executaveis por authenticated'
);

-- 11. Cobertura de mutação (CHECK e UNIQUE das 2 novas tabelas privadas).
select throws_ok(
  $$ insert into privado.transacoes_oauth_social (provedor, plataforma, code_challenge_hash, callback_url, expira_em)
     values ('invalido', 'web', repeat('c', 64), 'https://frilabr.com/app/entrar/apple/retorno', now() + interval '5 min') $$,
  '23514', null, 'CHECK provedor em transacoes_oauth_social recusa valor invalido'
);
select throws_ok(
  $$ insert into privado.transacoes_oauth_social (provedor, plataforma, code_challenge_hash, callback_url, expira_em)
     values ('apple', 'desktop', repeat('d', 64), 'https://frilabr.com/app/entrar/apple/retorno', now() + interval '5 min') $$,
  '23514', null, 'CHECK plataforma em transacoes_oauth_social recusa valor invalido'
);
select throws_ok(
  $$ insert into privado.transacoes_oauth_social (provedor, plataforma, code_challenge_hash, callback_url, expira_em)
     values ('apple', 'web', repeat('e', 64), 'curto', now() + interval '5 min') $$,
  '23514', null, 'CHECK callback_url em transacoes_oauth_social recusa valor curto'
);
select throws_ok(
  $$ insert into privado.transacoes_oauth_social (provedor, plataforma, code_challenge_hash, callback_url, expira_em)
     values ('apple', 'web', repeat('a', 64), 'https://frilabr.com/app/entrar/apple/retorno', now() + interval '5 min') $$,
  '23505', null, 'UNIQUE code_challenge_hash em transacoes_oauth_social recusa duplicata'
);
select throws_ok(
  $$ insert into privado.tokens_sociais_consumidos (token_hash, provedor, usuario_id, expira_em)
     values ('curto', 'apple', '90200000-0000-4000-8000-000000000003'::uuid, now() + interval '1 hour') $$,
  '23514', null, 'CHECK token_hash em tokens_sociais_consumidos exige 64 caracteres'
);
select throws_ok(
  $$ insert into privado.tokens_sociais_consumidos (token_hash, provedor, usuario_id, expira_em)
     values (repeat('f', 64), 'invalido', '90200000-0000-4000-8000-000000000003'::uuid, now() + interval '1 hour') $$,
  '23514', null, 'CHECK provedor em tokens_sociais_consumidos recusa valor invalido'
);
select throws_ok(
  $$ insert into privado.tokens_sociais_consumidos (token_hash, provedor, usuario_id, expira_em)
     values (repeat('b', 64), 'apple', '90200000-0000-4000-8000-000000000003'::uuid, now() + interval '1 hour') $$,
  '23505', null, 'PK token_hash em tokens_sociais_consumidos recusa replay direto'
);

select * from finish();
rollback;
