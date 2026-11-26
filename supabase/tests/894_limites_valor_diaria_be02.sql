-- 894_limites_valor_diaria_be02.sql · B-124: o piso (R$ 50 = 5000 centavos) e o teto (R$ 2.000 = 200000
-- centavos) da diária por posição deixam de BLOQUEAR (substitui a trava do BE-02, #589). Ficam só como
-- referência de aviso nos apps, em privado.limites_valor_diaria_centavos(). O arquivo mantém o número 894.
--
-- Prova:
--   1. A referência (privado.limites_valor_diaria_centavos) ainda devolve (5000, 200000) e não é executável
--      por anon/authenticated (apenas service_role).
--   2. public.publicar_vaga ACEITA 1, 4999, 5000, 200000, 200001 e 100000000 (R$ 1.000.000,00); RECUSA 0 e
--      negativo com 422 campo_invalido (details valor_centavos); nulo segue 422 campo_obrigatorio.
--   3. public.publicar_escala aceita a mesma lista (numa escala só); recusa 0 e negativo com 422
--      campo_invalido (details vagas[i].valor_centavos), sem gravar evento (atomicidade).
--   4. public.chamar_profissional (vaga direta nova) aceita 1, 4999, 200001 e 100000000 e grava o valor
--      pedido; recusa 0 e negativo com 422 campo_invalido (details valor_centavos).
--   5. Vagas antigas fora da faixa (100 e 500000) continuam legíveis, aceitam transição de estado e AGORA
--      podem ser republicadas (republicar_vaga e republicar_posicoes_restantes), com o valor original.
begin;
set local frila.agendador_secret = 'segredo-de-teste';
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-23 12:00:00+00', true);
select plan(36);

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
  from generate_series(1, 7) n;

select pg_temp.como('c8940000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante', 'Contratante 894', '+5561955558941', '1990-01-01', '2026-09-22') $$);
select pg_temp.como('c8940000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional', 'Profissional A 894', '+5561955558942', '1990-01-01', '2026-09-22') $$);
select pg_temp.como('c8940000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional', 'Profissional B 894', '+5561955558943', '1990-01-01', '2026-09-22') $$);
-- Profissionais 4 a 7: cada chamada aceita deixa uma chamada aberta (409 chamada_ja_aberta na segunda do mesmo
-- profissional na casa), então cada caso aceito usa um profissional; o 7 só recebe as recusas (não fica com chamada).
select pg_temp.como(('c8940000-0000-4000-8000-00000000000' || n)::uuid,
  format($$ select public.criar_conta('profissional', 'Profissional %s 894', '+556195555894%s', '1990-01-01', '2026-09-22') $$, n, n))
  from generate_series(4, 7) n;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c8940000-0000-4000-8000-0000000000e1', 'Casa 894', '89412345000101', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c8940000-0000-4000-8000-000000000001', 'c8940000-0000-4000-8000-0000000000e1', 'administrador');

insert into public.profissional (usuario_id, ponto_base)
select ('c8940000-0000-4000-8000-00000000000' || n)::uuid, 'POINT(-47.8822 -15.7800)'::extensions.geography
  from generate_series(2, 7) n;

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
    coalesce(valor::text, 'null'),
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

create function pg_temp.erro_valor(campo text default 'valor_centavos') returns jsonb language sql as $$
  select jsonb_build_object('sqlstate', 'PGRST', 'status', 422, 'code', 'campo_invalido', 'details', campo) $$;

-- ── 1. Referência de aviso e permissões ───────────────────────────────────────
select results_eq(
  $$ select piso_centavos, teto_centavos from privado.limites_valor_diaria_centavos() $$,
  $$ values (5000::bigint, 200000::bigint) $$,
  '1. privado.limites_valor_diaria_centavos() segue devolvendo a referência: 5000 e 200000');

select results_eq(
  $$ select has_function_privilege('anon', 'privado.limites_valor_diaria_centavos()', 'EXECUTE'),
            has_function_privilege('authenticated', 'privado.limites_valor_diaria_centavos()', 'EXECUTE'),
            has_function_privilege('service_role', 'privado.limites_valor_diaria_centavos()', 'EXECUTE') $$,
  $$ values (false, false, true) $$,
  '2. privado.limites_valor_diaria_centavos() revogada de anon/authenticated e liberada para service_role');

select ok(
  (select obj_description('privado.limites_valor_diaria_centavos()'::regprocedure, 'pg_proc') like '%NINGUÉM bloqueia%'),
  '3. o COMMENT da referência diz que ninguém bloqueia por ela');

-- ── 2. public.publicar_vaga: qualquer valor positivo passa ───────────────────
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(1)),
  '{"ok": true}'::jsonb, '4. publicar_vaga: 1 centavo é aceito');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(4999)),
  '{"ok": true}'::jsonb, '5. publicar_vaga: 4999 (um centavo abaixo da referência de piso) é aceito');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(5000)),
  '{"ok": true}'::jsonb, '6. publicar_vaga: 5000 é aceito');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(200000)),
  '{"ok": true}'::jsonb, '7. publicar_vaga: 200000 é aceito');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(200001)),
  '{"ok": true}'::jsonb, '8. publicar_vaga: 200001 (um centavo acima da referência de teto) é aceito');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(100000000)),
  '{"ok": true}'::jsonb, '9. publicar_vaga: 100000000 (R$ 1.000.000,00) é aceito');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(0)),
  pg_temp.erro_valor(), '10. publicar_vaga: 0 -> 422 campo_invalido (valor_centavos)');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(-100)),
  pg_temp.erro_valor(), '11. publicar_vaga: -100 -> 422 campo_invalido (valor_centavos)');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001', pg_temp.sql_publicar_vaga(null)),
  '{"sqlstate": "PGRST", "status": 422, "code": "campo_obrigatorio", "details": "valor_centavos"}'::jsonb,
  '12. publicar_vaga: valor_centavos NULL -> 422 campo_obrigatorio (não campo_invalido)');

select results_eq(
  $$ select valor_centavos from public.vaga
      where estabelecimento_id = 'c8940000-0000-4000-8000-0000000000e1' and origem = 'publicacao'
        and inicio_em = '2026-11-24 18:00+00' order by valor_centavos $$,
  $$ values (1::bigint), (4999::bigint), (5000::bigint), (200000::bigint), (200001::bigint), (100000000::bigint) $$,
  '13. publicar_vaga gravou exatamente os 6 valores aceitos, e nenhum dos recusados');

-- ── 3. public.publicar_escala: qualquer valor positivo passa ─────────────────
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_publicar_escala(jsonb_build_array(
              pg_temp.item_escala(1, '2026-11-25T18:00:00Z', '2026-11-25T23:00:00Z'),
              pg_temp.item_escala(4999, '2026-11-25T19:00:00Z', '2026-11-25T23:30:00Z'),
              pg_temp.item_escala(5000, '2026-11-25T20:00:00Z', '2026-11-25T23:45:00Z'),
              pg_temp.item_escala(200000, '2026-11-25T21:00:00Z', '2026-11-25T23:50:00Z'),
              pg_temp.item_escala(200001, '2026-11-25T22:00:00Z', '2026-11-25T23:55:00Z'),
              pg_temp.item_escala(100000000, '2026-11-25T22:30:00Z', '2026-11-25T23:59:00Z')))),
  '{"ok": true}'::jsonb,
  '14. publicar_escala: 1, 4999, 5000, 200000, 200001 e 100000000 numa escala só são aceitos');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_publicar_escala(jsonb_build_array(pg_temp.item_escala(0)))),
  pg_temp.erro_valor('vagas[0].valor_centavos'),
  '15. publicar_escala: 0 -> 422 campo_invalido (vagas[0].valor_centavos)');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_publicar_escala(jsonb_build_array(pg_temp.item_escala(-500)))),
  pg_temp.erro_valor('vagas[0].valor_centavos'),
  '16. publicar_escala: -500 -> 422 campo_invalido (vagas[0].valor_centavos)');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_publicar_escala(jsonb_build_array(
              pg_temp.item_escala(1, '2026-11-26T18:00:00Z', '2026-11-26T23:00:00Z'),
              pg_temp.item_escala(0, '2026-11-26T19:00:00Z', '2026-11-26T23:30:00Z')))),
  pg_temp.erro_valor('vagas[1].valor_centavos'),
  '17. publicar_escala heterogênea (item 0 válido, item 1 com 0) -> 422 vagas[1].valor_centavos');

select is((select count(*)::int from public.evento where estabelecimento_id = 'c8940000-0000-4000-8000-0000000000e1'),
  1,
  '18. as escalas recusadas não gravam evento adicional (só a escala aceita de 14)');

select is((select count(*)::int from public.vaga
            where estabelecimento_id = 'c8940000-0000-4000-8000-0000000000e1' and inicio_em::date = '2026-11-26'),
  0,
  '19. a escala heterogênea recusada não deixou vaga gravada (atomicidade)');

-- ── 4. public.chamar_profissional (vaga direta nova): qualquer valor positivo passa
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000002', 1, '2026-12-01 18:00+00', '2026-12-01 23:00+00')),
  '{"ok": true}'::jsonb, '20. chamar_profissional: 1 centavo é aceito');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000003', 4999, '2026-12-02 18:00+00', '2026-12-02 23:00+00')),
  '{"ok": true}'::jsonb, '21. chamar_profissional: 4999 é aceito');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000004', 200001, '2026-12-03 18:00+00', '2026-12-03 23:00+00')),
  '{"ok": true}'::jsonb, '22. chamar_profissional: 200001 é aceito');
-- Casa nova (sem turno cumprido) aceita no máximo 3 chamadas abertas (RN34, CD-C14): libera as 3 abertas para
-- seguir provando o valor. Não é o que este teste mede.
update public.chamada set estado = 'cancelada', respondida_em = privado.agora()
 where estabelecimento_id = 'c8940000-0000-4000-8000-0000000000e1' and estado = 'aberta';

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000005', 100000000, '2026-12-04 18:00+00', '2026-12-04 23:00+00')),
  '{"ok": true}'::jsonb, '23. chamar_profissional: 100000000 (R$ 1.000.000,00) é aceito');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000006', 5000, '2026-12-05 18:00+00', '2026-12-05 23:00+00')),
  '{"ok": true}'::jsonb, '24. chamar_profissional: 5000 é aceito (controle: o valor da referência também passa)');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000007', 0, '2026-12-06 18:00+00', '2026-12-06 23:00+00')),
  pg_temp.erro_valor(), '25. chamar_profissional: 0 -> 422 campo_invalido (valor_centavos)');
select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            pg_temp.sql_chamar('c8940000-0000-4000-8000-000000000007', -1, '2026-12-06 18:00+00', '2026-12-06 23:00+00')),
  pg_temp.erro_valor(), '26. chamar_profissional: -1 -> 422 campo_invalido (valor_centavos)');

select results_eq(
  $$ select g.valor_centavos from public.vaga g
      where g.estabelecimento_id = 'c8940000-0000-4000-8000-0000000000e1' and g.origem = 'chamada_direta'
      order by g.valor_centavos $$,
  $$ values (1::bigint), (4999::bigint), (5000::bigint), (200001::bigint), (100000000::bigint) $$,
  '27. chamar_profissional gravou as vagas diretas com o valor pedido (e nenhuma das recusadas)');

-- ── 5. Vagas antigas fora da faixa: legíveis, com transição e AGORA republicáveis
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, modo, publicado_por, chave_cliente, publicado_em, estado)
values
  ('c8940000-0000-4000-8000-0000000000f1', 'c8940000-0000-4000-8000-0000000000e1',
   (select f.id from public.funcao f where f.nome = 'garçom'),
   '2026-12-10 18:00+00', '2026-12-10 23:00+00', 'CLN 201', 'Plano Piloto',
   'POINT(-47.8822 -15.7942)'::extensions.geography,
   100, 1, true, false, false, 'Maitre', 'urgencia', 'c8940000-0000-4000-8000-000000000001', gen_random_uuid(),
   '2026-11-23 12:00+00', 'publicada'),
  ('c8940000-0000-4000-8000-0000000000f2', 'c8940000-0000-4000-8000-0000000000e1',
   (select f.id from public.funcao f where f.nome = 'garçom'),
   '2026-12-10 18:00+00', '2026-12-10 23:00+00', 'CLN 201', 'Plano Piloto',
   'POINT(-47.8822 -15.7942)'::extensions.geography,
   500000, 1, true, false, false, 'Maitre', 'urgencia', 'c8940000-0000-4000-8000-000000000001', gen_random_uuid(),
   '2026-11-23 12:00+00', 'publicada'),
  -- seleção já fechada (encerrada) que ainda não começou: candidata a republicar_posicoes_restantes
  ('c8940000-0000-4000-8000-0000000000f3', 'c8940000-0000-4000-8000-0000000000e1',
   (select f.id from public.funcao f where f.nome = 'garçom'),
   '2026-12-12 18:00+00', '2026-12-12 23:00+00', 'CLN 201', 'Plano Piloto',
   'POINT(-47.8822 -15.7942)'::extensions.geography,
   100, 1, true, false, false, 'Maitre', 'selecao', 'c8940000-0000-4000-8000-000000000001', gen_random_uuid(),
   '2026-11-23 12:00+00', 'encerrada'),
  ('c8940000-0000-4000-8000-0000000000f4', 'c8940000-0000-4000-8000-0000000000e1',
   (select f.id from public.funcao f where f.nome = 'garçom'),
   '2026-12-13 18:00+00', '2026-12-13 23:00+00', 'CLN 201', 'Plano Piloto',
   'POINT(-47.8822 -15.7942)'::extensions.geography,
   500000, 1, true, false, false, 'Maitre', 'selecao', 'c8940000-0000-4000-8000-000000000001', gen_random_uuid(),
   '2026-11-23 12:00+00', 'encerrada');

select results_eq(
  $$ select id, valor_centavos from public.vaga
      where id in ('c8940000-0000-4000-8000-0000000000f1', 'c8940000-0000-4000-8000-0000000000f2')
      order by valor_centavos $$,
  $$ values ('c8940000-0000-4000-8000-0000000000f1'::uuid, 100::bigint),
            ('c8940000-0000-4000-8000-0000000000f2'::uuid, 500000::bigint) $$,
  '28. vagas antigas fora da faixa (100 e 500000) continuam legíveis');

select lives_ok(
  $$ update public.vaga set estado = 'cancelada' where id = 'c8940000-0000-4000-8000-0000000000f1' $$,
  '29. transição de estado em vaga antiga abaixo da referência (100) não quebra');

select lives_ok(
  $$ update public.vaga set estado = 'encerrada' where id = 'c8940000-0000-4000-8000-0000000000f2' $$,
  '30. transição de estado em vaga antiga acima da referência (500000) não quebra');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            format($$ select public.republicar_vaga('c8940000-0000-4000-8000-0000000000f1',
                      '2026-12-11 18:00+00', '2026-12-11 23:00+00', %L) $$, gen_random_uuid())),
  '{"ok": true}'::jsonb,
  '31. republicar_vaga de vaga antiga abaixo da referência (100) agora é aceita');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            format($$ select public.republicar_vaga('c8940000-0000-4000-8000-0000000000f2',
                      '2026-12-11 18:00+00', '2026-12-11 23:00+00', %L) $$, gen_random_uuid())),
  '{"ok": true}'::jsonb,
  '32. republicar_vaga de vaga antiga acima da referência (500000) agora é aceita');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            format($$ select public.republicar_posicoes_restantes('c8940000-0000-4000-8000-0000000000f3', %L) $$, gen_random_uuid())),
  '{"ok": true}'::jsonb,
  '33. republicar_posicoes_restantes de seleção antiga abaixo da referência (100) agora é aceita');

select is(pg_temp.resultado('c8940000-0000-4000-8000-000000000001',
            format($$ select public.republicar_posicoes_restantes('c8940000-0000-4000-8000-0000000000f4', %L) $$, gen_random_uuid())),
  '{"ok": true}'::jsonb,
  '34. republicar_posicoes_restantes de seleção antiga acima da referência (500000) agora é aceita');

select results_eq(
  $$ select g.valor_centavos from public.vaga g
      where g.republicada_de in ('c8940000-0000-4000-8000-0000000000f3', 'c8940000-0000-4000-8000-0000000000f4')
      order by g.valor_centavos $$,
  $$ values (100::bigint), (500000::bigint) $$,
  '35. as vagas de republicar_posicoes_restantes guardam o valor original das antigas (100 e 500000)');

select results_eq(
  $$ select g.valor_centavos from public.vaga g
      where g.estabelecimento_id = 'c8940000-0000-4000-8000-0000000000e1' and g.inicio_em = '2026-12-11 18:00+00'
      order by g.valor_centavos $$,
  $$ values (100::bigint), (500000::bigint) $$,
  '36. as vagas de republicar_vaga guardam o valor original das antigas (100 e 500000)');

select * from finish();
rollback;
