#!/usr/bin/env bash
# scripts/notificar-slack.sh
# Invólucro shell para envio de notificações ao canal Slack da equipe via Webhook.
# Cartões zYC0uhH2 e bB0tV5R8.
#
# Uso geral:
#   ./scripts/notificar-slack.sh --tipo ci_falha --branch develop --sha abc1234 --url https://...
#   ./scripts/notificar-slack.sh --tipo entrega --status aguardando --branch backend-v1.0.0
#   ./scripts/notificar-slack.sh --tipo backup_sucesso
#   ./scripts/notificar-slack.sh --checar-backup-30h
#   ./scripts/notificar-slack.sh --dry-run --titulo "Teste" --mensagem "Mensagem de ensaio"
#
# Comportamento com segredo ausente:
#   Se SLACK_WEBHOOK_URL não estiver configurado no ambiente nem no .env,
#   o script emite aviso no log (stderr) e encerra com código 0, sem quebrar o pipeline.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

exec python3 scripts/notificar_slack.py "$@"
