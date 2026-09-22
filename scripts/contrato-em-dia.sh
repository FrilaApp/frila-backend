#!/usr/bin/env bash
# O contrato nasce em BlendOps/Frila e é espelhado aqui. Este script prova que o
# espelho não divergiu.
#
# Por que espelhar em vez de referenciar: os testes de contrato e a CI precisam do
# arquivo em disco, e uma cópia que ninguém confere vira uma segunda verdade.
set -euo pipefail

origem="https://raw.githubusercontent.com/BlendOps/Frila/main/Documentos/API/openapi.yaml"
local_="contrato/openapi.yaml"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if [ -n "${GH_TOKEN:-}" ]; then
  curl -fsSL -H "Authorization: Bearer $GH_TOKEN" "$origem" -o "$tmp"
else
  curl -fsSL "$origem" -o "$tmp"
fi

if diff -q "$tmp" "$local_" >/dev/null; then
  echo "Contrato em dia: $(grep -m1 '^  version:' "$local_" | tr -d ' ')"
  exit 0
fi

echo "O espelho divergiu do contrato em BlendOps/Frila:"
diff -u "$local_" "$tmp" | head -60
echo
echo "Se a mudança é intencional, traga o arquivo:"
echo "  curl -fsSL '$origem' -o '$local_'"
echo "Se o contrato é que precisa mudar, mude lá primeiro, num PR próprio."
exit 1
