-- Limite diário de chamados de suporte por conta (D10, D13, SU-RN06).
--
-- Cobertura da função `privado.limite_de_suporte_por_dia()`
-- (migração 20261008100000_categoria_suporte_e_origem_ocorrencia.sql).
--
-- A função define a constante canônica de chamados que um usuário pode abrir
-- no app por dia no fuso de Brasília antes de ser barrado por 429 limite_excedido.
--
-- Este teste valida:
--   1. Existência, linguagem SQL, atributo IMMUTABLE e search_path vazio.
--   2. Controle de acesso estrito: sem EXECUTE para anon e authenticated; concedido a service_role.
--   3. Retorno do teto de 5 chamados.

begin;

select plan(8);

-- ── 1. Estrutura e controle de acesso ────────────────────────────────────────

select has_function('privado', 'limite_de_suporte_por_dia', array[]::text[],
  'privado.limite_de_suporte_por_dia() existe');

select function_lang_is('privado', 'limite_de_suporte_por_dia', array[]::text[], 'sql',
  'privado.limite_de_suporte_por_dia é em linguagem sql');

select is(
  (select provolatile from pg_proc where proname = 'limite_de_suporte_por_dia' and pronamespace = 'privado'::regnamespace),
  'i',
  'privado.limite_de_suporte_por_dia é IMMUTABLE'
);

select is(
  (select proconfig from pg_proc where proname = 'limite_de_suporte_por_dia' and pronamespace = 'privado'::regnamespace),
  array['search_path=""'],
  'privado.limite_de_suporte_por_dia tem search_path vazio'
);

select is(has_function_privilege('anon', 'privado.limite_de_suporte_por_dia()', 'execute'), false,
  'anon não pode executar privado.limite_de_suporte_por_dia');

select is(has_function_privilege('authenticated', 'privado.limite_de_suporte_por_dia()', 'execute'), false,
  'authenticated não pode executar privado.limite_de_suporte_por_dia');

select is(has_function_privilege('service_role', 'privado.limite_de_suporte_por_dia()', 'execute'), true,
  'service_role pode executar privado.limite_de_suporte_por_dia');

-- ── 2. Valor canônico do limite ──────────────────────────────────────────────

select is(
  privado.limite_de_suporte_por_dia(),
  5,
  'o limite regulamentar de suporte é exatamente 5 chamados/dia (D13)'
);

select * from finish();

rollback;
