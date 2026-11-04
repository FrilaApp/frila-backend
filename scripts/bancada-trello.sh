#!/usr/bin/env bash
# A ponte do quadro do Trello para o log de fatos da Bancada.
#
#   ./scripts/bancada-trello.sh                      ontem e hoje
#   ./scripts/bancada-trello.sh --desde 2026-09-28   um intervalo
#   ./scripts/bancada-trello.sh --seco               mostra o que faria
#   ./scripts/bancada-trello.sh --todas-etiquetas    o quadro inteiro, não só Backend
#   ./scripts/bancada-trello.sh --autor Matheus      só as ações de uma pessoa
#
# A lógica mora em `bancada_trello.py`, do mesmo jeito que o portão do contrato mora em
# `contrato_responde.py`: shell para achar as coisas, Python para ler a API e decidir.
#
# O que este invólucro faz, e o `.py` não: achar o `.env`, avisar alto quando os hooks do
# vault estão desligados, e lembrar que publicar é do humano.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

[ -f .env ] || { echo "✗ .env ausente: as credenciais do Trello saem dele" >&2; exit 1; }

# Os hooks do vault ficam desligados sem avisar — `core.hooksPath` apontando para um
# caminho que não existe faz o git não rodar hook nenhum e não reclamar. Foi o que manteve
# o registro parado entre 10/09 e 23/09. Sem hook, o fato que esta ponte escreve nunca é
# commitado nem publicado, e o aviso tem de ser alto.
vault_de_aviso() {
  local v
  v="$(python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "scripts"))
from bancada_trello import achar_vault
try:
    print(achar_vault(None, os.getcwd()))
except SystemExit:
    print("")
PY
)"
  printf '%s' "$v"
}

VAULT="$(vault_de_aviso || true)"
if [ -n "$VAULT" ] && { [ -d "$VAULT/.git" ] || [ -n "$(git -C "$VAULT" rev-parse --show-toplevel 2>/dev/null)" ]; }; then
  raiz_git="$(git -C "$VAULT" rev-parse --show-toplevel 2>/dev/null || true)"
  hooks="$(git -C "$VAULT" config core.hooksPath 2>/dev/null || true)"
  if [ -z "$hooks" ] || [ ! -d "$raiz_git/$hooks" ]; then
    printf '  ⚠ Os hooks do vault não estão instalados (core.hooksPath: %s).\n' "${hooks:-vazio}" >&2
    printf '    Os fatos escritos agora não serão commitados nem publicados.\n' >&2
    printf '    Conserte com: (cd %s && ./scripts/bootstrap.sh)\n\n' "$VAULT" >&2
  fi
fi

exec python3 scripts/bancada_trello.py "$@"
