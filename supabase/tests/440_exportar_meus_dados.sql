-- Exportar meus dados (cartão nUpPFCpM · US25, RF25, RNF08, RN15, UC16 · LGPD art. 18).
--
-- Dois critérios de backend, e os dois medidos aqui pela forma, não pela leitura:
--
--   1. "O arquivo contém os dados de todas as tabelas com dado do usuário." A seção 5
--      enumera as tabelas pelo **catálogo** — quem tem chave estrangeira para `usuario`,
--      `profissional` ou `estabelecimento` — e compara com a lista do que a exportação
--      cobre mais a lista das exceções declaradas. Tabela nova com dado de pessoa deixa
--      este arquivo vermelho até alguém decidir de que lado ela fica. É a única forma de
--      asserção que não envelhece sozinha.
--
--   2. "Nada fica guardado no servidor depois da resposta." `privado.meus_dados` é
--      `stable`, e função `stable` **não consegue** escrever. A seção 2 mede o rótulo no
--      `pg_proc` e prova o efeito: um `INSERT` dentro dela é recusado pelo Postgres.
--
-- Dados do cenário (`cenarios.sql`): Ana (a…01 / e…01) é profissional com turnos e
-- avaliações; Zélia (b…01) administra o Bar do Cerrado (c…01).

begin;
select plan(32);

select set_config('frila.agora', '2026-09-29 11:00:00-03', true);

create temp table ids as select
  'a0000000-0000-4000-8000-000000000001'::uuid as ana,
  'e0000000-0000-4000-8000-000000000001'::uuid as ana_prof,
  'b0000000-0000-4000-8000-000000000001'::uuid as zelia,
  'c0000000-0000-4000-8000-000000000001'::uuid as bar;

-- ── 1. A função existe e só o service_role a alcança ─────────────────────────

select has_function('privado', 'meus_dados', array['uuid'],
  'privado.meus_dados(uuid) existe');

select is(
  has_function_privilege('authenticated', 'privado.meus_dados(uuid)', 'execute'),
  false,
  'privado.meus_dados não é alcançável pelo app: quem chama é a Edge Function');

select is(
  has_function_privilege('anon', 'privado.meus_dados(uuid)', 'execute'),
  false,
  'nem por anon');

select is(
  has_function_privilege('service_role', 'privado.meus_dados(uuid)', 'execute'),
  true,
  'o service_role a alcança');

-- ── 2. O critério 2, medido: a função não consegue escrever ──────────────────

select is(
  (select p.provolatile from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'meus_dados'),
  's'::"char",
  'privado.meus_dados é stable — e função stable não consegue escrever (critério 2)');

-- O rótulo não é decoração: o Postgres recusa a escrita. Esta asserção prova o efeito,
-- e não só a declaração.
create function pg_temp.tenta_escrever() returns void
language sql stable as $$
  insert into public.ocorrencia (tipo, autor_id, motivo)
  values ('suporte', 'a0000000-0000-4000-8000-000000000001', 'teste')
$$;

select throws_ok(
  $$ select pg_temp.tenta_escrever() $$,
  '0A000',
  null,
  'o Postgres recusa INSERT dentro de função stable: a promessa é estrutural');

-- Nenhuma tabela nova guarda o pedido de exportação: não há onde o dado ficar em repouso.
select is(
  (select count(*)::int from pg_tables
    where schemaname in ('public','privado')
      and tablename ~ '(exportacao|exportar|meus_dados|download)'),
  0,
  'não existe tabela de pedidos de exportação: o corpo da resposta morre com a conexão');

-- ── 3. O corpo casa com o schema MeusDados do contrato ───────────────────────

create temp table d as select privado.meus_dados((select ana from ids)) as j;

select is(
  (select string_agg(k, ',' order by k) from jsonb_object_keys((select j from d)) k),
  'avaliacoes_dadas,avaliacoes_recebidas,conta,disponibilidade,dispositivos,estabelecimentos,gerado_em,perfil_profissional,turnos',
  'o corpo tem exatamente as nove chaves de MeusDados, e nenhuma a mais');

select is(
  (select string_agg(k, ',' order by k) from jsonb_object_keys((select j->'conta' from d)) k),
  'email,estado,id,nascimento,nome,perfil,telefone',
  'conta traz exatamente os sete campos de Usuario — sem termos_aceite, sem criado_em');

select is(
  (select j->'conta'->>'id' from d),
  (select ana::text from ids),
  'a conta devolvida é a de quem pediu');

select is(
  (select (j->>'gerado_em')::timestamptz from d),
  privado.agora(),
  'gerado_em sai do relógio do produto, e não de now()');

select is(
  (select jsonb_typeof(j->'turnos') from d), 'array',
  'turnos é array');

select is(
  (select jsonb_typeof(j->'avaliacoes_dadas') from d), 'array',
  'avaliacoes_dadas é array');

select is(
  (select jsonb_typeof(j->'avaliacoes_recebidas') from d), 'array',
  'avaliacoes_recebidas é array');

select is(
  (select jsonb_typeof(j->'dispositivos') from d), 'array',
  'dispositivos é array');

select is(
  (select jsonb_typeof(j->'estabelecimentos') from d), 'array',
  'estabelecimentos é array');

select is(
  (select jsonb_typeof(j->'disponibilidade') from d), 'array',
  'disponibilidade é array');

select is(
  (select jsonb_typeof(j->'perfil_profissional') from d), 'object',
  'a conta de profissional traz perfil_profissional');

-- ── 4. O que o corpo NÃO leva (RN07, RN15) ───────────────────────────────────

select is(
  (select count(*)::int from jsonb_array_elements((select j->'avaliacoes_recebidas' from d)) a
    where a.value ? 'autor_id' or a.value ? 'autor'),
  0,
  'avaliações recebidas saem SEM o autor: a portabilidade não fura a RN07');

select is(
  (select bool_and(
            (select string_agg(k, ',' order by k) from jsonb_object_keys(a.value) k)
            = 'criada_em,resposta,turno_id')
     from jsonb_array_elements((select j->'avaliacoes_recebidas' from d)) a),
  true,
  'e trazem exatamente turno_id, resposta e criada_em');

-- O aparelho é fixture deste arquivo, e não sorte do cenário: sem ele, as duas
-- asserções do token passariam sobre um array vazio, que é o jeito mais convincente de
-- um teste de RN15 não medir nada.
insert into public.dispositivo (usuario_id, token_fcm, plataforma)
values ((select ana from ids), 'token-de-teste-do-440-nao-pode-vazar', 'ios');

create temp table d2 as select privado.meus_dados((select ana from ids)) as j;

select cmp_ok(
  (select jsonb_array_length(j->'dispositivos') from d2), '>=', 1,
  'o aparelho da fixture entra em dispositivos: a asserção abaixo tem o que medir');

select is(
  (select count(*)::int from jsonb_array_elements((select j->'dispositivos' from d2)) x
    where x.value ? 'token_fcm'),
  0,
  'o token de push não entra na exportação: é credencial de entrega, não dado do titular');

select is(
  (select (j::text like '%token-de-teste-do-440-nao-pode-vazar%') from d2),
  false,
  'e o token não aparece em lugar nenhum do corpo, em nenhuma profundidade (RN15)');

select is(
  (select string_agg(k, ',' order by k)
     from jsonb_array_elements((select j->'dispositivos' from d2)) x,
          jsonb_object_keys(x.value) k
    where x.value->>'token_fcm' is null
   ),
  (select string_agg(x, ',' order by x)
     from (select unnest(array['atualizado_em','plataforma']) x
             from jsonb_array_elements((select j->'dispositivos' from d2))) y),
  'cada aparelho traz só plataforma e atualizado_em, como Dispositivo declara');

-- ── 5. Critério 1: as tabelas com dado do usuário ────────────────────────────
--
-- O catálogo aqui é **toda** tabela de `public`, e não só as que têm chave estrangeira
-- para `usuario`. A primeira versão deste teste derivava a lista pelas chaves, e ela
-- perdeu `turno` e `estabelecimento` — `turno` guarda o instante e a distância do
-- check-in de uma pessoa e não aponta para `usuario` em coluna nenhuma. Uma regra que
-- decide "isto é dado de pessoa" por chave estrangeira erra exatamente nas tabelas do
-- meio do caminho.
--
-- Com toda tabela no catálogo, o padrão vira o seguro: tabela nova não pertence a
-- categoria nenhuma até alguém escrevê-la numa das três listas, e até lá este arquivo
-- fica vermelho.
--
--   `cobertas`     · a exportação devolve, e onde
--   `fora`         · guarda dado do titular e `MeusDados` não tem lugar para ela
--   `nao_pessoais` · não guarda dado de pessoa nenhuma

create temp table cobertas (t text, onde text);
insert into cobertas values
  ('usuario',                'conta'),
  ('profissional',           'perfil_profissional'),
  ('profissional_funcao',    'perfil_profissional.funcoes'),
  ('disponibilidade',        'disponibilidade e perfil_profissional.disponibilidades'),
  ('dispositivo',            'dispositivos, sem o token'),
  ('membro_estabelecimento', 'estabelecimentos'),
  ('estabelecimento',        'estabelecimentos'),
  ('turno',                  'turnos'),
  ('posicao',                'turnos, dentro de cada turno'),
  ('vaga',                   'turnos, em turno.vaga'),
  ('avaliacao',              'avaliacoes_dadas e avaliacoes_recebidas');

create temp table fora (t text, motivo text);
insert into fora values
  ('candidatura',          'MeusDados não declara candidaturas — divergência registrada no cartão nUpPFCpM'),
  ('ocorrencia',           'MeusDados não declara denúncias e contestações abertas pelo titular'),
  ('bloqueio',             'MeusDados não declara quem o titular bloqueou'),
  ('notificacao',          'MeusDados não declara o histórico de avisos'),
  ('despacho',             'MeusDados não declara as ofertas recebidas'),
  ('equipe_confianca',     'MeusDados não declara a equipe de confiança'),
  ('evento',               'agenda da casa, e não do titular'),
  ('entrada_demonstracao', 'conta de revisão da App Store: não há titular de dado pessoal aqui'),
  ('pedido_de_exclusao',   'MeusDados não declara o pedido de exclusão do próprio titular — o schema do contrato 0.2.26 tem nove campos e nenhum para ele (SHUDSozj)');

create temp table nao_pessoais (t text, motivo text);
insert into nao_pessoais values
  ('funcao', 'catálogo de funções do setor, igual para todo mundo');

create temp table catalogo as
  select tablename::text as t from pg_tables where schemaname = 'public';

select is(
  (select string_agg(t, ',' order by t) from catalogo
    where t not in (select t from cobertas)
      and t not in (select t from fora)
      and t not in (select t from nao_pessoais)),
  null,
  'toda tabela de public está coberta, declarada como exceção ou declarada como impessoal (critério 1)');

select is(
  (select string_agg(t, ',' order by t)
     from (select t from cobertas union all select t from fora
           union all select t from nao_pessoais) x
    where t not in (select t from catalogo)),
  null,
  'e nenhuma das três listas cita tabela que não existe mais');

-- A divergência que este cartão não resolve, escrita para não sumir: são seis tabelas
-- com dado do titular que o contrato não declara. Mudar isso é mudar o contrato primeiro.
select is(
  (select string_agg(t, ',' order by t) from fora
    where t in ('candidatura','ocorrencia','bloqueio','notificacao','despacho','equipe_confianca')),
  'bloqueio,candidatura,despacho,equipe_confianca,notificacao,ocorrencia',
  'seis tabelas com dado do titular ficam de fora porque MeusDados não as declara');

-- ── 6. A conta de contratante, e a que não existe ────────────────────────────

create temp table z as select privado.meus_dados((select zelia from ids)) as j;

select is(
  (select jsonb_typeof(j->'perfil_profissional') from z), 'null',
  'conta de contratante traz perfil_profissional nulo, como o contrato declara');

select cmp_ok(
  (select jsonb_array_length(j->'estabelecimentos') from z), '>=', 1,
  'e traz a casa de que ela é membro');

select is(
  (select j->'estabelecimentos'->0->>'papel' from z), 'administrador',
  'com o papel dela na casa');

select is(
  (select jsonb_typeof(j->'disponibilidade') from z), 'array',
  'e a disponibilidade vazia é array, não null: o cliente gerado não quebra');

select is(
  privado.meus_dados('a0000000-0000-4000-8000-0000000000ff'::uuid),
  null,
  'conta que não existe devolve null, e a Edge Function responde 404');

select * from finish();
rollback;
