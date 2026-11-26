-- 915_retencao_passo_falhou_aciona_alerta.sql · cartão ZRZrYYAe (canal do titular, LGPD art. 18).
-- O que o 838 prova: um passo da rotina diária de retenção que falha vai para privado.falha_execucao e não derruba a rotina.
-- O que o 838 só afirma no texto ("o item 6 da verificar_saude alerta"): que essa falha vira alerta para a equipe.
-- Este teste fecha o elo: passo de retenção falha, verificar_saude() emite o alerta falha_execucao_edge_function, uma vez por hora,
-- só dentro da janela de 15 minutos, e o aviso na fila de e-mail não carrega dado pessoal.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-26 12:00:00+00', true);
select plan(12);

delete from privado.alerta_emitido;
delete from privado.falha_execucao;
delete from pgmq.q_email;

-- Caminho normal: a rotina roda sem falha e a verificação de saúde não acusa falha de execução.
select is((select (privado.executar_retencao_diaria())->'falhas'), '[]'::jsonb, 'caminho normal: nenhum passo de retenção falha');
select lives_ok($$ select privado.verificar_saude() $$, 'verificar_saude() roda');
select ok(not exists (select 1 from privado.alerta_emitido where codigo = 'falha_execucao_edge_function'),
  'sem falha de retenção, o alerta de falha de execução não é emitido');

-- Um passo é forçado a falhar, só dentro desta transação (mesmo recurso do 838).
create or replace function privado.limpar_checkin_por_codigo(p_dias integer default 90, p_limite integer default 500)
returns integer language plpgsql as $$ begin raise exception 'falha forçada no 915' using errcode = 'U0915'; end $$;

select is((select (privado.executar_retencao_diaria())->'falhas'), '[{"passo": "expurgo_checkin_por_codigo", "sqlstate": "U0915"}]'::jsonb,
  'o passo forçado falha e só ele');
select is((select count(*)::int from privado.falha_execucao where origem = 'executar_retencao_diaria' and codigo = 'retencao_passo_falhou'), 1,
  'a falha de retenção ficou registrada em privado.falha_execucao');

select lives_ok($$ select privado.verificar_saude() $$, 'verificar_saude() roda com a falha registrada');
select is((select ultimo_em from privado.alerta_emitido where codigo = 'falha_execucao_edge_function'),
  '2026-11-26 12:00:00+00'::timestamptz, 'a falha de retenção acende o alerta falha_execucao_edge_function');
select is((select count(*)::int from pgmq.q_email where message->>'tipo' = 'alerta' and message->>'codigo' = 'falha_execucao_edge_function'), 1,
  'o alerta entrou na fila de e-mail da equipe');
select is((select array_agg(k order by k) from pgmq.q_email, jsonb_object_keys(message) k where message->>'codigo' = 'falha_execucao_edge_function'),
  array['codigo', 'tipo', 'valor'], 'o aviso leva só o código, o tipo e a contagem: nenhum dado pessoal');

-- Uma vez por hora por tipo: a segunda verificação logo depois não enfileira outro.
select privado.verificar_saude();
select is((select count(*)::int from pgmq.q_email where message->>'codigo' = 'falha_execucao_edge_function'), 1,
  'repetir a verificação dentro da hora não repete o alerta (teto de 1 por hora por tipo)');

-- Fora da janela de 15 minutos, a mesma falha não acende alerta novo.
select set_config('frila.agora', '2026-11-26 13:30:00+00', true);
delete from privado.alerta_emitido;
delete from pgmq.q_email;
select privado.verificar_saude();
select ok(not exists (select 1 from privado.alerta_emitido where codigo = 'falha_execucao_edge_function'),
  'passados 15 minutos, a falha antiga não acende o alerta de novo');
select is((select count(*)::int from pgmq.q_email where message->>'codigo' = 'falha_execucao_edge_function'), 0,
  'e nada entra na fila de e-mail por ela');

select * from finish();
rollback;
