#!/usr/bin/env bash
# Operações do quadro do Frila, para o pipeline não depender de decorar ids.
#
#   ./scripts/trello.sh ver <shortLink>                  cartão + checklist
#   ./scripts/trello.sh lista <lista>                    cartões de uma lista
#   ./scripts/trello.sh pegar <shortLink> <pessoa>       atribui e move p/ Em andamento
#   ./scripts/trello.sh revisao <shortLink> <url-do-pr>  move p/ Revisão e comenta o PR
#   ./scripts/trello.sh concluir <shortLink>             marca a checklist e move p/ Concluído
#   ./scripts/trello.sh comentar <shortLink> <texto>
#
# Listas: leia-primeiro historias s0 s1 s2 s3 s4 v1.1 v1.2 andamento revisao teste concluido
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; source .env; set +a

K="key=$TRELLO_API_KEY&token=$TRELLO_TOKEN"
API=https://api.trello.com/1

lista_id() {
  case "$1" in
    leia-primeiro) echo 6ab2123d15358e7214aa8517 ;;
    historias)     echo 6ab2688a385c4f270078258e ;;
    s0)            echo 6ab2123d15358e7214aa8518 ;;
    s1)            echo 6ab2123d15358e7214aa8519 ;;
    s2)            echo 6ab26483c8d52254376a59bf ;;
    s3)            echo 6ab2648556632cfec34a1f00 ;;
    s4)            echo 6ab291e8522c3e72027c0bf4 ;;
    v1.1)          echo 6ab26489762f421c5b03a942 ;;
    v1.2)          echo 6ab264a73020ba7103cf22c1 ;;
    andamento)     echo 6ab2123d15358e7214aa851a ;;
    revisao)       echo 6ab2123d15358e7214aa851b ;;
    teste)         echo 6ab2123d15358e7214aa851c ;;
    concluido)     echo 6ab2123d15358e7214aa851d ;;
    *) echo "lista desconhecida: $1" >&2; exit 2 ;;
  esac
}

membro_id() {
  case "$1" in
    matheus|Matheus)   echo 68636029129db61ca183db5c ;;
    caue|Cauê|Caue)    echo 64f28978a598d134b994893d ;;
    jotape|joaopaulo)  echo 681b5ef590e25075f87af2a2 ;;
    julia|Júlia|Julia) echo 67251a6fb78cb5703f53bc32 ;;
    fabricio|Fabrício) echo "$(curl -s "$API/boards/$TRELLO_BOARD_ID/members?$K" \
                                | python3 -c "import json,sys;print(next(m['id'] for m in json.load(sys.stdin) if m['username']=='fabriciotosta3'))")" ;;
    *) echo "pessoa desconhecida: $1" >&2; exit 2 ;;
  esac
}

case "${1:?uso: trello.sh <comando> …}" in

  ver)
    curl -s "$API/cards/${2:?}?$K&checklists=all&fields=name,desc,idList,due,shortUrl" \
      | python3 -c '
import json,sys
c=json.load(sys.stdin)
print(c["name"]); print(c["shortUrl"]); print()
print(c["desc"]); print()
for cl in c.get("checklists",[]):
    print("##", cl["name"])
    for i in cl["checkItems"]:
        print("  [%s] %s" % ("x" if i["state"]=="complete" else " ", i["name"]))'
    ;;

  lista)
    curl -s "$API/lists/$(lista_id "${2:?}")/cards?$K&fields=name,shortUrl,labels,idMembers,due" \
      | python3 -c '
import json,sys
for c in json.load(sys.stdin):
    lb=",".join(l["name"] for l in c["labels"] if l["name"])
    # O shortUrl é https://trello.com/c/<id>: o id é o último pedaço, e não o
    # penúltimo, que é sempre a letra "c". Com [-2] toda linha saía com "c" na
    # coluna do id, e quem quisesse `ver` um cartão tinha de ir ao navegador.
    print("%-12s %s  [%s]" % (c["shortUrl"].split("/")[-1], c["name"], lb))'
    ;;

  pegar)
    curl -s -X POST "$API/cards/${2:?}/idMembers?$K" -d "value=$(membro_id "${3:?}")" >/dev/null || true
    curl -s -X PUT  "$API/cards/${2}?$K" -d "idList=$(lista_id andamento)" -d "pos=bottom" \
      | python3 -c 'import json,sys;c=json.load(sys.stdin);print("Em andamento:",c["name"])'
    ;;

  revisao)
    curl -s -X POST "$API/cards/${2:?}/actions/comments?$K" \
      --data-urlencode "text=PR aberto: ${3:?}" >/dev/null
    curl -s -X PUT "$API/cards/${2}?$K" -d "idList=$(lista_id revisao)" \
      | python3 -c 'import json,sys;c=json.load(sys.stdin);print("Revisão:",c["name"])'
    ;;

  concluir)
    # Marca todos os itens da checklist e move. Só chame depois que o revisor
    # aprovou: a regra do quadro é que quem confere marca.
    card="${2:?}"
    full=$(curl -s "$API/cards/$card?$K&checklists=all&fields=name")
    echo "$full" | python3 -c '
import json,sys
c=json.load(sys.stdin)
print(c["id"])
for cl in c.get("checklists",[]):
    for i in cl["checkItems"]:
        if i["state"]!="complete": print(i["id"])' | {
      read -r card_id
      while read -r item; do
        curl -s -X PUT "$API/cards/$card_id/checkItem/$item?$K" -d "state=complete" >/dev/null
      done
    }
    curl -s -X PUT "$API/cards/$card?$K" -d "idList=$(lista_id concluido)" \
      | python3 -c 'import json,sys;c=json.load(sys.stdin);print("Concluído:",c["name"])'
    ;;

  comentar)
    curl -s -X POST "$API/cards/${2:?}/actions/comments?$K" \
      --data-urlencode "text=${3:?}" >/dev/null && echo "comentado"
    ;;

  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
