-- Recusas de painel_estabelecimento prometidas pelo contrato (401, 403, 422).
--
-- O contrato OpenAPI declara para `/rpc/painel_estabelecimento`:
--   - 401: nao_autenticado
--   - 403: sem_permissao (só membros do estabelecimento acessam o painel)
-- A implementação valida ainda os campos obrigatórios da janela de tempo:
--   - 422: campo_obrigatorio com details 'de' ou 'ate'
--
-- Ids próprios, começando em `c5600000`.

begin;
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

-- A chamada `sql` feita por `conta`, pronta para o `throws_ok` ou `lives_ok`.
create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create temp table ids as select
  'c5600000-0000-4000-8000-0000000000d1'::uuid as dona,
  'c5600000-0000-4000-8000-0000000000d2'::uuid as outro_dono,
  'c5600000-0000-4000-8000-0000000000e1'::uuid as profissional;

select pg_temp.autenticar((select dona from ids),         'dona@c56.test');
select pg_temp.autenticar((select outro_dono from ids),   'outro@c56.test');
select pg_temp.autenticar((select profissional from ids), 'prof@c56.test');

select pg_temp.como((select dona from ids),
  $$ select public.criar_conta('contratante','Dona do Painel','+5561956000001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select outro_dono from ids),
  $$ select public.criar_conta('contratante','Outro Dono','+5561956000002','1980-01-01','2026-09-22') $$);
select pg_temp.como((select profissional from ids),
  $$ select public.criar_conta('profissional','Profissional','+5561956000003','1995-01-01','2026-09-22') $$);

create temp table casa as
  select (pg_temp.como((select dona from ids),
    $$ select public.cadastrar_estabelecimento('Casa do Painel','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- ── 1. Sem sessão (401) ───────────────────────────────────────────────────────
select throws_ok(
  format($$ select public.painel_estabelecimento(%L, now(), now() + interval '1 day') $$,
         (select id from casa)),
  'PGRST', pg_temp.erro('nao_autenticado'),
  'painel_estabelecimento sem token é 401 nao_autenticado');

-- ── 2. Permissão e controle de acesso (403) ──────────────────────────────────
select throws_ok(
  pg_temp.por((select outro_dono from ids),
    format($$ select public.painel_estabelecimento(%L, now(), now() + interval '1 day') $$, (select id from casa))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'painel_estabelecimento por contratante de outro estabelecimento é 403 sem_permissao');

select throws_ok(
  pg_temp.por((select profissional from ids),
    format($$ select public.painel_estabelecimento(%L, now(), now() + interval '1 day') $$, (select id from casa))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'painel_estabelecimento por profissional é 403 sem_permissao');

select throws_ok(
  pg_temp.por((select dona from ids),
    $$ select public.painel_estabelecimento('c5600000-0000-4000-8000-ffffffffffff'::uuid, now(), now() + interval '1 day') $$),
  'PGRST', pg_temp.erro('sem_permissao'),
  'painel_estabelecimento para estabelecimento inexistente é 403 sem_permissao');

select throws_ok(
  pg_temp.por((select dona from ids),
    $$ select public.painel_estabelecimento(null, now(), now() + interval '1 day') $$),
  'PGRST', pg_temp.erro('sem_permissao'),
  'painel_estabelecimento sem estabelecimento_id é 403 sem_permissao');

-- ── 3. Parâmetros obrigatórios da janela (422) ───────────────────────────────
select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.painel_estabelecimento(%L, null, now() + interval '1 day') $$, (select id from casa))),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'de'),
  'painel_estabelecimento sem de é 422 campo_obrigatorio, details de');

select throws_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.painel_estabelecimento(%L, now(), null) $$, (select id from casa))),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'ate'),
  'painel_estabelecimento sem ate é 422 campo_obrigatorio, details ate');

-- ── 4. Caminho feliz com permissão (200) ─────────────────────────────────────
select lives_ok(
  pg_temp.por((select dona from ids),
    format($$ select public.painel_estabelecimento(%L, now(), now() + interval '1 day') $$, (select id from casa))),
  'painel_estabelecimento com permissão e parâmetros válidos responde com sucesso (200)');

select * from finish();
rollback;
