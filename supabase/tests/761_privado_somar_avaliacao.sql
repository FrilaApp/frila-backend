-- 761_privado_somar_avaliacao.sql
-- Cobertura direta do gatilho privado.somar_avaliacao() (AFTER INSERT em public.avaliacao):
-- mantém os contadores aval_total / aval_positivas de quem foi avaliado (RN07, RF16).
--
-- Mutantes que estes testes matam (ver PR):
--   M1  somar sempre +1 positivo, ignorando `resposta`   -> testes 5, 6, 7 e 8 ficam vermelhos
--   M2  trocar os ramos (profissional <-> estabelecimento) -> testes 3, 5, 6, 7 e 8 ficam vermelhos
--   M3  não incrementar aval_total                        -> o arquivo aborta no CHECK
--       estabelecimento_aval_coerente (positivas > total): a suíte reprova

begin;
select plan(8);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
-- Relógio fixo ANTES dos dados (docs/TESTES-PGTAP-PADROES.md, seção 3).
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('76100000-0000-4000-8000-0000000000a1', 'contratante',  'Dono 761', '+5561976100001', 'dono-761@t.test', '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('76100000-0000-4000-8000-0000000000b1', 'profissional', 'Pro 761',  '+5561976100002', 'pro-761@t.test',  '1995-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('76100000-0000-4000-8000-0000000000e1', 'Casa 761', '76100000000001', 'food_service', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('76100000-0000-4000-8000-0000000000a1', '76100000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('76100000-0000-4000-8000-0000000000c1', '76100000-0000-4000-8000-0000000000b1',
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
  values ('76100000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          '76100000-0000-4000-8000-0000000000a1', p_inicio - interval '1 day')
  returning id into v_vaga;
  insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_vaga, 'confirmada', '76100000-0000-4000-8000-0000000000c1', p_inicio - interval '12 hours', p_inicio, p_fim)
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

-- Dois turnos já terminados e verificados (agora = 20/10 12:00Z), em dias diferentes
-- para o EXCLUDE de sobreposição do profissional (RN21) não reclamar.
create temp table t as select
  pg_temp.montar('2026-10-19 10:00+00', '2026-10-19 14:00+00') as turno_a,
  pg_temp.montar('2026-10-18 10:00+00', '2026-10-18 14:00+00') as turno_b;

-- Linha de base: ninguém avaliado ainda.
select is(
  (select array[aval_total, aval_positivas] from public.profissional where id = '76100000-0000-4000-8000-0000000000c1'),
  array[0, 0], 'linha de base: profissional sem avaliação');
select is(
  (select array[aval_total, aval_positivas] from public.estabelecimento where id = '76100000-0000-4000-8000-0000000000e1'),
  array[0, 0], 'linha de base: estabelecimento sem avaliação');

-- Profissional avalia o estabelecimento (positivo): só o estabelecimento soma.
insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
select turno_a, '76100000-0000-4000-8000-0000000000b1', 'estabelecimento',
       '76100000-0000-4000-8000-0000000000e1', true from t;

select is(
  (select array[aval_total, aval_positivas] from public.estabelecimento where id = '76100000-0000-4000-8000-0000000000e1'),
  array[1, 1], 'voto positivo no estabelecimento: total 1, positivas 1');
select is(
  (select array[aval_total, aval_positivas] from public.profissional where id = '76100000-0000-4000-8000-0000000000c1'),
  array[0, 0], 'voto no estabelecimento não toca no contador do profissional');

-- Segundo turno, voto NEGATIVO no estabelecimento: total sobe, positivas não.
insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
select turno_b, '76100000-0000-4000-8000-0000000000b1', 'estabelecimento',
       '76100000-0000-4000-8000-0000000000e1', false from t;

select is(
  (select array[aval_total, aval_positivas] from public.estabelecimento where id = '76100000-0000-4000-8000-0000000000e1'),
  array[2, 1], 'voto negativo soma no total e não em positivas: 2 e 1');

-- Estabelecimento avalia o profissional: só o profissional soma.
insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
select turno_a, '76100000-0000-4000-8000-0000000000a1', 'profissional',
       '76100000-0000-4000-8000-0000000000c1', false from t;

select is(
  (select array[aval_total, aval_positivas] from public.profissional where id = '76100000-0000-4000-8000-0000000000c1'),
  array[1, 0], 'voto negativo no profissional: total 1, positivas 0');
select is(
  (select array[aval_total, aval_positivas] from public.estabelecimento where id = '76100000-0000-4000-8000-0000000000e1'),
  array[2, 1], 'voto no profissional não toca no contador do estabelecimento');

insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
select turno_b, '76100000-0000-4000-8000-0000000000a1', 'profissional',
       '76100000-0000-4000-8000-0000000000c1', true from t;

select is(
  (select array[aval_total, aval_positivas] from public.profissional where id = '76100000-0000-4000-8000-0000000000c1'),
  array[2, 1], 'segundo voto (positivo) no profissional acumula: 2 e 1');

select * from finish();
rollback;
