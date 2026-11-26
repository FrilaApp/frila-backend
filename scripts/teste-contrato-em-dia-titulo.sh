#!/usr/bin/env bash
# Testa offline o reconhecimento do título da versão em `scripts/contrato-em-dia.sh` (caso 3).
#
# Sem rede e sem token: exercita `escolher_commit_versao` via `source` e o fluxo completo do
# caso 3 em repositório temporário com `curl` dublado.
#
#   ./scripts/teste-contrato-em-dia-titulo.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SCRIPT="$PWD/scripts/contrato-em-dia.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

gravar_commits_json() {
  local arquivo="$1"
  shift
  python3 - "$arquivo" "$@" <<'PY'
import json
import sys

arquivo = sys.argv[1]
pares = sys.argv[2:]
commits = []
for i in range(0, len(pares), 2):
    commits.append({"sha": pares[i], "commit": {"message": pares[i + 1]}})
with open(arquivo, "w", encoding="utf-8") as f:
    json.dump(commits, f, ensure_ascii=False)
PY
}

# caso_escolha <nome> <sha_esperado> <versao_buscada> <sha1> <msg1> [<sha2> <msg2> ...]
caso_escolha() {
  local nome="$1" esperado="$2" versao="$3"
  shift 3
  local json="$TMP/commits_${casos}.json"
  casos=$((casos + 1))
  gravar_commits_json "$json" "$@"

  local obtido codigo=0
  obtido=$(
    # shellcheck source=scripts/contrato-em-dia.sh
    source "$SCRIPT"
    escolher_commit_versao "$json" "$versao"
  ) || codigo=$?

  if [ "$codigo" -eq 0 ] && [ "$obtido" = "$esperado" ]; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperava sha='$esperado' (exit 0), veio sha='$obtido' (exit $codigo)"
    falhas=$((falhas + 1))
  fi
}

# caso_fluxo_offline <nome> <exit_esperado> <trecho_esperado> <titulo_commit_espelho>
caso_fluxo_offline() {
  local nome="$1" esperado="$2" trecho="$3" titulo="$4"
  local dir="$TMP/fluxo_${casos}"
  casos=$((casos + 1))

  mkdir -p "$dir/scripts" "$dir/contrato"
  cp "$SCRIPT" "$dir/scripts/contrato-em-dia.sh"
  printf 'openapi: 3.1.0\ninfo:\n  version: 0.2.116\n' > "$dir/contrato/openapi.yaml"
  shasum -a 256 "$dir/contrato/openapi.yaml" | awk '{print $1}' > "$dir/contrato/openapi.yaml.sha256"

  local json_hist="$dir/commits.json"
  gravar_commits_json "$json_hist" \
    "sha_main_117" "feat(openapi): avanca main (0.2.117, B-125)" \
    "sha_espelho_116" "$titulo"

  printf 'openapi: 3.1.0\ninfo:\n  version: 0.2.117\n' > "$dir/main.yaml"

  local saida codigo=0
  (
    FRILA_DOCS_TOKEN="token_mock_teste"
    export FRILA_DOCS_TOKEN
    # shellcheck disable=SC2329
    curl() {
      local out="" url=""
      while [ $# -gt 0 ]; do
        case "$1" in
          (-o) out="$2"; shift 2 ;;
          (-H) shift 2 ;;
          (-*) shift ;;
          (*) url="$1"; shift ;;
        esac
      done
      case "$url" in
        (*"contents/api/openapi.yaml?ref=main"*)
          cp "$dir/main.yaml" "$out" ;;
        (*"commits?path=api/openapi.yaml"*)
          cp "$json_hist" "$out" ;;
        (*"contents/api/openapi.yaml?ref=sha_espelho_116"*)
          cp "$dir/contrato/openapi.yaml" "$out" ;;
        (*)
          return 1 ;;
      esac
    }
    # shellcheck source=scripts/contrato-em-dia.sh
    source "$dir/scripts/contrato-em-dia.sh"
    main
  ) >"$dir/saida.txt" 2>&1 || codigo=$?
  saida=$(cat "$dir/saida.txt")

  if [ "$codigo" = "$esperado" ] && printf '%s\n' "$saida" | grep -qF "$trecho"; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperava exit $esperado com '$trecho', veio $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Portão: reconhecimento do título da versão em contrato-em-dia.sh"

# (a) Formatos aceitos
caso_escolha "(a1) formato (<v>, B-124)" "sha116" "0.2.116" \
  "sha116" "feat(openapi): atualiza RPC (0.2.116, B-124)"
caso_escolha "(a2) formato (<v>)" "sha116" "0.2.116" \
  "sha116" "feat(openapi): atualiza RPC (0.2.116)"
caso_escolha "(a3) formato ... <v>)" "sha116" "0.2.116" \
  "sha116" "feat(openapi): atualiza RPC (B-124, 0.2.116)"
caso_escolha "(a4) formato contrato <v>" "sha116" "0.2.116" \
  "sha116" "Atualiza contrato 0.2.116"
caso_escolha "(a5) formato para <v> (case-insensitive)" "sha116" "0.2.116" \
  "sha116" "Sobe espelho PARA 0.2.116"

# (b) Fronteira de versão: não pode casar substring nem prefixo/sufixo numérico
caso_escolha "(b1) 0.2.11 não casa com (<v>, B-124) de 0.2.116" "" "0.2.11" \
  "sha116" "feat: algo (0.2.116, B-124)"
caso_escolha "(b2) 0.2.11 não casa com (<v>) de 0.2.116" "" "0.2.11" \
  "sha116" "feat: algo (0.2.116)"
caso_escolha "(b3) 0.2.11 não casa com ... <v>) de 0.2.116" "" "0.2.11" \
  "sha116" "feat: algo ... 0.2.116)"
caso_escolha "(b4) 0.2.11 não casa com contrato 0.2.116" "" "0.2.11" \
  "sha116" "Atualiza contrato 0.2.116"
caso_escolha "(b5) 0.2.11 não casa com para 0.2.116" "" "0.2.11" \
  "sha116" "Atualiza para 0.2.116"

caso_escolha "(b6) 0.2.116 não casa com 0.2.1160" "" "0.2.116" \
  "s1" "feat: (0.2.1160, B-999)" \
  "s2" "feat: (0.2.1160)" \
  "s3" "feat: ... 0.2.1160)" \
  "s4" "Atualiza contrato 0.2.1160" \
  "s5" "Atualiza para 0.2.1160"

caso_escolha "(b7) 0.2.116 não casa com 10.2.116" "" "0.2.116" \
  "s1" "feat: (10.2.116, B-999)" \
  "s2" "feat: (10.2.116)" \
  "s3" "feat: ... 10.2.116)" \
  "s4" "Atualiza contrato 10.2.116" \
  "s5" "Atualiza para 10.2.116"

caso_escolha "(b8) versão só na segunda linha do commit não casa" "" "0.2.116" \
  "sha_corpo" $'feat: ajuste sem versão no título\n\nDetalhes (0.2.116, B-124)'

# (c) Lista com dois commits que casam: pega o primeiro (mais novo)
caso_escolha "(c) dois commits que casam: escolhe o primeiro (mais novo)" "sha_novo" "0.2.116" \
  "sha117" "feat: versão seguinte (0.2.117, B-125)" \
  "sha_novo" "fix: ajusta descrição (0.2.116, B-124)" \
  "sha_antigo" "feat: publica versão (0.2.116)"

# (d) Nenhum commit casa -> vazio (e script falha com exit 1)
caso_escolha "(d1) nenhum commit casa retorna vazio" "" "0.2.116" \
  "sha117" "feat: versão seguinte (0.2.117, B-125)" \
  "sha115" "feat: versão anterior (0.2.115, B-123)"

caso_fluxo_offline "(d2) fluxo completo caso 3 com (0.2.116, B-124) passa" 0 \
  "fiel à versão 0.2.116 de FrilaApp/frila-docs (commit sha_espelho_116)" \
  "feat(openapi): espelho (0.2.116, B-124)"

caso_fluxo_offline "(d3) fluxo completo caso 3 sem commit correspondente falha (exit 1)" 1 \
  "Não encontrei o commit da versão 0.2.116" \
  "feat(openapi): outra versão (0.2.115, B-123)"

echo
if [ "$falhas" -ne 0 ]; then
  echo "$falhas de $casos casos falharam."
  exit 1
fi
echo "Os $casos casos passaram."
