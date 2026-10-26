-- 753_privado_eh_administrador.sql
--
-- Cobertura pgTAP de privado.eh_administrador(estab uuid).
-- Garante que a checagem de autoridade de administração por estabelecimento:
--   1. Retorna true quando o chamador autenticado é administrador do estabelecimento.
--   2. Retorna false quando o chamador autenticado é membro, porém com outro papel ('operador').
--   3. Retorna false quando o chamador não possui vínculo de membro com o estabelecimento.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(3);

-- Funções auxiliares temporárias para autenticação e isolamento de contexto JWT
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

create function pg_temp.autenticar_jwt(conta uuid) returns void
language plpgsql as $$
begin
  execute format('set local "request.jwt.claims" = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute format('set local "request.jwt.claim.sub" = %L', conta::text);
end $$;

-- Setup de Dados de Teste
create temp table ids as select
  '75300000-0000-4000-8000-000000000001'::uuid as user_admin,
  '75300000-0000-4000-8000-000000000002'::uuid as user_operador,
  '75300000-0000-4000-8000-000000000003'::uuid as user_estranho,
  '75300000-0000-4000-8000-000000000010'::uuid as estab_id;

select pg_temp.autenticar((select user_admin from ids),    'admin@753.test');
select pg_temp.autenticar((select user_operador from ids), 'operador@753.test');
select pg_temp.autenticar((select user_estranho from ids), 'estranho@753.test');

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('75300000-0000-4000-8000-000000000001', 'contratante', 'Admin 753', 'admin@753.test', '+5561975300001', '1980-01-01', 'ativa', '1.0', now()),
  ('75300000-0000-4000-8000-000000000002', 'contratante', 'Operador 753', 'operador@753.test', '+5561975300002', '1985-01-01', 'ativa', '1.0', now()),
  ('75300000-0000-4000-8000-000000000003', 'contratante', 'Estranho 753', 'estranho@753.test', '+5561975300003', '1990-01-01', 'ativa', '1.0', now());

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('75300000-0000-4000-8000-000000000010', 'Restaurante 753', '75300000000110', 'food_service', 'CLN 100', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('75300000-0000-4000-8000-000000000001', '75300000-0000-4000-8000-000000000010', 'administrador'),
  ('75300000-0000-4000-8000-000000000002', '75300000-0000-4000-8000-000000000010', 'operador');

-- ── 1. Administrador do estabelecimento ───────────────────────────────────────────
select pg_temp.autenticar_jwt((select user_admin from ids));
select is(
  privado.eh_administrador((select estab_id from ids)),
  true,
  'privado.eh_administrador retorna true para membro com papel administrador'
);

-- ── 2. Operador do estabelecimento (não administrador) ─────────────────────────────
select pg_temp.autenticar_jwt((select user_operador from ids));
select is(
  privado.eh_administrador((select estab_id from ids)),
  false,
  'privado.eh_administrador retorna false para membro com papel operador'
);

-- ── 3. Usuário sem vínculo com o estabelecimento ──────────────────────────────────
select pg_temp.autenticar_jwt((select user_estranho from ids));
select is(
  privado.eh_administrador((select estab_id from ids)),
  false,
  'privado.eh_administrador retorna false para usuário sem vínculo de membro'
);

select * from finish();

rollback;
