-- Teste pgTAP: supabase/tests/826_volatilidade_resolver_e_exigir_recurso.sql
-- Migração: 20261108210000_volatilidade_resolver_e_exigir_recurso.sql (B-VOLATIL).
-- As duas funções que só levantam pelo public.erro deixam de ser STABLE: o plpgsql_check da CI
-- (postgres 17.11) acusava "routine is marked as STABLE, but expression is VOLATILE" (#443, #444).
-- Sem o alter de uma delas, o teste dela fica vermelho.

begin;

select plan(4);

select is(
  (select p.provolatile::text from pg_proc p
    where p.oid = 'privado.resolver_conta_demonstracao(uuid, text)'::regprocedure),
  'v',
  'privado.resolver_conta_demonstracao(uuid, text) é VOLATILE');

select is(
  (select p.provolatile::text from pg_proc p
    where p.oid = 'privado.exigir_recurso(text)'::regprocedure),
  'v',
  'privado.exigir_recurso(text) é VOLATILE');

-- Nenhuma chamadora fica mais estável que a função que ela chama.
select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'privado')
      and p.provolatile in ('s', 'i')
      and p.prosrc ~ 'privado\.(resolver_conta_demonstracao|exigir_recurso)\s*\('),
  0,
  'nenhuma função STABLE ou IMMUTABLE chama resolver_conta_demonstracao nem exigir_recurso');

-- O comportamento não muda: exigir_recurso continua recusando a chave desligada.
select throws_ok(
  $$ select privado.exigir_recurso('chave_que_nao_existe_826') $$,
  'PGRST',
  null,
  'exigir_recurso continua recusando chave ausente (vale desligada)');

select * from finish();
rollback;
