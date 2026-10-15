-- Testes pgTAP de follow-up da auditoria de segurança (RF26, RN10, RN19, PR #184):
-- (a) `escolher_candidato` de candidatura inexistente vs bloqueada devolvem recusa idêntica (403 sem_permissao),
--     sem vazar a existência da candidatura ou do bloqueio mútuo.
-- (b) Fluxo legítimo sem bloqueio continua funcionando perfeitamente e devolve contato do profissional.

begin;
select plan(9);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agendador_secret = 'segredo-de-teste';
select set_config('frila.agora', '2027-07-01 12:00:00+00', true);

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

create function pg_temp.capturar_erro(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  begin
    execute sql into r;
  exception when others then
    reset role;
    execute 'reset request.jwt.claims';
    return jsonb_build_object('sqlstate', SQLSTATE, 'sqlerrm', SQLERRM);
  end;
  reset role;
  execute 'reset request.jwt.claims';
  return jsonb_build_object('sucesso', true, 'resultado', r);
end $$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create temp table ids as select
  'c6710000-0000-4000-8000-000000000001'::uuid as contratante_id,
  'c6710000-0000-4000-8000-000000000002'::uuid as prof_bloq1_user,
  'c6710000-0000-4000-8000-000000000003'::uuid as prof_bloq2_user,
  'c6710000-0000-4000-8000-000000000004'::uuid as prof_legitimo_user;

select pg_temp.autenticar((select contratante_id from ids),     'contratante671@test.local');
select pg_temp.autenticar((select prof_bloq1_user from ids),    'prof_bloq1_671@test.local');
select pg_temp.autenticar((select prof_bloq2_user from ids),    'prof_bloq2_671@test.local');
select pg_temp.autenticar((select prof_legitimo_user from ids), 'prof_legitimo_671@test.local');

select pg_temp.como((select contratante_id from ids),
  $$ select public.criar_conta('contratante','Dono Restaurante 671','+5561967100001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select prof_bloq1_user from ids),
  $$ select public.criar_conta('profissional','Profissional Bloqueador 1','+5561967100002','1995-01-01','2026-09-22') $$);
select pg_temp.como((select prof_bloq2_user from ids),
  $$ select public.criar_conta('profissional','Profissional Bloqueado 2','+5561967100003','1996-01-01','2026-09-22') $$);
select pg_temp.como((select prof_legitimo_user from ids),
  $$ select public.criar_conta('profissional','Profissional Legítimo','+5561967100004','1997-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select prof_bloq1_user from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como((select prof_bloq2_user from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como((select prof_legitimo_user from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

create temp table prof_ids as select
  (select id from public.profissional where usuario_id = (select prof_bloq1_user from ids)) as prof1_id,
  (select id from public.profissional where usuario_id = (select prof_bloq2_user from ids)) as prof2_id,
  (select id from public.profissional where usuario_id = (select prof_legitimo_user from ids)) as prof_legitimo_id;

create temp table casa as
  select (pg_temp.como((select contratante_id from ids),
    $$ select public.cadastrar_estabelecimento('Bistrô 671','04252011000110','food_service',
         'SCLN 105','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create temp table vaga_teste as
  select (pg_temp.como((select contratante_id from ids), format(
    $sql$ select public.publicar_vaga(%L, %L,
            '2027-07-10 18:00:00+00'::timestamptz, '2027-07-10 23:00:00+00'::timestamptz,
            'CLN 105', '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
            20000, 2, true, true, false, 'Dono 671', 'selecao',
            'd6710000-0000-4000-8000-000000000001'::uuid) $sql$,
    (select id from casa), (select garcom from fn)))->>'vaga_id')::uuid as id;

-- Candidaturas dos 3 profissionais
create temp table cand_bloq1 as
  select (pg_temp.como((select prof_bloq1_user from ids), format(
    $$ select public.candidatar(%L) $$, (select id from vaga_teste)))->>'candidatura_id')::uuid as id;

create temp table cand_bloq2 as
  select (pg_temp.como((select prof_bloq2_user from ids), format(
    $$ select public.candidatar(%L) $$, (select id from vaga_teste)))->>'candidatura_id')::uuid as id;

create temp table cand_legitimo as
  select (pg_temp.como((select prof_legitimo_user from ids), format(
    $$ select public.candidatar(%L) $$, (select id from vaga_teste)))->>'candidatura_id')::uuid as id;

-- Bloqueios mútuos:
-- 1. Profissional 1 bloqueia o estabelecimento
select pg_temp.como((select prof_bloq1_user from ids), format(
  $$ select public.bloquear('estabelecimento', %L) $$, (select id from casa)));

-- 2. Estabelecimento bloqueia o Profissional 2
select pg_temp.como((select contratante_id from ids), format(
  $$ select public.bloquear('profissional', %L) $$, (select prof2_id from prof_ids)));

-- ── (a) Recusa idêntica entre candidatura inexistente e bloqueada ──────────────
-- 1. Candidatura inexistente lança 403 sem_permissao
select throws_ok(
  format('select pg_temp.como(%L, %L)',
    (select contratante_id from ids),
    $$ select public.escolher_candidato('c6710000-0000-4000-8000-ffffffffffff'::uuid) $$),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '(a) escolher_candidato de candidatura inexistente recusa com 403 sem_permissao'
);

-- 2. Candidatura de profissional que bloqueou estabelecimento lança 403 sem_permissao
select throws_ok(
  format('select pg_temp.como(%L, %L)',
    (select contratante_id from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand_bloq1))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '(a) escolher_candidato de profissional com bloqueio ativo recusa com 403 sem_permissao'
);

-- 3. Prova estrita de equivalência exata do erro retornado
create temp table erro_inexistente as
  select pg_temp.capturar_erro((select contratante_id from ids),
    $$ select public.escolher_candidato('c6710000-0000-4000-8000-ffffffffffff'::uuid) $$) as r;

create temp table erro_bloqueado as
  select pg_temp.capturar_erro((select contratante_id from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand_bloq1))) as r;

select is(
  (select r from erro_inexistente),
  (select r from erro_bloqueado),
  '(a) o payload do erro de candidatura inexistente é estritamente idêntico ao de candidatura bloqueada'
);

-- 4. Sentido inverso: estabelecimento bloqueou profissional também devolve erro idêntico
create temp table erro_bloqueado_pela_casa as
  select pg_temp.capturar_erro((select contratante_id from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand_bloq2))) as r;

select is(
  (select r from erro_inexistente),
  (select r from erro_bloqueado_pela_casa),
  '(a) sentido inverso (casa bloqueou profissional) também devolve erro estritamente idêntico'
);

-- ── (b) Fluxo legítimo sem bloqueio confirma e devolve contato ────────────────
create temp table escolha_legitima as
  select pg_temp.como((select contratante_id from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand_legitimo))) as r;

-- 5. Sucesso na confirmação legítima
select is(
  (select r->>'estado' from escolha_legitima),
  'confirmada',
  '(b) fluxo legítimo: candidatura transita para confirmada'
);

-- 6. Resposta contém turno_id válido gerado
select is(
  ((select (r->>'turno_id')::uuid from escolha_legitima) is not null),
  true,
  '(b) fluxo legítimo: resposta traz o turno_id criado'
);

-- 7. Resposta devolve o contato do profissional (telefone e nome - RN10)
select is(
  (select r->'contato'->>'telefone' from escolha_legitima),
  '+5561967100004',
  '(b) fluxo legítimo: resposta traz o telefone de contato do profissional'
);

-- 8. Turno no banco possui o valor acordado da vaga
select is(
  (select valor_acordado_centavos from public.turno
    where id = (select (r->>'turno_id')::uuid from escolha_legitima)),
  20000::bigint,
  '(b) fluxo legítimo: o turno nasce com o valor acordado da vaga (RN11)'
);

-- 9. O profissional confirmado obtém o contato do estabelecimento via contato_do_turno (RN10)
select is(
  (select (pg_temp.como((select prof_legitimo_user from ids), format(
     $$ select public.contato_do_turno(%L) $$, (select (r->>'turno_id')::uuid from escolha_legitima)))->>'telefone')),
  '+5561967100001',
  '(b) fluxo legítimo: profissional confirmado obtém o contato do contratante via contato_do_turno'
);

select * from finish();
rollback;
