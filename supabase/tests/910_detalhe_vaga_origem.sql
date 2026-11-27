-- 910_detalhe_vaga_origem.sql
--
-- Z0HbaZ0P (acréscimo): `public.detalhe_vaga` devolve `origem` e `vaga_origem_id` (`Vaga.origem` e `Vaga.vaga_origem_id`, contrato 0.2.55 e
-- 0.2.56). Sem eles, a vaga direta e a vaga republicada a partir dela eram lidas como publicação comum.
--   A  vaga direta: origem = chamada_direta e vaga_origem_id nulo
--   B  vaga republicada de uma direta: origem = publicacao e vaga_origem_id = o id da direta
--   C  vaga comum: origem = publicacao e vaga_origem_id nulo
--   D  o resto da resposta não mudou, e as recusas e os privilégios são os de antes
-- Cenário (`cenarios.sql`): Ana (a…01, profissional) ocupa uma posição na vaga d…02 (Bar do Cerrado); d…01 é publicada pela mesma casa.
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-27 15:00:00+00', true);
select plan(20);

create function pg_temp.erro(sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  execute sql; return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return msg::jsonb || det::jsonb;
end $$;

create temp table ids as select
  'a0000000-0000-4000-8000-000000000001'::uuid as ana,
  'b0000000-0000-4000-8000-000000000002'::uuid as contratante,
  'd0000000-0000-4000-8000-000000000002'::uuid as direta,
  'd0000000-0000-4000-8000-000000000001'::uuid as republicada,
  'd0000000-0000-4000-8000-000000000007'::uuid as comum;

-- A direta é a que `chamar_profissional` grava com origem = chamada_direta; a republicada é a normal criada a partir dela
-- (`vaga_origem_id`, 20261107370000). Aqui só se marcam as colunas.
update public.vaga set origem = 'chamada_direta' where id = (select direta from ids);
update public.vaga set vaga_origem_id = (select direta from ids) where id = (select republicada from ids);

set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';
create temp table detalhe as
  select 'direta' as quem, public.detalhe_vaga((select direta from ids)) as j
  union all select 'republicada', public.detalhe_vaga((select republicada from ids))
  union all select 'comum', public.detalhe_vaga((select comum from ids));
reset request.jwt.claims;

-- ── A. Vaga direta ────────────────────────────────────────────────────────────
select is((select j->>'id' from detalhe where quem = 'direta'), (select direta::text from ids), '0 o detalhe é o da vaga direta (não passa vazio)');
select is((select j->>'origem' from detalhe where quem = 'direta'), 'chamada_direta', 'A1 a vaga direta sai com origem = chamada_direta');
select ok((select j ? 'vaga_origem_id' and jsonb_typeof(j->'vaga_origem_id') = 'null' from detalhe where quem = 'direta'),
  'A2 e com vaga_origem_id presente e nulo');

-- ── B. Vaga republicada a partir de uma direta ────────────────────────────────
select is((select j->>'id' from detalhe where quem = 'republicada'), (select republicada::text from ids), '0b o detalhe é o da republicada');
select is((select j->>'origem' from detalhe where quem = 'republicada'), 'publicacao', 'B1 a republicada sai com origem = publicacao');
select is((select j->>'vaga_origem_id' from detalhe where quem = 'republicada'), (select direta::text from ids),
  'B2 e com vaga_origem_id = o id da vaga direta');

-- ── C. Vaga comum ─────────────────────────────────────────────────────────────
select is((select j->>'id' from detalhe where quem = 'comum'), (select comum::text from ids), '0c o detalhe é o da vaga comum');
select is((select j->>'origem' from detalhe where quem = 'comum'), 'publicacao', 'C1 a vaga comum sai com origem = publicacao');
select ok((select j ? 'vaga_origem_id' and jsonb_typeof(j->'vaga_origem_id') = 'null' from detalhe where quem = 'comum'),
  'C2 e com vaga_origem_id presente e nulo');
select is((select count(*) from detalhe where jsonb_typeof(j->'origem') is distinct from 'string' or j->>'origem' not in ('publicacao', 'chamada_direta')),
  0::bigint, 'C3 em todo detalhe a origem é um valor de OrigemVaga');

-- ── D. O resto não mudou ──────────────────────────────────────────────────────
select is((select array_agg(k order by k) from (select distinct jsonb_object_keys(j) k from detalhe) x),
  array['distancia_km', 'estabelecimento', 'estado', 'fim_em', 'funcao', 'id', 'inclusos', 'inicio_em', 'local',
        'modo', 'observacoes', 'oculta', 'origem', 'participa_rateio', 'ponto', 'posicoes', 'posicoes_abertas', 'publicado_em',
        'regiao_administrativa', 'responsavel_local', 'traje', 'vaga_origem_id', 'valor_centavos'],
  'D1 as chaves são as de antes mais origem e vaga_origem_id');
select is(
  (select j->>'valor_centavos' from detalhe where quem = 'comum'),
  (select valor_centavos::text from public.vaga where id = (select comum from ids)), 'D2 o valor é o da tabela');
select is(
  (select j->>'modo' || '|' || (j->>'estado') from detalhe where quem = 'comum'),
  (select modo || '|' || estado from public.vaga where id = (select comum from ids)), 'D3 modo e estado são os da tabela');

set local request.jwt.claims = '{"sub":"a0000000-0000-4000-8000-000000000001","role":"authenticated"}';
select is(pg_temp.erro(format('select public.detalhe_vaga(%L)', 'd0000000-0000-4000-8000-0000000000ff'))->>'status', '404', 'D4 vaga inexistente: 404');
select is(pg_temp.erro('select public.detalhe_vaga(null)')->>'details', 'vaga_id', 'D5 sem vaga_id: 422');
reset request.jwt.claims;
select is(pg_temp.erro(format('select public.detalhe_vaga(%L)', (select comum from ids)))->>'status', '401', 'D6 sem sessão: 401');
set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';
select is(pg_temp.erro(format('select public.detalhe_vaga(%L)', (select comum from ids)))->>'status', '422', 'D7 contratante não lê o detalhe do profissional: 422 (perfil incompatível), como antes');
reset request.jwt.claims;
select ok(has_function_privilege('authenticated', 'public.detalhe_vaga(uuid)', 'execute'), 'D8 authenticated executa');
select ok(not has_function_privilege('anon', 'public.detalhe_vaga(uuid)', 'execute'), 'D9 anon não executa');
select ok((select prosecdef and 'search_path=""' = any(proconfig) from pg_proc where oid = 'public.detalhe_vaga(uuid)'::regprocedure),
  'D10 security definer com search_path vazio');

select * from finish();
rollback;
