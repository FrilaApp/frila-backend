#!/usr/bin/env bash
# Testa a suíte de conferências do portão `scripts/pre-tag.sh`.
#
# Cobre os cenários essenciais:
#   1. Ausência de argumento de tag (exit 2)
#   2. Formato de tag inválido sem semver (exit 2)
#   3. Commit não ancestral de origin/develop (exit 1)
#   4. Tentativa dentro da janela proibida da RNF12 (exit 1)
#   5. Versão ausente no CHANGELOG (exit 1)
#   6. Cenário completo válido / fora da janela (exit 0)
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
  if [ "$codigo" = "$esperado" ] && printf '%s\n' "$saida" | grep -qF -- "$frase"; then
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

# ── 2. Janela de manutenção (RNF12) ───────────────────────────
COMMIT_BASE_DEV=$(git rev-parse origin/develop 2>/dev/null || git rev-parse develop 2>/dev/null || git rev-parse HEAD)

# Simula horário dentro da janela: sexta-feira 20h SP
conferir "tentativa dentro da janela proibida (sexta 20h) é bloqueada com exit 1" \
  1 "dentro da janela proibida" \
  env FRILA_AGORA="2026-10-30 20:00" "$PORTAO" --commit "$COMMIT_BASE_DEV" backend-v1.0.0

# ── 3. CHANGELOG ───────────────────────────────────────────────
# Cria changelog temporário sem a versão 9.9.9
FAKE_CHANGELOG="$TMP/CHANGELOG_SEM_VERSAO.md"
cat <<'EOF' > "$FAKE_CHANGELOG"
# Changelog
## [Não lançado]
## [1.0.0] - 2026-10-04
EOF

conferir "versão ausente no changelog sai com exit 1" \
  1 "CHANGELOG: versão [9.9.9] não encontrada" \
  env FRILA_AGORA="2026-11-02 10:00" "$PORTAO" --commit "$COMMIT_BASE_DEV" --changelog "$FAKE_CHANGELOG" backend-v9.9.9

# ── 4. Ancestralidade ─────────────────────────────────────────
# Cria um repositório git temporário para testar árvore de ancestralidade divergente
REPO_TESTE="$TMP/repo_teste"
mkdir -p "$REPO_TESTE"
(
  cd "$REPO_TESTE"
  git init --quiet -b develop
  git config user.email "teste@frila.app"
  git config user.name "Testador"
  echo "base" > base.txt
  git add base.txt && git commit -m "commit base" --quiet

  # Branch paralela divergente
  git checkout -b feature --quiet
  echo "feature" > feature.txt
  git add feature.txt && git commit -m "commit feature divergente" --quiet
)

COMMIT_DIVERGENTE=$(cd "$REPO_TESTE" && git rev-parse HEAD)
CHANGELOG_BOM="$TMP/CHANGELOG_BOM.md"
cat <<'EOF' > "$CHANGELOG_BOM"
# Changelog
## [1.0.0] - 2026-10-04
EOF

conferir "commit divergente que não está na develop reprova com exit 1" \
  1 "NÃO é ancestral de" \
  env FRILA_AGORA="2026-11-02 10:00" "$PORTAO" \
    --commit "$COMMIT_DIVERGENTE" \
    --base "develop" \
    --changelog "$CHANGELOG_BOM" \
    backend-v1.0.0

# ── 5. Caminho feliz completo ─────────────────────────────────
# Segunda-feira às 10h da manhã (fora da janela proibida da RNF12),
# commit ancestral de develop ($COMMIT_BASE_DEV), versão 1.0.0 documentada no CHANGELOG.md
conferir "caminho feliz passa com exit 0 fora da janela proibida" \
  0 "Todas as 5 conferências passaram com sucesso" \
  env FRILA_AGORA="2026-11-02 10:00" "$PORTAO" --commit "$COMMIT_BASE_DEV" backend-v1.0.0

echo
if [ "$falhas" -ne 0 ]; then
  echo "Total de falhas: $falhas de $casos casos." >&2
  exit 1
fi
echo "Todos os $casos casos passaram."
exit 0
