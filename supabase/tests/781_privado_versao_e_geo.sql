-- 781_privado_versao_e_geo.sql
--
-- Cobertura pgTAP de privado.versao_em_partes(versao text),
-- privado.ponto_do_json(p jsonb, campo text) e privado.ponto_em_json(g extensions.geography),
-- com provas de mutação dinâmica que matam mutantes de SemVer, limites geográficos
-- e conversão PostGIS (RN18, RN22, RF14).
--
-- Regras validadas:
--   1. privado.versao_em_partes:
--      - Converte SemVer (1 a 4 partes numéricas) para int[] permitindo ordenação natural (1.2.10 > 1.2.9).
--      - Retorna NULL para strings inválidas (prefixo 'v', sufixos alfanuméricos, mais de 4 partes, negativos, vazios e NULL).
--   2. privado.ponto_do_json:
--      - Converte coordenadas do contrato JSON (latitude, longitude) para geography PostGIS (SRID 4326).
--      - Rejeita com 422 campo_invalido coordenadas fora dos limites (-90 <= lat <= 90, -180 <= lon <= 180).
--      - Rejeita com 422 campo_obrigatorio entradas nulas ou com atributos faltantes.
--      - Rejeita com 422 campo_invalido valores não numéricos.
--      - Propaga o nome do campo informado no argumento 'campo' para o details do erro.
--   3. privado.ponto_em_json:
--      - Converte geography PostGIS para jsonb formatado com 6 casas decimais.
--      - Retorna NULL sem erro quando a geografia informada é NULL.
--      - Garante round-trip fiel (jsonb -> geography -> jsonb).
--   4. Provas de Mutação Dinâmica via pg_get_functiondef matando mutantes de SemVer e validação geográfica.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(31);

-- ── 1. privado.versao_em_partes: SemVer Válido e Ordenação ────────────────────────
select is(
  privado.versao_em_partes('1.2.3'),
  '{1,2,3}'::int[],
  'versão de 3 partes 1.2.3 é decomposta em array de inteiros'
);

select is(
  privado.versao_em_partes('1.0'),
  '{1,0}'::int[],
  'versão de 2 partes 1.0 é decomposta em array de inteiros'
);

select is(
  privado.versao_em_partes('2'),
  '{2}'::int[],
  'versão de 1 parte 2 é decomposta em array de inteiros'
);

select is(
  privado.versao_em_partes('1.2.10.4'),
  '{1,2,10,4}'::int[],
  'versão de 4 partes 1.2.10.4 é decomposta em array de inteiros'
);

select ok(
  privado.versao_em_partes('1.2.10') > privado.versao_em_partes('1.2.9'),
  'ordenação natural: 1.2.10 é superior a 1.2.9 via comparação de arrays int[]'
);

select ok(
  privado.versao_em_partes('2.0.0') > privado.versao_em_partes('1.9.9'),
  'ordenação natural: major version 2.0.0 é superior a 1.9.9'
);

-- ── 2. privado.versao_em_partes: Formatos Inválidos Retornam NULL ──────────────────
select is(
  privado.versao_em_partes('v1.0.0'),
  null,
  'versão com prefixo "v" retorna NULL'
);

select is(
  privado.versao_em_partes('1.2.beta'),
  null,
  'versão com identificador pré-release alfabético retorna NULL'
);

select is(
  privado.versao_em_partes('1.2.3.4.5'),
  null,
  'versão com 5 partes (acima do limite de 4) retorna NULL'
);

select is(
  privado.versao_em_partes('1..2'),
  null,
  'versão com pontos consecutivos vazios retorna NULL'
);

select is(
  privado.versao_em_partes('-1.2'),
  null,
  'versão com número negativo retorna NULL'
);

select is(
  privado.versao_em_partes(''),
  null,
  'string de versão vazia retorna NULL'
);

select is(
  privado.versao_em_partes(null),
  null,
  'entrada NULL de versão retorna NULL'
);

-- ── 3. privado.ponto_do_json: Coordenada Válida PostGIS ───────────────────────────
select is(
  extensions.ST_Y(privado.ponto_do_json('{"latitude": -15.7942, "longitude": -47.8822}'::jsonb)::extensions.geometry)::numeric,
  -15.7942,
  'latitude do json é convertida com exatidão para ST_Y da geometria PostGIS'
);

select is(
  extensions.ST_X(privado.ponto_do_json('{"latitude": -15.7942, "longitude": -47.8822}'::jsonb)::extensions.geometry)::numeric,
  -47.8822,
  'longitude do json é convertida com exatidão para ST_X da geometria PostGIS'
);

-- ── 4. privado.ponto_do_json: Limites Geográficos Excedidos ───────────────────────
select throws_matching(
  $$ select privado.ponto_do_json('{"latitude": 90.0001, "longitude": -47.8822}'::jsonb) $$,
  'campo_invalido',
  'latitude superior a 90 graus lança 422 campo_invalido'
);

select throws_matching(
  $$ select privado.ponto_do_json('{"latitude": -90.0001, "longitude": -47.8822}'::jsonb) $$,
  'campo_invalido',
  'latitude inferior a -90 graus lança 422 campo_invalido'
);

select throws_matching(
  $$ select privado.ponto_do_json('{"latitude": -15.7942, "longitude": 180.0001}'::jsonb) $$,
  'campo_invalido',
  'longitude superior a 180 graus lança 422 campo_invalido'
);

select throws_matching(
  $$ select privado.ponto_do_json('{"latitude": -15.7942, "longitude": -180.0001}'::jsonb) $$,
  'campo_invalido',
  'longitude inferior a -180 graus lança 422 campo_invalido'
);

-- ── 5. privado.ponto_do_json: Campos Obrigatórios e Malformados ───────────────────
select throws_matching(
  $$ select privado.ponto_do_json(null) $$,
  'campo_obrigatorio',
  'json nulo lança 422 campo_obrigatorio'
);

select throws_matching(
  $$ select privado.ponto_do_json('{}'::jsonb) $$,
  'campo_obrigatorio',
  'objeto json vazio lança 422 campo_obrigatorio'
);

select throws_matching(
  $$ select privado.ponto_do_json('{"latitude": -15.7942}'::jsonb) $$,
  'campo_obrigatorio',
  'objeto sem longitude lança 422 campo_obrigatorio'
);

select throws_matching(
  $$ select privado.ponto_do_json('{"longitude": -47.8822}'::jsonb) $$,
  'campo_obrigatorio',
  'objeto sem latitude lança 422 campo_obrigatorio'
);

select throws_matching(
  $$ select privado.ponto_do_json('{"latitude": "invalido", "longitude": -47.8822}'::jsonb) $$,
  'campo_invalido',
  'valor não numérico na coordenada lança 422 campo_invalido'
);

select throws_matching(
  $$ select privado.ponto_do_json('{"latitude": 100, "longitude": 0}'::jsonb, 'local_evento') $$,
  'local_evento',
  'argumento customizado de campo propaga para details da mensagem de erro'
);

-- ── 6. privado.ponto_em_json: Geography para JSONB e Round-Trip ───────────────────
select is(
  privado.ponto_em_json('SRID=4326;POINT(-47.882212 -15.794234)'::extensions.geography),
  '{"latitude": -15.794234, "longitude": -47.882212}'::jsonb,
  'geography PostGIS é convertido para jsonb com 6 casas decimais'
);

select is(
  privado.ponto_em_json(null),
  null,
  'geography nulo resulta em retorno NULL sem erro de ponto flutuante'
);

select is(
  privado.ponto_em_json(privado.ponto_do_json('{"latitude": -15.794234, "longitude": -47.882212}'::jsonb)),
  '{"latitude": -15.794234, "longitude": -47.882212}'::jsonb,
  'round-trip jsonb -> geography -> jsonb preserva valores das coordenadas'
);

-- ── 7. Provas de Mutação Dinâmica via pg_get_functiondef ─────────────────────────
create temp table canonicos as select
  pg_get_functiondef('privado.versao_em_partes(text)'::regprocedure) as def_versao,
  pg_get_functiondef('privado.ponto_do_json(jsonb,text)'::regprocedure) as def_ponto_do,
  pg_get_functiondef('privado.ponto_em_json(extensions.geography)'::regprocedure) as def_ponto_em;

-- Mutante M1: Regex de versão aceita apenas números inteiros sem ponto
-- Demonstra que sob M1 SemVer padrão '1.2.3' retornaria NULL; morto pelo teste canônico 1.
do $$
begin
  execute replace(
    (select def_versao from canonicos),
    '^[0-9]{1,6}(\.[0-9]{1,6}){0,3}$',
    '^[0-9]+$'
  );
end $$;

select is(
  privado.versao_em_partes('1.2.3'),
  null,
  'mutante M1 (regex sem suporte a pontos): rejeita SemVer 1.2.3 retornando NULL; morto pela suíte'
);

-- Restauração dinâmica de M1
do $$
begin
  execute (select def_versao from canonicos);
end $$;

-- Mutante M2: Omissão de validação de limites de latitude/longitude
-- Demonstra que sob M2 coordenadas ilegais não lançariam 422 campo_invalido via public.erro.
do $$
begin
  execute replace(
    (select def_ponto_do from canonicos),
    'if v_lat < -90 or v_lat > 90 or v_lon < -180 or v_lon > 180 then',
    'if false and (v_lat < -90 or v_lat > 90 or v_lon < -180 or v_lon > 180) then'
  );
end $$;

select lives_ok(
  $$ select privado.ponto_do_json('{"latitude": 90.0001, "longitude": -47.8822}'::jsonb) $$,
  'mutante M2 (sem validação de limites): deixa latitude ilegal passar sem erro 422; morto pelo teste canônico 16'
);

-- Restauração dinâmica de M2
do $$
begin
  execute (select def_ponto_do from canonicos);
end $$;

-- Mutante M3: Omissão de tratamento de NULL em ponto_em_json
-- Demonstra que sob M3 passar geografia NULL falharia ao tentar extrair geometria.
do $$
begin
  execute replace(
    (select def_ponto_em from canonicos),
    'when g is null then null',
    'when false then null'
  );
end $$;

select is(
  privado.ponto_em_json(null),
  '{"latitude": null, "longitude": null}'::jsonb,
  'mutante M3 (sem tratamento de geography null): constrói json com campos nulos em vez de null; morto pela suíte'
);

-- Restauração dinâmica de M3
do $$
begin
  execute (select def_ponto_em from canonicos);
end $$;

select * from finish();

rollback;
