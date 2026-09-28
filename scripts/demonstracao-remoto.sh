#!/usr/bin/env bash
# Põe a porta da revisão da App Store de pé num projeto remoto, e **mede** que ela subiu.
#
# É o que falta para o critério 1 do cartão `7gpPBgTH` valer onde o cartão manda: ele diz
# "no `frila-dev`", e até aqui a porta só existia na máquina. Três passos que sempre foram
# feitos à mão, na ordem errada mais de uma vez:
#
#   1. os segredos, por `supabase secrets set`
#   2. o deploy, por `supabase functions deploy entrar-demonstracao`
#   3. a conferência, pelo `demonstracao.sh` apontado ao remoto
#
# O terceiro é o que justifica o script existir. Segredo gravado e função no ar não provam
# que o revisor entra: na primeira vez que isto foi montado na máquina, a função subiu e
# respondeu 404 em tudo, porque os segredos tinham ido para o processo da CLI e não para o
# worker. Deploy sem conferência é esperança.
#
# ── Autenticação ──────────────────────────────────────────────────────────────────────
#
# Não precisa de `supabase login` interativo: a CLI aceita `SUPABASE_ACCESS_TOKEN` do
# ambiente, e o `.env` já tem a variável. O que ela precisa é de um token **válido** — em
# 25/09 o do `.env` respondia 401 na Management API, e é isso que o primeiro passo mede
# antes de tentar qualquer coisa. Token novo em
# https://supabase.com/dashboard/account/tokens
#
# ── Uso ───────────────────────────────────────────────────────────────────────────────
#
#   ./scripts/demonstracao-remoto.sh dev                      # frila-dev, segredos do .env.local
#   ./scripts/demonstracao-remoto.sh dev --segredos <arquivo>
#   ./scripts/demonstracao-remoto.sh dev --seco               # mostra o que faria
#
# `prod` existe e é recusado sem `EU_SEI_QUE_E_PRODUCAO=1`. O `demonstracao.sh` **grava**:
# ele percorre o ciclo da presença no turno semeado e gasta o teto de tentativas. No
# `frila-dev` isso é o que se quer; em produção é escrita em produção, e a decisão é de
# quem está lendo isto, não deste script.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; source .env; set +a

AMBIENTE="${1:?uso: demonstracao-remoto.sh <dev|prod> [--segredos <arquivo>] [--seco]}"
shift || true

ARQUIVO_SEGREDOS="supabase/functions/.env.local"
SECO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --segredos) ARQUIVO_SEGREDOS="${2:?--segredos precisa do arquivo}"; shift 2 ;;
    --seco)     SECO=1; shift ;;
    *) echo "opção desconhecida: $1" >&2; exit 2 ;;
  esac
done

falhou() { printf '  ✗ %s\n' "$1" >&2; exit 1; }
ok()     { printf '  ✓ %s\n' "$1"; }

case "$AMBIENTE" in
  dev)
    REF="${FRILA_DEV_PROJECT_REF:-}"
    URL_REMOTA="${FRILA_DEV_URL:-}"
    ANON_REMOTA="${FRILA_DEV_ANON_KEY:-}"
    SR_REMOTA="${FRILA_DEV_SERVICE_ROLE_KEY:-}"
    ;;
  prod)
    [ "${EU_SEI_QUE_E_PRODUCAO:-}" = "1" ] || falhou \
      "prod recusado. O demonstracao.sh grava: percorre o ciclo da presença no turno semeado e gasta o teto de tentativas. Se é isso mesmo, EU_SEI_QUE_E_PRODUCAO=1"
    REF="${FRILA_PROD_PROJECT_REF:-}"
    URL_REMOTA="${FRILA_PROD_URL:-}"
    ANON_REMOTA="${FRILA_PROD_ANON_KEY:-}"
    SR_REMOTA="${FRILA_PROD_SERVICE_ROLE_KEY:-}"
    ;;
  *) echo "ambiente desconhecido: $AMBIENTE (use dev ou prod)" >&2; exit 2 ;;
esac

for par in "REF:$REF" "URL:$URL_REMOTA" "ANON:$ANON_REMOTA" "SERVICE_ROLE:$SR_REMOTA"; do
  [ -n "${par#*:}" ] || falhou "falta ${par%%:*} do ambiente $AMBIENTE no .env"
done

echo "▸ O token de conta responde?"
#
# Primeiro de propósito: sem isto, `secrets set` falha com 401 depois de o script já ter
# impresso meia dúzia de linhas verdes, e quem lê culpa o passo errado.
status=$(curl -s -o /dev/null -w '%{http_code}' \
         -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN:-}" \
         https://api.supabase.com/v1/projects)
[ "$status" = "200" ] || falhou \
  "a Management API respondeu $status. Gere um token novo em https://supabase.com/dashboard/account/tokens e grave como SUPABASE_ACCESS_TOKEN no .env"
ok "Management API: 200"

echo "▸ O projeto $AMBIENTE é alcançável, e é o que o .env diz?"
nome=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
        "https://api.supabase.com/v1/projects/$REF" \
       | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("name",""))
except Exception: print("")')
[ -n "$nome" ] || falhou "o projeto $REF não respondeu — confira FRILA_${AMBIENTE^^}_PROJECT_REF"
ok "$REF é \"$nome\""

echo "▸ As migrações do remoto estão em dia com o main?"
#
# A porta pode subir com o banco atrás, e aí ela responde 200 e o revisor vê uma tela que
# não é a de hoje. O aviso não interrompe: aplicar migração é outro script, e misturar os
# dois esconderia qual dos dois falhou.
locais=$(find supabase/migrations -maxdepth 1 -name '*.sql' | wc -l | tr -d ' ')
remotas=$(curl -s -X POST -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
           -H 'Content-Type: application/json' \
           -d '{"query":"select count(*) as n from supabase_migrations.schema_migrations"}' \
           "https://api.supabase.com/v1/projects/$REF/database/query" \
          | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print(d[0]["n"] if isinstance(d, list) and d else "?")
except Exception: print("?")')
if [ "$remotas" = "$locais" ]; then
  ok "$remotas migrações no remoto, $locais no repositório"
else
  printf '  ⚠ %s migrações no remoto e %s no repositório.\n' "$remotas" "$locais" >&2
  printf '    A porta sobe de qualquer jeito, mas o banco está atrás. Depois disto:\n' >&2
  printf '      ./scripts/aplicar-remoto.sh %s\n' "$REF" >&2
fi

echo "▸ Os segredos"
[ -f "$ARQUIVO_SEGREDOS" ] || falhou "não achei $ARQUIVO_SEGREDOS"
set -a; source "$ARQUIVO_SEGREDOS"; set +a
: "${DEMONSTRACAO_EMAILS:?falta DEMONSTRACAO_EMAILS em $ARQUIVO_SEGREDOS}"
: "${DEMONSTRACAO_CODIGO:?falta DEMONSTRACAO_CODIGO em $ARQUIVO_SEGREDOS}"

# O `.env.exemplo` e a CI trazem códigos de mentira de propósito. Subir um deles para um
# projeto remoto é publicar a porta: o código está num arquivo versionado.
case "$DEMONSTRACAO_CODIGO" in
  troque-este-codigo|codigo-de-ci-sem-valor)
    falhou "DEMONSTRACAO_CODIGO é o valor de exemplo (\"$DEMONSTRACAO_CODIGO\"), que está em arquivo versionado. Use um código de verdade" ;;
esac
[ "${#DEMONSTRACAO_CODIGO}" -ge 8 ] || falhou \
  "DEMONSTRACAO_CODIGO tem ${#DEMONSTRACAO_CODIGO} caracteres. O teto de tentativas é 10 por 10 minutos, o que segura pouco contra um código curto que nunca expira"
ok "$(printf '%s' "$DEMONSTRACAO_EMAILS" | tr ',' '\n' | wc -l | tr -d ' ') endereço(s) declarado(s), e o código não é o de exemplo"

if [ -n "$SECO" ]; then
  echo
  echo "— seco: daqui para baixo nada seria escrito. O que rodaria:"
  echo "    supabase secrets set DEMONSTRACAO_EMAILS=… DEMONSTRACAO_CODIGO=… --project-ref $REF"
  echo "    supabase functions deploy entrar-demonstracao --project-ref $REF"
  echo "    SUPABASE_URL=$URL_REMOTA … ./scripts/demonstracao.sh"
  exit 0
fi

# `secrets set` recebe os valores pela linha de comando, então o `set -x` de quem estiver
# depurando vazaria o código. O subshell com +x é a garantia de que não vaza nem por
# acidente.
( set +x
  supabase secrets set \
    "DEMONSTRACAO_EMAILS=$DEMONSTRACAO_EMAILS" \
    "DEMONSTRACAO_CODIGO=$DEMONSTRACAO_CODIGO" \
    --project-ref "$REF" >/dev/null
) || falhou "supabase secrets set falhou"
ok "segredos gravados no $AMBIENTE"

echo "▸ O deploy"
supabase functions deploy entrar-demonstracao --project-ref "$REF" >/dev/null \
  || falhou "supabase functions deploy falhou"
ok "entrar-demonstracao no ar em $REF"

echo
echo "▸ A conferência, que é o motivo deste script"
echo
# O `demonstracao.sh` já é o portão: a porta, o que ela recusa, os dados semeados, o ciclo
# da presença inteiro e o teto. Apontado ao remoto, ele mede exatamente o que o critério 1
# do cartão pede. A `service_role` entra para ele poder zerar o registro de tentativas sem
# contêiner — sem isso, ele só podia ser medido uma vez por janela de dez minutos.
SUPABASE_URL="$URL_REMOTA" \
SUPABASE_ANON_KEY="$ANON_REMOTA" \
SUPABASE_SERVICE_ROLE_KEY="$SR_REMOTA" \
DB_CONTAINER=nenhum-no-remoto \
  ./scripts/demonstracao.sh

echo
echo "A porta da revisão está de pé no $AMBIENTE ($REF), e medida por HTTP."
