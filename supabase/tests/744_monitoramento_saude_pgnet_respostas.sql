-- Teste pgTAP: Alerta operacional de falhas assíncronas do pg_net em verificar_saude (Item 22)
-- Cobre:
-- 1. Respostas 200 normais não disparam alerta
-- 2. Falhas antigas (>15 min) não disparam alerta
-- 3. timed_out = true emite alerta 'pgnet_falha_transporte'
-- 4. error_msg is not null emite alerta 'pgnet_falha_transporte'
-- 5. status_code >= 500 (502) emite alerta 'pgnet_falha_transporte'
-- 6. status_code in (401, 403, 404) emite alerta 'pgnet_resposta_recusada'
-- 7. Rate-limit de 1h suprime o segundo alerta
-- 8. Execução defensiva de verificar_saude não quebra

begin;
select plan(11);

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

-- ── 4. timed_out = true nos últimos 15 min emite 'pgnet_falha_transporte' ─────
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values (1005, null, null, null, null, true, null, privado.agora() - interval '5 minutes');

select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_falha_transporte'),
  1,
  'timed_out = true recente emite alerta operacional pgnet_falha_transporte'
);

-- ── 5. Rate-limit 1/hora suprime envio imediato subsequente ───────────────────
select privado.verificar_saude();

select is(
  (select suprimidos from privado.alerta_emitido where codigo = 'pgnet_falha_transporte'),
  1,
  'segunda chamada dentro da janela de 1h suprime o alerta pgnet_falha_transporte'
);

-- ── 6. error_msg is not null e status_code 502 contados em transporte ─────────
-- Avança o relógio mais de 1h para vencer o rate-limit
select set_config('frila.agora', '2026-10-18 13:30:00-03', true);

insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values 
  (1006, null, null, null, null, false, 'Couldn''t connect to server', privado.agora() - interval '3 minutes'),
  (1007, 502, 'text/html', '{}'::jsonb, 'Bad Gateway', false, null, privado.agora() - interval '4 minutes');

select privado.verificar_saude();

-- O alerta deve ter sido emitido de novo com valor = 2 falhas na janela
select is(
  (select count(*)::int from pgmq.q_email where (message->>'tipo') = 'alerta' and (message->>'codigo') = 'pgnet_falha_transporte' and (message->>'valor')::int = 2),
  1,
  'falha de conexão (error_msg) e erro 502 somam na contagem do alerta pgnet_falha_transporte'
);

-- ── 7. Respostas 401 e 404 emitem 'pgnet_resposta_recusada' ───────────────────
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values 
  (1008, 401, 'application/json', '{}'::jsonb, '{"code":401}', false, null, privado.agora() - interval '2 minutes'),
  (1009, 404, 'application/json', '{}'::jsonb, '{"code":404}', false, null, privado.agora() - interval '1 minute');

select privado.verificar_saude();

select is(
  (select count(*)::int from privado.alerta_emitido where codigo = 'pgnet_resposta_recusada'),
  1,
  'respostas HTTP 401 e 404 recentes emitem alerta operacional pgnet_resposta_recusada'
);

select is(
  (select count(*)::int from pgmq.q_email where (message->>'tipo') = 'alerta' and (message->>'codigo') = 'pgnet_resposta_recusada' and (message->>'valor')::int = 2),
  1,
  'a quantidade de respostas 401/404 é enviada como valor numérico para a equipe'
);

-- ── 8. Rate-limit 1/hora independente para pgnet_resposta_recusada ────────────
select privado.verificar_saude();

select is(
  (select suprimidos from privado.alerta_emitido where codigo = 'pgnet_resposta_recusada'),
  1,
  'segunda chamada dentro de 1h suprime o alerta pgnet_resposta_recusada'
);

-- ── 9. Sigilo Absoluto: nada de headers ou content vazado nos alertas ─────────
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

-- ── 10. Robustez defensiva: chamada limpa a verificar_saude ──────────────────
select lives_ok(
  'select privado.verificar_saude()',
  'verificar_saude executa defensivamente e com sucesso'
);

select * from finish();
rollback;
