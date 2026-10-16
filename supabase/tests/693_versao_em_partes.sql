-- Versão de build e ordem natural para gate de versão mínima do app (S0, RNF01).
--
-- Cobertura exaustiva da função `privado.versao_em_partes(text)`
-- (migração 20260928193700_configuracao_do_app.sql).
--
-- A função converte uma string de versão (números separados por ponto, até 4 partes,
-- com até 6 dígitos por parte) em um array `int[]` permitindo a comparação por ordem
-- natural no PostgreSQL (ex: '1.2.10' > '1.2.9'). Fora do formato, devolve NULL de forma
-- segura sem lançar exceção, delegando as recusas de integridade às restrições CHECK de
-- `privado.configuracao_app`.
--
-- Este teste valida:
--   1. Existência, linguagem SQL, atributo IMMUTABLE e search_path vazio.
--   2. Controle de acesso estrito: sem EXECUTE para anon e authenticated; concedido a service_role.
--   3. Casos válidos: de 1 a 4 partes, incluindo semver canônico (ex: 0.2.43) e zeros à esquerda (ex: 01.2.3 -> {1,2,3}).
--   4. Comparação por ordem natural (ex: 1.2.10 > 1.2.9, 2.0.0 > 1.99.99 e 1.2 < 1.2.0).
--   5. Limites superior (6 dígitos por parte, 4 partes) e inferior (0).
--   6. Casos inválidos retornando NULL com segurança: nulos, strings vazias, prefixos 'v',
--      sufixos de pré-release ('-beta'), mais de 4 partes, mais de 6 dígitos por parte,
--      pontos duplos, pontos nas extremidades (.1.0 e 1.2.) e espaços em branco (' 1.2.3', '1.2.3 ').

begin;

select plan(28);

-- ── 1. Estrutura e controle de acesso ────────────────────────────────────────

select has_function('privado', 'versao_em_partes', array['text'],
  'privado.versao_em_partes(text) existe');

select function_lang_is('privado', 'versao_em_partes', array['text'], 'sql',
  'versao_em_partes é em linguagem sql');

select is(
  (select provolatile from pg_proc where proname = 'versao_em_partes' and pronamespace = 'privado'::regnamespace),
  'i',
  'versao_em_partes é IMMUTABLE (usável em índices e restrições CHECK)'
);

select is(
  (select proconfig from pg_proc where proname = 'versao_em_partes' and pronamespace = 'privado'::regnamespace),
  array['search_path=""'],
  'versao_em_partes tem search_path vazio'
);

select is(has_function_privilege('anon', 'privado.versao_em_partes(text)', 'execute'), false,
  'anon não tem permissão de execução em privado.versao_em_partes');

select is(has_function_privilege('authenticated', 'privado.versao_em_partes(text)', 'execute'), false,
  'authenticated não tem permissão de execução em privado.versao_em_partes');

select is(has_function_privilege('service_role', 'privado.versao_em_partes(text)', 'execute'), true,
  'service_role pode executar privado.versao_em_partes');

-- ── 2. Versões válidas e ordem natural ────────────────────────────────────────

select is(privado.versao_em_partes('1'), array[1],
  '1 parte: 1 converte para {1}');

select is(privado.versao_em_partes('1.0'), array[1, 0],
  '2 partes: 1.0 converte para {1,0}');

select is(privado.versao_em_partes('0.2.43'), array[0, 2, 43],
  '3 partes (semver): 0.2.43 converte para {0,2,43}');

select is(privado.versao_em_partes('1.2.3.4'), array[1, 2, 3, 4],
  '4 partes: 1.2.3.4 converte para {1,2,3,4}');

select is(privado.versao_em_partes('01.2.3'), array[1, 2, 3],
  'zeros à esquerda em partes válidas são absorvidos no cast para int');

select is(
  privado.versao_em_partes('1.2.10') > privado.versao_em_partes('1.2.9'),
  true,
  'ordem natural de array: 1.2.10 é superior a 1.2.9');

select is(
  privado.versao_em_partes('2.0.0') > privado.versao_em_partes('1.99.99'),
  true,
  'ordem natural de array: 2.0.0 é superior a 1.99.99');

select is(
  privado.versao_em_partes('1.2') < privado.versao_em_partes('1.2.0'),
  true,
  'ordem de array: prefixo mais curto {1,2} é menor que {1,2,0}');

-- ── 3. Limites estruturais ───────────────────────────────────────────────────

select is(privado.versao_em_partes('0'), array[0],
  'limite inferior: 0 é aceito');

select is(
  privado.versao_em_partes('999999.999999.999999.999999'),
  array[999999, 999999, 999999, 999999],
  'limites superiores: exatamente 6 dígitos por parte e 4 partes são aceitos'
);

-- ── 4. Versões inválidas (retorno seguro de NULL) ─────────────────────────────

select is(privado.versao_em_partes(null), null,
  'nulo devolve nulo sem estourar exceção');

select is(privado.versao_em_partes(''), null,
  'string vazia devolve nulo');

select is(privado.versao_em_partes('v1.0'), null,
  'prefixo de versão v devolve nulo');

select is(privado.versao_em_partes('1.0-beta'), null,
  'sufixo de pré-release devolve nulo');

select is(privado.versao_em_partes('1.2.3.4.5'), null,
  '5 partes excede o teto de 4 e devolve nulo');

select is(privado.versao_em_partes('1000000'), null,
  '7 dígitos em uma parte excede o teto de 6 e devolve nulo');

select is(privado.versao_em_partes('1..0'), null,
  'ponto consecutivo devolve nulo');

select is(privado.versao_em_partes('.1.0'), null,
  'ponto no início devolve nulo');

select is(privado.versao_em_partes('1.2.'), null,
  'ponto no final devolve nulo');

select is(privado.versao_em_partes(' 1.2.3'), null,
  'espaço no início devolve nulo');

select is(privado.versao_em_partes('1.2.3 '), null,
  'espaço no final devolve nulo');

select * from finish();

rollback;
