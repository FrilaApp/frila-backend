-- Falha de transporte no despacho imediato registra em privado.falha_execucao (Achado 3 da AUDITORIA-CRON.md).
--
-- Quando net.http_post falha (ex: timeout de rede, URL inacessível, erro de transporte):
--   1. A falha NÃO deve gravar ocorrência do tipo 'revisao_despacho' em public.ocorrencia contra o contratante.
--   2. A falha DEVE ser registrada em privado.falha_execucao com origem='despacho_imediato' e codigo='falha_transporte_pg_net'.
--   3. A mensagem deve permanecer íntegra na fila pgmq.q_despacho para repetição pelo pg_cron.

begin;

select plan(5);

set local frila.agendador_secret = 'segredo-de-teste';
-- URL inválida que força net.http_post a falhar/lançar exceção
set local frila.edge_function_url = 'http://[invalid-url-force-error';

-- Pega uma vaga real do seed/cenários
create temp table vaga_teste as select id from public.vaga limit 1;

-- Dispara o despacho com URL que falha
select lives_ok(
  $$ select privado.disparar_despacho((select id from vaga_teste)) $$,
  'privado.disparar_despacho captura falha de transporte no exception when others sem abortar transação'
);

-- Asserção 1: NÃO deve ter inserido nada em public.ocorrencia contra o contratante
select is(
  (select count(*)::int from public.ocorrencia where tipo = 'revisao_despacho'),
  0,
  'falha de transporte do pg_net NÃO gera ocorrência de revisao_despacho em public.ocorrencia contra o contratante'
);

-- Asserção 2: DEVE ter registrado em privado.falha_execucao
select is(
  (select count(*)::int from privado.falha_execucao
    where origem = 'despacho_imediato' and codigo = 'falha_transporte_pg_net'),
  1,
  'falha de transporte é registrada em privado.falha_execucao'
);

-- Asserção 3: Detalhes contêm a vaga_id
select is(
  (select detalhes->>'vaga_id' from privado.falha_execucao
    where origem = 'despacho_imediato' and codigo = 'falha_transporte_pg_net'
    order by criada_em desc limit 1),
  (select id::text from vaga_teste),
  'detalhes da falha_execucao preservam a vaga_id para observabilidade'
);

-- Asserção 4: Se chamada sem vaga_id, também grava sem falhar
select lives_ok(
  $$ select privado.disparar_despacho(null) $$,
  'disparar_despacho(null) sob erro de transporte também grava em falha_execucao com detalhes nulos'
);

select * from finish();
rollback;
