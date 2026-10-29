-- 768_privado_json_estabelecimento_funcao_inclusos.sql
-- Cobertura direta dos três montadores de JSON das RPCs de leitura (contrato openapi.yaml):
--   privado.estabelecimento_em_json(estabelecimento, papel_membro)  -> objeto `Estabelecimento`
--   privado.funcao_em_json(funcao)                                   -> objeto `Funcao`
--   privado.inclusos_em_json(vaga)                                   -> objeto `Inclusos`
-- São funções IMMUTABLE e puras: o que se prova é o formato exato (nome de campo, nível,
-- coordenadas na ordem latitude/longitude) que os três clientes nativos leem.
--
-- Mutantes que estes testes matam (ver PR):
--   M1  trocar latitude/longitude em estabelecimento_em_json  -> teste 1 fica vermelho
--   M2  `papel` fixo em 'administrador'                       -> teste 2 fica vermelho
--   M3  trocar nome/categoria em funcao_em_json               -> teste 3 fica vermelho
--   M4  trocar inclui_refeicao/inclui_transporte               -> testes 4 e 5 ficam vermelhos

begin;
select plan(7);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
-- Relógio fixo ANTES dos dados (docs/TESTES-PGTAP-PADROES.md, seção 3).
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76800000-0000-4000-8000-0000000000a1', 'contratante',  'Dono 768', '+5561976800001', 'dono-768@t.test', '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('76800000-0000-4000-8000-0000000000b1', 'profissional', 'Pro 768',  '+5561976800002', 'pro-768@t.test',  '1995-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('76800000-0000-4000-8000-0000000000e1', 'Casa 768', '76800000000001', 'food_service', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('76800000-0000-4000-8000-0000000000a1', '76800000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76800000-0000-4000-8000-0000000000c1', '76800000-0000-4000-8000-0000000000b1',
   'POINT(-47.88 -15.79)'::extensions.geography);

-- Vaga com uma posição confirmada para o profissional e, opcionalmente, um turno.
-- Devolve o id do turno (ou o da posição, quando p_turno = 'nenhum').
create function pg_temp.montar(p_inicio timestamptz, p_fim timestamptz, p_turno text default 'verificado')
returns uuid language plpgsql as $$
declare v_vaga uuid; v_pos uuid; v_turno uuid;
begin
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente,
                           publicado_por, publicado_em)
  values ('76800000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          '76800000-0000-4000-8000-0000000000a1', p_inicio - interval '1 day')
  returning id into v_vaga;
  insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_vaga, 'confirmada', '76800000-0000-4000-8000-0000000000c1', p_inicio - interval '12 hours', p_inicio, p_fim)
  returning id into v_pos;
  if p_turno = 'nenhum' then return v_pos; end if;
  if p_turno = 'verificado' then
    insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
    values (v_pos, p_inicio, 'geolocalizado', 50, 'verificado', 12000) returning id into v_turno;
  else
    insert into public.turno (posicao_id, valor_acordado_centavos)
    values (v_pos, 12000) returning id into v_turno;
  end if;
  return v_turno;
end $$;

update public.estabelecimento set regiao_administrativa = 'Taguatinga'
 where id = '76800000-0000-4000-8000-0000000000e1';

insert into public.funcao (id, nome, categoria, ativo) values
  ('76800000-0000-4000-8000-0000000000f1', 'Função Teste 768', 'categoria_teste', false);

-- Duas vagas com combinações opostas de inclusos, para que trocar dois campos não passe por simetria.
create temp table pos as select
  pg_temp.montar('2026-10-21 10:00+00', '2026-10-21 14:00+00', 'nenhum') as a,
  pg_temp.montar('2026-10-22 10:00+00', '2026-10-22 14:00+00', 'nenhum') as b;
create temp table t as select
  (select vaga_id from public.posicao where id = pos.a) as vaga_a,
  (select vaga_id from public.posicao where id = pos.b) as vaga_b
  from pos;
update public.vaga set inclui_refeicao = false, inclui_transporte = true, exige_material_proprio = true
 where id = (select vaga_b from t);

-- 1. estabelecimento_em_json: todos os campos do contrato, coordenadas em {latitude, longitude}.
select is(
  (select privado.estabelecimento_em_json(e, 'administrador') from public.estabelecimento e
    where e.id = '76800000-0000-4000-8000-0000000000e1'),
  '{"id":"76800000-0000-4000-8000-0000000000e1","nome":"Casa 768","documento":"76800000000001",
    "tipo":"food_service","endereco":"CLN 201 Bloco A","regiao_administrativa":"Taguatinga",
    "ponto":{"latitude":-15.7942,"longitude":-47.8822},"papel":"administrador"}'::jsonb,
  'estabelecimento_em_json devolve o objeto Estabelecimento completo, com latitude e longitude no lugar certo');

-- 2. O papel é o do chamador, não uma constante.
select is(
  (select privado.estabelecimento_em_json(e, 'operador') ->> 'papel' from public.estabelecimento e
    where e.id = '76800000-0000-4000-8000-0000000000e1'),
  'operador', 'estabelecimento_em_json devolve o papel recebido');

-- 3. funcao_em_json: id, nome e categoria — `ativo` é interno e não sai.
select is(
  (select privado.funcao_em_json(f) from public.funcao f where f.id = '76800000-0000-4000-8000-0000000000f1'),
  '{"id":"76800000-0000-4000-8000-0000000000f1","nome":"Função Teste 768","categoria":"categoria_teste"}'::jsonb,
  'funcao_em_json devolve id, nome e categoria, sem a coluna interna ativo');

-- 4-5. inclusos_em_json: as três flags nos nomes do contrato, em duas combinações opostas.
select is(
  (select privado.inclusos_em_json(v) from public.vaga v where v.id = (select vaga_a from t)),
  '{"inclui_refeicao":true,"inclui_transporte":false,"exige_material_proprio":false}'::jsonb,
  'inclusos_em_json: refeição sim, transporte não, material não');
select is(
  (select privado.inclusos_em_json(v) from public.vaga v where v.id = (select vaga_b from t)),
  '{"inclui_refeicao":false,"inclui_transporte":true,"exige_material_proprio":true}'::jsonb,
  'inclusos_em_json: refeição não, transporte sim, material sim');

-- 6. Pureza: os três são IMMUTABLE (podem ser usados em índice e em SELECT de lista sem custo escondido).
select is(
  (select array_agg(p.provolatile::text order by p.proname) from pg_proc p
    where p.pronamespace = 'privado'::regnamespace
      and p.proname in ('estabelecimento_em_json', 'funcao_em_json', 'inclusos_em_json')),
  array['i', 'i', 'i'], 'os três montadores são IMMUTABLE');

-- 7. Execução fechada para os papéis da API.
select is(
  (select bool_or(has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
     from pg_proc p
    where p.pronamespace = 'privado'::regnamespace
      and p.proname in ('estabelecimento_em_json', 'funcao_em_json', 'inclusos_em_json')),
  false, 'anon e authenticated não executam os montadores direto');

select * from finish();
rollback;
