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
#   2. **Divergência do original** — o espelho bate com a versão do contrato publicada
#      em FrilaApp/frila-docs. Se a main do frila-docs já avançou para versões posteriores
#      (outras fatias já mescladas), o script avisa mas aceita, desde que o espelho seja
#      idêntico à versão declarada no histórico de commits do frila-docs. Se divergir da
#      própria versão declarada ou estiver adiante da main, falha.
#
# Sem token, a segunda não roda e o script **diz isso em voz alta** em vez de passar
# calado: verde sobre nada é pior que vermelho.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

espelho=contrato/openapi.yaml
soma=contrato/openapi.yaml.sha256
origem_main="https://api.github.com/repos/FrilaApp/frila-docs/contents/api/openapi.yaml?ref=main"
commits_api="https://api.github.com/repos/FrilaApp/frila-docs/commits?path=api/openapi.yaml"

versao=$(sed -n 's/^  version: *//p' "$espelho" | head -1 | tr -d '[:space:]')

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
#
# O `.env` entra aqui, e não só o ambiente. Custou caro não ler: em 25/09 este portão saiu
# **0** em quatro baterias seguidas, avisando que não conferiu o original — e o token estava
# no `.env` todo esse tempo. Enquanto isso o espelho envelhecia da 0.2.15 para trás de uma
# 0.2.17 que já existia lá, e o único portão que pega isso era justamente o que estava
# passando. Os outros scripts do repositório leem o `.env`; este não lia.
# shellcheck source=/dev/null
if [ -f .env ]; then set -a; source .env; set +a; fi

token="${FRILA_DOCS_TOKEN:-${GH_TOKEN:-}}"

if [ -z "$token" ]; then
  echo
  echo "⚠  Original NÃO conferido: FrilaApp/frila-docs é privado e não há token."
  echo "   O espelho pode estar íntegro e mesmo assim atrasado em relação ao contrato."
  echo "   Para ligar: crie um PAT com leitura em FrilaApp/frila-docs, grave como o secret"
  echo "   FRILA_DOCS_TOKEN do repositório, e como FRILA_DOCS_TOKEN no .env local."
  echo
  echo "   Este caminho sai 2, e não 0: ele mediu a integridade do espelho e NÃO mediu a"
  echo "   divergência. A regra dos portões é que caminho que não mediu sai diferente de"
  echo "   zero — verde sobre metade da pergunta é o jeito mais barato de perder a outra"
  echo "   metade de vista."
  exit 2
fi

tmp_main=$(mktemp)
tmp_hist=$(mktemp)
tmp_json=$(mktemp)
trap 'rm -f "$tmp_main" "$tmp_hist" "$tmp_json"' EXIT

if ! curl -fsSL -H "Authorization: Bearer $token" \
       -H "Accept: application/vnd.github.raw" "$origem_main" -o "$tmp_main"; then
  echo
  echo "Token presente, mas não consegui ler o contrato na main de FrilaApp/frila-docs."
  echo "Confira se o PAT tem leitura de conteúdo nesse repositório."
  exit 1
fi

versao_main=$(sed -n 's/^  version: *//p' "$tmp_main" | head -1 | tr -d '[:space:]')

# Caso 1: O espelho declara a mesma versão da main
if [ "$versao" = "$versao_main" ]; then
  if diff -q "$tmp_main" "$espelho" >/dev/null; then
    echo "Espelho em dia com FrilaApp/frila-docs (versão $versao na main)."
    exit 0
  fi

  echo
  echo "O espelho divergiu do contrato $versao na main de FrilaApp/frila-docs:"
  diff -u "$espelho" "$tmp_main" | head -60 || true
  echo
  echo "Se a mudança é intencional, traga o arquivo e regrave a soma:"
  echo "  gh api repos/FrilaApp/frila-docs/contents/api/openapi.yaml \\"
  echo "    -H 'Accept: application/vnd.github.raw' > $espelho"
  echo "  shasum -a 256 $espelho | awk '{print \$1}' > $soma"
  echo "Se o contrato é que precisa mudar, mude lá primeiro, num PR próprio."
  exit 1
fi

# Caso 2: Versões diferentes. Se o espelho estiver ADIANTE da main, falha.
maior=$(printf '%s\n%s\n' "$versao" "$versao_main" | sort -V | tail -1)

if [ "$maior" = "$versao" ]; then
  echo
  echo "O espelho local está ADIANTE da main de FrilaApp/frila-docs ($versao > $versao_main)."
  echo "O contrato nasce em frila-docs e deve ser mesclado na main de lá primeiro."
  exit 1
fi

# Caso 3: A main do frila-docs avançou para versões posteriores ($versao_main > $versao).
# Comum em entregas por fatias: cada PR de backend espelha a sua versão do contrato.
echo
echo "Aviso: a main de FrilaApp/frila-docs está em $versao_main, e o espelho local declara $versao."
echo "Conferindo se o espelho bate com a versão $versao publicada no histórico do frila-docs..."

if ! curl -fsSL -H "Authorization: Bearer $token" \
       -H "Accept: application/vnd.github.v3+json" "$commits_api" -o "$tmp_json"; then
  echo "Não consegui consultar o histórico de commits do contrato em FrilaApp/frila-docs."
  exit 1
fi

commit_sha=$(python3 -c "
import json, sys
try:
    with open('$tmp_json') as f:
        commits = json.load(f)
    v = '$versao'
    sha = ''
    for c in commits:
        first_line = c.get('commit', {}).get('message', '').splitlines()[0]
        if f'({v})' in first_line or f'contrato {v}' in first_line.lower() or f'para {v}' in first_line.lower():
            sha = c.get('sha', '')
            break
    print(sha)
except Exception:
    sys.exit(1)
")

if [ -z "$commit_sha" ]; then
  echo "Não encontrei o commit da versão $versao no histórico recente de FrilaApp/frila-docs."
  echo "Verifique se a versão $versao foi commitada na main com a marca '($versao)' no título."
  exit 1
fi

url_versao="https://api.github.com/repos/FrilaApp/frila-docs/contents/api/openapi.yaml?ref=$commit_sha"

if ! curl -fsSL -H "Authorization: Bearer $token" \
       -H "Accept: application/vnd.github.raw" "$url_versao" -o "$tmp_hist"; then
  echo "Não consegui baixar a versão $versao (commit $commit_sha) de FrilaApp/frila-docs."
  exit 1
fi

if diff -q "$tmp_hist" "$espelho" >/dev/null; then
  echo "Espelho íntegro e fiel à versão $versao de FrilaApp/frila-docs (commit $commit_sha)."
  echo "Aviso: a main do frila-docs está em $versao_main (fatia posterior)."
  exit 0
fi

echo
echo "O espelho divergiu da versão $versao publicada em FrilaApp/frila-docs (commit $commit_sha):"
diff -u "$espelho" "$tmp_hist" | head -60 || true
echo
echo "Traga o arquivo da versão $versao e regrave a soma:"
echo "  gh api repos/FrilaApp/frila-docs/contents/api/openapi.yaml?ref=$commit_sha \\"
echo "    -H 'Accept: application/vnd.github.raw' > $espelho"
echo "  shasum -a 256 $espelho | awk '{print \$1}' > $soma"
exit 1
