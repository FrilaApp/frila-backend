-- `perfil_publico`: o bloqueio esconde o perfil público (cartão 1aGJPQK2, US26, RF26, UC17, contrato 0.2.28).
--
-- Conforme a decisão de produto de 30/09 e contrato 0.2.28:
--   * devolve `404 nao_encontrado` nos dois sentidos de bloqueio entre quem chama e o perfil;
--   * devolve `404 nao_encontrado` quando a outra parte é membro do estabelecimento consultado
--     (ou quando quem chama é membro de estabelecimento com bloqueio com o profissional);
--   * resposta idêntica a id inexistente (404 nao_encontrado, sem vazar a existência do bloqueio);
--   * não bloqueia o próprio usuário nem o próprio estabelecimento.

begin;
select plan(10);

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

-- Usuários de teste (prefixo c5500000)
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('c5500000-0000-4000-8000-000000000001','profissional','Pedro',  '+5561955000001','pedro@c55.test', '1995-01-01','2026-09-22', now()),
  ('c5500000-0000-4000-8000-000000000002','profissional','Paula',  '+5561955000002','paula@c55.test', '1996-01-01','2026-09-22', now()),
  ('c5500000-0000-4000-8000-000000000003','profissional','Neutro', '+5561955000003','neutro@c55.test','1997-01-01','2026-09-22', now()),
  ('c5500000-0000-4000-8000-000000000011','contratante', 'Carla',  '+5561955000011','carla@c55.test', '1980-01-01','2026-09-22', now()),
  ('c5500000-0000-4000-8000-000000000012','contratante', 'Carlos', '+5561955000012','carlos@c55.test','1981-01-01','2026-09-22', now()),
  ('c5500000-0000-4000-8000-000000000021','contratante', 'Marcelo','+5561955000021','marcelo@c55.test','1982-01-01','2026-09-22', now());

select pg_temp.autenticar('c5500000-0000-4000-8000-000000000001', 'pedro@c55.test');
select pg_temp.autenticar('c5500000-0000-4000-8000-000000000002', 'paula@c55.test');
select pg_temp.autenticar('c5500000-0000-4000-8000-000000000003', 'neutro@c55.test');
select pg_temp.autenticar('c5500000-0000-4000-8000-000000000011', 'carla@c55.test');
select pg_temp.autenticar('c5500000-0000-4000-8000-000000000012', 'carlos@c55.test');
select pg_temp.autenticar('c5500000-0000-4000-8000-000000000021', 'marcelo@c55.test');

-- Perfis profissionais (prefixo f5500000)
insert into public.profissional (id, usuario_id, ponto_base) values
  ('f5500000-0000-4000-8000-000000000001', 'c5500000-0000-4000-8000-000000000001', 'POINT(-47.8811 -15.7911)'::extensions.geography),
  ('f5500000-0000-4000-8000-000000000002', 'c5500000-0000-4000-8000-000000000002', 'POINT(-47.8812 -15.7912)'::extensions.geography),
  ('f5500000-0000-4000-8000-000000000003', 'c5500000-0000-4000-8000-000000000003', 'POINT(-47.8813 -15.7913)'::extensions.geography);

-- Estabelecimentos (prefixo e5500000)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('e5500000-0000-4000-8000-000000000001', 'Bar Bloqueado', '11111111000111', 'food_service', 'CLN 101', 'POINT(-47.88 -15.79)'::extensions.geography),
  ('e5500000-0000-4000-8000-000000000002', 'Bar Livre',     '22222222000122', 'food_service', 'CLN 102', 'POINT(-47.89 -15.80)'::extensions.geography);

-- Membros dos estabelecimentos
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c5500000-0000-4000-8000-000000000011', 'e5500000-0000-4000-8000-000000000001', 'administrador'),
  ('c5500000-0000-4000-8000-000000000021', 'e5500000-0000-4000-8000-000000000001', 'operador'),
  ('c5500000-0000-4000-8000-000000000012', 'e5500000-0000-4000-8000-000000000002', 'administrador');

-- Bloqueios configurados:
-- 1. Pedro (p1) bloqueou Carlos (c2)
-- 2. Carlos (c2) bloqueou Paula (p2)
-- 3. Marcelo (m1, operador do Bar Bloqueado e1) bloqueou Pedro (p1)
-- 4. Paula (p2) bloqueou Carla (c1, administradora do Bar Bloqueado e1)
insert into public.bloqueio (autor_id, bloqueado_id) values
  ('c5500000-0000-4000-8000-000000000001', 'c5500000-0000-4000-8000-000000000012'),
  ('c5500000-0000-4000-8000-000000000012', 'c5500000-0000-4000-8000-000000000002'),
  ('c5500000-0000-4000-8000-000000000021', 'c5500000-0000-4000-8000-000000000001'),
  ('c5500000-0000-4000-8000-000000000002', 'c5500000-0000-4000-8000-000000000011');

-- ── 1. Sem token ───────────────────────────────────────────────────────────────
select throws_ok(
  $$ select public.perfil_publico('f5500000-0000-4000-8000-000000000001') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'sem token dá 401 nao_autenticado');

-- ── 2. Perfil profissional: sentido 1 (profissional bloqueou chamador) ─────────
-- Pedro (p1) bloqueou Carlos (c2) -> Carlos recebe 404 ao consultar Pedro
select throws_ok(
  $$ select pg_temp.como('c5500000-0000-4000-8000-000000000012',
       'select public.perfil_publico(''f5500000-0000-4000-8000-000000000001'')') $$,
  'PGRST', pg_temp.erro('nao_encontrado'),
  'profissional: quem foi bloqueado recebe 404 nao_encontrado ao consultar autor do bloqueio');

-- ── 3. Perfil profissional: sentido 2 (chamador bloqueou profissional) ─────────
-- Carlos (c2) bloqueou Paula (p2) -> Carlos recebe 404 ao consultar Paula
select throws_ok(
  $$ select pg_temp.como('c5500000-0000-4000-8000-000000000012',
       'select public.perfil_publico(''f5500000-0000-4000-8000-000000000002'')') $$,
  'PGRST', pg_temp.erro('nao_encontrado'),
  'profissional: autor do bloqueio recebe 404 nao_encontrado ao consultar quem bloqueou');

-- ── 4. Perfil profissional: membro de estabelecimento com bloqueio ─────────────
-- Marcelo (m1) bloqueou Pedro (p1); Carla (c1) é membro do mesmo estabelecimento (e1)
-- Carla recebe 404 ao consultar Pedro
select throws_ok(
  $$ select pg_temp.como('c5500000-0000-4000-8000-000000000011',
       'select public.perfil_publico(''f5500000-0000-4000-8000-000000000001'')') $$,
  'PGRST', pg_temp.erro('nao_encontrado'),
  'profissional: membro de estabelecimento com bloqueio recebe 404 nao_encontrado');

-- ── 5. Perfil profissional: sem bloqueio ───────────────────────────────────────
-- Neutro consulta Pedro -> 200 com perfil do Pedro
select is(
  (select pg_temp.como('c5500000-0000-4000-8000-000000000003',
     'select public.perfil_publico(''f5500000-0000-4000-8000-000000000001'')')->>'nome'),
  'Pedro',
  'profissional sem bloqueio devolve perfil normalmente');

-- ── 6. Perfil estabelecimento: sentido 1 (chamador bloqueou membro) ────────────
-- Paula (p2) bloqueou Carla (c1, membro de e1) -> Paula recebe 404 ao consultar e1
select throws_ok(
  $$ select pg_temp.como('c5500000-0000-4000-8000-000000000002',
       'select public.perfil_publico(''e5500000-0000-4000-8000-000000000001'')') $$,
  'PGRST', pg_temp.erro('nao_encontrado'),
  'estabelecimento: quem bloqueou membro recebe 404 nao_encontrado ao consultar estabelecimento');

-- ── 7. Perfil estabelecimento: sentido 2 (membro bloqueou chamador) ────────────
-- Marcelo (m1, membro de e1) bloqueou Pedro (p1) -> Pedro recebe 404 ao consultar e1
select throws_ok(
  $$ select pg_temp.como('c5500000-0000-4000-8000-000000000001',
       'select public.perfil_publico(''e5500000-0000-4000-8000-000000000001'')') $$,
  'PGRST', pg_temp.erro('nao_encontrado'),
  'estabelecimento: quem foi bloqueado por membro recebe 404 nao_encontrado ao consultar estabelecimento');

-- ── 8. Perfil estabelecimento: sem bloqueio ────────────────────────────────────
-- Neutro consulta Bar Bloqueado (e1) -> 200 com perfil do estabelecimento
select is(
  (select pg_temp.como('c5500000-0000-4000-8000-000000000003',
     'select public.perfil_publico(''e5500000-0000-4000-8000-000000000001'')')->>'nome'),
  'Bar Bloqueado',
  'estabelecimento sem bloqueio devolve perfil normalmente');

-- ── 9. Auto-consulta de profissional ───────────────────────────────────────────
-- Pedro consultando o próprio perfil profissional
select is(
  (select pg_temp.como('c5500000-0000-4000-8000-000000000001',
     'select public.perfil_publico(''f5500000-0000-4000-8000-000000000001'')')->>'nome'),
  'Pedro',
  'auto-consulta de profissional não é impedida por outros bloqueios da conta');

-- ── 10. Auto-consulta de membro do próprio estabelecimento ──────────────────────
-- Carla consultando o próprio estabelecimento (e1)
select is(
  (select pg_temp.como('c5500000-0000-4000-8000-000000000011',
     'select public.perfil_publico(''e5500000-0000-4000-8000-000000000001'')')->>'nome'),
  'Bar Bloqueado',
  'membro consultando o próprio estabelecimento não é impedido por bloqueios existentes');

select * from finish();
rollback;
