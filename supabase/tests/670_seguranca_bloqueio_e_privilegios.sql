-- Testes de segurança: bloqueio mútuo no modo seleção e concessões mínimas de privilégios
-- (Achados 1, 3 e 4 da auditoria de segurança - RF26, RN10, RN15, LGPD).
--
-- 1. `candidatos_da_vaga`: candidatos com bloqueio mútuo com o estabelecimento não aparecem na listagem.
-- 2. `escolher_candidato`: tentativa de escolher candidato com bloqueio mútuo é recusada com 403 sem_permissao.
-- 3. `privado.taxa_aceite_notificacoes_7d`: sem EXECUTE para authenticated e anon; concedido a service_role.
-- 4. `public.pedido_de_exclusao`: sem privilégios para public, anon e authenticated.

begin;
select plan(7);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agendador_secret = 'segredo-de-teste';
select set_config('frila.agora', '2027-06-01 12:00:00+00', true);

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

create temp table ids as select
  'c6700000-0000-4000-8000-000000000001'::uuid as contratante_id,
  'c6700000-0000-4000-8000-000000000002'::uuid as prof1_user,
  'c6700000-0000-4000-8000-000000000003'::uuid as prof2_user;

select pg_temp.autenticar((select contratante_id from ids), 'contratante670@test.local');
select pg_temp.autenticar((select prof1_user from ids),      'prof1_670@test.local');
select pg_temp.autenticar((select prof2_user from ids),      'prof2_670@test.local');

select pg_temp.como((select contratante_id from ids),
  $$ select public.criar_conta('contratante','Dono Restaurante 670','+5561967000001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select prof1_user from ids),
  $$ select public.criar_conta('profissional','Profissional Um Bloqueador','+5561967000002','1995-01-01','2026-09-22') $$);
select pg_temp.como((select prof2_user from ids),
  $$ select public.criar_conta('profissional','Profissional Dois Bloqueado','+5561967000003','1996-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select prof1_user from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como((select prof2_user from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

create temp table prof_ids as select
  (select id from public.profissional where usuario_id = (select prof1_user from ids)) as prof1_id,
  (select id from public.profissional where usuario_id = (select prof2_user from ids)) as prof2_id;

create temp table casa as
  select (pg_temp.como((select contratante_id from ids),
    $$ select public.cadastrar_estabelecimento('Bistrô 670','04252011000110','food_service',
         'SCLN 105','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- Cria vaga em modo seleção com 2 posições abertas
create temp table vaga_teste as
  select (pg_temp.como((select contratante_id from ids), format(
    $sql$ select public.publicar_vaga(%L, %L,
            '2027-06-05 18:00:00+00'::timestamptz, '2027-06-05 23:00:00+00'::timestamptz,
            'CLN 105', '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
            18000, 2, true, true, false, 'Dono 670', 'selecao',
            'd6700000-0000-4000-8000-000000000001'::uuid) $sql$,
    (select id from casa), (select garcom from fn)))->>'vaga_id')::uuid as id;

-- Profissional 1 e Profissional 2 se candidatam
create temp table cand1 as
  select (pg_temp.como((select prof1_user from ids), format(
    $$ select public.candidatar(%L) $$, (select id from vaga_teste)))->>'candidatura_id')::uuid as id;

create temp table cand2 as
  select (pg_temp.como((select prof2_user from ids), format(
    $$ select public.candidatar(%L) $$, (select id from vaga_teste)))->>'candidatura_id')::uuid as id;

-- Profissional 1 bloqueia o Estabelecimento
select pg_temp.como((select prof1_user from ids), format(
  $$ select public.bloquear('estabelecimento', %L) $$, (select id from casa)));

-- ── 1. candidatos_da_vaga não deve listar Profissional 1 (bloqueado com a casa) ─
select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.como((select contratante_id from ids), format(
            $$ select public.candidatos_da_vaga(%L) $$, (select id from vaga_teste)))) elem
    where (elem->'profissional'->>'id')::uuid = (select prof1_id from prof_ids)),
  0,
  'candidatos_da_vaga oculta candidato cujo profissional bloqueou o estabelecimento'
);

-- ── 2. candidatos_da_vaga lista normalmente Profissional 2 (sem bloqueio) ──────
select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.como((select contratante_id from ids), format(
            $$ select public.candidatos_da_vaga(%L) $$, (select id from vaga_teste)))) elem
    where (elem->'profissional'->>'id')::uuid = (select prof2_id from prof_ids)),
  1,
  'candidatos_da_vaga mantém candidato sem bloqueio ativo'
);

-- ── 3. escolher_candidato rejeita com 403 sem_permissao para Profissional 1 ────
select throws_ok(
  format('select pg_temp.como(%L, %L)',
    (select contratante_id from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand1))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  'escolher_candidato rejeita candidatura de profissional que bloqueou o estabelecimento'
);

-- ── 4. Sentido inverso: Estabelecimento bloqueia Profissional 2 ────────────────
select pg_temp.como((select contratante_id from ids), format(
  $$ select public.bloquear('profissional', %L) $$, (select prof2_id from prof_ids)));

-- ── 5. candidatos_da_vaga agora fica vazio (ambos os profissionais bloqueados) ─
select is(
  jsonb_array_length(pg_temp.como((select contratante_id from ids), format(
    $$ select public.candidatos_da_vaga(%L) $$, (select id from vaga_teste)))),
  0,
  'candidatos_da_vaga oculta candidato bloqueado pelo estabelecimento'
);

-- ── 6. escolher_candidato rejeita Profissional 2 (bloqueado pela casa) ──────────
select throws_ok(
  format('select pg_temp.como(%L, %L)',
    (select contratante_id from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand2))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  'escolher_candidato rejeita candidatura quando estabelecimento bloqueou o profissional'
);

-- ── 7. Achado 3: privado.taxa_aceite_notificacoes_7d restrita a service_role ───
select ok(
  not has_function_privilege('authenticated', 'privado.taxa_aceite_notificacoes_7d()', 'execute')
  and not has_function_privilege('anon', 'privado.taxa_aceite_notificacoes_7d()', 'execute')
  and has_function_privilege('service_role', 'privado.taxa_aceite_notificacoes_7d()', 'execute'),
  'privado.taxa_aceite_notificacoes_7d sem execute para authenticated/anon e concedido a service_role'
);

-- ── 8. Achado 4: public.pedido_de_exclusao sem privilégios para public/anon/authenticated
select ok(
  not has_table_privilege('public', 'public.pedido_de_exclusao', 'select')
  and not has_table_privilege('public', 'public.pedido_de_exclusao', 'insert')
  and not has_table_privilege('anon', 'public.pedido_de_exclusao', 'select')
  and not has_table_privilege('authenticated', 'public.pedido_de_exclusao', 'select'),
  'public.pedido_de_exclusao sem privilegios concedidos a public, anon ou authenticated'
);

select * from finish();
rollback;
