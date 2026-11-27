-- 906_rate_limit_e_revogacao_pontual_auth.sql
--
-- As três funções internas de auth (as Edge Functions chamam duas por SQL; a sessao_eh_pre_corte é chamada por funções SQL,
-- 20261124235000:168 e :201 e 20261125210000:65) e que nenhum teste cobria
-- (definição vigente: 20261124235000_autenticacao_dispositivo_confiavel_30d.sql; só teste, nada de código muda):
--   A  privado.consumir_rate_limit_auth(chave, limite, janela_s): N passa e N+1 recusa, a recusa persiste, chaves
--      independentes, virada de janela, janela própria e a limpeza de linhas com mais de 1 h
--   B  privado.revogar_sessao_pontual(session_id, usuario_id): só apaga a sessão do dono (auth.sessions e
--      privado.sessoes_verificadas); com o usuario_id de outra conta não apaga nada; id nulo ou inexistente não falha
--   C  privado.sessao_eh_pre_corte(session_id, usuario_id): só é pré-corte se há corte, a sessão é do usuário e foi
--      criada ESTRITAMENTE antes do corte
--   D  anon e authenticated não executam nenhuma das três
-- Só dados sintéticos; tudo dentro da transação.
begin;
select plan(42);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- 26/11/2026, 15:00:00 UTC: início de uma janela de 600 s (a de 10 min do padrão) e de 60 s.
select set_config('frila.agora', '2026-11-26 15:00:00+00', true);

-- ── D. Privilégios ────────────────────────────────────────────────────────────

select ok(
  not has_function_privilege('anon', 'privado.consumir_rate_limit_auth(text, integer, integer)', 'execute')
  and not has_function_privilege('authenticated', 'privado.consumir_rate_limit_auth(text, integer, integer)', 'execute'),
  'D1 consumir_rate_limit_auth não é executável por anon nem por authenticated');

select ok(
  not has_function_privilege('anon', 'privado.revogar_sessao_pontual(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'privado.revogar_sessao_pontual(uuid, uuid)', 'execute'),
  'D2 revogar_sessao_pontual não é executável por anon nem por authenticated');

select ok(
  not has_function_privilege('anon', 'privado.sessao_eh_pre_corte(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'privado.sessao_eh_pre_corte(uuid, uuid)', 'execute'),
  'D3 sessao_eh_pre_corte não é executável por anon nem por authenticated');

-- D4 a D6: o 42501 pode vir do USAGE no schema privado (anon não o tem); quem trava o EXECUTE de cada função é o
-- has_function_privilege de D1 a D3. Os três abaixo confirmam o efeito visto de fora.
create function pg_temp.sqlstate_como(papel text, sql text) returns text language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
  return 'ok';
exception when others then
  reset role;
  return sqlstate;
end $$;

select is(pg_temp.sqlstate_como('authenticated', $$ select privado.consumir_rate_limit_auth('x', 1, 600) $$), '42501',
  'D4 authenticated chamando consumir_rate_limit_auth recebe permission denied');
select is(pg_temp.sqlstate_como('authenticated',
  $$ select privado.revogar_sessao_pontual('c1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001') $$),
  '42501', 'D5 authenticated chamando revogar_sessao_pontual recebe permission denied');
select is(pg_temp.sqlstate_como('anon',
  $$ select privado.sessao_eh_pre_corte('c1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001') $$),
  '42501', 'D6 anon chamando sessao_eh_pre_corte recebe permission denied');

-- ── A. Rate limit ─────────────────────────────────────────────────────────────

select is(privado.consumir_rate_limit_auth('login:a', 3), true,  'A1 1ª tentativa de 3 passa');
select is(privado.consumir_rate_limit_auth('login:a', 3), true,  'A2 2ª tentativa de 3 passa');
select is(privado.consumir_rate_limit_auth('login:a', 3), true,  'A3 3ª tentativa de 3 (o limite) ainda passa');
select is(privado.consumir_rate_limit_auth('login:a', 3), false, 'A4 4ª tentativa (N+1) é recusada');
select is(privado.consumir_rate_limit_auth('login:a', 3), false, 'A5 a recusa persiste na mesma janela');

select is(
  (select contagem from privado.rate_limit_auth where chave = 'login:a'), 5,
  'A6 a contagem da janela é de 5 (cada tentativa conta, inclusive as recusadas)');

select is(privado.consumir_rate_limit_auth('login:b', 3), true,
  'A7 outra chave tem a própria contagem e passa');

select is(privado.consumir_rate_limit_auth('login:um', 1), true,  'A8 limite 1: a 1ª passa');
select is(privado.consumir_rate_limit_auth('login:um', 1), false, 'A9 limite 1: a 2ª é recusada');

-- Virada de janela (padrão de 600 s: 15:00:00 a 15:09:59 é uma janela só).
select set_config('frila.agora', '2026-11-26 15:09:59+00', true);
select is(privado.consumir_rate_limit_auth('login:a', 3), false,
  'A10 no último segundo da janela a chave esgotada continua recusada');

select set_config('frila.agora', '2026-11-26 15:10:00+00', true);
select is(privado.consumir_rate_limit_auth('login:a', 3), true,
  'A11 na virada da janela a chave volta a passar');
select is(
  (select contagem from privado.rate_limit_auth where chave = 'login:a' and janela = '2026-11-26 15:10:00+00'), 1,
  'A12 a janela nova começa em 1');
select is(
  (select contagem from privado.rate_limit_auth where chave = 'login:a' and janela = '2026-11-26 15:00:00+00'), 6,
  'A13 a janela anterior fica como estava (5 + a recusa do A10)');

-- Janela própria de 60 s.
select set_config('frila.agora', '2026-11-26 16:00:00+00', true);
select is(privado.consumir_rate_limit_auth('otp:x', 1, 60), true,  'A14 janela de 60 s: a 1ª passa');
select is(privado.consumir_rate_limit_auth('otp:x', 1, 60), false, 'A15 janela de 60 s: a 2ª é recusada');
select set_config('frila.agora', '2026-11-26 16:01:00+00', true);
select is(privado.consumir_rate_limit_auth('otp:x', 1, 60), true,  'A16 um minuto depois a janela de 60 s virou');

-- Limpeza: linha com mais de 1 h sai na próxima chamada; a recente fica.
insert into privado.rate_limit_auth (chave, janela, contagem) values
  ('velha', '2026-11-26 15:00:00+00', 9),
  ('recente', '2026-11-26 15:02:00+00', 9);
select privado.consumir_rate_limit_auth('qualquer', 5);
select is((select count(*) from privado.rate_limit_auth where chave = 'velha'), 0::bigint,
  'A17 a linha com mais de 1 h é apagada');
select is((select count(*) from privado.rate_limit_auth where chave = 'recente'), 1::bigint,
  'A18 a linha de menos de 1 h fica');

-- ── Fixture de contas e sessões (B e C) ───────────────────────────────────────

insert into auth.users (id, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
  ('a1000000-0000-4000-8000-000000000001', 'dona.906@frila.test',  '', '{}'::jsonb, '{}'::jsonb, now(), now()),
  ('a2000000-0000-4000-8000-000000000002', 'outra.906@frila.test', '', '{}'::jsonb, '{}'::jsonb, now(), now());

insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('c1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', '2026-11-20 12:00:00+00', '2026-11-20 12:00:00+00'),
  ('c2000000-0000-4000-8000-000000000002', 'a2000000-0000-4000-8000-000000000002', '2026-11-20 12:00:00+00', '2026-11-20 12:00:00+00');

insert into privado.sessoes_verificadas (session_id, usuario_id, dispositivo_id) values
  ('c1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001', null),
  ('c2000000-0000-4000-8000-000000000002', 'a2000000-0000-4000-8000-000000000002', null);

-- ── B. Revogação pontual ──────────────────────────────────────────────────────

select privado.revogar_sessao_pontual('c1000000-0000-4000-8000-000000000001', 'a2000000-0000-4000-8000-000000000002');

select is((select count(*) from auth.sessions where id = 'c1000000-0000-4000-8000-000000000001'), 1::bigint,
  'B1 revogar com o usuario_id de OUTRA conta não apaga a sessão de auth');
select is((select count(*) from privado.sessoes_verificadas where session_id = 'c1000000-0000-4000-8000-000000000001'), 1::bigint,
  'B2 revogar com o usuario_id de OUTRA conta não apaga a verificação da sessão');

select privado.revogar_sessao_pontual(null, 'a1000000-0000-4000-8000-000000000001');
select is((select count(*) from auth.sessions where user_id = 'a1000000-0000-4000-8000-000000000001'), 1::bigint,
  'B3 session_id nulo não falha e não apaga nada');

create temp table n_sessoes as select count(*) as n from auth.sessions;
create temp table n_verif as select count(*) as n from privado.sessoes_verificadas;
select privado.revogar_sessao_pontual('c9000000-0000-4000-8000-000000000009', 'a1000000-0000-4000-8000-000000000001');
select is((select count(*) from auth.sessions), (select n from n_sessoes),
  'B4 sessão inexistente não falha e não apaga nenhuma outra');
select is((select count(*) from privado.sessoes_verificadas), (select n from n_verif),
  'B4b sessão inexistente não apaga nenhuma verificação');

-- 2ª sessão da MESMA dona: a revogação é pontual, esta tem de ficar.
insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('c6000000-0000-4000-8000-000000000006', 'a1000000-0000-4000-8000-000000000001', '2026-11-20 12:00:00+00', '2026-11-20 12:00:00+00');
insert into privado.sessoes_verificadas (session_id, usuario_id, dispositivo_id) values
  ('c6000000-0000-4000-8000-000000000006', 'a1000000-0000-4000-8000-000000000001', null);

select privado.revogar_sessao_pontual('c1000000-0000-4000-8000-000000000001', 'a1000000-0000-4000-8000-000000000001');
select is((select count(*) from auth.sessions where id = 'c1000000-0000-4000-8000-000000000001'), 0::bigint,
  'B5 revogar com o dono apaga a sessão de auth');
select is((select count(*) from privado.sessoes_verificadas where session_id = 'c1000000-0000-4000-8000-000000000001'), 0::bigint,
  'B6 revogar com o dono apaga a verificação da sessão');
select is((select count(*) from auth.sessions where id = 'c2000000-0000-4000-8000-000000000002'), 1::bigint,
  'B7 a sessão da outra conta continua');
select is((select count(*) from privado.sessoes_verificadas where session_id = 'c2000000-0000-4000-8000-000000000002'), 1::bigint,
  'B8 a verificação da outra conta continua');

select is((select count(*) from auth.sessions where id = 'c6000000-0000-4000-8000-000000000006'), 1::bigint,
  'B9 a outra sessão da MESMA dona continua no auth');
select is((select count(*) from privado.sessoes_verificadas where session_id = 'c6000000-0000-4000-8000-000000000006'), 1::bigint,
  'B10 a outra sessão da MESMA dona continua verificada');

-- ── C. Pré-corte ──────────────────────────────────────────────────────────────

insert into auth.sessions (id, user_id, created_at, updated_at) values
  ('c3000000-0000-4000-8000-000000000003', 'a1000000-0000-4000-8000-000000000001', '2026-11-25 10:00:00+00', '2026-11-25 10:00:00+00'),
  ('c4000000-0000-4000-8000-000000000004', 'a1000000-0000-4000-8000-000000000001', '2026-11-26 10:00:00+00', '2026-11-26 10:00:00+00'),
  ('c5000000-0000-4000-8000-000000000005', 'a1000000-0000-4000-8000-000000000001', '2026-11-26 09:00:00+00', '2026-11-26 09:00:00+00');

update privado.config_auth set corte_sessoes_anteriores_em = null where unica;
select is(privado.sessao_eh_pre_corte('c3000000-0000-4000-8000-000000000003', 'a1000000-0000-4000-8000-000000000001'), false,
  'C1 sem corte configurado nenhuma sessão é pré-corte');

update privado.config_auth set corte_sessoes_anteriores_em = '2026-11-26 09:00:00+00' where unica;
select is(privado.sessao_eh_pre_corte('c3000000-0000-4000-8000-000000000003', 'a1000000-0000-4000-8000-000000000001'), true,
  'C2 sessão criada antes do corte é pré-corte');
select is(privado.sessao_eh_pre_corte('c4000000-0000-4000-8000-000000000004', 'a1000000-0000-4000-8000-000000000001'), false,
  'C3 sessão criada depois do corte não é pré-corte');
select is(privado.sessao_eh_pre_corte('c5000000-0000-4000-8000-000000000005', 'a1000000-0000-4000-8000-000000000001'), false,
  'C4 sessão criada exatamente no instante do corte não é pré-corte (estritamente antes)');
select is(privado.sessao_eh_pre_corte('c3000000-0000-4000-8000-000000000003', 'a2000000-0000-4000-8000-000000000002'), false,
  'C5 com o usuario_id de outra conta a sessão não é pré-corte');
select is(privado.sessao_eh_pre_corte(null, 'a1000000-0000-4000-8000-000000000001'), false,
  'C6 session_id nulo não é pré-corte');
select is(privado.sessao_eh_pre_corte('c9000000-0000-4000-8000-000000000009', 'a1000000-0000-4000-8000-000000000001'), false,
  'C7 sessão inexistente não é pré-corte');

select * from finish();
rollback;
