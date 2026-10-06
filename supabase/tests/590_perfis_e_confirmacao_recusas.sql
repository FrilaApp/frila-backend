-- Recusas contratuais de perfil incompatível e confirmação de presença (RN13, RN20, RN22, RN25).
--
-- O contrato OpenAPI declara:
--   - `/rpc/candidatar`: 422 RegraRecusou (perfil_incompativel, campo_obrigatorio vaga_id)
--   - `/rpc/detalhe_vaga`: 422 RegraRecusou (perfil_incompativel, campo_obrigatorio vaga_id)
--   - `/rpc/minhas_candidaturas`: 422 RegraRecusou (perfil_incompativel)
--   - `/rpc/confirmar_checkin_manual`: 403 SemPermissao (conta_suspensa, não membro, profissional)
--
-- Ids próprios, começando em `c5900000`.

begin;
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2027-05-01 12:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste';
select plan(8);

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
  'c5900000-0000-4000-8000-0000000000d1'::uuid as dona,
  'c5900000-0000-4000-8000-0000000000d2'::uuid as dona_alheia,
  'c5900000-0000-4000-8000-0000000000d3'::uuid as dona_suspensa,
  'c5900000-0000-4000-8000-0000000000e1'::uuid as prof;

select pg_temp.autenticar((select dona from ids),          'dona@c59.test');
select pg_temp.autenticar((select dona_alheia from ids),   'dona-alheia@c59.test');
select pg_temp.autenticar((select dona_suspensa from ids), 'dona-suspensa@c59.test');
select pg_temp.autenticar((select prof from ids),          'prof@c59.test');

select pg_temp.como((select dona from ids),
  $$ select public.criar_conta('contratante','Dona do Restaurante','+5561959000001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select dona_alheia from ids),
  $$ select public.criar_conta('contratante','Dona de Outro Lugar','+5561959000002','1980-01-01','2026-09-22') $$);
select pg_temp.como((select dona_suspensa from ids),
  $$ select public.criar_conta('contratante','Dona Suspensa','+5561959000003','1980-01-01','2026-09-22') $$);
select pg_temp.como((select prof from ids),
  $$ select public.criar_conta('profissional','Profissional Bar','+5561959000004','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select prof from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

create temp table casa as
  select (pg_temp.como((select dona from ids),
    $$ select public.cadastrar_estabelecimento('Casa do 590','12345678000195','food_service',
         'SCLN 408','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- Vincula dona_suspensa como administradora da mesma casa antes de suspendê-la
insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ((select id from casa), (select dona_suspensa from ids), 'administrador');

update public.usuario set estado = 'suspensa' where id = (select dona_suspensa from ids);

create function pg_temp.publicar(chave uuid) returns uuid
language sql as $$
  select (pg_temp.como((select dona from ids), format(
    $sql$ select public.publicar_vaga(%L, %L,
         '2027-05-04 21:00:00+00'::timestamptz, '2027-05-05 03:00:00+00'::timestamptz,
         'CLN 408', '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Dona', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn), chave))->>'vaga_id')::uuid;
$$;

create temp table v as select
  pg_temp.publicar('c5900000-0000-4000-8000-000000000001') as id;

-- Profissional ganha a vaga (modo urgência) e cria posição confirmada e turno
create temp table cand as select
  pg_temp.como((select prof from ids),
    format($$ select public.candidatar(%L) $$, (select id from v))) as res;

create temp table t as select
  ((select res from cand)->>'turno_id')::uuid as id;

-- Registra check-in manual no turno para permitir teste de confirmação
update public.turno
   set checkin_tipo = 'manual',
       checkin_em = '2027-05-04 21:05:00+00'::timestamptz,
       verificacao = 'pendente'
 where id = (select id from t);

-- ── 1. candidatar: perfil contratante recebe 422 perfil_incompativel ──────────
select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.candidatar(%L) $$, (select id from v))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'candidatar por contratante é 422 perfil_incompativel (RN25)');

-- ── 2. candidatar: vaga_id nulo recebe 422 campo_obrigatorio ──────────────────
select throws_ok(
  pg_temp.por((select prof from ids),
    $$ select public.candidatar(null) $$),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'vaga_id'),
  'candidatar com vaga_id nulo é 422 campo_obrigatorio');

-- ── 3. detalhe_vaga: perfil contratante recebe 422 perfil_incompativel ────────
select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.detalhe_vaga(%L) $$, (select id from v))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'detalhe_vaga por contratante é 422 perfil_incompativel (RN25)');

-- ── 4. detalhe_vaga: vaga_id nulo recebe 422 campo_obrigatorio ────────────────
select throws_ok(
  pg_temp.por((select prof from ids),
    $$ select public.detalhe_vaga(null) $$),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'vaga_id'),
  'detalhe_vaga com vaga_id nulo é 422 campo_obrigatorio');

-- ── 5. minhas_candidaturas: perfil contratante recebe 422 perfil_incompativel ─
select throws_ok(
  pg_temp.por((select dona from ids),
    $$ select public.minhas_candidaturas() $$),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'minhas_candidaturas por contratante é 422 perfil_incompativel (RN25)');

-- ── 6. confirmar_checkin_manual: conta suspensa recebe 403 conta_suspensa ────
select throws_ok(
  pg_temp.por((select dona_suspensa from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select id from t))),
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'confirmar_checkin_manual por membro com conta suspensa é 403 sem_permissao (RN13)');

-- ── 7. confirmar_checkin_manual: contratante não membro recebe 403 ────────────
select throws_ok(
  pg_temp.por((select dona_alheia from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select id from t))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'confirmar_checkin_manual por não membro da casa é 403 sem_permissao (RF20)');

-- ── 8. confirmar_checkin_manual: profissional recebe 403 sem_permissao ────────
select throws_ok(
  pg_temp.por((select prof from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select id from t))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'confirmar_checkin_manual pelo profissional do turno é 403 sem_permissao (RF20)');

select * from finish();
rollback;
