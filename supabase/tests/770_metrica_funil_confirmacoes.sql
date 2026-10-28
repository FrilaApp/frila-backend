-- 770_metrica_funil_confirmacoes.sql
-- Cobertura da view metrica.funil_confirmacoes (Plano de Métricas, funil do piloto): uma linha por
-- posição CONFIRMADA, com o tempo entre a publicação da vaga e a confirmação. Fica fora do funil
-- tudo o que não é tração real: conta de demonstração e conta da equipe Frila, em qualquer das
-- duas pontas (quem publicou e quem foi confirmado).
--
-- Mutantes (CREATE OR REPLACE VIEW) que estes testes matam (ver PR):
--   V1  não excluir publicador de demonstração               -> teste 4 fica vermelho
--   V2  não excluir profissional de demonstração             -> teste 5 fica vermelho
--   V3  não excluir publicador da equipe                     -> teste 6 fica vermelho
--   V4  não excluir profissional da equipe                   -> teste 7 fica vermelho
--   V5  `dia` em UTC em vez de America/Sao_Paulo             -> teste 2 fica vermelho
--   V6  tirar o `confirmado_em IS NOT NULL`                  -> teste 8 fica vermelho
--   V7  duração em minutos em vez de segundos                -> testes 1 e 3 ficam vermelhos

begin;
select plan(11);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
-- Relógio fixo ANTES dos dados (docs/TESTES-PGTAP-PADROES.md, seção 3).
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('77000000-0000-4000-8000-0000000000a1', 'contratante',  'Dono 770', '+5561977000001', 'dono-770@t.test', '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('77000000-0000-4000-8000-0000000000b1', 'profissional', 'Pro 770',  '+5561977000002', 'pro-770@t.test',  '1995-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('77000000-0000-4000-8000-0000000000e1', 'Casa 770', '77000000000001', 'food_service', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('77000000-0000-4000-8000-0000000000a1', '77000000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('77000000-0000-4000-8000-0000000000c1', '77000000-0000-4000-8000-0000000000b1',
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
  values ('77000000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          '77000000-0000-4000-8000-0000000000a1', p_inicio - interval '1 day')
  returning id into v_vaga;
  insert into public.posicao (vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_vaga, 'confirmada', '77000000-0000-4000-8000-0000000000c1', p_inicio - interval '12 hours', p_inicio, p_fim)
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

-- Outras pontas do funil: publicador de demonstração (a2), publicador da equipe (a3), profissional
-- de demonstração (b2/c2) e profissional da equipe (b3/c3).
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em, demonstracao) values
  ('77000000-0000-4000-8000-0000000000a2', 'contratante',  'Dono demo 770',   '+5561977000003', 'demo-770@t.test',  '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00', true),
  ('77000000-0000-4000-8000-0000000000a3', 'contratante',  'Dono equipe 770', '+5561977000004', 'equipe-770@t.test','1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00', false),
  ('77000000-0000-4000-8000-0000000000b2', 'profissional', 'Pro demo 770',    '+5561977000005', 'pdemo-770@t.test', '1994-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00', true),
  ('77000000-0000-4000-8000-0000000000b3', 'profissional', 'Pro equipe 770',  '+5561977000006', 'pequipe-770@t.test','1993-01-01','ativa', '2026-09-22', '2026-09-22 12:00:00+00', false);
insert into public.profissional (id, usuario_id, ponto_base) values
  ('77000000-0000-4000-8000-0000000000c2', '77000000-0000-4000-8000-0000000000b2', 'POINT(-47.88 -15.79)'::extensions.geography),
  ('77000000-0000-4000-8000-0000000000c3', '77000000-0000-4000-8000-0000000000b3', 'POINT(-47.88 -15.79)'::extensions.geography);
insert into privado.conta_equipe (usuario_id) values
  ('77000000-0000-4000-8000-0000000000a3'), ('77000000-0000-4000-8000-0000000000b3');

-- Uma vaga + posição por cenário. Cada linha: (rótulo, publicador, profissional, estado,
-- publicado_em, confirmado_em). Os profissionais reaproveitados (c1) ficam em dias diferentes
-- para o EXCLUDE de sobreposição não reclamar.
create function pg_temp.cenario(p_rotulo text, p_publicador uuid, p_prof uuid, p_estado public.estado_posicao,
                                p_publicado timestamptz, p_confirmado timestamptz, p_dia date)
returns uuid language plpgsql as $$
declare v_vaga uuid; v_pos uuid;
begin
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente,
                           publicado_por, publicado_em)
  values ('77000000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_dia + time '18:00', p_dia + time '22:00', p_rotulo, 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          p_publicador, p_publicado)
  returning id into v_vaga;
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (gen_random_uuid(), v_vaga, p_estado, p_prof, p_confirmado, p_dia + time '18:00', p_dia + time '22:00')
  returning id into v_pos;
  return v_pos;
end $$;

create temp table c as select
  -- 1h entre publicar e confirmar (3600 s), publicada às 02:30Z = 23:30 de 19/10 em Brasília
  pg_temp.cenario('normal',  '77000000-0000-4000-8000-0000000000a1', '77000000-0000-4000-8000-0000000000c1', 'confirmada',
                  '2026-10-20 02:30+00', '2026-10-20 03:30+00', date '2026-10-26') as normal,
  pg_temp.cenario('cumprida','77000000-0000-4000-8000-0000000000a1', '77000000-0000-4000-8000-0000000000c1', 'cumprida',
                  '2026-10-20 15:00+00', '2026-10-20 15:10+00', date '2026-10-27') as cumprida,
  pg_temp.cenario('demo_pub','77000000-0000-4000-8000-0000000000a2', '77000000-0000-4000-8000-0000000000c1', 'confirmada',
                  '2026-10-20 15:00+00', '2026-10-20 15:10+00', date '2026-10-28') as demo_pub,
  pg_temp.cenario('demo_pro','77000000-0000-4000-8000-0000000000a1', '77000000-0000-4000-8000-0000000000c2', 'confirmada',
                  '2026-10-20 15:00+00', '2026-10-20 15:10+00', date '2026-10-26') as demo_pro,
  pg_temp.cenario('eq_pub',  '77000000-0000-4000-8000-0000000000a3', '77000000-0000-4000-8000-0000000000c1', 'confirmada',
                  '2026-10-20 15:00+00', '2026-10-20 15:10+00', date '2026-10-29') as eq_pub,
  pg_temp.cenario('eq_pro',  '77000000-0000-4000-8000-0000000000a1', '77000000-0000-4000-8000-0000000000c3', 'confirmada',
                  '2026-10-20 15:00+00', '2026-10-20 15:10+00', date '2026-10-26') as eq_pro,
  -- cancelada com profissional gravado mas sem confirmado_em: nunca foi confirmada.
  pg_temp.cenario('sem_conf','77000000-0000-4000-8000-0000000000a1', '77000000-0000-4000-8000-0000000000c1', 'cancelada',
                  '2026-10-20 15:00+00', null, date '2026-10-30') as sem_conf;

create function pg_temp.na_view(p_pos uuid) returns bigint language sql as $$
  select count(*) from metrica.funil_confirmacoes where posicao_id = p_pos
$$;

-- 1. Caminho feliz: a posição normal aparece com a duração em SEGUNDOS entre publicar e confirmar.
select is(
  (select duracao_confirmacao_segundos from metrica.funil_confirmacoes where posicao_id = (select normal from c)),
  3600::numeric, 'a posição confirmada entra no funil com a duração em segundos (1 h = 3600)');

-- 2. O dia do funil é o dia de Brasília: 02:30Z de 20/10 é 23:30 de 19/10.
select is(
  (select dia from metrica.funil_confirmacoes where posicao_id = (select normal from c)),
  date '2026-10-19', 'dia é o dia em America/Sao_Paulo (02:30Z de 20/10 cai em 19/10)');

-- 3. Posição cumprida também é confirmada: entra, com os demais campos ligados à vaga.
select is(
  (select array[estabelecimento_id::text, duracao_confirmacao_segundos::int::text]
     from metrica.funil_confirmacoes where posicao_id = (select cumprida from c)),
  array['77000000-0000-4000-8000-0000000000e1', '600'],
  'posição cumprida entra, trazendo o estabelecimento e 600 s');

-- 4-7. Fora do funil: demonstração e equipe, nas duas pontas.
select is(pg_temp.na_view((select demo_pub from c)), 0::bigint, 'vaga publicada por conta de demonstração fica fora');
select is(pg_temp.na_view((select demo_pro from c)), 0::bigint, 'profissional de conta de demonstração fica fora');
select is(pg_temp.na_view((select eq_pub from c)),   0::bigint, 'vaga publicada por conta da equipe Frila fica fora');
select is(pg_temp.na_view((select eq_pro from c)),   0::bigint, 'profissional da equipe Frila fica fora');

-- 8. Posição que nunca foi confirmada (confirmado_em nulo) fica fora, mesmo com profissional gravado.
select is(pg_temp.na_view((select sem_conf from c)), 0::bigint, 'posição sem confirmado_em fica fora');

-- 9. Formato da view: o contrato que o painel do piloto lê.
select columns_are('metrica', 'funil_confirmacoes',
  array['posicao_id', 'vaga_id', 'estabelecimento_id', 'dia', 'publicado_em', 'confirmado_em',
        'duracao_confirmacao_segundos'],
  'a view expõe as sete colunas do funil');

-- 10-11. Acesso: só service_role lê a métrica; os papéis da API não.
select is(
  has_table_privilege('anon', 'metrica.funil_confirmacoes', 'select')
  or has_table_privilege('authenticated', 'metrica.funil_confirmacoes', 'select'),
  false, 'anon e authenticated não leem metrica.funil_confirmacoes');
select is(has_table_privilege('service_role', 'metrica.funil_confirmacoes', 'select'), true,
  'service_role lê metrica.funil_confirmacoes');

select * from finish();
rollback;
