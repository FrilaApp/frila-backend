-- 721_cron_executar_retencao_diaria.sql
-- Cobertura pgTAP do job pg_cron 'retencao_e_limpeza_diaria' e da função privado.executar_retencao_diaria()
-- Foco: catálogo, menor privilégio, integridade temporal, bordas estritas no segundo e eliminação de falsos-verdes.
--
-- Cobertura implementada:
--   1. Existência e integridade do agendamento no catálogo cron.job (horário 06:30, comando exato, ativo);
--   2. Definição da rotina privado.executar_retencao_diaria() com SECURITY DEFINER, search_path='' e retorno jsonb;
--   3. Menor privilégio: execução restrita a service_role (revogado de anon, authenticated e public);
--   4. Borda estrita de 15 dias em contas_anonimizadas_limpas:
--      - 14d 23h 59m 59s (15d - 1s): PRESERVADA (nascimento e ponto_base mantidos);
--      - 15d 00h 00m 00s (15d exatos): PURGADA (cláusula <= no catálogo);
--      - 15d 00h 00m 01s (15d + 1s): PURGADA;
--      - Contagem exata de contas purgadas (= 3);
--   5. Borda estrita de 90 dias em eventos_app_limpos:
--      - 89d 23h 59m 59s (90d - 1s): PRESERVADO;
--      - 90d 00h 00m 00s (90d exatos): PRESERVADO (cláusula < no catálogo);
--      - 90d 00h 00m 01s (90d + 1s): REMOVIDO;
--      - Contagem exata de eventos removidos (= 2);
--   6. Retorno estruturado contendo 'executado_em', 'contas_anonimizadas_limpas', 'higiene' e 'eventos_app_limpos';
--   7. Idempotência em execuções repetidas dentro do mesmo ciclo.

BEGIN;

-- 1. Setup de ambiente: garantir teste ativo e fixar relógio inicial antes de inserir dados
INSERT INTO privado.ambiente (eh_teste) VALUES (true)
ON CONFLICT DO NOTHING;

-- Fixar relógio ANTES de qualquer inserção (2026-10-20 06:30:00 UTC)
SELECT set_config('frila.agora', '2026-10-20 06:30:00+00', true);
SET LOCAL timezone = 'UTC';

SELECT * FROM plan(32);

-- ── 1. Catálogo do Job pg_cron ──────────────────────────────────────────────

SELECT has_table('cron', 'job', 'Tabela cron.job existe');

SELECT is(
  (SELECT jobname FROM cron.job WHERE jobname = 'retencao_e_limpeza_diaria'),
  'retencao_e_limpeza_diaria',
  'Job retencao_e_limpeza_diaria está registrado no pg_cron'
);

SELECT is(
  (SELECT schedule FROM cron.job WHERE jobname = 'retencao_e_limpeza_diaria'),
  '30 6 * * *',
  'Job retencao_e_limpeza_diaria agendado diariamente às 06:30'
);

SELECT is(
  (SELECT command FROM cron.job WHERE jobname = 'retencao_e_limpeza_diaria'),
  'select privado.executar_retencao_diaria()',
  'Comando do job executa estritamente privado.executar_retencao_diaria()'
);

SELECT is(
  (SELECT active FROM cron.job WHERE jobname = 'retencao_e_limpeza_diaria'),
  true,
  'Job retencao_e_limpeza_diaria está ativo'
);

-- ── 2. Catálogo da Função e Menor Privilégio ────────────────────────────────

SELECT has_function(
  'privado',
  'executar_retencao_diaria',
  array[]::text[],
  'Função privado.executar_retencao_diaria() existe'
);

SELECT function_returns(
  'privado',
  'executar_retencao_diaria',
  'jsonb',
  'Função privado.executar_retencao_diaria() retorna jsonb estruturado'
);

SELECT is(
  (SELECT prosecdef FROM pg_proc WHERE proname = 'executar_retencao_diaria' AND pronamespace = 'privado'::regnamespace),
  true,
  'Função privado.executar_retencao_diaria() é SECURITY DEFINER'
);

SELECT is(
  (SELECT proconfig FROM pg_proc WHERE proname = 'executar_retencao_diaria' AND pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'Função privado.executar_retencao_diaria() define search_path="" vazio contra sequestro de schema'
);

SELECT is(
  has_function_privilege('service_role', 'privado.executar_retencao_diaria()', 'execute'),
  true,
  'service_role possui privilégio de execução em privado.executar_retencao_diaria()'
);

SELECT is(
  has_function_privilege('authenticated', 'privado.executar_retencao_diaria()', 'execute'),
  false,
  'authenticated não possui privilégio de execução em privado.executar_retencao_diaria()'
);

SELECT is(
  has_function_privilege('anon', 'privado.executar_retencao_diaria()', 'execute'),
  false,
  'anon não possui privilégio de execução em privado.executar_retencao_diaria()'
);

SELECT is(
  has_function_privilege('public', 'privado.executar_retencao_diaria()', 'execute'),
  false,
  'public não possui privilégio de execução em privado.executar_retencao_diaria()'
);

-- ── 3. Fixtures Determinísticas com Borda Estrita no Segundo ────────────────

-- Limpa eventos_app preexistentes na transação para assegurar contagem exata
DELETE FROM public.evento_app;

-- Fixtures de Contas Anonimizadas (Borda de 15 dias = 2026-10-05 06:30:00+00):
-- C1: 14d 23h 59m 59s atrás (2026-10-05 06:30:01+00) -> DENTRO DA CARÊNCIA -> PRESERVADA
-- C2: Exatamente 15 dias atrás (2026-10-05 06:30:00+00) -> <= 15 dias -> PURGADA
-- C3: 15 dias e 1 segundo atrás (2026-10-05 06:29:59+00) -> PURGADA
-- C4: 16 dias atrás (2026-10-04 06:30:00+00) -> PURGADA

INSERT INTO public.usuario (
  id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em, anonimizado_em
) VALUES
  ('72100000-0000-4000-8000-000000000001', 'profissional', 'Conta 15d Menos 1s', '+5561972100001', 'c1@frila.test', '1990-01-01', 'anonimizada', '1.0', now(), '2026-10-05 06:30:01+00'),
  ('72100000-0000-4000-8000-000000000002', 'profissional', 'Conta 15d Exatos',   '+5561972100002', 'c2@frila.test', '1991-02-02', 'anonimizada', '1.0', now(), '2026-10-05 06:30:00+00'),
  ('72100000-0000-4000-8000-000000000003', 'profissional', 'Conta 15d Mais 1s',  '+5561972100003', 'c3@frila.test', '1992-03-03', 'anonimizada', '1.0', now(), '2026-10-05 06:29:59+00'),
  ('72100000-0000-4000-8000-000000000004', 'profissional', 'Conta 16d Antiga',   '+5561972100004', 'c4@frila.test', '1993-04-04', 'anonimizada', '1.0', now(), '2026-10-04 06:30:00+00');

INSERT INTO public.profissional (
  id, usuario_id, ponto_base
) VALUES
  ('72110000-0000-4000-8000-000000000001', '72100000-0000-4000-8000-000000000001', ST_SetSRID(ST_MakePoint(-47.8825, -15.7942), 4326)::geography),
  ('72110000-0000-4000-8000-000000000002', '72100000-0000-4000-8000-000000000002', ST_SetSRID(ST_MakePoint(-47.8825, -15.7942), 4326)::geography),
  ('72110000-0000-4000-8000-000000000003', '72100000-0000-4000-8000-000000000003', ST_SetSRID(ST_MakePoint(-47.8825, -15.7942), 4326)::geography),
  ('72110000-0000-4000-8000-000000000004', '72100000-0000-4000-8000-000000000004', ST_SetSRID(ST_MakePoint(-47.8825, -15.7942), 4326)::geography);

-- Fixtures de Eventos de App (Borda de 90 dias = 2026-07-22 06:30:00+00):
-- E1: 89d 23h 59m 59s atrás (2026-07-22 06:30:01+00) -> DENTRO DA JANELA -> PRESERVADO
-- E2: Exatamente 90 dias atrás (2026-07-22 06:30:00+00) -> não é < 90 dias -> PRESERVADO
-- E3: 90 dias e 1 segundo atrás (2026-07-22 06:29:59+00) -> mais de 90 dias -> REMOVIDO
-- E4: 111 dias atrás (2026-07-01 06:30:00+00) -> mais de 90 dias -> REMOVIDO

INSERT INTO public.evento_app (
  id, usuario_id, evento, ocorrido_em, criado_em
) VALUES
  ('72120000-0000-4000-8000-000000000001', '72100000-0000-4000-8000-000000000001', 'app_aberto', '2026-07-22 06:30:01+00', '2026-07-22 06:30:01+00'),
  ('72120000-0000-4000-8000-000000000002', '72100000-0000-4000-8000-000000000001', 'app_aberto', '2026-07-22 06:30:00+00', '2026-07-22 06:30:00+00'),
  ('72120000-0000-4000-8000-000000000003', '72100000-0000-4000-8000-000000000001', 'app_aberto', '2026-07-22 06:29:59+00', '2026-07-22 06:29:59+00'),
  ('72120000-0000-4000-8000-000000000004', '72100000-0000-4000-8000-000000000001', 'app_aberto', '2026-07-01 06:30:00+00', '2026-07-01 06:30:00+00');

-- ── 4. Execução da Rotina e Validação dos Efeitos com Borda Estrita ──────────

CREATE TEMP TABLE r_resultado AS
SELECT privado.executar_retencao_diaria() AS res;

-- 14. Timestamp reflete com exatidão o relógio fixo
SELECT is(
  (SELECT (res->>'executado_em')::timestamptz FROM r_resultado),
  '2026-10-20 06:30:00+00'::timestamptz,
  'executado_em reflete com precisão o relógio determinístico privado.agora()'
);

-- 15. Contas purgadas: exatamente 3 (C2, C3, C4)
SELECT is(
  (SELECT (res->>'contas_anonimizadas_limpas')::integer FROM r_resultado),
  3,
  'contas_anonimizadas_limpas registra exatamente 3 contas purgadas'
);

-- 16-17. Conta C1 (15d - 1s) PRESERVADA
SELECT is(
  (SELECT nascimento FROM public.usuario WHERE id = '72100000-0000-4000-8000-000000000001'),
  '1990-01-01'::date,
  'Conta C1 dentro da carência (15d - 1s) preserva data de nascimento'
);

SELECT is(
  (SELECT ponto_base IS NOT NULL FROM public.profissional WHERE id = '72110000-0000-4000-8000-000000000001'),
  true,
  'Profissional C1 dentro da carência (15d - 1s) preserva ponto_base'
);

-- 18-19. Conta C2 (15d exatos) PURGADA
SELECT is(
  (SELECT nascimento FROM public.usuario WHERE id = '72100000-0000-4000-8000-000000000002'),
  null,
  'Conta C2 no limite exato de 15 dias tem nascimento purgado para NULL'
);

SELECT is(
  (SELECT ponto_base FROM public.profissional WHERE id = '72110000-0000-4000-8000-000000000002'),
  null,
  'Profissional C2 no limite exato de 15 dias tem ponto_base anulado para NULL'
);

-- 20-21. Conta C3 (15d + 1s) PURGADA
SELECT is(
  (SELECT nascimento FROM public.usuario WHERE id = '72100000-0000-4000-8000-000000000003'),
  null,
  'Conta C3 com 15 dias e 1 segundo tem nascimento purgado para NULL'
);

SELECT is(
  (SELECT ponto_base FROM public.profissional WHERE id = '72110000-0000-4000-8000-000000000003'),
  null,
  'Profissional C3 com 15 dias e 1 segundo tem ponto_base anulado para NULL'
);

-- 22. Eventos removidos: exatamente 2 (E3, E4)
SELECT is(
  (SELECT (res->>'eventos_app_limpos')::integer FROM r_resultado),
  2,
  'eventos_app_limpos registra exatamente 2 eventos antigos purgados'
);

-- 23-24. Eventos E1 e E2 PRESERVADOS no banco
SELECT is(
  (SELECT count(*)::integer FROM public.evento_app WHERE id = '72120000-0000-4000-8000-000000000001'),
  1,
  'Evento E1 (90d - 1s) é preservado no banco de dados'
);

SELECT is(
  (SELECT count(*)::integer FROM public.evento_app WHERE id = '72120000-0000-4000-8000-000000000002'),
  1,
  'Evento E2 (90d exatos) é preservado no banco de dados (borda estrita: não é < 90d)'
);

-- 25-26. Eventos E3 e E4 REMOVIDOS do banco
SELECT is(
  (SELECT count(*)::integer FROM public.evento_app WHERE id = '72120000-0000-4000-8000-000000000003'),
  0,
  'Evento E3 (90d + 1s) foi fisicamente removido do banco'
);

SELECT is(
  (SELECT count(*)::integer FROM public.evento_app WHERE id = '72120000-0000-4000-8000-000000000004'),
  0,
  'Evento E4 (111d) foi fisicamente removido do banco'
);

-- 27-30. Chaves e estrutura do objeto higiene
SELECT is(
  (SELECT jsonb_typeof(res->'higiene') FROM r_resultado),
  'object',
  'Objeto higiene está presente no resultado consolidado'
);

SELECT is(
  ((SELECT res->'higiene' FROM r_resultado) ? 'cron_job_run_details'),
  true,
  'higiene contém a chave cron_job_run_details'
);

SELECT is(
  ((SELECT res->'higiene' FROM r_resultado) ? 'pgmq_arquivo'),
  true,
  'higiene contém a chave pgmq_arquivo'
);

SELECT is(
  ((SELECT res->'higiene' FROM r_resultado) ? 'pgmq_arquivo_email'),
  true,
  'higiene contém a chave pgmq_arquivo_email'
);

-- ── 5. Idempotência em Segunda Execução ─────────────────────────────────────

CREATE TEMP TABLE r_reexec AS
SELECT privado.executar_retencao_diaria() AS res;

SELECT is(
  (SELECT (res->>'contas_anonimizadas_limpas')::integer FROM r_reexec),
  0,
  'Reexecução imediata encontra 0 contas adicionais para limpar'
);

SELECT is(
  (SELECT (res->>'eventos_app_limpos')::integer FROM r_reexec),
  0,
  'Reexecução imediata encontra 0 eventos adicionais para limpar'
);

SELECT * FROM finish();

ROLLBACK;
