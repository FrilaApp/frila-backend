-- `contato_do_turno` na 0.2.49: deprecada no contrato, mas ainda no ar.
--
-- Decisão de produto de 04/11/2026 (issue #396): o contato não é trocado pelo app. O
-- contrato 0.2.49 marca a operação como `deprecated` e diz que ela segue respondendo como
-- hoje enquanto houver app antigo na loja. Este arquivo trava as duas metades: a função
-- continua existindo e liberada só para `authenticated`, e o catálogo diz que está
-- deprecada. O comportamento da resposta (prazo, bloqueio, conta ativa) é de 150.

begin;
select plan(5);

select has_function('public', 'contato_do_turno', array['uuid'],
  'contato_do_turno segue no ar para os apps já publicados');

select ok(
  has_function_privilege('authenticated', 'public.contato_do_turno(uuid)', 'execute'),
  'authenticated segue executando contato_do_turno');

select ok(
  not has_function_privilege('anon', 'public.contato_do_turno(uuid)', 'execute'),
  'anon continua sem executar contato_do_turno');

select matches(
  obj_description('public.contato_do_turno(uuid)'::regprocedure, 'pg_proc'),
  '^DEPRECADA na 0\.2\.49',
  'o comentário da função abre dizendo que ela está deprecada na 0.2.49');

select matches(
  obj_description('public.contato_do_turno(uuid)'::regprocedure, 'pg_proc'),
  'contato_expirado',
  'o comentário mantém o comportamento vigente (403 contato_expirado)');

select * from finish();
rollback;
