-- 758_privado_operacao_exigir_operador.sql
--
-- Cobertura pgTAP de privado.operacao_exigir_operador(operador uuid, alvo uuid)
-- e provas de mutação dinâmica que matam mutantes de auto-moderação e conta ativa.
--
-- Regras validadas:
--   1. Operador nulo é rejeitado com 422 campo_obrigatorio (operador_id).
--   2. Operador inexistente é rejeitado com 422 campo_invalido (operador_id).
--   3. Operador com conta não ativa (ex.: suspensa) é rejeitado com 422 campo_invalido (operador_id).
--   4. Tentativa de auto-moderação (operador = alvo) é rejeitada com 422 campo_invalido (operador_id).
--   5. Operador válido (conta ativa e diferente do alvo) sucede normalmente (lives_ok).
--
-- Provas de Mutação Dinâmica via pg_get_functiondef:
--   - Mutante M1: Omissão da trava de auto-moderação (operador = alvo)
--     Demonstra que sob M1 a auto-moderação passaria ilicitamente sem erro (discriminado).
--   - Mutante M2: Afrouxamento da checagem de estado da conta (omite u.estado = 'ativa')
--     Demonstra que sob M2 um operador suspenso passaria ilicitamente sem erro (discriminado).

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(7);

-- Setup de Dados de Teste
create temp table ids as select
  '75800000-0000-4000-8000-000000000001'::uuid as op_ativo,
  '75800000-0000-4000-8000-000000000002'::uuid as op_suspenso,
  '75800000-0000-4000-8000-000000000003'::uuid as alvo_usuario;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', op_ativo, 'authenticated', 'authenticated',
       'op_ativo758@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', op_suspenso, 'authenticated', 'authenticated',
       'op_suspenso758@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', alvo_usuario, 'authenticated', 'authenticated',
       'alvo758@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('75800000-0000-4000-8000-000000000001', 'contratante', 'Operador Ativo 758',    'op_ativo758@test.com',    '+5561975800001', '1985-01-01', 'ativa',    '1.0', now()),
  ('75800000-0000-4000-8000-000000000002', 'contratante', 'Operador Suspenso 758',  'op_suspenso758@test.com',  '+5561975800002', '1987-01-01', 'suspensa', '1.0', now()),
  ('75800000-0000-4000-8000-000000000003', 'profissional', 'Alvo de Moderação 758', 'alvo758@test.com',         '+5561975800003', '1990-01-01', 'ativa',    '1.0', now());

-- ── 1. Operador nulo: campo_obrigatorio ───────────────────────────────────────────
select throws_matching(
  $$ select privado.operacao_exigir_operador(null, '75800000-0000-4000-8000-000000000003'::uuid) $$,
  'campo_obrigatorio.*operador_id',
  'operador nulo é rejeitado com 422 campo_obrigatorio (operador_id)'
);

-- ── 2. Operador inexistente: campo_invalido ───────────────────────────────────────
select throws_matching(
  $$ select privado.operacao_exigir_operador('75800000-0000-4000-8000-ffffffffffff'::uuid, '75800000-0000-4000-8000-000000000003'::uuid) $$,
  'campo_invalido.*operador_id',
  'operador inexistente é rejeitado com 422 campo_invalido (operador_id)'
);

-- ── 3. Operador com conta não ativa (suspensa): campo_invalido ────────────────────
select throws_matching(
  $$ select privado.operacao_exigir_operador((select op_suspenso from ids), (select alvo_usuario from ids)) $$,
  'campo_invalido.*operador_id',
  'operador com conta suspensa é rejeitado com 422 campo_invalido (operador_id)'
);

-- ── 4. Auto-moderação (operador = alvo): campo_invalido ───────────────────────────
select throws_matching(
  $$ select privado.operacao_exigir_operador((select op_ativo from ids), (select op_ativo from ids)) $$,
  'campo_invalido.*operador_id',
  'tentativa de auto-moderação (operador = alvo) é rejeitada com 422 campo_invalido (operador_id)'
);

-- ── 5. Caminho feliz: operador ativo e diferente do alvo ──────────────────────────
select lives_ok(
  $$ select privado.operacao_exigir_operador('75800000-0000-4000-8000-000000000001'::uuid, '75800000-0000-4000-8000-000000000003'::uuid) $$,
  'operador ativo e diferente do alvo passa normalmente sem erro'
);

-- ── 6. Prova de Mutação M1: Omissão da trava de auto-moderação ────────────────────
do $$
begin
  execute replace(
    pg_get_functiondef('privado.operacao_exigir_operador(uuid, uuid)'::regprocedure),
    'if operador = alvo then',
    'if false and operador = alvo then'
  );
end $$;

select lives_ok(
  $$ select privado.operacao_exigir_operador('75800000-0000-4000-8000-000000000001'::uuid, '75800000-0000-4000-8000-000000000001'::uuid) $$,
  'mutante M1 (sem trava de auto-moderação): chamada passaria sem erro; mutante discriminado e morto pelo teste 4'
);

-- Restauração dinâmica canônica de M1
do $$
begin
  execute replace(
    pg_get_functiondef('privado.operacao_exigir_operador(uuid, uuid)'::regprocedure),
    'if false and operador = alvo then',
    'if operador = alvo then'
  );
end $$;

-- ── 7. Prova de Mutação M2: Afrouxamento da checagem de conta ativa ───────────────
do $$
begin
  execute replace(
    pg_get_functiondef('privado.operacao_exigir_operador(uuid, uuid)'::regprocedure),
    'where u.id = operador and u.estado = ''ativa''',
    'where u.id = operador'
  );
end $$;

select lives_ok(
  $$ select privado.operacao_exigir_operador('75800000-0000-4000-8000-000000000002'::uuid, '75800000-0000-4000-8000-000000000003'::uuid) $$,
  'mutante M2 (sem checagem de conta ativa): operador suspenso passaria sem erro; mutante discriminado e morto pelo teste 3'
);

-- Restauração dinâmica canônica de M2
do $$
begin
  execute replace(
    pg_get_functiondef('privado.operacao_exigir_operador(uuid, uuid)'::regprocedure),
    'where u.id = operador',
    'where u.id = operador and u.estado = ''ativa'''
  );
end $$;

select * from finish();

rollback;
