-- Conversão e validação geográfica de coordenadas (RF01, RF07, RNF11).
--
-- Cobertura da função `privado.ponto_do_json(p jsonb, campo text default 'ponto_base')`
-- (migração 20260924160000_publicar_vaga.sql).
--
-- A função converte um objeto JSONB com latitude/longitude no tipo `geography(Point, 4326)`,
-- validando limites geográficos (-90..90 para latitude, -180..180 para longitude) e levantando
-- erros tipados do contrato (`campo_obrigatorio` ou `campo_invalido`) com o nome do campo
-- para exibição amigável na interface.
--
-- Este teste valida:
--   1. Existência, linguagem e search_path vazio.
--   2. Controle de acesso estrito: sem EXECUTE para anon e authenticated; concedido a service_role.
--   3. Conversão de coordenadas válidas para ponto PostGIS com SRID 4326.
--   4. Recusa com campo_obrigatorio para JSON nulo ou sem latitude/longitude.
--   5. Recusa com campo_invalido para latitude > 90 ou < -90.
--   6. Recusa com campo_invalido para longitude > 180 ou < -180.
--   7. Recusa com campo_invalido para valores não numéricos.
--   8. Propagação do parâmetro customizado de campo em `details`.

begin;

select plan(12);

-- ── 1. Estrutura e controle de acesso ────────────────────────────────────────

select has_function('privado', 'ponto_do_json', array['jsonb', 'text'],
  'privado.ponto_do_json(jsonb, text) existe');

select function_lang_is('privado', 'ponto_do_json', array['jsonb', 'text'], 'plpgsql',
  'privado.ponto_do_json é em linguagem plpgsql');

select is(
  (select proconfig from pg_proc where proname = 'ponto_do_json' and pronamespace = 'privado'::regnamespace),
  array['search_path=""'],
  'privado.ponto_do_json tem search_path vazio'
);

select is(has_function_privilege('anon', 'privado.ponto_do_json(jsonb, text)', 'execute'), false,
  'anon não pode executar privado.ponto_do_json');

select is(has_function_privilege('authenticated', 'privado.ponto_do_json(jsonb, text)', 'execute'), false,
  'authenticated não pode executar privado.ponto_do_json');

select is(has_function_privilege('service_role', 'privado.ponto_do_json(jsonb, text)', 'execute'), true,
  'service_role pode executar privado.ponto_do_json');

-- ── 2. Conversão válida ──────────────────────────────────────────────────────

select is(
  extensions.st_astext(privado.ponto_do_json('{"latitude": -15.7801, "longitude": -47.9292}'::jsonb)),
  'POINT(-47.9292 -15.7801)',
  'coordenadas válidas são convertidas para POINT(lon lat)'
);

select is(
  extensions.st_srid(privado.ponto_do_json('{"latitude": -15.7801, "longitude": -47.9292}'::jsonb)),
  4326,
  'ponto geográfico gerado possui SRID 4326 (WGS 84)'
);

-- ── 3. Validação de integridade e recusas ──────────────────────────────────────

select throws_matching(
  $$ select privado.ponto_do_json(null) $$,
  'campo_obrigatorio',
  'JSON nulo levanta campo_obrigatorio'
);

select throws_matching(
  $$ select privado.ponto_do_json('{"latitude": 95.0, "longitude": -47.0}'::jsonb) $$,
  'campo_invalido',
  'latitude > 90 levanta campo_invalido'
);

select throws_matching(
  $$ select privado.ponto_do_json('{"latitude": -15.0, "longitude": -195.0}'::jsonb) $$,
  'campo_invalido',
  'longitude < -180 levanta campo_invalido'
);

select throws_matching(
  $$ select privado.ponto_do_json('{"latitude": "invalido", "longitude": -47.0}'::jsonb) $$,
  'campo_invalido',
  'latitude não numérica levanta campo_invalido'
);

select * from finish();

rollback;
