#!/usr/bin/env bash
# Roda um comando com novas tentativas e espera crescente (dobra a cada falha).
#
# Uso:
#   scripts/com-novas-tentativas.sh <comando> [argumentos...]
#
# Padrão: 4 tentativas, esperando 15 s, 30 s e 60 s entre elas. Passou em qualquer uma: sai 0.
# Falhou em todas: escreve uma mensagem clara e sai com o código da última falha (issue #545:
# uma falha de rede no apt derrubava o backup do dia).
#
# Variáveis:
#   COM_NOVAS_TENTATIVAS_MAX      total de tentativas (padrão 4)
#   COM_NOVAS_TENTATIVAS_ESPERA   espera antes da 2ª tentativa, em segundos (padrão 15)
#   COM_NOVAS_TENTATIVAS_DORMIR   programa que espera N segundos (padrão sleep; o teste troca)
#
# Comando com pipe ou redirecionamento: envolva num `bash -c '...'`.

set -Eeuo pipefail

max="${COM_NOVAS_TENTATIVAS_MAX:-4}"
espera="${COM_NOVAS_TENTATIVAS_ESPERA:-15}"
dormir="${COM_NOVAS_TENTATIVAS_DORMIR:-sleep}"

if [[ $# -eq 0 ]]; then
  echo "uso: $0 <comando> [argumentos...]" >&2
  exit 2
fi
if ! [[ "$max" =~ ^[1-9][0-9]*$ ]] || ! [[ "$espera" =~ ^[0-9]+$ ]]; then
  echo "ERRO: COM_NOVAS_TENTATIVAS_MAX deve ser inteiro >= 1 e COM_NOVAS_TENTATIVAS_ESPERA inteiro >= 0." >&2
  exit 2
fi

tentativa=1
while true; do
  rc=0
  "$@" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    exit 0
  fi
  if [[ "$tentativa" -ge "$max" ]]; then
    echo "ERRO: esgotou as $max tentativas (último código $rc): $*" >&2
    exit "$rc"
  fi
  echo "Tentativa $tentativa de $max falhou (código $rc): $1. Nova tentativa em ${espera}s." >&2
  "$dormir" "$espera"
  espera=$((espera * 2))
  tentativa=$((tentativa + 1))
done
