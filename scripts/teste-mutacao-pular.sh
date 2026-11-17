#!/usr/bin/env bash
# Testa o decisor de pular/rodar a mutação (Mudança 1 da otimização de CI).
#
# Roda sem Postgres e sem rede, usando repositórios git temporários isolados.
#
# Casos cobertos:
#   1. PR que só toca no contrato pula (exit 10).
#   2. PR com migração roda (exit 0).
#   3. PR com teste pgTAP roda (exit 0).
#   4. PR com supabase/cenarios.sql roda (exit 0).
#   5. PR só com supabase/functions/ pula (exit 10).
#   6. PR com script de teste de mutação roda (exit 0).
#   7. CI com clone raso (depth 2) e PR só de contrato PULA a mutação (exit 10).
#   8. CI com clone raso (depth 2) e PR com cenarios.sql RODA a mutação (exit 0).
#   9. CI com clone raso (depth 2) e PR com supabase/functions/ PULA a mutação (exit 10).
#  10. CI com clone raso insuficiente (depth 1) cai na falha segura e RODA (exit 0).
#  11. Erro no diff ou base inexistente roda por falha segura (exit 0).
#  12. PR com git mv de teste para fora roda (--no-renames) (exit 0).
#  13. PR com caminho acentuado em migrações roda (core.quotePath=false) (exit 0).
#  14. Evento push roda sempre (exit 0).
#  15. Execução local fora de CI roda (exit 0).
#
#   ./scripts/teste-mutacao-pular.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DECISOR="$PWD/scripts/deve-rodar-mutacao.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

# Configura um git temporário com branch base ('develop') para testes locais
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

# Simula com precisão cirúrgica o runner do GitHub Actions:
# Um repositório remoto, um commit de merge sintético (refs/pull/X/merge)
# e checkout com profundidade específica (fetch-depth).
testar_clone_raso_merge() {
  local nome="$1"
  local profundidade="$2"
  local cmd_modificacao="$3"
  local codigo_esperado="$4"
  local texto_esperado="$5"

  casos=$((casos + 1))
  local repo_base="$TMP/remote_$casos.git"
  local repo_work="$TMP/work_$casos"
  local repo_ci="$TMP/ci_$casos"

  git init --bare --quiet "$repo_base"
  git clone --quiet "$repo_base" "$repo_work"
  (
    cd "$repo_work" || exit 1
    git config user.name "Tester"
    git config user.email "tester@frilabr.com"
    mkdir -p contrato supabase/migrations supabase/tests scripts
    touch contrato/openapi.yaml
    touch supabase/migrations/20260922150000_init.sql
    touch supabase/tests/010_base.sql
    cp "$DECISOR" scripts/deve-rodar-mutacao.sh
    git add .
    git commit --quiet -m "commit base"
    git branch -M develop
    git push --quiet origin develop

    # Criar branch do PR
    git checkout --quiet -b feature develop
    eval "$cmd_modificacao"
    git add .
    git commit --quiet -m "mudanca no PR"
    git push --quiet origin feature

    # Simular merge ref do GitHub Actions (refs/pull/1/merge)
    git checkout --quiet develop
    git merge --quiet --no-ff feature -m "Merge refs/pull/1/merge (synthetic)"
    git push --quiet origin develop:refs/pull/1/merge
  )

  # Simular runner do CI com a profundidade configurada (usando protocolo file:// para respeitar --depth)
  git clone --depth="$profundidade" --branch=develop --quiet "file://$repo_base" "$repo_ci"
  (
    cd "$repo_ci" || exit 1
    git fetch --depth="$profundidade" --quiet "file://$repo_base" refs/pull/1/merge:refs/remotes/pull/1/merge
    git checkout --quiet refs/remotes/pull/1/merge
  )

  local saida
  local codigo=0
  saida=$(
    cd "$repo_ci"
    GITHUB_EVENT_NAME="pull_request" GITHUB_BASE_REF="develop" ./scripts/deve-rodar-mutacao.sh 2>&1
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
  "pull_request" "develop" 10 "Mutação pulada" \
  "echo 'novo: 1' >> contrato/openapi.yaml && git add . && git commit --quiet -m 'so contrato'"

testar_caso "PR com migração roda a mutação" \
  "pull_request" "develop" 0 "Mutação vai rodar" \
  "touch supabase/migrations/20261112_nova.sql && git add . && git commit --quiet -m 'com migracao'"

testar_caso "PR com teste pgTAP roda a mutação" \
  "pull_request" "develop" 0 "Mutação vai rodar" \
  "touch supabase/tests/900_novo_teste.sql && git add . && git commit --quiet -m 'com teste'"

testar_caso "PR com supabase/cenarios.sql roda a mutação" \
  "pull_request" "develop" 0 "Mutação vai rodar: PR altera arquivos relevantes" \
  "echo '-- fixtures' >> supabase/cenarios.sql && git add . && git commit --quiet -m 'com cenarios'"

testar_caso "PR só com supabase/functions/ pula a mutação" \
  "pull_request" "develop" 10 "Mutação pulada" \
  "mkdir -p supabase/functions/push && echo 'console.log(1);' > supabase/functions/push/index.ts && git add . && git commit --quiet -m 'com functions'"

testar_caso "PR com script de teste de mutação roda a mutação" \
  "pull_request" "develop" 0 "Mutação vai rodar: PR altera arquivos relevantes" \
  "echo '# test' >> scripts/teste-mutacao-pular.sh && git add . && git commit --quiet -m 'com script teste'"

testar_clone_raso_merge "CI com clone raso (depth 2) e PR só de contrato PULA a mutação" \
  2 "echo 'novo' >> contrato/openapi.yaml" 10 "Mutação pulada"

testar_clone_raso_merge "CI com clone raso (depth 2) e PR com cenarios.sql RODA a mutação" \
  2 "echo '-- massa' >> supabase/cenarios.sql" 0 "Mutação vai rodar: PR altera arquivos relevantes"

testar_clone_raso_merge "CI com clone raso (depth 2) e PR com supabase/functions/ PULA a mutação" \
  2 "mkdir -p supabase/functions/auth && echo 'deno' > supabase/functions/auth/index.ts" 10 "Mutação pulada"

testar_clone_raso_merge "CI com clone raso insuficiente (depth 1) cai na falha segura e RODA" \
  1 "echo 'novo' >> contrato/openapi.yaml" 0 "falha segura"

testar_caso "Erro no diff ou base inexistente roda por falha segura" \
  "pull_request" "base_inexistente_xyz" 0 "falha segura" \
  "echo 'touch' > contrato/openapi.yaml && git add . && git commit --quiet -m 'mod'"

testar_caso "PR com git mv de teste para fora roda a mutação (--no-renames)" \
  "pull_request" "develop" 0 "Mutação vai rodar" \
  "mkdir -p docs/historico && git mv supabase/tests/010_base.sql docs/historico/010_base.sql && git commit --quiet -m 'move teste para fora'"

testar_caso "PR com caminho acentuado em migrações roda a mutação (core.quotePath=false)" \
  "pull_request" "develop" 0 "Mutação vai rodar" \
  "touch 'supabase/migrations/20261112000000_função.sql' && git add . && git commit --quiet -m 'migracao acentuada'"

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
