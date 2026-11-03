#!/usr/bin/env bash
# Executa shellcheck nos scripts shell (.sh) alterados em relação à base.
#
# Portão opcional (não-bloqueante): útil em desenvolvimento e em CI para emitir
# alertas sobre scripts tocados sem bloquear o pipeline por estilos legados.
#
# Uso:
#   ./scripts/shellcheck-alterados.sh
#   ./scripts/shellcheck-alterados.sh --severity=warning
#   ./scripts/shellcheck-alterados.sh --base develop
#   ./scripts/shellcheck-alterados.sh arquivo1.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

BASE=""
SEVERITY=""
ARQUIVOS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      BASE="${2:-}"
      shift 2
      ;;
    --severity=*)
      SEVERITY="$1"
      shift
      ;;
    -h|--help)
      echo "Uso: $0 [--base <branch>] [--severity=error|warning|info|style] [arquivos...]"
      exit 0
      ;;
    *)
      ARQUIVOS+=("$1")
      shift
      ;;
  esac
done

if [ ${#ARQUIVOS[@]} -eq 0 ]; then
  # Descobre a base padrão se não fornecida
  if [ -z "$BASE" ]; then
    if git rev-parse --verify origin/develop >/dev/null 2>&1; then
      BASE="origin/develop"
    elif git rev-parse --verify develop >/dev/null 2>&1; then
      BASE="develop"
    elif git rev-parse --verify origin/main >/dev/null 2>&1; then
      BASE="origin/main"
    elif git rev-parse --verify main >/dev/null 2>&1; then
      BASE="main"
    else
      BASE="HEAD~1"
    fi
  fi

  # Coleta arquivos .sh adicionados ou modificados (com commits ou no working tree)
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && ARQUIVOS+=("$f")
  done < <(git diff --name-only --diff-filter=d "$BASE" -- '*.sh' 2>/dev/null || git diff --name-only --diff-filter=d HEAD -- '*.sh' 2>/dev/null || true)

  # Inclui novos arquivos ainda untracked
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && [[ "$f" == *.sh ]] && ARQUIVOS+=("$f")
  done < <(git status --porcelain --untracked-files=all | awk '$1 == "??" {print $2}')
fi

if [ ${#ARQUIVOS[@]} -eq 0 ]; then
  echo "✓ Nenhum script shell (.sh) alterado em relação a ${BASE:-base}."
  exit 0
fi

echo "▸ Analisando scripts alterados com shellcheck (${#ARQUIVOS[@]} arquivo(s)):"
for f in "${ARQUIVOS[@]}"; do
  echo "  - $f"
done
echo

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "⚠ shellcheck não está instalado no PATH; ignorando conferência."
  exit 0
fi

SC_ARGS=()
if [ -n "$SEVERITY" ]; then
  SC_ARGS+=("$SEVERITY")
fi

status=0
for f in "${ARQUIVOS[@]}"; do
  if ! shellcheck "${SC_ARGS[@]}" "$f"; then
    status=1
  fi
done

if [ $status -eq 0 ]; then
  echo "✓ Scripts alterados passaram no shellcheck sem achados (${SEVERITY:-todas severidades})."
else
  echo "⚠ Achados encontrados pelo shellcheck nos scripts alterados acima."
fi

exit "$status"
