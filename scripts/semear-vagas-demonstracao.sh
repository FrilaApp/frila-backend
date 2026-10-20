#!/usr/bin/env bash
# Semeia vagas futuras abertas para o estabelecimento de demonstração do contratante
# (Bar da Revisão), no frila-dev. Cartão `5boVdM0t`, critério 4.
#
# Chama `public.publicar_vaga` pela REST do PostgREST, autenticado como
# `revisao-contratante@frila.app` — a mesma conta que a revisão da Apple usa. A sessão
# nasce do jeito que a Edge Function `entrar-demonstracao` nasce a dela (dois passos de
# Auth Admin, `generate_link` + `verify`), só que aqui com `service_role` direto, porque
# a porta de demonstração no frila-dev está com a janela (`DEMONSTRACAO_ATIVA_ATE`)
# vencida/ausente — bloqueio `2` da vila (token de Management API 401), fora do alcance
# deste script. Quando alguém destravar o token e reaplicar os segredos, este caminho
# deixa de ser necessário; ele continua funcionando igual, porque é a mesma RPC.
#
# Idempotente por chave_cliente (RF04): rodar de novo com as mesmas datas devolve as
# vagas já existentes em vez de duplicar. Datas diferentes (ou `--a-partir-de`
# diferente) sempre criam vagas novas.
#
# Uso:
#   ./scripts/semear-vagas-demonstracao.sh <quantidade> [--a-partir-de AAAA-MM-DD]
#
# Sem --a-partir-de, começa em 2026-11-20 (bem depois da submissão de 06/11 — RN da
# revisão da Apple não pode achar a vaga vencida no meio da revisão). Uma vaga por dia,
# em dias consecutivos, para que "lista cheia" e "detalhe" tenham o que listar mesmo que
# a revisão leve alguns dias.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; source .env; set +a

QUANTIDADE="${1:?uso: semear-vagas-demonstracao.sh <quantidade> [--a-partir-de AAAA-MM-DD]}"
shift || true
A_PARTIR_DE="2026-11-20"
while [ $# -gt 0 ]; do
  case "$1" in
    --a-partir-de) A_PARTIR_DE="${2:?--a-partir-de precisa da data}"; shift 2 ;;
    *) echo "opção desconhecida: $1" >&2; exit 2 ;;
  esac
done

case "$QUANTIDADE" in
  ''|*[!0-9]*) echo "quantidade precisa ser um inteiro positivo: $QUANTIDADE" >&2; exit 2 ;;
esac
[ "$QUANTIDADE" -ge 1 ] || { echo "quantidade precisa ser >= 1" >&2; exit 2; }

for par in "URL:${FRILA_DEV_URL:-}" "ANON:${FRILA_DEV_ANON_KEY:-}" "SERVICE_ROLE:${FRILA_DEV_SERVICE_ROLE_KEY:-}"; do
  [ -n "${par#*:}" ] || { echo "falta ${par%%:*} do frila-dev no .env" >&2; exit 1; }
done

EMAIL_CONTRATANTE="revisao-contratante@frila.app"
ESTABELECIMENTO_BAR_DA_REVISAO="de000000-0000-4000-8000-000000000010"

# funcao.id nasce de gen_random_uuid() em supabase/seed.sql: muda por ambiente e por
# reset. Resolver pelo nome em tempo de execução em vez de fixar o uuid evita cair
# exatamente no candidato 1 do cartão `5boVdM0t` (422 campo_invalido/funcao_id por id de
# outro ambiente).
FUNCAO_GARCOM=$(curl -s "$FRILA_DEV_URL/rest/v1/funcao?nome=eq.gar%C3%A7om&select=id" \
  -H "apikey: $FRILA_DEV_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $FRILA_DEV_SERVICE_ROLE_KEY" \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[0]['id'] if d else '')")
[ -n "$FUNCAO_GARCOM" ] || { echo "✗ função 'garçom' não encontrada no catálogo do frila-dev" >&2; exit 1; }

echo "▸ Sessão para $EMAIL_CONTRATANTE (bypass da porta de demonstração, mesma RPC de login)"
LINK=$(curl -s -X POST "$FRILA_DEV_URL/auth/v1/admin/generate_link" \
  -H "apikey: $FRILA_DEV_SERVICE_ROLE_KEY" \
  -H "Authorization: Bearer $FRILA_DEV_SERVICE_ROLE_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"magiclink\",\"email\":\"$EMAIL_CONTRATANTE\"}")
OTP=$(printf '%s' "$LINK" | python3 -c "import json,sys;print(json.load(sys.stdin).get('email_otp',''))")
if [ -z "$OTP" ]; then
  echo "✗ generate_link não devolveu email_otp. Resposta (sem token): $(printf '%s' "$LINK" | python3 -c "import json,sys;d=json.load(sys.stdin);d.pop('email_otp',None);print(d)")" >&2
  exit 1
fi

SESSAO=$(curl -s -X POST "$FRILA_DEV_URL/auth/v1/verify" \
  -H "apikey: $FRILA_DEV_ANON_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"magiclink\",\"email\":\"$EMAIL_CONTRATANTE\",\"token\":\"$OTP\"}")
ACCESS_TOKEN=$(printf '%s' "$SESSAO" | python3 -c "import json,sys;print(json.load(sys.stdin).get('access_token',''))")
if [ -z "$ACCESS_TOKEN" ]; then
  echo "✗ verify não devolveu sessão." >&2
  exit 1
fi
echo "  ✓ sessão obtida (access_token presente, não impresso)"

echo "▸ Publicando $QUANTIDADE vaga(s), a partir de $A_PARTIR_DE, um dia cada"
for i in $(seq 0 $((QUANTIDADE - 1))); do
  DIA=$(python3 -c "
import datetime
base = datetime.date.fromisoformat('$A_PARTIR_DE')
print((base + datetime.timedelta(days=$i)).isoformat())
")
  CHAVE=$(python3 -c "
import uuid
# chave_cliente determinística por dia: reroda sem duplicar vaga do mesmo dia.
print(uuid.uuid5(uuid.NAMESPACE_URL, 'frila-dev:demonstracao:bar-da-revisao:' + '$DIA'))
")
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'estabelecimento_id': '$ESTABELECIMENTO_BAR_DA_REVISAO',
  'funcao_id': '$FUNCAO_GARCOM',
  'inicio_em': '${DIA}T13:00:00-03:00',
  'fim_em': '${DIA}T18:00:00-03:00',
  'local': 'Bar da Revisao - salao principal',
  'ponto': {'latitude': -15.7801, 'longitude': -47.9292},
  'valor_centavos': 14000,
  'posicoes': 3,
  'inclui_refeicao': True,
  'inclui_transporte': False,
  'exige_material_proprio': False,
  'responsavel_local': 'Gerente do Bar da Revisao',
  'modo': 'urgencia',
  'chave': '$CHAVE',
  'alerta_antecedencia_min': 180,
}))
")
  RESP=$(curl -s -w "\n%{http_code}" -X POST "$FRILA_DEV_URL/rest/v1/rpc/publicar_vaga" \
    -H "Content-Type: application/json" \
    -H "apikey: $FRILA_DEV_ANON_KEY" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -d "$PAYLOAD")
  STATUS=$(printf '%s' "$RESP" | tail -n1)
  BODY=$(printf '%s' "$RESP" | sed '$d')
  if [ "$STATUS" != "200" ]; then
    echo "  ✗ vaga de $DIA: HTTP $STATUS — $BODY" >&2
    exit 1
  fi
  VAGA_ID=$(printf '%s' "$BODY" | python3 -c "import json,sys;print(json.load(sys.stdin)['vaga_id'])")
  echo "  ✓ $DIA → vaga_id $VAGA_ID"
done

echo
echo "Semeadas $QUANTIDADE vaga(s) para Bar da Revisão, a partir de $A_PARTIR_DE."
