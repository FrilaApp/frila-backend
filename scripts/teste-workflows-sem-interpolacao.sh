#!/usr/bin/env bash
# scripts/teste-workflows-sem-interpolacao.sh
# Endurecimento dos workflows: valores do evento (branch, nome, SHA, URL, input) passam por `env:` e
# entram no comando como "$VAR", nunca interpolados no texto do `run:`.
#
# Uso: ./scripts/teste-workflows-sem-interpolacao.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

falhas=0
ok()    { echo "  ✓ $1"; }
falha() { echo "  ✗ $1"; falhas=$((falhas + 1)); }
varrer() { python3 -I scripts/verificar_interpolacao_workflows.py "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ 1. Nenhum workflow do repositório interpola valor do evento no run:"
shopt -s nullglob
ARQUIVOS=(.github/workflows/*.yml .github/actions/*/action.yml)
shopt -u nullglob
if saida="$(varrer "${ARQUIVOS[@]}")"; then
  ok "${#ARQUIVOS[@]} arquivos sem interpolação vetada no run:"
else
  falha "interpolação vetada: $saida"
fi

echo "▸ 2. O verificador pega a interpolação em bloco e em linha única (o teste pode falhar)"
cat > "$TMP/bloco.yml" <<'YML'
jobs:
  j:
    steps:
      - name: ruim em bloco
        run: |
          echo "ok"
          ./x.sh --branch "${{ github.event.workflow_run.head_branch }}"
      - name: ruim em linha
        run: echo "${{ github.head_ref }}" && echo "${{ inputs.mensagem }}"
      - name: ruim com a expressão quebrada em duas linhas
        run: |
          ./x.sh --branch "${{
            github.event.workflow_run.head_branch }}"
YML
saida="$(varrer "$TMP/bloco.yml")"; cod=$?
if [ "$cod" -eq 1 ] && [ "$(printf '%s\n' "$saida" | wc -l | tr -d ' ')" -eq 4 ]; then
  ok "4 ocorrências apontadas (bloco, head_ref e inputs na linha única, expressão quebrada em duas linhas)"
else
  falha "esperava saída 1 com 4 ocorrências; veio $cod: $saida"
fi

echo "▸ 3. O que fica permitido: env:, github.event_name e segredo"
cat > "$TMP/bom.yml" <<'YML'
jobs:
  j:
    steps:
      - name: bom
        env:
          RAMO: ${{ github.event.workflow_run.head_branch }}
          TOKEN: ${{ secrets.X }}
        run: |
          if [ "${{ github.event_name }}" = "push" ]; then ./x.sh --branch="$RAMO"; fi
YML
if varrer "$TMP/bom.yml" >/dev/null; then
  ok "env:, github.event_name e segredo não são apontados"
else
  falha "o verificador reprovou um workflow que passa os valores por env"
fi

echo "▸ 4. notifica-slack.yml: os 5 valores do workflow_run chegam por env e o comando usa \"\$VAR\""
WF=.github/workflows/notifica-slack.yml
for chave in WORKFLOW_NOME CONCLUSAO RAMO SHA_COMMIT URL_EXECUCAO; do
  if grep -q "^          $chave: \${{ github.event.workflow_run\." "$WF" && grep -q "=\"\$$chave\"" "$WF"; then
    ok "$chave via env e usado como \"\$$chave\""
  else
    falha "$chave não passa por env ou não é usado como \"\$$chave\" em $WF"
  fi
done

echo "=========================================================="
if [ "$falhas" -eq 0 ]; then
  echo "✓ Workflows sem interpolação de valor do evento no run:"
  exit 0
fi
echo "✗ $falhas falha(s)"
exit 1
