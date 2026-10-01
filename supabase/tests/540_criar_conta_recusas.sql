-- Recusas de `criar_conta` que o contrato declara e nenhum teste provava (Oráculo, 01/10).
--
-- `POST /rpc/criar_conta` declara `401` e `409`. O `080_criar_conta` prova os 422, o
-- `perfil_divergente` e a idempotência; faltavam duas recusas que o código já levanta:
--   * `401 nao_autenticado` com `details: sem_email_confirmado` (sessão sem e-mail na
--     credencial: sem e-mail não há conta, RN25);
--   * `409 conta_existente` com `details: email_em_uso` (o e-mail já pertence a outra conta
--     do produto, e o `unique_violation` vira o código do app em vez de um `23505` cru).
--
-- Ids próprios, começando em `c5400000`.

begin;
select plan(2);

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

-- Credencial sem e-mail: a sessão existe, a conta não, e `auth.users.email` é nulo.
insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'c5400000-0000-4000-8000-0000000000a1',
        'authenticated', 'authenticated', null, '{}'::jsonb, '{}'::jsonb, now(), now(), false, false);

select throws_ok(
  $$ select pg_temp.como('c5400000-0000-4000-8000-0000000000a1',
       'select public.criar_conta(''profissional'', ''Sem Email'', ''+5561954000001'', ''1990-01-01'', ''2026-09-22'')') $$,
  'PGRST', pg_temp.erro('nao_autenticado', 'sem_email_confirmado'),
  'criar_conta com credencial sem e-mail é 401 sem_email_confirmado');

-- O e-mail `dup@c54.test` já é de outra conta do produto (a de `b1`), e a credencial `b2`
-- chega com o mesmo e-mail por outro caminho de login.
select pg_temp.autenticar('c5400000-0000-4000-8000-0000000000b1', 'b1@c54.test');
select pg_temp.autenticar('c5400000-0000-4000-8000-0000000000b2', 'dup@c54.test');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('c5400000-0000-4000-8000-0000000000b1', 'profissional', 'Dono do Email', '+5561954000002',
        'dup@c54.test', '1990-01-01', '2026-09-22', now());

select throws_ok(
  $$ select pg_temp.como('c5400000-0000-4000-8000-0000000000b2',
       'select public.criar_conta(''profissional'', ''Email Repetido'', ''+5561954000003'', ''1990-01-01'', ''2026-09-22'')') $$,
  'PGRST', pg_temp.erro('conta_existente', 'email_em_uso'),
  'criar_conta com e-mail de outra conta é 409 email_em_uso');

select * from finish();
rollback;
