#!/usr/bin/env bash
# A porta do `despachar` por HTTP: só o segredo do agendador abre (cartão ZqmkOaHn).
#
#   sem nada               → 401 nao_autenticado
#   com a chave publicável → 401 nao_autenticado   (é a que está dentro do app)
#   com segredo errado     → 401 nao_autenticado
#   com o segredo          → 200 {"processadas": 0}
#
# Uso local, com a função servida:
#   supabase functions serve --env-file supabase/functions/.env.local
#   ./scripts/despachar-porta.sh
#
# Uso contra um projeto remoto: SUPABASE_URL, SUPABASE_ANON_KEY (a publicável) e
# SEGREDO_AGENDADOR no ambiente. O script nunca imprime nenhum dos três.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# O que vier do ambiente ganha do arquivo: é assim que o mesmo script mede o frila-dev.
# Sem array associativo: o bash do macOS é o 3.2.
antes_url="${SUPABASE_URL:-}"; antes_anon="${SUPABASE_ANON_KEY:-}"; antes_segredo="${SEGREDO_AGENDADOR:-}"
[ -f supabase/functions/.env.local ] && { set -a; source supabase/functions/.env.local; set +a; }
[ -n "$antes_url" ] && SUPABASE_URL="$antes_url"
[ -n "$antes_anon" ] && SUPABASE_ANON_KEY="$antes_anon"
[ -n "$antes_segredo" ] && SEGREDO_AGENDADOR="$antes_segredo"

URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
ANON="${SUPABASE_ANON_KEY:-}"
[ -z "$ANON" ] && ANON=$(supabase status -o env 2>/dev/null | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')
SEGREDO="${SEGREDO_AGENDADOR:-}"

if [ -z "$ANON" ] || [ -z "$SEGREDO" ]; then
  echo "Sem SUPABASE_ANON_KEY ou sem SEGREDO_AGENDADOR. Copie supabase/functions/.env.exemplo" >&2
  echo "para supabase/functions/.env.local e sirva a função com --env-file." >&2
  exit 1
fi

PORTA="$URL/functions/v1/despachar"

ok()    { printf '  ✓ %s\n' "$1"; }
falhou(){ printf '  ✗ %s\n' "$1" >&2; exit 1; }

# Devolve "<corpo>\n<status>". Os cabeçalhos entram por arquivo de configuração do curl,
# e não pela linha de comando: argumento de processo aparece no `ps` de quem estiver na
# mesma máquina, e o segredo não pode.
chamar() { # chamar <método> [cabeçalho...]
  local metodo="$1"; shift
  local cfg; cfg=$(mktemp); chmod 600 "$cfg"
  for h in "$@"; do printf 'header = "%s"\n' "$h" >> "$cfg"; done
  curl -s -w '\n%{http_code}' -X "$metodo" --max-time 20 -K "$cfg" \
    -H 'Content-Type: application/json' -d '{}' "$PORTA"
  rm -f "$cfg"
}
status_de() { printf '%s' "$1" | tail -1; }
code_de()   { printf '%s' "$1" | sed '$d' | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("code",""))
except Exception: print("")'; }

espera_401() { # espera_401 <descrição> <resposta>
  [ "$(status_de "$2")" = 401 ] && [ "$(code_de "$2")" = nao_autenticado ] \
    && ok "$1: 401 nao_autenticado" \
    || falhou "$1: esperava 401 nao_autenticado, veio $(status_de "$2") $(code_de "$2")"
}

echo "▸ A porta recusa quem não é o agendador"
espera_401 "sem cabeçalho nenhum" "$(chamar POST)"
espera_401 "com a chave publicável" "$(chamar POST "apikey: $ANON" "Authorization: Bearer $ANON")"
espera_401 "com a chave publicável no lugar do segredo" "$(chamar POST "x-segredo-agendador: $ANON")"
espera_401 "com segredo errado" "$(chamar POST "x-segredo-agendador: ${SEGREDO}x")"

echo "▸ A porta abre para o segredo do agendador"
r=$(chamar POST "x-segredo-agendador: $SEGREDO")
[ "$(status_de "$r")" = 200 ] || falhou "com o segredo: esperava 200, veio $(status_de "$r")"
[ "$(printf '%s' "$r" | sed '$d' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("processadas"))')" = 0 ] \
  || falhou "com o segredo: o corpo não trouxe processadas: 0"
ok "com o segredo: 200 {\"processadas\": 0}"

echo "Porta do despachar conferida em $URL"
