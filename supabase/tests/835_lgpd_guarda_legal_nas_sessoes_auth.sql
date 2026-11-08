-- 835_lgpd_guarda_legal_nas_sessoes_auth.sql · LGPD-J6, brief B-GUARDA (migração 20261108230000).
-- A etapa (c) de privado.limpar_trilha_e_sessoes_auth (#442) pula as sessões das contas em guarda legal vigente
-- (privado.registro_acesso_guarda, Marco Civil art. 15, § 2º), pelo mesmo predicado de privado.limpar_registros_acesso
-- (#449): a guarda vale de desde, inclusive, até ate, exclusive. Sem guarda, com a guarda vencida ou ainda por
-- começar, a sessão parada há mais de 6 meses sai, como no #442.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-08 12:00:00+00', true);
select plan(13);

-- Base limpa dentro da transação (desfeita no fim): só as linhas deste teste contam.
delete from auth.sessions;
delete from privado.registro_acesso_guarda;

-- Contas sintéticas: 01 em guarda vigente, 02 sem guarda, 03 com a guarda vencida, 04 com a guarda por começar,
-- 05 com a guarda que começa agora, 06 com a guarda que termina agora, 07 com uma guarda vencida e outra vigente.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c8350000-0000-4000-8000-00000000000' || n)::uuid, 'authenticated',
       'authenticated', 'u' || n || '@t835.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 7) n;

insert into privado.registro_acesso_guarda (usuario_id, desde, ate, referencia) values
  ('c8350000-0000-4000-8000-000000000001', privado.agora() - interval '1 month', privado.agora() + interval '1 year', 'T835-vigente'),
  ('c8350000-0000-4000-8000-000000000003', privado.agora() - interval '1 year', privado.agora() - interval '1 day', 'T835-vencida'),
  ('c8350000-0000-4000-8000-000000000004', privado.agora() + interval '1 day', privado.agora() + interval '1 year', 'T835-futura'),
  ('c8350000-0000-4000-8000-000000000005', privado.agora(), privado.agora() + interval '1 year', 'T835-comeca-agora'),
  ('c8350000-0000-4000-8000-000000000006', privado.agora() - interval '1 year', privado.agora(), 'T835-termina-agora'),
  ('c8350000-0000-4000-8000-000000000007', privado.agora() - interval '2 years', privado.agora() - interval '1 year', 'T835-velha'),
  ('c8350000-0000-4000-8000-000000000007', privado.agora() - interval '1 day', privado.agora() + interval '1 month', 'T835-nova');

-- Uma sessão parada há 7 meses por conta (criada há 1 ano, renovada e atualizada há 7 meses), cada uma com um
-- refresh_token. A conta 01 tem ainda uma sessão recente, que fica de todo jeito.
create function pg_temp.sessao(conta int, id uuid, parada interval) returns void language sql as $$
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, ip)
  values (id, ('c8350000-0000-4000-8000-00000000000' || conta)::uuid, privado.agora() - interval '1 year',
          privado.agora() - parada, (privado.agora() - parada) at time zone 'UTC', '203.0.113.32');
  insert into auth.refresh_tokens (instance_id, token, user_id, revoked, created_at, updated_at, session_id)
  values ('00000000-0000-0000-0000-000000000000', 'zz835-' || id::text,
          ('c8350000-0000-4000-8000-00000000000' || conta)::text, false,
          privado.agora() - parada, privado.agora() - parada, id);
$$;
create function pg_temp.tem_sessao(id uuid) returns boolean language sql as $$
  select exists (select 1 from auth.sessions s where s.id = tem_sessao.id)
$$;
create function pg_temp.tem_token(id uuid) returns boolean language sql as $$
  select exists (select 1 from auth.refresh_tokens t where t.session_id = tem_token.id)
$$;

select pg_temp.sessao(n, ('c8350000-0000-4000-8000-0000000000b' || n)::uuid, interval '7 months')
  from generate_series(1, 7) n;
select pg_temp.sessao(1, 'c8350000-0000-4000-8000-0000000000c1', interval '1 day');

-- ── A rodada ─────────────────────────────────────────────────────────────────
create temp table r as select privado.limpar_trilha_e_sessoes_auth() as j;
select results_eq($$ select (j->>'sessoes_paradas')::int, j->'falhas' from r $$,
  $$ values (4, '[]'::jsonb) $$, 'apaga só as 4 sessões paradas sem guarda vigente, sem falha');

-- Positiva: a guarda vigente segura a sessão e o refresh_token.
select ok(pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b1'),
  'conta em guarda vigente: a sessão parada há 7 meses fica');
select ok(pg_temp.tem_token('c8350000-0000-4000-8000-0000000000b1'),
  'conta em guarda vigente: o refresh_token da sessão fica');
select ok(pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000c1'),
  'conta em guarda vigente: a sessão recente fica');
select ok(pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b5'),
  'borda: a guarda que começa agora (desde = agora) já vale, e a sessão fica');
select ok(pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b7'),
  'conta com uma guarda vencida e outra vigente: vale a vigente, e a sessão fica');

-- Negativas: sem guarda vigente, a sessão parada sai, com o refresh_token em cascata.
select ok(not pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b2'),
  'conta sem guarda: a sessão parada há 7 meses sai');
select ok(not pg_temp.tem_token('c8350000-0000-4000-8000-0000000000b2'),
  'conta sem guarda: o refresh_token cai em cascata');
select ok(not pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b3'),
  'conta com a guarda vencida: a sessão parada sai');
select ok(not pg_temp.tem_token('c8350000-0000-4000-8000-0000000000b3'),
  'conta com a guarda vencida: o refresh_token cai em cascata');
select ok(not pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b4'),
  'conta com a guarda por começar (desde amanhã): a sessão parada sai');
select ok(not pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b6'),
  'borda: a guarda que termina agora (ate = agora) já não vale, e a sessão sai');

-- A guarda que venceu deixa a sessão sair na rodada seguinte.
update privado.registro_acesso_guarda set ate = privado.agora() - interval '1 second'
 where usuario_id = 'c8350000-0000-4000-8000-000000000001';
select is((privado.limpar_trilha_e_sessoes_auth() ->> 'sessoes_paradas')::int, 1,
  'vencida a guarda da conta 01, a sessão parada dela sai na rodada seguinte');

select * from finish();
rollback;
