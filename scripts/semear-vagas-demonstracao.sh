#!/usr/bin/env bash
# Semeia vagas futuras abertas de demonstração pós-06/11 para o Bar da Revisão
# (cartão 5boVdM0t, critério 4):
#
#   - Vagas abertas para Bar da Revisão / revisao-contratante;
#   - Posições abertas configuráveis (padrão 20 por vaga para destravar o teste "Detalhe 20x");
#   - Quantidade de vagas configurável (padrão 5 para destravar o teste "Lista cheia");
#   - Datas pós-06/11 (padrão a partir de 2026-11-20).
#   - Idempotente por chave_cliente (RF04): rodar de novo com as mesmas datas não duplica.
#
# Uso:
#   ./scripts/semear-vagas-demonstracao.sh <quantidade> [--a-partir-de AAAA-MM-DD]    # remoto (frila-dev)
#   ./scripts/semear-vagas-demonstracao.sh local [<quantidade>] [--posicoes N]       # local (contêiner Docker)
#   ./scripts/semear-vagas-demonstracao.sh dev [<quantidade>] [--a-partir-de DATA]   # remoto explícito
#   ./scripts/semear-vagas-demonstracao.sh prod <quantidade>                         # produção (exige confirmação)
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck disable=SC1091
[ -f .env ] && { set -a; source .env; set +a; }

AMBIENTE="dev"
QUANTIDADE=""
A_PARTIR_DE="2026-11-20"
POSICOES="20"
SECO=""

# Valores padrão de demonstração (DEMONSTRACAO_EMAILS em supabase/functions/entrar-demonstracao/index.ts
# e migração renovar_dados_demonstracao para Bar da Revisão)
EMAIL_CONTRATANTE="${EMAIL_CONTRATANTE:-revisao-contratante@frila.app}"
ESTABELECIMENTO_BAR_DA_REVISAO="${ESTABELECIMENTO_BAR_DA_REVISAO:-de000000-0000-4000-8000-000000000010}"

# Verifica se o primeiro argumento é o identificador de ambiente
if [ $# -gt 0 ]; then
  case "$1" in
    local|dev|prod)
      AMBIENTE="$1"
      shift
      ;;
  esac
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --local) AMBIENTE="local"; shift ;;
    --dev)   AMBIENTE="dev"; shift ;;
    --prod)  AMBIENTE="prod"; shift ;;
    --a-partir-de|--inicio) A_PARTIR_DE="$2"; shift 2 ;;
    --quantidade) QUANTIDADE="$2"; shift 2 ;;
    --posicoes)   POSICOES="$2"; shift 2 ;;
    --seco)       SECO=1; shift ;;
    [0-9]*)
      if [ -z "$QUANTIDADE" ]; then
        QUANTIDADE="$1"; shift
      else
        echo "argumento inesperado: $1" >&2; exit 2
      fi
      ;;
    *)
      echo "opção desconhecida: $1" >&2; exit 2
      ;;
  esac
done

QUANTIDADE="${QUANTIDADE:-5}"

case "$QUANTIDADE" in
  ''|*[!0-9]*) echo "quantidade precisa ser um inteiro positivo: $QUANTIDADE" >&2; exit 2 ;;
esac
[ "$QUANTIDADE" -ge 1 ] || { echo "quantidade precisa ser >= 1" >&2; exit 2; }

falhou() { printf '  ✗ %s\n' "$1" >&2; exit 1; }
ok()     { printf '  ✓ %s\n' "$1"; }

if [ "$AMBIENTE" = "local" ]; then
  DB="${DB_CONTAINER:-supabase_db_frila-backend}"
  INICIO_BASE="'${A_PARTIR_DE}T18:00:00Z'::timestamptz"
  QUERY="select privado.semear_vagas_demonstracao($QUANTIDADE, $INICIO_BASE, $POSICOES);"
  echo "▸ Semeadura de $QUANTIDADE vaga(s) de demonstração no ambiente local ($POSICOES posições/vaga)"
  if [ -n "$SECO" ]; then
    echo "  [seco] docker exec -i $DB psql -U postgres -d postgres -c \"$QUERY\""
    exit 0
  fi
  docker exec -i "$DB" psql -U postgres -d postgres -q -c "$QUERY" >/dev/null \
    || falhou "falha ao executar semeadura no contêiner $DB"
  ok "vagas de demonstração semeadas no contêiner local com sucesso"
  exit 0
fi

# ── Execução Remota (dev ou prod via REST / PostgREST) ─────────────────────────
if [ "$AMBIENTE" = "prod" ]; then
  [ "${EU_SEI_QUE_E_PRODUCAO:-}" = "1" ] || falhou \
    "prod recusado. A semeadura altera dados no banco de produção. Se é isso mesmo, execute com EU_SEI_QUE_E_PRODUCAO=1"
  BASE_URL="${FRILA_PROD_URL:-}"
  ANON_KEY="${FRILA_PROD_ANON_KEY:-}"
  SERVICE_ROLE="${FRILA_PROD_SERVICE_ROLE_KEY:-}"
else
  BASE_URL="${FRILA_DEV_URL:-}"
  ANON_KEY="${FRILA_DEV_ANON_KEY:-}"
  SERVICE_ROLE="${FRILA_DEV_SERVICE_ROLE_KEY:-}"
fi

if [ -n "$SECO" ]; then
  echo "  [seco] semeadura remota no $AMBIENTE: $QUANTIDADE vaga(s) a partir de $A_PARTIR_DE ($POSICOES posições)"
  exit 0
fi

for par in "URL:${BASE_URL}" "ANON:${ANON_KEY}" "SERVICE_ROLE:${SERVICE_ROLE}" "EMAIL_CONTRATANTE:${EMAIL_CONTRATANTE}" "ESTABELECIMENTO_BAR_DA_REVISAO:${ESTABELECIMENTO_BAR_DA_REVISAO}"; do
  [ -n "${par#*:}" ] || { echo "falta ${par%%:*} para $AMBIENTE no .env" >&2; exit 1; }
done

FUNCAO_GARCOM=$(curl -s "$BASE_URL/rest/v1/funcao?nome=eq.gar%C3%A7om&select=id" \
  -H "apikey: $SERVICE_ROLE" \
  -H "Authorization: Bearer $SERVICE_ROLE" \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[0]['id'] if d else '')")
[ -n "$FUNCAO_GARCOM" ] || { echo "✗ função 'garçom' não encontrada no catálogo de $AMBIENTE" >&2; exit 1; }

echo "▸ Sessão para $EMAIL_CONTRATANTE em $AMBIENTE (bypass da porta de demonstração, mesma RPC de login)"
LINK=$(curl -s -X POST "$BASE_URL/auth/v1/admin/generate_link" \
  -H "apikey: $SERVICE_ROLE" \
  -H "Authorization: Bearer $SERVICE_ROLE" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"magiclink\",\"email\":\"$EMAIL_CONTRATANTE\"}")
OTP=$(printf '%s' "$LINK" | python3 -c "import json,sys;print(json.load(sys.stdin).get('email_otp',''))")
if [ -z "$OTP" ]; then
  echo "✗ generate_link não devolveu email_otp. Resposta (sem token): $(printf '%s' "$LINK" | python3 -c "import json,sys;d=json.load(sys.stdin);d.pop('email_otp',None);print(d)")" >&2
  exit 1
fi

SESSAO=$(curl -s -X POST "$BASE_URL/auth/v1/verify" \
  -H "apikey: $ANON_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"magiclink\",\"email\":\"$EMAIL_CONTRATANTE\",\"token\":\"$OTP\"}")
ACCESS_TOKEN=$(printf '%s' "$SESSAO" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))")
if [ -z "$ACCESS_TOKEN" ]; then
  echo "✗ verify não devolveu sessão." >&2
  exit 1
fi
echo "  ✓ sessão obtida (access_token presente, não impresso)"

echo "▸ Publicando $QUANTIDADE vaga(s), a partir de $A_PARTIR_DE, um dia cada ($POSICOES posições/vaga)"
for i in $(seq 0 $((QUANTIDADE - 1))); do
  DIA=$(python3 -c "
import datetime
base = datetime.date.fromisoformat('$A_PARTIR_DE')
print((base + datetime.timedelta(days=$i)).isoformat())
")
  CHAVE=$(python3 -c "
import uuid
print(uuid.uuid5(uuid.NAMESPACE_URL, '$AMBIENTE:demonstracao:bar-da-revisao:' + '$DIA'))
")
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'estabelecimento_id': '$ESTABELECIMENTO_BAR_DA_REVISAO',
  'funcao_id': '$FUNCAO_GARCOM',
  'inicio_em': '${DIA}T13:00:00-03:00',
  'fim_em': '${DIA}T18:00:00-03:00',
  'local': 'Bar da Revisao - salao principal',
  'ponto': {'latitude': -15.7801, 'longitude': -47.9292},
  'valor_centavos': 14000,
  'posicoes': int('$POSICOES'),
  'inclui_refeicao': True,
  'inclui_transporte': False,
  'exige_material_proprio': False,
  'responsavel_local': 'Gerente do Bar da Revisao',
  'modo': 'urgencia',
  'chave': '$CHAVE',
  'alerta_antecedencia_min': 180,
}))
")
  RESP=$(curl -s -w "\n%{http_code}" -X POST "$BASE_URL/rest/v1/rpc/publicar_vaga" \
    -H "Content-Type: application/json" \
    -H "apikey: $ANON_KEY" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "$PAYLOAD")
  STATUS=$(printf '%s' "$RESP" | tail -n1)
  BODY=$(printf '%s' "$RESP" | sed '$d')
  if [ "$STATUS" != "200" ]; then
    echo "  ✗ vaga de $DIA: HTTP $STATUS — $BODY" >&2
    exit 1
  fi
  VAGA_ID=$(printf '%s' "$BODY" | python3 -c "import json,sys;print(json.load(sys.stdin)['vaga_id'])")
  echo "  ✓ $DIA → vaga_id $VAGA_ID"
done

echo
echo "Semeadas $QUANTIDADE vaga(s) para Bar da Revisão em $AMBIENTE, a partir de $A_PARTIR_DE ($POSICOES posições/vaga)."
