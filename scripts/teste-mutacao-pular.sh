#!/usr/bin/env bash
# Testa o decisor de pular/rodar a mutação (Mudança 1 da otimização de CI).
#
# Roda sem Postgres e sem rede, usando um repositório git temporário.
#
# Casos cobertos:
#   1. PR que só toca no contrato pula (exit 1).
#   2. PR com migração roda (exit 0).
#   3. PR com teste roda (exit 0).
#   4. Erro no diff ou base inexistente roda por falha segura (exit 0).
#   5. Evento push roda sempre (exit 0).
#   6. Execução local fora de CI roda (exit 0).
#
#   ./scripts/teste-mutacao-pular.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DECISOR="$PWD/scripts/deve-rodar-mutacao.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

# Configura um git temporário com branch base ('develop')
setup_repo() {
  local dir="$1"
  mkdir -p "$dir"
  (
    cd "$dir" || exit 1
    git init --quiet -b develop
    git config user.name "Tester"
    git config user.email "tester@frilabr.com"
    mkdir -p contrato supabase/migrations supabase/tests scripts
    touch contrato/openapi.yaml
    touch supabase/migrations/20260922150000_init.sql
    touch supabase/tests/010_base.sql
    cp "$DECISOR" scripts/deve-rodar-mutacao.sh
    git add .
    git commit --quiet -m "commit base"
    git checkout --quiet -b feature
  )
}

testar_caso() {
  local nome="$1"
  local evento="$2"
  local base_arg="$3"
  local codigo_esperado="$4"
  local texto_esperado="$5"
  local cmd_setup="$6"

  casos=$((casos + 1))
  local repo="$TMP/caso$casos"
  setup_repo "$repo"

  # Executa modificação específica do caso no repo
  ( cd "$repo" && eval "$cmd_setup" )

  local saida
  local codigo=0
  saida=$(
    cd "$repo"
    GITHUB_EVENT_NAME="$evento" ./scripts/deve-rodar-mutacao.sh "$base_arg" 2>&1
  ) || codigo=$?

  local contem=0
  if printf '%s\n' "$saida" | grep -qF "$texto_esperado"; then
    contem=1
  fi

  if [ "$codigo" -eq "$codigo_esperado" ] && [ "$contem" -eq 1 ]; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperado exit $codigo_esperado contendo '$texto_esperado', veio exit $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Decisor de mutação: pula ou roda nos casos certos"

testar_caso "PR só de contrato pula a mutação" \
  "pull_request" "develop" 1 "Mutação pulada" \
  "echo 'novo: 1' >> contrato/openapi.yaml && git add . && git commit --quiet -m 'so contrato'"

testar_caso "PR com migração roda a mutação" \
  "pull_request" "develop" 0 "Mutação vai rodar" \
  "touch supabase/migrations/20261112_nova.sql && git add . && git commit --quiet -m 'com migracao'"

testar_caso "PR com teste pgTAP roda a mutação" \
  "pull_request" "develop" 0 "Mutação vai rodar" \
  "touch supabase/tests/900_novo_teste.sql && git add . && git commit --quiet -m 'com teste'"

testar_caso "Erro no diff ou base inexistente roda por falha segura" \
  "pull_request" "base_inexistente_xyz" 0 "falha segura" \
  "echo 'touch' > contrato/openapi.yaml && git add . && git commit --quiet -m 'mod'"

testar_caso "Evento push roda sempre" \
  "push" "develop" 0 "evento 'push'" \
  "echo 'touch' > contrato/openapi.yaml && git add . && git commit --quiet -m 'mod'"

testar_caso "Execução local fora de CI roda" \
  "" "develop" 0 "execução local" \
  "echo 'touch' > contrato/openapi.yaml && git add . && git commit --quiet -m 'mod'"

echo
if [ "$falhas" -ne 0 ]; then
  echo "$falhas de $casos casos falharam."
  exit 1
fi
echo "Os $casos casos passaram."
