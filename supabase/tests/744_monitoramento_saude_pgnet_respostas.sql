-- Teste pgTAP: Alerta operacional de falhas assíncronas do pg_net em verificar_saude (Item 22)
-- Cobre:
-- 1. Respostas 200 normais não disparam alerta
-- 2. Falhas antigas (>15 min) não disparam alerta
-- 3. Limiar de transporte: < 3 falhas isoladas NÃO disparam alerta pgnet_falha_transporte
-- 4. >= 3 falhas recentes (timed_out, error_msg, 5xx) disparam alerta 'pgnet_falha_transporte'
-- 5. Rate-limit de 1h suprime envio imediato subsequente de transporte
-- 6. status_code in (401, 403, 404) emitem alerta 'pgnet_resposta_recusada' (cobrindo 401, 403 e 404)
-- 7. Contagem exata de respostas recusadas enviada no alerta
-- 8. Respostas recusadas (401, 403, 404) NÃO são contabilizadas no código de transporte
-- 9. Rate-limit de 1h independente para pgnet_resposta_recusada
-- 10. Sigilo: nenhum header de net._http_response vazado em q_email
-- 11. Sigilo: nenhum content de net._http_response vazado em q_email
-- 12. Execução defensiva de verificar_saude não quebra

begin;
select plan(23);

-- ── 1. Preparação: ativa modo teste e limpa alertas/fila ──────────────────────
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

delete from privado.alerta_emitido where codigo in ('pgnet_falha_transporte', 'pgnet_resposta_recusada');
delete from net._http_response;

-- Fixa o relógio para testes determinísticos
select set_config('frila.agora', '2026-10-18 12:00:00-03', true);

-- ── 2. Sem falhas recentes: resposta 200 não emite alerta de pgnet ────────────
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values (1001, 200, 'application/json', '{}'::jsonb, '{"ok":true}', false, null, privado.agora() - interval '2 minutes');

select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo in ('pgnet_falha_transporte', 'pgnet_resposta_recusada')),
  0,
  'respostas HTTP 200 recentes não disparam alertas de pg_net'
);

-- ── 3. Falhas fora da janela (>15 min) não disparam alerta ────────────────────
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values 
  (1002, null, null, null, null, true, 'timeout', privado.agora() - interval '16 minutes'),
  (1003, 502, 'text/html', '{}'::jsonb, 'Bad Gateway', false, null, privado.agora() - interval '20 minutes'),
  (1004, 401, 'application/json', '{}'::jsonb, '{"code":401}', false, null, privado.agora() - interval '30 minutes');

select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo in ('pgnet_falha_transporte', 'pgnet_resposta_recusada')),
  0,
  'falhas assíncronas do pg_net mais velhas que 15 min não disparam alerta'
);

-- ── 4. Limiar de transporte: 1 ou 2 timeouts (< 3) NÃO disparam alerta ─────────
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values 
  (1005, null, null, null, null, true, null, privado.agora() - interval '5 minutes'),
  (1006, null, null, null, null, true, null, privado.agora() - interval '4 minutes');

select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_falha_transporte'),
  0,
  '1 ou 2 falhas isoladas de transporte (< 3) não disparam alerta pgnet_falha_transporte'
);

-- ── 5. Na 3ª falha recente (limiar >= 3), emite 'pgnet_falha_transporte' ───────
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values (1007, 502, 'text/html', '{}'::jsonb, 'Bad Gateway', false, null, privado.agora() - interval '3 minutes');

select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_falha_transporte'),
  1,
  'ao atingir o limiar de >= 3 falhas na janela, emite alerta operacional pgnet_falha_transporte'
);

-- ── 6. Rate-limit 1/hora suprime envio imediato subsequente ───────────────────
select privado.verificar_saude();

select is(
  (select suprimidos from privado.alerta_emitido where codigo = 'pgnet_falha_transporte'),
  1,
  'segunda chamada dentro da janela de 1h suprime o alerta pgnet_falha_transporte'
);

-- ── 7. Respostas 401, 403 e 404 emitem 'pgnet_resposta_recusada' ──────────────
-- Avança o relógio para testar respostas recusadas
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values 
  (1008, 401, 'application/json', '{}'::jsonb, '{"code":401}', false, null, privado.agora() - interval '2 minutes'),
  (1009, 403, 'application/json', '{}'::jsonb, '{"code":403}', false, null, privado.agora() - interval '2 minutes'),
  (1010, 404, 'application/json', '{}'::jsonb, '{"code":404}', false, null, privado.agora() - interval '1 minute');

select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_resposta_recusada'),
  1,
  'respostas HTTP 401, 403 e 404 recentes emitem alerta operacional pgnet_resposta_recusada'
);

select is(
  (select count(*)::int from pgmq.q_email where (message->>'tipo') = 'alerta' and (message->>'codigo') = 'pgnet_resposta_recusada' and (message->>'valor')::int = 3),
  1,
  'a quantidade exata de respostas recusadas (3, cobrindo 401, 403 e 404) é enviada como valor numérico'
);

-- ── 8. Respostas recusadas (401/403/404) NÃO são contabilizadas no transporte ──
-- O número de alertas de transporte deve permanecer exatamente 1
select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_falha_transporte'),
  1,
  'respostas recusadas 401/403/404 não são somadas nem afetam o código pgnet_falha_transporte'
);

-- ── 9. Rate-limit 1/hora independente para pgnet_resposta_recusada ────────────
select privado.verificar_saude();

select is(
  (select suprimidos from privado.alerta_emitido where codigo = 'pgnet_resposta_recusada'),
  1,
  'segunda chamada dentro de 1h suprime o alerta pgnet_resposta_recusada'
);

-- ── 10. Sigilo Absoluto: nada de headers ou content vazado nos alertas ────────
select is(
  (select count(*)::int from pgmq.q_email where (message->>'tipo') = 'alerta' and message ? 'headers'),
  0,
  'cabeçalhos HTTP da tabela net._http_response nunca são colocados na mensagem do alerta'
);

select is(
  (select count(*)::int from pgmq.q_email where (message->>'tipo') = 'alerta' and message ? 'content'),
  0,
  'conteúdo de resposta da tabela net._http_response nunca é colocado na mensagem do alerta'
);

-- ── 12. Robustez defensiva: chamada limpa a verificar_saude ───────────────────
select lives_ok(
  'select privado.verificar_saude()',
  'verificar_saude executa defensivamente e com sucesso'
);

-- ── 13. Isolamento dos blocos 1 a 6: falhas prévias continuam alertando ────────
delete from privado.alerta_emitido where codigo = 'falha_execucao_edge_function';
insert into privado.falha_execucao (origem, codigo, detalhes, criada_em)
values ('enviar-email', 'erro_teste', '{"status":500}'::jsonb, privado.agora() - interval '2 minutes');

select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'falha_execucao_edge_function'),
  1,
  'alerta de falha_execucao dos blocos 1-6 é emitido com sucesso e não é afetado pelo bloco 7'
);

-- ── 14. Guarda: quando extensão pg_net ou net._http_response está ausente, cai no else ──
savepoint s_guarda_pgnet;
set local frila.simular_sem_pgnet = 'on';
delete from privado.alerta_emitido where codigo = 'pgnet_monitor_indisponivel';

select lives_ok(
  'select privado.verificar_saude()',
  'verificar_saude roda normalmente mesmo com net._http_response ausente (guarda ativa)'
);

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_monitor_indisponivel'),
  1,
  'guarda ausente/sem privilégio dispara alerta pgnet_monitor_indisponivel via else'
);

rollback to savepoint s_guarda_pgnet;

-- ── 15. Exceção: quando consulta gera erro em tempo de execução, bloco exception captura e emite alerta ──
savepoint s_excecao_pgnet;
set local frila.simular_excecao_pgnet = 'on';
delete from privado.alerta_emitido where codigo = 'pgnet_monitor_indisponivel';

select lives_ok(
  'select privado.verificar_saude()',
  'verificar_saude não quebra ao disparar exceção dentro do bloco 7 (pg_net)'
);

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_monitor_indisponivel'),
  1,
  'bloco de exceção do pg_net captura erro e dispara alerta pgnet_monitor_indisponivel'
);

rollback to savepoint s_excecao_pgnet;
set local frila.simular_excecao_pgnet = 'off';

-- ── 16. Guarda eh_teste: fora do ambiente de teste, ganchos frila.simular_* são ignorados ──
savepoint s_sem_eh_teste;
update privado.ambiente set eh_teste = false;
set local frila.simular_sem_pgnet = 'on';
delete from privado.alerta_emitido where codigo = 'pgnet_monitor_indisponivel';

select lives_ok(
  'select privado.verificar_saude()',
  'verificar_saude roda sem erro quando eh_teste é falso mesmo com frila.simular_sem_pgnet ativo'
);

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_monitor_indisponivel'),
  0,
  'gancho frila.simular_sem_pgnet é ignorado fora de teste (zero alertas indevidos)'
);

set local frila.simular_sem_pgnet = 'off';
set local frila.simular_excecao_pgnet = 'on';

select lives_ok(
  'select privado.verificar_saude()',
  'verificar_saude roda sem erro quando eh_teste é falso mesmo com frila.simular_excecao_pgnet ativo'
);

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_monitor_indisponivel'),
  0,
  'gancho frila.simular_excecao_pgnet é ignorado fora de teste (zero alertas indevidos)'
);

rollback to savepoint s_sem_eh_teste;
set local frila.simular_excecao_pgnet = 'off';

-- ── 17. Rate-limit para pgnet_monitor_indisponivel ───────────────────────────
select ok(
  privado.emitir_alerta('pgnet_monitor_indisponivel', 1),
  'primeiro alerta de pgnet_monitor_indisponivel é emitido com sucesso'
);

select is(
  privado.emitir_alerta('pgnet_monitor_indisponivel', 1),
  false,
  'segundo alerta de pgnet_monitor_indisponivel dentro de 1h é suprimido pelo rate-limit'
);

select * from finish();
rollback;

