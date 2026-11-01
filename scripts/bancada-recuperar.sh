#!/usr/bin/env bash
# Recupera o atraso do log de fatos: roda o `bancada-sync.sh` dia a dia num intervalo.
#
#   ./scripts/bancada-recuperar.sh --desde 2026-09-29                   até hoje
#   ./scripts/bancada-recuperar.sh --desde 2026-09-29 --ate 2026-10-26
#   ./scripts/bancada-recuperar.sh --desde 2026-10-01 --autor Matheus   só uma pessoa
#   ./scripts/bancada-recuperar.sh --desde 2026-10-01 --seco
#
# Por que existe
# --------------
# O `bancada-sync.sh` é por dia, por desenho: o fato sobre um commit pertence ao dia em
# que o commit foi feito. Quando a ponte fica parada — ficou de 28/09 a 27/10/2026 —
# recuperar o atraso exige chamá-lo uma vez por data, e fazer isso à mão é o que não
# aconteceu em 29 dias.
#
# Por que o filtro de autor
# -------------------------
# Medido em 27/10/2026: entre 29/09 e 26/10 havia 10 commits do Matheus e 154 de outras
# pessoas sem fato no log. Uma passagem sem filtro traz os 164 de uma vez, e o diário de
# cada um desses dias passa a ter fato de gente que não escreveu narrativa nenhuma ali.
# Com `--autor`, a recuperação fica do tamanho do que se quer registrar. Sem ele, o
# comportamento é o de sempre: todo mundo.
#
# Idempotência
# ------------
# Nenhuma: a idempotência é do `bancada-sync.sh`, que já pula commit cujo sha está no log
# (`ja_registrado`) e commit que é o mesmo trabalho depois de um rebase (`mesmo_trabalho`).
# Este laço só escolhe as datas.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DESDE=""; ATE="$(date +%Y-%m-%d)"; AUTOR=""; SECO=""; SO_COM_COMMIT=1

while [ $# -gt 0 ]; do
  case "$1" in
    --desde) DESDE="${2:?--desde exige AAAA-MM-DD}"; shift 2 ;;
    --ate)   ATE="${2:?--ate exige AAAA-MM-DD}"; shift 2 ;;
    --autor) AUTOR="${2:?--autor exige um trecho do nome}"; shift 2 ;;
    --seco)  SECO="--seco"; shift ;;
    --todos-os-dias) SO_COM_COMMIT=0; shift ;;
    *) echo "opção desconhecida: $1" >&2; exit 2 ;;
  esac
done

[ -n "$DESDE" ] || { echo "uso: bancada-recuperar.sh --desde AAAA-MM-DD [--ate AAAA-MM-DD] [--autor <nome>] [--seco]" >&2; exit 2; }

for d in "$DESDE" "$ATE"; do
  printf '%s' "$d" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
    || { echo "data em formato inesperado: $d (use AAAA-MM-DD)" >&2; exit 2; }
done

# O `date` do macOS não é o do GNU: `-v+1d` com `-j` é o caminho aqui, e `-d` falharia.
proximo_dia() { date -j -v+1d -f %Y-%m-%d "$1" +%Y-%m-%d; }

echo "▸ Recuperando de $DESDE a $ATE${AUTOR:+ · autor ~ $AUTOR}"
echo

dia="$DESDE"
dias=0; com_commit=0
while :; do
  # Pula a data sem commit nenhum do autor pedido: chamar a ponte nesses dias só criaria
  # a nota do dia a partir do modelo, e nota em branco de dia sem trabalho é ruído.
  if [ "$SO_COM_COMMIT" = 1 ]; then
    n=$(git log --branches --no-merges --format='%aI%x09%an' \
        | awk -F '\t' -v dia="$dia" -v autor="$AUTOR" \
            'substr($1,1,10)==dia && (autor=="" || index(tolower($2), tolower(autor))>0)' \
        | grep -c . || true)
    if [ "$n" -eq 0 ]; then
      dia=$(proximo_dia "$dia"); dias=$((dias+1))
      [ "$dia" \> "$ATE" ] && break
      continue
    fi
    com_commit=$((com_commit+1))
  fi

  echo "── $dia"
  BANCADA_AUTOR="$AUTOR" ./scripts/bancada-sync.sh ${SECO:+--seco} "$dia" \
    | sed -n '/^▸ Commits do backend/,/fato(s) novo(s)/p' | sed 's/^/   /'
  dias=$((dias+1))
  [ "$dia" = "$ATE" ] && break
  dia=$(proximo_dia "$dia")
  [ "$dia" \> "$ATE" ] && break
done

echo
echo "  $dias dia(s) percorrido(s), $com_commit com commit do filtro."
echo
echo "  O fato fica no working tree do vault. Publicar é do humano: o pre-push do vault"
echo "  exige Touch ID e é ele quem commita o log. Nunca use SKIP_BIOMETRICS."
