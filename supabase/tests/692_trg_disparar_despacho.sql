-- Disparo assíncrono pós-commit do motor de despacho (RNF03, RF18).
--
-- Cobertura do gatilho `trg_despacho_enfileirado` e da função `privado.trg_disparar_despacho()`
-- (migração 20260926010000_motor_despacho.sql).
--
-- Sempre que uma mensagem entra na fila `pgmq.q_despacho` (via `publicar_vaga`, `cancelar_posicao`
-- ou `reabrir_por_atraso`), o gatilho AFTER INSERT dispara imediatamente a chamada HTTP
-- assíncrona pós-commit via `net.http_post` para acordar a Edge Function `despachar`.
--
-- Para garantir determinismo em qualquer ambiente de CI (onde `frila.agendador_secret`
-- pode ou não estar pré-configurado globalmente na sessão), os testes controlam o valor do
-- segredo explicitamente via `SET LOCAL` dentro do bloco transacional.
--
-- Este teste valida:
--   1. Existência, linguagem e atributo SECURITY DEFINER de `privado.trg_disparar_despacho()`.
--   2. Presença do gatilho `trg_despacho_enfileirado` em `pgmq.q_despacho`.
--   3. Controle de acesso estrito: sem EXECUTE para anon e authenticated; concedido a service_role.
--   4. Disparo do gatilho ao enfileirar mensagem com secret ausente (falha observável com mensagem exata).
--   5. Disparo do gatilho ao enfileirar mensagem com secret definido na transação (sucesso e enfileiramento).
--   6. Presença da mensagem na fila `pgmq.q_despacho` para consumo pelo consumidor ou fallback.
--   7. Presença e agendamento a cada minuto ('* * * * *') do job `reprocessar_despacho` no pg_cron.

begin;

select plan(11);

-- ── 1. Estrutura e controle de acesso ────────────────────────────────────────

select has_function('privado', 'trg_disparar_despacho', array[]::text[],
  'privado.trg_disparar_despacho() existe');

select function_lang_is('privado', 'trg_disparar_despacho', array[]::text[], 'plpgsql',
  'trg_disparar_despacho é em plpgsql');

select is_definer('privado', 'trg_disparar_despacho', array[]::text[],
  'trg_disparar_despacho é SECURITY DEFINER');

select is(
  (select count(*)::int from pg_trigger t
     join pg_class c on c.oid = t.tgrelid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'pgmq' and c.relname = 'q_despacho'
      and t.tgname = 'trg_despacho_enfileirado' and not t.tgisinternal),
  1,
  'gatilho trg_despacho_enfileirado ativo em pgmq.q_despacho'
);

select is(has_function_privilege('anon', 'privado.trg_disparar_despacho()', 'execute'), false,
  'anon não executa privado.trg_disparar_despacho');

select is(has_function_privilege('authenticated', 'privado.trg_disparar_despacho()', 'execute'), false,
  'authenticated não executa privado.trg_disparar_despacho');

select is(has_function_privilege('service_role', 'privado.trg_disparar_despacho()', 'execute'), true,
  'service_role pode executar privado.trg_disparar_despacho');

-- ── 2. Disparo determinístico na inserção em q_despacho ──────────────────────

-- Caso 1: Segredo vazio definido explicitamente nesta transação
set local frila.agendador_secret = '';

select throws_ok(
  $$ select pgmq.send('despacho', '{"vaga_id": "b6920000-0000-4000-8000-000000000001"}'::jsonb) $$,
  'Configuração frila.agendador_secret ausente no banco de dados',
  'inserção em q_despacho aciona trg_disparar_despacho e falha de forma observável se secret não configurado'
);

-- Caso 2: Segredo preenchido definido explicitamente nesta transação
set local frila.agendador_secret = 'segredo-de-teste-deterministico';
set local frila.edge_function_url = 'http://127.0.0.1:54321/functions/v1/despachar';

select lives_ok(
  $$ select pgmq.send('despacho', '{"vaga_id": "b6920000-0000-4000-8000-000000000001"}'::jsonb) $$,
  'com agendador_secret definido na transação, inserção em q_despacho dispara com sucesso'
);

select is(
  (select count(*)::int from pgmq.q_despacho where (message->>'vaga_id') = 'b6920000-0000-4000-8000-000000000001'),
  1,
  'mensagem permanece enfileirada na fila q_despacho'
);

-- ── 3. Fallback do pg_cron para reprocessamento ──────────────────────────────

select is(
  (select schedule from cron.job where jobname = 'reprocessar_despacho'),
  '* * * * *',
  'o job reprocessar_despacho drena a fila a cada minuto'
);

select * from finish();

rollback;
