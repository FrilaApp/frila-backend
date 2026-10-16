-- 703_contas_auth_orfas.sql
-- Cobertura pgTAP da função privado.contas_auth_orfas(integer) (UC09 2a, RF25).
-- Caracteriza o comportamento atual do sistema:
--   1. Retenção estrita de 24 horas no relógio frila.agora (corte exato no segundo);
--   2. Listagem em massa (>50 contas, lote de 65) provando ausência de LIMIT no SQL;
--   3. Contas com cadastro ativo em public.usuario são ignoradas;
--   4. Contas anonimizadas com credencial viva em auth.users NÃO são recolhidas
--      (comportamento arquitetural atual sob avaliação técnica do dono, pois a linha
--       em public.usuario continua existindo e a cláusula not exists avalia como falso).

begin;
set local timezone = 'UTC';
select plan(15);

-- ── 1. Metadados e Privilégios Mínimos ───────────────────────────────────────
select has_function('privado', 'contas_auth_orfas', array['integer'], 'funcao existe no schema privado');
select is_definer('privado', 'contas_auth_orfas', array['integer'], 'funcao e SECURITY DEFINER');
select ok(
  (select proconfig from pg_proc where proname = 'contas_auth_orfas' and pronamespace = 'privado'::regnamespace)
  @> array['search_path=""'],
  'funcao opera com search_path="" vazio fixado contra sequestro de schema'
);
select is(has_function_privilege('service_role', 'privado.contas_auth_orfas(integer)', 'execute'), true, 'service_role pode executar');
select is(has_function_privilege('authenticated', 'privado.contas_auth_orfas(integer)', 'execute'), false, 'authenticated nao executa');
select is(has_function_privilege('anon', 'privado.contas_auth_orfas(integer)', 'execute'), false, 'anon nao executa');
select is(has_function_privilege('public', 'privado.contas_auth_orfas(integer)', 'execute'), false, 'public nao executa');

-- ── 2. Setup Temporal e Contas de Teste (Padrão 694 + TESTES-PGTAP-PADROES) ──
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
-- Fixa o relógio de referência: 2026-10-20 12:00:00+00.
-- Ponto de corte exato de 24h: 2026-10-19 12:00:00+00.
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

-- Inserção de contas singulares e de borda temporal em auth.users:
-- 7030...00b1: 23h 59m 59s atrás (2026-10-19 12:00:01) -> preservada (< 24h)
-- 7030...00b2: 24h 00m 00s exatos (2026-10-19 12:00:00) -> preservada (operador < estrito)
-- 7030...00b3: 24h 00m 01s atrás (2026-10-19 11:59:59) -> capturada (> 24h)
-- 7030...0002: órfã recente (10h atrás: 2026-10-20 02:00:00) -> capturada apenas com p_horas menor
-- 7030...0003: conta ativa (30h atrás) com linha regular em public.usuario -> ignorada
-- 7030...0004: conta anonimizada (30h atrás) com credencial viva em auth.users -> caracterização
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous) values
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-0000000000b1', 'authenticated', 'authenticated', 'borda_recente@teste.com', '2026-10-19 12:00:01+00', '2026-10-19 12:00:01+00', false, false),
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-0000000000b2', 'authenticated', 'authenticated', 'borda_exata@teste.com',   '2026-10-19 12:00:00+00', '2026-10-19 12:00:00+00', false, false),
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-0000000000b3', 'authenticated', 'authenticated', 'borda_antiga@teste.com',  '2026-10-19 11:59:59+00', '2026-10-19 11:59:59+00', false, false),
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'orfa_10h@teste.com',      '2026-10-20 02:00:00+00', '2026-10-20 02:00:00+00', false, false),
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'ativa@teste.com',         '2026-10-19 06:00:00+00', '2026-10-19 06:00:00+00', false, false),
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'anonimizada@teste.com',   '2026-10-19 06:00:00+00', '2026-10-19 06:00:00+00', false, false);

-- Inserção de lote em massa (>50 contas, exatamente 65) criadas há 48h para provar ausência de LIMIT no SQL:
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select
  '00000000-0000-0000-0000-000000000000'::uuid,
  ('70310000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
  'authenticated', 'authenticated',
  'massa_' || i || '@teste.com',
  '2026-10-18 12:00:00+00'::timestamptz,
  '2026-10-18 12:00:00+00'::timestamptz,
  false, false
from generate_series(1, 65) as s(i);

-- Inserções em public.usuario (com termos_versao e termos_aceite_em obrigatórios conforme regra 694):
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado, anonimizado_em) values
  ('70300000-0000-4000-8000-000000000003', 'profissional', 'Usuario Ativo', '+5561970300003', 'ativa@teste.com', '1995-01-01', '2026-09-22', '2026-10-19 06:00:00+00', 'ativa', null),
  ('70300000-0000-4000-8000-000000000004', 'profissional', 'Conta encerrada', null, null, '1995-01-01', '2026-09-22', '2026-10-19 06:00:00+00', 'anonimizada', '2026-10-19 12:00:00+00');

-- ── 3. Aferição da Borda Estrita de 24 Horas ──────────────────────────────────
select is(
  (select count(*)::int from privado.contas_auth_orfas() where id = '70300000-0000-4000-8000-0000000000b1'),
  0,
  'borda estrita: conta com 23h59m59s e preservada (dentro da janela de tolerancia)'
);

select is(
  (select count(*)::int from privado.contas_auth_orfas() where id = '70300000-0000-4000-8000-0000000000b2'),
  0,
  'borda estrita: conta com exatamente 24h00m00s e preservada (operador < e estrito)'
);

select is(
  (select count(*)::int from privado.contas_auth_orfas() where id = '70300000-0000-4000-8000-0000000000b3'),
  1,
  'borda estrita: conta com 24h00m01s e capturada para expurgo'
);

-- ── 4. Parametrização, Contas Cadastradas e Caracterização da Anonimizada ────
select is(
  (select count(*)::int from privado.contas_auth_orfas(8) where id = '70300000-0000-4000-8000-000000000002'),
  1,
  'contas_auth_orfas respeita parametro p_horas (janela de 8h captura orfa de 10h)'
);

select is(
  (select count(*)::int from privado.contas_auth_orfas() where id = '70300000-0000-4000-8000-000000000003'),
  0,
  'conta com cadastro ativo em public.usuario nao e retornada'
);

-- Caracterização do comportamento atual da conta anonimizada sob avaliação técnica:
select is(
  (select count(*)::int from privado.contas_auth_orfas() where id = '70300000-0000-4000-8000-000000000004'),
  0,
  'caracterizacao: conta anonimizada com credencial viva em auth.users NAO e retornada por ter registro em usuario'
);

select is(
  (select created_at from privado.contas_auth_orfas() where id = '70300000-0000-4000-8000-0000000000b3'),
  '2026-10-19 11:59:59+00'::timestamptz,
  'contas_auth_orfas projeta created_at estruturado fiel ao timestamp de auth.users'
);

-- ── 5. Prova de Volume em Massa: Lista Todas sem LIMIT (Lote de 65 contas) ────
select is(
  (select count(*)::int from privado.contas_auth_orfas() where id::text like '70310000-0000-4000-8000-%'),
  65,
  'contas_auth_orfas lista todas as 65 contas do lote em massa sem limite nem paginacao silenciosa de 50'
);

select * from finish();
rollback;
