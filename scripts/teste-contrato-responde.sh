#!/usr/bin/env bash
# O portão do corpo contra o contrato fecha nos casos conhecidos.
#
# Cartão `oCv0WPNY`. Um portão com furo aprova calado, e este é o portão que decide se a
# resposta que o iOS vai desserializar casa com o modelo que ele gerou. Ele roda antes de
# julgar o PR, como os outros dois autotestes deste repositório.
#
# Não precisa de Postgres: alimenta o validador com corpos sintéticos e confere o veredito.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PY=.venv-contrato/bin/python
[ -x "$PY" ] || PY=python3

falhas=0

# Toda colheita de mentira daqui leva também a recusa prometida que o `VIGIADAS` do
# validador vigia, porque o validador tem **duas** direções e um só código de saída: o
# corpo de sucesso, que é o que este autoteste mede, e a recusa que o contrato promete,
# que é do `teste-contrato-promete.sh`.
#
# Sem esta linha o validador reprova por promessa não medida, e os nove casos daqui
# passariam a medir a direção errada: os quatro que esperam 0 sairiam 1, e os cinco que
# esperam 1 sairiam 1 mesmo sem o defeito de corpo que cada um existe para provar — cinco
# casos decorativos, verdes com e sem a validação que eles vigiam. Medido em 02/10, ao
# fundir a `develop`.
PROMESSA_OK='{"op":"promete:perfilPublico:404","corpo":{"status":404}}'

# Roda o validador com uma colheita de mentira na entrada. Guarda a saída em `saida` e o
# código em `codigo`, as duas globais de propósito: `codigo=$(julga ...)` abriria subshell
# e a saída guardada lá dentro se perderia — medido, e o autoteste passava a reprovar
# todo caso que confere texto.
julga() {
  saida=$(printf '%s\n%s\n' "$PROMESSA_OK" "$1" | "$PY" scripts/contrato_responde.py 2>&1)
  codigo=$?
}

caso() {
  local nome="$1" esperado="$2" entrada="$3" trecho="${4:-}"
  julga "$entrada"
  if [ "$codigo" != "$esperado" ]; then
    echo "  ✗ $nome — saiu $codigo, esperado $esperado"
    falhas=$((falhas + 1))
    return
  fi
  if [ -n "$trecho" ] && ! grep -qF "$trecho" <<<"$saida"; then
    echo "  ✗ $nome — saiu $codigo, mas a mensagem não diz '$trecho'"
    falhas=$((falhas + 1))
    return
  fi
  echo "  ✓ $nome"
}

# Um corpo de `MeusDados` com os dezesseis campos que o contrato 0.2.33 declara. É o ponto de
# partida: sem este caso verde, os dois vermelhos abaixo não provariam nada — provariam
# apenas que o validador reprova tudo.
DEZESSEIS='{"op":"exportarMeusDados","corpo":{"gerado_em":"2026-09-29T14:00:00Z","conta":{"id":"a0000000-0000-4000-8000-000000000001","perfil":"profissional","nome":"Ana","telefone":"+5561999990001","email":"ana@frila.test","nascimento":"1998-04-02","estado":"ativa"},"perfil_profissional":null,"estabelecimentos":[],"disponibilidade":[],"turnos":[],"avaliacoes_dadas":[],"avaliacoes_recebidas":[],"dispositivos":[],"candidaturas":[],"ocorrencias":[],"bloqueios":[],"notificacoes":[],"despachos":[],"equipe_confianca":[],"pedido_de_exclusao":null}}'

echo "▸ O portão do corpo contra o contrato"

caso "corpo com os campos declarados passa" 0 "$DEZESSEIS"

# Campo a mais no JSON devolvido: o contrato não declara e o validador precisa acusar.
EXTRA=${DEZESSEIS%\}\}}',"campo_inventado_nao_declarado":true}}'
caso "campo que o contrato não declara reprova" 1 "$EXTRA" "campo_inventado_nao_declarado não está declarada"
caso "e nomeia a operação" 1 "$EXTRA" "exportarMeusDados:"

# O outro sentido, que é o que quebra cliente em produção: o modelo gerado espera o campo
# e ele some da resposta.
SEM_CONTA=$(printf '%s' "$DEZESSEIS" | "$PY" -c '
import json,sys
d=json.load(sys.stdin); d["corpo"].pop("conta"); print(json.dumps(d))')
caso "campo obrigatório que sumiu reprova" 1 "$SEM_CONTA" "conta"

# Tipo trocado: o contrato declara `turnos` como array.
TIPO=$(printf '%s' "$DEZESSEIS" | "$PY" -c '
import json,sys
d=json.load(sys.stdin); d["corpo"]["turnos"] = "nenhum"; print(json.dumps(d))')
caso "tipo que não bate reprova" 1 "$TIPO" "turnos"

# A Edge Function que responde 202, e não 200. Exigir 200 deixaria de fora justamente a
# operação que anonimiza conta.
DOIS_ZERO_DOIS='{"op":"excluirConta","corpo":{"perfil_removido_em":"2026-09-29T14:00:00Z","dados_apagados_ate":"2026-10-14","turnos_cancelados":2}}'
caso "operação que responde 202 é conferida" 0 "$DOIS_ZERO_DOIS"

DOIS_ZERO_DOIS_EXTRA=${DOIS_ZERO_DOIS%\}\}}',"segredo":"x"}}'
caso "e reprova com campo a mais" 1 "$DOIS_ZERO_DOIS_EXTRA" "segredo não está declarada"

# As que o portão não alcança saem nomeadas, com o motivo, em seção própria — e não
# misturadas com as que ainda não foram implementadas.
caso "declara o que não alcança, com o motivo" 0 "$DEZESSEIS" "Fora do alcance deste portão"
caso "e separa de quem só não foi implementada" 0 "$DEZESSEIS" "Ainda sem implementação"

echo
if [ "$falhas" -ne 0 ]; then
  echo "✗ $falhas caso(s) do portão não fecharam."
  exit 1
fi
echo "Os 9 casos passaram."
