-- 766_privado_posicoes_candidataveis.sql
-- Cobertura direta de privado.posicoes_candidataveis(vaga, agora): quantas posições da vaga ainda
-- aceitam candidatura no instante `agora` (o número que a tela de vagas mostra como "vagas
-- restantes"). A regra de uma posição só está em privado.posicao_candidatavel; aqui se mede a
-- soma por vaga: só as posições DESTA vaga, e só as candidatáveis.
--
-- Mutantes que estes testes matam (ver PR):
--   M1  contar todas as posições da vaga (sem `posicao_candidatavel`)  -> testes 1, 3 e 4 ficam vermelhos
--   M2  remover o filtro `p.vaga_id = vaga` (soma de todas as vagas)   -> testes 1, 3, 4, 5, 6 e 7 ficam vermelhos
--   M3  `count(*)` trocado por `count(distinct p.vaga_id)`             -> testes 1 e 3 ficam vermelhos

begin;
select plan(7);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
-- Relógio fixo ANTES dos dados (docs/TESTES-PGTAP-PADROES.md, seção 3).
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76600000-0000-4000-8000-0000000000a1', 'contratante',  'Dono 766', '+5561976600001', 'dono-766@t.test', '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('76600000-0000-4000-8000-0000000000b1', 'profissional', 'Pro 766',  '+5561976600002', 'pro-766@t.test',  '1995-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('76600000-0000-4000-8000-0000000000e1', 'Casa 766', '76600000000001', 'food_service', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('76600000-0000-4000-8000-0000000000a1', '76600000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76600000-0000-4000-8000-0000000000c1', '76600000-0000-4000-8000-0000000000b1',
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
  values ('76600000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          '76600000-0000-4000-8000-0000000000a1', p_inicio - interval '1 day')
  returning id into v_vaga;
  insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_vaga, 'confirmada', '76600000-0000-4000-8000-0000000000c1', p_inicio - interval '12 hours', p_inicio, p_fim)
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

-- Vaga A (quatro posições) e vaga B (uma), ambas de urgência no dia 22/10.
-- A: f1 aberta futura (conta), f2 aberta futura (conta), f3 aberta já iniciada (não conta),
--    f4 confirmada (não conta).
create function pg_temp.vaga(p_id uuid, p_inicio timestamptz, p_fim timestamptz) returns void
language sql as $$
  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente,
                           publicado_por, publicado_em)
  values (p_id, '76600000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 4, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          '76600000-0000-4000-8000-0000000000a1', p_inicio - interval '1 day')
$$;

select pg_temp.vaga('76600000-0000-4000-8000-0000000000d1', '2026-10-22 18:00+00', '2026-10-22 22:00+00');
select pg_temp.vaga('76600000-0000-4000-8000-0000000000d2', '2026-10-22 18:00+00', '2026-10-22 22:00+00');
select pg_temp.vaga('76600000-0000-4000-8000-0000000000d3', '2026-10-23 18:00+00', '2026-10-23 22:00+00');  -- sem posição alguma

insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em) values
  ('76600000-0000-4000-8000-0000000000d1', 'aberta',    null, null, '2026-10-22 18:00+00', '2026-10-22 22:00+00'),
  ('76600000-0000-4000-8000-0000000000d1', 'aberta',    null, null, '2026-10-22 18:00+00', '2026-10-22 22:00+00'),
  ('76600000-0000-4000-8000-0000000000d1', 'aberta',    null, null, '2026-10-22 12:00+00', '2026-10-22 16:00+00'),  -- já começou em 22/10 14:00
  ('76600000-0000-4000-8000-0000000000d1', 'confirmada', '76600000-0000-4000-8000-0000000000c1',
                                           '2026-10-19 12:00+00', '2026-10-22 18:00+00', '2026-10-22 22:00+00'),
  ('76600000-0000-4000-8000-0000000000d2', 'aberta',    null, null, '2026-10-22 18:00+00', '2026-10-22 22:00+00');

-- 1. Caminho feliz: da vaga A só as duas abertas e ainda por começar.
select is(privado.posicoes_candidataveis('76600000-0000-4000-8000-0000000000d1', '2026-10-22 14:00+00'), 2,
  'conta as posições abertas que ainda não começaram (e só elas)');

-- 2. O tipo é inteiro (a RPC o entrega como número no JSON).
select is(pg_typeof(privado.posicoes_candidataveis('76600000-0000-4000-8000-0000000000d1', '2026-10-22 14:00+00'))::text,
  'integer', 'devolve integer');

-- 3. O relógio é o argumento: antes das 12h a posição "já iniciada" ainda é futura e passa a contar.
select is(privado.posicoes_candidataveis('76600000-0000-4000-8000-0000000000d1', '2026-10-22 11:59+00'), 3,
  'com agora antes do início da terceira posição, ela volta a contar');

-- 4. Depois do início de todas: nenhuma candidatável (nem a confirmada).
select is(privado.posicoes_candidataveis('76600000-0000-4000-8000-0000000000d1', '2026-10-22 18:00+00'), 0,
  'no instante do início (inicio_em > agora é falso) nenhuma posição é candidatável');

-- 5. Isolamento por vaga: a vaga B tem uma, a A tem duas — não se misturam.
select is(privado.posicoes_candidataveis('76600000-0000-4000-8000-0000000000d2', '2026-10-22 14:00+00'), 1,
  'a contagem é só da vaga pedida');

-- 6. Vaga sem posições e vaga inexistente: zero, sem erro.
select is(privado.posicoes_candidataveis('76600000-0000-4000-8000-0000000000d3', '2026-10-22 14:00+00'), 0,
  'vaga sem posições devolve 0');
select is(privado.posicoes_candidataveis('76600000-0000-4000-8000-0000000000ff', '2026-10-22 14:00+00'), 0,
  'vaga inexistente devolve 0 (não é erro)');

select * from finish();
rollback;
