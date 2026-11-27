-- 920_desbloquear_nao_desfaz_bloqueio_de_outra_casa.sql
--
-- wanATOvb: `public.desbloquear('profissional', P)` apaga os bloqueios dos membros das casas de QUEM CHAMA (`meu.usuario_id = v_uid`,
-- migração 20261105150000). Sem esse filtro, qualquer contratante desfaria o bloqueio de TODAS as casas sobre o profissional. O 797 tem uma só
-- casa, e o `desbloquear` do 786 de "outro contratante" só pega o 404 de alvo inexistente.
--   A  a casa A bloqueia P; o dono da casa B desbloqueia P: a linha de A continua, e P segue fora de `privado.elegiveis` para a vaga de A
--   B  quando B também bloqueou P, o desbloqueio de B apaga só a linha de B: P volta para a vaga de B e continua fora da de A
--   C  controle: o dono de A desbloqueia de verdade, e P volta para a vaga de A (o teste não é vazio)
-- Cenário: duas casas (A e B, um dono cada), um profissional, uma vaga em cada casa. Ids próprios (`c9200000`). Só dados sintéticos.
begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-05 12:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-920';

select plan(20);

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, privado.agora(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
          privado.agora(), privado.agora(), false, false)
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

-- ── O cenário ─────────────────────────────────────────────────────────────────

select pg_temp.autenticar('c9200000-0000-4000-8000-000000000001', 'dono920a@t.test');
select pg_temp.autenticar('c9200000-0000-4000-8000-000000000002', 'dono920b@t.test');
select pg_temp.autenticar('c9200000-0000-4000-8000-000000000003', 'prof920@t.test');

select pg_temp.como('c9200000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante','Dona da Casa A','+5561955559201','1980-01-01','2026-09-22') $$);
select pg_temp.como('c9200000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('contratante','Dono da Casa B','+5561955559202','1980-01-01','2026-09-22') $$);
select pg_temp.como('c9200000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional','Profissional P','+5561955559203','1995-01-01','2026-09-22') $$);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('c9200000-0000-4000-8000-0000000000a1', 'Casa A 920', '92011222000191', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('c9200000-0000-4000-8000-0000000000b1', 'Casa B 920', '92011222000292', 'food_service', 'CLN 202', 'POINT(-47.8825 -15.7945)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c9200000-0000-4000-8000-000000000001', 'c9200000-0000-4000-8000-0000000000a1', 'administrador'),
  ('c9200000-0000-4000-8000-000000000002', 'c9200000-0000-4000-8000-0000000000b1', 'administrador');

insert into public.profissional (usuario_id, ponto_base) values
  ('c9200000-0000-4000-8000-000000000003', 'POINT(-47.8822 -15.7800)'::extensions.geography);

create temp table ids as
select (select p.id from public.profissional p where p.usuario_id = 'c9200000-0000-4000-8000-000000000003') as prof,
       'c9200000-0000-4000-8000-0000000000a1'::uuid as casa_a,
       'c9200000-0000-4000-8000-0000000000b1'::uuid as casa_b,
       'c9200000-0000-4000-8000-000000000001'::uuid as dona_a,
       'c9200000-0000-4000-8000-000000000002'::uuid as dono_b,
       'c9200000-0000-4000-8000-000000000003'::uuid as conta_prof,
       (select id from public.funcao where nome = 'garçom') as funcao;

insert into public.profissional_funcao (profissional_id, funcao_id) select prof, funcao from ids;
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select prof, d::smallint, '00:00'::time, '23:59:59'::time from ids, generate_series(0, 6) d;

-- Uma vaga em cada casa.
create temp table vaga_a as
select (pg_temp.como('c9200000-0000-4000-8000-000000000001', format(
  $$ select public.publicar_vaga(%L::uuid, %L::uuid,
       '2026-11-07 18:00:00+00'::timestamptz, '2026-11-07 23:00:00+00'::timestamptz,
       'CLN 201','{"latitude":-15.7942,"longitude":-47.8822}'::jsonb,
       12000::bigint, 2, true, false, false, 'Maitre',
       'urgencia'::public.modo_preenchimento, %L::uuid) $$,
  (select casa_a from ids), (select funcao from ids), gen_random_uuid()))->>'vaga_id')::uuid as id;
create temp table vaga_b as
select (pg_temp.como('c9200000-0000-4000-8000-000000000002', format(
  $$ select public.publicar_vaga(%L::uuid, %L::uuid,
       '2026-11-08 18:00:00+00'::timestamptz, '2026-11-08 23:00:00+00'::timestamptz,
       'CLN 202','{"latitude":-15.7945,"longitude":-47.8825}'::jsonb,
       12000::bigint, 2, true, false, false, 'Maitre',
       'urgencia'::public.modo_preenchimento, %L::uuid) $$,
  (select casa_b from ids), (select funcao from ids), gen_random_uuid()))->>'vaga_id')::uuid as id;

-- O profissional é elegível para as duas vagas antes de qualquer bloqueio.
select is((select count(*)::int from privado.elegiveis((select id from vaga_a)) where profissional_id = (select prof from ids)), 1,
  '0 o profissional é elegível para a vaga da casa A antes do bloqueio (o teste mede um corte real)');
select is((select count(*)::int from privado.elegiveis((select id from vaga_b)) where profissional_id = (select prof from ids)), 1,
  '0b e para a vaga da casa B');

-- ── A. A casa A bloqueia P; o dono da casa B desbloqueia ─────────────────────

select lives_ok(
  $$ select pg_temp.como('c9200000-0000-4000-8000-000000000001', format($x$ select public.bloquear('profissional', %L::uuid) $x$, (select prof from ids))) $$,
  'A1 a casa A bloqueia o profissional P');
select is((select count(*)::int from privado.elegiveis((select id from vaga_a)) where profissional_id = (select prof from ids)), 0,
  'A2 P sai dos elegíveis da vaga da casa A');
select is((select count(*)::int from privado.elegiveis((select id from vaga_b)) where profissional_id = (select prof from ids)), 1,
  'A3 e segue elegível para a casa B (o bloqueio é da A)');

-- As linhas de bloqueio que existem antes de o dono da casa B chamar `desbloquear`.
create temp table bloqueios_antes as select id, autor_id, bloqueado_id from public.bloqueio;

select lives_ok(
  $$ select pg_temp.como('c9200000-0000-4000-8000-000000000002', format($x$ select public.desbloquear('profissional', %L::uuid) $x$, (select prof from ids))) $$,
  'A4 o dono da casa B desbloqueia P: a chamada responde (é idempotente, 200)');
select is((select count(*)::int from public.bloqueio where autor_id = (select dona_a from ids) and bloqueado_id = (select conta_prof from ids)), 1,
  'A5 a linha de bloqueio da casa A continua');
select is((select count(*)::int from privado.elegiveis((select id from vaga_a)) where profissional_id = (select prof from ids)), 0,
  'A6 P segue fora dos elegíveis da vaga da casa A');
select is((select count(*)::int from public.bloqueio b join bloqueios_antes a using (id)), (select count(*)::int from bloqueios_antes),
  'A7 todas as linhas de bloqueio de antes continuam (nenhuma foi apagada)');
select ok((select count(*) from bloqueios_antes) >= 1, 'A8 e havia o que apagar');

-- ── B. A casa B também bloqueia P; o desbloqueio de B apaga só a de B ─────────

select lives_ok(
  $$ select pg_temp.como('c9200000-0000-4000-8000-000000000002', format($x$ select public.bloquear('profissional', %L::uuid) $x$, (select prof from ids))) $$,
  'B1 a casa B bloqueia P também');
select is((select count(*)::int from privado.elegiveis((select id from vaga_b)) where profissional_id = (select prof from ids)), 0,
  'B2 P sai dos elegíveis da vaga da casa B');
select lives_ok(
  $$ select pg_temp.como('c9200000-0000-4000-8000-000000000002', format($x$ select public.desbloquear('profissional', %L::uuid) $x$, (select prof from ids))) $$,
  'B3 o dono da casa B desbloqueia P');
select is((select count(*)::int from privado.elegiveis((select id from vaga_b)) where profissional_id = (select prof from ids)), 1,
  'B4 P volta para a vaga da casa B (o desbloqueio de B vale para B)');
select is((select count(*)::int from public.bloqueio where autor_id = (select dono_b from ids)), 0, 'B5 a linha da casa B saiu');
select is((select count(*)::int from public.bloqueio where autor_id = (select dona_a from ids) and bloqueado_id = (select conta_prof from ids)), 1,
  'B6 a linha da casa A continua');
select is((select count(*)::int from privado.elegiveis((select id from vaga_a)) where profissional_id = (select prof from ids)), 0,
  'B7 e P segue fora da vaga da casa A');

-- ── C. Controle: o dono de A desbloqueia de verdade ───────────────────────────

select lives_ok(
  $$ select pg_temp.como('c9200000-0000-4000-8000-000000000001', format($x$ select public.desbloquear('profissional', %L::uuid) $x$, (select prof from ids))) $$,
  'C1 o dono da casa A desbloqueia P');
select is((select count(*)::int from public.bloqueio where bloqueado_id = (select conta_prof from ids) and autor_id = (select dona_a from ids)), 0, 'C2 agora as linhas de A saíram');
select is((select count(*)::int from privado.elegiveis((select id from vaga_a)) where profissional_id = (select prof from ids)), 1,
  'C3 e P volta para a vaga da casa A');

select * from finish();
rollback;
