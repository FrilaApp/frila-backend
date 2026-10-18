-- Invoca as duas funções e confere os cabeçalhos enfileirados pelo pg_net.
-- Todos os valores de segredo deste teste são sintéticos; o rollback isola o Vault.
begin;
select plan(22);

set local frila.edge_function_url = 'http://127.0.0.1:54321/functions/v1/despachar';
set local frila.email_function_url = 'http://127.0.0.1:54321/functions/v1/enviar-email';
delete from vault.secrets where name = 'agendador_secret';
delete from pgmq.q_email;
-- Mantém uma mensagem na fila para exercitar a leitura do segredo no e-mail.
set local frila.agendador_secret = 'segredo-sintetico-preparo-748';
select pgmq.send('email', '{"tipo":"teste_vault_748"}'::jsonb);
delete from net.http_request_queue;
create temporary table requisicoes_vault (funcao text, req_id bigint) on commit drop;

-- Só Vault: o retorno não nulo detecta a saída defensiva do e-mail sem segredo.
set local frila.agendador_secret = '';
select vault.create_secret('segredo-sintetico-vault-748', 'agendador_secret');
insert into requisicoes_vault values
  ('despacho', privado.disparar_despacho()),
  ('email', privado.disparar_email());
select ok(req_id is not null, funcao || ': só Vault retorna requisição')
  from requisicoes_vault order by funcao;
select is(q.headers->>'x-agendador-secret', 'segredo-sintetico-vault-748',
          r.funcao || ': só Vault preenche x-agendador-secret')
  from requisicoes_vault r left join net.http_request_queue q on q.id = r.req_id order by r.funcao;
select is(q.headers->>'Authorization', 'Bearer segredo-sintetico-vault-748',
          r.funcao || ': só Vault preenche Authorization')
  from requisicoes_vault r left join net.http_request_queue q on q.id = r.req_id order by r.funcao;

-- Ambos: conferir os cabeçalhos das funções prova a prioridade efetiva do Vault.
set local frila.agendador_secret = 'segredo-sintetico-guc-748';
truncate requisicoes_vault;
insert into requisicoes_vault values
  ('despacho', privado.disparar_despacho()),
  ('email', privado.disparar_email());
select ok(req_id is not null, funcao || ': ambas as fontes retornam requisição')
  from requisicoes_vault order by funcao;
select is(q.headers->>'x-agendador-secret', 'segredo-sintetico-vault-748',
          r.funcao || ': Vault tem prioridade sobre GUC em x-agendador-secret')
  from requisicoes_vault r left join net.http_request_queue q on q.id = r.req_id order by r.funcao;
select is(q.headers->>'Authorization', 'Bearer segredo-sintetico-vault-748',
          r.funcao || ': Vault tem prioridade sobre GUC em Authorization')
  from requisicoes_vault r left join net.http_request_queue q on q.id = r.req_id order by r.funcao;

-- Sem Vault: as mesmas funções usam o GUC de compatibilidade.
delete from vault.secrets where name = 'agendador_secret';
truncate requisicoes_vault;
insert into requisicoes_vault values
  ('despacho', privado.disparar_despacho()),
  ('email', privado.disparar_email());
select ok(req_id is not null, funcao || ': fallback GUC retorna requisição')
  from requisicoes_vault order by funcao;
select is(q.headers->>'x-agendador-secret', 'segredo-sintetico-guc-748',
          r.funcao || ': fallback GUC preenche x-agendador-secret')
  from requisicoes_vault r left join net.http_request_queue q on q.id = r.req_id order by r.funcao;
select is(q.headers->>'Authorization', 'Bearer segredo-sintetico-guc-748',
          r.funcao || ': fallback GUC preenche Authorization')
  from requisicoes_vault r left join net.http_request_queue q on q.id = r.req_id order by r.funcao;

-- Nenhuma fonte: preserva a exceção do despacho e o warning + null do e-mail.
set local frila.agendador_secret = '';
delete from net.http_request_queue;
select throws_ok($$ select privado.disparar_despacho() $$,
  'P0001', 'Configuração frila.agendador_secret ausente no banco de dados',
  'despacho sem segredo mantém a exceção atual');
select is(privado.disparar_email(), null::bigint, 'e-mail sem segredo retorna null');
select is((select count(*)::int from net.http_request_queue), 0,
  'nenhuma requisição é enfileirada sem segredo');
select is((select count(*)::int from pgmq.q_email), 1,
  'e-mail sem segredo preserva a mensagem na fila');

select * from finish();
rollback;
