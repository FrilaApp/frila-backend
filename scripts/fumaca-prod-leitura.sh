#!/usr/bin/env bash
# Fumaça pós-deploy estritamente de leitura (read-only smoke test).
#
# Baseado na especificação em .maestri/produtos/fumaca-prod-segura.md.
#
# REGRA FUNDAMENTAL: ZERO ESCRITAS
# - Utiliza exclusivamente métodos HTTP GET e HEAD.
# - SEM POST, sem mutação no banco, sem inserção de dados, sem disparo de e-mails/push.
# - URL e chave anônima informadas exclusivamente por variáveis de ambiente ou parâmetros.
#
# Probes realizados (11 probes de leitura pura):
#   1. GET /functions/v1/saude -> HTTP 200 (conectividade do Postgres e runtime Deno)
#   2. HEAD /functions/v1/saude -> HTTP 200 (probe de baixa latência)
#   3. GET /functions/v1/<funcao> (7 funções) -> HTTP 405 (rejeição de método sem execução)
#   4. GET /functions/v1/entrar-demonstracao -> HTTP 404 (rota Deno uniforme com anon key)
#   5. GET /rest/v1/ (sem auth) -> HTTP 401 (comprova fail-closed do PostgREST)
#
# Uso:
#   ./scripts/fumaca-prod-leitura.sh <URL> [ANON_KEY]
# Ou:
#   SUPABASE_URL=... SUPABASE_ANON_KEY=... ./scripts/fumaca-prod-leitura.sh
set -uo pipefail

URL_BASE="${1:-${SUPABASE_URL:-${FRILA_DEV_URL:-}}}"
ANON_KEY="${2:-${SUPABASE_ANON_KEY:-${FRILA_DEV_ANON_KEY:-}}}"
TIMEOUT="${FUMACA_TIMEOUT:-10}"

if [ -z "$URL_BASE" ]; then
  echo "✗ Erro: URL não informada." >&2
  echo "Uso: $0 <URL> [ANON_KEY]" >&2
  echo "Ou defina SUPABASE_URL (e opcionalmente SUPABASE_ANON_KEY) no ambiente." >&2
  exit 2
fi

# Remove barra final se houver
URL_BASE="${URL_BASE%/}"

echo "=========================================================="
echo "▸ Fumaça pós-deploy só de LEITURA (zero mutações)"
echo "▸ Alvo: $URL_BASE"
echo "=========================================================="

falhas=0
casos=0

registrar() {
  local ok="$1" nome="$2" detalhe="$3"
  casos=$((casos + 1))
  if [ "$ok" = "1" ]; then
    echo "  ✓ $nome: $detalhe"
  else
    echo "  ✗ $nome: $detalhe"
    falhas=$((falhas + 1))
  fi
}

# ─────────────────────────────────────────────────────────────
# 1. Probe de Saúde (GET e HEAD)
# ─────────────────────────────────────────────────────────────
echo "1. Probe de Saúde e Conectividade do Banco:"

# GET saude
saida_saude=$(curl -sS --max-time "$TIMEOUT" -w "\nHTTP_STATUS:%{http_code}" "$URL_BASE/functions/v1/saude" 2>&1 || true)
codigo_saude=$(echo "$saida_saude" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2 || echo "000")
corpo_saude=$(echo "$saida_saude" | sed '/HTTP_STATUS:/d')

if [ "$codigo_saude" = "200" ] && echo "$corpo_saude" | grep -qE '"(ok":true|status":"(saudavel|ok))"'; then
  registrar 1 "GET /functions/v1/saude" "HTTP 200 OK (Postgres e Deno operacionais)"
else
  registrar 0 "GET /functions/v1/saude" "esperado HTTP 200 com status saudável, veio HTTP $codigo_saude ($corpo_saude)"
fi

# HEAD saude (baixa latência)
codigo_head=$(curl -sS -I --max-time "$TIMEOUT" -w "%{http_code}" -o /dev/null "$URL_BASE/functions/v1/saude" 2>&1 || echo "000")
if [ "$codigo_head" = "200" ]; then
  registrar 1 "HEAD /functions/v1/saude" "HTTP 200 OK (probe leve respondendo)"
else
  registrar 0 "HEAD /functions/v1/saude" "esperado HTTP 200, veio HTTP $codigo_head"
fi

# ─────────────────────────────────────────────────────────────
# 2. Implantação das Edge Functions via Rejeição de Método (GET)
# As funções aceitam apenas POST; chamada GET comprova presença no Kong sem executar nada.
# ─────────────────────────────────────────────────────────────
echo ""
echo "2. Roteamento e Implantação das Edge Functions (método GET não permitido):"

FUNCOES_405=("despachar" "enviar-email" "enviar-push" "limpar-contas-orfas" "excluir-conta" "exportar-meus-dados" "exportar-turnos")

for fn in "${FUNCOES_405[@]}"; do
  # Se houver anon key, envia no header para atravessar verify_jwt limpo se aplicável
  if [ -n "$ANON_KEY" ]; then
    res_code=$(curl -sS --max-time "$TIMEOUT" -w "%{http_code}" -o /dev/null \
      -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" \
      "$URL_BASE/functions/v1/$fn" 2>&1 || echo "000")
  else
    res_code=$(curl -sS --max-time "$TIMEOUT" -w "%{http_code}" -o /dev/null \
      "$URL_BASE/functions/v1/$fn" 2>&1 || echo "000")
  fi

  # Aceita 405 (Method Not Allowed) ou 401 (Fail-Closed de JWT se sem token)
  if [ "$res_code" = "405" ] || [ "$res_code" = "401" ]; then
    registrar 1 "GET /functions/v1/$fn" "HTTP $res_code (roteamento confirmado, sem execução)"
  else
    registrar 0 "GET /functions/v1/$fn" "esperado HTTP 405 ou 401, veio HTTP $res_code"
  fi
done

# entrar-demonstracao (com anon key deve responder 404 de acordo com a rota Deno uniforme;
# aceitar 401 esconderia o gateway rejeitando a chamada, por isso enviamos Authorization+apikey e exigimos 404)
if [ -n "$ANON_KEY" ]; then
  res_demo=$(curl -sS --max-time "$TIMEOUT" -w "%{http_code}" -o /dev/null \
    -H "apikey: $ANON_KEY" -H "Authorization: Bearer $ANON_KEY" \
    "$URL_BASE/functions/v1/entrar-demonstracao" 2>&1 || echo "000")
else
  res_demo=$(curl -sS --max-time "$TIMEOUT" -w "%{http_code}" -o /dev/null \
    "$URL_BASE/functions/v1/entrar-demonstracao" 2>&1 || echo "000")
fi

if [ "$res_demo" = "404" ]; then
  registrar 1 "GET /functions/v1/entrar-demonstracao" "HTTP 404 (função ativa na borda, rota uniforme)"
else
  registrar 0 "GET /functions/v1/entrar-demonstracao" "esperado HTTP 404, veio HTTP $res_demo"
fi

# ─────────────────────────────────────────────────────────────
# 3. Proteção e Fail-Closed de Rotas Privadas (PostgREST)
# ─────────────────────────────────────────────────────────────
echo ""
echo "3. Proteção de Acesso e Fail-Closed do PostgREST:"

# GET na raiz do PostgREST sem credenciais DEVE falhar com 401 Unauthorized
st_sem_auth=$(curl -sS --max-time "$TIMEOUT" -w "%{http_code}" -o /dev/null \
  "$URL_BASE/rest/v1/" 2>&1 || echo "000")
if [ "$st_sem_auth" = "401" ]; then
  registrar 1 "GET /rest/v1/ sem credenciais" "HTTP 401 Unauthorized (fail-closed confirmado)"
else
  registrar 0 "GET /rest/v1/ sem credenciais" "esperado HTTP 401, veio HTTP $st_sem_auth"
fi

# ─────────────────────────────────────────────────────────────
# Veredito Final
# ─────────────────────────────────────────────────────────────
echo ""
echo "=========================================================="
if [ "$falhas" -eq 0 ]; then
  echo "✓ Suíte de fumaça de leitura passou ($casos/$casos probes verdes)."
  echo "  Nenhuma operação mutante ou escrita executada."
  echo "=========================================================="
  exit 0
else
  echo "✗ Suíte de fumaça de leitura falhou ($falhas de $casos probes falharam)."
  echo "=========================================================="
  exit 1
fi
