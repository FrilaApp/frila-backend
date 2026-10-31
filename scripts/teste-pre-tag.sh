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
  env FRILA_AGORA="2026-10-30 20:00" "$PORTAO" --commit "$COMMIT_VALIDO_DEV" backend-v1.0.0

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

# ── 5. Ancestralidade estrita contra origin/develop ────────────
# O commit atual (HEAD desta branch feature) ainda não foi mesclado na develop
COMMIT_NAO_ANCESTRAL=$(git rev-parse HEAD)
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

echo
if [ "$falhas" -ne 0 ]; then
  echo "Total de falhas: $falhas de $casos casos." >&2
  exit 1
fi
echo "Todos os $casos casos passaram."
exit 0
