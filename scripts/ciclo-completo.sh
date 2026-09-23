#!/usr/bin/env bash
# Smoke test do ciclo, por HTTP, como um cliente de verdade:
#
#   pedir código → ler o e-mail → trocar por sessão → criar_conta → …
#
# Existe porque o pgTAP roda dentro do banco e não prova que a rota existe, que o
# PostgREST a expõe, que o e-mail sai, nem que o status HTTP é o que o contrato promete.
# Aqui, prova. Cada RPC do Sprint 1 acrescenta um passo.
#
# Uso:  ./scripts/ciclo-completo.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

[ -f .env ] && { set -a; source .env; set +a; }

URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
CAIXA="${INBUCKET_URL:-http://127.0.0.1:54324}"
ANON="${SUPABASE_ANON_KEY:-}"
[ -z "$ANON" ] && ANON=$(supabase status -o env 2>/dev/null | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')

if [ -z "$ANON" ]; then
  echo "Sem SUPABASE_ANON_KEY e sem 'supabase status'. Suba o ambiente: supabase start" >&2
  exit 1
fi

ok()    { printf '  ✓ %s\n' "$1"; }
falhou(){ printf '  ✗ %s\n' "$1" >&2; exit 1; }

# Um endereço novo por execução: o script não pode depender de estado deixado pela
# execução anterior, senão passa na segunda vez por motivo errado.
# `date +%s` colide se o script rodar duas vezes no mesmo segundo, e aí a segunda
# execução passa por motivo errado — a conta da primeira já existe.
EMAIL="ciclo-$(date +%s)-$$-$RANDOM@frila.test"

echo "▸ Entrada por código no e-mail"

codigo=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/auth/v1/otp" \
  -H "apikey: $ANON" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\"}")
[ "$codigo" = "200" ] || falhou "POST /auth/v1/otp devolveu $codigo"
ok "código pedido para $EMAIL"

# A caixa local do `supabase start`. Sem provedor de e-mail de verdade, é aqui que o
# código aparece — e é o que o critério de aceite do cartão manda conferir.
corpo=$(curl -s "$CAIXA/api/v1/search?query=to:$EMAIL" \
        | python3 -c "
import json,sys
d=json.load(sys.stdin)
ms=d.get('messages') or []
print(ms[0]['ID'] if ms else '')" )
[ -n "$corpo" ] || falhou "nenhum e-mail para $EMAIL na caixa local ($CAIXA)"

texto=$(curl -s "$CAIXA/api/v1/message/$corpo" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print((d.get('Text') or '') + '\n' + (d.get('HTML') or ''))")

otp=$(printf '%s' "$texto" | grep -oE '\b[0-9]{6}\b' | head -1)
[ -n "$otp" ] || falhou "não achei um código de 6 dígitos no e-mail"
ok "código de 6 dígitos no corpo do e-mail"

printf '%s' "$texto" | grep -qi 'código de entrada' \
  || falhou "o e-mail não está em português"
ok "e-mail em português"

# Link mágico abre o navegador, sai do aplicativo e quebra o fluxo em Android de
# entrada, que é onde está a maior parte da oferta.
#
# O padrão é `<a href` e não `verify|confirm`: um deep link ou um encurtador passariam
# pelo segundo e quebrariam o fluxo igual. O modelo deste e-mail não tem link nenhum, e
# é assim que ele deve continuar.
printf '%s' "$texto" | grep -qiE '<a[^>]+href' \
  && falhou "o e-mail traz link; o contrato pede código, e link nenhum"
ok "sem link no corpo"

sessao=$(curl -s -X POST "$URL/auth/v1/verify" \
  -H "apikey: $ANON" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"token\":\"$otp\",\"type\":\"email\"}")
TOKEN=$(printf '%s' "$sessao" | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))")
[ -n "$TOKEN" ] || falhou "verify não devolveu sessão: $sessao"
ok "sessão aberta com o código"

echo
echo "▸ A conta"

# Antes de `criar_conta` existe sessão e não existe conta. É como o aplicativo sabe que
# tem de mandar para o cadastro.
codigo=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$URL/rest/v1/rpc/minha_conta" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}')
[ "$codigo" = "404" ] || falhou "minha_conta antes do cadastro devolveu $codigo, esperado 404"
ok "minha_conta → 404 antes do cadastro"

conta=$(curl -s -X POST "$URL/rest/v1/rpc/criar_conta" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"perfil":"profissional","nome":"Ciclo Completo","telefone":"+5561999990000",
       "nascimento":"1995-01-01","termos_versao":"2026-09-22"}')
perfil=$(printf '%s' "$conta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('perfil',''))" 2>/dev/null || true)
[ "$perfil" = "profissional" ] || falhou "criar_conta não devolveu a conta: $conta"
ok "criar_conta → conta de profissional"

email_gravado=$(printf '%s' "$conta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('email',''))")
[ "$email_gravado" = "$EMAIL" ] || falhou "o e-mail gravado ($email_gravado) não é o da sessão"
ok "o e-mail gravado é o da credencial confirmada"

echo
echo "▸ Os erros, com status e código"
#
# É a única camada onde o **status** pode ser conferido: ele viaja no `DETAIL` da
# exceção e quem o traduz é o PostgREST. Um teste de banco vê o código e não vê o
# status — foi assim que o `DETAIL` sem `headers` passou batido e devolvia 500 em toda
# recusa de regra.
recusa() {
  local desc="$1" esperado_http="$2" esperado_code="$3" corpo="$4" rota="${5:-criar_conta}"
  local tmp http code
  tmp=$(mktemp)
  http=$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$URL/rest/v1/rpc/$rota" \
    -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d "$corpo")
  code=$(python3 -c "import json,sys; print(json.load(open('$tmp')).get('code',''))" 2>/dev/null || true)
  rm -f "$tmp"
  [ "$http" = "$esperado_http" ] || falhou "$desc: HTTP $http, esperado $esperado_http"
  [ "$code" = "$esperado_code" ] || falhou "$desc: code '$code', esperado '$esperado_code'"
  ok "$desc → $http $code"
}

# O 409 primeiro, enquanto $TOKEN ainda é o da sessão que **já tem** conta. Depois ele
# passa a ser o da segunda sessão, que é de onde saem os 422.
recusa "RN25: reenviar com outro perfil" 409 conta_existente \
  '{"perfil":"contratante","nome":"Outro","telefone":"+5561999990000","nascimento":"1995-01-01","termos_versao":"2026-09-22"}'

# Uma sessão nova, ainda sem conta: é dela que saem os 422, porque a sessão anterior já
# tem conta e cairia sempre no 409.
EMAIL2="ciclo-b-$(date +%s)-$$-$RANDOM@frila.test"
curl -s -o /dev/null -X POST "$URL/auth/v1/otp" -H "apikey: $ANON" \
  -H 'Content-Type: application/json' -d "{\"email\":\"$EMAIL2\"}"
MID2=$(curl -s "$CAIXA/api/v1/search?query=to:$EMAIL2" | python3 -c "
import json,sys; d=json.load(sys.stdin); ms=d.get('messages') or []; print(ms[0]['ID'] if ms else '')")
OTP2=$(curl -s "$CAIXA/api/v1/message/$MID2" | python3 -c "
import json,sys; d=json.load(sys.stdin); print((d.get('Text') or '')+(d.get('HTML') or ''))" \
  | grep -oE '\b[0-9]{6}\b' | head -1)
TOKEN=$(curl -s -X POST "$URL/auth/v1/verify" -H "apikey: $ANON" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL2\",\"token\":\"$OTP2\",\"type\":\"email\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))")
[ -n "$TOKEN" ] || falhou "não consegui abrir a segunda sessão"

base='"perfil":"profissional","nome":"Fulano","telefone":"+5561999990000","termos_versao":"2026-09-22"'

recusa "RN20: 17 anos" 422 menor_de_idade \
  "{$base,\"nascimento\":\"$(date -v-17y +%Y-%m-%d 2>/dev/null || date -d '-17 years' +%Y-%m-%d)\"}"

recusa "telefone fora do E.164" 422 campo_obrigatorio \
  '{"perfil":"profissional","nome":"Fulano","telefone":"61999990000","nascimento":"1990-01-01","termos_versao":"2026-09-22"}'

recusa "sem o aceite dos termos" 422 campo_obrigatorio \
  '{"perfil":"profissional","nome":"Fulano","telefone":"+5561999990000","nascimento":"1990-01-01","termos_versao":"  "}'

recusa "minha_conta sem conta criada" 404 nao_encontrado '{}' minha_conta

echo
echo "▸ O que ainda não existe"
echo "  ⏭  publicar_vaga, candidatar, check-in e avaliar entram com as RPCs do Sprint 1."
echo "     Cada uma acrescenta um passo aqui, com o status HTTP conferido."
echo
echo "Ciclo verificado até a criação da conta."
