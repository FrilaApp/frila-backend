-- 15 recusas criticas do contrato lote 3 (05/10/2026).
--
-- Cobre os 15 pares adicionais de recusa por risco do inventario /private/tmp/claude-502/recusas-nao-vigiadas-04-10.md:
-- 1.  confirmarCheckinManual (403 sem_permissao)
-- 2.  confirmarCheckinManual (404 nao_encontrado)
-- 3.  fazerCheckin (403 sem_permissao)
-- 4.  fazerCheckin (404 nao_encontrado)
-- 5.  fazerCheckout (403 sem_permissao)
-- 6.  fazerCheckout (404 nao_encontrado)
-- 7.  republicarVaga (403 sem_permissao)
-- 8.  republicarVaga (404 nao_encontrado)
-- 9.  detalheVaga (403 sem_permissao)
-- 10. detalheVaga (404 nao_encontrado)
-- 11. candidatosDaVaga (403 sem_permissao)
-- 12. candidatosDaVaga (404 nao_encontrado)
-- 13. incluirNaEquipe (403 sem_permissao)
-- 14. incluirNaEquipe (404 nao_encontrado)
-- 15. removerDaEquipe (403 sem_permissao)
--
-- Ids proprios comecando em `c4870000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(15);

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
  'c4870000-0000-4000-8000-000000000001'::uuid as contratante_dono,
  'c4870000-0000-4000-8000-000000000002'::uuid as contratante_outro,
  'c4870000-0000-4000-8000-000000000003'::uuid as profissional_1,
  'c4870000-0000-4000-8000-000000000004'::uuid as profissional_2,
  'c4870000-0000-4000-8000-000000000005'::uuid as profissional_suspenso;

select pg_temp.autenticar((select contratante_dono from ids), 'dono487@test.local');
select pg_temp.autenticar((select contratante_outro from ids), 'outro487@test.local');
select pg_temp.autenticar((select profissional_1 from ids), 'pro1_487@test.local');
select pg_temp.autenticar((select profissional_2 from ids), 'pro2_487@test.local');
select pg_temp.autenticar((select profissional_suspenso from ids), 'suspenso487@test.local');

-- Criacao de contas
select pg_temp.como((select contratante_dono from ids),
  $$ select public.criar_conta('contratante','Dono Casa 487','+5561948700001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select contratante_outro from ids),
  $$ select public.criar_conta('contratante','Outro Contratante 487','+5561948700002','1980-01-01','2026-09-22') $$);
select pg_temp.como((select profissional_1 from ids),
  $$ select public.criar_conta('profissional','Profissional 1 487','+5561948700003','1995-01-01','2026-09-22') $$);
select pg_temp.como((select profissional_2 from ids),
  $$ select public.criar_conta('profissional','Profissional 2 487','+5561948700004','1994-01-01','2026-09-22') $$);
select pg_temp.como((select profissional_suspenso from ids),
  $$ select public.criar_conta('profissional','Suspenso 487','+5561948700005','1993-05-05','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select profissional_1 from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$,
  (select garcom from fn)));
select pg_temp.como((select profissional_2 from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$,
  (select garcom from fn)));
select pg_temp.como((select profissional_suspenso from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$,
  (select garcom from fn)));

update public.usuario set estado = 'suspensa' where id = (select profissional_suspenso from ids);

create temp table prof2 as select id from public.profissional where usuario_id = (select profissional_2 from ids);

-- Estabelecimentos
create temp table casa1 as select (
  pg_temp.como((select contratante_dono from ids),
    $$ select public.cadastrar_estabelecimento('Casa Principal 487','04252011000110','food_service','CLN 108','{"latitude":-15.7905,"longitude":-47.8855}') $$)
)->>'id' as id;

create temp table casa2 as select (
  pg_temp.como((select contratante_outro from ids),
    $$ select public.cadastrar_estabelecimento('Casa Outra 487','68558622000173','food_service','CLN 109','{"latitude":-15.7905,"longitude":-47.8855}') $$)
)->>'id' as id;

-- Publicacao de vaga para os testes
create temp table vaga as select (
  pg_temp.como((select contratante_dono from ids), format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-05-10 20:00:00+00'::timestamptz, '2027-05-11 02:00:00+00'::timestamptz,
         'CLN 108','{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
         16000::bigint, 1, true, false, false, 'Gerente', 'urgencia'::public.modo_preenchimento,
         gen_random_uuid()) $$,
    (select id from casa1), (select garcom from fn)))
)->>'vaga_id' as id;

-- Candidatura confirmada
create temp table cand as select (
  pg_temp.como((select profissional_1 from ids), format(
    $$ select public.candidatar(%L::uuid) $$,
    (select id from vaga)))
) as r;

create temp table turno_info as select
  ((select r from cand)->>'turno_id')::uuid as turno_id,
  ((select r from cand)->>'posicao_id')::uuid as posicao_id;

-- 1. confirmarCheckinManual: 403 sem_permissao (profissional tentando confirmar seu proprio check-in manual)
select throws_ok(
  pg_temp.por((select profissional_1 from ids), format(
    $$ select public.confirmar_checkin_manual(%L::uuid) $$,
    (select turno_id from turno_info))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '1. confirmarCheckinManual: 403 sem_permissao quando chamado por profissional'
);

-- 2. confirmarCheckinManual: 404 nao_encontrado (turno inexistente)
select throws_ok(
  pg_temp.por((select contratante_dono from ids),
    $$ select public.confirmar_checkin_manual('c4870000-0000-4000-8000-000000000099'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '2. confirmarCheckinManual: 404 nao_encontrado quando turno nao existe'
);

-- 3. fazerCheckin: 403 sem_permissao (profissional suspenso tentando fazer check-in)
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids), format(
    $$ select public.fazer_checkin(%L::uuid, 40, '2027-05-10 20:05:00+00'::timestamptz) $$,
    (select turno_id from turno_info))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '3. fazerCheckin: 403 sem_permissao quando chamado por conta suspensa'
);

-- 4. fazerCheckin: 404 nao_encontrado (turno inexistente)
select throws_ok(
  pg_temp.por((select profissional_1 from ids),
    $$ select public.fazer_checkin('c4870000-0000-4000-8000-000000000099'::uuid, 40, '2027-05-10 20:05:00+00'::timestamptz) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '4. fazerCheckin: 404 nao_encontrado quando turno nao existe'
);

-- 5. fazerCheckout: 403 sem_permissao (profissional suspenso tentando fazer checkout)
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids), format(
    $$ select public.fazer_checkout(%L::uuid, 40, '2027-05-11 01:55:00+00'::timestamptz) $$,
    (select turno_id from turno_info))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '5. fazerCheckout: 403 sem_permissao quando chamado por conta suspensa'
);

-- 6. fazerCheckout: 404 nao_encontrado (turno inexistente)
select throws_ok(
  pg_temp.por((select profissional_1 from ids),
    $$ select public.fazer_checkout('c4870000-0000-4000-8000-000000000099'::uuid, 40, '2027-05-11 01:55:00+00'::timestamptz) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '6. fazerCheckout: 404 nao_encontrado quando turno nao existe'
);

-- 7. republicarVaga: 403 sem_permissao (contratante de outro estabelecimento tentando republicar)
select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.republicar_vaga(%L::uuid, '2027-05-15 20:00:00+00'::timestamptz, '2027-05-16 02:00:00+00'::timestamptz, gen_random_uuid()) $$,
    (select id from vaga))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '7. republicarVaga: 403 sem_permissao quando chamador nao e membro do estabelecimento'
);

-- 8. republicarVaga: 404 nao_encontrado (vaga de origem inexistente)
select throws_ok(
  pg_temp.por((select contratante_dono from ids),
    $$ select public.republicar_vaga('c4870000-0000-4000-8000-000000000099'::uuid, '2027-05-15 20:00:00+00'::timestamptz, '2027-05-16 02:00:00+00'::timestamptz, gen_random_uuid()) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '8. republicarVaga: 404 nao_encontrado quando vaga de origem nao existe'
);

-- 9. detalheVaga: 403 sem_permissao (profissional suspenso tentando consultar detalhe de vaga)
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids), format(
    $$ select public.detalhe_vaga(%L::uuid) $$,
    (select id from vaga))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '9. detalheVaga: 403 sem_permissao quando chamado por conta suspensa'
);

-- 10. detalheVaga: 404 nao_encontrado (vaga inexistente)
select throws_ok(
  pg_temp.por((select profissional_1 from ids),
    $$ select public.detalhe_vaga('c4870000-0000-4000-8000-000000000099'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '10. detalheVaga: 404 nao_encontrado quando vaga nao existe'
);

-- 11. candidatosDaVaga: 403 sem_permissao (contratante de outro estabelecimento tentando listar candidatos)
select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.candidatos_da_vaga(%L::uuid) $$,
    (select id from vaga))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '11. candidatosDaVaga: 403 sem_permissao quando chamador nao e membro do estabelecimento'
);

-- 12. candidatosDaVaga: 404 nao_encontrado (vaga inexistente)
select throws_ok(
  pg_temp.por((select contratante_dono from ids),
    $$ select public.candidatos_da_vaga('c4870000-0000-4000-8000-000000000099'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '12. candidatosDaVaga: 404 nao_encontrado quando vaga nao existe'
);

-- 13. incluirNaEquipe: 403 sem_permissao (profissional sem turno verificado cumprido no estabelecimento)
select throws_ok(
  pg_temp.por((select contratante_dono from ids), format(
    $$ select public.incluir_na_equipe(%L::uuid, %L::uuid) $$,
    (select id from casa1), (select id from prof2))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'sem_turno_cumprido'),
  '13. incluirNaEquipe: 403 sem_permissao quando profissional nao tem turno verificado cumprido na casa'
);

-- 14. incluirNaEquipe: 404 nao_encontrado (profissional inexistente)
select throws_ok(
  pg_temp.por((select contratante_dono from ids), format(
    $$ select public.incluir_na_equipe(%L::uuid, 'c4870000-0000-4000-8000-000000000099'::uuid) $$,
    (select id from casa1))),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '14. incluirNaEquipe: 404 nao_encontrado quando profissional nao existe'
);

-- 15. removerDaEquipe: 403 sem_permissao (contratante de outro estabelecimento tentando remover da equipe)
select throws_ok(
  pg_temp.por((select contratante_outro from ids), format(
    $$ select public.remover_da_equipe(%L::uuid, 'c4870000-0000-4000-8000-000000000099'::uuid) $$,
    (select id from casa1))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  '15. removerDaEquipe: 403 sem_permissao quando chamador nao e administrador do estabelecimento'
);

rollback;
