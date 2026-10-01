-- Recusas por conta suspensa e perfil incompativel em presença e vaga (RN13, RN25).
--
-- O contrato OpenAPI declara para:
--   - `/rpc/cancelar_vaga`: 403 sem_permissao (conta_suspensa)
--   - `/rpc/fazer_checkin`: 403 sem_permissao (conta_suspensa)
--   - `/rpc/fazer_checkout`: 403 sem_permissao (conta_suspensa)
-- O código já aplicava `privado.exigir_conta_ativa()`, mas não havia asserção pgTAP
-- testando a recusa em cada uma dessas operações.
--
-- Ids próprios, começando em `c5700000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(5);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2027-04-01 12:00:00+00', true);

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create temp table ids as select
  'c5700000-0000-4000-8000-0000000000d1'::uuid as dona,
  'c5700000-0000-4000-8000-0000000000d2'::uuid as dona_suspensa,
  'c5700000-0000-4000-8000-0000000000e1'::uuid as prof,
  'c5700000-0000-4000-8000-0000000000e2'::uuid as prof_suspenso;

select pg_temp.autenticar((select dona from ids),          'dona@c57.test');
select pg_temp.autenticar((select dona_suspensa from ids), 'dona-suspensa@c57.test');
select pg_temp.autenticar((select prof from ids),          'prof@c57.test');
select pg_temp.autenticar((select prof_suspenso from ids), 'prof-suspenso@c57.test');

select pg_temp.como((select dona from ids),
  $$ select public.criar_conta('contratante','Dona Ativa','+5561957000001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select dona_suspensa from ids),
  $$ select public.criar_conta('contratante','Dona Suspensa','+5561957000002','1980-01-01','2026-09-22') $$);
select pg_temp.como((select prof from ids),
  $$ select public.criar_conta('profissional','Profissional Ativo','+5561957000003','1995-01-01','2026-09-22') $$);
select pg_temp.como((select prof_suspenso from ids),
  $$ select public.criar_conta('profissional','Profissional Suspenso','+5561957000004','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select prof from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como((select prof_suspenso from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

update public.usuario set estado = 'suspensa' where id in ((select dona_suspensa from ids), (select prof_suspenso from ids));

create temp table casa as
  select (pg_temp.como((select dona from ids),
    $$ select public.cadastrar_estabelecimento('Casa do Teste 570','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create function pg_temp.publicar(chave uuid) returns uuid
language sql as $$
  select (pg_temp.como((select dona from ids), format(
    $sql$ select public.publicar_vaga(%L, %L,
         '2027-04-03 21:00:00+00'::timestamptz, '2027-04-04 03:00:00+00'::timestamptz,
         'CLN 406', '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Seu Zé', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn), chave))->>'vaga_id')::uuid;
$$;

create temp table v as select
  pg_temp.publicar('c5700000-0000-4000-8000-000000000001') as id;

create temp table t as select
  (pg_temp.como((select prof from ids),
     format($$ select public.candidatar(%L) $$, (select id from v)))->>'turno_id')::uuid as id;

-- ── 1. Conta suspensa tentando cancelar vaga (403) ───────────────────────────
select throws_ok(
  pg_temp.por((select dona_suspensa from ids),
    format($$ select public.cancelar_vaga(%L, 'imprevisto') $$, (select id from v))),
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'cancelar_vaga por conta suspensa é 403 sem_permissao, details conta_suspensa (RN13)');

-- ── 2. Conta suspensa tentando fazer check-in (403) ──────────────────────────
select throws_ok(
  pg_temp.por((select prof_suspenso from ids),
    format($$ select public.fazer_checkin(%L, 50, now()) $$, (select id from t))),
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'fazer_checkin por conta suspensa é 403 sem_permissao, details conta_suspensa (RN13)');

-- ── 3. Conta suspensa tentando fazer check-out (403) ─────────────────────────
select throws_ok(
  pg_temp.por((select prof_suspenso from ids),
    format($$ select public.fazer_checkout(%L, 50, now()) $$, (select id from t))),
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'fazer_checkout por conta suspensa é 403 sem_permissao, details conta_suspensa (RN13)');

-- ── 4. Profissional tentando cancelar vaga (422 perfil_incompativel) ─────────
select throws_ok(
  pg_temp.por((select prof from ids),
    format($$ select public.cancelar_vaga(%L, 'imprevisto') $$, (select id from v))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'cancelar_vaga por profissional é 422 perfil_incompativel');

-- ── 5. Dona ativa cancelando vaga com sucesso (200) ──────────────────────────
select lives_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.cancelar_vaga(%L, 'evento cancelado') $$, (select id from v))),
  'dona ativa cancela a vaga com sucesso');

select * from finish();
rollback;
