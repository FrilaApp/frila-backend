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
select plan(53);

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
  'avaliacoes_dadas,avaliacoes_recebidas,bloqueios,candidaturas,conta,despachos,disponibilidade,dispositivos,equipe_confianca,estabelecimentos,gerado_em,notificacoes,ocorrencias,pedido_de_exclusao,perfil_profissional,turnos',
  'o corpo tem exatamente as dezesseis chaves de MeusDados, e nenhuma a mais');

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
  ('avaliacao',              'avaliacoes_dadas e avaliacoes_recebidas'),
  ('candidatura',            'candidaturas'),
  ('ocorrencia',             'ocorrencias, com papel e sem resultado'),
  ('bloqueio',               'bloqueios, só os que o titular criou (RF26)'),
  ('notificacao',            'notificacoes, sem tentativas nem erro do provedor'),
  ('despacho',               'despachos'),
  ('equipe_confianca',       'equipe_confianca, só o lado do profissional'),
  ('pedido_de_exclusao',     'pedido_de_exclusao, ou null');

create temp table fora (t text, motivo text);
insert into fora values
  ('evento',               'agenda da casa, e não do titular'),
  ('entrada_demonstracao', 'conta de revisão da App Store: não há titular de dado pessoal aqui'),
  ('evento_app',           'MeusDados não declara eventos de telemetria do app (cartão 3zsjXW60)');

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

-- Aqui havia uma asserção que fixava a divergência: seis tabelas com dado do titular que
-- o contrato não declarava. O cartão IrtkCWDz a resolveu, as sete entraram em `cobertas`, e
-- a asserção foi removida em vez de relaxada — uma asserção que afirma uma falta é para
-- morrer quando a falta acaba. O que sobra no lugar é a garantia inversa: nenhuma tabela
-- com dado do titular pode voltar a aparecer em `fora` sem alguém reescrever este bloco.
select is(
  (select string_agg(t, ',' order by t) from fora),
  'entrada_demonstracao,evento,evento_app',
  'só três tabelas ficam de fora, e nenhuma delas guarda dado do titular');

-- ── 5b. As sete coleções do contrato 0.2.27 ──────────────────────────────────
-- Uma asserção por campo, e cada uma também cobra o que o campo NÃO leva. Sem a segunda
-- metade, uma revisão futura "completaria" o JSON com `resultado`, com os bloqueios
-- recebidos ou com o token do aparelho, e nenhum teste reclamaria.

select ok((select j ? 'candidaturas' from d),
  'candidaturas está no corpo');
select ok((select jsonb_typeof(j->'candidaturas') = 'array' from d),
  'candidaturas é array, inclusive quando vazio');

-- O objeto é o `Candidatura` do contrato: `vaga` é um VagaResumo, e nada de chaves achatadas.
select ok(
  (select not exists (
     select 1 from jsonb_array_elements(j->'candidaturas') c
      where not (c.value ? 'vaga') or c.value ? 'posicao_id' or c.value ? 'vaga_id')
     from d),
  'toda candidatura traz vaga (VagaResumo), sem posicao_id nem vaga_id achatados');

select ok((select j ? 'ocorrencias' from d),
  'ocorrencias está no corpo');
-- `resultado` é a decisão interna do suporte, e não dado do titular. Em nenhuma ocorrência.
select ok(
  (select not exists (
     select 1 from jsonb_array_elements(j->'ocorrencias') o where o.value ? 'resultado')
     from d),
  'RN07: nenhuma ocorrência leva resultado');
-- Toda ocorrência diz de que lado o titular está.
select ok(
  (select not exists (
     select 1 from jsonb_array_elements(j->'ocorrencias') o
      where (o.value->>'papel') is distinct from 'autor'
        and (o.value->>'papel') is distinct from 'alvo')
     from d),
  'toda ocorrência traz papel, e ele é autor ou alvo');

select ok((select j ? 'bloqueios' from d),
  'bloqueios está no corpo');
-- RF26: o bloqueio é invisível para o bloqueado. Nenhum bloqueio em que o titular seja o
-- bloqueado pode aparecer, em nenhuma profundidade do corpo.
select ok(
  (select not exists (
     select 1 from jsonb_array_elements(j->'bloqueios') b where b.value ? 'bloqueado_id')
     from d),
  'RN10: nenhum bloqueio leva bloqueado_id — o schema Bloqueio devolve o par, nunca o id de conta');
select ok(
  (select not exists (
     select 1 from jsonb_array_elements(j->'bloqueios') b
      where (b.value->>'alvo_tipo') is distinct from 'profissional'
        and (b.value->>'alvo_tipo') is distinct from 'estabelecimento')
     from d),
  'todo bloqueio traz alvo_tipo, e ele é profissional ou estabelecimento');
select ok(
  (select not exists (
     select 1 from jsonb_array_elements(j->'bloqueios') b
      where (b.value->>'alvo_id')::uuid in (select u.id from public.usuario u))
     from d),
  'RN10: nenhum alvo_id é id de conta — é id de profissional ou de estabelecimento');
select ok(
  (select (j #>> '{}') not like '%' || (
     select b.autor_id::text from public.bloqueio b
      where b.bloqueado_id = (select ana from ids) limit 1) || '%'
     from d)
  or (select not exists (select 1 from public.bloqueio b
                          where b.bloqueado_id = (select ana from ids))),
  'RF26: quem bloqueou o titular não aparece em nenhuma profundidade do corpo');

select ok((select j ? 'notificacoes' from d),
  'notificacoes está no corpo');
-- RN15: o diário de bordo do provedor de push não é dado do titular.
select ok(
  (select not exists (
     select 1 from jsonb_array_elements(j->'notificacoes') n
      where n.value ? 'tentativas' or n.value ? 'motivo_falha'
         or n.value ? 'proxima_tentativa_em' or n.value ? 'esperou_teto')
     from d),
  'RN15: nenhuma notificação leva tentativas, motivo_falha, proxima_tentativa_em nem esperou_teto');

select ok((select j ? 'despachos' from d),
  'despachos está no corpo');
select ok(
  (select not exists (
     select 1 from jsonb_array_elements(j->'despachos') ds where ds.value ? 'notificacao_id')
     from d),
  'despachos não leva notificacao_id, que é ligação interna');

select ok((select j ? 'equipe_confianca' from d),
  'equipe_confianca está no corpo');
select ok(
  (select not exists (
     select 1 from jsonb_array_elements(j->'equipe_confianca') e
      where not (e.value ? 'nome') or not (e.value ? 'estabelecimento_id') or not (e.value ? 'adicionado_em'))
     from d),
  'toda entrada de equipe_confianca traz estabelecimento_id, nome e adicionado_em');

select ok((select j ? 'pedido_de_exclusao' from d),
  'pedido_de_exclusao está no corpo');
-- `null` quando não há pedido, e não objeto vazio nem ausência da chave.
select ok(
  (select jsonb_typeof(j->'pedido_de_exclusao') in ('null','object') from d),
  'pedido_de_exclusao é objeto ou null, nunca ausente');
select ok(
  (select jsonb_typeof(j->'pedido_de_exclusao') = 'null' or (j->'pedido_de_exclusao') ? 'tentativas'
     from d),
  'pedido_de_exclusao, quando existe, traz tentativas');

-- ── 5c. O lado do profissional na equipe de confiança ────────────────────────
-- A equipe das casas que o titular administra é dado dos profissionais dela. Com a Zélia,
-- que é contratante e administra o bar, a coleção tem de sair vazia.
create temp table zec as select privado.meus_dados((select zelia from ids)) as j;
select is(
  (select jsonb_array_length(j->'equipe_confianca') from zec),
  0,
  'a equipe das casas que o titular administra não entra em equipe_confianca');

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
