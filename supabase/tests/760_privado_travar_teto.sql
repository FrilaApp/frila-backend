-- 760_privado_travar_teto.sql
-- Cobertura direta de privado.travar_teto(uuid): o cadeado por profissional que serializa as
-- confirmações do teto de RN23 (candidatar/escolher/denunciar chamam antes de contar).
--
-- O que um pgTAP numa sessão só consegue provar: QUAL cadeado é tomado (chave e escopo) e que
-- profissionais diferentes não disputam o mesmo. A espera entre duas sessões é concorrência e
-- fica com o pgbench; aqui isso é declarado, não simulado.
--
-- Mutantes que estes testes matam (ver PR):
--   M1  prefixo 'rn23:' trocado por outro      -> teste 3 fica vermelho
--   M2  chave sem o profissional (constante)   -> testes 3, 4 e 6 ficam vermelhos
--   M3  não tomar cadeado nenhum (select 1)    -> testes 3, 4 e 6 ficam vermelhos

begin;
select plan(6);

-- Cadeados advisory que ESTA sessão segura, com a chave de 64 bits reconstruída de classid/objid.
create function pg_temp.chaves() returns setof bigint
language sql as $$
  select ((classid::bigint << 32) | objid::bigint)
    from pg_locks
   where locktype = 'advisory' and pid = pg_backend_pid() and granted
$$;

select is((select count(*) from pg_temp.chaves()), 0::bigint,
  'antes da chamada a sessão não segura cadeado advisory nenhum');

select lives_ok(
  $$ select privado.travar_teto('76000000-0000-4000-8000-0000000000c1') $$,
  'travar_teto toma o cadeado sem erro');

select ok(
  hashtextextended('rn23:76000000-0000-4000-8000-0000000000c1', 0) in (select * from pg_temp.chaves()),
  'o cadeado tomado é o da chave "rn23:<profissional>" (mesma que todos os chamadores do teto usam)');

select privado.travar_teto('76000000-0000-4000-8000-0000000000c2');

select is((select count(*) from pg_temp.chaves()), 2::bigint,
  'outro profissional toma outro cadeado: o teto de um não trava o de outro');

select lives_ok(
  $$ select privado.travar_teto('76000000-0000-4000-8000-0000000000c1') $$,
  'repetir o mesmo profissional na mesma transação não se bloqueia nem falha (reentrante)');

select is((select count(*) from pg_temp.chaves()), 2::bigint,
  'a repetição não cria cadeado novo: continuam dois');

select * from finish();
rollback;
