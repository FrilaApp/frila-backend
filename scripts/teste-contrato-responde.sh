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

# Roda o validador com uma colheita de mentira na entrada. Guarda a saída em `saida` e o
# código em `codigo`, as duas globais de propósito: `codigo=$(julga ...)` abriria subshell
# e a saída guardada lá dentro se perderia — medido, e o autoteste passava a reprovar
# todo caso que confere texto.
julga() {
  saida=$(printf '%s\n' "$1" | "$PY" scripts/contrato_responde.py 2>&1)
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

# Um corpo de `MeusDados` com os nove campos que o contrato 0.2.27 declara. É o ponto de
# partida: sem este caso verde, os dois vermelhos abaixo não provariam nada — provariam
# apenas que o validador reprova tudo.
NOVE='{"op":"exportarMeusDados","corpo":{"gerado_em":"2026-09-29T14:00:00Z","conta":{"id":"a0000000-0000-4000-8000-000000000001","perfil":"profissional","nome":"Ana","telefone":"+5561999990001","email":"ana@frila.test","nascimento":"1998-04-02","estado":"ativa"},"perfil_profissional":null,"estabelecimentos":[],"disponibilidade":[],"turnos":[],"avaliacoes_dadas":[],"avaliacoes_recebidas":[],"dispositivos":[]}}'

echo "▸ O portão do corpo contra o contrato"

caso "corpo com os campos declarados passa" 0 "$NOVE"

# O CASO DE 01/10, que é o motivo deste portão existir: `privado.meus_dados` passou a
# devolver as sete coleções do PR #99 enquanto o contrato ainda declarava nove campos. Não
# havia portão que reclamasse — o `contrato-acompanha-o-codigo.sh` só dispara em função de
# `public`, e `meus_dados` é de `privado`.
DEZESSEIS=${NOVE%\}\}}',"candidaturas":[],"ocorrencias":[],"bloqueios":[],"notificacoes":[],"despachos":[],"equipe_confianca":[],"pedido_de_exclusao":null}}'
caso "campo que o contrato não declara reprova" 1 "$DEZESSEIS" "candidaturas não está declarada"
caso "e nomeia a operação" 1 "$DEZESSEIS" "exportarMeusDados:"

# O outro sentido, que é o que quebra cliente em produção: o modelo gerado espera o campo
# e ele some da resposta.
SEM_CONTA=$(printf '%s' "$NOVE" | "$PY" -c '
import json,sys
d=json.load(sys.stdin); d["corpo"].pop("conta"); print(json.dumps(d))')
caso "campo obrigatório que sumiu reprova" 1 "$SEM_CONTA" "conta"

# Tipo trocado: o contrato declara `turnos` como array.
TIPO=$(printf '%s' "$NOVE" | "$PY" -c '
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
caso "declara o que não alcança, com o motivo" 0 "$NOVE" "Fora do alcance deste portão"
caso "e separa de quem só não foi implementada" 0 "$NOVE" "Ainda sem implementação"

echo
if [ "$falhas" -ne 0 ]; then
  echo "✗ $falhas caso(s) do portão não fecharam."
  exit 1
fi
echo "Os 9 casos passaram."
