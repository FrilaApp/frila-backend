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
EMAIL="ciclo-$(date +%s)@frila.test"

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
printf '%s' "$texto" | grep -qE 'href="https?://[^"]*(verify|confirm)' \
  && falhou "o e-mail traz link de confirmação; o contrato pede código, não link"
ok "sem link de confirmação"

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
ok "o e-mail vem da credencial confirmada, não da tela"

# RN20 pelo caminho real, com o código de erro que o aplicativo compara sem traduzir.
erro=$(curl -s -X POST "$URL/rest/v1/rpc/criar_conta" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"perfil":"contratante","nome":"Outro","telefone":"+5561999990000",
       "nascimento":"1995-01-01","termos_versao":"2026-09-22"}')
cod=$(printf '%s' "$erro" | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',''))" 2>/dev/null || true)
[ "$cod" = "conta_existente" ] || falhou "reenvio com outro perfil devolveu '$cod', esperado conta_existente"
ok "RN25: reenviar com outro perfil → conta_existente"

echo
echo "▸ O que ainda não existe"
echo "  ⏭  publicar_vaga, candidatar, check-in e avaliar entram com as RPCs do Sprint 1."
echo "     Cada uma acrescenta um passo aqui, com o status HTTP conferido."
echo
echo "Ciclo verificado até a criação da conta."
