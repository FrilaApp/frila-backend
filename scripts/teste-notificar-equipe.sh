#!/usr/bin/env bash
# O aviso por e-mail não derruba o pipeline, e não deixa passar uso errado.
#
# Roda sem rede e sem credencial, de propósito: todo caso força `SMTP_HOST` vazio no
# ambiente do filho. Um teste que achasse credencial no `.env` da máquina mandaria
# e-mail de verdade para os três sócios a cada rodada, e uma suíte que manda e-mail é
# uma suíte que ninguém roda duas vezes.
#
#   ./scripts/teste-notificar-equipe.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ALVO=scripts/notificar_equipe.py

falhas=0
ok()    { printf '  ✓ %s\n' "$1"; }
falha() { printf '  ✗ %s\n' "$1" >&2; falhas=$((falhas+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Chama o `.py` direto, e não o invólucro: o invólucro carrega o `.env` da máquina, e o
# teste precisa controlar o ambiente inteiro para não tocar em SMTP nenhum.
rodar() {
  local saida_arquivo="$TMP/saida"
  env -u SMTP_USER -u SMTP_PASS -u SMTP_TLS SMTP_HOST="" SMTP_SENDER="nao-responda@frila.app" \
    python3 "$ALVO" "$@" >"$saida_arquivo" 2>&1
  codigo=$?
  saida="$(cat "$saida_arquivo")"
  return 0
}

echo "=== Testes do aviso por e-mail para a equipe ==="

# ── 1. Ensaio: sai 0 e lista os destinatários padrão ──────────────────────────
echo "▸ 1. --dry-run sai 0 e lista os destinatários"
rodar --assunto "Entrega no frila-dev" --corpo "develop em c293dfc" --dry-run
[ "$codigo" -eq 0 ] && ok "código de saída 0" || falha "esperava 0, veio $codigo"
for esperado in cauecarneiroc@gmail.com joaopauloalbuquerque606@gmail.com fbtostadev@gmail.com; do
  case "$saida" in
    *"$esperado"*) ok "lista $esperado" ;;
    *) falha "não listou $esperado" ;;
  esac
done
case "$saida" in
  *"nada foi enviado"*) ok "diz que nada foi enviado" ;;
  *) falha "não avisou que o ensaio não envia" ;;
esac

# ── 2. Uso errado: sai 1 com a linha de uso ──────────────────────────────────
echo "▸ 2. sem assunto e sem corpo sai 1 com mensagem de uso"
rodar --corpo "só o corpo"
[ "$codigo" -eq 1 ] && ok "sem --assunto: código 1" || falha "sem --assunto: esperava 1, veio $codigo"
case "$saida" in
  *"uso: notificar-equipe.sh"*) ok "sem --assunto: imprime o uso" ;;
  *) falha "sem --assunto: não imprimiu o uso" ;;
esac

rodar --assunto "só o assunto"
[ "$codigo" -eq 1 ] && ok "sem --corpo: código 1" || falha "sem --corpo: esperava 1, veio $codigo"
case "$saida" in
  *"uso: notificar-equipe.sh"*) ok "sem --corpo: imprime o uso" ;;
  *) falha "sem --corpo: não imprimiu o uso" ;;
esac

rodar
[ "$codigo" -eq 1 ] && ok "sem argumento nenhum: código 1" || falha "sem argumento: esperava 1, veio $codigo"

# ── 3. Sem credencial, envio real sai 0 ──────────────────────────────────────
# É o caso que protege o pipeline: a máquina de quem não configurou o `.env` não pode
# reprovar a entrega por não ter conseguido anunciá-la.
echo "▸ 3. sem SMTP configurado, o envio real sai 0 sem enviar"
rodar --assunto "Entrega" --corpo "corpo qualquer"
[ "$codigo" -eq 0 ] && ok "código de saída 0" || falha "esperava 0, veio $codigo"
case "$saida" in
  *"SMTP não configurado"*) ok "explica que falta credencial" ;;
  *) falha "não explicou a falta de credencial" ;;
esac

# ── 4. --para substitui o padrão, por vírgula e por repetição ────────────────
echo "▸ 4. --para substitui os destinatários padrão"
rodar --assunto "A" --corpo "B" --para "um@exemplo.com,dois@exemplo.com" --dry-run
[ "$codigo" -eq 0 ] && ok "código de saída 0" || falha "esperava 0, veio $codigo"
case "$saida" in
  *um@exemplo.com*dois@exemplo.com*) ok "aceita lista por vírgula" ;;
  *) falha "não aceitou lista por vírgula" ;;
esac
case "$saida" in
  *cauecarneiroc@gmail.com*) falha "manteve o destinatário padrão depois de --para" ;;
  *) ok "não manda para o padrão quando --para foi dado" ;;
esac

# ── 5. Injeção de cabeçalho é recusada ───────────────────────────────────────
# Quem controla o texto do destinatário controlaria o `Bcc` se o `\n` passasse.
echo "▸ 5. quebra de linha no destinatário e no assunto é recusada"
rodar --assunto "A" --corpo "B" --para "$(printf 'x@y.com\nBcc: z@w.com')" --dry-run
[ "$codigo" -eq 1 ] && ok "destinatário com \\n: código 1" || falha "destinatário com \\n: esperava 1, veio $codigo"
# Esta carga passa pela contagem de `@` e só morre na recusa explícita de `\n`: sem ela,
# o endereço `x@dominio.com\nsegundo` seria aceito e viraria cabeçalho `To` extra. Medido:
# com a recusa de `\n` removida, o caso acima continuava verde e este fica vermelho.
rodar --assunto "A" --corpo "B" --para "$(printf 'x@dominio.com\nsegundo')" --dry-run
[ "$codigo" -eq 1 ] && ok "destinatário com \\n que tem um só @: código 1" || falha "destinatário com \\n que tem um só @: esperava 1, veio $codigo"
rodar --assunto "$(printf 'A\nBcc: z@w.com')" --corpo "B" --dry-run
[ "$codigo" -eq 1 ] && ok "assunto com \\n: código 1" || falha "assunto com \\n: esperava 1, veio $codigo"

echo
if [ "$falhas" -eq 0 ]; then
  echo "✓ todos os casos passaram"
  exit 0
fi
echo "✗ $falhas verificação(ões) falharam" >&2
exit 1
