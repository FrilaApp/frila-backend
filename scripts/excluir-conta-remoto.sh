#!/usr/bin/env bash
# Prova de ponta a ponta da exclusão de conta no remoto (cartão OrS9gEfU, critério 4).
#
# O pgTAP (tests/290_excluir_conta.sql) prova a regra dentro do banco. Este script prova
# o que só se vê de fora: a Edge Function `excluir-conta` no ar, o PostgREST, o Auth e
# o estado que sobra para a outra parte. Ele cria duas contas descartáveis, faz as duas
# terem um turno passado e um futuro entre si, exclui uma e confere cada efeito que o
# cartão promete:
#
#   - a conta não entra (token antigo → 401; credencial sumiu do Auth → 404);
#   - não recebe despacho (privado.elegiveis não a lista);
#   - não aparece em busca (perfil_publico → "Conta encerrada");
#   - o turno futuro foi cancelado e a vaga reaberta;
#   - o turno passado da outra parte mostra "Conta encerrada" sem mudar a reputação dela.
#
# Só frila-dev. As contas são criadas pela Auth Admin API com e-mails em `@frila.test`
# (domínio reservado, RFC 2606) e apagadas no fim, mesmo quando um passo falha. A chave de
# serviço e a anon vêm da Management API e ficam só na memória do processo: nada é
# impresso, gravado ou passado por argumento.
#
# Uso:
#   SUPABASE_ACCESS_TOKEN=$(tr -d '\n' < ~/.config/frila/supabase-token) \
#     ./scripts/excluir-conta-remoto.sh dev [--seco]
#
#   --seco  mostra o que faria e sai sem tocar no remoto.
#
# Variáveis (opcionais, do .env): FRILA_DEV_PROJECT_REF. Sem ela, o projeto é achado pelo
# nome `frila-dev` na lista da Management API.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

AMBIENTE="${1:?uso: $0 dev [--seco]}"
shift
SECO=false
for arg in "$@"; do
  case "$arg" in
    --seco) SECO=true ;;
    *) printf 'Opção desconhecida: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

[ -f .env ] && { set -a; source .env; set +a; }

ok()     { printf '  ✓ %s\n' "$1"; }
aviso()  { printf '  ⚠ %s\n' "$1" >&2; }
falhou() { printf '  ✗ %s\n' "$1" >&2; exit 1; }

# A exclusão apaga a credencial no Auth. Em produção isso é irreversível e o único
# motivo para rodar lá seria apagar conta de gente de verdade — que é o que a revisão da
# Apple proíbe. Este script não aceita `prod`, nem com a variável de confirmação.
case "$AMBIENTE" in
  dev) NOME_ESPERADO="frila-dev" ;;
  *) falhou "este script só roda no frila-dev (recebi '$AMBIENTE')" ;;
esac

API="https://api.supabase.com/v1"
EMAIL_A="exclusao-a-$(date +%s)-$$-$RANDOM@frila.test"
EMAIL_B="exclusao-b-$(date +%s)-$$-$RANDOM@frila.test"

if $SECO; then
  echo "▸ Modo seco: o que seria feito no $NOME_ESPERADO"
  echo "    1. Conferir SUPABASE_ACCESS_TOKEN na Management API e achar o projeto $NOME_ESPERADO"
  echo "    2. Ler anon e service_role de /projects/\$REF/api-keys (só em memória)"
  echo "    3. Criar A ($EMAIL_A) e B ($EMAIL_B) por POST /auth/v1/admin/users"
  echo "    4. Abrir sessão de cada um por admin/generate_link (magiclink) + /auth/v1/verify"
  echo "    5. B: criar_conta contratante, cadastrar_estabelecimento; A: criar_conta profissional, criar_perfil_profissional"
  echo "    6. SQL (semeadura do pgTAP 290): turno passado cumprido, turno futuro confirmado e vaga aberta entre A e B"
  echo "    7. A avalia B pelo turno passado; GET meus_turnos de A confere a semeadura"
  echo "    8. POST /functions/v1/excluir-conta como A, {confirmar: true} → 202"
  echo "    9. Verificar: Auth 404, token antigo 401, elegiveis sem A, perfil_publico 'Conta encerrada',"
  echo "       usuário anonimizado, posição futura cancelada e vaga reaberta, painel de B 'Conta encerrada',"
  echo "       reputação de B igual antes e depois, pedido de exclusão registrado"
  echo "   10. Limpar: linhas criadas (por id) e os usuários do Auth (A, se sobrou, e B)"
  exit 0
fi

# ── Management API ─────────────────────────────────────────────────────────────

http_mgmt=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN:-}" "$API/projects")
[ "$http_mgmt" = "200" ] || falhou "a Management API respondeu $http_mgmt: SUPABASE_ACCESS_TOKEN ausente ou inválido"

REF="${FRILA_DEV_PROJECT_REF:-}"
if [ -z "$REF" ]; then
  REF=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" "$API/projects" \
    | python3 -c 'import json,sys
ps = [p for p in json.load(sys.stdin) if p.get("name") == sys.argv[1]]
print(ps[0]["id"] if len(ps) == 1 else "")' "$NOME_ESPERADO")
fi
[ -n "$REF" ] || falhou "não achei um projeto chamado $NOME_ESPERADO na Management API"

nome=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" "$API/projects/$REF" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || true)
[ "$nome" = "$NOME_ESPERADO" ] || falhou "o projeto $REF chama-se '$nome', esperado $NOME_ESPERADO"
ok "projeto $NOME_ESPERADO ($REF)"

# As chaves ficam em variáveis do processo e não saem daqui. Nada de `set -x`.
chaves=$(curl -s -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" "$API/projects/$REF/api-keys?reveal=true")
ANON=$(printf '%s' "$chaves" | python3 -c 'import json,sys
print(next((k["api_key"] for k in json.load(sys.stdin) if k.get("name") == "anon"), ""))')
SR=$(printf '%s' "$chaves" | python3 -c 'import json,sys
print(next((k["api_key"] for k in json.load(sys.stdin) if k.get("name") == "service_role"), ""))')
unset chaves
[ -n "$ANON" ] && [ -n "$SR" ] || falhou "a Management API não devolveu anon e service_role"
ok "chaves anon e service_role lidas (só em memória)"

URL="https://$REF.supabase.co"

# Segurança extra: as contas de demonstração nunca entram aqui. Os e-mails deste script
# são gerados por execução e o nome do domínio é reservado; se, mesmo assim, alguém
# apontar DEMONSTRACAO_EMAILS para um deles, o script para antes de criar qualquer coisa.
case ",${DEMONSTRACAO_EMAILS:-}," in
  *",$EMAIL_A,"*|*",$EMAIL_B,"*) falhou "e-mail de teste colide com DEMONSTRACAO_EMAILS" ;;
esac

# ── Helpers ───────────────────────────────────────────────────────────────────

json_campo() { # json_campo <chave> ← JSON no stdin (objeto, ou lista: 1ª linha)
  python3 -c 'import json,sys
d = json.load(sys.stdin)
if isinstance(d, list): d = d[0] if d else {}
v = d.get(sys.argv[1], "") if isinstance(d, dict) else ""
print("" if v is None else v)' "$1" 2>/dev/null || true
}

sql() { # sql "<query>" → JSON das linhas; falha se a API recusar
  local tmp http corpo
  tmp=$(mktemp)
  http=$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$API/projects/$REF/database/query" \
    -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$1")")
  corpo=$(cat "$tmp"); rm -f "$tmp"
  case "$http" in
    200|201) printf '%s' "$corpo" ;;
    *) printf 'SQL recusado (%s): %s\n' "$http" "$corpo" >&2; return 1 ;;
  esac
}

sql1() { sql "$1" | json_campo "$2"; } # sql1 "<query>" <coluna> → valor da 1ª linha

admin() { # admin <método> <caminho> [<json>] → "http corpo"
  local tmp http
  tmp=$(mktemp)
  http=$(curl -s -o "$tmp" -w '%{http_code}' -X "$1" "$URL/auth/v1/admin/$2" \
    -H "apikey: $SR" -H "Authorization: Bearer $SR" -H 'Content-Type: application/json' \
    ${3:+-d "$3"})
  printf '%s %s' "$http" "$(cat "$tmp")"
  rm -f "$tmp"
}

rpc() { # rpc <token> <rota> <json> → "http corpo" (POST, como o app)
  local tmp http
  tmp=$(mktemp)
  http=$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$URL/rest/v1/rpc/$2" \
    -H "apikey: $ANON" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$3")
  printf '%s %s' "$http" "$(cat "$tmp")"
  rm -f "$tmp"
}

rpc_get() { # rpc_get <token> <rota> [--data-urlencode k=v ...] → "http corpo"
  local token="$1" rota="$2" tmp http
  shift 2
  tmp=$(mktemp)
  http=$(curl -s -o "$tmp" -w '%{http_code}' -G "$URL/rest/v1/rpc/$rota" \
    -H "apikey: $ANON" -H "Authorization: Bearer $token" "$@")
  printf '%s %s' "$http" "$(cat "$tmp")"
  rm -f "$tmp"
}

# Sessão sem caixa de e-mail: o mesmo caminho do `entrar-demonstracao`.
sessao_de() { # sessao_de <email> → access_token
  local otp sessao
  otp=$(admin POST generate_link "{\"type\":\"magiclink\",\"email\":\"$1\"}" | cut -d' ' -f2- | json_campo email_otp)
  [ -n "$otp" ] || return 1
  sessao=$(curl -s -X POST "$URL/auth/v1/verify" -H "apikey: $ANON" -H 'Content-Type: application/json' \
    -d "{\"type\":\"magiclink\",\"email\":\"$1\",\"token\":\"$otp\"}")
  printf '%s' "$sessao" | json_campo access_token
}

em() { python3 -c "import datetime as d; print((d.datetime.now(d.timezone.utc)+d.timedelta(hours=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }

# ── Limpeza: roda sempre, inclusive quando um passo falha ──────────────────────

ID_A=""; ID_B=""; PROF_A=""; ESTAB=""
VERIFICACOES_OK=0; VERIFICACOES_FALHAS=0; NAO_EXECUTADAS=0

verifica() { # verifica "<descrição>" <valor> <esperado>
  if [ "$2" = "$3" ]; then
    VERIFICACOES_OK=$((VERIFICACOES_OK + 1)); ok "$1 → $2"
  else
    VERIFICACOES_FALHAS=$((VERIFICACOES_FALHAS + 1)); printf '  ✗ %s → %s (esperado %s)\n' "$1" "$2" "$3" >&2
  fi
}

nao_executada() { NAO_EXECUTADAS=$((NAO_EXECUTADAS + 1)); printf '  – %s → não executada (bloqueio do ambiente)\n' "$1"; }

apagar_auth() { # apagar_auth <id> <email esperado>: só apaga se o e-mail bater
  local resp http email
  [ -n "$1" ] || return 0
  resp=$(admin GET "users/$1")
  http=${resp%% *}
  [ "$http" = "404" ] && { ok "Auth: $2 já não existia"; return 0; }
  email=$(printf '%s' "${resp#* }" | json_campo email)
  [ "$email" = "$2" ] || { aviso "Auth: $1 não é $2 (é '$email'); não apago"; return 0; }
  http=$(admin DELETE "users/$1" | cut -d' ' -f1)
  case "$http" in
    200|204) ok "Auth: $2 apagado" ;;
    *) aviso "Auth: não consegui apagar $2 ($http)" ;;
  esac
}

limpar() {
  local codigo=$? resp
  trap - EXIT
  echo
  echo "▸ Limpeza"
  if [ -n "$ID_A$ID_B" ]; then
    resp=$(sql "
create temp table falhas_limpeza (comando text, erro text);
do \$\$
declare c text;
begin
  foreach c in array array[
    \$q\$delete from public.avaliacao where autor_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)
        or turno_id in (select t.id from public.turno t join public.posicao p on p.id = t.posicao_id
                        join public.vaga g on g.id = p.vaga_id where g.estabelecimento_id = nullif('$ESTAB','')::uuid)\$q\$,
    \$q\$delete from public.ocorrencia where usuario_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid) or autor_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)
        or posicao_id in (select p.id from public.posicao p join public.vaga g on g.id = p.vaga_id
                          where g.estabelecimento_id = nullif('$ESTAB','')::uuid)\$q\$,
    \$q\$delete from public.notificacao where profissional_id = nullif('$PROF_A','')::uuid\$q\$,
    \$q\$delete from public.notificacao where usuario_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)\$q\$,
    \$q\$delete from public.turno where posicao_id in (select p.id from public.posicao p
        join public.vaga g on g.id = p.vaga_id where g.estabelecimento_id = nullif('$ESTAB','')::uuid)\$q\$,
    \$q\$delete from public.candidatura where profissional_id = nullif('$PROF_A','')::uuid
        or posicao_id in (select p.id from public.posicao p join public.vaga g on g.id = p.vaga_id
                          where g.estabelecimento_id = nullif('$ESTAB','')::uuid)\$q\$,
    \$q\$delete from public.despacho where vaga_id in (select id from public.vaga where estabelecimento_id = nullif('$ESTAB','')::uuid)\$q\$,
    \$q\$delete from public.posicao where vaga_id in (select id from public.vaga where estabelecimento_id = nullif('$ESTAB','')::uuid)\$q\$,
    \$q\$delete from public.vaga where estabelecimento_id = nullif('$ESTAB','')::uuid\$q\$,
    \$q\$delete from public.membro_estabelecimento where estabelecimento_id = nullif('$ESTAB','')::uuid or usuario_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)\$q\$,
    \$q\$delete from public.estabelecimento where id = nullif('$ESTAB','')::uuid\$q\$,
    \$q\$delete from public.disponibilidade where profissional_id = nullif('$PROF_A','')::uuid\$q\$,
    \$q\$delete from public.profissional_funcao where profissional_id = nullif('$PROF_A','')::uuid\$q\$,
    \$q\$delete from public.profissional where id = nullif('$PROF_A','')::uuid or usuario_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)\$q\$,
    \$q\$delete from public.dispositivo where usuario_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)\$q\$,
    \$q\$delete from public.evento_app where usuario_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)\$q\$,
    \$q\$delete from public.bloqueio where autor_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid) or alvo_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)\$q\$,
    \$q\$delete from public.pedido_de_exclusao where usuario_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)\$q\$,
    \$q\$delete from privado.escrita_por_conta where usuario_id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)\$q\$,
    \$q\$delete from public.usuario where id in (nullif('$ID_A','')::uuid, nullif('$ID_B','')::uuid)\$q\$
  ] loop
    begin
      execute c;
    exception when undefined_column or undefined_table then
      null; -- tabela ou coluna que esta versão do esquema não tem: nada a limpar
    when others then
      insert into falhas_limpeza values (left(c, 60), sqlerrm);
    end;
  end loop;
end \$\$;
select count(*)::int as n, coalesce(string_agg(comando || ' → ' || erro, ' | '), '') as erros from falhas_limpeza;
" 2>&1) || { aviso "limpeza SQL não rodou: $resp"; resp='{"n":"?"}'; }
    n=$(printf '%s' "$resp" | json_campo n)
    if [ "$n" = "0" ]; then
      ok "banco: linhas de A, B, estabelecimento, vagas e turnos apagadas"
    else
      aviso "banco: $n comando(s) de limpeza falharam: $(printf '%s' "$resp" | json_campo erros)"
    fi
  fi
  apagar_auth "$ID_A" "$EMAIL_A"
  apagar_auth "$ID_B" "$EMAIL_B"
  unset SR ANON TOKEN_A TOKEN_B
  echo
  if [ "$codigo" -ne 0 ]; then
    printf 'Interrompido antes do fim (código %s).\n' "$codigo"
    exit "$codigo"
  fi
  printf 'Verificações: %s OK, %s falharam, %s não executadas.\n' "$VERIFICACOES_OK" "$VERIFICACOES_FALHAS" "$NAO_EXECUTADAS"
  [ "$VERIFICACOES_FALHAS" -eq 0 ] && [ "$NAO_EXECUTADAS" -eq 0 ]
}
trap limpar EXIT

# ── As contas ──────────────────────────────────────────────────────────────────

echo
echo "▸ As contas descartáveis"

resp=$(admin POST users "{\"email\":\"$EMAIL_A\",\"email_confirm\":true}")
ID_A=$(printf '%s' "${resp#* }" | json_campo id)
[ -n "$ID_A" ] || falhou "Auth não criou A (${resp%% *})"
resp=$(admin POST users "{\"email\":\"$EMAIL_B\",\"email_confirm\":true}")
ID_B=$(printf '%s' "${resp#* }" | json_campo id)
[ -n "$ID_B" ] || falhou "Auth não criou B (${resp%% *})"
ok "A e B criados no Auth ($EMAIL_A, $EMAIL_B)"

TOKEN_A=$(sessao_de "$EMAIL_A") || true
TOKEN_B=$(sessao_de "$EMAIL_B") || true
[ -n "$TOKEN_A" ] && [ -n "$TOKEN_B" ] || falhou "não consegui abrir sessão por generate_link + verify"
ok "sessões abertas por magic link, sem caixa de e-mail"

resp=$(rpc "$TOKEN_B" criar_conta '{"perfil":"contratante","nome":"Bar da Exclusão","telefone":"+5561999990001","nascimento":"1980-01-01","termos_versao":"2026-09-22"}')
[ "$(printf '%s' "${resp#* }" | json_campo perfil)" = "contratante" ] || falhou "criar_conta de B: $resp"
resp=$(rpc "$TOKEN_A" criar_conta '{"perfil":"profissional","nome":"Profissional da Exclusão","telefone":"+5561999990002","nascimento":"1995-01-01","termos_versao":"2026-09-22"}')
[ "$(printf '%s' "${resp#* }" | json_campo perfil)" = "profissional" ] || falhou "criar_conta de A: $resp"
ok "criar_conta: B contratante, A profissional"

CNPJ=$(python3 -c "
import random
b=[random.randint(0,9) for _ in range(8)]+[0,0,0,1]
def dv(ds,ps):
    r=sum(d*p for d,p in zip(ds,ps))%11
    return 0 if r<2 else 11-r
p1=[5,4,3,2,9,8,7,6,5,4,3,2]; b.append(dv(b,p1)); b.append(dv(b,[6]+p1))
print(''.join(map(str,b)))")
resp=$(rpc "$TOKEN_B" cadastrar_estabelecimento "{\"nome\":\"Bar da Exclusão\",\"documento\":\"$CNPJ\",\"tipo\":\"food_service\",\"endereco\":\"CLN 201\",\"ponto\":{\"latitude\":-15.7942,\"longitude\":-47.8822}}")
ESTAB=$(printf '%s' "${resp#* }" | json_campo id)
[ -n "$ESTAB" ] || falhou "cadastrar_estabelecimento: $resp"
ok "B administra o estabelecimento $ESTAB"

FUNCAO=$(curl -s "$URL/rest/v1/funcao?select=id&nome=eq.gar%C3%A7om" \
  -H "apikey: $ANON" -H "Authorization: Bearer $TOKEN_A" | json_campo id)
[ -n "$FUNCAO" ] || falhou "não li a função garçom pelo catálogo"
# Disponível todos os dias, o dia inteiro: a vaga aberta cai em qualquer horário, e o
# despacho (privado.elegiveis) só lista quem tem grade que cubra o turno (RF18).
DISPONIBILIDADES=$(python3 -c 'import json; print(json.dumps([{"dia_semana": d, "hora_inicio": "00:00", "hora_fim": "23:59"} for d in range(7)]))')
resp=$(rpc "$TOKEN_A" criar_perfil_profissional "{\"funcoes\":[\"$FUNCAO\"],\"ponto_base\":{\"latitude\":-15.7650,\"longitude\":-47.8830},\"disponibilidades\":$DISPONIBILIDADES}")
PROF_A=$(printf '%s' "${resp#* }" | json_campo id)
[ -n "$PROF_A" ] || falhou "criar_perfil_profissional: $resp"
ok "A tem perfil profissional $PROF_A (garçom)"

# ── Os turnos entre A e B ──────────────────────────────────────────────────────

echo
echo "▸ Um turno passado, um futuro e uma vaga aberta"
#
# Publicar por RPC enfileira o despacho, e o gatilho da fila exige `frila.agendador_secret`
# no banco — que o frila-dev não tem hoje (docs/RUNBOOK-INCIDENTES.md, item 1; cabe ao
# dono resolver). A semeadura é então a do pgTAP 290: vaga, posição e turno inseridos por
# SQL, com as mesmas colunas e os mesmos estados, e conferidos por HTTP logo em seguida.

uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }
VAGA_PASSADA=$(uuid); POS_PASSADA=$(uuid); TURNO_PASSADO=$(uuid)
VAGA_FUTURA=$(uuid);  POS_FUTURA=$(uuid);  TURNO_FUTURO=$(uuid)
VAGA_ABERTA=$(uuid);  POS_ABERTA=$(uuid)

PONTO="extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography"
sql "
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto,
                         local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
values
  ('$VAGA_PASSADA', '$ESTAB', '$FUNCAO', '$ID_B', now() - interval '2 days', now() - interval '2 days' + interval '6 hours',
   15000, 'preenchida', $PONTO, 'SCLS 402', 'urgencia', 1, false, false, false, 'Maria', gen_random_uuid()),
  ('$VAGA_FUTURA', '$ESTAB', '$FUNCAO', '$ID_B', now() + interval '4 days', now() + interval '4 days' + interval '6 hours',
   18000, 'preenchida', $PONTO, 'SCLS 402', 'urgencia', 1, false, false, false, 'Maria', gen_random_uuid()),
  ('$VAGA_ABERTA', '$ESTAB', '$FUNCAO', '$ID_B', now() + interval '5 days', now() + interval '5 days' + interval '6 hours',
   17000, 'publicada', $PONTO, 'SCLS 402', 'urgencia', 1, false, false, false, 'Maria', gen_random_uuid());
insert into public.posicao (id, vaga_id, profissional_id, estado, inicio_em, fim_em, confirmado_em, falta)
values
  ('$POS_PASSADA', '$VAGA_PASSADA', '$PROF_A', 'cumprida', now() - interval '2 days', now() - interval '2 days' + interval '6 hours', now() - interval '3 days', false),
  ('$POS_FUTURA',  '$VAGA_FUTURA',  '$PROF_A', 'confirmada', now() + interval '4 days', now() + interval '4 days' + interval '6 hours', now() - interval '1 hour', false);
insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
values ('$POS_ABERTA', '$VAGA_ABERTA', 'aberta', now() + interval '5 days', now() + interval '5 days' + interval '6 hours');
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('$TURNO_PASSADO', '$POS_PASSADA', now() - interval '2 days', 'geolocalizado', 15, 'verificado', 15000);
insert into public.turno (id, posicao_id, valor_acordado_centavos, verificacao)
values ('$TURNO_FUTURO', '$POS_FUTURA', 18000, 'pendente');
select 1 as n" >/dev/null || falhou "não consegui semear as vagas, posições e turnos"
ok "semeado por SQL (pgTAP 290): turno passado cumprido, turno futuro confirmado, vaga aberta"

meus=$(rpc_get "$TOKEN_A" meus_turnos | cut -d' ' -f2- \
  | python3 -c 'import json,sys; ids={t.get("id") for t in json.load(sys.stdin)}; print(sum(1 for a in sys.argv[1:] if a in ids))' \
    "$TURNO_PASSADO" "$TURNO_FUTURO" 2>/dev/null || echo 0)
[ "$meus" = "2" ] || falhou "GET meus_turnos de A não lista os dois turnos semeados ($meus de 2)"
ok "GET meus_turnos de A lista o turno passado e o futuro"

resp=$(rpc "$TOKEN_A" avaliar "{\"turno_id\":\"$TURNO_PASSADO\",\"resposta\":true}")
case "${resp%% *}" in
  200) ok "A avaliou B pelo turno passado (reputação de B deixa de ser zero)" ;;
  *) aviso "A não conseguiu avaliar B (${resp%% *} $(printf '%s' "${resp#* }" | json_campo code)); a reputação segue como está" ;;
esac

reputacao_de_b() { # reputacao_de_b → "positivas/total (SQL) · reputação do perfil público (HTTP)"
  local s h
  s=$(sql "select aval_positivas::text || '/' || aval_total::text as r from public.estabelecimento where id = nullif('$ESTAB','')::uuid" | json_campo r)
  h=$(rpc_get "$TOKEN_B" perfil_publico --data-urlencode "id=$ESTAB" | cut -d' ' -f2- \
    | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin).get("reputacao"), sort_keys=True))' 2>/dev/null || true)
  printf '%s %s' "$s" "$h"
}
elegivel_a() { sql1 "select count(*)::int as n from privado.elegiveis('$VAGA_ABERTA'::uuid) where profissional_id = nullif('$PROF_A','')::uuid" n; }

REPUTACAO_ANTES=$(reputacao_de_b)
ok "antes: reputação de B = $REPUTACAO_ANTES; minha_conta de A → $(rpc "$TOKEN_A" minha_conta '{}' | cut -d' ' -f1)"
verifica "antes: A elegível para a vaga aberta (despacho)" "$(elegivel_a)" "1"

segredo=$(sql1 "select case when nullif(current_setting('frila.agendador_secret', true), '') is null then 'ausente' else 'presente' end as s" s)
ok "frila.agendador_secret no banco: $segredo (a reabertura do turno futuro depende dele)"

# ── A exclusão ─────────────────────────────────────────────────────────────────

echo
echo "▸ POST /functions/v1/excluir-conta como A"

excluir() { # excluir <token> → "http corpo"
  local tmp http
  tmp=$(mktemp)
  http=$(curl -s -o "$tmp" -w '%{http_code}' -X POST "$URL/functions/v1/excluir-conta" \
    -H "apikey: $ANON" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d '{"confirmar":true}')
  printf '%s %s' "$http" "$(cat "$tmp")"
  rm -f "$tmp"
}

COM_TURNO_FUTURO=true
resp=$(excluir "$TOKEN_A"); http=${resp%% *}; corpo=${resp#* }
if [ "$http" != "202" ] && [ "$segredo" = "ausente" ]; then
  # O caminho do turno futuro reabre a posição e enfileira o despacho; sem o segredo o
  # gatilho da fila levanta erro, a transação volta e a função responde 500. Fica
  # registrado como falha; o resto da prova segue sem o turno futuro.
  verifica "exclusão com turno futuro (reabertura precisa do agendador_secret)" "$http $(printf '%s' "$corpo" | json_campo code)" "202"
  # A causa, dita pelo banco: a mesma função, chamada por SQL, devolve o erro do gatilho.
  causa=$(sql "select privado.excluir_conta('$ID_A'::uuid) as dados" 2>&1 | python3 -c 'import json,sys,re
m = re.search(r"\{.*\}", sys.stdin.read(), re.S)
print((json.loads(m.group(0)).get("message", "") if m else "")[:120])' 2>/dev/null || true)
  aviso "causa no banco: ${causa:-(sem mensagem)}"
  sql "delete from public.turno where id = '$TURNO_FUTURO';
       delete from public.posicao where id = '$POS_FUTURA';
       delete from public.vaga where id = '$VAGA_FUTURA';
       select 1 as n" >/dev/null || falhou "não consegui retirar o turno futuro para seguir a prova"
  COM_TURNO_FUTURO=false
  aviso "turno futuro retirado por SQL; a exclusão vai de novo, só com o turno passado"
  resp=$(excluir "$TOKEN_A"); http=${resp%% *}; corpo=${resp#* }
fi
verifica "excluir-conta responde" "$http" "202"
if $COM_TURNO_FUTURO; then
  verifica "turnos_cancelados no corpo" "$(printf '%s' "$corpo" | json_campo turnos_cancelados)" "1"
else
  verifica "turnos_cancelados no corpo" "$(printf '%s' "$corpo" | json_campo turnos_cancelados)" "0"
fi

# ── O que o cartão promete ─────────────────────────────────────────────────────

echo
echo "▸ Depois da exclusão"

verifica "credencial sumiu do Auth (GET admin/users/A)" "$(admin GET "users/$ID_A" | cut -d' ' -f1)" "404"
verifica "token antigo de A em minha_conta" "$(rpc "$TOKEN_A" minha_conta '{}' | cut -d' ' -f1)" "401"
verifica "token antigo de A em candidatar" "$(rpc "$TOKEN_A" candidatar "{\"vaga_id\":\"$VAGA_ABERTA\"}" | cut -d' ' -f1)" "401"
verifica "excluir de novo com o token antigo" "$(excluir "$TOKEN_A" | cut -d' ' -f1)" "401"
verifica "A elegível para a vaga aberta (despacho)" "$(elegivel_a)" "0"
verifica "perfil_publico de A, visto por B" \
  "$(rpc_get "$TOKEN_B" perfil_publico --data-urlencode "id=$PROF_A" | cut -d' ' -f2- | json_campo nome)" "Conta encerrada"
verifica "usuario de A anonimizado (nome|email|telefone|estado)" \
  "$(sql1 "select nome || '|' || coalesce(email,'') || '|' || coalesce(telefone,'') || '|' || estado::text as r from public.usuario where id = nullif('$ID_A','')::uuid" r)" \
  "Conta encerrada|||anonimizada"
verifica "pedido de exclusão registrado para A (estado)" \
  "$(sql1 "select estado from public.pedido_de_exclusao where usuario_id = nullif('$ID_A','')::uuid" estado)" "concluido"
if $COM_TURNO_FUTURO; then
  verifica "posição futura de A (estado|falta)" \
    "$(sql1 "select estado::text || '|' || falta::text as r from public.posicao where id = '$POS_FUTURA'" r)" "cancelada|false"
  verifica "vaga futura reaberta (estado|posições abertas)" \
    "$(sql1 "select g.estado::text || '|' || (select count(*) from public.posicao p where p.vaga_id = g.id and p.estado = 'aberta')::text as r from public.vaga g where g.id = '$VAGA_FUTURA'" r)" \
    "publicada|1"
  verifica "ocorrência de cancelamento com motivo" \
    "$(sql1 "select motivo from public.ocorrencia where posicao_id = '$POS_FUTURA' and tipo = 'cancelamento' limit 1" motivo)" \
    "exclusão de conta"
else
  nao_executada "posição futura de A cancelada sem falta"
  nao_executada "vaga futura reaberta com posição nova"
  nao_executada "ocorrência de cancelamento com motivo 'exclusão de conta'"
fi
verifica "turno passado no painel de B mostra" \
  "$(rpc_get "$TOKEN_B" painel_estabelecimento --data-urlencode "estabelecimento_id=$ESTAB" \
      --data-urlencode "de=$(em -120)" --data-urlencode "ate=$(em 240)" | cut -d' ' -f2- \
    | python3 -c 'import json,sys
d = json.load(sys.stdin)
print(next((p.get("profissional", {}).get("nome", "") for v in d.get("vagas", []) for p in v.get("posicoes", [])
            if p.get("id") == sys.argv[1]), "(posição não listada)"))' "$POS_PASSADA" 2>/dev/null || echo "(painel ilegível)")" \
  "Conta encerrada"
verifica "reputação de B (SQL positivas/total · perfil público) igual à de antes" "$(reputacao_de_b)" "$REPUTACAO_ANTES"
