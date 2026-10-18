-- Falha de transporte no despacho imediato registra em privado.falha_execucao (Achado 3 da AUDITORIA-CRON.md).
--
-- Quando net.http_post falha (ex: timeout de rede, URL inacessível, erro de transporte):
--   1. A falha NÃO deve gravar ocorrência do tipo 'revisao_despacho' em public.ocorrencia contra o contratante.
--   2. A falha DEVE ser registrada em privado.falha_execucao com origem='despacho_imediato' e codigo='falha_transporte_pg_net'.
--   3. A mensagem deve permanecer íntegra na fila pgmq.q_despacho para repetição pelo pg_cron.

begin;

select plan(6);

set local frila.agendador_secret = 'segredo-de-teste';
-- URL inválida que força net.http_post a falhar/lançar exceção
set local frila.edge_function_url = 'http://[invalid-url-force-error';

-- Dispara o despacho com vaga_id literal explícito
select lives_ok(
  $$ select privado.disparar_despacho('a0000000-0000-4000-8000-000000000099'::uuid) $$,
  'privado.disparar_despacho captura falha de transporte no exception when others sem abortar transação'
);

-- Asserção 1: NÃO deve ter inserido nada em public.ocorrencia contra o contratante desta vaga
select is(
  (select count(*)::int from public.ocorrencia
    where tipo = 'revisao_despacho'
      and (motivo like '%a0000000-0000-4000-8000-000000000099%'
           or resultado like '%a0000000-0000-4000-8000-000000000099%')),
  0,
  'falha de transporte do pg_net NÃO gera ocorrência de revisao_despacho contra o contratante desta vaga'
);

-- Asserção 2: DEVE ter registrado em privado.falha_execucao
select is(
  (select count(*)::int from privado.falha_execucao
    where origem = 'despacho_imediato' and codigo = 'falha_transporte_pg_net'),
  1,
  'falha de transporte é registrada em privado.falha_execucao'
);

-- Asserção 3: Detalhes preservam a vaga_id literal passada
select is(
  (select count(*)::int from privado.falha_execucao
    where origem = 'despacho_imediato'
      and codigo = 'falha_transporte_pg_net'
      and detalhes = jsonb_build_object('vaga_id', 'a0000000-0000-4000-8000-000000000099')),
  1,
  'detalhes da falha_execucao preservam a vaga_id literal para observabilidade'
);

-- Asserção 4: Se chamada sem vaga_id, também grava sem falhar
select lives_ok(
  $$ select privado.disparar_despacho(null) $$,
  'disparar_despacho(null) sob erro de transporte também grava em falha_execucao com detalhes nulos'
);

-- Asserção 5: Detalhes da segunda chamada são nulos
select is(
  (select count(*)::int from privado.falha_execucao
    where origem = 'despacho_imediato'
      and codigo = 'falha_transporte_pg_net'
      and detalhes is null),
  1,
  'detalhes são nulos quando disparar_despacho é invocado sem vaga_id'
);

select * from finish();
rollback;
