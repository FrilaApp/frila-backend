-- 709_trg_posicao_reaberta_abre_rodada.sql
--
-- Cobertura pgTAP do trigger posicao_reaberta_abre_rodada e da função privado.abrir_rodada_da_reabertura().
-- Regras de Negócio: US07, US15 (cenário 4), US16 · RN05, RN12, RN22, RN23 · UC05 · decisão 8zLfn0mt item 2.
-- Migração: 20260929110000_rodada_de_despacho.sql:383-407.
--
-- Contexto Arquitetural:
--   Quando uma posição é reaberta por atraso/falta (new.reaberta_por_atraso_de IS NOT NULL),
--   o gatilho AFTER INSERT incrementa vaga.rodada_despacho = vaga.rodada_despacho + 1.
--   Isso abre a rodada seguinte de despacho, permitindo que profissionais elegíveis
--   que já haviam recebido a vaga na publicação inicial recebam uma nova notificação de vaga reaberta,
--   conforme a unicidade de despacho e notificação por (vaga, profissional, rodada).
--
-- 1. Metadados e privilégios mínimos:
--    - Trigger registrado em public.posicao com tipo AFTER INSERT.
--    - privado.abrir_rodada_da_reabertura() com search_path="" vazio fixado.
--    - Privilégios: service_role permitido; authenticated, anon e public negados.
-- 2. Exercício e Borda da Cláusula WHEN:
--    - Insert de posições originais/normais (reaberta_por_atraso_de IS NULL) não aciona o gatilho.
--    - Insert com reaberta_por_atraso_de preenchido incrementa rodada_despacho da vaga em +1.
--    - Incrementos subsequentes avançam a rodada sequencialmente.
--    - Isolamento entre vagas: reabertura em uma vaga não altera a rodada de outra vaga.
--    - Restrição de evento: UPDATE em posição reaberta não aciona o gatilho (restrito a AFTER INSERT).
-- 3. Prova de Mutação:
--    - Sem o trigger (DROP TRIGGER), o insert com reaberta_por_atraso_de não incrementa rodada_despacho.

begin;

-- Pré-requisito canônico: habilitar ambiente de teste e congelar relógio antes de inserir dados
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local timezone = 'UTC';
set local frila.agora = '2026-10-20 12:00:00+00';

select plan(20);

-- ── 1. Metadados e Privilégios Mínimos ───────────────────────────────────────

select has_trigger(
  'public',
  'posicao',
  'posicao_reaberta_abre_rodada',
  'tabela public.posicao possui o trigger posicao_reaberta_abre_rodada'
);

select has_function(
  'privado',
  'abrir_rodada_da_reabertura',
  array[]::text[],
  'privado.abrir_rodada_da_reabertura() existe no schema privado'
);

select function_returns(
  'privado',
  'abrir_rodada_da_reabertura',
  array[]::text[],
  'trigger',
  'privado.abrir_rodada_da_reabertura() retorna trigger'
);

select is_definer(
  'privado',
  'abrir_rodada_da_reabertura',
  array[]::text[],
  'privado.abrir_rodada_da_reabertura() é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'abrir_rodada_da_reabertura' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'privado.abrir_rodada_da_reabertura() possui search_path="" vazio fixado'
);

select ok(
  has_function_privilege('service_role', 'privado.abrir_rodada_da_reabertura()', 'execute'),
  'service_role pode executar privado.abrir_rodada_da_reabertura()'
);

select ok(
  not has_function_privilege('authenticated', 'privado.abrir_rodada_da_reabertura()', 'execute'),
  'authenticated não pode executar privado.abrir_rodada_da_reabertura()'
);

select ok(
  not has_function_privilege('anon', 'privado.abrir_rodada_da_reabertura()', 'execute'),
  'anon não pode executar privado.abrir_rodada_da_reabertura()'
);

select ok(
  not has_function_privilege('public', 'privado.abrir_rodada_da_reabertura()', 'execute'),
  'public não pode executar privado.abrir_rodada_da_reabertura()'
);

-- ── 2. Cenário de Teste (prefixo 709) ──────────────────────────────────────────

-- Inserção de usuário contratante com termos canônicos (sem now()):
insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado
) values (
  '70900000-0000-4000-8000-000000000001', 'contratante', 'Contratante 709',
  '+5561970900001', 'c709@test.com', '1985-01-01', '2026-09-22',
  '2026-10-20 12:00:00+00', 'ativa'
);

insert into public.estabelecimento (
  id, nome, documento, tipo, endereco, ponto, regiao_administrativa
) values (
  '70900000-0000-4000-8000-000000000010', 'Restaurante 709', '99888777000199', 'food_service',
  'SCLN 309 Bloco D', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto'
);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('70900000-0000-4000-8000-000000000010', '70900000-0000-4000-8000-000000000001', 'administrador');

-- Criação de duas vagas independentes (Vaga 1 e Vaga 2), cada uma com rodada_despacho inicial = 1:
insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por
) values
  ('70900000-0000-4000-8000-000000000031', '70900000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8825 -15.7942)'::extensions.geography,
   'Restaurante 709', 15000, 4, true, false, false, 'Gerente 709',
   '2026-10-25 18:00:00+00', '2026-10-25 23:00:00+00', 'direto', 'publicada', 'Plano Piloto',
   '70900000-0000-4000-8000-000000000031', '70900000-0000-4000-8000-000000000001'),
  ('70900000-0000-4000-8000-000000000032', '70900000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8825 -15.7942)'::extensions.geography,
   'Restaurante 709', 15000, 2, true, false, false, 'Gerente 709',
   '2026-10-26 18:00:00+00', '2026-10-26 23:00:00+00', 'direto', 'publicada', 'Plano Piloto',
   '70900000-0000-4000-8000-000000000032', '70900000-0000-4000-8000-000000000001');

select is(
  (select rodada_despacho from public.vaga where id = '70900000-0000-4000-8000-000000000031'),
  1,
  'vaga 1 nasce com rodada_despacho = 1 na publicacao'
);

select is(
  (select rodada_despacho from public.vaga where id = '70900000-0000-4000-8000-000000000032'),
  1,
  'vaga 2 nasce com rodada_despacho = 1 na publicacao'
);

-- Inserção de posições originais normais (reaberta_por_atraso_de IS NULL):
insert into public.posicao (
  id, vaga_id, estado, inicio_em, fim_em, reaberta_por_atraso_de
) values
  ('70900000-0000-4000-8000-000000000041', '70900000-0000-4000-8000-000000000031', 'aberta', '2026-10-25 18:00:00+00', '2026-10-25 23:00:00+00', null),
  ('70900000-0000-4000-8000-000000000042', '70900000-0000-4000-8000-000000000031', 'aberta', '2026-10-25 18:00:00+00', '2026-10-25 23:00:00+00', null),
  ('70900000-0000-4000-8000-000000000043', '70900000-0000-4000-8000-000000000031', 'aberta', '2026-10-25 18:00:00+00', '2026-10-25 23:00:00+00', null),
  ('70900000-0000-4000-8000-000000000051', '70900000-0000-4000-8000-000000000032', 'aberta', '2026-10-26 18:00:00+00', '2026-10-26 23:00:00+00', null);

-- ── 3. Disparo Negativo: Cláusula WHEN com reaberta_por_atraso_de IS NULL ────

select is(
  (select rodada_despacho from public.vaga where id = '70900000-0000-4000-8000-000000000031'),
  1,
  'clausula WHEN: insert de posicoes normais com reaberta_por_atraso_de IS NULL mantem rodada_despacho em 1'
);

select is(
  (select rodada_despacho from public.vaga where id = '70900000-0000-4000-8000-000000000032'),
  1,
  'clausula WHEN: insert de posicoes normais na vaga 2 mantem rodada_despacho em 1'
);

-- ── 4. Disparo Positivo: Reabertura por atraso incrementa rodada_despacho ─────

-- Inserção da primeira posição reaberta na vaga 1 (reabrindo a posição 709...0041):
insert into public.posicao (
  id, vaga_id, estado, inicio_em, fim_em, reaberta_por_atraso_de
) values (
  '70900000-0000-4000-8000-000000000061',
  '70900000-0000-4000-8000-000000000031',
  'aberta',
  '2026-10-25 18:00:00+00',
  '2026-10-25 23:00:00+00',
  '70900000-0000-4000-8000-000000000041'
);

select is(
  (select rodada_despacho from public.vaga where id = '70900000-0000-4000-8000-000000000031'),
  2,
  'disparo positivo: insert de posicao com reaberta_por_atraso_de incrementa rodada_despacho de 1 para 2'
);

select is(
  (select rodada_despacho from public.vaga where id = '70900000-0000-4000-8000-000000000032'),
  1,
  'isolamento: reabertura em vaga 1 preserva rodada_despacho da vaga 2 em 1'
);

-- Inserção da segunda posição reaberta na vaga 1 (reabrindo a posição 709...0042):
insert into public.posicao (
  id, vaga_id, estado, inicio_em, fim_em, reaberta_por_atraso_de
) values (
  '70900000-0000-4000-8000-000000000062',
  '70900000-0000-4000-8000-000000000031',
  'aberta',
  '2026-10-25 18:00:00+00',
  '2026-10-25 23:00:00+00',
  '70900000-0000-4000-8000-000000000042'
);

select is(
  (select rodada_despacho from public.vaga where id = '70900000-0000-4000-8000-000000000031'),
  3,
  'disparo sequencial: segunda posicao reaberta por atraso incrementa rodada_despacho sequencialmente para 3'
);

-- ── 5. Restrição de Evento: UPDATE não dispara o gatilho (AFTER INSERT) ───────

update public.posicao
   set falta = false
 where id = '70900000-0000-4000-8000-000000000061';

select is(
  (select rodada_despacho from public.vaga where id = '70900000-0000-4000-8000-000000000031'),
  3,
  'restricao de evento: UPDATE em posicao reaberta nao dispara gatilho (AFTER INSERT restrito)'
);

-- ── 6. Proteção de Unicidade e Consistência ───────────────────────────────────

-- Tentativa de reabrir pela segunda vez a mesma posição original (709...0041) viola unicidade parcial
select throws_ok(
  $$insert into public.posicao (
      id, vaga_id, estado, inicio_em, fim_em, reaberta_por_atraso_de
    ) values (
      '70900000-0000-4000-8000-000000000099',
      '70900000-0000-4000-8000-000000000031',
      'aberta',
      '2026-10-25 18:00:00+00',
      '2026-10-25 23:00:00+00',
      '70900000-0000-4000-8000-000000000041'
    )$$,
  '23505',
  null,
  'posicao_uma_reabertura_por_falta: segunda reabertura da mesma posicao original e barrada por unicidade'
);

select is(
  (select rodada_despacho from public.vaga where id = '70900000-0000-4000-8000-000000000031'),
  3,
  'insercao rejeitada por unicidade nao altera rodada_despacho'
);

-- ── 7. Prova de Mutação (Sem o Gatilho Ativo) ─────────────────────────────────

-- Remove temporariamente o trigger da sessão de teste:
drop trigger posicao_reaberta_abre_rodada on public.posicao;

-- Inserção de posição reaberta (reabrindo a posição 709...0043) com o trigger desligado:
insert into public.posicao (
  id, vaga_id, estado, inicio_em, fim_em, reaberta_por_atraso_de
) values (
  '70900000-0000-4000-8000-000000000064',
  '70900000-0000-4000-8000-000000000031',
  'aberta',
  '2026-10-25 18:00:00+00',
  '2026-10-25 23:00:00+00',
  '70900000-0000-4000-8000-000000000043'
);

select is(
  (select rodada_despacho from public.vaga where id = '70900000-0000-4000-8000-000000000031'),
  3,
  'prova de mutacao: sem o gatilho posicao_reaberta_abre_rodada, insert com reaberta_por_atraso_de nao incrementa rodada_despacho'
);

select * from finish();
rollback;
