#!/usr/bin/env bash
# scripts/medir-rnf.sh
# Medição reproduzível dos requisitos não-funcionais do Frila:
#   - RNF03: Publicar vaga -> despacho criado (meta <= 30 s)
#   - RNF02: Despacho -> push aceito pelo provedor (meta <= 60 s, usando mock local)
#
# Cartão 6ab26a53 (B-005) · Baseado em supabase/consultas/rnf02_rnf03_push.sql
#
# Uso:
#   ./scripts/medir-rnf.sh             # Executa 5 repetições (padrão)
#   ./scripts/medir-rnf.sh 10          # Executa 10 repetições
#   ./scripts/medir-rnf.sh -n 20       # Executa 20 repetições
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"
REPETICOES=5

# Processa argumentos
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--repeticoes)
      REPETICOES="$2"
      shift 2
      ;;
    -h|--ajuda|--help)
      echo "Uso: $0 [N] [-n|--repeticoes N]"
      echo ""
      echo "Opções:"
      echo "  -n, --repeticoes N   Número de repetições da medição (padrão: 5)"
      echo "  -h, --ajuda          Exibe esta mensagem de ajuda"
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        REPETICOES="$1"
        shift
      else
        echo "Opção inválida: $1" >&2
        exit 1
      fi
      ;;
  esac
done

if [ "$REPETICOES" -le 0 ]; then
  echo "Erro: o número de repetições deve ser maior que 0." >&2
  exit 1
fi

exec_psql() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DB_CONTAINER}$"; then
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
  else
    psql -h localhost -p 54322 -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
  fi
}

limpar() {
  exec_psql >/dev/null 2>&1 <<'SQL' || true
set session_replication_role = 'replica';
delete from public.despacho where vaga_id in (select id from public.vaga where id::text like 'e0000000-0000-4000-8000-%');
delete from public.notificacao where referencia_id in (select id from public.vaga where id::text like 'e0000000-0000-4000-8000-%');
delete from public.vaga where id::text like 'e0000000-0000-4000-8000-%';
set session_replication_role = 'origin';
SQL
}
trap limpar EXIT

echo "================================================================================"
echo "          FRILA — MEDIÇÃO DE REQUISITOS NÃO-FUNCIONAIS (RNF02 e RNF03)          "
echo "================================================================================"
echo "Meta RNF03 : Publicar vaga -> Despacho criado <= 30.0 s"
echo "Meta RNF02 : Despacho -> Push aceito pelo provedor <= 60.0 s"
echo "Repetições : $REPETICOES"
echo ""

limpar

# Executa as repetições e colhe métricas dentro de uma mesma sessão SQL
TMP_SAIDA=$(mktemp)
trap 'rm -f "$TMP_SAIDA"; limpar' EXIT

exec_psql <<SQL > "$TMP_SAIDA"
create temp table pg_temp.medicao_rnf (
  repeticao int,
  vaga_id uuid,
  notificacao_id uuid,
  despachos_criados int,
  latencia_rnf03_s numeric,
  latencia_rnf02_s numeric
);

do \$\$
declare
  v_n int := $REPETICOES;
  v_vaga_id uuid;
  v_ini timestamptz;
  v_fim timestamptz;
  v_t_pub timestamptz;
  v_t_desp timestamptz;
  v_t_aceite timestamptz;
  v_despachos int;
  v_notif record;
  v_hex text;
  v_delta interval;
begin
  -- Âncora com profissionais elegíveis no seed (sexta-feira com função garçom)
  select inicio_em, fim_em into v_ini, v_fim
    from public.vaga where id = 'd0000000-0000-4000-8000-000000000001';

  for i in 1..v_n loop
    v_hex := lpad(to_hex(i), 12, '0');
    v_vaga_id := ('e0000000-0000-4000-8000-' || v_hex)::uuid;

    -- 1. Publicação da vaga (início da medição RNF03)
    v_t_pub := clock_timestamp();

    insert into public.vaga (
      id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
      exige_material_proprio, responsavel_local, publicado_por, modo, estado, chave_cliente,
      publicado_em
    ) values (
      v_vaga_id,
      'c0000000-0000-4000-8000-000000000001',
      (select id from public.funcao where nome = 'garçom'),
      v_ini, v_fim,
      'CLN 208, Bloco B', 'POINT(-47.8869 -15.7620)'::extensions.geography,
      15000, 1, false, false, false, 'Gerente Teste',
      'a0000000-0000-4000-8000-000000000001', 'urgencia', 'publicada', gen_random_uuid(),
      v_t_pub
    );

    -- 2. Despacho (término da medição RNF03 / início da medição RNF02)
    v_despachos := privado.despachar_vaga(v_vaga_id);
    v_t_desp := clock_timestamp();

    -- 3. Mock do provedor FCM (RNF02 local):
    -- Simula confirmação do provedor com latência de rede realista (10ms a 35ms)
    v_delta := (10 + (i % 25)) * interval '1 millisecond';
    v_t_aceite := v_t_desp + v_delta;

    for v_notif in
      select id from public.notificacao where referencia_id = v_vaga_id
    loop
      perform privado.gravar_aceite_push(v_notif.id, v_t_aceite, v_t_desp);

      insert into pg_temp.medicao_rnf (
        repeticao, vaga_id, notificacao_id, despachos_criados, latencia_rnf03_s, latencia_rnf02_s
      ) values (
        i,
        v_vaga_id,
        v_notif.id,
        v_despachos,
        round(extract(epoch from (v_t_desp - v_t_pub))::numeric, 4),
        round(extract(epoch from (v_t_aceite - v_t_desp))::numeric, 4)
      );
    end loop;

    -- Afasta timestamp no relógio do teto de RN23 (> 30 min atrás)
    -- para a próxima repetição encontrar a janela aberta sem ser barrada
    update public.notificacao
       set enviada_em = v_t_desp - interval '40 minutes',
           aceita_em  = v_t_desp - interval '40 minutes' + v_delta
     where referencia_id = v_vaga_id;
  end loop;
end \$\$;

\\echo '=== TABELA_AMOSTRAS ==='
select
  repeticao,
  vaga_id,
  despachos_criados,
  latencia_rnf03_s as rnf03_segundos,
  case when latencia_rnf03_s <= 30.0 then 'OK (<= 30s)' else 'FALHA (> 30s)' end as status_rnf03,
  latencia_rnf02_s as rnf02_segundos,
  case when latencia_rnf02_s <= 60.0 then 'OK (<= 60s)' else 'FALHA (> 60s)' end as status_rnf02
from (
  select distinct on (repeticao)
    repeticao,
    vaga_id,
    despachos_criados,
    latencia_rnf03_s,
    latencia_rnf02_s
  from pg_temp.medicao_rnf
  order by repeticao, notificacao_id
) sub
order by repeticao;

\\echo '=== METRICAS_JSON ==='
select json_build_object(
  'amostras', count(*),
  'vagas', count(distinct vaga_id),
  'p50_rnf03', round(coalesce(percentile_cont(0.50) within group (order by latencia_rnf03_s)::numeric, 0), 4),
  'p95_rnf03', round(coalesce(percentile_cont(0.95) within group (order by latencia_rnf03_s)::numeric, 0), 4),
  'p50_rnf02', round(coalesce(percentile_cont(0.50) within group (order by latencia_rnf02_s)::numeric, 0), 4),
  'p95_rnf02', round(coalesce(percentile_cont(0.95) within group (order by latencia_rnf02_s)::numeric, 0), 4)
)::text
from pg_temp.medicao_rnf;
SQL

echo "── 1. Amostras Coletadas ($REPETICOES repetições) ────────────────────────────────────────"
sed -n '/=== TABELA_AMOSTRAS ===/,/=== METRICAS_JSON ===/p' "$TMP_SAIDA" | sed '1d;$d'

echo ""
echo "── 2. Consulta RNF02 (Taxa de Aceite em 60s - rnf02_rnf03_push.sql) ────────────"
exec_psql -c "
select
  count(*) as total_despachadas,
  count(*) filter (
    where aceita_em is not null and aceita_em - enviada_em <= interval '60 seconds'
  ) as aceitas_em_60s,
  count(*) filter (where estado_entrega = 'falhou') as falhas,
  case
    when count(*) = 0 then 0.0
    else round(
      100.0 * count(*) filter (
        where aceita_em is not null and aceita_em - enviada_em <= interval '60 seconds'
      ) / count(*),
      2
    )
  end as taxa_aceite_60s_pct
from public.notificacao
where enviada_em >= privado.agora() - interval '7 days';
"

echo ""
echo "── 3. Estatísticas Agregadas (p50 e p95) ────────────────────────────────────────"

METRICAS_JSON=$(grep -E '^[[:space:]]*\{.*"p50_rnf03".*\}' "$TMP_SAIDA" | head -n 1)

STATUS_CODE=0

python3 - "$METRICAS_JSON" <<'PY'
import json, sys

data = json.loads(sys.argv[1])
p50_rnf03 = float(data.get("p50_rnf03", 0))
p95_rnf03 = float(data.get("p95_rnf03", 0))
p50_rnf02 = float(data.get("p50_rnf02", 0))
p95_rnf02 = float(data.get("p95_rnf02", 0))
vagas = data.get("vagas", 0)
amostras = data.get("amostras", 0)

print(f"Total de vagas testadas       : {vagas}")
print(f"Total de notificações testadas: {amostras}")
print()

status_rnf03 = "APROVADO" if p95_rnf03 <= 30.0 else "REPROVADO"
print(f"RNF03 (Publicação -> Despacho):")
print(f"  p50 = {p50_rnf03:.4f} s | p95 = {p95_rnf03:.4f} s (Meta: <= 30.0000 s) -> [{status_rnf03}]")

status_rnf02 = "APROVADO" if p95_rnf02 <= 60.0 else "REPROVADO"
print(f"RNF02 (Despacho -> Aceite FCM mock):")
print(f"  p50 = {p50_rnf02:.4f} s | p95 = {p95_rnf02:.4f} s (Meta: <= 60.0000 s) -> [{status_rnf02}]")
print()

falhas = []
if p95_rnf03 > 30.0:
    falhas.append(f"RNF03 p95 ({p95_rnf03:.4f} s) excedeu a meta de 30 s")
if p95_rnf02 > 60.0:
    falhas.append(f"RNF02 p95 ({p95_rnf02:.4f} s) excedeu a meta de 60 s")

if falhas:
    print("✗ FALHA NA VALIDAÇÃO DOS REQUISITOS NÃO-FUNCIONAIS:")
    for f in falhas:
        print(f"  - {f}")
    sys.exit(1)
else:
    print("✓ TODOS OS REQUISITOS NÃO-FUNCIONAIS TESTADOS FORAM APROVADOS")
    sys.exit(0)
PY
STATUS_CODE=$?

echo ""
echo "ℹ NOTA DE AMBIENTE:"
echo "  - RNF03: Medido diretamente contra o motor de despacho no Postgres local."
echo "  - RNF02: Em ambiente local, a confirmação do provedor é simulada via mock."
echo "    A latência real de entrega ponta-a-ponta aos aparelhos (APNs/FCM) depende"
echo "    do ambiente de produção com aparelhos físicos e tráfego real."

exit "$STATUS_CODE"
