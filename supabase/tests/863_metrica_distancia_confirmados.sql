-- 863_metrica_distancia_confirmados.sql
-- Cobertura das views metrica.distancia_confirmados e metrica.distancia_confirmados_resumo
-- (D02, Cartão imAEq801).
--
-- Mutantes que estes testes matam:
--   V1  não excluir publicador de demonstração               -> teste 11 fica vermelho
--   V2  não excluir profissional de demonstração             -> teste 12 fica vermelho
--   V3  não excluir publicador da equipe                     -> teste 13 fica vermelho
--   V4  não excluir profissional da equipe                   -> teste 14 fica vermelho
--   V5  não filtrar p.estado in ('confirmada', 'cumprida')   -> teste 15 fica vermelho
--   V6  `dia` em UTC em vez de America/Sao_Paulo             -> teste 9 fica vermelho
--   V7  resumo não filtrar janela de 28 dias                 -> teste 16 fica vermelho
--   V8  permissões abertas para anon/authenticated           -> testes 5 e 7 ficam vermelhos

begin;
select plan(16);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- Relógio fixo em 2026-11-16 12:00:00-03
select set_config('frila.agora', '2026-11-16 12:00:00-03', true);

-- ── 1. Setup de Usuários e Estabelecimentos ───────────────────────────────────

-- Usuários reais: contratante A1 e profissional B1
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em) values
  ('86300000-0000-4000-8000-0000000000a1', 'contratante',  'Dono 863', '+5561986300001', 'dono-863@t.test', '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('86300000-0000-4000-8000-0000000000b1', 'profissional', 'Pro 863',  '+5561986300002', 'pro-863@t.test',  '1995-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00');

-- Estabelecimento na Asa Norte (CLN 201: -47.8822, -15.7942)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('86300000-0000-4000-8000-0000000000e1', 'Restaurante 863', '86300000000001', 'food_service', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('86300000-0000-4000-8000-0000000000a1', '86300000-0000-4000-8000-0000000000e1', 'administrador');

-- Profissional com ponto base conhecido (ex: -47.8800, -15.7900)
insert into public.profissional (id, usuario_id, ponto_base) values
  ('86300000-0000-4000-8000-0000000000c1', '86300000-0000-4000-8000-0000000000b1',
   'POINT(-47.8800 -15.7900)'::extensions.geography);

-- Contas de demonstração (a2 contratante demo, b2 profissional demo)
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em, demonstracao) values
  ('86300000-0000-4000-8000-0000000000a2', 'contratante',  'Dono demo 863',   '+5561986300003', 'demo-863@t.test',  '1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00', true),
  ('86300000-0000-4000-8000-0000000000b2', 'profissional', 'Pro demo 863',    '+5561986300005', 'pdemo-863@t.test', '1994-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00', true);

insert into public.profissional (id, usuario_id, ponto_base) values
  ('86300000-0000-4000-8000-0000000000c2', '86300000-0000-4000-8000-0000000000b2', 'POINT(-47.8800 -15.7900)'::extensions.geography);

-- Contas de equipe Frila (a3 contratante equipe, b3 profissional equipe)
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em, demonstracao) values
  ('86300000-0000-4000-8000-0000000000a3', 'contratante',  'Dono equipe 863', '+5561986300004', 'equipe-863@t.test','1980-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00', false),
  ('86300000-0000-4000-8000-0000000000b3', 'profissional', 'Pro equipe 863',  '+5561986300006', 'pequipe-863@t.test','1993-01-01','ativa', '2026-09-22', '2026-09-22 12:00:00+00', false);

insert into public.profissional (id, usuario_id, ponto_base) values
  ('86300000-0000-4000-8000-0000000000c3', '86300000-0000-4000-8000-0000000000b3', 'POINT(-47.8800 -15.7900)'::extensions.geography);

insert into privado.conta_equipe (usuario_id) values
  ('86300000-0000-4000-8000-0000000000a3'), ('86300000-0000-4000-8000-0000000000b3');

-- ── 2. Função Auxiliar de Cenários ─────────────────────────────────────────────

create function pg_temp.cenario(
  p_rotulo text,
  p_publicador uuid,
  p_prof uuid,
  p_estado public.estado_posicao,
  p_publicado timestamptz,
  p_confirmado timestamptz,
  p_inicio timestamptz,
  p_fim timestamptz
)
returns uuid language plpgsql as $$
declare v_vaga uuid; v_pos uuid;
begin
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente,
                           publicado_por, publicado_em)
  values ('86300000-0000-4000-8000-0000000000e1', (select id from public.funcao order by nome limit 1),
          p_inicio, p_fim, p_rotulo, 'POINT(-47.8822 -15.7942)'::extensions.geography,
          12000, 1, true, false, false, 'Responsável', 'urgencia', gen_random_uuid(),
          p_publicador, p_publicado)
  returning id into v_vaga;

  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (gen_random_uuid(), v_vaga, p_estado, p_prof, p_confirmado, p_inicio, p_fim)
  returning id into v_pos;

  return v_pos;
end $$;

-- Cria tabela com os cenários de teste:
-- normal: dentro de 28 dias, confirmada
-- cumprida: dentro de 28 dias, cumprida
-- demo_pub: publicado por demo
-- demo_pro: profissional demo
-- eq_pub: publicado por equipe Frila
-- eq_pro: profissional equipe Frila
-- cancelada: posição cancelada
-- antiga: confirmada, mas com inicio_em há mais de 28 dias (> 28 dias de 2026-11-16)
create temp table c as select
  pg_temp.cenario('normal',  '86300000-0000-4000-8000-0000000000a1', '86300000-0000-4000-8000-0000000000c1', 'confirmada',
                  '2026-11-15 02:30+00', '2026-11-15 03:00+00', '2026-11-15 18:00+00', '2026-11-15 22:00+00') as normal,
  pg_temp.cenario('cumprida','86300000-0000-4000-8000-0000000000a1', '86300000-0000-4000-8000-0000000000c1', 'cumprida',
                  '2026-11-10 10:00+00', '2026-11-10 10:30+00', '2026-11-10 18:00+00', '2026-11-10 22:00+00') as cumprida,
  pg_temp.cenario('demo_pub','86300000-0000-4000-8000-0000000000a2', '86300000-0000-4000-8000-0000000000c1', 'confirmada',
                  '2026-11-12 10:00+00', '2026-11-12 10:30+00', '2026-11-12 18:00+00', '2026-11-12 22:00+00') as demo_pub,
  pg_temp.cenario('demo_pro','86300000-0000-4000-8000-0000000000a1', '86300000-0000-4000-8000-0000000000c2', 'confirmada',
                  '2026-11-12 10:00+00', '2026-11-12 10:30+00', '2026-11-12 18:00+00', '2026-11-12 22:00+00') as demo_pro,
  pg_temp.cenario('eq_pub',  '86300000-0000-4000-8000-0000000000a3', '86300000-0000-4000-8000-0000000000c1', 'confirmada',
                  '2026-11-13 10:00+00', '2026-11-13 10:30+00', '2026-11-13 18:00+00', '2026-11-13 22:00+00') as eq_pub,
  pg_temp.cenario('eq_pro',  '86300000-0000-4000-8000-0000000000a1', '86300000-0000-4000-8000-0000000000c3', 'confirmada',
                  '2026-11-13 10:00+00', '2026-11-13 10:30+00', '2026-11-13 18:00+00', '2026-11-13 22:00+00') as eq_pro,
  pg_temp.cenario('cancelada','86300000-0000-4000-8000-0000000000a1', '86300000-0000-4000-8000-0000000000c1', 'cancelada',
                  '2026-11-14 10:00+00', '2026-11-14 10:30+00', '2026-11-14 18:00+00', '2026-11-14 22:00+00') as cancelada,
  pg_temp.cenario('antiga',  '86300000-0000-4000-8000-0000000000a1', '86300000-0000-4000-8000-0000000000c1', 'confirmada',
                  '2026-10-01 10:00+00', '2026-10-01 10:30+00', '2026-10-01 18:00+00', '2026-10-01 22:00+00') as antiga;

create function pg_temp.na_view(p_pos uuid) returns bigint language sql as $$
  select count(*) from metrica.distancia_confirmados where posicao_id = p_pos;
$$;

-- ── 3. Testes Estruturais e de Privilégios ──────────────────────────────────────

-- 1-2. Existência das views
select has_view('metrica', 'distancia_confirmados', 'view metrica.distancia_confirmados existe');
select has_view('metrica', 'distancia_confirmados_resumo', 'view metrica.distancia_confirmados_resumo existe');

-- 3-4. Contrato de Colunas (sem PII)
select columns_are('metrica', 'distancia_confirmados',
  array['posicao_id', 'vaga_id', 'estabelecimento_id', 'profissional_id', 'dia',
        'publicado_em', 'confirmado_em', 'inicio_em', 'estado_posicao', 'distancia_metros'],
  'metrica.distancia_confirmados expõe exatamente as 10 colunas contratadas sem PII');

select columns_are('metrica', 'distancia_confirmados_resumo',
  array['total_confirmados', 'p50_metros', 'p90_metros', 'p99_metros', 'min_metros', 'max_metros', 'avg_metros'],
  'metrica.distancia_confirmados_resumo expõe as 7 métricas agregadas');

-- 5-6. Privilégios em metrica.distancia_confirmados
select is(
  has_table_privilege('anon', 'metrica.distancia_confirmados', 'select')
  or has_table_privilege('authenticated', 'metrica.distancia_confirmados', 'select'),
  false, 'anon e authenticated não possuem select em metrica.distancia_confirmados');
select is(has_table_privilege('service_role', 'metrica.distancia_confirmados', 'select'), true,
  'service_role possui select em metrica.distancia_confirmados');

-- 7-8. Privilégios em metrica.distancia_confirmados_resumo
select is(
  has_table_privilege('anon', 'metrica.distancia_confirmados_resumo', 'select')
  or has_table_privilege('authenticated', 'metrica.distancia_confirmados_resumo', 'select'),
  false, 'anon e authenticated não possuem select em metrica.distancia_confirmados_resumo');
select is(has_table_privilege('service_role', 'metrica.distancia_confirmados_resumo', 'select'), true,
  'service_role possui select em metrica.distancia_confirmados_resumo');

-- ── 4. Testes de Negócio e Isolamento ──────────────────────────────────────────

-- 9. Posição confirmada normal entra com distância correta e dia de Brasília
-- Ponto restaurante: (-47.8822, -15.7942), Ponto profissional: (-47.8800, -15.7900)
-- Distância calculada via PostGIS: ~521,29 m
select is(
  (select array[
     (distancia_metros between 500 and 550)::text,
     dia::text,
     estado_posicao::text
   ]
   from metrica.distancia_confirmados
   where posicao_id = (select normal from c)),
  array['true', '2026-11-14', 'confirmada'],
  'posição confirmada entra com distância calculada (~521 m), dia fuso Brasília (02:30Z de 15/11 é 23:30 de 14/11) e estado');

-- 10. Posição cumprida entra na view
select is(
  (select count(*) from metrica.distancia_confirmados where posicao_id = (select cumprida from c)),
  1::bigint,
  'posição com estado cumprida entra na view');

-- 11-14. Filtros de Demonstração e Equipe Frila
select is(pg_temp.na_view((select demo_pub from c)), 0::bigint, 'vaga de publicador demonstracao fica fora');
select is(pg_temp.na_view((select demo_pro from c)), 0::bigint, 'profissional demonstracao fica fora');
select is(pg_temp.na_view((select eq_pub from c)),   0::bigint, 'vaga de publicador da equipe Frila fica fora');
select is(pg_temp.na_view((select eq_pro from c)),   0::bigint, 'profissional da equipe Frila fica fora');

-- 15. Posição cancelada não entra na view
select is(pg_temp.na_view((select cancelada from c)), 0::bigint, 'posição cancelada fica fora da view');

-- 16. Resumo estatístico filtra posições com mais de 28 dias de inicio_em
-- As posições elegíveis nos últimos 28 dias criadas neste teste são 'normal' e 'cumprida' (total = 2).
-- A posição 'antiga' (inicio em 2026-10-01, > 28 dias de 2026-11-16) entra em distancia_confirmados mas fica FORA do resumo.
select is(
  (select total_confirmados from metrica.distancia_confirmados_resumo
   where exists (select 1 from metrica.distancia_confirmados where posicao_id = (select normal from c))),
  (select count(*)::bigint from metrica.distancia_confirmados where inicio_em >= privado.agora() - interval '28 days'),
  'metrica.distancia_confirmados_resumo filtra rigorosamente a janela de 28 dias a partir de privado.agora()');

select * from finish();
rollback;
