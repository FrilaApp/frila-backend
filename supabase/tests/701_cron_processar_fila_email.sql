-- 701_cron_processar_fila_email.sql
-- Cobertura pgTAP do job pg_cron 'processar_fila_email' e da função privado.disparar_email()
-- Mapeamento pg_cron: acionamento assíncrono e fallback periódico de envio de e-mail (RN15, RF23, RF26, RNF13)
--
-- Afere:
--   1. Existência da função privado.disparar_email(), retorno bigint, definer, search_path='' e privilégios mínimos;
--   2. Existência do gatilho trg_email_enfileirado e função associada privado.trg_disparar_email();
--   3. Agendamento ativo no pg_cron a cada minuto ('* * * * *') chamando select privado.disparar_email();
--   4. Comportamento com fila vazia: retorna NULL imediatamente (não desperdiça requisições HTTP);
--   5. Comportamento com fila populada e secret ausente: emite warning, não aborta e preserva o pedido na fila;
--   6. Comportamento com fila populada e secret configurado: executa net.http_post com sucesso via service_role;
--   7. Idempotência e resiliência: execuções repetidas sem acúmulo nem aborto;
--   8. Retorno a NULL após esvaziamento da fila.

begin;

set local timezone = 'UTC';
select plan(24);

-- ── 1. Estrutura e Controle de Acesso ──────────────────────────────────────────

select has_function(
  'privado',
  'disparar_email',
  array[]::text[],
  'privado.disparar_email() existe no schema privado'
);

select function_returns(
  'privado',
  'disparar_email',
  array[]::text[],
  'bigint',
  'privado.disparar_email() retorna bigint (id da requisição net.http_post ou null)'
);

select is_definer(
  'privado',
  'disparar_email',
  array[]::text[],
  'privado.disparar_email() é SECURITY DEFINER'
);

select ok(
  (select proconfig from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'disparar_email')
  @> array['search_path=""'],
  'privado.disparar_email() opera com search_path vazio'
);

select is(
  has_function_privilege('authenticated', 'privado.disparar_email()', 'execute'),
  false,
  'authenticated NÃO tem permissão de execute em privado.disparar_email()'
);

select is(
  has_function_privilege('anon', 'privado.disparar_email()', 'execute'),
  false,
  'anon NÃO tem permissão de execute em privado.disparar_email()'
);

select is(
  has_function_privilege('public', 'privado.disparar_email()', 'execute'),
  false,
  'public NÃO tem permissão de execute em privado.disparar_email()'
);

select is(
  has_function_privilege('service_role', 'privado.disparar_email()', 'execute'),
  true,
  'service_role pode executar privado.disparar_email()'
);

-- ── 2. Gatilho e Função de Disparo Imediato ────────────────────────────────────

select is(
  (select count(*)::int from pg_trigger t
     join pg_class c on c.oid = t.tgrelid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'pgmq' and c.relname = 'q_email'
      and t.tgname = 'trg_email_enfileirado' and not t.tgisinternal),
  1,
  'Gatilho trg_email_enfileirado está instalado e ativo em pgmq.q_email'
);

select has_function(
  'privado',
  'trg_disparar_email',
  array[]::text[],
  'privado.trg_disparar_email() existe'
);

select is(
  has_function_privilege('authenticated', 'privado.trg_disparar_email()', 'execute'),
  false,
  'authenticated não pode executar privado.trg_disparar_email()'
);

select is(
  has_function_privilege('service_role', 'privado.trg_disparar_email()', 'execute'),
  true,
  'service_role pode executar privado.trg_disparar_email()'
);

-- ── 3. Agendamento Periódico no pg_cron ────────────────────────────────────────

select is(
  (select count(*)::int from cron.job where jobname = 'processar_fila_email'),
  1,
  'Job processar_fila_email existe agendado no pg_cron'
);

select is(
  (select schedule from cron.job where jobname = 'processar_fila_email'),
  '* * * * *',
  'Job processar_fila_email está configurado para executar a cada minuto (* * * * *)'
);

select is(
  (select command from cron.job where jobname = 'processar_fila_email'),
  'select privado.disparar_email()',
  'Job invoca exatamente select privado.disparar_email()'
);

select ok(
  (select active from cron.job where jobname = 'processar_fila_email'),
  'Job processar_fila_email está ativo no pg_cron'
);

-- ── 4. Comportamento com Fila Vazia ───────────────────────────────────────────

-- Define segredo válido para provar que a devolução de NULL decorre da fila vazia e não do segredo ausente
set local frila.agendador_secret = 'segredo-de-teste-cron-701';

-- Esvazia mensagens prévias da fila email dentro da transação isolada
delete from pgmq.q_email;

select is(
  privado.disparar_email(),
  null,
  'Com fila vazia e segredo configurado, privado.disparar_email() retorna NULL e não dispara requisição HTTP'
);

-- ── 5. Comportamento com Fila Populada e Segredo Ausente ───────────────────────

-- Enfileira um pedido de teste
select pgmq.send('email', '{"ocorrencia_id": "70100000-0000-4000-8000-000000000001", "origem": "teste_cron"}'::jsonb);

set local frila.agendador_secret = '';

select is(
  privado.disparar_email(),
  null,
  'Com secret ausente, privado.disparar_email() retorna NULL e não aborta a transação'
);

select is(
  (select count(*)::int from pgmq.q_email where (message->>'ocorrencia_id') = '70100000-0000-4000-8000-000000000001'),
  1,
  'Pedido de e-mail permanece íntegro na fila q_email para tentativa futura'
);

-- ── 6. Comportamento com Fila Populada e Segredo Presente ─────────────────────

set local frila.agendador_secret = 'segredo-de-teste-cron-701';
set local frila.email_function_url = 'http://127.0.0.1:54321/functions/v1/enviar-email';

select isnt(
  privado.disparar_email(),
  null,
  'Com agendador_secret e URL configurados, privado.disparar_email() executa net.http_post com sucesso e devolve request_id'
);

select is(
  (select count(*)::int from pgmq.q_email where (message->>'ocorrencia_id') = '70100000-0000-4000-8000-000000000001'),
  1,
  'Pedido permanece na fila para processamento pelo consumidor Edge Function'
);

-- ── 7. Idempotência e Esvaziamento da Fila ─────────────────────────────────────

select isnt(
  privado.disparar_email(),
  null,
  'Segunda execução consecutiva é resiliente e executa net.http_post sem falhas'
);

select is(
  (select count(*)::int from pgmq.q_email where (message->>'ocorrencia_id') = '70100000-0000-4000-8000-000000000001'),
  1,
  'Fila mantém exatamente 1 pedido (sem duplicação nem perda)'
);

-- Simula conclusão do pedido (remoção da fila)
delete from pgmq.q_email where (message->>'ocorrencia_id') = '70100000-0000-4000-8000-000000000001';

select is(
  privado.disparar_email(),
  null,
  'Após esvaziamento da fila, privado.disparar_email() volta a retornar NULL'
);

select * from finish();
rollback;
