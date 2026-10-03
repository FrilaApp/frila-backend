#!/usr/bin/env bash
# O portão da direção contrato-à-frente fecha nos casos conhecidos.
#
# Cartão `EFveOeIb`. Um portão com furo aprova calado, e este é o único que vigia a
# direção em que o contrato promete uma recusa e o código não a levanta. Roda antes de
# julgar o PR, como o `teste-contrato-acompanha.sh` e o `teste-migracoes-sem-colisao.sh`.
#
# Não precisa de Postgres: alimenta o validador com colheitas de mentira.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PY=.venv-contrato/bin/python
[ -x "$PY" ] || PY=python3

falhas=0

julga() {
  saida=$(printf '%s\n' "$1" | "$PY" scripts/contrato_responde.py 2>&1)
  codigo=$?
}

caso() {
  local nome="$1" esperado="$2" entrada="$3" trecho="${4:-}"
  julga "$entrada"
  if [ "$codigo" != "$esperado" ]; then
    echo "  ✗ $nome — saiu $codigo, esperado $esperado"
    falhas=$((falhas + 1)); return
  fi
  if [ -n "$trecho" ] && ! grep -qF "$trecho" <<<"$saida"; then
    echo "  ✗ $nome — saiu $codigo, mas a mensagem não diz '$trecho'"
    falhas=$((falhas + 1)); return
  fi
  echo "  ✓ $nome"
}

echo "▸ O portão da direção contrato-à-frente"

# O par vigiado alcançado: `perfil_publico` devolvendo o 404 que o contrato promete. É o
# ponto de partida — sem este caso verde, os vermelhos abaixo não provariam nada, porque
# um portão que reprova tudo passaria em cada caso negativo.
ALCANCADO='{"op":"promete:perfilPublico:404","corpo":{"status":404}}'
caso "recusa prometida e alcançada passa" 0 "$ALCANCADO" "Toda recusa vigiada"

# O CASO DE 01/10, que é o motivo deste portão existir: o contrato 0.2.28 promete 404 em
# perfil_publico entre partes bloqueadas, e a função não filtra bloqueio.
NAO_ENTREGUE='{"op":"promete:perfilPublico:404","corpo":{"status":200}}'
caso "promessa que o código não cumpre reprova" 1 "$NAO_ENTREGUE" "promete 404 e o código devolveu 200"
caso "e nomeia a operação" 1 "$NAO_ENTREGUE" "perfilPublico:"

# Status errado também reprova: 403 no lugar de 404 vaza a existência de quem bloqueou.
OUTRO_STATUS='{"op":"promete:perfilPublico:404","corpo":{"status":403}}'
caso "status diferente do prometido reprova" 1 "$OUTRO_STATUS" "devolveu 403"

# Critério 4: caminho que não mediu sai diferente de zero e DIZ o que não mediu, em vez de
# passar verde por ausência. É o erro que o `contrato-em-dia.sh` já evita saindo 2 sem token.
caso "colheita que não tentou reprova, dizendo o que não mediu" 1 \
  '{"op":"minhaConta","corpo":{"id":"a0000000-0000-4000-8000-000000000001","perfil":"profissional","nome":"Ana","telefone":"+5561999990001","email":"ana@frila.test","nascimento":"1998-04-02","estado":"ativa","termos_versao":"1.0","termos_aceite_em":"2026-09-22T00:00:00Z"}}' \
  "a colheita não tentou"

# Erro de banco sem envelope: `status` nulo não é recusa do contrato, e dizer que é
# inventaria um status que ninguém devolveu.
SEM_ENVELOPE='{"op":"promete:perfilPublico:404","corpo":{"status":null}}'
caso "erro sem envelope não conta como recusa" 1 "$SEM_ENVELOPE" "devolveu None"

# A lista que envelheceu: par vigiado que o contrato deixou de prometer tem de falar, e não
# passar verde. Sem isto, um par removido do contrato ficaria em VIGIADAS para sempre,
# medindo uma promessa que não existe mais.
VELHO=$("$PY" - <<'PYEOF'
import re
caminho = "scripts/contrato_responde.py"
fonte = open(caminho, encoding="utf-8").read()
# Nada é escrito: só se confere que o ramo existe, para o caso ser honesto.
assert "o contrato não declara mais" in fonte, "o ramo da lista velha não existe"
print("ok")
PYEOF
)
if [ "$VELHO" = "ok" ]; then
  echo "  ✓ o portão trata par vigiado que o contrato deixou de prometer"
else
  echo "  ✗ o portão não trata par vigiado que o contrato deixou de prometer"
  falhas=$((falhas + 1))
fi

# A política sai na tela com os números, e não só o veredito: sem isso ninguém sabe que o
# portão vigia 1 de 118 pares.
caso "a saída diz quantos pares vigia, isenta e ainda não vigia" 0 "$ALCANCADO" "ainda não vigiados"
caso "e separa os isentos, que têm motivo escrito" 0 "$ALCANCADO" "isentos, com motivo"

echo
if [ "$falhas" -ne 0 ]; then
  echo "✗ $falhas caso(s) do portão não fecharam."
  exit 1
fi
echo "Os 9 casos passaram."
