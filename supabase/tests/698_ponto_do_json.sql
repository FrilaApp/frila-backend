-- Conversão e validação geográfica de coordenadas (RF01, RF07, RNF11).
--
-- Cobertura da função `privado.ponto_do_json(p jsonb, campo text default 'ponto_base')`
-- (migração 20260924160000_publicar_vaga.sql).
--
-- A função converte um objeto JSONB com latitude/longitude no tipo `geography(Point, 4326)`,
-- validando limites geográficos (-90..90 para latitude, -180..180 para longitude) e levantando
-- erros tipados do contrato (`campo_obrigatorio` ou `campo_invalido`) com o código SQLSTATE PGRST
-- e o nome do campo repassado em `details` para retorno amigável no app e PostgREST.
--
-- Este teste valida:
--   1. Existência, linguagem e search_path vazio.
--   2. Controle de acesso estrito: sem EXECUTE para anon e authenticated; concedido a service_role.
--   3. Conversão de coordenadas válidas para ponto PostGIS com SRID 4326 (WGS 84).
--   4. Aceite dos valores de fronteira exatos: lat 90 e -90; lon 180 e -180.
--   5. Recusa com código PGRST e mensagem JSON exata de `campo_obrigatorio` para:
--      - JSON nulo
--      - JSON vazio `{}`
--      - latitude ausente
--      - longitude ausente
--   6. Recusa com código PGRST e mensagem JSON exata de `campo_invalido` para:
--      - latitude > 90
--      - latitude < -90
--      - longitude > 180
--      - longitude < -180
--      - latitude não numérica
--      - longitude não numérica
--   7. Propagação correta do parâmetro customizado de `campo` em `details`.

begin;

select plan(22);

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

-- ── 2. Conversão válida e fronteiras aceitas ─────────────────────────────────

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

select is(
  extensions.st_astext(privado.ponto_do_json('{"latitude": 90, "longitude": 180}'::jsonb)),
  'POINT(180 90)',
  'fronteira máxima exata aceita: lat 90 e lon 180'
);

select is(
  extensions.st_astext(privado.ponto_do_json('{"latitude": -90, "longitude": -180}'::jsonb)),
  'POINT(-180 -90)',
  'fronteira mínima exata aceita: lat -90 e lon -180'
);

-- ── 3. Validação de presença obrigatória (campo_obrigatorio) ──────────────────

select throws_ok(
  $$ select privado.ponto_do_json(null) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "ponto_base", "hint" : null}',
  'JSON nulo levanta PGRST campo_obrigatorio com details ponto_base'
);

select throws_ok(
  $$ select privado.ponto_do_json('{}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "ponto_base", "hint" : null}',
  'JSON vazio levanta PGRST campo_obrigatorio'
);

select throws_ok(
  $$ select privado.ponto_do_json('{"longitude": -47.0}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "ponto_base", "hint" : null}',
  'latitude ausente levanta PGRST campo_obrigatorio'
);

select throws_ok(
  $$ select privado.ponto_do_json('{"latitude": -15.0}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "ponto_base", "hint" : null}',
  'longitude ausente levanta PGRST campo_obrigatorio'
);

-- ── 4. Validação de limites e tipos numéricos (campo_invalido) ───────────────

select throws_ok(
  $$ select privado.ponto_do_json('{"latitude": 90.0001, "longitude": -47.0}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "ponto_base", "hint" : null}',
  'latitude > 90 levanta PGRST campo_invalido'
);

select throws_ok(
  $$ select privado.ponto_do_json('{"latitude": -90.0001, "longitude": -47.0}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "ponto_base", "hint" : null}',
  'latitude < -90 levanta PGRST campo_invalido'
);

select throws_ok(
  $$ select privado.ponto_do_json('{"latitude": -15.0, "longitude": 180.0001}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "ponto_base", "hint" : null}',
  'longitude > 180 levanta PGRST campo_invalido'
);

select throws_ok(
  $$ select privado.ponto_do_json('{"latitude": -15.0, "longitude": -180.0001}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "ponto_base", "hint" : null}',
  'longitude < -180 levanta PGRST campo_invalido'
);

select throws_ok(
  $$ select privado.ponto_do_json('{"latitude": "invalido", "longitude": -47.0}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "ponto_base", "hint" : null}',
  'latitude não numérica levanta PGRST campo_invalido'
);

select throws_ok(
  $$ select privado.ponto_do_json('{"latitude": -15.0, "longitude": "nao_num"}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "ponto_base", "hint" : null}',
  'longitude não numérica levanta PGRST campo_invalido'
);

-- ── 5. Propagação de campo customizado em details ────────────────────────────

select throws_ok(
  $$ select privado.ponto_do_json(null, 'localizacao_vaga') $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "localizacao_vaga", "hint" : null}',
  'parâmetro customizado localizacao_vaga é repassado em details (campo_obrigatorio)'
);

select throws_ok(
  $$ select privado.ponto_do_json('{"latitude": 95, "longitude": 0}'::jsonb, 'localizacao_vaga') $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "localizacao_vaga", "hint" : null}',
  'parâmetro customizado localizacao_vaga é repassado em details (campo_invalido)'
);

select * from finish();

rollback;
