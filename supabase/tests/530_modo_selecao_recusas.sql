-- Recusas do modo seleção que o contrato declara (revisão do Oráculo e carga-agy, 01/10).
--
-- O contrato declara:
--   - `candidatos_da_vaga`: 401 nao_autenticado, 403 sem_permissao (conta suspensa), 404, 422 perfil_incompativel
--   - `escolher_candidato`: 401 nao_autenticado, 403 sem_permissao (conta suspensa),
--                           409 (candidatura_indisponivel, posicao_ja_preenchida, vaga_encerrada),
--                           422 (campo_obrigatorio, vaga_oculta, perfil_incompativel)
--   - `minhas_candidaturas`: 401 nao_autenticado
--   - `retirar_candidatura`: 401 nao_autenticado, 404 nao_encontrado,
--                            409 (candidatura_indisponivel para aceita/virou turno),
--                            422 perfil_incompativel
--
-- Ids próprios, começando em `c5300000`.

begin;
set search_path to public, extensions;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(12);

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

-- A chamada `sql` feita por `conta`, pronta para o `throws_ok`.
create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create temp table ids as select
  'c5300000-0000-4000-8000-0000000000d1'::uuid as dona,
  'c5300000-0000-4000-8000-0000000000d2'::uuid as suspensa,
  'c5300000-0000-4000-8000-0000000000e1'::uuid as prof1,
  'c5300000-0000-4000-8000-0000000000e2'::uuid as prof2;

select pg_temp.autenticar((select dona from ids),     'dona@c53.test');
select pg_temp.autenticar((select suspensa from ids), 'suspensa@c53.test');
select pg_temp.autenticar((select prof1 from ids),    'prof1@c53.test');
select pg_temp.autenticar((select prof2 from ids),    'prof2@c53.test');

select pg_temp.como((select dona from ids),
  $$ select public.criar_conta('contratante','Dona da Seleção','+5561953000001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select suspensa from ids),
  $$ select public.criar_conta('contratante','Dona Suspensa','+5561953000002','1980-01-01','2026-09-22') $$);
select pg_temp.como((select prof1 from ids),
  $$ select public.criar_conta('profissional','Profissional Um','+5561953000003','1995-01-01','2026-09-22') $$);
select pg_temp.como((select prof2 from ids),
  $$ select public.criar_conta('profissional','Profissional Dois','+5561953000004','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select prof1 from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como((select prof2 from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

update public.usuario set estado = 'suspensa' where id = (select suspensa from ids);

create temp table casa as
  select (pg_temp.como((select dona from ids),
    $$ select public.cadastrar_estabelecimento('Casa da Seleção 530','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create function pg_temp.publicar(chave uuid, inicio timestamptz, fim timestamptz) returns uuid
language sql as $$
  select (pg_temp.como((select dona from ids), format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L,
         'CLN 406', '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Seu Zé', 'selecao', %L) $sql$,
    (select id from casa), (select garcom from fn), inicio, fim, chave))->>'vaga_id')::uuid;
$$;

-- ── 1 a 4. Sem sessão ─────────────────────────────────────────────────────────
select throws_ok(
  $$ select public.candidatos_da_vaga('c5300000-0000-4000-8000-000000000001') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'candidatos_da_vaga sem token é 401 nao_autenticado');

select throws_ok(
  $$ select public.escolher_candidato('c5300000-0000-4000-8000-000000000002') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'escolher_candidato sem token é 401 nao_autenticado');

select throws_ok(
  $$ select public.minhas_candidaturas() $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'minhas_candidaturas sem token é 401 nao_autenticado');

select throws_ok(
  $$ select public.retirar_candidatura('c5300000-0000-4000-8000-000000000003') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'retirar_candidatura sem token é 401 nao_autenticado');

-- ── 5 e 6. escolher_candidato: conta suspensa e campo obrigatório ─────────────
select throws_ok(
  $$ select pg_temp.como('c5300000-0000-4000-8000-0000000000d2',
       'select public.escolher_candidato(''c5300000-0000-4000-8000-000000000002'')') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'escolher_candidato por conta suspensa é 403 conta_suspensa');

select throws_ok(
  $$ select pg_temp.como('c5300000-0000-4000-8000-0000000000d1',
       'select public.escolher_candidato(null)') $$,
  'PGRST', pg_temp.erro('campo_obrigatorio', 'candidatura_id'),
  'escolher_candidato sem candidatura_id é 422 campo_obrigatorio');

-- ── Cenário de vagas e candidaturas para 409 e 422 ────────────────────────────
-- Vaga 1 (1 posição, futura): ambos os profissionais se candidatam
create temp table v1 as select
  pg_temp.publicar('c5300000-0000-4000-8000-000000000010',
                   '2027-05-04 21:00:00+00'::timestamptz,
                   '2027-05-05 03:00:00+00'::timestamptz) as id;

create temp table cand1 as select
  (pg_temp.como((select prof1 from ids),
     format($$ select public.candidatar(%L) $$, (select id from v1)))->>'candidatura_id')::uuid as id;

create temp table cand2 as select
  (pg_temp.como((select prof2 from ids),
     format($$ select public.candidatar(%L) $$, (select id from v1)))->>'candidatura_id')::uuid as id;

-- A dona escolhe cand1: vaga v1 fica preenchida e cand1 fica com estado 'aceita'
select pg_temp.como((select dona from ids),
  format($$ select public.escolher_candidato(%L) $$, (select id from cand1)));

-- ── 7. retirar_candidatura: candidatura aceita responde 409 ───────────────────
select throws_ok(
  pg_temp.por((select prof1 from ids),
    format($$ select public.retirar_candidatura(%L) $$, (select id from cand1))),
  'PGRST', pg_temp.erro('candidatura_indisponivel'),
  'retirar_candidatura de candidatura aceita é 409 candidatura_indisponivel (RN24)');

-- ── 8. escolher_candidato: candidatura já aceita responde 409 ─────────────────
select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand1))),
  'PGRST', pg_temp.erro('candidatura_indisponivel'),
  'escolher_candidato de candidatura já aceita é 409 candidatura_indisponivel');

-- ── 9. escolher_candidato: vaga já preenchida responde 409 ────────────────────
select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand2))),
  'PGRST', pg_temp.erro('posicao_ja_preenchida'),
  'escolher_candidato quando a vaga já está preenchida é 409 posicao_ja_preenchida (RN19)');

-- ── 10. escolher_candidato: vaga encerrada a menos de 24h responde 409 ────────
create temp table v2 as select
  pg_temp.publicar('c5300000-0000-4000-8000-000000000020',
                   '2027-05-10 10:00:00+00'::timestamptz,
                   '2027-05-10 16:00:00+00'::timestamptz) as id;

create temp table cand_v2 as select
  (pg_temp.como((select prof1 from ids),
     format($$ select public.candidatar(%L) $$, (select id from v2)))->>'candidatura_id')::uuid as id;

-- Avança o relógio para 23h antes do início da vaga v2 (< 24h)
select set_config('frila.agora', '2027-05-09 11:00:00+00', true);

select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand_v2))),
  'PGRST', pg_temp.erro('vaga_encerrada'),
  'escolher_candidato a menos de 24h do início da vaga é 409 vaga_encerrada (RN24)');

select set_config('frila.agora', '2027-05-01 12:00:00+00', true);

-- ── 11. escolher_candidato: candidatura retirada responde 409 ─────────────────
create temp table v3 as select
  pg_temp.publicar('c5300000-0000-4000-8000-000000000030',
                   '2027-05-15 18:00:00+00'::timestamptz,
                   '2027-05-16 00:00:00+00'::timestamptz) as id;

create temp table cand_v3 as select
  (pg_temp.como((select prof2 from ids),
     format($$ select public.candidatar(%L) $$, (select id from v3)))->>'candidatura_id')::uuid as id;

-- prof2 retira a candidatura
select pg_temp.como((select prof2 from ids),
  format($$ select public.retirar_candidatura(%L) $$, (select id from cand_v3)));

select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand_v3))),
  'PGRST', pg_temp.erro('candidatura_indisponivel'),
  'escolher_candidato de candidatura que foi retirada é 409 candidatura_indisponivel');

-- ── 12. escolher_candidato: vaga ocultada pela moderação responde 422 ─────────
create temp table v4 as select
  pg_temp.publicar('c5300000-0000-4000-8000-000000000040',
                   '2027-05-20 18:00:00+00'::timestamptz,
                   '2027-05-21 00:00:00+00'::timestamptz) as id;

create temp table cand_v4 as select
  (pg_temp.como((select prof1 from ids),
     format($$ select public.candidatar(%L) $$, (select id from v4)))->>'candidatura_id')::uuid as id;

-- Oculta a vaga na moderação da Equipe Frila
with nova_ocorrencia as (
  insert into public.ocorrencia (
    tipo, usuario_id, estabelecimento_id, autor_id, motivo, criada_em, resolvido_em, resultado
  ) values (
    'suporte', (select dona from ids), (select id from casa), (select dona from ids),
    'ocultação preventiva', now(), now(), 'ocultada'
  ) returning id
)
insert into privado.vaga_ocultada (vaga_id, ocorrencia_id, oculta_em)
select (select id from v4), id, now() from nova_ocorrencia;

select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.escolher_candidato(%L) $$, (select id from cand_v4))),
  'PGRST', pg_temp.erro('vaga_oculta'),
  'escolher_candidato em vaga ocultada pela moderação é 422 vaga_oculta');

select * from finish();
rollback;
