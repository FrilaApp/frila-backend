-- pgTAP: Fundação server-side de login social Apple e Google (contrato 0.2.117).
-- Cobre:
-- 1. Conta social (apple/google) sem encrypted_password NÃO fica presa em precisa_definir_senha sob enforcement.
-- 2. Conta legada OTP-only sem encrypted_password e sem identidade social CONTINUA exigindo senha sob enforcement.
-- 3. Bypass direto no GoTrue (sem concluir_login_social) é bloqueado por sessao_tem_dispositivo_verificado sob enforcement.
-- 4. concluir_login_social comprova auth.identities do provedor, grava sessoes_verificadas e hook emite dispositivo_verificado=true.
-- 5. concluir_login_social recusa usuário sem identidade do provedor declarado.
-- 6. Revogação online (revogar_todos_dispositivos) invalida imediatamente a sessão social.

begin;
select plan(12);

-- Liga enforcement somente nesta transação de teste (nunca altera migração/modo sombra).
update privado.config_auth
   set exigir_dispositivo_verificado = true,
       corte_sessoes_anteriores_em = '2026-01-01 00:00:00+00'::timestamptz
 where unica = true;

-- Cria 2 usuários sintéticos sem encrypted_password:
-- u_social: possui identidade apple em auth.identities
-- u_legado: não possui identidade social (OTP-only)
insert into auth.users (id, email, encrypted_password, created_at, updated_at, raw_app_meta_data, raw_user_meta_data)
values
  ('90200000-0000-4000-8000-000000000001'::uuid, 'social-apple@frila.test', '', now(), now(), '{}'::jsonb, '{}'::jsonb),
  ('90200000-0000-4000-8000-000000000002'::uuid, 'legado-otp@frila.test',   '', now(), now(), '{}'::jsonb, '{}'::jsonb);

insert into auth.identities (id, user_id, provider_id, identity_data, provider, created_at, updated_at)
values (
  '90200000-0000-4000-8000-000000000011'::uuid,
  '90200000-0000-4000-8000-000000000001'::uuid,
  'apple-sub-sintetico-1',
  jsonb_build_object('sub', 'apple-sub-sintetico-1', 'email', 'social-apple@frila.test'),
  'apple',
  now(),
  now()
);

-- 1. Conta social sem senha NÃO precisa definir senha sob enforcement.
select is(
  privado.usuario_precisa_definir_senha(
    '90200000-0000-4000-8000-000000000001'::uuid,
    '90200000-0000-4000-8000-000000000101'::uuid
  ),
  false,
  'conta com identidade apple sem encrypted_password nao fica presa em precisa_definir_senha'
);

-- 2. Conta legada OTP-only sem senha e sem identidade social CONTINUA precisando definir senha.
select is(
  privado.usuario_precisa_definir_senha(
    '90200000-0000-4000-8000-000000000002'::uuid,
    '90200000-0000-4000-8000-000000000102'::uuid
  ),
  true,
  'conta legada OTP-only sem identidade social continua com precisa_definir_senha=true sob enforcement'
);

-- 3. Bypass direto no GoTrue (sessão social sem passar por concluir_login_social) não está autorizada.
select is(
  privado.sessao_tem_dispositivo_verificado(
    '90200000-0000-4000-8000-000000000101'::uuid,
    '90200000-0000-4000-8000-000000000001'::uuid
  ),
  false,
  'bypass direto no GoTrue sem concluir_login_social nao tem dispositivo_verificado'
);

select is(
  privado.verificar_sessao_dispositivo_online(
    '90200000-0000-4000-8000-000000000001'::uuid,
    '90200000-0000-4000-8000-000000000101'::uuid
  ),
  false,
  'verificar_sessao_dispositivo_online recusa sessao social nao registrada sob enforcement'
);

-- 4. concluir_login_social recusa provedor divergente (google quando só tem apple) e usuário sem identidade social.
select is(
  (privado.concluir_login_social(
    '90200000-0000-4000-8000-000000000001'::uuid,
    '90200000-0000-4000-8000-000000000101'::uuid,
    'google'
  ) ->> 'ok')::boolean,
  false,
  'concluir_login_social recusa provedor google quando usuario possui apenas identidade apple'
);

select is(
  (privado.concluir_login_social(
    '90200000-0000-4000-8000-000000000002'::uuid,
    '90200000-0000-4000-8000-000000000102'::uuid,
    'apple'
  ) ->> 'ok')::boolean,
  false,
  'concluir_login_social recusa conta sem identidade social'
);

-- 5. concluir_login_social com identidade apple válida registra sessoes_verificadas e autoriza online.
select is(
  privado.concluir_login_social(
    '90200000-0000-4000-8000-000000000001'::uuid,
    '90200000-0000-4000-8000-000000000101'::uuid,
    'apple'
  ),
  jsonb_build_object('ok', true, 'precisa_definir_senha', false),
  'concluir_login_social autoriza sessao social valida sem exigir senha'
);

select is(
  privado.verificar_sessao_dispositivo_online(
    '90200000-0000-4000-8000-000000000001'::uuid,
    '90200000-0000-4000-8000-000000000101'::uuid
  ),
  true,
  'verificar_sessao_dispositivo_online aceita sessao social registrada'
);

-- 6. Custom Access Token Hook emite dispositivo_verificado=true e precisa_definir_senha=false.
select is(
  privado.custom_access_token_hook(jsonb_build_object(
    'user_id', '90200000-0000-4000-8000-000000000001',
    'claims', jsonb_build_object(
      'session_id', '90200000-0000-4000-8000-000000000101',
      'app_metadata', '{}'::jsonb
    )
  )) -> 'claims' -> 'app_metadata',
  jsonb_build_object('dispositivo_verificado', true, 'precisa_definir_senha', false),
  'custom_access_token_hook emite dispositivo_verificado=true e precisa_definir_senha=false para sessao social'
);

-- 7. Revogação online (revogar_todos_dispositivos) derruba imediatamente a sessão social.
select is(
  privado.revogar_todos_dispositivos('90200000-0000-4000-8000-000000000001'::uuid),
  0,
  'revogar_todos_dispositivos executa sem erro em conta social sem dispositivo 30d'
);

select is(
  privado.verificar_sessao_dispositivo_online(
    '90200000-0000-4000-8000-000000000001'::uuid,
    '90200000-0000-4000-8000-000000000101'::uuid
  ),
  false,
  'sessao social perde autorizacao imediatamente apos revogar_todos_dispositivos'
);

-- 8. Privilégios: authenticated/anon não podem chamar privado.concluir_login_social.
select ok(
  not has_function_privilege('authenticated', 'privado.concluir_login_social(uuid, uuid, text)', 'EXECUTE')
  and not has_function_privilege('anon', 'privado.concluir_login_social(uuid, uuid, text)', 'EXECUTE'),
  'privado.concluir_login_social nao e executavel por anon ou authenticated'
);

select * from finish();
rollback;
