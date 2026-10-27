#!/usr/bin/env bash
# O trabalho diário da ponte, num comando: commits do dia e quadro do dia para o vault.
#
# É o que o agendador chama. Rodando à mão, faz a mesma coisa:
#
#   ./scripts/bancada-ponte-diaria.sh              últimos 3 dias
#   ./scripts/bancada-ponte-diaria.sh --dias 30    recuperação maior
#   ./scripts/bancada-ponte-diaria.sh --seco
#
# Por que launchd local, e não um job de CI — três linhas, medidas em 27/10/2026:
#   1. O fato é escrito no working tree do vault, que existe nesta máquina; um runner da
#      GitHub Actions não tem o vault para escrever, e abrir um PR por dia com fato
#      gerado por robô trocaria um buraco por ruído.
#   2. As credenciais do Trello moram no `.env` local: `gh secret list` do
#      `frila-backend` devolve só `FRILA_DOCS_TOKEN`, então a CI não tem com que ler o
#      quadro sem alguém cadastrar segredos novos.
#   3. Publicar exige Touch ID, por decisão do vault. Um job que não pode publicar tem de
#      rodar onde a pessoa está, para avisá-la — e é isso que este script faz no fim.
#
# O que ele NÃO faz: `git push`, `git commit` no log e `SKIP_BIOMETRICS`. Ele deixa o fato
# no working tree e avisa. Quem publica é a pessoa, com `git push`, e é o `pre-push` do
# vault que commita o log.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DIAS=3
SECO=""
AUTOR="${BANCADA_AUTOR:-Matheus}"
while [ $# -gt 0 ]; do
  case "$1" in
    --dias)  DIAS="${2:?--dias exige um número}"; shift 2 ;;
    --autor) AUTOR="${2:?--autor exige um trecho do nome}"; shift 2 ;;
    --seco)  SECO="--seco"; shift ;;
    *) echo "opção desconhecida: $1" >&2; exit 2 ;;
  esac
done

DESDE="$(date -j -v-"${DIAS}"d +%Y-%m-%d)"
HOJE="$(date +%Y-%m-%d)"

echo "▸ Ponte diária da Bancada · $DESDE a $HOJE · autor ~ $AUTOR"
echo

VAULT="$(python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "scripts"))
from bancada_trello import achar_vault
print(achar_vault(None, os.getcwd()))
PY
)" || { echo "✗ vault não encontrado — nada foi escrito" >&2; exit 1; }

# Quantos fatos existiam antes, para o aviso dizer número e não impressão.
antes=$(grep -rh '^- `' "$VAULT/05 - Registros" 2>/dev/null | grep -c . || true)

echo "═══ 1. Commits do frila-backend"
./scripts/bancada-recuperar.sh --desde "$DESDE" --ate "$HOJE" --autor "$AUTOR" ${SECO:+--seco} || true

echo
echo "═══ 2. Quadro do Trello"
./scripts/bancada-trello.sh --desde "$DESDE" --ate "$HOJE" ${SECO:+--seco} || true

depois=$(grep -rh '^- `' "$VAULT/05 - Registros" 2>/dev/null | grep -c . || true)
novos=$((depois - antes))

echo
echo "═══ 3. O que falta de gente"
if [ "$novos" -gt 0 ]; then
  echo "  $novos fato(s) novo(s) no working tree do vault, ainda não publicados."
  echo "  Publique com:  (cd $VAULT && git push)   — o Touch ID é o portão, e é proposital."
  # Aviso na tela de quem está na máquina. `|| true` porque num agendador sem sessão
  # gráfica o osascript falha, e falhar em avisar não pode derrubar a ponte.
  osascript -e "display notification \"$novos fato(s) novo(s) esperando git push\" \
    with title \"Bancada\" subtitle \"ponte diária\"" >/dev/null 2>&1 || true
else
  echo "  Nenhum fato novo — dia sem registro é um dado, não um problema."
fi
echo
echo "  Fatos no acervo: $antes → $depois"
