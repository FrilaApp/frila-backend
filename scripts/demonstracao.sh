#!/usr/bin/env bash
# A porta de demonstração da revisão da App Store, por HTTP, como o revisor faria:
#
#   entrar-demonstracao → vagas_abertas → meus_turnos → contato_do_turno
#
# Existe pelo mesmo motivo do `ciclo-completo.sh`: o pgTAP roda dentro do banco e não
# prova que a Edge Function está no ar, que ela devolve o schema `Sessao` do contrato,
# nem que o status é o que o contrato promete. Aqui, prova.
#
# Os três critérios de aceite do cartão `7gpPBgTH` que dependem de código estão medidos
# neste arquivo. O quarto — as notas anexadas ao cartão — não é código.
#
# Uso:  ./scripts/demonstracao.sh
#
# Precisa da função servida, com os segredos:
#   supabase functions serve --env-file supabase/functions/.env.local
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -f .env ] && { set -a; source .env; set +a; }
[ -f supabase/functions/.env.local ] && { set -a; source supabase/functions/.env.local; set +a; }

URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
ANON="${SUPABASE_ANON_KEY:-}"
[ -z "$ANON" ] && ANON=$(supabase status -o env 2>/dev/null | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')

if [ -z "$ANON" ]; then
  echo "Sem SUPABASE_ANON_KEY e sem 'supabase status'. Suba o ambiente: supabase start" >&2
  exit 1
fi

CODIGO="${DEMONSTRACAO_CODIGO:-}"
EMAILS="${DEMONSTRACAO_EMAILS:-}"
if [ -z "$CODIGO" ] || [ -z "$EMAILS" ]; then
  echo "Sem DEMONSTRACAO_CODIGO/DEMONSTRACAO_EMAILS. Copie supabase/functions/.env.exemplo" >&2
  echo "para supabase/functions/.env.local e sirva a função com --env-file." >&2
  exit 1
fi

CONTRATANTE="${EMAILS%%,*}"
PROFISSIONAL="${EMAILS##*,}"
PORTA="$URL/functions/v1/entrar-demonstracao"

ok()    { printf '  ✓ %s\n' "$1"; }
falhou(){ printf '  ✗ %s\n' "$1" >&2; exit 1; }

# Devolve "<status>\n<corpo>". O status entra na conferência junto com o `code`: uma
# recusa tem três eixos e conferir dois não basta.
chamar() { # chamar <url> <json> [token]
  local token="${3:-$ANON}"
  curl -s -w '\n%{http_code}' -X POST "$1" \
    -H "apikey: $ANON" -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' -d "$2"
}

status_de() { printf '%s' "$1" | tail -1; }
corpo_de()  { printf '%s' "$1" | sed '$d'; }

campo() { # campo <json> <chave>
  printf '%s' "$1" | python3 -c "
import json,sys
try: d = json.load(sys.stdin)
except Exception: print(''); raise SystemExit
for parte in sys.argv[1].split('.'):
    if isinstance(d, list): d = d[int(parte)] if len(d) > int(parte) else {}
    elif isinstance(d, dict): d = d.get(parte, '')
    else: d = ''
print(d if d is not None else '')" "$2"
}

echo "▸ A função está no ar?"
if ! curl -s -o /dev/null --max-time 5 "$PORTA"; then
  falhou "não alcancei $PORTA — sirva a função: supabase functions serve --env-file supabase/functions/.env.local"
fi
ok "$PORTA responde"

# Este script gasta o teto de tentativas de propósito, na última seção. Sem limpar antes,
# a segunda execução dentro da mesma janela de 10 minutos começa já no 429 e reprova nas
# **primeiras** asserções — vermelho pelo motivo errado, que é indistinguível de vermelho
# pelo motivo certo para quem só olha o ✗. Medido: a segunda execução seguida saía com 9
# de 11 asserções e exit 1.
#
# A limpeza é do registro de tentativas, que é dado de portão e não do produto. Se o
# contêiner não estiver ao alcance, o script avisa e segue: numa máquina sem Docker
# local, rodar uma vez por janela continua funcionando.
DB=${DB_CONTAINER:-supabase_db_frila-backend}
if docker exec -i "$DB" psql -U postgres -d postgres -q -c \
     'truncate public.entrada_demonstracao' >/dev/null 2>&1; then
  ok "registro de tentativas zerado, para o teto não vir gasto da execução anterior"
else
  printf '  ⚠ não consegui zerar public.entrada_demonstracao (contêiner %s).\n' "$DB" >&2
  printf '    Se a execução anterior foi há menos de 10 minutos, o teto ainda está gasto.\n' >&2
fi

# ── Critério 2: o código fixo não abre nada além do que foi declarado ────────────────
echo "▸ O que a porta recusa"

r=$(chamar "$PORTA" "{\"email\":\"invasor-$RANDOM@qualquer.test\",\"codigo\":\"$CODIGO\"}")
[ "$(status_de "$r")" = "404" ] || falhou "e-mail não declarado devolveu $(status_de "$r"), e o contrato pede 404"
[ "$(campo "$(corpo_de "$r")" code)" = "nao_encontrado" ] \
  || falhou "e-mail não declarado não devolveu o code nao_encontrado"
ok "e-mail fora da lista declarada: 404 nao_encontrado"

r=$(chamar "$PORTA" "{\"email\":\"$PROFISSIONAL\",\"codigo\":\"codigo-errado-$RANDOM\"}")
[ "$(status_de "$r")" = "404" ] || falhou "código errado devolveu $(status_de "$r")"
# O código errado responde 404 e não 401 de propósito: um 401 confirmaria que aquele
# endereço é uma conta de revisão, que é justamente o que não deve ser descoberto.
[ "$(campo "$(corpo_de "$r")" code)" = "nao_encontrado" ] \
  || falhou "código errado não devolveu nao_encontrado — e 401 aqui entregaria a lista de endereços"
ok "código errado no e-mail certo: 404 nao_encontrado, indistinguível do anterior"

# ── Critério 1: as duas contas entram e enxergam os dados semeados ───────────────────
echo "▸ As duas contas entram"

r=$(chamar "$PORTA" "{\"email\":\"$CONTRATANTE\",\"codigo\":\"$CODIGO\"}")
[ "$(status_de "$r")" = "200" ] || falhou "o contratante de revisão recebeu $(status_de "$r")"
[ "$(campo "$(corpo_de "$r")" token_type)" = "bearer" ] || falhou "a sessão do contratante não veio no schema Sessao"
TOKEN_CASA=$(campo "$(corpo_de "$r")" access_token)
[ -n "$TOKEN_CASA" ] || falhou "a sessão do contratante veio sem access_token"
ok "contratante: 200 com sessão"

r=$(chamar "$PORTA" "{\"email\":\"$PROFISSIONAL\",\"codigo\":\"$CODIGO\"}")
[ "$(status_de "$r")" = "200" ] || falhou "o profissional de revisão recebeu $(status_de "$r")"
sessao=$(corpo_de "$r")
[ "$(campo "$sessao" token_type)" = "bearer" ] || falhou "a sessão do profissional não veio no schema Sessao"
[ -n "$(campo "$sessao" refresh_token)" ] || falhou "a sessão veio sem refresh_token, que o contrato exige"
ok "profissional: 200 com sessão, token_type bearer e refresh_token"

TOKEN=$(campo "$sessao" access_token)
[ -n "$TOKEN" ] || falhou "sessão sem access_token"

echo "▸ O que a conta de revisão enxerga"

r=$(chamar "$URL/rest/v1/rpc/vagas_abertas" '{"latitude":-15.794,"longitude":-47.8825}' "$TOKEN")
[ "$(status_de "$r")" = "200" ] || falhou "vagas_abertas devolveu $(status_de "$r")"
n=$(printf '%s' "$(corpo_de "$r")" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(len(d.get('vagas', d) if isinstance(d, dict) else d))")
[ "$n" -ge 1 ] || falhou "a lista da conta de revisão veio vazia — é exatamente a diretriz 4.2"
ok "vagas_abertas: $n vaga(s), e a lista não nasce vazia"

r=$(chamar "$URL/rest/v1/rpc/meus_turnos" '{}' "$TOKEN")
[ "$(status_de "$r")" = "200" ] || falhou "meus_turnos devolveu $(status_de "$r")"
turno=$(printf '%s' "$(corpo_de "$r")" | python3 -c "
import json,sys
d=json.load(sys.stdin)
ts=d.get('turnos', d) if isinstance(d, dict) else d
print(ts[0]['id'] if ts else '')")
[ -n "$turno" ] || falhou "a conta de revisão não tem turno confirmado semeado"
ok "meus_turnos: o turno confirmado está lá"

r=$(chamar "$URL/rest/v1/rpc/contato_do_turno" "{\"turno_id\":\"$turno\"}" "$TOKEN")
[ "$(status_de "$r")" = "200" ] || falhou "contato_do_turno devolveu $(status_de "$r")"
[ -n "$(campo "$(corpo_de "$r")" telefone)" ] || falhou "o contato veio sem telefone"
ok "contato_do_turno: contato liberado, com prazo"

# ── O ciclo da presença, que é a metade do app que a revisão precisa alcançar ─────────
#
# O turno semeado para a revisão começa dois dias depois de o seed rodar, e a janela do
# registro abre 60 minutos antes do início. Sem a isenção da migração
# `20260925230000_janela_da_demonstracao`, tudo daqui para baixo responde
# `422 fora_da_janela` — medido em 25/09, e é o que o revisor encontraria em 06/11.
#
# Aqui o caminho vai inteiro: o profissional bate o ponto longe do local, a casa
# confirma, e o turno fecha. É o único lugar onde o caminho feliz do check-in é medido
# por HTTP: o `ciclo-completo.sh` pula essa parte de propósito, porque para uma conta
# real ela pede um turno que já aconteceu e o relógio do produto só se sobrepõe dentro do
# pgTAP.
#
# O contraste — a conta real continuar recebendo 422 no mesmo cenário — está em
# `supabase/tests/230_janela_da_demonstracao.sql`, que tem as duas contas no mesmo
# relógio.
echo "▸ O ciclo da presença, fora da janela"

agora=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# A recusa vem primeiro, e não por gosto de ordem: `fazer_checkin` devolve o registro já
# gravado antes de chegar à janela, então depois do check-in válido esta chamada mediria a
# idempotência e passaria sem testar nada.
#
# A isenção é só da janela. Registro no futuro continua recusado, e é esta asserção que
# impede alguém de ler "a revisão atravessa a janela" como "a revisão fabrica presença".
r=$(chamar "$URL/rest/v1/rpc/fazer_checkin" \
      "{\"turno_id\":\"$turno\",\"distancia_m\":null,\"registrado_em\":\"2027-01-01T12:00:00Z\"}" "$TOKEN")
[ "$(status_de "$r")" = "422" ] \
  || falhou "registro no futuro devolveu $(status_de "$r"), e o contrato pede 422"
[ "$(campo "$(corpo_de "$r")" code)" = "registro_no_futuro" ] \
  || falhou "registro no futuro recusou com $(campo "$(corpo_de "$r")" code)"
ok "registro no futuro: 422 registro_no_futuro — a isenção é só da janela"

r=$(chamar "$URL/rest/v1/rpc/fazer_checkin" \
      "{\"turno_id\":\"$turno\",\"distancia_m\":null,\"registrado_em\":\"$agora\"}" "$TOKEN")
[ "$(status_de "$r")" = "200" ] \
  || falhou "fazer_checkin devolveu $(status_de "$r") $(campo "$(corpo_de "$r")" code) — a revisão não alcança o check-in"
[ "$(campo "$(corpo_de "$r")" tipo)" = "manual" ] \
  || falhou "o check-in sem distância saiu $(campo "$(corpo_de "$r")" tipo), e RN22 pede manual"
ok "fazer_checkin: 200 manual, longe do local e fora da janela"

r=$(chamar "$URL/rest/v1/rpc/confirmar_checkin_manual" "{\"turno_id\":\"$turno\"}" "$TOKEN_CASA")
[ "$(status_de "$r")" = "200" ] \
  || falhou "confirmar_checkin_manual devolveu $(status_de "$r") $(campo "$(corpo_de "$r")" code)"
[ "$(campo "$(corpo_de "$r")" verificacao)" = "verificado" ] \
  || falhou "depois do toque da casa a verificação ficou $(campo "$(corpo_de "$r")" verificacao)"
ok "confirmar_checkin_manual: a casa da revisão confirma, e vira verificado"

r=$(chamar "$URL/rest/v1/rpc/fazer_checkout" \
      "{\"turno_id\":\"$turno\",\"distancia_m\":null,\"registrado_em\":\"$agora\"}" "$TOKEN")
[ "$(status_de "$r")" = "200" ] \
  || falhou "fazer_checkout devolveu $(status_de "$r") $(campo "$(corpo_de "$r")" code)"
[ -n "$(campo "$(corpo_de "$r")" registrado_em)" ] || falhou "o check-out veio sem registrado_em"
ok "fazer_checkout: o turno da revisão fecha"

# ── O teto de tentativas ─────────────────────────────────────────────────────────────
#
# Código fixo que nunca expira precisa de teto, senão o espaço de um código curto sai em
# poucas horas. O teto é por e-mail e por janela; aqui basta provar que ele existe e que
# a recusa é a que o contrato promete.
echo "▸ O teto de tentativas"

teto=""
for _ in $(seq 1 15); do
  r=$(chamar "$PORTA" "{\"email\":\"$PROFISSIONAL\",\"codigo\":\"errado\"}")
  if [ "$(status_de "$r")" = "429" ]; then teto="$(corpo_de "$r")"; break; fi
done
[ -n "$teto" ] || falhou "quinze tentativas erradas seguidas e nenhuma 429: o teto não está segurando"
[ "$(campo "$teto" code)" = "limite_excedido" ] \
  || falhou "o teto recusou com $(campo "$teto" code), e o contrato pede limite_excedido"
ok "429 limite_excedido depois de repetir o código errado"

echo
echo "A porta de demonstração está de pé: recusa o que não foi declarado, abre as duas"
echo "contas, entrega os dados semeados, leva o ciclo da presença até o fim fora da janela"
echo "e tem teto de tentativas."
