#!/usr/bin/env bash
# Decide se a etapa de mutação deve rodar ou se pode ser pulada com segurança.
#
# Em PRs que não alteram nada que a mutação mede (migrações, testes pgTAP,
# configurações do banco, seed ou os próprios scripts e mapas de mutação),
# a etapa é pulada para economizar tempo e cota de CI.
#
# Em push (develop, main) roda SEMPRE.
# Falha segura: qualquer erro no diff, base ausente ou dúvida faz RODAR.
#
# Códigos de saída:
#   0 - Deve rodar (em push, local, erro de diff ou arquivos relevantes alterados)
#   1 - Pode pular (somente em pull_request sem arquivos relevantes)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

evento="${GITHUB_EVENT_NAME:-}"

# Em push (develop e main) e em qualquer execução fora de pull_request (inclusive local),
# roda sempre.
if [ "$evento" != "pull_request" ]; then
  if [ -n "$evento" ]; then
    echo "Mutação vai rodar: evento '$evento' (roda sempre fora de pull_request)."
  else
    echo "Mutação vai rodar: execução local (fora de pull_request de CI)."
  fi
  exit 0
fi

# Determinar base de comparação
base_informada="${1:-${GITHUB_BASE_REF:-develop}}"
base=""

# Tentar origin/<base> (padrão em CI com checkout raso) e depois <base> direta
if [[ "$base_informada" != origin/* ]] && [ "$base_informada" != "HEAD" ]; then
  git fetch --quiet origin "$base_informada" 2>/dev/null || true
  if git rev-parse --verify --quiet "origin/$base_informada" >/dev/null 2>&1; then
    base="origin/$base_informada"
  elif git rev-parse --verify --quiet "$base_informada" >/dev/null 2>&1; then
    base="$base_informada"
  fi
else
  if [[ "$base_informada" == origin/* ]]; then
    git fetch --quiet origin "${base_informada#origin/}" 2>/dev/null || true
  fi
  if git rev-parse --verify --quiet "$base_informada" >/dev/null 2>&1; then
    base="$base_informada"
  elif git rev-parse --verify --quiet "${base_informada#origin/}" >/dev/null 2>&1; then
    base="${base_informada#origin/}"
  fi
fi

# Se a base não existir, falha segura: RODAR
if [ -z "$base" ]; then
  echo "Mutação vai rodar (falha segura): base '$base_informada' não encontrada no repositório."
  exit 0
fi

# Calcular diff contra a base
diff_saida=$(git diff --name-only "$base"...HEAD 2>&1)
diff_codigo=$?

if [ "$diff_codigo" -ne 0 ]; then
  echo "Mutação vai rodar (falha segura): erro ao calcular git diff contra '$base'."
  exit 0
fi

# Caminhos que influenciam o que a mutação mede
relevante=""
while IFS= read -r arq; do
  [ -z "$arq" ] && continue
  case "$arq" in
    supabase/migrations/*|supabase/tests/*|supabase/config*|supabase/seed.sql|scripts/mutacao.sh|scripts/mutacao-matadores.tsv|scripts/deve-rodar-mutacao.sh)
      relevante="$arq"
      break
      ;;
  esac
done <<< "$diff_saida"

if [ -n "$relevante" ]; then
  echo "Mutação vai rodar: PR altera arquivos relevantes ($relevante)."
  exit 0
fi

echo "Mutação pulada: PR não altera migrações, testes, configurações nem scripts de mutação."
exit 1
