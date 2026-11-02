#!/usr/bin/env bash
# Autoteste automatizado de scripts/auditar-scripts-backend.sh
#
# Valida que o auditor de scripts:
#   1. Aprova o diretório real com exit 0.
#   2. Detecta e reprova com exit 1 fixtures sintéticas contendo violações:
#      - Script sem permissão de execução (+x)
#      - Script sem tratamento defensivo de variáveis (falta set -u)
#      - Script usando caminho temporário fixo inseguro em /tmp sem mktemp
#      - Script contendo segredo/token hardcoded
#      - Script com comando rm -rf desprotegido
#
# Uso:
#   ./scripts/teste-auditar-scripts-backend.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUDITOR="$ROOT_DIR/scripts/auditar-scripts-backend.sh"

[[ -x "$AUDITOR" ]] || { echo "ERRO: auditor '$AUDITOR' não encontrado ou sem +x." >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/frila-teste-auditor.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM

casos=0
falhas=0

conferir() {
  local desc="$1" esperado="$2" frase="$3"
  shift 3
  casos=$((casos + 1))
  local saida codigo
  set +e
  saida=$("$@" 2>&1)
  codigo=$?
  set -e
  if [[ "$codigo" -eq "$esperado" ]] && printf '%s' "$saida" | grep -qF -- "$frase"; then
    echo "  ✓ $desc"
  else
    echo "  ✗ $desc: saiu $codigo (esperado $esperado)" >&2
    printf '%s\n' "$saida" | sed 's/^/      /' >&2
    falhas=$((falhas + 1))
  fi
}

echo "=== Autoteste do Auditor de Scripts de Backend ==="

# 1. Caso nominal contra o repositório real
conferir "execução nominal no repositório passa com 100% de conformidade" \
  0 "Auditoria de scripts aprovada com 100% de conformidade" \
  "$AUDITOR" "$ROOT_DIR/scripts"

# Prepara pasta de fixture sintética para testar as detecções de violação
FIXTURE="$TMP/scripts_fixture"
mkdir -p "$FIXTURE"

criar_script_valido() {
  local path="$1"
  cat <<'EOF' > "$path"
#!/usr/bin/env bash
set -euo pipefail
TMP_ARQ=$(mktemp)
echo "ok" > "$TMP_ARQ"
rm -f "$TMP_ARQ"
EOF
  chmod +x "$path"
}

# 2. Violação: script sem +x
mkdir -p "$FIXTURE/caso1"
criar_script_valido "$FIXTURE/caso1/script.sh"
chmod -x "$FIXTURE/caso1/script.sh"
conferir "script sem permissão de execução reprova com exit 1" \
  1 "não possui permissão de execução (+x)" \
  "$AUDITOR" "$FIXTURE/caso1"

# 3. Violação: script sem set -u
mkdir -p "$FIXTURE/caso2"
cat <<'EOF' > "$FIXTURE/caso2/sem_set_u.sh"
#!/usr/bin/env bash
set -e
echo "teste"
EOF
chmod +x "$FIXTURE/caso2/sem_set_u.sh"
conferir "script sem set -u reprova com exit 1" \
  1 "falta proteção contra variáveis não declaradas" \
  "$AUDITOR" "$FIXTURE/caso2"

# 4. Violação: caminho fixo em /tmp sem mktemp
mkdir -p "$FIXTURE/caso3"
cat <<'EOF' > "$FIXTURE/caso3/tmp_fixo.sh"
#!/usr/bin/env bash
set -euo pipefail
echo "dado" > /tmp/meu_arquivo_inseguro.txt
EOF
chmod +x "$FIXTURE/caso3/tmp_fixo.sh"
conferir "script com caminho fixo em /tmp reprova com exit 1" \
  1 "uso de caminho temporário fixo inseguro em /tmp" \
  "$AUDITOR" "$FIXTURE/caso3"

# 5. Violação: token hardcoded
mkdir -p "$FIXTURE/caso4"
cat <<'EOF' > "$FIXTURE/caso4/token_hardcoded.sh"
#!/usr/bin/env bash
set -euo pipefail
TOKEN="sbp_123456789012345678901234567890123456"
echo "$TOKEN"
EOF
chmod +x "$FIXTURE/caso4/token_hardcoded.sh"
conferir "script com token Supabase hardcoded reprova com exit 1" \
  1 "potencial token Supabase hardcoded detectado" \
  "$AUDITOR" "$FIXTURE/caso4"

# 6. Violação: rm -rf desprotegido
mkdir -p "$FIXTURE/caso5"
cat <<'EOF' > "$FIXTURE/caso5/rm_inseguro.sh"
#!/usr/bin/env bash
set -euo pipefail
rm -rf /
EOF
chmod +x "$FIXTURE/caso5/rm_inseguro.sh"
conferir "script com comando 'rm -rf /' reprova com exit 1" \
  1 "comando 'rm -rf' com caminho de alto risco" \
  "$AUDITOR" "$FIXTURE/caso5"

echo
if [[ "$falhas" -gt 0 ]]; then
  echo "✗ $falhas de $casos casos falharam." >&2
  exit 1
fi

echo "✓ Todos os $casos casos do autoteste passaram com sucesso."
exit 0
