-- O molde das funções e o relógio do produto.
--
-- Uma função `security definer` sem `set search_path = ''` é sequestrável: basta que
-- alguém consiga criar um schema no caminho de busca com uma tabela de mesmo nome, e a
-- função passa a ler os dados do atacante com os privilégios do dono. É o modo de falha
-- clássico do Postgres, e a única defesa que não depende de ninguém lembrar dela é um
-- teste que varre o catálogo.

begin;
select plan(13);

-- ── Toda security definer carrega search_path vazio ────────────────────────────
select is(
  (select coalesce(string_agg(n.nspname || '.' || p.proname, ', ' order by p.proname), '')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','privado')
      and p.prosecdef
      -- O Postgres guarda `set search_path = ''` como a string `search_path=""`.
      -- Qualquer outro valor — inclusive `search_path=public` — reprova.
      and not coalesce(p.proconfig, '{}') @> array['search_path=""']),
  '',
  'nenhuma função security definer sem set search_path = ''''');

select isnt(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.prosecdef),
  0,
  'e existem funções security definer para o teste acima ter o que varrer');

-- O advisor do Supabase reclama de qualquer função sem caminho fixo, não só das
-- `security definer`. Três passaram batidas na primeira rodada e só apareceram quando
-- o advisor rodou contra o frila-dev; este teste traz a checagem para antes do push.
select is(
  (select coalesce(string_agg(n.nspname || '.' || p.proname, ', ' order by p.proname), '')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public','privado')
      and p.prokind = 'f'
      and coalesce(p.proconfig, '{}')::text not like '%search_path%'),
  '',
  'nenhuma função de public ou privado sem search_path fixo');

-- ── A rede de proteção do RLS ─────────────────────────────────────────────────
--
-- Veio do painel do frila-dev e não existia no local. Migração a trouxe para os dois,
-- porque ambiente que responde diferente à mesma migração é o pior lugar para
-- descobrir um erro.
select is(
  (select count(*)::int from pg_event_trigger where evtname = 'ensure_rls'),
  1,
  'o event trigger que liga RLS em tabela nova existe aqui, e não só no painel do frila-dev');

-- ── O schema `privado` fica fora da API ────────────────────────────────────────
--
-- O PostgREST só expõe os schemas de `[api].schemas`. Se `privado` entrasse lá, as
-- auxiliares — que são `security definer` e leem qualquer linha — virariam rotas.
select is(
  (select count(*)::int from information_schema.role_routine_grants
    where routine_schema = 'privado' and grantee in ('anon')),
  0,
  'anon não executa nada do schema privado');

-- ── `public.erro` não é chamável pelo cliente ──────────────────────────────────
--
-- As funções que a usam são security definer e executam como o dono. O cliente não
-- precisa dela, e com acesso podia fabricar códigos de erro que nenhuma regra levantou.
select is(
  (select count(*)::int from information_schema.role_routine_grants
    where routine_schema = 'public' and routine_name = 'erro'
      and grantee in ('anon','authenticated')),
  0,
  'POST /rpc/erro é recusado: nem anon nem authenticated executam');

-- ── O envelope de erro precisa das duas chaves ────────────────────────────────
--
-- O PostgREST recusa o `DETAIL` sem `headers` e devolve `500 PGRST121` no lugar do
-- status que a regra levantou — ou seja, toda recusa de regra de negócio chegaria ao
-- aplicativo como "erro interno". Um teste que só confere o `sqlstate` não pega isso,
-- porque dentro do banco a exceção está certa; quem pega é o `ciclo-completo.sh`,
-- chamando por HTTP. Esta asserção traz o mesmo alarme para dentro da suíte.
select is(
  (select (regexp_match(pg_get_functiondef(p.oid), '''headers''')) is not null
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'erro'),
  true,
  'o envelope de erro monta DETAIL com status e headers, como o PostgREST exige');

-- ── O relógio ──────────────────────────────────────────────────────────────────
--
-- Todo prazo do produto passa por `privado.agora()`: os 7 dias do contato (RN10), o
-- fim previsto que libera a avaliação (RN07), as 24 horas do modo seleção (RN24), os
-- 15 minutos do alerta de atraso, a janela crítica da vaga vazia.

select ok(
  privado.agora() between now() - interval '5 s' and now() + interval '5 s',
  'sem sobreposição, o relógio é o relógio');

-- O marcador é escrito **aqui dentro**, e o rollback o leva junto. Nenhum arquivo do
-- repositório o grava: não há semente listada em `config.toml` para um
-- `supabase db push --include-seed` levar a um ambiente publicado.
select is(
  (select count(*)::int from privado.ambiente),
  0,
  'nenhuma migração e nenhuma semente deixa marcador de teste para trás — é assim que o frila-dev nasce');

-- `privado.ambiente` é tabela de uma linha só, e o `check (id)` sobre a chave booleana
-- é o que garante isso: com `id = false` haveria uma segunda linha, e
-- `exists (select 1 ... where eh_teste)` passaria a depender de qual delas alguém
-- escreveu por último. O relógio do produto ficaria sobreponível conforme a ordem de
-- escrita — que é o pior jeito de um prazo virar decoração.
--
-- Esta asserção entrou em 23/09, quando o verificador de mutação passou a varrer o
-- schema `privado` e mediu que a restrição não tinha nenhuma.
select throws_ok(
  $$ insert into privado.ambiente (id, eh_teste) values (false, true) $$,
  '23514',
  null,
  'privado.ambiente é de uma linha só: id = false é recusado');

insert into privado.ambiente (id, eh_teste) values (true, true);

set local frila.agora = '2026-12-25 03:00:00+00';

select is(
  privado.agora(),
  '2026-12-25 03:00:00+00'::timestamptz,
  'no ambiente de teste, frila.agora sobrepõe o relógio — é o que torna prazo testável');

-- E agora o que realmente importa: o remoto não tem o marcador, e lá a sobreposição
-- tem que ser ignorada mesmo com a variável posta.
update privado.ambiente set eh_teste = false;

select is(
  privado.agora() between now() - interval '5 s' and now() + interval '5 s',
  true,
  'fora do ambiente de teste, frila.agora é ignorado mesmo estando definido');

delete from privado.ambiente;

select is(
  privado.agora() between now() - interval '5 s' and now() + interval '5 s',
  true,
  'e sem linha nenhuma em privado.ambiente — que é o estado do frila-dev e do frila-prod — também');

select * from finish();
rollback;
