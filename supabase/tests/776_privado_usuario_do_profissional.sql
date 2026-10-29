-- 776_privado_usuario_do_profissional.sql
--
-- Cobertura pgTAP de privado.usuario_do_profissional(prof uuid)
-- e provas de mutação dinâmica que matam mutantes de projeção
-- e de quebra de mapeamento de titularidade da conta (RF25, RN06).
--
-- Regras validadas:
--   1. Retorna o usuario_id correto para o profissional_id informado.
--   2. Discrimina múltiplos profissionais mapeando cada um ao seu respectivo usuario_id.
--   3. Retorna NULL para profissional_id inexistente.
--   4. Retorna NULL para argumento NULL.
--
-- Provas de Mutação Dinâmica via pg_get_functiondef:
--   - Mutante M1: Omissão da cláusula WHERE (sem filtro por id do profissional)
--     Demonstra que sob M1 profissionais distintos colidiriam no mesmo usuário (morto pelo teste 2).
--   - Mutante M2: Retorno do id do profissional em vez de usuario_id
--     Demonstra que sob M2 a identidade do titular seria corrompida (morto pelo teste 1).

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(6);

-- Setup de Dados de Teste
create temp table ids as select
  '77600000-0000-4000-8000-000000000001'::uuid as u1,
  '77600000-0000-4000-8000-000000000002'::uuid as u2,
  '77600000-0000-4000-8000-000000000011'::uuid as p1,
  '77600000-0000-4000-8000-000000000012'::uuid as p2;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u1, 'authenticated', 'authenticated',
       'u1_776@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u2, 'authenticated', 'authenticated',
       'u2_776@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('77600000-0000-4000-8000-000000000001', 'profissional', 'Profissional 1 776', 'u1_776@test.com', '+5561977600001', '1990-01-01', 'ativa', '1.0', now()),
  ('77600000-0000-4000-8000-000000000002', 'profissional', 'Profissional 2 776', 'u2_776@test.com', '+5561977600002', '1992-02-02', 'ativa', '1.0', now());

insert into public.profissional (id, usuario_id, ponto_base) values
  ('77600000-0000-4000-8000-000000000011', '77600000-0000-4000-8000-000000000001', 'POINT(-47.8822 -15.7942)'::extensions.geography),
  ('77600000-0000-4000-8000-000000000012', '77600000-0000-4000-8000-000000000002', 'POINT(-47.8822 -15.7942)'::extensions.geography);

-- ── 1. Retorna o usuario_id do profissional 1 ─────────────────────────────────────
select is(
  privado.usuario_do_profissional((select p1 from ids)),
  (select u1 from ids),
  'privado.usuario_do_profissional retorna o usuario_id do titular do perfil profissional'
);

-- ── 2. Discrimina titularidades distintas (profissional 2 -> usuario 2) ───────────
select is(
  privado.usuario_do_profissional((select p2 from ids)),
  (select u2 from ids),
  'privado.usuario_do_profissional retorna usuario_id distinto para outro profissional'
);

-- ── 3. Profissional inexistente retorna NULL ──────────────────────────────────────
select is(
  privado.usuario_do_profissional('77600000-0000-4000-8000-ffffffffffff'::uuid),
  null,
  'privado.usuario_do_profissional retorna NULL para profissional inexistente'
);

-- ── 4. Argumento NULL retorna NULL ────────────────────────────────────────────────
select is(
  privado.usuario_do_profissional(null),
  null,
  'privado.usuario_do_profissional retorna NULL para entrada nula'
);

-- ── 5. Provas de Mutação Dinâmica via pg_get_functiondef ─────────────────────────
create temp table canonicos as select
  pg_get_functiondef('privado.usuario_do_profissional(uuid)'::regprocedure) as def;

-- Mutante M1: Omissão de filtro WHERE por profissional (restrito aos dados do teste)
-- Demonstra que sob M1 profissionais distintos colidiriam no mesmo usuário (morto pelo teste 2).
do $$
begin
  execute replace(
    (select def from canonicos),
    'where id = prof',
    'where id in (''77600000-0000-4000-8000-000000000011'', ''77600000-0000-4000-8000-000000000012'') order by id limit 1'
  );
end $$;

select is(
  privado.usuario_do_profissional((select p2 from ids)),
  (select u1 from ids),
  'mutante M1 (sem filtro de prof): retornaria o primeiro usuário arbitrário; morto pelo teste 2'
);

-- Restauração dinâmica de M1
do $$
begin
  execute (select def from canonicos);
end $$;

-- ── 6. Prova de Mutação M2: Retorno de id da tabela profissional ──────────────────
-- Mutante M2: Retorno do id do profissional em vez de usuario_id
-- Demonstra que sob M2 a identidade do titular seria corrompida (morto pelo teste 1).
do $$
begin
  execute replace(
    (select def from canonicos),
    'select usuario_id from public.profissional',
    'select id from public.profissional'
  );
end $$;

select is(
  privado.usuario_do_profissional((select p1 from ids)),
  (select p1 from ids),
  'mutante M2 (retorna id em vez de usuario_id): diverge do titular; morto pelo teste 1'
);

-- Restauração dinâmica de M2
do $$
begin
  execute (select def from canonicos);
end $$;

select * from finish();

rollback;
