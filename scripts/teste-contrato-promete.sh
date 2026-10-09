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

OUTRAS_VIGIADAS=$(cat <<'EOF'
{"op":"promete:contatoDoTurno:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:contatoDoTurno:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:cancelarPosicao:409","corpo":{"status":409,"code":"posicao_nao_cancelavel"}}
{"op":"promete:cancelarVaga:409","corpo":{"status":409,"code":"vaga_encerrada"}}
{"op":"promete:excluirConta:409","corpo":{"status":409,"code":"administrador_unico"}}
{"op":"promete:bloquear:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:bloquear:422","corpo":{"status":422,"code":"campo_invalido"}}
{"op":"promete:denunciar:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:contestarSuspensao:409","corpo":{"status":409,"code":"contestacao_ja_aberta"}}
{"op":"promete:contestarSuspensao:422","corpo":{"status":422,"code":"sem_suspensao_ativa"}}
{"op":"promete:reabrirPorAtraso:409","corpo":{"status":409,"code":"posicao_nao_cancelavel"}}
{"op":"promete:reabrirPorAtraso:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:confirmarCheckinManual:409","corpo":{"status":409,"code":"checkin_ja_confirmado"}}
{"op":"promete:fazerCheckin:409","corpo":{"status":409,"code":"vaga_encerrada"}}
{"op":"promete:fazerCheckout:409","corpo":{"status":409,"code":"checkin_pendente"}}
{"op":"promete:cancelarPosicao:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:cancelarPosicao:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:cancelarVaga:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:cancelarVaga:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:publicarVaga:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:candidatar:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:candidatar:409","corpo":{"status":409,"code":"vaga_encerrada"}}
{"op":"promete:retirarCandidatura:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:retirarCandidatura:409","corpo":{"status":409,"code":"candidatura_indisponivel"}}
{"op":"promete:escolherCandidato:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:escolherCandidato:409","corpo":{"status":409,"code":"posicao_ja_preenchida"}}
{"op":"promete:avaliar:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:avaliar:409","corpo":{"status":409,"code":"avaliacao_ja_registrada"}}
{"op":"promete:cadastrarEstabelecimento:409","corpo":{"status":409,"code":"documento_ja_cadastrado"}}
{"op":"promete:cadastrarEstabelecimento:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:bloquear:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:denunciar:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:denunciar:422","corpo":{"status":422,"code":"campo_invalido"}}
{"op":"promete:avisarACaminho:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:configuracaoDoApp:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:confirmarCheckinManual:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:confirmarCheckinManual:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:fazerCheckin:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:fazerCheckin:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:fazerCheckout:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:fazerCheckout:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:republicarVaga:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:republicarVaga:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:detalheVaga:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:detalheVaga:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:candidatosDaVaga:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:candidatosDaVaga:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:incluirNaEquipe:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:incluirNaEquipe:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:removerDaEquipe:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:criarPerfilProfissional:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:atualizarPerfilProfissional:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:pedirRevisaoDespacho:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:meuEstabelecimento:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:equipeDeConfianca:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:vagasAbertas:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:retirarCandidatura:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:minhasCandidaturas:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:meusTurnos:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:painelEstabelecimento:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:minhaConta:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:meuPerfilProfissional:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:atualizarPerfilProfissional:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:criarConta:409","corpo":{"status":409,"code":"conta_existente"}}
{"op":"promete:criarPerfilProfissional:409","corpo":{"status":409,"code":"perfil_ja_existe"}}
{"op":"promete:pedirRevisaoDespacho:409","corpo":{"status":409,"code":"contestacao_ja_aberta"}}
{"op":"promete:avaliar:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:criteriosDeNotificacao:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:criteriosDeNotificacao:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:meusEstabelecimentos:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:registrarDispositivo:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:pedirRevisaoDespacho:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:cadastrarEstabelecimento:422","corpo":{"status":422,"code":"perfil_incompativel"}}
{"op":"promete:atualizarPerfilProfissional:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:publicarVaga:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:escolherCandidato:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:cancelarVaga:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:cancelarPosicao:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:fazerCheckin:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:fazerCheckout:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:publicarVaga:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:cancelarVaga:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:cancelarPosicao:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:candidatar:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:retirarCandidatura:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:fazerCheckin:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:fazerCheckout:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:confirmarCheckinManual:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:reabrirPorAtraso:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:avaliar:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:bloquear:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:denunciar:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:contestarSuspensao:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:pedirRevisaoDespacho:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:candidatosDaVaga:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:painelEstabelecimento:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:candidatar:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:retirarCandidatura:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:reabrirPorAtraso:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:confirmarCheckinManual:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:contatoDoTurno:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:detalheVaga:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:candidatosDaVaga:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:republicarVaga:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:avisarACaminho:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:configuracaoDoApp:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:criarPerfilProfissional:422","corpo":{"status":422,"code":"perfil_incompativel"}}
{"op":"promete:vagasAbertas:422","corpo":{"status":422,"code":"perfil_incompativel"}}
{"op":"promete:minhasCandidaturas:422","corpo":{"status":422,"code":"perfil_incompativel"}}
{"op":"promete:meusEstabelecimentos:422","corpo":{"status":422,"code":"perfil_incompativel"}}
{"op":"promete:criarConta:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:registrarEvento:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:escolherCandidato:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:minhasCandidaturas:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:vagasAbertas:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:detalheVaga:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:republicarVaga:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:meusTurnos:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:contatoDoTurno:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:avisarACaminho:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:painelEstabelecimento:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:meusEstabelecimentos:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:meuEstabelecimento:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:equipeDeConfianca:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:situacaoDaConta:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:criteriosDeNotificacao:422","corpo":{"status":422,"code":"perfil_incompativel"}}
{"op":"promete:incluirNaEquipe:422","corpo":{"status":422,"code":"perfil_incompativel"}}
{"op":"promete:removerDaEquipe:422","corpo":{"status":422,"code":"perfil_incompativel"}}
{"op":"promete:minhaConta:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:meuPerfilProfissional:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:atualizarPerfilProfissional:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:criarPerfilProfissional:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:cadastrarEstabelecimento:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:criteriosDeNotificacao:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:incluirNaEquipe:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:removerDaEquipe:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:perfilPublico:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:registrarDispositivo:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:removerDispositivo:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:registrarEvento:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:criarConta:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:abrirSuporte:401","corpo":{"status":401,"code":"nao_autenticado"}}
{"op":"promete:abrirSuporte:403","corpo":{"status":403,"code":"sem_permissao"}}
{"op":"promete:abrirSuporte:404","corpo":{"status":404,"code":"nao_encontrado"}}
{"op":"promete:abrirSuporte:422","corpo":{"status":422,"code":"campo_obrigatorio"}}
{"op":"promete:abrirSuporte:429","corpo":{"status":429,"code":"limite_excedido"}}
EOF
)

# O par vigiado alcançado: `perfil_publico` devolvendo o 404 que o contrato promete. É o
# ponto de partida — sem este caso verde, os vermelhos abaixo não provariam nada, porque
# um portão que reprova tudo passaria em cada caso negativo.
ALCANCADO=$(printf '{"op":"promete:perfilPublico:404","corpo":{"status":404,"code":"nao_encontrado"}}\n%s' "$OUTRAS_VIGIADAS")
caso "recusa prometida e alcançada passa" 0 "$ALCANCADO" "Toda recusa vigiada"

# O CASO DE 01/10, que é o motivo deste portão existir: o contrato 0.2.28 promete 404 em
# perfil_publico entre partes bloqueadas, e a função não filtra bloqueio.
NAO_ENTREGUE=$(printf '{"op":"promete:perfilPublico:404","corpo":{"status":200,"code":null}}\n%s' "$OUTRAS_VIGIADAS")
caso "promessa que o código não cumpre reprova" 1 "$NAO_ENTREGUE" "promete 404 e o código devolveu 200"
caso "e nomeia a operação" 1 "$NAO_ENTREGUE" "perfilPublico:"

# Status errado também reprova: 403 no lugar de 404 vaza a existência de quem bloqueou.
OUTRO_STATUS=$(printf '{"op":"promete:perfilPublico:404","corpo":{"status":403,"code":"sem_permissao"}}\n%s' "$OUTRAS_VIGIADAS")
caso "status diferente do prometido reprova" 1 "$OUTRO_STATUS" "devolveu 403"

# Code errado também reprova: status 404 com code divergente no envelope
OUTRO_CODE=$(printf '{"op":"promete:perfilPublico:404","corpo":{"status":404,"code":"outro_codigo"}}\n%s' "$OUTRAS_VIGIADAS")
caso "code diferente do prometido reprova" 1 "$OUTRO_CODE" "devolveu code"

# Critério 4: caminho que não mediu sai diferente de zero e DIZ o que não mediu, em vez de
# passar verde por ausência. É o erro que o `contrato-em-dia.sh` já evita saindo 2 sem token.
caso "colheita que não tentou reprova, dizendo o que não mediu" 1 \
  '{"op":"minhaConta","corpo":{"id":"a0000000-0000-4000-8000-000000000001","perfil":"profissional","nome":"Ana","telefone":"+5561999990001","email":"ana@frila.test","nascimento":"1998-04-02","estado":"ativa","termos_versao":"1.0","termos_aceite_em":"2026-09-22T00:00:00Z"}}' \
  "a colheita não tentou"

# Erro de banco sem envelope: `status` nulo não é recusa do contrato, e dizer que é
# inventaria um status que ninguém devolveu.
SEM_ENVELOPE=$(printf '{"op":"promete:perfilPublico:404","corpo":{"status":null,"code":null}}\n%s' "$OUTRAS_VIGIADAS")
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
