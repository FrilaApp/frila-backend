-- 703_contas_auth_orfas.sql
-- Cobertura pgTAP de privado.contas_auth_orfas(integer) (UC09 2a, RF25, Item 11).
begin;
set local timezone = 'UTC';
select plan(11);

-- ── 1. Metadados e Privilégios Mínimos ───────────────────────────────────────
select has_function('privado', 'contas_auth_orfas', array['integer'], 'funcao existe');
select is_definer('privado', 'contas_auth_orfas', array['integer'], 'funcao e SECURITY DEFINER');
select ok((select proconfig from pg_proc where proname = 'contas_auth_orfas' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'], 'search_path vazio');
select is(has_function_privilege('service_role', 'privado.contas_auth_orfas(integer)', 'execute'), true, 'service_role pode executar');
select is(has_function_privilege('authenticated', 'privado.contas_auth_orfas(integer)', 'execute'), false, 'authenticated nao executa');
select is(has_function_privilege('anon', 'privado.contas_auth_orfas(integer)', 'execute'), false, 'anon nao executa');

-- ── 2. Setup Temporal e Contas de Teste (Padrão 694 + TESTES-PGTAP-PADROES) ──
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous) values
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'orfa1@teste.com', '2026-10-19 06:00:00+00', '2026-10-19 06:00:00+00', false, false),
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'orfa2@teste.com', '2026-10-20 02:00:00+00', '2026-10-20 02:00:00+00', false, false),
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'ativa@teste.com', '2026-10-19 06:00:00+00', '2026-10-19 06:00:00+00', false, false),
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'anon@teste.com',  '2026-10-19 06:00:00+00', '2026-10-19 06:00:00+00', false, false),
  ('00000000-0000-0000-0000-000000000000', '70300000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'orfa3@teste.com', '2026-10-18 12:00:00+00', '2026-10-18 12:00:00+00', false, false);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado, anonimizado_em) values
  ('70300000-0000-4000-8000-000000000003', 'profissional', 'Usuario Ativo', '+5561970300003', 'ativa@teste.com', '1995-01-01', '2026-09-22', '2026-10-19 06:00:00+00', 'ativa', null),
  ('70300000-0000-4000-8000-000000000004', 'profissional', 'Conta encerrada', null, null, '1995-01-01', '2026-09-22', '2026-10-19 06:00:00+00', 'anonimizada', '2026-10-19 12:00:00+00');

-- ── 3. Comportamento e Caracterização (Lista Todas, 24h, Órfãs e Item 11) ──────
select set_eq(
  $$ select id::text from privado.contas_auth_orfas() where id in (
       '70300000-0000-4000-8000-000000000001', '70300000-0000-4000-8000-000000000002', '70300000-0000-4000-8000-000000000003', '70300000-0000-4000-8000-000000000004', '70300000-0000-4000-8000-000000000005'
     ) $$,
  array['70300000-0000-4000-8000-000000000001', '70300000-0000-4000-8000-000000000005'],
  'contas_auth_orfas lista todas as orfas com >24h sem limite e ignora <24h e cadastradas'
);

-- Borda da retenção: janela menor (8 horas) inclui a órfã de 10 horas
select is(
  (select count(*)::int from privado.contas_auth_orfas(8) where id = '70300000-0000-4000-8000-000000000002'),
  1, 'contas_auth_orfas respeita parametro p_horas capturando conta na nova janela'
);

-- Conta ativa concluída NÃO é pega
select is(
  (select count(*)::int from privado.contas_auth_orfas() where id = '70300000-0000-4000-8000-000000000003'),
  0, 'conta com cadastro ativo em public.usuario nao e retornada'
);

-- Caracterização do Item 11 do Painel: conta anonimizada com credencial viva NÃO é pega
select is(
  (select count(*)::int from privado.contas_auth_orfas() where id = '70300000-0000-4000-8000-000000000004'),
  0, 'Item 11: conta anonimizada com credencial viva NAO e orfa (tem linha em public.usuario)'
);

-- Retorno estruturado das colunas (id, created_at)
select is(
  (select created_at from privado.contas_auth_orfas() where id = '70300000-0000-4000-8000-000000000001'),
  '2026-10-19 06:00:00+00'::timestamptz,
  'contas_auth_orfas retorna created_at fiel da credencial de auth.users'
);

select * from finish();
rollback;
