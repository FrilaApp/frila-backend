#!/usr/bin/env bash
# Aviso por e-mail para os sócios, para um passo de pipeline não depender de ninguém
# estar olhando o terminal.
#
#   ./scripts/notificar-equipe.sh --assunto "Entrega no frila-dev" --corpo "develop em 3f3ec40"
#   ./scripts/notificar-equipe.sh --assunto "Teste" --corpo "oi" --dry-run
#   ./scripts/notificar-equipe.sh --assunto "Só para um" --corpo "oi" --para cauecarneiroc@gmail.com
#
# Destinatários padrão: Cauê, Jotapê e Fabrício. `--para` aceita repetição e lista
# separada por vírgula.
#
# A lógica mora em `notificar_equipe.py`: shell para achar as coisas, Python para falar o
# protocolo.
#
# O que este invólucro faz, e o `.py` não: achar a raiz do repositório, carregar o `.env`
# e dizer alto quando ele não existe — sem derrubar o pipeline por causa disso, porque um
# aviso que não sai não pode reprovar a entrega que ele ia anunciar.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

if [ -f .env ]; then
  # `set -a` exporta o que o `.env` declarar; o `.py` lê do ambiente, nunca do arquivo.
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
else
  printf '  ⚠ .env ausente: sem credencial de SMTP, o aviso não sai.\n' >&2
  printf '    Copie o .env.example e preencha SMTP_HOST, SMTP_USER, SMTP_PASS e SMTP_SENDER.\n' >&2
fi

exec python3 scripts/notificar_equipe.py "$@"
