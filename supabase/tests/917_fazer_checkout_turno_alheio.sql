-- 917_fazer_checkout_turno_alheio.sql
--
-- fazer_checkout de um turno que é de OUTRO profissional é 404 nao_encontrado e não toca no turno. A posição vem de
-- privado.turno_do_profissional, que só a devolve para o dono (privado.usuario_do_profissional(...) = auth.uid()). O 487
-- só cobre turno inexistente, e o 786 só o dono e os contratantes: sem este arquivo, buscar a posição pelo turno_id sem
-- conferir o dono deixaria qualquer profissional registrar a saída do turno de outro.
--
-- O controle é o dono: o mesmo pedido, feito por ele, registra a saída.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(6);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2027-05-01 12:00:00+00';

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

create function pg_temp.erro(codigo text) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : null, "hint" : null}', codigo, codigo)
$$;

create temp table ids as select
  '91700000-0000-4000-8000-000000000001'::uuid as contratante,
  '91700000-0000-4000-8000-000000000002'::uuid as dono_do_turno,
  '91700000-0000-4000-8000-000000000003'::uuid as outro_profissional;

select pg_temp.autenticar((select contratante from ids), 'casa917@test.local');
select pg_temp.autenticar((select dono_do_turno from ids), 'dono917@test.local');
select pg_temp.autenticar((select outro_profissional from ids), 'outro917@test.local');

select pg_temp.como((select contratante from ids),
  $$ select public.criar_conta('contratante','Casa 917','+5561991700001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select dono_do_turno from ids),
  $$ select public.criar_conta('profissional','Dono do Turno 917','+5561991700002','1995-01-01','2026-09-22') $$);
select pg_temp.como((select outro_profissional from ids),
  $$ select public.criar_conta('profissional','Outro Profissional 917','+5561991700003','1994-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select dono_do_turno from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$,
  (select garcom from fn)));
select pg_temp.como((select outro_profissional from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$,
  (select garcom from fn)));

create temp table casa as select (
  pg_temp.como((select contratante from ids),
    $$ select public.cadastrar_estabelecimento('Casa 917','04252011000110','food_service','CLN 108','{"latitude":-15.7905,"longitude":-47.8855}') $$)
)->>'id' as id;

create temp table vaga as select (
  pg_temp.como((select contratante from ids), format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2027-05-10 20:00:00+00'::timestamptz, '2027-05-11 02:00:00+00'::timestamptz,
         'CLN 108','{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
         16000::bigint, 1, true, false, false, 'Gerente', 'urgencia'::public.modo_preenchimento,
         gen_random_uuid()) $$,
    (select id from casa), (select garcom from fn)))
)->>'vaga_id' as id;

-- O turno é do dono: ele se candidata e faz o check-in.
create temp table turno_info as select ((
  pg_temp.como((select dono_do_turno from ids), format($$ select public.candidatar(%L::uuid) $$, (select id from vaga)))
)->>'turno_id')::uuid as turno_id;

set local frila.agora = '2027-05-10 20:05:00+00';
select pg_temp.como((select dono_do_turno from ids), format(
  $$ select public.fazer_checkin(%L::uuid, 40, '2027-05-10 20:05:00+00'::timestamptz) $$,
  (select turno_id from turno_info)));

-- Dentro da janela do check-out, com o check-in feito: só falta ser o dono.
set local frila.agora = '2027-05-11 01:50:00+00';

create temp table antes as
  select to_jsonb(t) as turno from public.turno t where t.id = (select turno_id from turno_info);
create temp table taxa_antes as
  select p.taxa_comparecimento from public.profissional p where p.usuario_id = (select dono_do_turno from ids);

select ok(
  (select turno ->> 'checkin_em' is not null and turno ->> 'checkout_em' is null from antes),
  'o turno do dono tem check-in e ainda não tem check-out'
);

-- ── Outro profissional tenta registrar a saída do turno do dono ────────────────────────
select throws_ok(
  pg_temp.por((select outro_profissional from ids), format(
    $$ select public.fazer_checkout(%L::uuid, 40, '2027-05-11 01:50:00+00'::timestamptz) $$,
    (select turno_id from turno_info))),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'fazer_checkout do turno de outro profissional é 404 nao_encontrado'
);

select is(
  (select to_jsonb(t) from public.turno t where t.id = (select turno_id from turno_info)),
  (select turno from antes),
  'o turno do dono não muda: nem checkout_em, nem recebido_em, nem distância, nem verificação'
);

select is(
  (select p.taxa_comparecimento from public.profissional p where p.usuario_id = (select dono_do_turno from ids)),
  (select taxa_comparecimento from taxa_antes),
  'a taxa de comparecimento do dono não muda'
);

-- ── Controle: o dono faz o mesmo pedido e a saída é registrada ─────────────────────────
select is(
  (pg_temp.como((select dono_do_turno from ids), format(
    $$ select public.fazer_checkout(%L::uuid, 40, '2027-05-11 01:50:00+00'::timestamptz) $$,
    (select turno_id from turno_info))) ->> 'registrado_em')::timestamptz,
  '2027-05-11 01:50:00+00'::timestamptz,
  'o dono do turno registra a saída com o mesmo pedido'
);

select is(
  (select t.checkout_em from public.turno t where t.id = (select turno_id from turno_info)),
  '2027-05-11 01:50:00+00'::timestamptz,
  'a saída do dono fica gravada no turno'
);

select * from finish();
rollback;
