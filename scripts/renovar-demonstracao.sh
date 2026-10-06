#!/usr/bin/env bash
# Renova os dados de demonstração (cartão RzllRo3o, item 6):
#
#   - Contas revisao-contratante e revisao-profissional;
#   - Vagas (aberta e preenchida) e turnos com datas sempre à frente do relógio;
#   - Turno de demonstração restaurado para pendente de check-in (virgem);
#   - Teto de tentativas em entrada_demonstracao zerado.
#
# Uso:
#   ./scripts/renovar-demonstracao.sh                      # local (padrão)
#   ./scripts/renovar-demonstracao.sh local                # local explícito
#   ./scripts/renovar-demonstracao.sh local --data "2026-11-01T12:00:00Z"
#   ./scripts/renovar-demonstracao.sh dev                  # frila-dev remoto
#   ./scripts/renovar-demonstracao.sh prod                 # frila-prod (exige EU_SEI_QUE_E_PRODUCAO=1)
#   ./scripts/renovar-demonstracao.sh <ambiente> --seco
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[ -f .env ] && { set -a; source .env; set +a; }

AMBIENTE="${1:-local}"
shift || true

DATA_REF="null"
SECO=""

while [ $# -gt 0 ]; do
  case "$1" in
    --data) DATA_REF="'$2'::timestamptz"; shift 2 ;;
    --seco) SECO=1; shift ;;
    *) echo "opção desconhecida: $1" >&2; exit 2 ;;
  esac
done

falhou() { printf '  ✗ %s\n' "$1" >&2; exit 1; }
ok()     { printf '  ✓ %s\n' "$1"; }

QUERY="select privado.renovar_dados_demonstracao($DATA_REF);"

case "$AMBIENTE" in
  local)
    DB="${DB_CONTAINER:-supabase_db_frila-backend}"
    echo "▸ Renovação dos dados de demonstração no ambiente local"
    if [ -n "$SECO" ]; then
      echo "  [seco] docker exec -i $DB psql -U postgres -d postgres -c \"$QUERY\""
      exit 0
    fi
    docker exec -i "$DB" psql -U postgres -d postgres -q -c "$QUERY" >/dev/null \
      || falhou "falha ao executar renovação no contêiner $DB"
    ok "dados de demonstração renovados no contêiner local"
    ;;
  dev)
    REF="${FRILA_DEV_PROJECT_REF:-<project-ref-dev>}"
    echo "▸ Renovação dos dados de demonstração no frila-dev ($REF)"
    if [ -n "$SECO" ]; then
      echo "  [seco] POST https://api.supabase.com/v1/projects/$REF/database/query: $QUERY"
      exit 0
    fi
    [ -n "${FRILA_DEV_PROJECT_REF:-}" ] || falhou "falta FRILA_DEV_PROJECT_REF no .env"
    : "${SUPABASE_ACCESS_TOKEN:?falta SUPABASE_ACCESS_TOKEN no .env}"
    curl -s -X POST -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
         -H 'Content-Type: application/json' \
         -d "{\"query\":\"$QUERY\"}" \
         "https://api.supabase.com/v1/projects/$REF/database/query" >/dev/null \
      || falhou "falha ao renovar dados de demonstração no frila-dev"
    ok "dados de demonstração renovados no frila-dev"
    ;;
  prod)
    REF="${FRILA_PROD_PROJECT_REF:-<project-ref-prod>}"
    echo "▸ Renovação dos dados de demonstração no frila-prod ($REF)"
    if [ -n "$SECO" ]; then
      echo "  [seco] POST https://api.supabase.com/v1/projects/$REF/database/query: $QUERY"
      exit 0
    fi
    [ "${EU_SEI_QUE_E_PRODUCAO:-}" = "1" ] || falhou \
      "prod recusado. A renovação altera dados no banco de produção. Se é isso mesmo, execute com EU_SEI_QUE_E_PRODUCAO=1"
    [ -n "${FRILA_PROD_PROJECT_REF:-}" ] || falhou "falta FRILA_PROD_PROJECT_REF no .env"
    : "${SUPABASE_ACCESS_TOKEN:?falta SUPABASE_ACCESS_TOKEN no .env}"
    curl -s -X POST -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
         -H 'Content-Type: application/json' \
         -d "{\"query\":\"$QUERY\"}" \
         "https://api.supabase.com/v1/projects/$REF/database/query" >/dev/null \
      || falhou "falha ao renovar dados de demonstração no frila-prod"
    ok "dados de demonstração renovados no frila-prod"
    ;;
  *)
    echo "ambiente desconhecido: $AMBIENTE (use local, dev ou prod)" >&2
    exit 2
    ;;
esac
