#!/usr/bin/env bash
# O contrato nasce em FrilaApp/frila-docs e é espelhado aqui. Este script prova que o
# espelho não foi mexido e, quando tem acesso ao original, que não divergiu dele.
#
# Por que espelhar em vez de referenciar: os testes de contrato e a CI precisam do
# arquivo em disco, e uma cópia que ninguém confere vira uma segunda verdade.
#
# Duas verificações, e a diferença entre elas importa:
#
#   1. **Integridade local** — o espelho bate com o `openapi.yaml.sha256` commitado.
#      Pega a edição às escondidas no espelho. Roda sempre.
#   2. **Divergência do original** — o espelho bate com o arquivo em FrilaApp/frila-docs.
#      Pega o contrato que mudou lá e ninguém trouxe. Exige token, porque o
#      repositório é privado e o GITHUB_TOKEN do Actions não alcança outro repo.
#
# Sem token, a segunda não roda e o script **diz isso em voz alta** em vez de passar
# calado: verde sobre nada é pior que vermelho.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

espelho=contrato/openapi.yaml
soma=contrato/openapi.yaml.sha256
origem="https://api.github.com/repos/FrilaApp/frila-docs/contents/api/openapi.yaml?ref=main"

versao=$(sed -n 's/^  version: *//p' "$espelho" | head -1)

# ── 1. Integridade local ───────────────────────────────────────────────────────
if [ ! -f "$soma" ]; then
  echo "Falta $soma. Gere com:"
  echo "  shasum -a 256 $espelho | awk '{print \$1}' > $soma"
  exit 1
fi

atual=$(shasum -a 256 "$espelho" | awk '{print $1}')
gravada=$(tr -d '[:space:]' < "$soma")

if [ "$atual" != "$gravada" ]; then
  echo "O espelho do contrato foi alterado sem atualizar a soma."
  echo "  gravada: $gravada"
  echo "  atual:   $atual"
  echo
  echo "Se a mudança veio do repositório do Frila, traga o arquivo e regrave a soma."
  echo "Se você editou o espelho à mão: não edite. O contrato muda lá, num PR próprio."
  exit 1
fi

echo "Espelho íntegro: contrato $versao, sha256 $atual"

# ── 2. Divergência do original ─────────────────────────────────────────────────
token="${FRILA_DOCS_TOKEN:-${GH_TOKEN:-}}"

if [ -z "$token" ]; then
  echo
  echo "⚠  Original NÃO conferido: FrilaApp/frila-docs é privado e não há token."
  echo "   O espelho pode estar íntegro e mesmo assim atrasado em relação ao contrato."
  echo "   Para ligar: crie um PAT com leitura em FrilaApp/frila-docs e grave como o secret"
  echo "   FRILA_DOCS_TOKEN do repositório."
  exit 0
fi

tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL -H "Authorization: Bearer $token" \
       -H "Accept: application/vnd.github.raw" "$origem" -o "$tmp"; then
  echo
  echo "Token presente, mas não consegui ler o contrato em FrilaApp/frila-docs."
  echo "Confira se o PAT tem leitura de conteúdo nesse repositório."
  exit 1
fi

if diff -q "$tmp" "$espelho" >/dev/null; then
  echo "Espelho em dia com FrilaApp/frila-docs."
  exit 0
fi

echo
echo "O espelho divergiu do contrato em FrilaApp/frila-docs:"
diff -u "$espelho" "$tmp" | head -60
echo
echo "Se a mudança é intencional, traga o arquivo e regrave a soma:"
echo "  gh api repos/FrilaApp/frila-docs/contents/api/openapi.yaml \\"
echo "    -H 'Accept: application/vnd.github.raw' > $espelho"
echo "  shasum -a 256 $espelho | awk '{print \$1}' > $soma"
echo "Se o contrato é que precisa mudar, mude lá primeiro, num PR próprio."
exit 1
