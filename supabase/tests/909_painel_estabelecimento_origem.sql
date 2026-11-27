-- 909_painel_estabelecimento_origem.sql
--
-- Z0HbaZ0P: `public.painel_estabelecimento` devolve `vaga.origem` (`VagaResumo.origem`, contrato 0.2.55). Sem o campo, a vaga criada por
-- `chamar_profissional` (origem = chamada_direta) era lida como publicação e o "Acompanhar chamadas" de Minhas vagas nunca aparecia.
--   A  a vaga de origem chamada_direta sai com 'chamada_direta' e a publicada com 'publicacao'; todas saem com o campo, num valor do contrato
--   B  o resto da resposta não mudou: as mesmas chaves em `vaga`, no item e na raiz, e os valores que já existiam
--   C  as recusas e os privilégios são os de antes
-- Cenário (`cenarios.sql`): Zélia (b…01) administra o Bar do Cerrado (c…01), que tem vagas publicadas. Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-27 15:00:00+00', true);
select plan(22);

create function pg_temp.erro(sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  execute sql; return null;
exception when sqlstate 'PGRST' then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  return msg::jsonb || det::jsonb;
end $$;

create temp table ids as select
  'c0000000-0000-4000-8000-000000000001'::uuid as casa,
  'b0000000-0000-4000-8000-000000000001'::uuid as zelia,
  'd0000000-0000-4000-8000-000000000001'::uuid as vaga_publicada,
  'd0000000-0000-4000-8000-000000000002'::uuid as vaga_direta;

-- A vaga direta é a que `chamar_profissional` grava com `origem = 'chamada_direta'` (20261107300000); aqui só se marca a coluna.
update public.vaga set origem = 'chamada_direta' where id = (select vaga_direta from ids);

select is((select origem from public.vaga where id = (select vaga_publicada from ids)), 'publicacao', '0 cenário: a vaga publicada nasce com origem publicacao');
select is((select origem from public.vaga where id = (select vaga_direta from ids)), 'chamada_direta', '0b e a direta com origem chamada_direta');

set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}';
create temp table painel as
  select public.painel_estabelecimento((select casa from ids), now() - interval '10 years', now() + interval '10 years') as j;
reset request.jwt.claims;

create temp table vagas_do_painel as
  select v as item, v->'vaga' as vaga, v->'vaga'->>'id' as id
    from painel, jsonb_array_elements(j->'vagas') v;

-- ── A. origem ─────────────────────────────────────────────────────────────────

select ok((select count(*) from vagas_do_painel) >= 2, 'A0 o painel traz as vagas da casa (não passa vazio)');
select is((select vaga->>'origem' from vagas_do_painel where id = (select vaga_direta::text from ids)), 'chamada_direta',
  'A1 a vaga de origem chamada_direta sai com origem = chamada_direta');
select is((select vaga->>'origem' from vagas_do_painel where id = (select vaga_publicada::text from ids)), 'publicacao',
  'A2 a vaga publicada sai com origem = publicacao');
select is((select count(*) from vagas_do_painel where not (vaga ? 'origem')), 0::bigint, 'A3 nenhuma vaga sai sem a chave origem');
select is((select count(*) from vagas_do_painel where jsonb_typeof(vaga->'origem') is distinct from 'string'), 0::bigint,
  'A4 e nenhuma com origem nula ou de outro tipo');
select is((select count(*) from vagas_do_painel where vaga->>'origem' not in ('publicacao', 'chamada_direta')), 0::bigint,
  'A5 a origem é sempre um valor de OrigemVaga');
select is(
  (select array_agg(vaga->>'origem' order by id) from vagas_do_painel),
  (select array_agg(v.origem order by v.id::text) from public.vaga v where v.estabelecimento_id = (select casa from ids)),
  'A6 a origem de cada vaga no painel é a da tabela');

-- ── B. o resto não mudou ──────────────────────────────────────────────────────

select is((select array_agg(k order by k) from (select distinct jsonb_object_keys(vaga) k from vagas_do_painel) x),
  array['fim_em', 'funcao', 'id', 'inicio_em', 'local', 'origem', 'regiao_administrativa', 'valor_centavos'],
  'B1 vaga tem as 7 chaves de antes mais origem');
select is((select array_agg(k order by k) from (select distinct jsonb_object_keys(item) k from vagas_do_painel) x),
  array['alerta_vaga_vazia', 'candidatos_pendentes', 'estado', 'modo', 'oculta', 'posicoes', 'republicavel_em_urgencia', 'vaga'],
  'B2 o item do painel tem as mesmas chaves de antes');
select is((select array_agg(k order by k) from painel, jsonb_object_keys(j) k),
  array['checkins_pendentes', 'estabelecimento_id', 'vagas'], 'B3 a raiz tem as mesmas chaves de antes');
select is((select (j->>'estabelecimento_id')::uuid from painel), (select casa from ids), 'B4 estabelecimento_id é o da casa');
select is(
  (select vaga->>'funcao' || '|' || (vaga->>'valor_centavos') from vagas_do_painel where id = (select vaga_publicada::text from ids)),
  (select f.nome || '|' || v.valor_centavos from public.vaga v join public.funcao f on f.id = v.funcao_id where v.id = (select vaga_publicada from ids)),
  'B5 função e valor da vaga são os da tabela');
select is(
  (select item->>'modo' || '|' || (item->>'estado') from vagas_do_painel where id = (select vaga_publicada::text from ids)),
  (select v.modo || '|' || v.estado from public.vaga v where v.id = (select vaga_publicada from ids)),
  'B6 modo e estado do item são os da tabela');
select is(
  (select jsonb_array_length(item->'posicoes') from vagas_do_painel where id = (select vaga_publicada::text from ids)),
  (select count(*)::int from public.posicao where vaga_id = (select vaga_publicada from ids)),
  'B7 as posições da vaga continuam todas');

-- ── C. recusas e privilégios ──────────────────────────────────────────────────

reset request.jwt.claims;
select is(pg_temp.erro(format('select public.painel_estabelecimento(%L, now(), now())', (select casa from ids)))->>'status', '401',
  'C1 sem sessão: 401');
set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000002","role":"authenticated"}';
select is(pg_temp.erro(format('select public.painel_estabelecimento(%L, now(), now())', (select casa from ids)))->>'status', '403',
  'C2 quem não é membro da casa: 403');
set local request.jwt.claims = '{"sub":"b0000000-0000-4000-8000-000000000001","role":"authenticated"}';
select is(pg_temp.erro(format('select public.painel_estabelecimento(%L, null, now())', (select casa from ids)))->>'details', 'de',
  'C3 sem o início da janela: 422 campo_obrigatorio (de)');
reset request.jwt.claims;
select ok(has_function_privilege('authenticated', 'public.painel_estabelecimento(uuid, timestamptz, timestamptz)', 'execute'),
  'C4 authenticated executa');
select ok(not has_function_privilege('anon', 'public.painel_estabelecimento(uuid, timestamptz, timestamptz)', 'execute'),
  'C5 anon não executa');
select ok((select prosecdef and 'search_path=""' = any(proconfig) from pg_proc
            where oid = 'public.painel_estabelecimento(uuid, timestamptz, timestamptz)'::regprocedure),
  'C6 security definer com search_path vazio');

select * from finish();
rollback;
