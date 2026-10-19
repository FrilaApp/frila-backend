-- Recusas do modo seleção por perfil incompatível, conta suspensa e alvo inexistente (RN13, RN24, RN25).
--
-- O contrato OpenAPI declara para:
--   - `/rpc/candidatos_da_vaga`: 401, 403 sem_permissao (conta_suspensa), 404
--   - `/rpc/escolher_candidato`: 401, 403, 409, 422 perfil_incompativel
--   - `/rpc/retirar_candidatura`: 401, 404 nao_encontrado, 409, 422 perfil_incompativel
--
-- Ids próprios, começando em `c5800000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(6);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2027-05-01 12:00:00+00', true);

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
  'c5800000-0000-4000-8000-0000000000d1'::uuid as dona,
  'c5800000-0000-4000-8000-0000000000d2'::uuid as dona_suspensa,
  'c5800000-0000-4000-8000-0000000000e1'::uuid as prof1,
  'c5800000-0000-4000-8000-0000000000e2'::uuid as prof2;

select pg_temp.autenticar((select dona from ids),          'dona@c58.test');
select pg_temp.autenticar((select dona_suspensa from ids), 'dona-suspensa@c58.test');
select pg_temp.autenticar((select prof1 from ids),         'prof1@c58.test');
select pg_temp.autenticar((select prof2 from ids),         'prof2@c58.test');

select pg_temp.como((select dona from ids),
  $$ select public.criar_conta('contratante','Dona da Seleção','+5561958000001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select dona_suspensa from ids),
  $$ select public.criar_conta('contratante','Dona Suspensa','+5561958000002','1980-01-01','2026-09-22') $$);
select pg_temp.como((select prof1 from ids),
  $$ select public.criar_conta('profissional','Profissional Um','+5561958000003','1995-01-01','2026-09-22') $$);
select pg_temp.como((select prof2 from ids),
  $$ select public.criar_conta('profissional','Profissional Dois','+5561958000004','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select prof1 from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como((select prof2 from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

update public.usuario set estado = 'suspensa' where id = (select dona_suspensa from ids);

create temp table casa as
  select (pg_temp.como((select dona from ids),
    $$ select public.cadastrar_estabelecimento('Casa da Seleção 580','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create function pg_temp.publicar(chave uuid) returns uuid
language sql as $$
  select (pg_temp.como((select dona from ids), format(
    $sql$ select public.publicar_vaga(%L, %L,
         '2027-05-04 21:00:00+00'::timestamptz, '2027-05-05 03:00:00+00'::timestamptz,
         'CLN 406', '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Seu Zé', 'selecao', %L) $sql$,
    (select id from casa), (select garcom from fn), chave))->>'vaga_id')::uuid;
$$;

create temp table v as select
  pg_temp.publicar('c5800000-0000-4000-8000-000000000001') as id;

-- O prof1 se candidata na vaga e cria uma candidatura pendente.
create temp table cand1 as select
  (pg_temp.como((select prof1 from ids),
     format($$ select public.candidatar(%L) $$, (select id from v)))->>'candidatura_id')::uuid as id;

-- ── 1. candidatos_da_vaga: perfil profissional recebe 422 perfil_incompativel ─
select throws_ok(
  pg_temp.por((select prof1 from ids),
    format($$ select public.candidatos_da_vaga(%L) $$, (select id from v))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'candidatos_da_vaga por profissional é 422 perfil_incompativel');

-- ── 2. candidatos_da_vaga: conta suspensa recebe 403 sem_permissao ───────────
select throws_ok(
  pg_temp.por((select dona_suspensa from ids),
    format($$ select public.candidatos_da_vaga(%L) $$, (select id from v))),
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'candidatos_da_vaga por conta suspensa é 403 sem_permissao, details conta_suspensa (RN13)');

-- ── 3. escolher_candidato: perfil profissional recebe 422 perfil_incompativel ─
select throws_ok(
  pg_temp.por((select prof1 from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand1))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'escolher_candidato por profissional é 422 perfil_incompativel');

-- ── 4. retirar_candidatura: perfil contratante recebe 422 perfil_incompativel ─
select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.retirar_candidatura(%L) $$, (select id from cand1))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'retirar_candidatura por contratante é 422 perfil_incompativel');

-- ── 5. retirar_candidatura: candidatura inexistente recebe 404 nao_encontrado ─
select throws_ok(
  pg_temp.por((select prof1 from ids),
    $$ select public.retirar_candidatura('c5800000-0000-4000-8000-ffffffffffff'::uuid) $$),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'retirar_candidatura de candidatura inexistente é 404 nao_encontrado');

-- ── 6. retirar_candidatura: candidatura de outro profissional é 404 ───────────
select throws_ok(
  pg_temp.por((select prof2 from ids),
    format($$ select public.retirar_candidatura(%L) $$, (select id from cand1))),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'retirar_candidatura de candidatura alheia é 404 nao_encontrado (não vaza existência)');

select * from finish();
rollback;
