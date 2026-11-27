-- 921_meus_dados_motivo_da_ocorrencia.sql
--
-- v4bWGhC9 (LGPD): `privado.meus_dados` (exportação dos dados do titular) só devolve o `motivo` de uma ocorrência quando o titular é o AUTOR dela ou
-- quando ela é uma SUSPENSÃO (`case when o.autor_id = p_usuario or o.tipo = 'suspensao' then o.motivo else null end`). Em qualquer outra, o alvo
-- vê a ocorrência (papel `alvo`) mas não o texto. O 440 só confere `resultado` e `papel`: trocar o `case` por `o.motivo` não deixava nada
-- vermelho, e o denunciado leria pela exportação o texto de quem o denunciou.
--   A  o ALVO de uma denúncia: a ocorrência aparece com papel `alvo` e `motivo` nulo; o texto do denunciante não está em NENHUM ponto do corpo
--   B  o AUTOR da denúncia: papel `autor` e `motivo` preenchido
--   C  uma SUSPENSÃO: o alvo lê o motivo
--   D  o titular lê o motivo de uma ocorrência que ele mesmo abriu (suporte)
-- Ids próprios (`c9210000`). Só dados sintéticos.
begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-20 12:00:00+00', true);

select plan(19);

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, privado.agora(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
          privado.agora(), privado.agora(), false, false)
  on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

-- D: denunciante. A: denunciado (alvo). E: quem registra a suspensão.
select pg_temp.autenticar('c9210000-0000-4000-8000-000000000001', 'denunciante921@t.test');
select pg_temp.autenticar('c9210000-0000-4000-8000-000000000002', 'denunciado921@t.test');
select pg_temp.autenticar('c9210000-0000-4000-8000-000000000003', 'equipe921@t.test');
select pg_temp.como('c9210000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante','Denunciante 921','+5561955559211','1980-01-01','2026-09-22') $$);
select pg_temp.como('c9210000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('contratante','Denunciado 921','+5561955559212','1980-01-01','2026-09-22') $$);
select pg_temp.como('c9210000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('contratante','Equipe 921','+5561955559213','1980-01-01','2026-09-22') $$);

-- Os textos têm marcas fáceis de procurar no corpo inteiro.
insert into public.ocorrencia (id, tipo, autor_id, usuario_id, motivo, criada_em) values
  ('c9210000-0000-4000-8000-0000000000d1', 'denuncia',  'c9210000-0000-4000-8000-000000000001', 'c9210000-0000-4000-8000-000000000002',
   'SIGILO-921: o denunciado nao pode ler isto', '2026-11-10 10:00:00+00'),
  ('c9210000-0000-4000-8000-0000000000d2', 'suspensao', 'c9210000-0000-4000-8000-000000000003', 'c9210000-0000-4000-8000-000000000002',
   'SUSPENSAO-921: motivo que o titular le', '2026-11-11 10:00:00+00'),
  ('c9210000-0000-4000-8000-0000000000d3', 'suporte',   'c9210000-0000-4000-8000-000000000002', null,
   'SUPORTE-921: aberto pelo proprio titular', '2026-11-12 10:00:00+00'),
  -- Outros tipos em que o titular é só o ALVO: hoje só a suspensão mostra o motivo, e a regra é a de esconder os demais.
  ('c9210000-0000-4000-8000-0000000000d4', 'revisao_despacho', 'c9210000-0000-4000-8000-000000000001', 'c9210000-0000-4000-8000-000000000002',
   'REVISAO-921: texto de outra pessoa', '2026-11-13 10:00:00+00'),
  ('c9210000-0000-4000-8000-0000000000d5', 'cancelamento', 'c9210000-0000-4000-8000-000000000001', 'c9210000-0000-4000-8000-000000000002',
   'CANCELAMENTO-921: texto de outra pessoa', '2026-11-14 10:00:00+00');

create temp table alvo as select privado.meus_dados('c9210000-0000-4000-8000-000000000002') as j;
create temp table autor as select privado.meus_dados('c9210000-0000-4000-8000-000000000001') as j;

create function pg_temp.oc(corpo jsonb, id uuid) returns jsonb language sql as $$
  select o.value from jsonb_array_elements(corpo->'ocorrencias') o where (o.value->>'id')::uuid = id
$$;

select is((select jsonb_array_length(j->'ocorrencias') from alvo), 5, '0 o titular exporta as cinco ocorrências em que aparece');
select is((select jsonb_array_length(j->'ocorrencias') from autor), 3, '0b o denunciante exporta as três que ele abriu (denúncia, revisão e cancelamento)');

-- ── A. O alvo de uma denúncia ─────────────────────────────────────────────────

select is((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d1'::uuid))->>'papel', 'alvo', 'A1 a denúncia aparece para o denunciado, com papel alvo');
select is((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d1'::uuid))->>'tipo', 'denuncia', 'A2 e com o tipo');
select ok((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d1'::uuid)) ? 'motivo', 'A3 a chave motivo existe no objeto (o contrato não muda de forma)');
select is(jsonb_typeof((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d1'::uuid))->'motivo'), 'null', 'A4 o motivo da denúncia é nulo para o denunciado');
select is(position('SIGILO-921' in (select j::text from alvo)), 0, 'A5 o texto do denunciante não aparece em nenhum ponto da exportação do denunciado');

-- Os outros tipos em que o titular é só o alvo também não mostram o texto de quem os abriu.
select is(jsonb_typeof((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d4'::uuid))->'motivo'), 'null', 'A6 revisao_despacho: motivo nulo para o alvo');
select is(jsonb_typeof((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d5'::uuid))->'motivo'), 'null', 'A7 cancelamento: motivo nulo para o alvo');
select is((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d4'::uuid))->>'papel', 'alvo', 'A8 e eles aparecem com papel alvo');
select is(position('REVISAO-921' in (select j::text from alvo)) + position('CANCELAMENTO-921' in (select j::text from alvo)), 0, 'A9 nenhum desses textos está na exportação do alvo');

-- ── B. O autor da denúncia ────────────────────────────────────────────────────

select is((pg_temp.oc((select j from autor), 'c9210000-0000-4000-8000-0000000000d1'::uuid))->>'papel', 'autor', 'B1 para o denunciante o papel é autor');
select is((pg_temp.oc((select j from autor), 'c9210000-0000-4000-8000-0000000000d1'::uuid))->>'motivo', 'SIGILO-921: o denunciado nao pode ler isto',
  'B2 e o motivo está preenchido: ele lê o que escreveu');

-- ── C. Uma suspensão ──────────────────────────────────────────────────────────

select is((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d2'::uuid))->>'papel', 'alvo', 'C1 a suspensão aparece com papel alvo');
select is((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d2'::uuid))->>'motivo', 'SUSPENSAO-921: motivo que o titular le',
  'C2 e o motivo da suspensão é preenchido para o suspenso');

-- ── D. Ocorrência aberta pelo próprio titular ─────────────────────────────────

select is((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d3'::uuid))->>'papel', 'autor', 'D1 a ocorrência que ele abriu tem papel autor');
select is((pg_temp.oc((select j from alvo), 'c9210000-0000-4000-8000-0000000000d3'::uuid))->>'motivo', 'SUPORTE-921: aberto pelo proprio titular',
  'D2 e o motivo é o que ele escreveu');

-- ── E. A exportação de quem não é parte nenhuma ───────────────────────────────

select is((select jsonb_array_length(privado.meus_dados('c9210000-0000-4000-8000-000000000003')->'ocorrencias')), 1,
  'E1 a equipe só vê a suspensão que registrou (como autora)');
select is(position('SIGILO-921' in privado.meus_dados('c9210000-0000-4000-8000-000000000003')::text), 0, 'E2 e o texto da denúncia não está na exportação dela');

select * from finish();
rollback;
