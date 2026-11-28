-- 928_turno_vaga_origem.sql
--
-- A vaga dentro de `Turno` leva `origem` (`VagaResumo.origem`, contrato 0.2.55). Quem monta o turno é
-- `privado.turno_em_json`, usado por `public.meus_turnos` e pela exportação (`privado.meus_dados`, coleção `turnos`).
-- Sem a chave, o app lê "ausente vale publicacao" e toda vaga direta parece normal na tela de cancelar.
--   A  meus_turnos do profissional: o turno da vaga direta sai com 'chamada_direta' e o da vaga normal com 'publicacao'
--   B  meus_turnos da casa: o mesmo
--   C  exportação (profissional e contratante): o mesmo, na coleção turnos
--   D  os privilégios e a blindagem da função são os de antes
-- Cenário (`cenarios.sql`): Ana (a…01 / e…01) tem o turno f2…201 na vaga d…02 e o f2…701 na vaga d…07, as duas do
-- Bar do Cerrado (c…01), administrado pela Zélia (b…01). Só dados sintéticos.
begin;
select plan(17);

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
  'b0000000-0000-4000-8000-000000000001'::uuid as zelia,
  'c0000000-0000-4000-8000-000000000001'::uuid as casa,
  'd0000000-0000-4000-8000-000000000002'::uuid as vaga_direta,
  'd0000000-0000-4000-8000-000000000007'::uuid as vaga_publicada,
  'f2000000-0000-4000-8000-000000000201'::uuid as turno_direto,
  'f2000000-0000-4000-8000-000000000701'::uuid as turno_publicado;

-- A vaga direta é a que `chamar_profissional` grava com `origem = 'chamada_direta'`; aqui só se marca a coluna, que é
-- tudo o que `turno_em_json` lê.
update public.vaga set origem = 'chamada_direta' where id = (select vaga_direta from ids);

-- ── 0. O cenário tem o que o teste supõe (senão ele passaria vazio) ──────────

select is((select origem from public.vaga where id = (select vaga_direta from ids)), 'chamada_direta',
  '0a cenário: a vaga d…02 é direta');
select is((select origem from public.vaga where id = (select vaga_publicada from ids)), 'publicacao',
  '0b cenário: a vaga d…07 é de publicação');

-- Uma linha por (caminho, turno), com o objeto `vaga` que saiu.
create temp table saidas (caminho text, turno uuid, vaga jsonb);

insert into saidas
  select 'meus_turnos_prof', (e->>'id')::uuid, e->'vaga'
    from jsonb_array_elements(pg_temp.como((select ana from ids), $$ select public.meus_turnos() $$)) e
   where (e->>'id')::uuid in (select turno_direto from ids union all select turno_publicado from ids);

insert into saidas
  select 'meus_turnos_casa', (e->>'id')::uuid, e->'vaga'
    from jsonb_array_elements(pg_temp.como((select zelia from ids),
           $$ select public.meus_turnos(null, null, 'c0000000-0000-4000-8000-000000000001') $$)) e
   where (e->>'id')::uuid in (select turno_direto from ids union all select turno_publicado from ids);

insert into saidas
  select 'exportacao_prof', (e->>'id')::uuid, e->'vaga'
    from (select privado.meus_dados((select ana from ids)) as j) x, jsonb_array_elements(x.j->'turnos') e
   where (e->>'id')::uuid in (select turno_direto from ids union all select turno_publicado from ids);

insert into saidas
  select 'exportacao_casa', (e->>'id')::uuid, e->'vaga'
    from (select privado.meus_dados((select zelia from ids)) as j) x, jsonb_array_elements(x.j->'turnos') e
   where (e->>'id')::uuid in (select turno_direto from ids union all select turno_publicado from ids);

select is(
  (select array_agg(caminho || '=' || n order by caminho)
     from (select caminho, count(*) as n from saidas group by caminho) c),
  array['exportacao_casa=2', 'exportacao_prof=2', 'meus_turnos_casa=2', 'meus_turnos_prof=2'],
  '0c os quatro caminhos trazem os dois turnos');

create function pg_temp.origem(p_caminho text, p_turno uuid) returns text language sql as $$
  select vaga->>'origem' from saidas where caminho = p_caminho and turno = p_turno
$$;

-- ── A. meus_turnos do profissional ───────────────────────────────────────────

select is(pg_temp.origem('meus_turnos_prof', (select turno_direto from ids)), 'chamada_direta',
  'A1 meus_turnos (profissional): o turno da vaga direta sai com origem = chamada_direta');
select is(pg_temp.origem('meus_turnos_prof', (select turno_publicado from ids)), 'publicacao',
  'A2 meus_turnos (profissional): o turno da vaga normal sai com origem = publicacao');

-- ── B. meus_turnos da casa ───────────────────────────────────────────────────

select is(pg_temp.origem('meus_turnos_casa', (select turno_direto from ids)), 'chamada_direta',
  'B1 meus_turnos (casa): o turno da vaga direta sai com origem = chamada_direta');
select is(pg_temp.origem('meus_turnos_casa', (select turno_publicado from ids)), 'publicacao',
  'B2 meus_turnos (casa): o turno da vaga normal sai com origem = publicacao');

-- ── C. exportação (privado.meus_dados, coleção turnos) ───────────────────────

select is(pg_temp.origem('exportacao_prof', (select turno_direto from ids)), 'chamada_direta',
  'C1 exportação (profissional): o turno da vaga direta sai com origem = chamada_direta');
select is(pg_temp.origem('exportacao_prof', (select turno_publicado from ids)), 'publicacao',
  'C2 exportação (profissional): o turno da vaga normal sai com origem = publicacao');
select is(pg_temp.origem('exportacao_casa', (select turno_direto from ids)), 'chamada_direta',
  'C3 exportação (contratante): o turno da vaga direta sai com origem = chamada_direta');
select is(pg_temp.origem('exportacao_casa', (select turno_publicado from ids)), 'publicacao',
  'C4 exportação (contratante): o turno da vaga normal sai com origem = publicacao');

-- ── D. privilégios e blindagem ───────────────────────────────────────────────

select ok(not has_function_privilege('anon', 'privado.turno_em_json(uuid, uuid)', 'execute'),
  'D1 anon não executa turno_em_json');
select ok(not has_function_privilege('authenticated', 'privado.turno_em_json(uuid, uuid)', 'execute'),
  'D2 authenticated não executa turno_em_json');
select ok(has_function_privilege('service_role', 'privado.turno_em_json(uuid, uuid)', 'execute'),
  'D3 service_role executa turno_em_json');
select ok(
  (select prosecdef and 'search_path=""' = any(proconfig) from pg_proc
    where oid = 'privado.turno_em_json(uuid, uuid)'::regprocedure),
  'D4 security definer com search_path vazio');
select is(
  (select provolatile::text from pg_proc where oid = 'privado.turno_em_json(uuid, uuid)'::regprocedure),
  's', 'D5 a função continua stable');
select ok(
  obj_description('privado.turno_em_json(uuid, uuid)'::regprocedure, 'pg_proc')
    like '%segue o leitor `autor` (0.2.89, #519), não o JWT.%',
  'D6 o comentário da função não perde o que já dizia');

select * from finish();
rollback;
