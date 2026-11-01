-- 775_privado_validar_ponto_base_profissional.sql
--
-- Cobertura pgTAP do gatilho e função privado.validar_ponto_base_profissional()
-- e provas de mutação dinâmica que matam mutantes de afrouxamento e inversão
-- de proteção de integridade e privacidade geográfica (RF25, RN15).
--
-- Regras validadas:
--   1. Conta ativa com ponto_base preenchido insere e atualiza normalmente (lives_ok).
--   2. Conta anonimizada permite ponto_base nulo (retenção transacional de 15 dias, RF25) (lives_ok).
--   3. Conta ativa com ponto_base nulo é rejeitada com check_violation (SQLSTATE 23514).
--   4. Conta suspensa com ponto_base nulo é rejeitada com check_violation (SQLSTATE 23514).
--
-- Provas de Mutação Dinâmica via pg_get_functiondef:
--   - Mutante M1: Omissão da verificação de estado da conta (permite nulo incondicionalmente)
--     Demonstra que sob M1 conta ativa com ponto_base nulo passaria sem erro (morto pelo teste 3).
--   - Mutante M2: Inversão da condição (v_estado = 'anonimizada' em vez de distinct from)
--     Demonstra que sob M2 conta anonimizada seria bloqueada de expurgar coordenadas (morto pelo teste 2).

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(6);

-- Setup de Dados de Teste
create temp table ids as select
  '77500000-0000-4000-8000-000000000001'::uuid as u_ativo,
  '77500000-0000-4000-8000-000000000002'::uuid as u_suspenso,
  '77500000-0000-4000-8000-000000000003'::uuid as u_anonimizado,
  '77500000-0000-4000-8000-000000000011'::uuid as p_ativo,
  '77500000-0000-4000-8000-000000000012'::uuid as p_suspenso,
  '77500000-0000-4000-8000-000000000013'::uuid as p_anonimizado;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u_ativo, 'authenticated', 'authenticated',
       'ativo775@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u_suspenso, 'authenticated', 'authenticated',
       'suspenso775@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u_anonimizado, 'authenticated', 'authenticated',
       'anon775@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em, anonimizado_em) values
  ('77500000-0000-4000-8000-000000000001', 'profissional', 'Ativo 775',      'ativo775@test.com',    '+5561977500001', '1990-01-01', 'ativa',       '1.0', now(), null),
  ('77500000-0000-4000-8000-000000000002', 'profissional', 'Suspenso 775',    'suspenso775@test.com', '+5561977500002', '1991-02-02', 'suspensa',    '1.0', now(), null),
  ('77500000-0000-4000-8000-000000000003', 'profissional', 'Anonimizado 775', null,                  null,             '1992-03-03', 'anonimizada', '1.0', now(), now());

-- ── 1. Conta ativa com ponto_base preenchido insere normalmente (lives_ok) ─────────
select lives_ok(
  format($$ insert into public.profissional (id, usuario_id, ponto_base)
            values ('%s'::uuid, '%s'::uuid, 'POINT(-47.8822 -15.7942)'::extensions.geography) $$,
         (select p_ativo from ids), (select u_ativo from ids)),
  'profissional ativo com ponto_base não-nulo é inserido com sucesso'
);

-- ── 2. Conta anonimizada permite ponto_base nulo (lives_ok) ───────────────────────
select lives_ok(
  format($$ insert into public.profissional (id, usuario_id, ponto_base)
            values ('%s'::uuid, '%s'::uuid, null) $$,
         (select p_anonimizado from ids), (select u_anonimizado from ids)),
  'profissional anonimizado permite ponto_base nulo (expurgo de geolocalização)'
);

-- ── 3. Conta ativa com ponto_base nulo levanta check_violation ────────────────────
select throws_ok(
  format($$ update public.profissional set ponto_base = null where id = '%s'::uuid $$,
         (select p_ativo from ids)),
  '23514',
  'ponto_base só pode ser nulo para conta anonimizada (RF25, RN15)',
  'tentativa de atualizar ponto_base para nulo em conta ativa é rejeitada com check_violation'
);

-- ── 4. Conta suspensa com ponto_base nulo levanta check_violation ──────────────────
select throws_ok(
  format($$ insert into public.profissional (id, usuario_id, ponto_base)
            values ('%s'::uuid, '%s'::uuid, null) $$,
         (select p_suspenso from ids), (select u_suspenso from ids)),
  '23514',
  'ponto_base só pode ser nulo para conta anonimizada (RF25, RN15)',
  'tentativa de inserir ponto_base nulo em conta suspensa é rejeitada com check_violation'
);

-- ── 5. Prova de Mutação M1: Omissão da verificação de estado da conta ─────────────
do $$
begin
  execute replace(
    pg_get_functiondef('privado.validar_ponto_base_profissional()'::regprocedure),
    'if v_estado is distinct from ''anonimizada'' then',
    'if false and v_estado is distinct from ''anonimizada'' then'
  );
end $$;

select lives_ok(
  format($$ update public.profissional set ponto_base = null where id = '%s'::uuid $$,
         (select p_ativo from ids)),
  'mutante M1 (sem checagem de estado): conta ativa com ponto_base nulo passaria; mutante discriminado e morto pelo teste 3'
);

-- Restauração dinâmica de M1
do $$
begin
  execute replace(
    pg_get_functiondef('privado.validar_ponto_base_profissional()'::regprocedure),
    'if false and v_estado is distinct from ''anonimizada'' then',
    'if v_estado is distinct from ''anonimizada'' then'
  );
end $$;

-- ── 6. Prova de Mutação M2: Inversão de condição (v_estado = 'anonimizada') ────────
do $$
begin
  execute replace(
    pg_get_functiondef('privado.validar_ponto_base_profissional()'::regprocedure),
    'if v_estado is distinct from ''anonimizada'' then',
    'if v_estado = ''anonimizada'' then'
  );
end $$;

select throws_ok(
  format($$ update public.profissional set ponto_base = null where id = '%s'::uuid $$,
         (select p_anonimizado from ids)),
  '23514',
  'ponto_base só pode ser nulo para conta anonimizada (RF25, RN15)',
  'mutante M2 (condição invertida): conta anonimizada seria bloqueada de ter ponto_base nulo; morto pelo teste 2'
);

-- Restauração dinâmica de M2
do $$
begin
  execute replace(
    pg_get_functiondef('privado.validar_ponto_base_profissional()'::regprocedure),
    'if v_estado = ''anonimizada'' then',
    'if v_estado is distinct from ''anonimizada'' then'
  );
end $$;

select * from finish();

rollback;
