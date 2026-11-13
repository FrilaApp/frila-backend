#!/usr/bin/env bash
# Decide se a etapa de mutação deve rodar ou se pode ser pulada com segurança.
#
# Em PRs que não alteram nada que a mutação mede (migrações, testes pgTAP,
# configurações do banco, seed, cenarios.sql ou os próprios scripts e mapas de mutação),
# a etapa é pulada para economizar tempo e cota de CI.
# Edge functions (supabase/functions/) são testadas pelo job Deno e não ativam a mutação.
#
# Em push (develop, main) roda SEMPRE.
# Falha segura: qualquer erro no diff, clone raso incompleto ou dúvida faz RODAR.
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

diff_saida=""
diff_codigo=1

# Estratégia 1: em pull_request de CI com checkout raso (fetch-depth >= 2),
# HEAD é o commit de merge sintético (refs/pull/X/merge). O primeiro pai (HEAD^1)
# é a ponta da base e HEAD^2 é a ponta do PR. O diff entre HEAD^1 e HEAD lista
# exatamente os arquivos alterados no PR sem precisar de merge-base ou histórico completo.
if git rev-parse --verify --quiet HEAD^2 >/dev/null 2>&1 && \
   git rev-parse --verify --quiet HEAD^1 >/dev/null 2>&1; then
  diff_saida=$(git -c core.quotePath=false diff --no-renames --name-only HEAD^1 HEAD 2>/dev/null)
  diff_codigo=$?
fi

# Estratégia 2: clone completo, branch local ou quando HEAD não é commit de merge sintético
if [ "$diff_codigo" -ne 0 ]; then
  # Se o repositório é raso e não temos HEAD^1 nem base completa, não arriscar: falha segura
  if [ -f "$(git rev-parse --git-dir 2>/dev/null)/shallow" ] && \
     ! git rev-parse --verify --quiet HEAD^1 >/dev/null 2>&1; then
    echo "Mutação vai rodar (falha segura): clone raso sem histórico suficiente (HEAD^1 ausente)."
    exit 0
  fi

  base_informada="${1:-${GITHUB_BASE_REF:-develop}}"
  base=""

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

  if [ -n "$base" ]; then
    diff_saida=$(git -c core.quotePath=false diff --no-renames --name-only "$base"...HEAD 2>/dev/null)
    diff_codigo=$?
  fi
fi

# Se não foi possível calcular o diff, falha segura: RODAR
if [ "$diff_codigo" -ne 0 ]; then
  echo "Mutação vai rodar (falha segura): não foi possível calcular git diff no ambiente atual."
  exit 0
fi

# Analisar caminhos alterados.
# Regra: qualquer arquivo em supabase/ (exceto supabase/functions/, que é Deno e a mutação não mede)
# e os scripts de mutação (execução, mapas e testes). Na dúvida, roda.
relevante=""
while IFS= read -r arq; do
  [ -z "$arq" ] && continue
  case "$arq" in
    supabase/functions/*)
      # Edge functions são testadas pelo job Deno, não pela mutação do banco
      ;;
    supabase/*|scripts/*mutacao*|.github/workflows/ci.yml)
      relevante="$arq"
      break
      ;;
  esac
done <<< "$diff_saida"

if [ -n "$relevante" ]; then
  echo "Mutação vai rodar: PR altera arquivos relevantes ($relevante)."
  exit 0
fi

echo "Mutação pulada: PR não altera arquivos relevantes para o banco ou para a mutação."
exit 1
