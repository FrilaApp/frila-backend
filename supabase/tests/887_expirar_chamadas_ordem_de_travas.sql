-- 887_expirar_chamadas_ordem_de_travas.sql
--
-- B-065 (#562): privado.expirar_chamadas pega a vaga antes da chamada (vaga -> chamada -> usuario).
--
-- O ciclo só aparece com várias conexões: scripts/corrida-chamada.sh, cenários 14 a 18 (40P01 em
-- 4 de 4 rodadas da ordem forçada antes da 20261117170000). Numa sessão só fica o catálogo, que
-- falha com o corpo da 20261117130000 (lá, 'for update of c' vinha primeiro e as chamadas iam
-- por expira_em):
--   1. as vagas das chamadas vencidas são travadas, em ordem de id, antes das chamadas;
--   2. as chamadas são travadas em ordem de id, só as das vagas travadas;
--   3. a função segue SECURITY DEFINER com search_path vazio.
begin;
set local search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(5);

create temp table fonte as
select f.src,
       strpos(f.src, 'order by g.id for no key update') as trava_vagas,
       strpos(f.src, 'for update of c') as trava_chamadas
  from (select regexp_replace(p.prosrc, '\s+', ' ', 'g') as src
          from pg_proc p where p.oid = 'privado.expirar_chamadas()'::regprocedure) f;

select ok((select trava_vagas > 0 and trava_chamadas > trava_vagas from fonte),
  'as vagas das chamadas vencidas são travadas (por id) antes das chamadas');
select ok((select strpos(src, 'c.vaga_id = any (v_vagas) order by c.id for update of c') > 0 from fonte),
  'as chamadas são travadas por id, só as das vagas já travadas');
select ok((select strpos(substr(src, 1, trava_chamadas), 'for update') = 0 from fonte),
  'nenhuma outra trava (for update) vem antes da trava das chamadas');
select is((select prosecdef from pg_proc where oid = 'privado.expirar_chamadas()'::regprocedure), true,
  'expirar_chamadas segue SECURITY DEFINER');
select ok((select proconfig from pg_proc where oid = 'privado.expirar_chamadas()'::regprocedure) @> array['search_path=""'],
  'expirar_chamadas segue com search_path vazio');

select * from finish();
rollback;
