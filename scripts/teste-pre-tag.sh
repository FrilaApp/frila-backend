#!/usr/bin/env bash
# Testa a suíte de conferências do portão `scripts/pre-tag.sh`.
#
# Cobre os cenários essenciais e as exigências da revisão técnica:
#   1. Ausência de argumento de tag (exit 2)
#   2. Formato de tag inválido sem semver (exit 2)
#   3. Sem HEAD silencioso: tag inexistente sem --commit falha (exit 2)
#   4. Ancestralidade estrita contra origin/develop (exit 1)
#   5. Tentativa dentro da janela proibida da RNF12 (exit 1)
#   6. CHANGELOG no commit alvo (exit 1 se o commit alvo não tiver a versão)
#   7. Passo 4 sem falso verde: falha se base main for inexistente (exit 2)
#   8. Passo 4: falha se migração de main for editada no commit alvo (exit 1)
#   9. Cenário completo válido / fora da janela (exit 0)
#
# Uso:
#   ./scripts/teste-pre-tag.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PORTAO="$PWD/scripts/pre-tag.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

conferir() { # conferir <descrição> <saída esperada> <frase esperada> <comando...>
  local desc="$1" esperado="$2" frase="$3"; shift 3
  local saida codigo
  saida=$("$@" 2>&1); codigo=$?
  casos=$((casos + 1))
  if [ "$codigo" = "$esperado" ] && printf '%s' "$saida" | grep -qF -- "$frase"; then
    echo "  ✓ $desc"
  else
    echo "  ✗ $desc: saiu $codigo (esperado $esperado), com frase procurada \"$frase\""
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Teste do portão pré-tag (scripts/pre-tag.sh)"

# ── 1. Argumentos e validação de formato ───────────────────────
conferir "falta de argumento de tag sai com código 2" \
  2 "Tag não informada" \
  "$PORTAO"

conferir "tag sem versão semântica sai com código 2" \
  2 "deve conter uma versão semântica" \
  "$PORTAO" "tag-invalida"

# ── 2. Sem HEAD silencioso ─────────────────────────────────────
conferir "tag inexistente sem --commit falha com código 2 (sem HEAD silencioso)" \
  2 "não encontrada como ref git" \
  "$PORTAO" "backend-v9.9.9-inexistente"

# Resolve commit válido da develop para os testes seguintes
COMMIT_VALIDO_DEV=$(git rev-parse origin/develop 2>/dev/null || git rev-parse develop 2>/dev/null || git rev-parse HEAD)

# ── 3. Janela de manutenção (RNF12) ───────────────────────────
conferir "tentativa dentro da janela proibida (sexta 20h) é bloqueada com exit 1" \
  1 "dentro da janela proibida" \
  env RNF12_ATIVA=1 FRILA_AGORA="2026-10-30 20:00" "$PORTAO" --commit "$COMMIT_VALIDO_DEV" backend-v1.0.0

# ── 4. CHANGELOG no commit alvo ────────────────────────────────
# Testa override onde a versão não existe
FAKE_CHANGELOG="$TMP/CHANGELOG_SEM_VERSAO.md"
cat <<'EOF' > "$FAKE_CHANGELOG"
# Changelog
## [Não lançado]
## [1.0.0] - 2026-10-04
EOF

conferir "versão ausente no changelog sai com exit 1" \
  1 "CHANGELOG: versão [9.9.9] não encontrada" \
  env FRILA_AGORA="2026-11-02 10:00" "$PORTAO" \
    --commit "$COMMIT_VALIDO_DEV" \
    --changelog "$FAKE_CHANGELOG" \
    backend-v9.9.9

# Testa que regex não aceita curinga no lugar dos pontos (ex: 1x0x0 vs 1.0.0)
FAKE_CHANGELOG_REGEX="$TMP/CHANGELOG_REGEX.md"
cat <<'EOF' > "$FAKE_CHANGELOG_REGEX"
# Changelog
## [1x0x0] - 2026-10-04
EOF

conferir "versão com caractere não-ponto (1x0x0) é rejeitada com exit 1 (P2-03 Lince)" \
  1 "CHANGELOG: versão [1.0.0] não encontrada" \
  env FRILA_AGORA="2026-11-02 10:00" "$PORTAO" \
    --commit "$COMMIT_VALIDO_DEV" \
    --changelog "$FAKE_CHANGELOG_REGEX" \
    backend-v1.0.0

# ── 5. Ancestralidade estrita contra origin/develop ────────────
# Fixture sintética: cria um commit órfão desconectado garantidamente NÃO ancestral
# de origin/develop, tornando o teste determinístico e independente da branch em que roda.
EMPTY_TREE=$(git hash-object -t tree -w /dev/null)
COMMIT_NAO_ANCESTRAL=$(git -c user.name="Teste" -c user.email="teste@frila.app" commit-tree "$EMPTY_TREE" -m "teste: commit fora da develop")
CHANGELOG_BOM="$TMP/CHANGELOG_BOM.md"
cat <<'EOF' > "$CHANGELOG_BOM"
# Changelog
## [1.0.0] - 2026-10-04
EOF

conferir "commit fora da develop reprova no passo 1 com exit 1" \
  1 "NÃO é ancestral de" \
  env FRILA_AGORA="2026-11-02 10:00" "$PORTAO" \
    --commit "$COMMIT_NAO_ANCESTRAL" \
    --changelog "$CHANGELOG_BOM" \
    backend-v1.0.0

# ── 6. Passo 4 sem falso verde (base main inválida ou migração editada) ──
conferir "base main inválida falha no passo 4 com código 2 (sem falso verde)" \
  2 "Impossível auditar imutabilidade" \
  env FRILA_AGORA="2026-11-02 10:00" "$PORTAO" \
    --commit "$COMMIT_VALIDO_DEV" \
    --main "branch-inexistente-xyz" \
    --changelog "$CHANGELOG_BOM" \
    backend-v1.0.0

# ── 7. Caminho feliz completo ─────────────────────────────────
conferir "caminho feliz passa com exit 0 fora da janela proibida" \
  0 "Todas as 5 conferências passaram com sucesso" \
  env FRILA_AGORA="2026-11-02 10:00" "$PORTAO" \
    --commit "$COMMIT_VALIDO_DEV" \
    --changelog "$CHANGELOG_BOM" \
    backend-v1.0.0

# ── 7b. RNF12 suspensa (decisão do Cauê, 08/11/2026) ──────────
# shellcheck disable=SC2329  # chamada pelo conferir, por nome
suspensa_sem_fora() {  # com a RNF12 suspensa, o passo 2 não pode dizer "fora da janela"
  local s c
  s=$(env -u RNF12_ATIVA FRILA_AGORA="2026-10-30 20:00" "$PORTAO" \
        --commit "$COMMIT_VALIDO_DEV" --changelog "$CHANGELOG_BOM" backend-v1.0.0 2>&1); c=$?
  printf '%s\n' "$s"
  if printf '%s' "$s" | grep -qF "fora da janela proibida"; then echo "disse 'fora da janela'"; return 9; fi
  return "$c"
}
conferir "RNF12 suspensa (padrão), sexta 20h: o passo 2 diz que a janela não foi conferida" \
  0 "[2/5] Janela RNF12: não conferida (RNF12 suspensa" \
  suspensa_sem_fora

conferir "RNF12_ATIVA=1 fora da janela: o passo 2 diz fora da janela proibida" \
  0 "[2/5] Janela RNF12: fora da janela proibida" \
  env RNF12_ATIVA=1 FRILA_AGORA="2026-11-02 10:00" "$PORTAO" \
    --commit "$COMMIT_VALIDO_DEV" \
    --changelog "$CHANGELOG_BOM" \
    backend-v1.0.0

# ── 8. Testes sintéticos de mutação (Sondas Lince P2-01 e P2-02) ────────
DIR_ORIGEM="$PWD"
REPO_SINTETICO="$TMP/repo_sintetico"
mkdir -p "$REPO_SINTETICO/scripts" "$REPO_SINTETICO/supabase/migrations"
cp "$PORTAO" "$REPO_SINTETICO/scripts/"
cp "$DIR_ORIGEM/scripts/janela-de-manutencao.sh" "$REPO_SINTETICO/scripts/"
(
  cd "$REPO_SINTETICO" || exit 1
  git init -q -b main
  git config user.email "testador@frilabr.com"
  git config user.name "Testador"
  echo "create table t1();" > supabase/migrations/20260901000000_t1.sql
  git add .
  git commit -q -m "feat: initial main"
  git checkout -q -b develop
  # Simula colisão no commit alvo da develop (duas migrações com mesmo timestamp)
  echo "create table c1();" > supabase/migrations/20261001000000_a.sql
  echo "create table c2();" > supabase/migrations/20261001000000_b.sql
  cat <<'EOF' > CHANGELOG.md
# Changelog
## [1.0.0] - 2026-10-04
EOF
  git add .
  git commit -q -m "feat: commit com colisao"
)

SHA_COLISAO=$(git -C "$REPO_SINTETICO" rev-parse HEAD)
cd "$REPO_SINTETICO" || exit 1
conferir "commit alvo com migrações colidentes reprova no passo 5 com exit 1 (P2-01 Lince)" \
  1 "colisão de versão encontrada no commit alvo" \
  env FRILA_AGORA="2026-11-02 10:00" "./scripts/pre-tag.sh" \
    --base "develop" \
    --main "main" \
    --commit "$SHA_COLISAO" \
    backend-v1.0.0
cd "$DIR_ORIGEM" || exit 1

# Simula edição de migração existente de main
REPO_MUTACAO="$TMP/repo_mutacao"
mkdir -p "$REPO_MUTACAO/scripts" "$REPO_MUTACAO/supabase/migrations"
cp "$PORTAO" "$REPO_MUTACAO/scripts/"
cp "$DIR_ORIGEM/scripts/janela-de-manutencao.sh" "$REPO_MUTACAO/scripts/"
(
  cd "$REPO_MUTACAO" || exit 1
  git init -q -b main
  git config user.email "testador@frilabr.com"
  git config user.name "Testador"
  echo "create table base();" > supabase/migrations/20260901000000_base.sql
  git add .
  git commit -q -m "feat: base main"
  git checkout -q -b develop
  # Edita a migração já existente em main
  echo "create table base_alterada();" > supabase/migrations/20260901000000_base.sql
  cat <<'EOF' > CHANGELOG.md
# Changelog
## [1.0.0] - 2026-10-04
EOF
  git add .
  git commit -q -m "fix: edicao proibida de migracao"
)

SHA_MUTACAO=$(git -C "$REPO_MUTACAO" rev-parse HEAD)
cd "$REPO_MUTACAO" || exit 1
conferir "commit alvo que edita migração de main reprova no passo 4 com exit 1 (P2-02 Lince)" \
  1 "migração já existente em main foi modificada ou removida" \
  env FRILA_AGORA="2026-11-02 10:00" "./scripts/pre-tag.sh" \
    --base "develop" \
    --main "main" \
    --commit "$SHA_MUTACAO" \
    backend-v1.0.0
cd "$DIR_ORIGEM" || exit 1

echo
if [ "$falhas" -ne 0 ]; then
  echo "Total de falhas: $falhas de $casos casos." >&2
  exit 1
fi
echo "Todos os $casos casos passaram."
exit 0
