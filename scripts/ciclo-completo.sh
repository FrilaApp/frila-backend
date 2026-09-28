#!/usr/bin/env bash
# Smoke test do ciclo, por HTTP, como um cliente de verdade:
#
#   pedir código → ler o e-mail → trocar por sessão → criar_conta → …
#
# Existe porque o pgTAP roda dentro do banco e não prova que a rota existe, que o
# PostgREST a expõe, que o e-mail sai, nem que o status HTTP é o que o contrato promete.
# Aqui, prova. Cada RPC do Sprint 1 acrescenta um passo.
#
# Uso:  ./scripts/ciclo-completo.sh [--sobrescrever-segredo]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

sobrescrever_segredo=false
case "${1:-}" in
  '') ;;
  --sobrescrever-segredo) sobrescrever_segredo=true ;;
  *) printf 'Opção desconhecida: %s\n' "$1" >&2; exit 2 ;;
esac

[ -f .env ] && { set -a; source .env; set +a; }

URL="${SUPABASE_URL:-http://127.0.0.1:54321}"
CAIXA="${INBUCKET_URL:-http://127.0.0.1:54324}"
ANON="${SUPABASE_ANON_KEY:-}"

# O trigger de despacho roda dentro do Postgres, portanto a variável local precisa
# ser aplicada ao banco antes da primeira RPC que enfileira uma vaga. O valor nunca
# é exibido nem gravado no repositório.
if [ -n "${AGENDADOR_SECRET:-}" ]; then
  DB="${DB_CONTAINER:-supabase_db_frila-backend}"
  estado_segredo=$(docker exec -e PGPASSWORD=postgres -i "$DB" \
    psql -U supabase_admin -d postgres -X -q -At -v ON_ERROR_STOP=1 \
      -v segredo="$AGENDADOR_SECRET" -f - <<'SQL'
select case
  when nullif(current_setting('frila.agendador_secret', true), '') is null then 'ausente'
  when current_setting('frila.agendador_secret', true) = :'segredo' then 'igual'
  else 'diferente'
end;
SQL
  )

  if [ "$estado_segredo" = "diferente" ] && [ "$sobrescrever_segredo" = false ]; then
    printf '%s\n' \
      'AGENDADOR_SECRET já está configurado com outro valor; use --sobrescrever-segredo para substituir.' >&2
    exit 1
  fi

  if [ "$estado_segredo" = "igual" ]; then
    printf '%s\n' 'AGENDADOR_SECRET já está configurado no banco local.'
  else
    docker exec -e PGPASSWORD=postgres -i "$DB" \
      psql -U supabase_admin -d postgres -X -q -v ON_ERROR_STOP=1 \
        -v segredo="$AGENDADOR_SECRET" -f - <<'SQL'
alter database postgres set frila.agendador_secret = :'segredo';
alter role authenticator set frila.agendador_secret = :'segredo';
select pg_terminate_backend(pid)
  from pg_stat_activity
 where usename = 'authenticator' and pid <> pg_backend_pid();
SQL
    if [ "$estado_segredo" = "ausente" ]; then
      printf '%s\n' 'AGENDADOR_SECRET configurado no banco local.'
    else
      printf '%s\n' 'AGENDADOR_SECRET substituído no banco local.'
    fi
  fi

  for _ in $(seq 1 30); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$URL/rest/v1/")" = "200" ] && break
    sleep 1
  done
fi

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

# O token da primeira sessão, que tem conta de profissional. A partir daqui `$TOKEN`
# passa a ser o da segunda; as RPCs do perfil precisam da primeira de volta.
TOKEN_CONTA="$TOKEN"

# A mesma sessão é de profissional: cadastrar estabelecimento é do outro perfil.
recusa "RN25: profissional cadastrando estabelecimento" 422 perfil_incompativel \
  '{"nome":"Bar","documento":"11222333000181","tipo":"food_service","endereco":"CLN 201",
    "ponto":{"latitude":-15.79,"longitude":-47.88}}' cadastrar_estabelecimento

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

# Diretriz 1.2. Está aqui, e não só no pgTAP, porque o pgTAP vê o código e não vê o
# status — e `campo_invalido` e `campo_obrigatorio` são o mesmo 422 com significados
# diferentes para a tela. Se um dia a recusa do filtro sair como 500, é esta linha que
# descobre.
recusa "diretriz 1.2: nome com termo bloqueado" 422 campo_invalido \
  '{"perfil":"profissional","nome":"Ana Caralho","telefone":"+5561999990000","nascimento":"1990-01-01","termos_versao":"2026-09-22"}'

recusa "minha_conta sem conta criada" 404 nao_encontrado '{}' minha_conta

echo
echo "▸ O estabelecimento"

# A segunda sessão ainda não tem conta: vira a contratante que cadastra o bar.
conta=$(curl -s -X POST "$URL/rest/v1/rpc/criar_conta" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"perfil":"contratante","nome":"Dona do Bar","telefone":"+5561999990000",
       "nascimento":"1980-01-01","termos_versao":"2026-09-22"}')
perfil=$(printf '%s' "$conta" | python3 -c "import json,sys; print(json.load(sys.stdin).get('perfil',''))" 2>/dev/null || true)
[ "$perfil" = "contratante" ] || falhou "criar_conta de contratante não devolveu a conta: $conta"
ok "criar_conta → conta de contratante"

# Um CNPJ novo por execução, com o dígito verificador calculado aqui: o documento é
# único no banco, e repetir o da execução anterior daria 409 pelo motivo errado.
CNPJ=$(python3 -c "
import random
b=[random.randint(0,9) for _ in range(8)]+[0,0,0,1]
def dv(ds,ps):
    r=sum(d*p for d,p in zip(ds,ps))%11
    return 0 if r<2 else 11-r
p1=[5,4,3,2,9,8,7,6,5,4,3,2]; b.append(dv(b,p1)); b.append(dv(b,[6]+p1))
print(''.join(map(str,b)))")
ERRADO="${CNPJ:0:13}$(( (${CNPJ:13:1} + 1) % 10 ))"

corpo_estab="{\"nome\":\"Bar do Ciclo\",\"documento\":\"$CNPJ\",\"tipo\":\"food_service\",
  \"endereco\":\"CLN 201\",\"ponto\":{\"latitude\":-15.7942,\"longitude\":-47.8822}}"

estab=$(curl -s -X POST "$URL/rest/v1/rpc/cadastrar_estabelecimento" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$corpo_estab")
ESTAB=$(printf '%s' "$estab" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
papel=$(printf '%s' "$estab" | python3 -c "import json,sys; print(json.load(sys.stdin).get('papel',''))" 2>/dev/null || true)
[ -n "$ESTAB" ] && [ "$papel" = "administrador" ] \
  || falhou "cadastrar_estabelecimento não devolveu o estabelecimento: $estab"
ok "cadastrar_estabelecimento → administrador do estabelecimento"

de_novo=$(curl -s -X POST "$URL/rest/v1/rpc/cadastrar_estabelecimento" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$corpo_estab" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
[ "$de_novo" = "$ESTAB" ] || falhou "reenviar o cadastro devolveu outro estabelecimento ($de_novo)"
ok "reenviar o cadastro devolve o mesmo estabelecimento"

recusa "RF02: CNPJ com dígito verificador errado" 422 campo_obrigatorio \
  "{\"nome\":\"Bar\",\"documento\":\"$ERRADO\",\"tipo\":\"food_service\",\"endereco\":\"CLN 201\",
    \"ponto\":{\"latitude\":-15.79,\"longitude\":-47.88}}" cadastrar_estabelecimento

# O painel é GET no contrato. A função não é `stable` — ela levanta erro por
# `public.erro`, que é volátil — e o PostgREST a executa numa transação só de leitura.
# Este passo é o que prova que a rota responde por GET.
painel_get() {
  local estab="$1" tmp http
  tmp=$(mktemp)
  http=$(curl -s -o "$tmp" -w '%{http_code}' -G "$URL/rest/v1/rpc/painel_estabelecimento" \
    -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
    --data-urlencode "estabelecimento_id=$estab" \
    --data-urlencode "de=2026-01-01T00:00:00Z" \
    --data-urlencode "ate=2027-01-01T00:00:00Z")
  printf '%s %s' "$http" "$(cat "$tmp")"
  rm -f "$tmp"
}

resp=$(painel_get "$ESTAB")
http=${resp%% *}; corpo=${resp#* }
[ "$http" = "200" ] || falhou "GET painel_estabelecimento devolveu $http: $corpo"
eid=$(printf '%s' "$corpo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('estabelecimento_id',''))" 2>/dev/null || true)
[ "$eid" = "$ESTAB" ] || falhou "o painel não é do estabelecimento pedido: $corpo"
ok "GET painel_estabelecimento → 200, do estabelecimento pedido"

resp=$(painel_get "00000000-0000-4000-8000-000000000000")
http=${resp%% *}; corpo=${resp#* }
code=$(printf '%s' "$corpo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',''))" 2>/dev/null || true)
[ "$http" = "403" ] && [ "$code" = "sem_permissao" ] \
  || falhou "painel de estabelecimento alheio: HTTP $http code '$code', esperado 403 sem_permissao"
ok "GET painel de estabelecimento alheio → 403 sem_permissao"

# `meus_estabelecimentos` é a leitura que vem **antes** de todas as outras do contratante:
# `publicar_vaga`, `painel_estabelecimento` e `republicar_vaga` recebem
# `estabelecimento_id`, e é daqui que o app o tira. Por GET, como o contrato manda.
tmp=$(mktemp)
http=$(curl -s -o "$tmp" -w '%{http_code}' -G "$URL/rest/v1/rpc/meus_estabelecimentos" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN")
corpo=$(cat "$tmp"); rm -f "$tmp"
[ "$http" = "200" ] || falhou "GET meus_estabelecimentos devolveu $http: $corpo"

achou=$(printf '%s' "$corpo" | python3 -c "
import json,sys
d = json.load(sys.stdin)
alvo = sys.argv[1]
print(next((e.get('papel','') for e in d if e.get('id') == alvo), ''))" "$ESTAB" 2>/dev/null || true)
[ "$achou" = "administrador" ] \
  || falhou "meus_estabelecimentos não trouxe o estabelecimento recém-criado como administrador: $corpo"
ok "GET meus_estabelecimentos → 200, com a casa criada e o papel de administrador"

# RN10: esta tela não é a de cadastro. Telefone, e-mail, documento, endereço e coordenada
# ficam de fora — o pgTAP já cobra isso, mas o corpo que sai pelo PostgREST é outro objeto
# e merece a mesma pergunta.
printf '%s' "$corpo" | grep -qiE 'telefone|email|documento|endereco|latitude|longitude|\+55' \
  && falhou "meus_estabelecimentos vazou dado de contato ou de cadastro: $corpo"
ok "RN10: nenhum contato, documento ou coordenada em meus_estabelecimentos"

echo
echo "▸ A vaga"
#
# A sessão corrente é a da contratante que acabou de cadastrar o bar, que é quem pode
# publicar por ele. Cada recusa daqui existe no pgTAP com o código; o que só se vê
# nesta camada é o **status**, e é por isso que ela está aqui também.

FUNCAO_VAGA=$(curl -s "$URL/rest/v1/funcao?select=id&nome=eq.gar%C3%A7om" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
[ -n "$FUNCAO_VAGA" ] || falhou "não consegui ler o catálogo de funções por HTTP"

# Datas em UTC, longe o bastante para não esbarrar no fuso de quem roda o script.
INICIO=$(python3 -c "
import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(days=3)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
FIM=$(python3 -c "
import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(days=3, hours=6)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
CHAVE=$(python3 -c "import uuid; print(uuid.uuid4())")

vaga_corpo() { # vaga_corpo <chave> [<campo extra em json, sem as chaves externas>]
  printf '{"estabelecimento_id":"%s","funcao_id":"%s","inicio_em":"%s","fim_em":"%s",
           "local":"CLN 406, Asa Norte","ponto":{"latitude":-15.7890,"longitude":-47.8850},
           "valor_centavos":18000,"posicoes":3,"inclui_refeicao":true,
           "inclui_transporte":true,"exige_material_proprio":false,
           "responsavel_local":"Seu Zé","modo":"urgencia","chave":"%s"%s}' \
    "$ESTAB" "$FUNCAO_VAGA" "$INICIO" "$FIM" "$1" "${2:-}"
}

vaga=$(curl -s -X POST "$URL/rest/v1/rpc/publicar_vaga" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$(vaga_corpo "$CHAVE")")
VAGA=$(printf '%s' "$vaga" | python3 -c "import json,sys; print(json.load(sys.stdin).get('vaga_id',''))" 2>/dev/null || true)
n_pos=$(printf '%s' "$vaga" | python3 -c "
import json,sys; print(len(json.load(sys.stdin).get('posicoes') or []))" 2>/dev/null || true)
[ -n "$VAGA" ] && [ "$n_pos" = "3" ] \
  || falhou "publicar_vaga não devolveu a vaga com três posições: $vaga"
ok "publicar_vaga → vaga publicada, três posições"

# RF04. A rede cai depois do commit e o app reenvia: a mesma chave não pode publicar
# duas vagas — nem criar mais três posições.
de_novo=$(curl -s -X POST "$URL/rest/v1/rpc/publicar_vaga" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "$(vaga_corpo "$CHAVE")" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('vaga_id',''))" 2>/dev/null || true)
[ "$de_novo" = "$VAGA" ] || falhou "reenviar com a mesma chave devolveu outra vaga ($de_novo)"
ok "RF04: reenviar com a mesma chave devolve a mesma vaga"

recusa "RN02: responsável em branco" 422 campo_obrigatorio \
  "$(vaga_corpo "$(python3 -c 'import uuid; print(uuid.uuid4())')" ',"responsavel_local":"  "')" \
  publicar_vaga

recusa "RN18: valor zero" 422 campo_invalido \
  "$(vaga_corpo "$(python3 -c 'import uuid; print(uuid.uuid4())')" ',"valor_centavos":0')" \
  publicar_vaga

recusa "v1.0: modo seleção não existe" 422 campo_invalido \
  "$(vaga_corpo "$(python3 -c 'import uuid; print(uuid.uuid4())')" ',"modo":"selecao"')" \
  publicar_vaga

recusa "diretriz 1.2: termo bloqueado em observações" 422 campo_invalido \
  "$(vaga_corpo "$(python3 -c 'import uuid; print(uuid.uuid4())')" ',"observacoes":"Nada de caralho aqui"')" \
  publicar_vaga

# O fim antes do início: a recusa sai da RPC com o código do contrato, e não da
# constraint do banco como 500.
recusa "fim antes do início" 422 horario_invalido \
  "$(printf '{"estabelecimento_id":"%s","funcao_id":"%s","inicio_em":"%s","fim_em":"%s",
     "local":"CLN 406","ponto":{"latitude":-15.789,"longitude":-47.885},
     "valor_centavos":18000,"posicoes":1,"inclui_refeicao":true,"inclui_transporte":true,
     "exige_material_proprio":false,"responsavel_local":"Seu Zé","modo":"urgencia",
     "chave":"%s"}' "$ESTAB" "$FUNCAO_VAGA" "$FIM" "$INICIO" \
     "$(python3 -c 'import uuid; print(uuid.uuid4())')")" \
  publicar_vaga

echo
echo "▸ O perfil do profissional"
#
# A sessão corrente ($TOKEN) é a segunda, que ainda não tem conta. Volta-se para a
# primeira, que tem conta de profissional, para exercitar as três RPCs do perfil.
TOKEN="$TOKEN_CONTA"

chamar() { # chamar <rota> <corpo> → ecoa o JSON da resposta
  curl -s -X POST "$URL/rest/v1/rpc/$1" \
    -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' -d "$2"
}

recusa "perfil antes de existir" 404 nao_encontrado '{}' meu_perfil_profissional

# O catálogo é lido pela rota que o app usa, e não por SQL: é a prova de que a tabela
# está exposta e legível por quem tem sessão.
FUNCAO=$(curl -s "$URL/rest/v1/funcao?select=id&nome=eq.gar%C3%A7om" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
[ -n "$FUNCAO" ] || falhou "não consegui ler o catálogo de funções por HTTP"
ok "catálogo de funções legível por HTTP"

perfil=$(chamar criar_perfil_profissional "{\"funcoes\":[\"$FUNCAO\"],
  \"ponto_base\":{\"latitude\":-15.7650,\"longitude\":-47.8830},
  \"disponibilidades\":[{\"dia_semana\":5,\"hora_inicio\":\"18:00\",\"hora_fim\":\"02:00\"}]}")

janela=$(printf '%s' "$perfil" | python3 -c "
import json,sys
d=json.load(sys.stdin)
j=(d.get('disponibilidades') or [{}])[0]
print(f\"{j.get('hora_inicio')}-{j.get('hora_fim')}\")" 2>/dev/null || true)

[ "$janela" = "18:00-02:00" ] || falhou "a janela 18:00–02:00 não voltou igual: $janela · $perfil"
ok "criar_perfil_profissional → a janela que atravessa a meia-noite volta igual"

# O ponto base sai como latitude/longitude, e não como WKT: o formato do banco não
# vaza para o cliente.
lat=$(printf '%s' "$perfil" | python3 -c "
import json,sys; print(json.load(sys.stdin).get('ponto_base',{}).get('latitude',''))")
[ "$lat" = "-15.765" ] || falhou "o ponto base voltou como '$lat', esperado -15.765"
ok "o ponto base volta como coordenada, não como geography crua"

recusa "criar duas vezes" 409 perfil_ja_existe \
  "{\"funcoes\":[\"$FUNCAO\"],\"ponto_base\":{\"latitude\":-15.76,\"longitude\":-47.88}}" \
  criar_perfil_profissional

recusa "atualizar com funcoes vazia" 422 campo_obrigatorio \
  '{"funcoes":[]}' atualizar_perfil_profissional

recusa "atualizar sem nenhum campo" 422 campo_obrigatorio \
  '{}' atualizar_perfil_profissional

echo
echo "▸ A lista de vagas"
#
# A sessão é a do profissional, que acabou de ganhar perfil e ponto base. A vaga foi
# publicada pela contratante da segunda sessão: é o primeiro ponto do ciclo em que um
# lado enxerga o trabalho do outro.
#
# As duas operações são GET no contrato, e é isso que este passo prova — o pgTAP chama
# a função e não sabe por qual verbo o PostgREST a expõe.

get_rpc() { # get_rpc <rota> [<query>] → "<http> <corpo>"
  local rota="$1" query="${2:-}" tmp http
  tmp=$(mktemp)
  http=$(curl -s -o "$tmp" -w '%{http_code}' -G "$URL/rest/v1/rpc/$rota" \
    -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" ${query:+$query})
  printf '%s %s' "$http" "$(cat "$tmp")"
  rm -f "$tmp"
}

resp=$(get_rpc vagas_abertas)
http=${resp%% *}; corpo=${resp#* }
[ "$http" = "200" ] || falhou "GET vagas_abertas devolveu $http: $corpo"
tem=$(printf '%s' "$corpo" | python3 -c "
import json,sys
print(sum(1 for v in json.load(sys.stdin) if v['id'] == '$VAGA'))" 2>/dev/null || true)
[ "$tem" = "1" ] || falhou "a vaga publicada não apareceu na lista: $corpo"
ok "GET vagas_abertas → 200, e a vaga publicada está na lista"

# RN06. A tela não pode ser ordenada por reputação nem por pagamento, e a lista traz a
# distância justamente para que a ordem seja verificável de fora.
ordenada=$(printf '%s' "$corpo" | python3 -c "
import json,sys
d=[v['distancia_km'] for v in json.load(sys.stdin)]
print('sim' if d == sorted(d) else 'nao')")
[ "$ordenada" = "sim" ] || falhou "a lista não veio ordenada por distância: $corpo"
ok "RN06: a lista vem ordenada por distância"

resp=$(get_rpc detalhe_vaga "--data-urlencode vaga_id=$VAGA")
http=${resp%% *}; corpo=${resp#* }
[ "$http" = "200" ] || falhou "GET detalhe_vaga devolveu $http: $corpo"
id=$(printf '%s' "$corpo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
[ "$id" = "$VAGA" ] || falhou "o detalhe não é da vaga pedida: $corpo"
ok "GET detalhe_vaga → 200, da vaga pedida"

# RN10: o contato sai por `contato_do_turno`, depois da confirmação. Nunca daqui.
printf '%s' "$corpo" | grep -qE '"(documento|telefone|whatsapp)"' \
  && falhou "o detalhe traz documento ou contato: $corpo"
ok "RN10: nem documento nem contato no detalhe"

resp=$(get_rpc detalhe_vaga "--data-urlencode vaga_id=00000000-0000-4000-8000-000000000000")
http=${resp%% *}; corpo=${resp#* }
code=$(printf '%s' "$corpo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',''))" 2>/dev/null || true)
[ "$http" = "404" ] && [ "$code" = "nao_encontrado" ] \
  || falhou "detalhe de vaga inexistente: HTTP $http code '$code', esperado 404 nao_encontrado"
ok "GET detalhe_vaga de vaga que não existe → 404 nao_encontrado"

resp=$(get_rpc vagas_abertas "--data-urlencode limite=101")
http=${resp%% *}; corpo=${resp#* }
code=$(printf '%s' "$corpo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',''))" 2>/dev/null || true)
[ "$http" = "422" ] && [ "$code" = "campo_invalido" ] \
  || falhou "limite acima do teto: HTTP $http code '$code', esperado 422 campo_invalido"
ok "limite acima do teto do contrato → 422 campo_invalido"

echo
echo "▸ A candidatura"
#
# A mesma sessão de profissional que acabou de ver a lista. A vaga tem três posições, e
# a função dela é a mesma do perfil criado acima — é o caminho feliz do modo urgência.

cand=$(curl -s -X POST "$URL/rest/v1/rpc/candidatar" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"vaga_id\":\"$VAGA\"}")
estado=$(printf '%s' "$cand" | python3 -c "import json,sys; print(json.load(sys.stdin).get('estado',''))" 2>/dev/null || true)
TURNO=$(printf '%s' "$cand" | python3 -c "import json,sys; print(json.load(sys.stdin).get('turno_id') or '')" 2>/dev/null || true)
[ "$estado" = "confirmada" ] && [ -n "$TURNO" ] \
  || falhou "candidatar não confirmou: $cand"
ok "candidatar → confirmada, com turno"

# RN10: o contato só existe depois da confirmação, e com prazo. É a primeira vez no
# ciclo em que um telefone sai do servidor.
wa=$(printf '%s' "$cand" | python3 -c "
import json,sys; print((json.load(sys.stdin).get('contato') or {}).get('whatsapp_url',''))" 2>/dev/null || true)
case "$wa" in
  https://wa.me/55*) ok "RN10: o contato vem com o link do WhatsApp pronto" ;;
  *) falhou "o contato não veio como o contrato promete: $cand" ;;
esac

de_novo=$(curl -s -X POST "$URL/rest/v1/rpc/candidatar" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"vaga_id\":\"$VAGA\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('turno_id') or '')" 2>/dev/null || true)
[ "$de_novo" = "$TURNO" ] || falhou "reenviar a candidatura devolveu outro turno ($de_novo)"
ok "reenviar a candidatura devolve o mesmo turno"

recusa "candidatar em vaga que não existe" 404 nao_encontrado \
  '{"vaga_id":"00000000-0000-4000-8000-000000000000"}' candidatar

echo
echo "▸ Os meus turnos"
#
# A leitura que o profissional abre no dia do turno. É GET no contrato, e é aqui que
# isso se prova — o pgTAP chama a função e não sabe por qual verbo ela é exposta.

resp=$(get_rpc meus_turnos)
http=${resp%% *}; corpo=${resp#* }
[ "$http" = "200" ] || falhou "GET meus_turnos devolveu $http: $corpo"
achou=$(printf '%s' "$corpo" | python3 -c "
import json,sys
print(sum(1 for t in json.load(sys.stdin) if t['id'] == '$TURNO'))" 2>/dev/null || true)
[ "$achou" = "1" ] || falhou "o turno confirmado não apareceu em meus_turnos: $corpo"
ok "GET meus_turnos → 200, com o turno confirmado"

# RN10: o telefone tem porta própria. Uma lista que já o trouxesse tornaria o prazo
# de 7 dias decorativo.
printf '%s' "$corpo" | grep -qE '"(telefone|whatsapp_url)"' \
  && falhou "meus_turnos traz contato, e não deveria: $corpo"
ok "RN10: nenhum telefone sai por meus_turnos"

echo
echo "▸ O contato, com prazo"
#
# RN10 é a primeira regra do ciclo que depende do relógio, e o único lugar onde um
# telefone sai do servidor. O 403 do prazo não dá para exercitar por HTTP sem esperar
# sete dias — ele está no pgTAP, com o relógio do produto na mão.

resp=$(get_rpc contato_do_turno "--data-urlencode turno_id=$TURNO")
http=${resp%% *}; corpo=${resp#* }
[ "$http" = "200" ] || falhou "GET contato_do_turno devolveu $http: $corpo"
tel=$(printf '%s' "$corpo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('telefone',''))" 2>/dev/null || true)
[ -n "$tel" ] || falhou "o contato não veio: $corpo"
ok "GET contato_do_turno → 200, com o telefone da casa"

resp=$(get_rpc contato_do_turno "--data-urlencode turno_id=00000000-0000-4000-8000-000000000000")
http=${resp%% *}; corpo=${resp#* }
code=$(printf '%s' "$corpo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',''))" 2>/dev/null || true)
[ "$http" = "404" ] && [ "$code" = "nao_encontrado" ] \
  || falhou "contato de turno inexistente: HTTP $http code '$code', esperado 404 nao_encontrado"
ok "GET contato_do_turno de turno que não existe → 404 nao_encontrado"


echo
echo "▸ A presença"
#
# O caminho feliz do check-in depende da janela de 60 minutos antes do início, e a vaga
# deste ciclo começa em três dias — sobrepor o relógio do produto é coisa de pgTAP,
# dentro da transação. O que esta camada prova é o **status** das recusas, que o teste
# de banco não alcança.

AGORA=$(python3 -c "
import datetime as d; print(d.datetime.now(d.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")

recusa "check-in fora da janela de 60 min" 422 fora_da_janela \
  "{\"turno_id\":\"$TURNO\",\"distancia_m\":100,\"registrado_em\":\"$AGORA\"}" \
  fazer_checkin

recusa "check-out sem check-in" 409 checkin_pendente \
  "{\"turno_id\":\"$TURNO\",\"distancia_m\":100,\"registrado_em\":\"$AGORA\"}" \
  fazer_checkout

recusa "check-in em turno que não existe" 404 nao_encontrado \
  '{"turno_id":"00000000-0000-4000-8000-000000000000","distancia_m":10,"registrado_em":"2026-01-01T00:00:00Z"}' \
  fazer_checkin


echo
echo "▸ A avaliação e o perfil público"
#
# O turno deste ciclo começa em três dias, e a avaliação só abre depois do fim previsto
# (RN07): o 200, o reenvio idempotente e o 409 dependem do relógio do produto, que só se
# sobrepõe dentro da transação do pgTAP (tests/180_avaliar_e_perfil_publico.sql). O que
# esta camada prova é a rota, o verbo e o **status** — o 422 da regra chega como 422.

recusa "RN07: avaliar antes do fim do turno" 422 avaliacao_indisponivel \
  "{\"turno_id\":\"$TURNO\",\"resposta\":true}" avaliar

recusa "avaliar turno que não é seu" 403 sem_permissao \
  '{"turno_id":"00000000-0000-4000-8000-000000000000","resposta":true}' avaliar

PROF=$(chamar meu_perfil_profissional '{}' \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
[ -n "$PROF" ] || falhou "não consegui ler o id do perfil profissional"

# GET no contrato, como o painel: a função não escreve e responde na transação só de
# leitura do PostgREST.
resp=$(get_rpc perfil_publico "--data-urlencode id=$PROF")
http=${resp%% *}; corpo=${resp#* }
[ "$http" = "200" ] || falhou "GET perfil_publico do profissional devolveu $http: $corpo"
rep=$(printf '%s' "$corpo" | python3 -c "
import json,sys; d=json.load(sys.stdin); r=d.get('reputacao',{})
print(d.get('tipo'), r.get('total'), sorted(d), sorted(r))" 2>/dev/null || true)
[ "$rep" = "profissional 0 ['funcoes', 'id', 'nome', 'reputacao', 'tipo'] ['positivas', 'taxa_comparecimento', 'total', 'turnos_considerados', 'turnos_realizados']" ] \
  || falhou "perfil_publico do profissional fora do contrato: $corpo"
ok "GET perfil_publico → 200, PerfilPublico do contrato, sem histórico com total 0"

printf '%s' "$corpo" | grep -qE '"(telefone|email|nascimento|ponto_base)"|\+55' \
  && falhou "perfil_publico traz dado de contato: $corpo"
ok "RN10: nenhum telefone, e-mail, nascimento ou ponto base no perfil público"

resp=$(get_rpc perfil_publico "--data-urlencode id=$ESTAB")
http=${resp%% *}; corpo=${resp#* }
tipo=$(printf '%s' "$corpo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tipo',''))" 2>/dev/null || true)
[ "$http" = "200" ] && [ "$tipo" = "estabelecimento" ] \
  || falhou "GET perfil_publico do estabelecimento: HTTP $http, $corpo"
ok "GET perfil_publico do estabelecimento → 200"

resp=$(get_rpc perfil_publico "--data-urlencode id=00000000-0000-4000-8000-000000000000")
http=${resp%% *}; corpo=${resp#* }
code=$(printf '%s' "$corpo" | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',''))" 2>/dev/null || true)
[ "$http" = "404" ] && [ "$code" = "nao_encontrado" ] \
  || falhou "perfil_publico de id inexistente: HTTP $http code '$code', esperado 404 nao_encontrado"
ok "GET perfil_publico de id inexistente → 404 nao_encontrado"

echo
echo "▸ O que ainda não existe"
echo "  ⏭  o caminho feliz do check-in e da avaliação por HTTP pede um turno que já"
echo "     aconteceu, e o relógio do produto só se sobrepõe dentro do pgTAP."
echo
echo "Ciclo verificado até as recusas da presença e da avaliação, e o perfil público."
