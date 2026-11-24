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
      - name: ruim com event_name e ref no shell
        run: if [ "${{ github.event_name }}" = "push" ] && [ "${{ github.ref }}" = "refs/heads/main" ]; then ./x.sh; fi
      - name: ruim com a expressão quebrada em duas linhas
        run: |
          ./x.sh --branch "${{
            github.event.workflow_run.head_branch }}"
YML
saida="$(varrer "$TMP/bloco.yml")"; cod=$?
if [ "$cod" -eq 1 ] && [ "$(printf '%s\n' "$saida" | wc -l | tr -d ' ')" -eq 6 ]; then
  ok "6 ocorrências apontadas (bloco, head_ref e inputs, event_name e ref, expressão quebrada em duas linhas)"
else
  falha "esperava saída 1 com 6 ocorrências; veio $cod: $saida"
fi

echo "▸ 3. O que fica permitido: valores do evento por env: e segredo"
cat > "$TMP/bom.yml" <<'YML'
jobs:
  j:
    steps:
      - name: bom
        env:
          RAMO: ${{ github.event.workflow_run.head_branch }}
          EVENTO: ${{ github.event_name }}
          REF: ${{ github.ref }}
          TOKEN: ${{ secrets.X }}
        run: |
          if [ "$EVENTO" = "push" ] && [ "$REF" = "refs/heads/main" ]; then ./x.sh --branch="$RAMO"; fi
YML
if varrer "$TMP/bom.yml" >/dev/null; then
  ok "valores do evento por env: e segredo não são apontados"
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

echo "▸ 5. ci.yml: o passo da mutação recebe event_name e ref por env, e o job deste teste existe"
CI=.github/workflows/ci.yml
# shellcheck disable=SC2016
if grep -q '^          EVENTO: \${{ github.event_name }}' "$CI" && grep -q '^          REF: \${{ github.ref }}' "$CI"; then
  ok "EVENTO e REF passam por env no passo 'Os testes cobrem as regras'"
else
  falha "EVENTO/REF não passam por env em $CI"
fi
if grep -q 'run: ./scripts/teste-workflows-sem-interpolacao.sh' "$CI"; then
  ok "o ci.yml roda este teste (um job próprio)"
else
  falha "o ci.yml não roda scripts/teste-workflows-sem-interpolacao.sh: sem isso o teste só vale na máquina de quem lembrar"
fi

echo "=========================================================="
if [ "$falhas" -eq 0 ]; then
  echo "✓ Workflows sem interpolação de valor do evento no run:"
  exit 0
fi
echo "✗ $falhas falha(s)"
exit 1
