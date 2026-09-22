#!/usr/bin/env bash
# Recusa PR que edita uma migração já existente na base.
#
# Uma migração aplicada é imutável: o ambiente que já rodou a versão antiga não
# roda a nova, e a diferença aparece semanas depois como coluna que existe numa
# máquina e não existe na outra. Correção entra como migração nova.
set -euo pipefail

base="${1:-origin/main}"
git fetch --quiet origin "${base#origin/}" 2>/dev/null || true

editadas=$(git diff --name-only --diff-filter=MD "$base"...HEAD -- supabase/migrations/ || true)

if [ -n "$editadas" ]; then
  echo "Migração já aplicada foi editada ou removida:"
  echo "$editadas" | sed 's/^/  /'
  echo
  echo "Corrija com uma migração nova: supabase migration new <nome>"
  exit 1
fi

echo "Nenhuma migração existente foi tocada."
