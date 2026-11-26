-- 905_meus_dados_nome_inteiro_da_contraparte.sql
--
-- Issue #519 (acompanhamento do #518, contrato 0.2.89): na exportação do contratante (`privado.meus_dados`), a
-- contraparte de um turno é o profissional e, com turno entre eles, o nome sai INTEIRO (`PerfilPublico.nome`).
-- A exportação roda pelo service_role, sem `auth.uid()`; o nome tem de seguir o titular exportado, não o JWT.
--
-- Cenário (`cenarios.sql`): Zélia (b…01) administra o Bar do Cerrado (c…01); Ana Ribeiro (a…01 / e…01) tem o turno
-- f2…201 confirmado numa vaga da casa. Só dados sintéticos.
--   1  meus_dados da Zélia: a contraparte do turno com a Ana sai com o nome inteiro (e não o curto)
--   2  a mesma contraparte, lida pelo próprio contratante em meus_turnos (JWT), sai igual: um nome só nos dois caminhos
--   3  o lado do profissional não muda: a contraparte da Ana continua sendo a casa
begin;
select plan(7);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

create temp table ids as select
  'a0000000-0000-4000-8000-000000000001'::uuid as ana,
  'e0000000-0000-4000-8000-000000000001'::uuid as ana_prof,
  'b0000000-0000-4000-8000-000000000001'::uuid as zelia,
  'f2000000-0000-4000-8000-000000000201'::uuid as turno;

-- ── 0. O cenário tem o que o teste supõe (senão ele passaria vazio) ──────────

select is(
  (select nome from public.usuario where id = (select ana from ids)), 'Ana Ribeiro',
  'cenário: a profissional se chama Ana Ribeiro');

select isnt(
  privado.nome_curto('Ana Ribeiro'), 'Ana Ribeiro',
  'o nome curto é diferente do inteiro (o teste distingue os dois)');

-- ── 1. A exportação do contratante ───────────────────────────────────────────

create temp table exp as
  select privado.meus_dados((select zelia from ids)) as j;

create temp table contraparte_exp as
  select t->'contraparte' as c
    from exp, jsonb_array_elements(j->'turnos') t
   where t->>'id' = (select turno::text from ids);

select is((select count(*) from contraparte_exp), 1::bigint,
  'a exportação da Zélia traz o turno com a Ana');

select is((select c->>'nome' from contraparte_exp), 'Ana Ribeiro',
  '#519: com turno entre eles, a contraparte sai com o nome inteiro na exportação do contratante');

-- ── 2. O mesmo nome pelo caminho do JWT ──────────────────────────────────────

select is(
  (select e->'contraparte'->>'nome'
     from jsonb_array_elements(pg_temp.como((select zelia from ids),
            $$ select public.meus_turnos(null, null, 'c0000000-0000-4000-8000-000000000001') $$)) e
    where e->>'id' = (select turno::text from ids)),
  'Ana Ribeiro',
  'meus_turnos do contratante devolve o mesmo nome inteiro');

-- ── 3. O lado do profissional não muda ───────────────────────────────────────

create temp table exp_prof as
  select t->'contraparte' as c
    from (select privado.meus_dados((select ana from ids)) as j) x, jsonb_array_elements(x.j->'turnos') t
   where t->>'id' = (select turno::text from ids);

select is((select c->>'tipo' from exp_prof), 'estabelecimento',
  'a exportação da profissional continua com a casa como contraparte');

select is((select c->>'id' from exp_prof), 'c0000000-0000-4000-8000-000000000001',
  'e a casa é o Bar do Cerrado');

select * from finish();
rollback;
