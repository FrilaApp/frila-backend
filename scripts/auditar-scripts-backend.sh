#!/usr/bin/env bash
# Auditoria estática de segurança e qualidade defensiva dos scripts de backend.
#
# Varre todos os scripts shell em `scripts/` verificando:
#   1. Permissão de execução executável (100755 / +x).
#   2. Tratamento estrito de variáveis não declaradas (set -u / set -euo pipefail).
#   3. Ausência de caminhos temporários fixos previsíveis em /tmp sem mktemp.
#   4. Ausência de credenciais, chaves privadas ou tokens hardcoded.
#   5. Proteção contra remoções recursivas inseguras (rm -rf com caminhos desprotegidos).
#   6. Conformidade estrita no ShellCheck (--severity=warning).
#
# Uso:
#   ./scripts/auditar-scripts-backend.sh [diretorio_scripts]
#
# Saída:
#   0 se todos os scripts forem aprovados; 1 se houver violações de segurança/qualidade.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${1:-$ROOT_DIR/scripts}"

if [[ ! -d "$SCRIPTS_DIR" ]]; then
  echo "ERRO: diretório de scripts '$SCRIPTS_DIR' não encontrado." >&2
  exit 1
fi

falhas=0
total_scripts=0

erro() {
  echo "  ✗ $1: $2" >&2
  falhas=$((falhas + 1))
}

ok() {
  echo "  ✓ $1"
}

echo "=== Auditoria de Segurança e Qualidade dos Scripts de Backend ==="
echo "Diretório avaliado: $SCRIPTS_DIR"
echo

# Coleta todos os scripts .sh
scripts=()
while IFS= read -r script_path; do
  scripts+=("$script_path")
done < <(find "$SCRIPTS_DIR" -maxdepth 2 -type f -name "*.sh" | sort)

total_scripts=${#scripts[@]}
if [[ "$total_scripts" -eq 0 ]]; then
  echo "AVISO: nenhum script .sh encontrado em $SCRIPTS_DIR."
  exit 0
fi

echo "▸ 1. Verificação de permissões de execução (+x)"
for s in "${scripts[@]}"; do
  nome_rel="${s#$ROOT_DIR/}"
  if [[ ! -x "$s" ]]; then
    erro "$nome_rel" "arquivo não possui permissão de execução (+x)"
  fi
done
if [[ "$falhas" -eq 0 ]]; then
  ok "Todos os $total_scripts scripts possuem permissão de execução (+x)"
fi

falhas_anterior=$falhas

echo "▸ 2. Verificação de tratamento de variáveis não declaradas (set -u / pipefail)"
for s in "${scripts[@]}"; do
  nome_rel="${s#$ROOT_DIR/}"
  # Procura por 'set -' contendo 'u' ou 'set -o nounset'
  if ! grep -qE 'set[[:space:]]+-[a-zA-Z]*u|set[[:space:]]+-o[[:space:]]+nounset' "$s"; then
    erro "$nome_rel" "falta proteção contra variáveis não declaradas (set -u / set -euo pipefail)"
  fi
done
if [[ "$falhas" -eq "$falhas_anterior" ]]; then
  ok "Todos os $total_scripts scripts possuem tratamento defensivo de variáveis não declaradas"
fi

falhas_anterior=$falhas

echo "▸ 3. Verificação contra arquivos temporários fixos inseguros em /tmp"
for s in "${scripts[@]}"; do
  nome_rel="${s#$ROOT_DIR/}"
  if [[ "$s" == *"auditar-scripts-backend.sh"* ]] || [[ "$s" == *"teste-auditar-scripts-backend.sh"* ]]; then
    continue
  fi
  # Busca por caminhos literais como /tmp/nome_fixo (ignora uso de mktemp ou variáveis como ${TMPDIR:-/tmp})
  linhas_vulneraveis=$(grep -nE '(\s|"|'\'')/tmp/[a-zA-Z0-9_\.-]+' "$s" | grep -vE 'mktemp|\$\{TMPDIR|\$TMPDIR|/tmp/frila-teste' || true)
  if [[ -n "$linhas_vulneraveis" ]]; then
    erro "$nome_rel" "uso de caminho temporário fixo inseguro em /tmp: $linhas_vulneraveis"
  fi
done
if [[ "$falhas" -eq "$falhas_anterior" ]]; then
  ok "Zero caminhos temporários fixos inseguros detectados"
fi

falhas_anterior=$falhas

echo "▸ 4. Verificação contra segredos ou tokens hardcoded"
for s in "${scripts[@]}"; do
  nome_rel="${s#$ROOT_DIR/}"
  # Não audita o próprio script de auditoria para evitar falso positivo nas strings de regex
  if [[ "$s" == *"auditar-scripts-backend.sh"* ]]; then
    continue
  fi
  # Verifica presença de tokens Supabase reais (sbp_[a-zA-Z0-9]{30,})
  if grep -nE 'sbp_[a-zA-Z0-9]{30,}' "$s" | grep -qvE 'sbp_dummy|sbp_exemplo|sbp_teste'; then
    erro "$nome_rel" "potencial token Supabase hardcoded detectado"
  fi
  # Verifica chaves privadas PEM
  padrao_chave="$(printf '%s %s %s' 'BEGIN' 'PRIVATE' 'KEY')"
  if grep -qF "$padrao_chave" "$s"; then
    erro "$nome_rel" "chave privada PEM hardcoded detectada"
  fi
  # Verifica JWTs reais (excluindo mocks de teste explicitamente nomeados)
  if grep -nE 'eyJh[a-zA-Z0-9_\.-]{40,}' "$s" | grep -qvE 'jwt_mock|token_mock|exemplo|teste|dummy'; then
    erro "$nome_rel" "potencial JWT de produção hardcoded detectado"
  fi
done
if [[ "$falhas" -eq "$falhas_anterior" ]]; then
  ok "Zero segredos ou chaves privadas hardcoded detectados"
fi

falhas_anterior=$falhas

echo "▸ 5. Verificação de remoções recursivas seguras (rm -rf protegido)"
for s in "${scripts[@]}"; do
  nome_rel="${s#$ROOT_DIR/}"
  if [[ "$s" == *"auditar-scripts-backend.sh"* ]] || [[ "$s" == *"teste-auditar-scripts-backend.sh"* ]]; then
    continue
  fi
  # Busca 'rm -rf /' ou 'rm -rf "$1"' desprotegido
  if grep -nE 'rm[[:space:]]+-[a-zA-Z]*r[a-zA-Z]*f?[[:space:]]+(/($|[[:space:]])|/\$|\"\$1\"|\$1\b)' "$s" >/dev/null; then
    erro "$nome_rel" "comando 'rm -rf' com caminho de alto risco ou desprotegido detectado"
  fi
done
if [[ "$falhas" -eq "$falhas_anterior" ]]; then
  ok "Comandos de remoção recursiva seguem padrões seguros e defensivos"
fi

falhas_anterior=$falhas

echo "▸ 6. Validação estrita via ShellCheck"
if command -v shellcheck >/dev/null 2>&1; then
  if ! shellcheck --severity=warning "${scripts[@]}"; then
    erro "ShellCheck" "encontrou alertas ou erros com severidade warning ou superior"
  else
    ok "ShellCheck aprovou todos os $total_scripts scripts sem alertas"
  fi
else
  echo "  ℹ ShellCheck não instalado no ambiente (ignorado)"
fi

echo
if [[ "$falhas" -gt 0 ]]; then
  echo "✗ Auditoria de scripts reprovada com $falhas violação(ões)." >&2
  exit 1
fi

echo "✓ Auditoria de scripts aprovada com 100% de conformidade ($total_scripts scripts verificados)."
exit 0
