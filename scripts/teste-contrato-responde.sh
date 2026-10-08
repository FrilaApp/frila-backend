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
PROMESSA_OK=$(cat <<'EOF'
{"op":"promete:perfilPublico:404","corpo":{"status":404,"code":"nao_encontrado"}}
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
EOF
)

# Roda o validador com uma colheita de mentira na entrada. Guarda a saída em `saida` e o
# código em `codigo`, as duas globais de propósito: `codigo=$(julga ...)` abriria subshell
# e a saída guardada lá dentro se perderia — medido, e o autoteste passava a reprovar
# todo caso que confere texto.
julga() {
  saida=$(printf '%s\n%s\n' "$PROMESSA_OK" "$1" | "$PY" scripts/contrato_responde.py 2>&1)
  codigo=$?
}

julga_com_flags() {
  local flags="$1" entrada="$2"
  saida=$(printf '%s\n%s\n' "$PROMESSA_OK" "$entrada" | "$PY" scripts/contrato_responde.py $flags 2>&1)
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

caso_flags() {
  local flags="$1" nome="$2" esperado="$3" entrada="$4" trecho="${5:-}"
  julga_com_flags "$flags" "$entrada"
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

# Coleções vazias: o contrato declara o array, mas sem nenhum item colhido o schema dos
# itens não é exercitado. Por padrão o portão avisa alto; com --falhar-vazias ele reprova.
caso "coleção vazia emite aviso alto por padrão" 0 "$DEZESSEIS" "coleção(ões) declarada(s) colhida(s) vazia(s)"
caso_flags "--falhar-vazias" "coleção vazia reprova com --falhar-vazias" 1 "$DEZESSEIS" "coleção(ões) declarada(s) colhida(s) vazia(s)"

VAGA_COM_POSICAO='{"op":"publicarVaga","corpo":{"vaga_id":"00000000-0000-0000-0000-000000000001","posicoes":["00000000-0000-0000-0000-000000000002"]}}'
caso_flags "--falhar-vazias" "coleção exercitada passa com --falhar-vazias" 0 "$VAGA_COM_POSICAO" "Toda coleção declarada observada nas respostas foi exercitada"

echo
if [ "$falhas" -ne 0 ]; then
  echo "✗ $falhas caso(s) do portão não fecharam."
  exit 1
fi
echo "Os 12 casos passaram."
