#!/usr/bin/env bash
# scripts/funil.sh
# Imprime o funil de conversão do piloto do Frila (Cartão 1MK1CGyF, T-0017, T-0020).
#
# Uso:
#   ./scripts/funil.sh                    # Imprime visão completa (Geral, Estabelecimento, Dia)
#   ./scripts/funil.sh --dia              # Imprime funil por dia
#   ./scripts/funil.sh --estabelecimento  # Imprime funil por estabelecimento
#   ./scripts/funil.sh --geral            # Imprime resumo geral
#   ./scripts/funil.sh --json             # Saída em formato JSON
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"

exec_sql() {
  local query="$1"
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" -c "$query"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DB_CONTAINER}$"; then
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -c "$query"
  else
    psql -h localhost -p 54322 -U postgres -d postgres -c "$query"
  fi
}

exec_sql_json() {
  local query="$1"
  local json_query="select coalesce(json_agg(t), '[]'::json) from ($query) t;"
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" -tAc "$json_query"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DB_CONTAINER}$"; then
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -tAc "$json_query"
  else
    psql -h localhost -p 54322 -U postgres -d postgres -tAc "$json_query"
  fi
}

modo="${1:-tudo}"

case "$modo" in
  --ajuda|-h|help)
    echo "Uso: $0 [--geral | --estabelecimento | --estab | --dia | --json]"
    echo ""
    echo "Opções:"
    echo "  --geral            Exibe o resumo consolidado do funil"
    echo "  --estabelecimento  Exibe o funil agrupado por estabelecimento"
    echo "  --dia              Exibe o funil agrupado por dia (data da publicação)"
    echo "  --json             Exibe todas as views em formato JSON estruturado"
    exit 0
    ;;
  --json)
    echo "{"
    echo '  "geral": '
    exec_sql_json "select * from metrica.funil_geral"
    echo '  ,'
    echo '  "por_estabelecimento": '
    exec_sql_json "select * from metrica.funil_por_estabelecimento"
    echo '  ,'
    echo '  "por_dia": '
    exec_sql_json "select * from metrica.funil_por_dia"
    echo "}"
    exit 0
    ;;
  --geral)
    echo "=== Funil Geral do Piloto ==="
    exec_sql "select * from metrica.funil_geral;"
    exit 0
    ;;
  --estabelecimento|--estab)
    echo "=== Funil por Estabelecimento ==="
    exec_sql "select * from metrica.funil_por_estabelecimento;"
    exit 0
    ;;
  --dia)
    echo "=== Funil por Dia ==="
    exec_sql "select * from metrica.funil_por_dia;"
    exit 0
    ;;
  *)
    echo "================================================================================"
    echo "                    FRILA — PAINEL DE MÉTRICAS DO PILOTO                        "
    echo "================================================================================"
    echo ""
    echo "── 1. Resumo Geral ─────────────────────────────────────────────────────────────"
    exec_sql "select * from metrica.funil_geral;"
    echo ""
    echo "── 2. Funil por Estabelecimento ────────────────────────────────────────────────"
    exec_sql "select * from metrica.funil_por_estabelecimento;"
    echo ""
    echo "── 3. Funil por Dia (Data de Publicação) ───────────────────────────────────────"
    exec_sql "select * from metrica.funil_por_dia;"
    ;;
esac
