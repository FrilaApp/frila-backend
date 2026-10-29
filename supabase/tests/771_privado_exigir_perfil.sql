-- 771_privado_exigir_perfil.sql
--
-- Cobertura pgTAP de privado.exigir_perfil(esperado public.perfil_conta)
-- e provas de mutação dinâmica que matam mutantes de omissão de conta ativa
-- e de afrouxamento da trava de perfil incompatível (RF25, RN06).
--
-- Regras validadas:
--   1. Usuário contratante ativo exigindo 'contratante' passa normalmente (lives_ok).
--   2. Usuário profissional ativo exigindo 'profissional' passa normalmente (lives_ok).
--   3. Incompatibilidade de perfil (contratante chamando exigir_perfil('profissional'))
--      é rejeitada com erro 422 'perfil_incompativel'.
--   4. Incompatibilidade reversa (profissional chamando exigir_perfil('contratante'))
--      é rejeitada com erro 422 'perfil_incompativel'.
--   5. Usuário com conta suspensa é barrado com erro 422 'conta_suspensa' via privado.exigir_conta_ativa().
--   6. Usuário com conta anonimizada é barrado com erro 401 'nao_autenticado'.
--   7. Chamada sem autenticação (auth.uid() nulo) é rejeitada com 422 'perfil_incompativel'.
--
-- Provas de Mutação Dinâmica via pg_get_functiondef:
--   - Mutante M1: Omissão de perform privado.exigir_conta_ativa()
--     Demonstra que sob M1 um usuário suspenso passaria ilicitamente sem erro (morto pelo teste 5).
--   - Mutante M2: Afrouxamento da checagem de perfil (if false and ...)
--     Demonstra que sob M2 uma chamada com perfil incompatível passaria ilicitamente (morto pelo teste 3).

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(9);

create function pg_temp.autenticar_jwt(conta uuid) returns void
language plpgsql as $$
begin
  execute format('set local "request.jwt.claims" = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute format('set local "request.jwt.claim.sub" = %L', conta::text);
end $$;

create function pg_temp.limpar_jwt() returns void
language plpgsql as $$
begin
  execute 'reset "request.jwt.claims"';
  execute 'reset "request.jwt.claim.sub"';
end $$;

-- Setup de Dados de Teste
create temp table ids as select
  '77100000-0000-4000-8000-000000000001'::uuid as u_contratante,
  '77100000-0000-4000-8000-000000000002'::uuid as u_profissional,
  '77100000-0000-4000-8000-000000000003'::uuid as u_suspenso,
  '77100000-0000-4000-8000-000000000004'::uuid as u_anonimizado;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u_contratante, 'authenticated', 'authenticated',
       'contratante771@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u_profissional, 'authenticated', 'authenticated',
       'profissional771@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u_suspenso, 'authenticated', 'authenticated',
       'suspenso771@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u_anonimizado, 'authenticated', 'authenticated',
       'anonimizado771@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em, anonimizado_em) values
  ('77100000-0000-4000-8000-000000000001', 'contratante',  'Dono 771',       'contratante771@test.com',  '+5561977100001', '1985-01-01', 'ativa',       '1.0', now(), null),
  ('77100000-0000-4000-8000-000000000002', 'profissional', 'Garçom 771',     'profissional771@test.com', '+5561977100002', '1990-01-01', 'ativa',       '1.0', now(), null),
  ('77100000-0000-4000-8000-000000000003', 'contratante',  'Suspenso 771',   'suspenso771@test.com',     '+5561977100003', '1987-01-01', 'suspensa',    '1.0', now(), null),
  ('77100000-0000-4000-8000-000000000004', 'contratante',  'Anonimizado 771', null,                       null,             '1988-01-01', 'anonimizada', '1.0', now(), now());

-- ── 1. Contratante ativo exigindo 'contratante' passa (lives_ok) ───────────────────
select pg_temp.autenticar_jwt('77100000-0000-4000-8000-000000000001');
select lives_ok(
  $$ select privado.exigir_perfil('contratante'::public.perfil_conta) $$,
  'usuário contratante ativo passa normalmente ao exigir perfil contratante'
);

-- ── 2. Profissional ativo exigindo 'profissional' passa (lives_ok) ─────────────────
select pg_temp.autenticar_jwt('77100000-0000-4000-8000-000000000002');
select lives_ok(
  $$ select privado.exigir_perfil('profissional'::public.perfil_conta) $$,
  'usuário profissional ativo passa normalmente ao exigir perfil profissional'
);

-- ── 3. Incompatibilidade: contratante chamando exigir_perfil('profissional') ──────
select pg_temp.autenticar_jwt('77100000-0000-4000-8000-000000000001');
select throws_matching(
  $$ select privado.exigir_perfil('profissional'::public.perfil_conta) $$,
  'perfil_incompativel',
  'contratante é rejeitado com 422 perfil_incompativel ao exigir profissional'
);

-- ── 4. Incompatibilidade: profissional chamando exigir_perfil('contratante') ──────
select pg_temp.autenticar_jwt('77100000-0000-4000-8000-000000000002');
select throws_matching(
  $$ select privado.exigir_perfil('contratante'::public.perfil_conta) $$,
  'perfil_incompativel',
  'profissional é rejeitado com 422 perfil_incompativel ao exigir contratante'
);

-- ── 5. Conta suspensa: bloqueado por exigir_conta_ativa com 422 conta_suspensa ────
select pg_temp.autenticar_jwt('77100000-0000-4000-8000-000000000003');
select throws_matching(
  $$ select privado.exigir_perfil('contratante'::public.perfil_conta) $$,
  'conta_suspensa',
  'usuário com conta suspensa é barrado com 422 conta_suspensa'
);

-- ── 6. Conta anonimizada: bloqueado com 401 nao_autenticado ───────────────────────
select pg_temp.autenticar_jwt('77100000-0000-4000-8000-000000000004');
select throws_matching(
  $$ select privado.exigir_perfil('contratante'::public.perfil_conta) $$,
  'nao_autenticado',
  'usuário com conta anonimizada é barrado com 401 nao_autenticado'
);

-- ── 7. Chamada sem autenticação (auth.uid() nulo): rejeitada com perfil_incompativel
select pg_temp.limpar_jwt();
select throws_matching(
  $$ select privado.exigir_perfil('contratante'::public.perfil_conta) $$,
  'perfil_incompativel',
  'chamada sem JWT autenticado é rejeitada com 422 perfil_incompativel'
);

-- ── 8. Prova de Mutação M1: Omissão de perform privado.exigir_conta_ativa() ────────
do $$
begin
  execute replace(
    pg_get_functiondef('privado.exigir_perfil(public.perfil_conta)'::regprocedure),
    'perform privado.exigir_conta_ativa();',
    '-- perform privado.exigir_conta_ativa();'
  );
end $$;

select pg_temp.autenticar_jwt('77100000-0000-4000-8000-000000000003');
select lives_ok(
  $$ select privado.exigir_perfil('contratante'::public.perfil_conta) $$,
  'mutante M1 (sem exigir_conta_ativa): conta suspensa passaria sem erro; mutante discriminado e morto pelo teste 5'
);

-- Restauração dinâmica canônica de M1
do $$
begin
  execute replace(
    pg_get_functiondef('privado.exigir_perfil(public.perfil_conta)'::regprocedure),
    '-- perform privado.exigir_conta_ativa();',
    'perform privado.exigir_conta_ativa();'
  );
end $$;

-- ── 9. Prova de Mutação M2: Afrouxamento da checagem de perfil (if false and ...) ───
do $$
begin
  execute replace(
    pg_get_functiondef('privado.exigir_perfil(public.perfil_conta)'::regprocedure),
    'if privado.perfil_da_conta() is distinct from esperado then',
    'if false and privado.perfil_da_conta() is distinct from esperado then'
  );
end $$;

select pg_temp.autenticar_jwt('77100000-0000-4000-8000-000000000001');
select lives_ok(
  $$ select privado.exigir_perfil('profissional'::public.perfil_conta) $$,
  'mutante M2 (sem checagem de perfil): perfil incompatível passaria sem erro; mutante discriminado e morto pelo teste 3'
);

-- Restauração dinâmica canônica de M2
do $$
begin
  execute replace(
    pg_get_functiondef('privado.exigir_perfil(public.perfil_conta)'::regprocedure),
    'if false and privado.perfil_da_conta() is distinct from esperado then',
    'if privado.perfil_da_conta() is distinct from esperado then'
  );
end $$;

select * from finish();

rollback;
