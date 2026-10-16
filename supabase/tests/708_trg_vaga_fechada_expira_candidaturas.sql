-- 708_trg_vaga_fechada_expira_candidaturas.sql
--
-- Cobertura pgTAP do trigger vaga_fechada_expira_candidaturas e da função privado.vaga_fechada_expira_candidaturas().
-- Regra de Negócio: D3, RN24 (candidatura em modo seleção vale até a vaga fechar).
-- Migração: 20260929234100_modo_selecao.sql:878-906.
--
-- Contexto e Conexão Arquitetural:
--   O trigger é acionado em AFTER UPDATE OF estado em public.vaga sob a condição
--   WHEN (new.estado in ('cancelada', 'encerrada') and old.estado is distinct from new.estado).
--   Ele expira automaticamente todas as candidaturas pendentes vinculadas às posições da vaga,
--   assegurando que o cancelamento pela casa ou encerramento da seleção invalide candidaturas
--   sem exigir varredura síncrona manual pelo chamador.
--
-- 1. Metadados e privilégios mínimos:
--    - Trigger registrado em public.vaga com tipo AFTER UPDATE OF estado.
--    - privado.vaga_fechada_expira_candidaturas() com search_path="" vazio fixado.
--    - Privilégios: service_role permitido; authenticated, anon e public negados.
-- 2. Exercício Positivo:
--    - Transição de publicada -> cancelada expira candidaturas pendentes da vaga.
--    - Transição de publicada -> encerrada expira candidaturas pendentes da vaga.
--    - Candidaturas já recusadas são preservadas intactas sem alteração de estado.
--    - Candidaturas de outras vagas permanecem intactas (isolamento por vaga).
-- 3. Exercício e Borda da Cláusula WHEN (com estado no SET):
--    - Caso 3a: Transição publicada -> preenchida (fora do conjunto cancelada/encerrada) mantém candidatura pendente.
--    - Caso 3b: Update com estado = 'cancelada' em vaga já cancelada (old = new) mantém candidatura pendente.
--    - Update em colunas normais (local) sem alterar estado não aciona o gatilho.
-- 4. Prova de Mutação:
--    - Sem o trigger (DROP TRIGGER), a transição para cancelada deixa a candidatura pendente.

begin;

-- Pré-requisito canônico: habilitar ambiente de teste e congelar relógio antes de inserir dados
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local timezone = 'UTC';
set local frila.agora = '2026-10-20 12:00:00+00';

select plan(17);

-- ── 1. Metadados e Privilégios Mínimos ───────────────────────────────────────

select has_trigger(
  'public',
  'vaga',
  'vaga_fechada_expira_candidaturas',
  'tabela public.vaga possui o trigger vaga_fechada_expira_candidaturas'
);

select has_function(
  'privado',
  'vaga_fechada_expira_candidaturas',
  array[]::text[],
  'privado.vaga_fechada_expira_candidaturas() existe no schema privado'
);

select function_returns(
  'privado',
  'vaga_fechada_expira_candidaturas',
  array[]::text[],
  'trigger',
  'privado.vaga_fechada_expira_candidaturas() retorna trigger'
);

select is_definer(
  'privado',
  'vaga_fechada_expira_candidaturas',
  array[]::text[],
  'privado.vaga_fechada_expira_candidaturas() é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'vaga_fechada_expira_candidaturas' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'privado.vaga_fechada_expira_candidaturas() possui search_path="" vazio fixado'
);

select ok(
  has_function_privilege('service_role', 'privado.vaga_fechada_expira_candidaturas()', 'execute'),
  'service_role pode executar privado.vaga_fechada_expira_candidaturas()'
);

select ok(
  not has_function_privilege('authenticated', 'privado.vaga_fechada_expira_candidaturas()', 'execute'),
  'authenticated não pode executar privado.vaga_fechada_expira_candidaturas()'
);

select ok(
  not has_function_privilege('anon', 'privado.vaga_fechada_expira_candidaturas()', 'execute'),
  'anon não pode executar privado.vaga_fechada_expira_candidaturas()'
);

select ok(
  not has_function_privilege('public', 'privado.vaga_fechada_expira_candidaturas()', 'execute'),
  'public não pode executar privado.vaga_fechada_expira_candidaturas()'
);

-- ── 2. Cenário de Teste (prefixo 708) ──────────────────────────────────────────

-- Inserção de usuários com padrão canônico (datas explícitas sem now()):
insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado
) values
  ('70800000-0000-4000-8000-000000000001', 'contratante',  'Contratante 708',  '+5561970800001', 'c708@test.com', '1985-01-01', '2026-09-22', '2026-10-20 12:00:00+00', 'ativa'),
  ('70800000-0000-4000-8000-000000000002', 'profissional', 'Profissional 708-A', '+5561970800002', 'p708a@test.com', '1992-02-02', '2026-09-22', '2026-10-20 12:00:00+00', 'ativa'),
  ('70800000-0000-4000-8000-000000000003', 'profissional', 'Profissional 708-B', '+5561970800003', 'p708b@test.com', '1994-03-03', '2026-09-22', '2026-10-20 12:00:00+00', 'ativa');

insert into public.estabelecimento (
  id, nome, documento, tipo, endereco, ponto, regiao_administrativa
) values (
  '70800000-0000-4000-8000-000000000010', 'Restaurante 708', '99888777000188', 'food_service',
  'SCLN 308 Bloco C', 'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto'
);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('70800000-0000-4000-8000-000000000010', '70800000-0000-4000-8000-000000000001', 'administrador');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('70800000-0000-4000-8000-000000000021', '70800000-0000-4000-8000-000000000002', 'POINT(-47.8825 -15.7942)'::extensions.geography),
  ('70800000-0000-4000-8000-000000000022', '70800000-0000-4000-8000-000000000003', 'POINT(-47.8825 -15.7942)'::extensions.geography);

-- Vagas em modo seleção com publicado_em explícito e estado válido 'publicada':
insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por, publicado_em
) values
  ('70800000-0000-4000-8000-000000000031', '70800000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8825 -15.7942)'::extensions.geography,
   'Restaurante 708', 15000, 2, true, false, false, 'Gerente',
   '2026-10-25 18:00:00+00', '2026-10-25 23:00:00+00', 'selecao', 'publicada', 'Plano Piloto',
   '70800000-0000-4000-8000-000000000031', '70800000-0000-4000-8000-000000000001', '2026-10-19 12:00:00+00'),
  ('70800000-0000-4000-8000-000000000032', '70800000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8825 -15.7942)'::extensions.geography,
   'Restaurante 708', 15000, 1, true, false, false, 'Gerente',
   '2026-10-26 18:00:00+00', '2026-10-26 23:00:00+00', 'selecao', 'publicada', 'Plano Piloto',
   '70800000-0000-4000-8000-000000000032', '70800000-0000-4000-8000-000000000001', '2026-10-19 12:00:00+00'),
  ('70800000-0000-4000-8000-000000000033', '70800000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8825 -15.7942)'::extensions.geography,
   'Restaurante 708', 15000, 1, true, false, false, 'Gerente',
   '2026-10-27 18:00:00+00', '2026-10-27 23:00:00+00', 'selecao', 'publicada', 'Plano Piloto',
   '70800000-0000-4000-8000-000000000033', '70800000-0000-4000-8000-000000000001', '2026-10-19 12:00:00+00'),
  ('70800000-0000-4000-8000-000000000034', '70800000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8825 -15.7942)'::extensions.geography,
   'Restaurante 708', 15000, 1, true, false, false, 'Gerente',
   '2026-10-28 18:00:00+00', '2026-10-28 23:00:00+00', 'selecao', 'publicada', 'Plano Piloto',
   '70800000-0000-4000-8000-000000000034', '70800000-0000-4000-8000-000000000001', '2026-10-19 12:00:00+00');

-- Posições das vagas:
insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em) values
  ('70800000-0000-4000-8000-000000000041', '70800000-0000-4000-8000-000000000031', 'aberta', '2026-10-25 18:00:00+00', '2026-10-25 23:00:00+00'),
  ('70800000-0000-4000-8000-000000000042', '70800000-0000-4000-8000-000000000032', 'aberta', '2026-10-26 18:00:00+00', '2026-10-26 23:00:00+00'),
  ('70800000-0000-4000-8000-000000000043', '70800000-0000-4000-8000-000000000033', 'aberta', '2026-10-27 18:00:00+00', '2026-10-27 23:00:00+00'),
  ('70800000-0000-4000-8000-000000000044', '70800000-0000-4000-8000-000000000031', 'aberta', '2026-10-25 18:00:00+00', '2026-10-25 23:00:00+00'),
  ('70800000-0000-4000-8000-000000000045', '70800000-0000-4000-8000-000000000034', 'aberta', '2026-10-28 18:00:00+00', '2026-10-28 23:00:00+00');

-- Candidaturas em estados heterogêneos:
insert into public.candidatura (id, posicao_id, profissional_id, estado, criada_em) values
  ('70800000-0000-4000-8000-000000000051', '70800000-0000-4000-8000-000000000041', '70800000-0000-4000-8000-000000000021', 'pendente', '2026-10-20 12:00:00+00'),
  ('70800000-0000-4000-8000-000000000052', '70800000-0000-4000-8000-000000000041', '70800000-0000-4000-8000-000000000022', 'recusada', '2026-10-20 12:00:00+00'),
  ('70800000-0000-4000-8000-000000000053', '70800000-0000-4000-8000-000000000042', '70800000-0000-4000-8000-000000000021', 'pendente', '2026-10-20 12:00:00+00'),
  ('70800000-0000-4000-8000-000000000054', '70800000-0000-4000-8000-000000000043', '70800000-0000-4000-8000-000000000022', 'pendente', '2026-10-20 12:00:00+00'),
  ('70800000-0000-4000-8000-000000000056', '70800000-0000-4000-8000-000000000045', '70800000-0000-4000-8000-000000000021', 'pendente', '2026-10-20 12:00:00+00');

-- ── 3. Disparo Positivo: Cancelamento da Vaga 1 ───────────────────────────────

update public.vaga
   set estado = 'cancelada'
 where id = '70800000-0000-4000-8000-000000000031';

select is(
  (select estado from public.candidatura where id = '70800000-0000-4000-8000-000000000051'),
  'expirada'::public.estado_candidatura,
  'trigger expira candidatura pendente quando vaga passa para cancelada'
);

select is(
  (select estado from public.candidatura where id = '70800000-0000-4000-8000-000000000052'),
  'recusada'::public.estado_candidatura,
  'candidatura ja recusada e preservada intacta sem alteracao para expirada'
);

select is(
  (select estado from public.candidatura where id = '70800000-0000-4000-8000-000000000053'),
  'pendente'::public.estado_candidatura,
  'candidatura de outra vaga (vaga 2) permanece pendente (isolamento)'
);

-- ── 4. Disparo Positivo: Encerramento da Vaga 2 ──────────────────────────────

update public.vaga
   set estado = 'encerrada'
 where id = '70800000-0000-4000-8000-000000000032';

select is(
  (select estado from public.candidatura where id = '70800000-0000-4000-8000-000000000053'),
  'expirada'::public.estado_candidatura,
  'trigger expira candidatura pendente quando vaga passa para encerrada'
);

-- ── 5. Disparo Negativo: Cláusula WHEN do Gatilho com estado no SET ──────────

-- Caso 5a: Transição publicada -> preenchida (fora de cancelada/encerrada):
-- O estado aparece no SET acionando avaliação do gatilho, mas o WHEN rejeita por new.estado
update public.vaga
   set estado = 'preenchida'
 where id = '70800000-0000-4000-8000-000000000033';

select is(
  (select estado from public.candidatura where id = '70800000-0000-4000-8000-000000000054'),
  'pendente'::public.estado_candidatura,
  'clausula WHEN: transicao para preenchida nao dispara trigger e candidatura segue pendente'
);

-- Caso 5b: Vaga já cancelada (Vaga 1), inserção de nova candidatura e update mantendo cancelada:
-- O estado aparece no SET, mas o WHEN rejeita por old.estado is distinct from new.estado
insert into public.candidatura (id, posicao_id, profissional_id, estado, criada_em) values
  ('70800000-0000-4000-8000-000000000055', '70800000-0000-4000-8000-000000000044', '70800000-0000-4000-8000-000000000021', 'pendente', '2026-10-20 12:00:00+00');

update public.vaga
   set estado = 'cancelada'
 where id = '70800000-0000-4000-8000-000000000031';

select is(
  (select estado from public.candidatura where id = '70800000-0000-4000-8000-000000000055'),
  'pendente'::public.estado_candidatura,
  'clausula WHEN: update com estado = cancelada em vaga ja cancelada nao dispara trigger (old = new)'
);

-- Caso 5c: Update em coluna que não altera o estado da vaga (sem estado no SET):
update public.vaga
   set local = 'Restaurante 708 - Salão Superior'
 where id = '70800000-0000-4000-8000-000000000034';

select is(
  (select estado from public.candidatura where id = '70800000-0000-4000-8000-000000000056'),
  'pendente'::public.estado_candidatura,
  'update em colunas normais sem alterar estado mantem candidatura pendente'
);

-- ── 6. Prova de Mutação (Sem o Gatilho Ativo) ─────────────────────────────────

-- Remove temporariamente o trigger da sessão de teste:
drop trigger vaga_fechada_expira_candidaturas on public.vaga;

-- Atualiza a Vaga 4 para cancelada:
update public.vaga
   set estado = 'cancelada'
 where id = '70800000-0000-4000-8000-000000000034';

select is(
  (select estado from public.candidatura where id = '70800000-0000-4000-8000-000000000056'),
  'pendente'::public.estado_candidatura,
  'prova de mutacao: sem o trigger vaga_fechada_expira_candidaturas, vaga cancelada deixa candidatura pendente'
);

select * from finish();
rollback;
