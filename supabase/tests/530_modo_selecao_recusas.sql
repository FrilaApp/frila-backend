-- Recusas do modo seleção que o contrato declara e nenhum teste provava (revisão do Oráculo, 01/10).
--
-- `candidatos_da_vaga`, `escolher_candidato`, `minhas_candidaturas` e `retirar_candidatura`
-- declaram `401 nao_autenticado`; `escolher_candidato` declara ainda `403 sem_permissao`
-- (conta suspensa) e `422 campo_obrigatorio` (`candidatura_id`). O código já recusava, mas
-- sem teste a recusa muda de `code` numa refatoração sem ninguém ver.
--
-- Fora daqui, de propósito: `422 campo_obrigatorio` em `candidatos_da_vaga` e em
-- `retirar_candidatura`, que o contrato não declara para a operação (divergência para o
-- contrato decidir, como na auditoria de 30/09).
--
-- Ids próprios, começando em `c5300000`.

begin;
select plan(6);

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
  'c5300000-0000-4000-8000-0000000000d2'::uuid as suspensa;

select pg_temp.autenticar((select dona from ids),     'dona@c53.test');
select pg_temp.autenticar((select suspensa from ids), 'suspensa@c53.test');

select pg_temp.como((select dona from ids),
  $$ select public.criar_conta('contratante','Dona da Seleção','+5561953000001','1980-01-01','2026-09-22') $$);
select pg_temp.como((select suspensa from ids),
  $$ select public.criar_conta('contratante','Dona Suspensa','+5561953000002','1980-01-01','2026-09-22') $$);

update public.usuario set estado = 'suspensa' where id = (select suspensa from ids);

-- ── Sem sessão ────────────────────────────────────────────────────────────────
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

-- ── escolher_candidato: conta suspensa e campo obrigatório ────────────────────
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

select * from finish();
rollback;
