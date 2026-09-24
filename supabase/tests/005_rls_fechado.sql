-- O RLS está ligado e a escrita direta está fechada.
--
-- Este arquivo existe por causa de um achado de revisão, e o achado foi medido, não
-- deduzido: com as concessões padrão do Supabase, `anon` — a role da chave publicável,
-- que vai dentro do app — tinha INSERT, UPDATE e DELETE nas dezenove tabelas, e
-- `insert into public.usuario (…)` devolvia `INSERT 0 1`.
--
-- Um teste que só olha a existência de política não pega isso. Estes tentam escrever.

begin;
select plan(13);

-- Executa `sql` com a identidade de `papel`. Se levantar, a subtransação do throws_ok
-- desfaz o SET LOCAL junto com o resto.
create function pg_temp.como(papel text, sql text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
end $$;

-- ── As tabelas com RLS ligado ──────────────────────────────────────────────────
--
-- Dezenove são as da Modelagem. A vigésima é `entrada_demonstracao`, que não é tabela
-- do produto: é o registro de tentativas da porta de demonstração, escrito só pela
-- Edge Function com a chave `service_role`. Ela entra nesta contagem de propósito — o
-- que este teste protege é "nenhuma tabela de `public` sem RLS", e abrir exceção por
-- nome seria o começo da lista de exceções.
select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity),
  20,
  'as 19 tabelas do produto e o registro da demonstração têm Row Level Security ligado');

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  0,
  'nenhuma tabela do schema public ficou sem RLS');

-- ── `anon` não escreve, e não lê ───────────────────────────────────────────────
select is(
  (select count(distinct table_name)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'
      and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE')),
  0,
  'anon não tem concessão de escrita em nenhuma tabela');

select throws_ok(
  $$ select pg_temp.como('anon', $x$
       insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
       values (gen_random_uuid(), 'profissional', 'Invasor',
               '+5561999990000', 'x@y.test', '1990-01-01', '2026-09-22', now()) $x$) $$,
  '42501',
  null,
  'a chave publicável do app não cria conta direto na tabela');

select throws_ok(
  $$ select pg_temp.como('anon', $x$
       update public.funcao set nome = 'qualquer coisa' $x$) $$,
  '42501',
  null,
  'a chave publicável não altera o catálogo');

select throws_ok(
  $$ select pg_temp.como('anon', $x$ delete from public.funcao $x$) $$,
  '42501',
  null,
  'a chave publicável não apaga nada');

-- Controle: o auxiliar não engole tudo. Se ele estivesse quebrado, os três throws_ok
-- acima passariam por acidente e o teste inteiro seria teatro.
select lives_ok(
  $$ select pg_temp.como('anon', $x$ select 1 $x$) $$,
  'o auxiliar de identidade executa o que é permitido — os erros acima são de permissão, não de sintaxe');

-- ── `authenticated` lê pelas políticas, mas nunca escreve direto ───────────────
--
-- Frase 1 da Modelagem: nenhuma tabela tem política de insert, update ou delete para
-- authenticated. Toda escrita passa por função `security definer`.
select is(
  (select count(distinct table_name)::int from information_schema.role_table_grants
    where grantee = 'authenticated' and table_schema = 'public'
      and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE')),
  0,
  'authenticated não tem concessão de escrita em nenhuma tabela');

select throws_ok(
  $$ select pg_temp.como('authenticated', $x$
       insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local,
                                ponto, valor_centavos, posicoes, inclui_refeicao,
                                inclui_transporte, exige_material_proprio,
                                responsavel_local, modo, chave_cliente)
       values (gen_random_uuid(), gen_random_uuid(), now(), now() + interval '8 h', 'x',
               'POINT(0 0)'::extensions.geography, 1, 1, true, false, false, 'z',
               'urgencia', gen_random_uuid()) $x$) $$,
  '42501',
  null,
  'nem o usuário logado publica vaga escrevendo na tabela: isso é trabalho da RPC');

-- ── O registro da porta de demonstração é fechado nos dois sentidos ────────────
--
-- `public.entrada_demonstracao` guarda as tentativas contra o código fixo da revisão da
-- App Store. Ela mora em `public` porque quem escreve é a Edge Function pela chave
-- `service_role`, e o PostgREST só alcança `public` — mas nenhuma chave que vai dentro
-- do app pode ler nem escrever nela. Ler seria entregar quantas tentativas faltam para
-- o teto; escrever seria zerar o teto.
select throws_ok(
  $$ select pg_temp.como('anon', $x$
       select count(*) from public.entrada_demonstracao $x$) $$,
  '42501',
  null,
  'a chave publicável não lê o registro de entrada da demonstração');

select throws_ok(
  $$ select pg_temp.como('authenticated', $x$
       insert into public.entrada_demonstracao (email, aceita)
       values ('invasor@x.test', true) $x$) $$,
  '42501',
  null,
  'nem o usuário logado escreve no registro para afogar o teto de tentativas');

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and tablename = 'entrada_demonstracao'),
  0,
  'e a tabela não tem política nenhuma: o acesso é só da service_role, que passa por cima da RLS');

select is(
  (select relrowsecurity from pg_class where oid = 'public.entrada_demonstracao'::regclass),
  true,
  'com a RLS ligada — sem ela, zero política significaria porta aberta e não porta fechada');

select * from finish();
rollback;
