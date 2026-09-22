-- O RLS está ligado e a escrita direta está fechada.
--
-- Este arquivo existe por causa de um achado de revisão, e o achado foi medido, não
-- deduzido: com as concessões padrão do Supabase, `anon` — a role da chave publicável,
-- que vai dentro do app — tinha INSERT, UPDATE e DELETE nas dezenove tabelas, e
-- `insert into public.usuario (…)` devolvia `INSERT 0 1`.
--
-- Um teste que só olha a existência de política não pega isso. Estes tentam escrever.

begin;
select plan(9);

-- Executa `sql` com a identidade de `papel`. Se levantar, a subtransação do throws_ok
-- desfaz o SET LOCAL junto com o resto.
create function pg_temp.como(papel text, sql text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
end $$;

-- ── As dezenove tabelas com RLS ligado ─────────────────────────────────────────
select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity),
  19,
  'as 19 tabelas do produto têm Row Level Security ligado');

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
       insert into public.usuario (id, perfil, nome, telefone, email, nascimento)
       values (gen_random_uuid(), 'profissional', 'Invasor',
               '+5561999990000', 'x@y.test', '1990-01-01') $x$) $$,
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

select * from finish();
rollback;
