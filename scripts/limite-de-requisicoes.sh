#!/usr/bin/env bash
# O limite de requisições de escrita responde 429 `limite_excedido` (RNF07). Cartão kT7NhMGV.
#
# Por que por HTTP, e não em pgTAP. O limite é decidido no `pgrst.db_pre_request`, que é
# configuração do PostgREST: o pgTAP alcança a função e a janela, mas não prova que o
# PostgREST a chama antes de cada requisição, nem devolve o status. E uma recusa tem três
# eixos — `sqlstate`, `code` e status —, e o terceiro só a chamada por HTTP mede. O
# `460_limite_de_requisicoes.sql` cobre o que sobrevive dentro do banco; este arquivo cobre
# o resto.
#
# Saída:
#   0  mediu, e passou
#   1  mediu, e reprovou
#   2  NÃO mediu — pré-condição ausente. Nunca verde por omissão.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[ -f .env ] && { set -a; source .env; set +a; }

URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
DB="${DB_CONTAINER:-supabase_db_frila-backend}"

nao_medi() { printf '✗ NÃO MEDI: %s\n' "$1" >&2; exit 2; }
falhou()   { printf '  ✗ %s\n' "$1" >&2; ruim=1; }
passou()   { printf '  ✓ %s\n' "$1"; }
ruim=0

command -v docker >/dev/null 2>&1 || nao_medi "docker não está no PATH"
docker inspect -f '{{.State.Running}}' "$DB" 2>/dev/null | grep -q true \
  || nao_medi "o contêiner $DB não está de pé (supabase start)"
# `-sf` não serve aqui: sem apikey o PostgREST responde 401, que é resposta e não
# ausência, e o curl sairia diferente de zero. O que interessa é ter havido resposta HTTP.
codigo_rest=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL/rest/v1/" 2>/dev/null)
case "$codigo_rest" in
  ''|000) nao_medi "o PostgREST em $URL não respondeu" ;;
esac

psql_() { docker exec -e PGPASSWORD=postgres -i "$DB" psql -U postgres -d postgres -X -q -At "$@"; }

# O gancho tem de estar ligado. Sem ele o teto existiria no banco e ninguém o consultaria,
# e uma rajada passaria inteira — verde por omissão é exatamente o que este portão recusa.
ligado=$(psql_ -c "select count(*) from pg_db_role_setting s
                     join pg_roles r on r.oid = s.setrole, unnest(s.setconfig) c
                    where r.rolname = 'authenticator'
                      and c like 'pgrst.db_pre_request=privado.limitar_requisicoes'")
[ "${ligado:-0}" = "1" ] || nao_medi "pgrst.db_pre_request não aponta para privado.limitar_requisicoes"

teto=$(psql_ -c "select teto from privado.limite_requisicao where escopo = 'escrita'")
case "$teto" in ''|*[!0-9]*) nao_medi "não consegui ler o teto de privado.limite_requisicao" ;; esac

ANON="${SUPABASE_ANON_KEY:-}"
[ -n "$ANON" ] || ANON=$(supabase status -o env 2>/dev/null | sed -n 's/^ANON_KEY=//p' | tr -d '"')
[ -n "$ANON" ] || nao_medi "não achei a ANON_KEY (nem no .env, nem no supabase status)"

# A porta de demonstração tem teto de tentativas próprio, e medir duas vezes na mesma
# janela o gasta. Zerar o registro antes é o que o `demonstracao.sh` já faz, pelo mesmo
# motivo — sem isto, este portão reprova por causa do teto da porta e não do teto que ele
# veio medir.
docker exec -i "$DB" psql -U postgres -d postgres -q -c \
  'truncate public.entrada_demonstracao' >/dev/null 2>&1 \
  || nao_medi "não consegui zerar public.entrada_demonstracao; o teto da porta de demonstração ficaria no caminho"

# A sessão sai pela porta da demonstração, que já existe e não depende de caixa de e-mail.
sessao=$(curl -s -X POST "$URL/functions/v1/entrar-demonstracao" \
  -H "apikey: $ANON" -H "Authorization: Bearer $ANON" -H 'Content-Type: application/json' \
  -d "{\"email\":\"revisao-profissional@frila.app\",\"codigo\":\"${DEMONSTRACAO_CODIGO:-}\"}")
TOKEN=$(printf '%s' "$sessao" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('access_token','') or '')
except Exception: print('')")
[ -n "$TOKEN" ] || nao_medi "a porta de demonstração não abriu sessão (a Edge Function está servida, com DEMONSTRACAO_CODIGO?)"

printf '▸ Limite de escrita por conta: teto de %s por janela\n' "$teto"

# Zera a janela desta conta, para a medição não herdar contagem de execução anterior.
psql_ -c "delete from privado.contador_requisicao" >/dev/null

total=$(( teto + 10 ))
oks=0; recusas=0; outros=0; corpo=''
for i in $(seq 1 "$total"); do
  cod=$(curl -s -o /tmp/.limite_resp -w '%{http_code}' -X POST "$URL/rest/v1/rpc/registrar_dispositivo" \
    -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    -d "{\"token_fcm\":\"tok_portao_$(printf '%030d' "$i")\",\"plataforma\":\"ios\"}")
  case "$cod" in
    200|201) oks=$((oks+1)) ;;
    429)     recusas=$((recusas+1)); corpo=$(cat /tmp/.limite_resp) ;;
    *)       outros=$((outros+1)) ;;
  esac
done
rm -f /tmp/.limite_resp

printf '  %s aceitas · %s recusadas · %s outras, em %s tentativas\n' "$oks" "$recusas" "$outros" "$total"

[ "$outros" -eq 0 ] || falhou "$outros respostas fora de 200 e 429"
[ "$oks" -eq "$teto" ] && passou "exatamente $teto aceitas, que é o teto" \
  || falhou "aceitou $oks, e o teto é $teto"
[ "$recusas" -eq 10 ] && passou "as 10 acima do teto recusadas" \
  || falhou "recusou $recusas das 10 acima do teto"

# O código importa tanto quanto o status: o cliente compara `code`, não a mensagem.
printf '%s' "$corpo" | grep -q '"code":"limite_excedido"' \
  && passou "a recusa traz code limite_excedido, como o contrato declara" \
  || falhou "a recusa não traz code limite_excedido: $corpo"
printf '%s' "$corpo" | grep -q '"details":null' \
  && passou "details null, como components/responses/LimiteExcedido" \
  || falhou "details não é null: $corpo"

# Leitura não gasta o teto. Se gastasse, a conta que consultou vagas ficaria sem escrever.
leitura=$(curl -s -o /dev/null -w '%{http_code}' "$URL/rest/v1/rpc/vagas_abertas" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN")
[ "$leitura" = "200" ] && passou "leitura por GET continua em 200 com o teto de escrita estourado" \
  || falhou "leitura por GET devolveu $leitura"

psql_ -c "delete from privado.contador_requisicao" >/dev/null

if [ "$ruim" -ne 0 ]; then
  printf '\n✗ O limite de requisições não se comporta como o contrato declara.\n' >&2
  exit 1
fi
printf '\n✓ Limite de requisições medido por HTTP: %s aceitas, 10 recusadas com 429 limite_excedido, e a leitura intacta.\n' "$teto"
