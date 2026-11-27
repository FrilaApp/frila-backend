-- 926_denunciar_midia_so_do_proprio_alvo.sql
--
-- cXTErlQo: `public.denunciar` com `midia_id` só aceita a foto do PRÓPRIO alvo (`m.estabelecimento_id = v_estab` para a casa;
-- `m.dono_usuario_id = v_usuario and m.estabelecimento_id is null` para o profissional) e responde 422 campo_invalido `midia_id` nos outros casos
-- (migração 20261117040000). O 805 só testa um id que não existe, embora o comentário prometa "inexistente ou alheio". Sem a trava, duas contas
-- denunciariam X apontando a foto de Y, e a ocultação por duas denúncias distintas esconderia a foto de quem não foi denunciado.
--   A  denunciar o profissional X com a foto real de Y: 422 midia_id; duas contas fazendo isso não ocultam a foto de Y e a ocorrência nem nasce
--   B  denunciar a casa A com o logo da casa B: 422 midia_id; duas contas, e o logo de B segue aprovado
--   C  cruzar os tipos: a casa A com a foto pessoal de X, e o profissional X com um logo de casa: 422 midia_id
--   D  controle: com a foto do próprio alvo, a denúncia entra, e duas contas distintas ocultam a foto do denunciado (X e a casa A)
-- Ids próprios (`c9260000`). Só dados sintéticos.
begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-27 12:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste-926';

select plan(22);

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
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

-- A recusa por inteiro: o envelope de public.erro (message) mais o status (detail).
create function pg_temp.erro(conta uuid, sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  perform pg_temp.como(conta, sql);
  return null;
exception when others then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return msg::jsonb || det::jsonb;
end $$;

-- D1 e D2: quem denuncia (duas contas distintas). X e Y: profissionais. CA e CB: donos das casas A e B.
select pg_temp.autenticar('c9260000-0000-4000-8000-000000000001', 'd1.926@t.test');
select pg_temp.autenticar('c9260000-0000-4000-8000-000000000002', 'd2.926@t.test');
select pg_temp.autenticar('c9260000-0000-4000-8000-000000000003', 'x.926@t.test');
select pg_temp.autenticar('c9260000-0000-4000-8000-000000000004', 'y.926@t.test');
select pg_temp.autenticar('c9260000-0000-4000-8000-000000000005', 'ca.926@t.test');
select pg_temp.autenticar('c9260000-0000-4000-8000-000000000006', 'cb.926@t.test');
select pg_temp.como('c9260000-0000-4000-8000-000000000001', $$ select public.criar_conta('contratante','Denunciante Um','+5561955559261','1980-01-01','2026-09-22') $$);
select pg_temp.como('c9260000-0000-4000-8000-000000000002', $$ select public.criar_conta('contratante','Denunciante Dois','+5561955559262','1980-01-01','2026-09-22') $$);
select pg_temp.como('c9260000-0000-4000-8000-000000000003', $$ select public.criar_conta('profissional','Profissional X','+5561955559263','1995-01-01','2026-09-22') $$);
select pg_temp.como('c9260000-0000-4000-8000-000000000004', $$ select public.criar_conta('profissional','Profissional Y','+5561955559264','1995-01-01','2026-09-22') $$);
select pg_temp.como('c9260000-0000-4000-8000-000000000005', $$ select public.criar_conta('contratante','Dona da Casa A','+5561955559265','1980-01-01','2026-09-22') $$);
select pg_temp.como('c9260000-0000-4000-8000-000000000006', $$ select public.criar_conta('contratante','Dono da Casa B','+5561955559266','1980-01-01','2026-09-22') $$);

insert into public.profissional (usuario_id, ponto_base) values
  ('c9260000-0000-4000-8000-000000000003', 'POINT(-47.8822 -15.7800)'::extensions.geography),
  ('c9260000-0000-4000-8000-000000000004', 'POINT(-47.8822 -15.7801)'::extensions.geography);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('c9260000-0000-4000-8000-0000000000a1', 'Casa A 926', '92611222000191', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('c9260000-0000-4000-8000-0000000000b1', 'Casa B 926', '92611222000292', 'food_service', 'CLN 202', 'POINT(-47.8825 -15.7945)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c9260000-0000-4000-8000-000000000005', 'c9260000-0000-4000-8000-0000000000a1', 'administrador'),
  ('c9260000-0000-4000-8000-000000000006', 'c9260000-0000-4000-8000-0000000000b1', 'administrador');

create temp table ids as select
  (select id from public.profissional where usuario_id = 'c9260000-0000-4000-8000-000000000003') as prof_x,
  (select id from public.profissional where usuario_id = 'c9260000-0000-4000-8000-000000000004') as prof_y,
  'c9260000-0000-4000-8000-0000000000a1'::uuid as casa_a,
  'c9260000-0000-4000-8000-0000000000b1'::uuid as casa_b,
  'c9260000-0000-4000-8000-0000000000d1'::uuid as foto_x,
  'c9260000-0000-4000-8000-0000000000d2'::uuid as foto_y,
  'c9260000-0000-4000-8000-0000000000d3'::uuid as logo_a,
  'c9260000-0000-4000-8000-0000000000d4'::uuid as logo_b;

-- A foto de X, a de Y, o logo da casa A e o logo da casa B; todas aprovadas, sem denúncia.
insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado) values
  ('c9260000-0000-4000-8000-0000000000d1', 'c9260000-0000-4000-8000-000000000003', null, 'profissional', 'foto_perfil', 'perfil/926-x.jpg', 'image/jpeg', 100, 'aprovada'),
  ('c9260000-0000-4000-8000-0000000000d2', 'c9260000-0000-4000-8000-000000000004', null, 'profissional', 'foto_perfil', 'perfil/926-y.jpg', 'image/jpeg', 100, 'aprovada'),
  ('c9260000-0000-4000-8000-0000000000d3', 'c9260000-0000-4000-8000-000000000005', 'c9260000-0000-4000-8000-0000000000a1', 'estabelecimento', 'foto_perfil', 'perfil/926-a.jpg', 'image/jpeg', 100, 'aprovada'),
  ('c9260000-0000-4000-8000-0000000000d4', 'c9260000-0000-4000-8000-000000000006', 'c9260000-0000-4000-8000-0000000000b1', 'estabelecimento', 'foto_perfil', 'perfil/926-b.jpg', 'image/jpeg', 100, 'aprovada');

-- Uma denúncia, como a conta `conta`, com os pedaços do corpo que variam.
create function pg_temp.denunciar(conta uuid, tipo text, alvo uuid, midia uuid) returns jsonb language sql as $$
  select pg_temp.erro(conta, format(
    $x$ select public.denunciar(%L, %L::uuid, 'outro', 'relato com mais de dez caracteres', gen_random_uuid(), null, %L::uuid) $x$, tipo, alvo, midia))
$$;

select is((select count(*)::int from privado.midia where id::text like 'c9260000-%' and estado = 'aprovada' and denuncias_distintas = 0), 4,
  '0 as quatro mídias começam aprovadas e sem denúncia');

-- ── A. Denunciar X com a foto de Y ────────────────────────────────────────────

select is((pg_temp.denunciar('c9260000-0000-4000-8000-000000000001', 'profissional', (select prof_x from ids), (select foto_y from ids)))->>'code',
  'campo_invalido', 'A1 a conta 1 denuncia X com a foto de Y: 422 campo_invalido');
select is((pg_temp.denunciar('c9260000-0000-4000-8000-000000000001', 'profissional', (select prof_x from ids), (select foto_y from ids)))->>'details',
  'midia_id', 'A2 e o details é midia_id');
select is((pg_temp.denunciar('c9260000-0000-4000-8000-000000000002', 'profissional', (select prof_x from ids), (select foto_y from ids)))->>'status',
  '422', 'A3 a conta 2 também: 422');
select is((select estado from privado.midia where id = (select foto_y from ids)), 'aprovada', 'A4 a foto de Y segue aprovada, com duas contas tentando');
select is((select denuncias_distintas from privado.midia where id = (select foto_y from ids)), 0::smallint, 'A5 e sem nenhuma denúncia contada');
select is((select count(*)::int from public.ocorrencia where midia_id = (select foto_y from ids)), 0, 'A6 nenhuma ocorrência aponta para a foto de Y');

-- ── B. Denunciar a casa A com o logo da casa B ────────────────────────────────

select is((pg_temp.denunciar('c9260000-0000-4000-8000-000000000001', 'estabelecimento', (select casa_a from ids), (select logo_b from ids)))->>'details',
  'midia_id', 'B1 a conta 1 denuncia a casa A com o logo da casa B: 422 midia_id');
select is((pg_temp.denunciar('c9260000-0000-4000-8000-000000000002', 'estabelecimento', (select casa_a from ids), (select logo_b from ids)))->>'code',
  'campo_invalido', 'B2 a conta 2 também: 422 campo_invalido');
select is((select estado from privado.midia where id = (select logo_b from ids)), 'aprovada', 'B3 o logo da casa B segue aprovado');
select is((select count(*)::int from public.ocorrencia where midia_id = (select logo_b from ids)), 0, 'B4 e nenhuma ocorrência aponta para ele');

-- ── C. Cruzar os tipos ────────────────────────────────────────────────────────

select is((pg_temp.denunciar('c9260000-0000-4000-8000-000000000001', 'estabelecimento', (select casa_a from ids), (select foto_x from ids)))->>'details',
  'midia_id', 'C1 a casa A com a foto pessoal de X: 422 midia_id');
select is((pg_temp.denunciar('c9260000-0000-4000-8000-000000000001', 'profissional', (select prof_x from ids), (select logo_a from ids)))->>'details',
  'midia_id', 'C2 o profissional X com o logo da casa A: 422 midia_id');

-- Um logo de casa cujo "dono" na tabela é o próprio X: ainda assim não vale como a foto pessoal de X (a foto pessoal não tem casa).
insert into privado.midia (id, dono_usuario_id, estabelecimento_id, dono_tipo, tipo, storage_path, mime, bytes, estado) values
  ('c9260000-0000-4000-8000-0000000000d5', 'c9260000-0000-4000-8000-000000000003', 'c9260000-0000-4000-8000-0000000000b1', 'estabelecimento', 'foto_perfil', 'perfil/926-b2.jpg', 'image/jpeg', 100, 'em_analise');
select is((pg_temp.denunciar('c9260000-0000-4000-8000-000000000001', 'profissional', (select prof_x from ids), 'c9260000-0000-4000-8000-0000000000d5'))->>'details',
  'midia_id', 'C3 uma mídia de casa, ainda que com X como dono_usuario_id, não vale como a foto de perfil de X');

-- ── D. Controles: com a foto do próprio alvo a denúncia entra e duas contas ocultam ──

select is((pg_temp.como('c9260000-0000-4000-8000-000000000001', format(
  $x$ select public.denunciar('profissional', %L::uuid, 'outro', 'relato com mais de dez caracteres', gen_random_uuid(), null, %L::uuid) $x$, (select prof_x from ids), (select foto_x from ids))))->>'tipo',
  'denuncia', 'D1 a conta 1 denuncia X com a foto de X: entra');
select is((select denuncias_distintas from privado.midia where id = (select foto_x from ids)), 1::smallint, 'D2 e a foto de X conta uma denúncia');
select is((pg_temp.como('c9260000-0000-4000-8000-000000000002', format(
  $x$ select public.denunciar('profissional', %L::uuid, 'outro', 'relato com mais de dez caracteres', gen_random_uuid(), null, %L::uuid) $x$, (select prof_x from ids), (select foto_x from ids))))->>'tipo',
  'denuncia', 'D3 a conta 2 também');
select is((select estado from privado.midia where id = (select foto_x from ids)), 'ocultada', 'D4 duas contas distintas ocultam a foto de X (a do denunciado)');
select is((select estado from privado.midia where id = (select foto_y from ids)), 'aprovada', 'D5 e a de Y continua aprovada');

select is((pg_temp.como('c9260000-0000-4000-8000-000000000001', format(
  $x$ select public.denunciar('estabelecimento', %L::uuid, 'outro', 'relato com mais de dez caracteres', gen_random_uuid(), null, %L::uuid) $x$, (select casa_a from ids), (select logo_a from ids))))->>'tipo',
  'denuncia', 'D6 a casa A com o logo da casa A: a denúncia entra');
select is((select denuncias_distintas from privado.midia where id = (select logo_a from ids)), 1::smallint, 'D7 e o logo da casa A conta uma denúncia');
select is((select denuncias_distintas from privado.midia where id = (select logo_b from ids)), 0::smallint, 'D8 e o da casa B segue em zero');

select * from finish();
rollback;
