-- Recusas criticas e regras do contrato lote 10 (08/10/2026).
--
-- Cobertura do encerramento das recusas da API:
-- 1. criarConta (401 nao_autenticado - chamador sem sessao)
-- 2. criarConta (401 nao_autenticado - sem email confirmado em auth.users)
-- 3. candidatar com conta suspensa comprova 422 inelegivel (RN13) e isencao do 403
-- 4. registrarDispositivo com conta suspensa comprova 200 OK (RN15) e isencao do 403
-- 5. removerDispositivo (401 nao_autenticado - chamador sem sessao)
--
-- Ids proprios comecando em `c4950000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(5);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, case when email is not null then now() else null end,
          '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
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

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create temp table ids as select
  'c4950000-0000-4000-8000-000000000001'::uuid as usuario_sem_email_id,
  'c4950000-0000-4000-8000-000000000002'::uuid as usuario_suspenso_id,
  'c4950000-0000-4000-8000-000000000003'::uuid as contratante_id,
  'c4950000-0000-4000-8000-000000000004'::uuid as vaga_id;

select pg_temp.autenticar((select usuario_sem_email_id from ids), null);
select pg_temp.autenticar((select usuario_suspenso_id from ids), 'suspenso495@test.local');
select pg_temp.autenticar((select contratante_id from ids), 'contratante495@test.local');

-- Cria contratante e vaga para o teste de candidatura
select pg_temp.como((select contratante_id from ids),
  $$ select public.criar_conta('contratante','Contratante 495','+5561911114951','1985-01-01','2026-09-22') $$);

create temp table estab as select (pg_temp.como((select contratante_id from ids),
  $$ select public.cadastrar_estabelecimento('Bar 495','29979036000140','food_service','CLN 108','{"latitude":-15.7905,"longitude":-47.8855}') $$)->>'id')::uuid as id;

create temp table func as select id from public.funcao where nome = 'garçom';

create temp table v as select (pg_temp.como((select contratante_id from ids), format(
  $$ select public.publicar_vaga(%L::uuid, %L::uuid, now() + interval '48 hours', now() + interval '54 hours',
                                 'CLN 108', '{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
                                 16000::bigint, 1, false, false, false, 'Gerente 495', 'urgencia'::public.modo_preenchimento,
                                 gen_random_uuid(), 'camisa preta', false, null, 180, null) $$,
  (select id from estab), (select id from func)))->>'vaga_id')::uuid as id;

update ids set vaga_id = (select id from v);

-- Cria o usuario profissional suspenso
select pg_temp.como((select usuario_suspenso_id from ids),
  $$ select public.criar_conta('profissional','Profissional Suspenso 495','+5561911114952','1990-01-01','2026-09-22') $$);

select pg_temp.como((select usuario_suspenso_id from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$,
  (select id from func)));

select privado.suspender(
  (select usuario_suspenso_id from ids),
  'Suspensao para teste de contrato lote 10',
  (select contratante_id from ids)
);

-- 1. criarConta: 401 nao_autenticado (chamador sem sessao / anonimo)
select throws_ok(
  $$ select public.criar_conta('profissional', 'Teste Anonimo', '+5561999990001', '1990-01-01', '1.0') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '1. criarConta sem sessao recusa 401 nao_autenticado'
);

-- 2. criarConta: 401 nao_autenticado (chamador autenticado mas sem email confirmado)
select throws_ok(
  pg_temp.por((select usuario_sem_email_id from ids),
    $$ select public.criar_conta('profissional', 'Sem Email', '+5561999990002', '1990-01-01', '1.0') $$),
  'PGRST',
  pg_temp.erro('nao_autenticado', 'sem_email_confirmado'),
  '2. criarConta sem email confirmado em auth.users recusa 401 nao_autenticado'
);

-- 3. candidatar com conta suspensa comprova 422 inelegivel (RN13) e isencao do 403
select throws_ok(
  pg_temp.por((select usuario_suspenso_id from ids),
    format($$ select public.candidatar(%L::uuid) $$, (select vaga_id from ids))),
  'PGRST',
  pg_temp.erro('inelegivel', 'perfil_suspenso'),
  '3. candidatar com conta suspensa recusa 422 inelegivel (RN13) e nao 403'
);

-- 4. registrarDispositivo com conta suspensa comprova 200 OK (RN15) e isencao do 403
select lives_ok(
  pg_temp.por((select usuario_suspenso_id from ids),
    $$ select public.registrar_dispositivo('fcm_token_teste_harness_contrato_495_1234', 'android') $$),
  '4. registrarDispositivo com conta suspensa tem permissao (200 OK, RN15) e nao 403'
);

-- 5. removerDispositivo: 401 nao_autenticado (chamador sem sessao / anonimo)
select throws_ok(
  $$ select public.remover_dispositivo('fcm_token_teste_harness_contrato_495_1234') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '5. removerDispositivo sem sessao recusa 401 nao_autenticado'
);

rollback;
