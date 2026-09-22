#!/usr/bin/env bash
# Smoke test do ciclo inteiro, por HTTP, como um cliente de verdade:
#
#   criar_conta → cadastrar_estabelecimento → publicar_vaga → candidatar
#              → fazer_checkin → fazer_checkout → avaliar
#
# Existe porque pgTAP roda dentro do banco e não prova que a rota existe, que o
# PostgREST a expõe, nem que o status HTTP é o que o contrato promete. Aqui, prova.
#
# Uso:  ./scripts/ciclo-completo.sh            contra o ambiente local
#       SUPABASE_URL=… SUPABASE_ANON_KEY=… ./scripts/ciclo-completo.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -f .env ] && { set -a; source .env; set +a; }

URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
ANON="${SUPABASE_ANON_KEY:-}"

if [ -z "$ANON" ]; then
  ANON=$(supabase status -o env 2>/dev/null | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')
fi

if [ -z "$ANON" ]; then
  echo "Sem SUPABASE_ANON_KEY e sem 'supabase status'. Suba o ambiente: supabase start" >&2
  exit 1
fi

# As RPCs entram cartão a cartão. Enquanto a primeira não existir, o script diz
# isso em voz alta em vez de passar em silêncio — CI verde sobre nada é pior que
# CI vermelha.
existe_rpc() {
  local nome="$1" codigo
  codigo=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    "$URL/rest/v1/rpc/$nome" -H "apikey: $ANON" \
    -H 'Content-Type: application/json' -d '{}')
  [ "$codigo" != "404" ]
}

if ! existe_rpc criar_conta; then
  echo "⏭  criar_conta ainda não existe — ciclo não testável."
  echo "   Cartão: S0 · Backend · Entrada por código no e-mail e criar_conta com perfil"
  exit 0
fi

echo "TODO: o ciclo entra aqui conforme as RPCs do Sprint 1 forem aterrissando."
echo "     Cada RPC nova acrescenta um passo, com o status HTTP conferido."
exit 0
