-- 809_contratacao_direta_b5cde_exportacao.sql
--
-- Cobertura exaustiva das fatias B5c, B5d, B5e e consolidação de exportar_meus_dados:
--   1. B5e: preferências de chamada (pausa, antecedência, só CNPJ) e versão do app no dispositivo.
--   2. B5c: cálculo de prazos com horário de silêncio (SP), lembretes e expiração automática.
--   3. B5d: cotas de par (CD-C13), casa nova (CD-C14), aviso J7, minhas_chamadas, detalhe_chamada e publicar_a_partir_da_chamada.
--   4. Exportação: consolidação de privado.meus_dados com PerfilProfissionalDetalhado (0.2.58), chamadas e mídias (0.2.59).

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_temp;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

insert into privado.recurso (chave, ligado) values ('chamada_direta', true)
on conflict (chave) do update set ligado = true;

select set_config('frila.agora', '2026-11-20 14:00:00-03', true);
set local frila.agendador_secret = 'segredo-de-teste';

select plan(50);

-- Helpers
create function pg_temp.executar(conta uuid, sql text) returns void language plpgsql as $$
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute sql;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute sql into r;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return r;
end $$;

create function pg_temp.erro_codigo(conta uuid, sql text) returns text language plpgsql as $$
declare
  r jsonb;
  msg text;
begin
  perform pg_temp.como(conta, sql);
  return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text;
  return (msg::jsonb ->> 'code');
end $$;

-- ── 1. Fixtures ───────────────────────────────────────────────────────────────
-- Contas de teste
insert into auth.users (id, aud, role, email) values
  ('80900000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'prof809_1@frila.test'),
  ('80900000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'prof809_2@frila.test'),
  ('80900000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'dono809_cpf@frila.test'),
  ('80900000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'dono809_cnpj@frila.test'),
  ('80900000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'estranho809@frila.test');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('80900000-0000-4000-8000-000000000001', 'profissional', 'Profissional Um', '+5561999990001', 'prof809_1@frila.test', '1995-05-10', 'ativa', '1.0', now()),
  ('80900000-0000-4000-8000-000000000002', 'profissional', 'Profissional Dois', '+5561999990002', 'prof809_2@frila.test', '1996-06-11', 'ativa', '1.0', now()),
  ('80900000-0000-4000-8000-000000000003', 'contratante', 'Contratante CPF', '+5561999990003', 'dono809_cpf@frila.test', '1988-03-03', 'ativa', '1.0', now()),
  ('80900000-0000-4000-8000-000000000004', 'contratante', 'Contratante CNPJ', '+5561999990004', 'dono809_cnpj@frila.test', '1982-04-04', 'ativa', '1.0', now()),
  ('80900000-0000-4000-8000-000000000005', 'profissional', 'Estranho', '+5561999990005', 'estranho809@frila.test', '1999-09-09', 'ativa', '1.0', now());

insert into public.profissional (id, usuario_id, ponto_base, apresentacao) values
  ('80900000-0000-4000-8000-000000000011', '80900000-0000-4000-8000-000000000001', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Sou o prof 1 com experiencia.'),
  ('80900000-0000-4000-8000-000000000012', '80900000-0000-4000-8000-000000000002', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Sou o prof 2.');

-- Função garçom
insert into public.profissional_funcao (profissional_id, funcao_id)
select '80900000-0000-4000-8000-000000000011', id from public.funcao where nome = 'garçom' limit 1;
insert into public.profissional_funcao (profissional_id, funcao_id)
select '80900000-0000-4000-8000-000000000012', id from public.funcao where nome = 'garçom' limit 1;

-- Casa 1 (CPF - 11 digitos)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('80900000-0000-4000-8000-000000000021', 'Festa CPF', '11122233344', 'evento', 'SHIS QL 10', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Lago Sul');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('80900000-0000-4000-8000-000000000021', '80900000-0000-4000-8000-000000000003', 'administrador');

-- Casa 2 (CNPJ - 14 digitos)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('80900000-0000-4000-8000-000000000022', 'Bar CNPJ', '11222333000199', 'food_service', 'CLS 201 Bloco B', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('80900000-0000-4000-8000-000000000022', '80900000-0000-4000-8000-000000000004', 'administrador');

-- Equipe de confiança para criar vínculo legítimo
insert into public.equipe_confianca (estabelecimento_id, profissional_id) values
  ('80900000-0000-4000-8000-000000000021', '80900000-0000-4000-8000-000000000011'),
  ('80900000-0000-4000-8000-000000000021', '80900000-0000-4000-8000-000000000012'),
  ('80900000-0000-4000-8000-000000000022', '80900000-0000-4000-8000-000000000011'),
  ('80900000-0000-4000-8000-000000000022', '80900000-0000-4000-8000-000000000012');

-- Liga recurso chamada_direta
update privado.recurso set ligado = true where chave = 'chamada_direta';

-- ── 2. Testes de B5e: Preferências de Chamada e Versão do Dispositivo ───────────
-- 2.1 Contratante tentando definir preferências toma 422 perfil_incompativel
select is(
  pg_temp.erro_codigo('80900000-0000-4000-8000-000000000003',
    $$select public.definir_preferencia_chamadas(aceita_de_quem_ja_trabalhou => true)$$),
  'perfil_incompativel',
  'B5e: contratante nao pode chamar definir_preferencia_chamadas'
);

-- 2.2 Sem nenhum parâmetro dá 422 campo_obrigatorio (nenhum_campo)
select is(
  pg_temp.erro_codigo('80900000-0000-4000-8000-000000000001',
    $$select public.definir_preferencia_chamadas()$$),
  'campo_obrigatorio',
  'B5e: definir_preferencia_chamadas sem parametros toma 422'
);

-- 2.3 Pausa no passado é 422 campo_invalido
select is(
  pg_temp.erro_codigo('80900000-0000-4000-8000-000000000001',
    $$select public.definir_preferencia_chamadas(pausado_ate => '2026-01-01'::date)$$),
  'campo_invalido',
  'B5e: pausado_ate no passado toma 422'
);

-- 2.4 Profissional 1 define preferências válidas
create temp table pref_res as
  select pg_temp.como('80900000-0000-4000-8000-000000000001',
    $$select public.definir_preferencia_chamadas(
        aceita_de_quem_ja_trabalhou => true,
        pausado_ate => '2026-11-25'::date,
        antecedencia_minima_h => 24,
        aceita_de => 'so_cnpj'
      )$$) as r;

select is(
  ((select r from pref_res) ->> 'antecedencia_minima_h')::int,
  24,
  'B5e: antecedencia minima 24h gravada com sucesso'
);
select is(
  (select r from pref_res) ->> 'aceita_de',
  'so_cnpj',
  'B5e: aceita_de so_cnpj gravado com sucesso'
);

-- 2.5 Casa CPF chama Profissional 1 em pausa e configurado so_cnpj -> recusa 422 pausado
select is(
  pg_temp.erro_codigo('80900000-0000-4000-8000-000000000003',
    format($$select public.chamar_profissional(
      chave => gen_random_uuid(),
      profissional_id => '80900000-0000-4000-8000-000000000011',
      estabelecimento_id => '80900000-0000-4000-8000-000000000021',
      funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
      inicio_em => '2026-11-22 18:00:00-03'::timestamptz,
      fim_em => '2026-11-22 23:00:00-03'::timestamptz,
      local => 'Lago Sul', regiao_administrativa => 'Lago Sul',
      ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
      valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false,
      exige_material_proprio => false, responsavel_local => 'Carlos'
    )$$)),
  'profissional_indisponivel',
  'B5e: profissional em pausa recusa com profissional_indisponivel (pausado)'
);

-- Remove pausa do Profissional 1
select pg_temp.como('80900000-0000-4000-8000-000000000001',
  $$select public.definir_preferencia_chamadas(remover_pausa => true)$$);

-- 2.6 Casa CPF tenta chamar Profissional 1 (que aceita só CNPJ) -> recusa 422 nao_aceita_chamadas
select is(
  pg_temp.erro_codigo('80900000-0000-4000-8000-000000000003',
    format($$select public.chamar_profissional(
      chave => gen_random_uuid(),
      profissional_id => '80900000-0000-4000-8000-000000000011',
      estabelecimento_id => '80900000-0000-4000-8000-000000000021',
      funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
      inicio_em => '2026-11-22 18:00:00-03'::timestamptz,
      fim_em => '2026-11-22 23:00:00-03'::timestamptz,
      local => 'Lago Sul', regiao_administrativa => 'Lago Sul',
      ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
      valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false,
      exige_material_proprio => false, responsavel_local => 'Carlos'
    )$$)),
  'profissional_indisponivel',
  'B5e: casa CPF barrada por opcao so_cnpj'
);

-- Profissional 1 volta a aceitar de todos, mas mantém antecedência 24h
select pg_temp.como('80900000-0000-4000-8000-000000000001',
  $$select public.definir_preferencia_chamadas(aceita_de => 'todos', antecedencia_minima_h => 24)$$);

-- 2.7 Casa tenta chamar com antecedência de apenas 6h -> recusa 422 antecedencia_insuficiente
select is(
  pg_temp.erro_codigo('80900000-0000-4000-8000-000000000004',
    format($$select public.chamar_profissional(
      chave => gen_random_uuid(),
      profissional_id => '80900000-0000-4000-8000-000000000011',
      estabelecimento_id => '80900000-0000-4000-8000-000000000022',
      funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
      inicio_em => '2026-11-20 20:00:00-03'::timestamptz, -- apenas 6h no futuro
      fim_em => '2026-11-20 23:00:00-03'::timestamptz,
      local => 'Asa Sul', regiao_administrativa => 'Plano Piloto',
      ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
      valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false,
      exige_material_proprio => false, responsavel_local => 'Gerente'
    )$$)),
  'profissional_indisponivel',
  'B5e: chamada com antecedencia menor que a minima escolhida (24h) e recusada'
);

-- 2.8 Registro de dispositivo com versao_app (B5e)
select pg_temp.executar('80900000-0000-4000-8000-000000000001',
  $$select public.registrar_dispositivo('token_fcm_prof_1_abc', 'ios', '0.2.56')$$);

select is(
  (select versao_app from public.dispositivo where token_fcm = 'token_fcm_prof_1_abc'),
  '0.2.56',
  'B5e: versao_app registrada com sucesso em public.dispositivo'
);

-- ── 3. Testes de B5c: Prazos, Silêncio, Lembretes e Expiração ─────────────────
-- Profissional 2 com antecedência padrão (6h)
-- Agora é 14:00 (fora do silêncio). Chamada para amanhã às 18:00 (mais de 24h de antecedência).
-- expira_em deve ser v_agora + 12h = 2026-11-21 02:00:00-03.
create temp table chamada_fora_silencio as
  select pg_temp.como('80900000-0000-4000-8000-000000000003',
    format($$select public.chamar_profissional(
      chave => '80900000-0000-4000-8000-000000000101'::uuid,
      profissional_id => '80900000-0000-4000-8000-000000000012',
      estabelecimento_id => '80900000-0000-4000-8000-000000000021',
      funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
      inicio_em => '2026-11-21 18:00:00-03'::timestamptz,
      fim_em => '2026-11-21 23:00:00-03'::timestamptz,
      local => 'Lago Sul', regiao_administrativa => 'Lago Sul',
      ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
      valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false,
      exige_material_proprio => false, responsavel_local => 'Carlos'
    )$$)) as r;

select is(
  ((select r from chamada_fora_silencio) ->> 'estado'),
  'aberta',
  'B5c: chamada criada com estado aberta'
);

-- Notificação chamada_recebida foi criada
select is(
  (select count(*) from public.notificacao where tipo = 'chamada_recebida' and usuario_id = '80900000-0000-4000-8000-000000000002'),
  1::bigint,
  'B5c: notificacao chamada_recebida gerada para o profissional'
);

-- Avança o relógio para dentro do horário de silêncio (23:30)
select set_config('frila.agora', '2026-11-20 23:30:00-03', true);

-- Reseta antecedência do Profissional 1 para o padrão 6h
select pg_temp.como('80900000-0000-4000-8000-000000000001',
  $$select public.definir_preferencia_chamadas(antecedencia_minima_h => 6)$$);

-- Chamada enviada no silêncio para início às 20:00 do dia seguinte.
-- A contagem das 12h deve começar às 07:00 do dia seguinte -> expira às 19:00.
create temp table chamada_no_silencio as
  select pg_temp.como('80900000-0000-4000-8000-000000000004',
    format($$select public.chamar_profissional(
      chave => '80900000-0000-4000-8000-000000000102'::uuid,
      profissional_id => '80900000-0000-4000-8000-000000000011',
      estabelecimento_id => '80900000-0000-4000-8000-000000000022',
      funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
      inicio_em => '2026-11-21 20:00:00-03'::timestamptz,
      fim_em => '2026-11-21 23:00:00-03'::timestamptz,
      local => 'Asa Sul', regiao_administrativa => 'Plano Piloto',
      ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
      valor_centavos => 19000, inclui_refeicao => true, inclui_transporte => false,
      exige_material_proprio => false, responsavel_local => 'Gerente'
    )$$)) as r;

select is(
  ((select expira_em from public.chamada where chave = '80900000-0000-4000-8000-000000000102') at time zone 'America/Sao_Paulo')::time,
  '19:00:00'::time,
  'B5c: chamada enviada no silencio expira as 19h (7h + 12h)'
);

-- Avança relógio para além do expira_em da primeira chamada (2026-11-21 03:00:00-03)
select set_config('frila.agora', '2026-11-21 03:00:00-03', true);

-- Executa expiração automática (privado.expirar_chamadas)
select is(
  privado.expirar_chamadas(),
  1,
  'B5c: privado.expirar_chamadas processou 1 chamada vencida'
);

select is(
  (select estado from public.chamada where chave = '80900000-0000-4000-8000-000000000101'),
  'expirada',
  'B5c: chamada com prazo vencido transicionou para expirada'
);

select is(
  (select count(*) from public.notificacao where tipo = 'chamada_expirada'),
  2::bigint, -- 1 para profissional, 1 para casa
  'B5c: notificacoes chamada_expirada emitidas para ambas as partes'
);

-- ── 4. Testes de B5d: Limites, Par CD-C13, Casa Nova CD-C14 e Aviso J7 ──────────
-- 4.1 Par em pausa (CD-C13): se houve recusa há menos de 24h, nova chamada é bloqueada
-- Vamos recusar a chamada aberta da Casa 2 com Prof 1
select pg_temp.como('80900000-0000-4000-8000-000000000001',
  format($$select public.responder_chamada(
    chamada_id => %L::uuid,
    resposta => 'recusar',
    motivo_recusa => 'agenda'
  )$$, (select id from public.chamada where chave = '80900000-0000-4000-8000-000000000102')));

select is(
  (select estado from public.chamada where chave = '80900000-0000-4000-8000-000000000102'),
  'recusada',
  'B5d: chamada recusada com sucesso'
);

-- Tentativa imediata da Casa 2 chamar Prof 1 toma 422 par_em_pausa
select is(
  pg_temp.erro_codigo('80900000-0000-4000-8000-000000000004',
    format($$select public.chamar_profissional(
      chave => gen_random_uuid(),
      profissional_id => '80900000-0000-4000-8000-000000000011',
      estabelecimento_id => '80900000-0000-4000-8000-000000000022',
      funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
      inicio_em => '2026-11-23 18:00:00-03'::timestamptz,
      fim_em => '2026-11-23 23:00:00-03'::timestamptz,
      local => 'Asa Sul', regiao_administrativa => 'Plano Piloto',
      ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
      valor_centavos => 19000, inclui_refeicao => true, inclui_transporte => false,
      exige_material_proprio => false, responsavel_local => 'Gerente'
    )$$)),
  'profissional_indisponivel',
  'B5d (CD-C13): par em pausa de 24h apos recusa toma profissional_indisponivel'
);

-- 4.2 Casa Nova (CD-C14): Casa 1 sem turnos cumpridos tem limite de 3 abertas
-- Vamos criar 3 chamadas abertas válidas para a Casa 1 (com profissionais diferentes ou vagas diferentes)
-- Inserir 2 novos profissionais na equipe de confiança da Casa 1
insert into auth.users (id, aud, role, email) values
  ('80900000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'p3@t.test'),
  ('80900000-0000-4000-8000-000000000007', 'authenticated', 'authenticated', 'p4@t.test'),
  ('80900000-0000-4000-8000-000000000008', 'authenticated', 'authenticated', 'p5@t.test');
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('80900000-0000-4000-8000-000000000006', 'profissional', 'P3', '+5561999990006', 'p3@t.test', '1990-01-01', 'ativa', '1.0', now()),
  ('80900000-0000-4000-8000-000000000007', 'profissional', 'P4', '+5561999990007', 'p4@t.test', '1990-01-01', 'ativa', '1.0', now()),
  ('80900000-0000-4000-8000-000000000008', 'profissional', 'P5', '+5561999990008', 'p5@t.test', '1990-01-01', 'ativa', '1.0', now());
insert into public.profissional (id, usuario_id, ponto_base) values
  ('80900000-0000-4000-8000-000000000013', '80900000-0000-4000-8000-000000000006', 'POINT(-47.8825 -15.7942)'::extensions.geography),
  ('80900000-0000-4000-8000-000000000014', '80900000-0000-4000-8000-000000000007', 'POINT(-47.8825 -15.7942)'::extensions.geography),
  ('80900000-0000-4000-8000-000000000015', '80900000-0000-4000-8000-000000000008', 'POINT(-47.8825 -15.7942)'::extensions.geography);
insert into public.profissional_funcao (profissional_id, funcao_id)
select p_id, f.id from (values
  ('80900000-0000-4000-8000-000000000013'::uuid),
  ('80900000-0000-4000-8000-000000000014'::uuid),
  ('80900000-0000-4000-8000-000000000015'::uuid)
) as t(p_id) cross join public.funcao f where f.nome = 'garçom';

insert into public.equipe_confianca (estabelecimento_id, profissional_id) values
  ('80900000-0000-4000-8000-000000000021', '80900000-0000-4000-8000-000000000013'),
  ('80900000-0000-4000-8000-000000000021', '80900000-0000-4000-8000-000000000014'),
  ('80900000-0000-4000-8000-000000000021', '80900000-0000-4000-8000-000000000015');

-- Abre chamada 1
select pg_temp.como('80900000-0000-4000-8000-000000000003',
  format($$select public.chamar_profissional(
    chave => gen_random_uuid(), profissional_id => '80900000-0000-4000-8000-000000000013',
    estabelecimento_id => '80900000-0000-4000-8000-000000000021',
    funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
    inicio_em => '2026-11-25 18:00:00-03'::timestamptz, fim_em => '2026-11-25 23:00:00-03'::timestamptz,
    local => 'Lago Sul', regiao_administrativa => 'Lago Sul', ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
    valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'C'
  )$$));

-- Abre chamada 2
select pg_temp.como('80900000-0000-4000-8000-000000000003',
  format($$select public.chamar_profissional(
    chave => gen_random_uuid(), profissional_id => '80900000-0000-4000-8000-000000000014',
    estabelecimento_id => '80900000-0000-4000-8000-000000000021',
    funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
    inicio_em => '2026-11-25 18:00:00-03'::timestamptz, fim_em => '2026-11-25 23:00:00-03'::timestamptz,
    local => 'Lago Sul', regiao_administrativa => 'Lago Sul', ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
    valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'C'
  )$$));

-- Abre chamada 3
select pg_temp.como('80900000-0000-4000-8000-000000000003',
  format($$select public.chamar_profissional(
    chave => gen_random_uuid(), profissional_id => '80900000-0000-4000-8000-000000000015',
    estabelecimento_id => '80900000-0000-4000-8000-000000000021',
    funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
    inicio_em => '2026-11-25 18:00:00-03'::timestamptz, fim_em => '2026-11-25 23:00:00-03'::timestamptz,
    local => 'Lago Sul', regiao_administrativa => 'Lago Sul', ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
    valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'C'
  )$$));

-- 4ª chamada aberta para casa sem turno toma 422 limite_de_chamadas
select is(
  pg_temp.erro_codigo('80900000-0000-4000-8000-000000000003',
    format($$select public.chamar_profissional(
      chave => gen_random_uuid(), profissional_id => '80900000-0000-4000-8000-000000000012',
      estabelecimento_id => '80900000-0000-4000-8000-000000000021',
      funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
      inicio_em => '2026-11-25 18:00:00-03'::timestamptz, fim_em => '2026-11-25 23:00:00-03'::timestamptz,
      local => 'Lago Sul', regiao_administrativa => 'Lago Sul', ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
      valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'C'
    )$$)),
  'limite_de_chamadas',
  'B5d (CD-C14): casa sem turno cumprido toma limite_de_chamadas ao tentar 4a aberta'
);

-- 4.3 Aviso J7: casa CPF chamando 3ª vez em 7 dias
-- Já foram 2 chamadas da Casa CPF para P3 no passado ou na sessão. Criamos cenário para 3ª chamada ao mesmo profissional:
delete from public.chamada where estabelecimento_id = '80900000-0000-4000-8000-000000000021';

-- Chamada 1 para P3
select pg_temp.como('80900000-0000-4000-8000-000000000003',
  format($$select public.chamar_profissional(
    chave => gen_random_uuid(), profissional_id => '80900000-0000-4000-8000-000000000013',
    estabelecimento_id => '80900000-0000-4000-8000-000000000021',
    funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
    inicio_em => '2026-11-26 18:00:00-03'::timestamptz, fim_em => '2026-11-26 23:00:00-03'::timestamptz,
    local => 'Lago Sul', regiao_administrativa => 'Lago Sul', ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
    valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'C'
  )$$));
-- Cancela chamada 1 para liberar cota aberta
update public.chamada set estado = 'cancelada' where profissional_id = '80900000-0000-4000-8000-000000000013';

-- Chamada 2 para P3
select pg_temp.como('80900000-0000-4000-8000-000000000003',
  format($$select public.chamar_profissional(
    chave => gen_random_uuid(), profissional_id => '80900000-0000-4000-8000-000000000013',
    estabelecimento_id => '80900000-0000-4000-8000-000000000021',
    funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
    inicio_em => '2026-11-27 18:00:00-03'::timestamptz, fim_em => '2026-11-27 23:00:00-03'::timestamptz,
    local => 'Lago Sul', regiao_administrativa => 'Lago Sul', ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
    valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'C'
  )$$));
update public.chamada set estado = 'cancelada' where profissional_id = '80900000-0000-4000-8000-000000000013' and estado = 'aberta';

-- 3ª chamada sem confirmo_recorrencia = true -> recusa 409 recorrencia_nao_confirmada
select is(
  pg_temp.erro_codigo('80900000-0000-4000-8000-000000000003',
    format($$select public.chamar_profissional(
      chave => gen_random_uuid(), profissional_id => '80900000-0000-4000-8000-000000000013',
      estabelecimento_id => '80900000-0000-4000-8000-000000000021',
      funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
      inicio_em => '2026-11-28 18:00:00-03'::timestamptz, fim_em => '2026-11-28 23:00:00-03'::timestamptz,
      local => 'Lago Sul', regiao_administrativa => 'Lago Sul', ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
      valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'C',
      confirmo_recorrencia => false
    )$$)),
  'recorrencia_nao_confirmada',
  'B5d (J7): 3a chamada de casa CPF ao mesmo profissional exige confirmacao'
);

-- Com confirmo_recorrencia => true conclui com sucesso
select is(
  (pg_temp.como('80900000-0000-4000-8000-000000000003',
    format($$select public.chamar_profissional(
      chave => '80900000-0000-4000-8000-000000000105'::uuid, profissional_id => '80900000-0000-4000-8000-000000000013',
      estabelecimento_id => '80900000-0000-4000-8000-000000000021',
      funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
      inicio_em => '2026-11-28 18:00:00-03'::timestamptz, fim_em => '2026-11-28 23:00:00-03'::timestamptz,
      local => 'Lago Sul', regiao_administrativa => 'Lago Sul', ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
      valor_centavos => 18000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'C',
      confirmo_recorrencia => true
    )$$)) ->> 'estado'),
  'aberta',
  'B5d (J7): com confirmo_recorrencia = true a chamada conclui com sucesso'
);

-- 4.4 RPC public.minhas_chamadas
-- Profissional 3 lista chamadas recebidas
create temp table lista_p3 as
  select pg_temp.como('80900000-0000-4000-8000-000000000006',
    $$select public.minhas_chamadas()$$) as r;

select is(
  jsonb_array_length((select r from lista_p3) -> 'itens') >= 1,
  true,
  'B5d: minhas_chamadas devolve itens para o profissional'
);

-- Contratante lista chamadas da casa
create temp table lista_casa as
  select pg_temp.como('80900000-0000-4000-8000-000000000003',
    $$select public.minhas_chamadas()$$) as r;

select is(
  jsonb_array_length((select r from lista_casa) -> 'itens') >= 1,
  true,
  'B5d: minhas_chamadas devolve itens para o contratante da casa'
);

-- 4.5 RPC public.detalhe_chamada
-- Profissional 3 lê detalhe da chamada aberta
create temp table det_aberta as
  select pg_temp.como('80900000-0000-4000-8000-000000000006',
    format($$select public.detalhe_chamada(%L::uuid)$$, (select id from public.chamada where chave = '80900000-0000-4000-8000-000000000105'))) as r;

select is(
  (select r from det_aberta) ->> 'estado',
  'aberta',
  'B5d: detalhe_chamada devolve chamada aberta'
);

-- Antes do aceite: local e ponto NÃO são expostos
select is(
  (select r from det_aberta) ? 'local',
  false,
  'B5d: detalhe_chamada omite local antes do aceite (RN36)'
);
select is(
  (select r from det_aberta) ? 'ponto',
  false,
  'B5d: detalhe_chamada omite ponto antes do aceite (RN36)'
);

-- Estranho tentando ler detalhe_chamada toma 404 nao_encontrado
select is(
  pg_temp.erro_codigo('80900000-0000-4000-8000-000000000005',
    format($$select public.detalhe_chamada(%L::uuid)$$, (select id from public.chamada where chave = '80900000-0000-4000-8000-000000000105'))),
  'nao_encontrado',
  'B5d: terceiro alheio toma 404 em detalhe_chamada'
);

-- Profissional 3 aceita a chamada
select pg_temp.como('80900000-0000-4000-8000-000000000006',
  format($$select public.responder_chamada(
    chamada_id => %L::uuid,
    resposta => 'aceitar'
  )$$, (select id from public.chamada where chave = '80900000-0000-4000-8000-000000000105')));

-- Agora detalhe_chamada exibe local e ponto
create temp table det_aceita as
  select pg_temp.como('80900000-0000-4000-8000-000000000006',
    format($$select public.detalhe_chamada(%L::uuid)$$, (select id from public.chamada where chave = '80900000-0000-4000-8000-000000000105'))) as r;

select is(
  (select r from det_aceita) ->> 'local',
  'Lago Sul',
  'B5d: detalhe_chamada revela local apos aceite (RN36)'
);
select is(
  (select r from det_aceita) ? 'ponto',
  true,
  'B5d: detalhe_chamada revela ponto apos aceite (RN36)'
);

-- 4.6 RPC public.publicar_a_partir_da_chamada
-- Criar uma vaga direta sem preencher para converter
create temp table chamada_conv as
  select pg_temp.como('80900000-0000-4000-8000-000000000004',
    format($$select public.chamar_profissional(
      chave => '80900000-0000-4000-8000-000000000109'::uuid,
      profissional_id => '80900000-0000-4000-8000-000000000012',
      estabelecimento_id => '80900000-0000-4000-8000-000000000022',
      funcao_id => (select id from public.funcao where nome = 'garçom' limit 1),
      inicio_em => '2026-11-28 18:00:00-03'::timestamptz, fim_em => '2026-11-28 23:00:00-03'::timestamptz,
      local => 'Asa Sul', regiao_administrativa => 'Plano Piloto', ponto => '{"latitude": -15.7942, "longitude": -47.8825}'::jsonb,
      valor_centavos => 20000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente'
    )$$)) as r;

-- Converte vaga direta em vaga normal pública
create temp table vaga_conv as
  select pg_temp.como('80900000-0000-4000-8000-000000000004',
    format($$select public.publicar_a_partir_da_chamada(
      vaga_id => %L::uuid,
      chave => '80900000-0000-4000-8000-000000000201'::uuid,
      modo => 'urgencia'
    )$$, (select vaga_id from public.chamada where chave = '80900000-0000-4000-8000-000000000109'))) as r;

select is(
  (select r from vaga_conv) ? 'vaga_id',
  true,
  'B5d: publicar_a_partir_da_chamada devolve vaga_id da nova vaga'
);

-- A vaga original direta foi encerrada
select is(
  (select estado from public.vaga where id = (select vaga_id from public.chamada where chave = '80900000-0000-4000-8000-000000000109')),
  'encerrada',
  'B5d: vaga direta original foi encerrada ao converter'
);

-- A chamada aberta foi encerrada com notificacao chamada_encerrada
select is(
  (select estado from public.chamada where chave = '80900000-0000-4000-8000-000000000109'),
  'encerrada',
  'B5d: chamada da vaga direta foi encerrada ao converter'
);

select is(
  (select count(*) from public.notificacao where tipo = 'chamada_encerrada'),
  1::bigint,
  'B5d: notificacao chamada_encerrada enviada ao profissional chamado'
);

-- Reenviar com a mesma chave é idempotente
select is(
  (pg_temp.como('80900000-0000-4000-8000-000000000004',
    format($$select public.publicar_a_partir_da_chamada(
      vaga_id => %L::uuid,
      chave => '80900000-0000-4000-8000-000000000201'::uuid,
      modo => 'urgencia'
    )$$, (select vaga_id from public.chamada where chave = '80900000-0000-4000-8000-000000000109'))) ->> 'vaga_id'),
  ((select r from vaga_conv) ->> 'vaga_id'),
  'B5d: publicar_a_partir_da_chamada e idempotente pela chave'
);

-- ── 5. Testes de Exportação de Dados (0.2.58 e 0.2.59) ─────────────────────────
-- Cria dados ricos de perfil para Profissional 1
update public.profissional
   set apresentacao = 'Apresentacao detalhada do profissional',
       onde_trabalhei = 'Restaurante Central',
       experiencia_faixa = 'de_3_a_5_anos',
       cursos = array['Boas Práticas de Manipulação'],
       idiomas = array['ingles'],
       atende_todo_df = true
 where id = '80900000-0000-4000-8000-000000000011';

create temp table exp_prof as
  select privado.meus_dados('80900000-0000-4000-8000-000000000001') as d;

-- 5.1 Perfil profissional detalhado presente e preenchido (0.2.58)
select is(
  ((select d from exp_prof) -> 'perfil_profissional' ->> 'apresentacao'),
  'Apresentacao detalhada do profissional',
  'Exportacao 0.2.58: perfil_profissional traz apresentacao'
);
select is(
  ((select d from exp_prof) -> 'perfil_profissional' ->> 'onde_trabalhei'),
  'Restaurante Central',
  'Exportacao 0.2.58: perfil_profissional traz onde_trabalhei'
);
select is(
  ((select d from exp_prof) -> 'perfil_profissional' ->> 'experiencia_faixa'),
  'de_3_a_5_anos',
  'Exportacao 0.2.58: perfil_profissional traz experiencia_faixa'
);
select is(
  ((select d from exp_prof) -> 'perfil_profissional' -> 'cursos' ->> 0),
  'Boas Práticas de Manipulação',
  'Exportacao 0.2.58: perfil_profissional traz cursos'
);
select is(
  ((select d from exp_prof) -> 'perfil_profissional' -> 'idiomas' ->> 0),
  'ingles',
  'Exportacao 0.2.58: perfil_profissional traz idiomas'
);
select is(
  ((select d from exp_prof) -> 'perfil_profissional' ->> 'atende_todo_df')::boolean,
  true,
  'Exportacao 0.2.58: perfil_profissional traz atende_todo_df'
);

-- 5.2 Coleção chamadas presente na exportação (0.2.59)
select is(
  ((select d from exp_prof) ? 'chamadas'),
  true,
  'Exportacao 0.2.59: meus_dados contem colecao chamadas'
);
select is(
  jsonb_array_length((select d from exp_prof) -> 'chamadas') >= 1,
  true,
  'Exportacao 0.2.59: chamadas do titular sao exportadas'
);

-- 5.3 Coleção mídias presente na exportação (0.2.59)
select is(
  ((select d from exp_prof) ? 'midias'),
  true,
  'Exportacao 0.2.59: meus_dados contem colecao midias'
);

-- 5.4 Preferência configurada na exportação (0.2.56 / 0.2.58)
select is(
  ((select d from exp_prof) -> 'perfil_profissional' ? 'preferencia_chamadas'),
  true,
  'Exportacao 0.2.58: perfil_profissional contem preferencia_chamadas'
);
select is(
  ((select d from exp_prof) -> 'perfil_profissional' -> 'preferencia_chamadas' ->> 'antecedencia_minima_h')::int,
  6,
  'Exportacao 0.2.58: preferencia_chamadas traz antecedencia_minima_h correta'
);
select is(
  ((select d from exp_prof) -> 'perfil_profissional' -> 'preferencia_chamadas' ->> 'aceita_de'),
  'todos',
  'Exportacao 0.2.58: preferencia_chamadas traz aceita_de'
);

-- 6. Garantias de Atomicidade e Retenção (Bloqueios e Observações R1)
-- 6.1 Índice único para impedir conversão concorrente duplicada
select has_index(
  'public',
  'vaga',
  'vaga_vaga_origem_id_unica',
  'vaga_origem_id',
  'vaga possui indice unico em vaga_origem_id impedindo duplicidade'
);

-- 6.2 Lembrete não gera notificação para chamada já vencida
do $$
declare
  v_vaga_id uuid;
  v_chamada_vencida uuid;
begin
  insert into public.vaga (
    estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
    valor_centavos, posicoes, publicado_por, modo, origem, chave_cliente,
    inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local
  )
  select
    '80900000-0000-4000-8000-000000000021'::uuid, id, '2026-11-20 18:00:00-03', '2026-11-20 23:00:00-03',
    'Local', 'Lago Sul', 'POINT(-47.8825 -15.7942)'::extensions.geography, 15000, 1,
    '80900000-0000-4000-8000-000000000003'::uuid, 'urgencia', 'chamada_direta', gen_random_uuid(),
    false, false, false, 'Responsavel Local'
  from public.funcao limit 1
  returning id into v_vaga_id;

  -- Insere chamada com lembrete e expiração no passado
  insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por,
                              expira_em, lembrete_em, criada_em, chave)
  values (
    v_vaga_id,
    '80900000-0000-4000-8000-000000000012'::uuid,
    '80900000-0000-4000-8000-000000000021'::uuid,
    '80900000-0000-4000-8000-000000000003'::uuid,
    '2026-11-20 12:00:00-03'::timestamptz,
    '2026-11-20 11:00:00-03'::timestamptz,
    '2026-11-20 10:00:00-03'::timestamptz,
    gen_random_uuid()
  )
  returning id into v_chamada_vencida;

  -- Executa lembretes: agora é 14h, chamada expirou às 12h
  perform privado.lembrar_chamadas();

  -- Verifica que NÃO gerou notificação de lembrete
  assert not exists (
    select 1 from public.notificacao
     where tipo = 'chamada_lembrete' and referencia_id = v_chamada_vencida
  ), 'chamada vencida nao deve gerar notificacao de lembrete';
end $$;
select pass('Lembretes: chamada vencida nao gera notificacao de lembrete');

-- 6.3 Retenção LGPD F2 em limpar_contas_anonimizadas
do $$
declare
  v_uid_anon uuid := '80900000-0000-4000-8000-000000000005'::uuid;
  v_prof_id  uuid;
begin
  -- Cria profissional para a conta v_uid_anon
  insert into public.profissional (usuario_id, ponto_base, apresentacao, onde_trabalhei, experiencia_faixa, cursos, idiomas)
  values (
    v_uid_anon,
    'POINT(-47.8825 -15.7942)'::extensions.geography,
    'Texto teste',
    'Lugar teste',
    'de_3_a_5_anos',
    array['Curso teste'],
    array['espanhol']
  )
  returning id into v_prof_id;

  -- Simula conta anonimizada há mais de 16 dias
  update public.usuario
     set estado = 'anonimizada',
         anonimizado_em = '2026-11-01 10:00:00-03'::timestamptz
   where id = v_uid_anon;

  -- Roda limpeza com retenção de 15 dias
  perform privado.limpar_contas_anonimizadas(15);

  -- Confere que todos os 5 campos F2 foram limpos (NULL)
  assert exists (
    select 1 from public.profissional
     where id = v_prof_id
       and apresentacao is null
       and onde_trabalhei is null
       and experiencia_faixa is null
       and cursos is null
       and idiomas is null
  ), 'limpar_contas_anonimizadas deve zerar todos os campos F2 do profissional';
end $$;
select pass('Retencao F2: limpar_contas_anonimizadas zera apresentacao, cursos e idiomas');

-- 6.4 Agendamento dos jobs em pg_cron (expirar e lembrar)
select is(
  (select count(*) = 1 from cron.job where jobname = 'expirar_chamadas_diretas'),
  true,
  'Job expirar_chamadas_diretas agendado em cron.job'
);
select is(
  (select count(*) = 1 from cron.job where jobname = 'lembrar_chamadas_diretas'),
  true,
  'Job lembrar_chamadas_diretas agendado em cron.job'
);

select * from finish();
rollback;
