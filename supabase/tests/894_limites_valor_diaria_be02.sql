-- 894_limites_valor_diaria_be02.sql · BE-02: piso (R$ 50 = 5000 centavos) e teto (R$ 2.000 = 200000 centavos)
-- do valor da diária por posição, centralizados em privado.limites_valor_diaria_centavos().
--
-- Prova:
--   1. Fonte única de verdade (privado.limites_valor_diaria_centavos) devolve (5000, 200000) e não é
--      executável por anon/authenticated (apenas service_role).
--   2. public.publicar_vaga recusa 4999, 0, -100, 200001 e 9223372036854775807 (bigint máximo) com
--      422 campo_invalido (details = valor_centavos) e aceita as bordas exatas 5000 e 200000.
--   3. public.publicar_escala recusa 4999, 200001 e 9223372036854775807 com
--      422 campo_invalido (details = vagas[0].valor_centavos) e aceita escala com 5000 e 200000.
--   4. public.chamar_profissional recusa 4999, 200001 e 9223372036854775807 com
--      422 campo_invalido (details = valor_centavos) e aceita as bordas exatas 5000 e 200000.
--   5. Linhas históricas fora da faixa (100 e 500000 centavos) continuam legíveis e permitem transições
--      de estado (ex: cancelamento), enquanto republicar_vaga de uma vaga histórica fora da faixa é
--      recusada com 422 campo_invalido (valor_centavos).
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-23 12:00:00+00', true);
select plan(23);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

create function pg_temp.resultado(conta uuid, sql text) returns jsonb language plpgsql as $$
declare v_estado text; v_msg text; v_detalhe text;
begin
  perform pg_temp.como(conta, sql);
  return '{"ok": true}'::jsonb;
exception when others then
  get stacked diagnostics v_estado = returned_sqlstate, v_msg = message_text, v_detalhe = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  if v_msg !~ '^\s*\{' then return jsonb_build_object('sqlstate', v_estado, 'message', v_msg); end if;
  return jsonb_build_object('sqlstate', v_estado, 'status', (nullif(v_detalhe, '')::jsonb ->> 'status')::int,
                            'code', v_msg::jsonb ->> 'code', 'details', v_msg::jsonb ->> 'details');
end $$;

-- ── Fixtures ──────────────────────────────────────────────────────────────────
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c8940000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '@t894.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 3) n;

select pg_temp.como('c8940000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante', 'Contratante 894', '+5561955558941', '1990-01-01', '2026-09-22') $$);
select pg_temp.como('c8940000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional', 'Profissional A 894', '+5561955558942', '1990-01-01', '2026-09-22') $$);
select pg_temp.como('c8940000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional', 'Profissional B 894', '+5561955558943', '1990-01-01', '2026-09-22') $$);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c8940000-0000-4000-8000-0000000000e1', 'Casa 894', '89412345000101', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c8940000-0000-4000-8000-000000000001', 'c8940000-0000-4000-8000-0000000000e1', 'administrador');

insert into public.profissional (usuario_id, ponto_base)
values ('c8940000-0000-4000-8000-000000000002', 'POINT(-47.8822 -15.7800)'::extensions.geography),
       ('c8940000-0000-4000-8000-000000000003', 'POINT(-47.8822 -15.7800)'::extensions.geography);

insert into public.profissional_funcao (profissional_id, funcao_id)
select p.id, (select f.id from public.funcao f where f.nome = 'garçom')
  from public.profissional p where p.usuario_id::text like 'c8940000-%';

insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c8940000-0000-4000-8000-0000000000e1', p.id
  from public.profissional p where p.usuario_id::text like 'c8940000-%';

update privado.recurso set ligado = true where chave = 'chamada_direta';
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do nothing;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select p.usuario_id, 'tok-894-' || p.usuario_id, 'ios', '1.2.0'
  from public.profissional p where p.usuario_id::text like 'c8940000-%'
on conflict (token_fcm) do nothing;

create function pg_temp.sql_publicar_vaga(valor bigint) returns text language sql as $$
  select format($a$ select public.publicar_vaga(
    estabelecimento_id => 'c8940000-0000-4000-8000-0000000000e1',
    funcao_id => %L,
    inicio_em => '2026-11-24 18:00+00',
    fim_em => '2026-11-24 23:00+00',
    local => 'CLN 201',
    ponto => '{"latitude":-15.7942,"longitude":-47.8822}'::jsonb,
    valor_centavos => %s,
    posicoes => 1,
    inclui_refeicao => true,
    inclui_transporte => false,
    exige_material_proprio => false,
    responsavel_local => 'Maitre',
    modo => 'urgencia',
    chave => %L,
    regiao_administrativa => 'Plano Piloto') $a$,
    (select f.id from public.funcao f where f.nome = 'garçom'),
    valor,
    gen_random_uuid()) $$;

create function pg_temp.sql_publicar_escala(vagas_json jsonb) returns text language sql as $$
  select format($a$ select public.publicar_escala(
    estabelecimento_id => 'c8940000-0000-4000-8000-0000000000e1',
    evento => '{"nome":"Evento 894","data":"2026-11-25","local":"CLN 201","regiao_administrativa":"Plano Piloto","ponto":{"latitude":-15.7942,"longitude":-47.8822}}'::jsonb,
    vagas => %L::jsonb,
    chave => %L) $a$,
    vagas_json::text,
    gen_random_uuid()) $$;

create function pg_temp.item_escala(valor bigint, inicio text default '2026-11-25T18:00:00Z', fim text default '2026-11-25T23:00:00Z')
returns jsonb language sql as $$
  select jsonb_build_object(
    'funcao_id', (select f.id from public.funcao f where f.nome = 'garçom'),
    'inicio_em', inicio,
    'fim_em', fim,
    'valor_centavos', valor,
    'posicoes', 1,
    'inclui_refeicao', true,
    'inclui_transporte', false,
    'exige_material_proprio', false,
    'responsavel_local', 'Maitre',
    'modo', 'urgencia') $$;

create function pg_temp.sql_chamar(prof_usuario uuid, valor bigint, inicio text default '2026-11-24 18:00+00', fim text default '2026-11-24 23:00+00')
returns text language sql as $$
  select format($a$ select public.chamar_profissional(
    chave => %L,
    profissional_id => %L,
    estabelecimento_id => 'c8940000-0000-4000-8000-0000000000e1',
    funcao_id => %L,
    inicio_em => %L,
    fim_em => %L,
    local => 'CLN 201',
    regiao_administrativa => 'Plano Piloto',
    ponto => '{"latitude":-15.7942,"longitude":-47.8822}'::jsonb,
    valor_centavos => %s,
    inclui_refeicao => true,
    inclui_transporte => false,
    exige_material_proprio => false,
    responsavel_local => 'Maitre') $a$,
    gen_random_uuid(),
    (select p.id from public.profissional p where p.usuario_id = prof_usuario),
    (select f.id from public.funcao f where f.nome = 'garçom'),
    inicio, fim, valor) $$;

-- ── 1. Fonte única de verdade e permissões ────────────────────────────────────
select results_eq(
  $$ select piso_centavos, teto_centavos from privado.limites_valor_diaria_centavos() $$,
  $$ values (5000::bigint, 200000::bigint) $$,
  '1. privado.limites_valor_diaria_centavos() devolve piso 5000 e teto 200000');

select results_eq(
  $$ select has_function_privilege('anon', 'privado.limites_valor_diaria_centavos()', 'EXECUTE'),
            has_function_privilege('authenticated', 'privado.limites_valor_diaria_centavos()', 'EXECUTE'),
            has_function_privilege('service_role', 'privado.limites_valor_diaria_centavos()', 'EXECUTE') $$,
  $$ values (false, false, true) $$,
  '2. privado.limites_valor_diaria_centavos() revogada de anon/authenticated e liberada para service_role');

-- ── 2. public.publicar_vaga: bordas e valores extremos ────────────────────────
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(4999)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  '3. publicar_vaga: 4999 (abaixo do piso) -> 422 campo_invalido');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(0)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  '4. publicar_vaga: 0 -> 422 campo_invalido');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(-100)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  '5. publicar_vaga: -100 -> 422 campo_invalido');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(200001)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  '6. publicar_vaga: 200001 (acima do teto) -> 422 campo_invalido');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(9223372036854775807)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  '7. publicar_vaga: bigint máximo (9223372036854775807) -> 422 campo_invalido');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(5000)),
  '{"ok": true}'::jsonb,
  '8. publicar_vaga: 5000 (piso exato) é aceito');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(200000)),
  '{"ok": true}'::jsonb,
  '9. publicar_vaga: 200000 (teto exato) é aceito');

-- ── 3. public.publicar_escala: bordas e valores extremos ──────────────────────
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_publicar_escala(jsonb_build_array(pg_temp.item_escala(4999)))),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "vagas[0].valor_centavos"}'::jsonb,
  '10. publicar_escala: 4999 -> 422 campo_invalido (vagas[0].valor_centavos)');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_publicar_escala(jsonb_build_array(pg_temp.item_escala(200001)))),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "vagas[0].valor_centavos"}'::jsonb,
  '11. publicar_escala: 200001 -> 422 campo_invalido (vagas[0].valor_centavos)');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_publicar_escala(jsonb_build_array(pg_temp.item_escala(9223372036854775807)))),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "vagas[0].valor_centavos"}'::jsonb,
  '12. publicar_escala: bigint máximo -> 422 campo_invalido (vagas[0].valor_centavos)');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_publicar_escala(jsonb_build_array(
              pg_temp.item_escala(5000, '2026-11-25T18:00:00Z', '2026-11-25T23:00:00Z'),
              pg_temp.item_escala(200000, '2026-11-25T19:00:00Z', '2026-11-25T23:30:00Z')))),
  '{"ok": true}'::jsonb,
  '13. publicar_escala: 5000 e 200000 (bordas exatas) são aceitos');

-- ── 4. public.chamar_profissional: bordas e valores extremos ──────────────────
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000002', 4999)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  '14. chamar_profissional: 4999 -> 422 campo_invalido');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000002', 200001)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  '15. chamar_profissional: 200001 -> 422 campo_invalido');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000002', 9223372036854775807)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  '16. chamar_profissional: bigint máximo -> 422 campo_invalido');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000002', 5000, '2026-11-26 18:00+00', '2026-11-26 23:00+00')),
  '{"ok": true}'::jsonb,
  '17. chamar_profissional: 5000 (piso exato) é aceito');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000003', 200000, '2026-11-27 18:00+00', '2026-11-27 23:00+00')),
  '{"ok": true}'::jsonb,
  '18. chamar_profissional: 200000 (teto exato) é aceito');

-- ── 5. Linhas históricas fora da faixa não quebram leitura nem transição ──────
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, modo, publicado_por, chave_cliente)
values
  ('c8940000-0000-4000-8000-0000000000f1', 'c8940000-0000-4000-8000-0000000000e1',
   (select f.id from public.funcao f where f.nome = 'garçom'),
   '2026-11-28 18:00+00', '2026-11-28 23:00+00', 'CLN 201', 'Plano Piloto',
   'POINT(-47.8822 -15.7942)'::extensions.geography,
   100, 1, true, false, false, 'Maitre', 'urgencia', 'c8940000-0000-4000-8000-000000000001', gen_random_uuid()),
  ('c8940000-0000-4000-8000-0000000000f2', 'c8940000-0000-4000-8000-0000000000e1',
   (select f.id from public.funcao f where f.nome = 'garçom'),
   '2026-11-28 18:00+00', '2026-11-28 23:00+00', 'CLN 201', 'Plano Piloto',
   'POINT(-47.8822 -15.7942)'::extensions.geography,
   500000, 1, true, false, false, 'Maitre', 'urgencia', 'c8940000-0000-4000-8000-000000000001', gen_random_uuid());

select results_eq(
  $$ select id, valor_centavos from public.vaga
      where id in ('c8940000-0000-4000-8000-0000000000f1', 'c8940000-0000-4000-8000-0000000000f2')
      order by valor_centavos $$,
  $$ values ('c8940000-0000-4000-8000-0000000000f1'::uuid, 100::bigint),
            ('c8940000-0000-4000-8000-0000000000f2'::uuid, 500000::bigint) $$,
  '19. vagas históricas fora da faixa (100 e 500000) continuam legíveis');

select lives_ok(
  $$ update public.vaga set estado = 'cancelada'
      where id = 'c8940000-0000-4000-8000-0000000000f1' $$,
  '20. transição de estado em vaga histórica abaixo do piso (100) não quebra');

select lives_ok(
  $$ update public.vaga set estado = 'encerrada'
      where id = 'c8940000-0000-4000-8000-0000000000f2' $$,
  '21. transição de estado em vaga histórica acima do teto (500000) não quebra');

-- Republicar vaga histórica fora da faixa é recusado pela nova regra
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            format($$ select public.republicar_vaga('c8940000-0000-4000-8000-0000000000f1',
                      '2026-11-29 18:00+00', '2026-11-29 23:00+00', %L) $$, gen_random_uuid())),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  '22. republicar_vaga de vaga histórica abaixo do piso (100) -> 422 campo_invalido');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            format($$ select public.republicar_vaga('c8940000-0000-4000-8000-0000000000f2',
                      '2026-11-29 18:00+00', '2026-11-29 23:00+00', %L) $$, gen_random_uuid())),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_invalido", "details": "valor_centavos"}'::jsonb,
  '23. republicar_vaga de vaga histórica acima do teto (500000) -> 422 campo_invalido');

select * from finish();
rollback;
