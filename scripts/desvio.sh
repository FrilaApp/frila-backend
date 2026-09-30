#!/usr/bin/env bash
# Compara o banco remoto com o que as migrações do repositório constroem.
#
# O que foi mudado pelo painel do Supabase não está em arquivo nenhum, e o próximo ambiente
# não tem: a função reescrita à mão, o `grant` a `anon`, o job do pg_cron pausado. Este
# portão pega isso. Ele roda `scripts/desvio.sql` no banco local, que precisa estar de pé
# com as migrações aplicadas do zero (`supabase db start` ou `supabase db reset`), e no
# projeto remoto pela Management API, e compara as duas listas.
#
# Não usa `supabase db diff --linked` porque ele pede a senha do banco, e a do frila-dev
# está com quem criou o projeto; o access token alcança o mesmo banco (mesmo motivo do
# `scripts/aplicar-remoto.sh`).
#
# Uso:  ./scripts/desvio.sh <project_ref>
#
# Saída: 0 sem desvio, 1 com desvio (e o relatório), 2 quando não conseguiu medir.
#
# Para o autoteste, `DESVIO_LOCAL` e `DESVIO_REMOTO` apontam para arquivos já prontos e
# pulam as duas consultas.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

REF="${1:-}"
CONTAINER="${DESVIO_CONTAINER:-supabase_db_frila-backend}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

nao_medi() { echo "✗ não medi: $1" >&2; exit 2; }

if [ -n "${DESVIO_LOCAL:-}" ]; then
  cp "$DESVIO_LOCAL" "$TMP/repositorio" || nao_medi "arquivo local $DESVIO_LOCAL"
else
  docker exec "$CONTAINER" true 2>/dev/null \
    || nao_medi "o banco local ($CONTAINER) não está de pé; rode supabase db start"
  docker exec -i -e PGPASSWORD=postgres "$CONTAINER" \
      psql -U postgres -d postgres -At -v ON_ERROR_STOP=1 < scripts/desvio.sql \
      > "$TMP/repositorio" \
    || nao_medi "a consulta falhou no banco local"
fi

if [ -n "${DESVIO_REMOTO:-}" ]; then
  cp "$DESVIO_REMOTO" "$TMP/remoto" || nao_medi "arquivo remoto $DESVIO_REMOTO"
else
  [ -n "$REF" ] || nao_medi "uso: desvio.sh <project_ref>"
  if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ] && [ -f .env ]; then
    set -a; source .env; set +a
  fi
  [ -n "${SUPABASE_ACCESS_TOKEN:-}" ] || nao_medi "falta SUPABASE_ACCESS_TOKEN"
  export SUPABASE_ACCESS_TOKEN REF
  python3 - > "$TMP/remoto" <<'PY' || nao_medi "a consulta falhou no projeto $REF"
import json, os, sys, urllib.request
req = urllib.request.Request(
    f"https://api.supabase.com/v1/projects/{os.environ['REF']}/database/query",
    data=json.dumps({"query": open("scripts/desvio.sql").read()}).encode(),
    headers={"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"],
             "Content-Type": "application/json"},
    method="POST")
try:
    linhas = json.load(urllib.request.urlopen(req, timeout=180))
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}: {e.read().decode()[:300]}", file=sys.stderr)
    sys.exit(1)
print("\n".join(l["linha"] for l in linhas))
PY
fi

# Lista vazia é consulta que não mediu, e não banco igual: nenhum banco com as migrações
# deste repositório tem zero objetos.
[ -s "$TMP/repositorio" ] || nao_medi "a lista do repositório veio vazia"
[ -s "$TMP/remoto" ] || nao_medi "a lista do remoto veio vazia"

LC_ALL=C sort -o "$TMP/repositorio" "$TMP/repositorio"
LC_ALL=C sort -o "$TMP/remoto" "$TMP/remoto"

so_repositorio=$(LC_ALL=C comm -23 "$TMP/repositorio" "$TMP/remoto")
so_remoto=$(LC_ALL=C comm -13 "$TMP/repositorio" "$TMP/remoto")

if [ -z "$so_repositorio" ] && [ -z "$so_remoto" ]; then
  echo "✓ sem desvio: $(wc -l < "$TMP/remoto" | tr -d ' ') objetos iguais no repositório e no remoto"
  exit 0
fi

echo "✗ DESVIO entre o repositório e o remoto"
if [ -n "$so_repositorio" ]; then
  echo
  echo "Só no repositório (migração não aplicada, ou desfeita pelo painel):"
  printf '%s\n' "$so_repositorio" | sed 's/^/  - /'
fi
if [ -n "$so_remoto" ]; then
  echo
  echo "Só no remoto (criado ou mudado fora de uma migração):"
  printf '%s\n' "$so_remoto" | sed 's/^/  + /'
fi
echo
echo "Uma mudança de verdade entra como migração nova; a do painel se desfaz no painel."
exit 1
