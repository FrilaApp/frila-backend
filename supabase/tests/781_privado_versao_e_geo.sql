-- 781_privado_versao_e_geo.sql
--
-- Cobertura pgTAP de privado.versao_em_partes(versao text),
-- privado.ponto_do_json(p jsonb, campo text) e privado.ponto_em_json(g extensions.geography),
-- com provas de mutação dinâmica que matam mutantes de SemVer, limites geográficos,
-- status HTTP 422 e arredondamento PostGIS (RN18, RN22, RF14).
--
-- Defeito preexistente identificado na revisão R-002 (Lince), preservado sem alteração de código:
--   1. JSON null em coordenada ('{"latitude": null, "longitude": 0}'):
--      A guarda em 20260924160000:90 verifica 'p->''latitude'' is null'. Em JSONB do Postgres,
--      um campo com valor JSON null resulta no literal 'null'::jsonb (que não é SQL NULL).
--      O valor atravessa a guarda sem levantar erro 422 e ao ser extraído via '->>' vira SQL NULL.
--      A construção do ponto ST_Point(NULL, ...) devolve SQL NULL em vez de lançar
--      422 campo_obrigatorio/campo_invalido como requerido pelo contrato (openapi.yaml:3825).
--      Encaminhado para correção de função em cartão e migração separados.
--
-- Regras validadas:
--   1. privado.versao_em_partes:
--      - Converte SemVer (1 a 4 partes numéricas) para int[] permitindo ordenação natural (1.2.10 > 1.2.9).
--      - Retorna NULL para strings inválidas (prefixo 'v', sufixos alfanuméricos, mais de 4 partes, negativos, vazios e NULL).
--   2. privado.ponto_do_json:
--      - Converte coordenadas do contrato JSON (latitude, longitude) para geography PostGIS (SRID 4326).
--      - Rejeita com status HTTP 422 campo_invalido coordenadas fora dos limites (-90 <= lat <= 90, -180 <= lon <= 180).
--      - Rejeita com status HTTP 422 campo_obrigatorio entradas nulas ou com atributos faltantes.
--      - Rejeita com status HTTP 422 campo_invalido valores não numéricos.
--      - Propaga o nome do campo informado no argumento 'campo' para o details do erro.
--   3. privado.ponto_em_json:
--      - Converte geography PostGIS para jsonb formatado com 6 casas decimais, aplicando round(..., 6).
--      - Retorna NULL sem erro quando a geografia informada é NULL.
--      - Garante round-trip fiel (jsonb -> geography -> jsonb).
--   4. Provas de Mutação Dinâmica via pg_get_functiondef matando mutantes de SemVer, validação geográfica, status HTTP e round.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(35);

-- Função auxiliar temporária para capturar diagnostics de exceção de public.erro
create or replace function pg_temp.capturar_erro_ponto(p jsonb, campo text default 'ponto_base')
returns jsonb language plpgsql as $$
declare
  v_state text;
  v_msg text;
  v_detail text;
begin
  begin
    perform privado.ponto_do_json(p, campo);
    return jsonb_build_object('ocorreu', false);
  exception when others then
    get stacked diagnostics
      v_state = returned_sqlstate,
      v_msg = message_text,
      v_detail = pg_exception_detail;
    return jsonb_build_object(
      'ocorreu', true,
      'sqlstate', v_state,
      'code', (v_msg::jsonb)->>'code',
      'status', ((v_detail::jsonb)->>'status')::int,
      'details', (v_msg::jsonb)->>'details'
    );
  end;
end $$;

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

-- ── 4. privado.ponto_do_json: Limites Geográficos Excedidos e Status HTTP 422 ───────
select is(
  ((pg_temp.capturar_erro_ponto('{"latitude": 90.0001, "longitude": -47.8822}'::jsonb))->>'status')::int,
  422,
  'latitude superior a 90 graus retorna erro com status HTTP 422 em PG_EXCEPTION_DETAIL'
);

select is(
  (pg_temp.capturar_erro_ponto('{"latitude": 90.0001, "longitude": -47.8822}'::jsonb))->>'code',
  'campo_invalido',
  'latitude superior a 90 graus retorna code campo_invalido em MESSAGE_TEXT'
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

-- ── 6. privado.ponto_em_json: Geography para JSONB, Arredondamento e Round-Trip ───
select is(
  privado.ponto_em_json('SRID=4326;POINT(-47.882212 -15.794234)'::extensions.geography),
  '{"latitude": -15.794234, "longitude": -47.882212}'::jsonb,
  'geography PostGIS é convertido para jsonb com 6 casas decimais'
);

select is(
  privado.ponto_em_json('SRID=4326;POINT(-47.8822127 -15.7942347)'::extensions.geography),
  '{"latitude": -15.794235, "longitude": -47.882213}'::jsonb,
  'geography com 7 casas decimais é arredondado para 6 casas decimais via round(..., 6)'
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

-- Mutante M4: Substituição do status HTTP 422 por 400 em ponto_do_json
-- Demonstra que a captura de PG_EXCEPTION_DETAIL discrimina status 400 versus 422.
do $$
begin
  execute replace(
    (select def_ponto_do from canonicos),
    'public.erro(422,',
    'public.erro(400,'
  );
end $$;

select is(
  ((pg_temp.capturar_erro_ponto('{"latitude": 90.0001, "longitude": -47.8822}'::jsonb))->>'status')::int,
  400,
  'mutante M4 (status HTTP 400 em vez de 422): detectado pela captura de PG_EXCEPTION_DETAIL; morto pela suíte'
);

-- Restauração dinâmica de M4
do $$
begin
  execute (select def_ponto_do from canonicos);
end $$;

-- Mutante M5: Omissão de round(..., 6) em ponto_em_json
-- Demonstra que sob M5 a 7ª casa decimal não seria arredondada.
do $$
begin
  execute replace(
    replace(
      (select def_ponto_em from canonicos),
      'round(extensions.ST_Y(g::extensions.geometry)::numeric, 6)',
      'extensions.ST_Y(g::extensions.geometry)::numeric'
    ),
    'round(extensions.ST_X(g::extensions.geometry)::numeric, 6)',
    'extensions.ST_X(g::extensions.geometry)::numeric'
  );
end $$;

select is(
  privado.ponto_em_json('SRID=4326;POINT(-47.8822127 -15.7942347)'::extensions.geography),
  '{"latitude": -15.7942347, "longitude": -47.8822127}'::jsonb,
  'mutante M5 (sem round para 6 casas): preserva a 7ª casa sem arredondamento; morto pela suíte'
);

-- Restauração dinâmica de M5
do $$
begin
  execute (select def_ponto_em from canonicos);
end $$;

select * from finish();

rollback;
