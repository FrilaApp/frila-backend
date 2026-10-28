#!/usr/bin/env bash
# Smoke test (teste de fumaça) das 6 funções da v1.0 e da probe de saúde.
# Cartão 6ace0f26 · Brief B-002
#
# Testa a probe `saude` e as 6 funções da v1.0 que dependem de produção:
#   1. saude (Edge Function)
#   2. escolher_candidato (RPC)
#   3. incluir_na_equipe (RPC)
#   4. pedir_revisao_despacho (RPC)
#   5. abrir_suporte (RPC)
#   6. avisar_a_caminho (RPC)
#   7. exportar-turnos (Edge Function)
#
# Usa as contas de demonstração da revisão da loja via `entrar-demonstracao`.
#
# Entradas por argumento ou variáveis de ambiente (nunca segredos gravados):
#   ./scripts/fumaca-v1.sh <URL_DO_PROJETO> <ANON_KEY>
# Ou:
#   URL_DO_PROJETO=... ANON_KEY=... ./scripts/fumaca-v1.sh
#
# Variáveis opcionais de ambiente:
#   DEMONSTRACAO_CODIGO   Código numérico fixo de demonstração (se ausente, tenta carregar de .env.local/.env)
#   DEMONSTRACAO_EMAILS   Lista de e-mails de demonstração separados por vírgula (padrão: contratante,profissional)
#   TOKEN_CONTRATANTE     Token JWT Bearer do contratante de demonstração (bypass opcional de entrar-demonstracao)
#   TOKEN_PROFISSIONAL    Token JWT Bearer do profissional de demonstração (bypass opcional de entrar-demonstracao)

set -uo pipefail

# Carrega arquivos locais se existirem, sem falhar se ausentes
if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi
if [ -f supabase/functions/.env.local ]; then
  set -a
  # shellcheck source=/dev/null
  source supabase/functions/.env.local
  set +a
fi

URL_RAW="${1:-${URL_DO_PROJETO:-${SUPABASE_URL:-http://127.0.0.1:54321}}}"
URL="${URL_RAW%/}"

ANON="${2:-${ANON_KEY:-${SUPABASE_ANON_KEY:-}}}"
if [ -z "$ANON" ] && [[ "$URL" =~ ^http://(127\.0\.0\.1|localhost) ]]; then
  ANON=$(supabase status -o env 2>/dev/null | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p' || true)
fi

if [ -z "$ANON" ]; then
  printf 'Uso: %s <URL_DO_PROJETO> <ANON_KEY>\n' "$0" >&2
  printf 'Ou configure as variáveis de ambiente URL_DO_PROJETO e ANON_KEY.\n' >&2
  exit 1
fi

CODIGO="${DEMONSTRACAO_CODIGO:-}"
EMAILS="${DEMONSTRACAO_EMAILS:-revisao-contratante@frila.app,revisao-profissional@frila.app}"
CONTRATANTE="${EMAILS%%,*}"
PROFISSIONAL="${EMAILS##*,}"

TOKEN_CASA="${TOKEN_CONTRATANTE:-}"
TOKEN_PROF="${TOKEN_PROFISSIONAL:-}"

FALHAS=0

# Helper para chamadas HTTP
# Uso: chamar <metodo> <url> [json_body] [bearer_token]
chamar() {
  local metodo="$1"
  local destino="$2"
  local corpo="${3:-}"
  local bearer="${4:-}"

  local args=(-s -w '\n%{http_code}' -X "$metodo" "$destino" -H "apikey: $ANON")

  if [ -n "$bearer" ]; then
    args+=(-H "Authorization: Bearer $bearer")
  else
    args+=(-H "Authorization: Bearer $ANON")
  fi

  if [ -n "$corpo" ]; then
    args+=(-H 'Content-Type: application/json' -d "$corpo")
  fi

  curl "${args[@]}"
}

status_de() { printf '%s' "$1" | tail -1; }
corpo_de()  { printf '%s' "$1" | sed '$d'; }

campo() {
  local json="$1"
  local chave="$2"
  printf '%s' "$json" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    print('')
    raise SystemExit(0)
for parte in sys.argv[1].split('.'):
    if isinstance(d, list):
        try:
            d = d[int(parte)]
        except Exception:
            d = ''
    elif isinstance(d, dict):
        d = d.get(parte, '')
    else:
        d = ''
print(d if d is not None else '')" "$chave"
}

detalhe_erro() {
  local corpo="$1"
  local d
  for k in code erro error message msg details; do
    d=$(campo "$corpo" "$k")
    if [ -n "$d" ]; then
      printf '%s' "$d"
      return 0
    fi
  done
  printf 'desconhecido'
}

printf '=== Teste de Fumaça v1.0 ===\n'
printf 'Alvo: %s\n\n' "$URL"

# ── 1. Probe de Saúde ────────────────────────────────────────────────────────
printf '▸ Probe operacional de saúde:\n'
res_saude=$(chamar "GET" "$URL/functions/v1/saude")
status_saude=$(status_de "$res_saude")
corpo_saude=$(corpo_de "$res_saude")

if [ "$status_saude" = "200" ]; then
  printf '  saude: PASSOU (HTTP %s)\n' "$status_saude"
else
  detalhe=$(detalhe_erro "$corpo_saude")
  printf '  saude: FALHOU (HTTP %s - %s)\n' "$status_saude" "$detalhe"
  FALHAS=$((FALHAS + 1))
fi

# ── 2. Autenticação via Contas de Demonstração ────────────────────────────────
printf '\n▸ Autenticação com contas de demonstração (entrar-demonstracao):\n'

if [ -n "$TOKEN_CASA" ] && [ -n "$TOKEN_PROF" ]; then
  printf '  entrar-demonstracao: PASSOU (usando tokens fornecidos no ambiente)\n'
elif [ -z "$CODIGO" ]; then
  printf '  entrar-demonstracao: FALHOU (DEMONSTRACAO_CODIGO não informado no ambiente)\n'
  FALHAS=$((FALHAS + 1))
else
  porta="$URL/functions/v1/entrar-demonstracao"
  
  # Contratante
  res_c=$(chamar "POST" "$porta" "{\"email\":\"$CONTRATANTE\",\"codigo\":\"$CODIGO\"}")
  st_c=$(status_de "$res_c")
  corpo_c=$(corpo_de "$res_c")
  
  # Profissional
  res_p=$(chamar "POST" "$porta" "{\"email\":\"$PROFISSIONAL\",\"codigo\":\"$CODIGO\"}")
  st_p=$(status_de "$res_p")
  corpo_p=$(corpo_de "$res_p")

  if [ "$st_c" = "200" ] && [ "$st_p" = "200" ]; then
    TOKEN_CASA=$(campo "$corpo_c" "access_token")
    TOKEN_PROF=$(campo "$corpo_p" "access_token")
    printf '  entrar-demonstracao: PASSOU (HTTP 200 contratante e profissional)\n'
  else
    printf '  entrar-demonstracao: FALHOU (HTTP %s contratante, HTTP %s profissional)\n' "$st_c" "$st_p"
    FALHAS=$((FALHAS + 1))
  fi
fi

# Fallback tokens para chamadas se autenticação falhar
TOKEN_CASA="${TOKEN_CASA:-$ANON}"
TOKEN_PROF="${TOKEN_PROF:-$ANON}"

# ── 3. As 6 Funções da v1.0 ──────────────────────────────────────────────────
printf '\n▸ Verificação das 6 funções da v1.0:\n'

# 1/6: escolher_candidato (RPC)
# Aceita: 200 (se sucesso com candidatura) ou 403 sem_permissao (candidatura dummy/inexistente ou de outra casa, RF26/RN10).
# Falha se 404 (função não encontrada / PGRST202), 500 ou 401 (sem sessão).
res_esc=$(chamar "POST" "$URL/rest/v1/rpc/escolher_candidato" \
  '{"candidatura_id":"00000000-0000-0000-0000-000000000000"}' "$TOKEN_CASA")
st_esc=$(status_de "$res_esc")
corpo_esc=$(corpo_de "$res_esc")
cod_esc=$(campo "$corpo_esc" "code")

if [ "$st_esc" = "200" ] || { [ "$st_esc" = "403" ] && [ "$cod_esc" = "sem_permissao" ]; }; then
  printf '  escolher_candidato: PASSOU (HTTP %s)\n' "$st_esc"
else
  detalhe=$(detalhe_erro "$corpo_esc")
  printf '  escolher_candidato: FALHOU (HTTP %s - %s)\n' "$st_esc" "$detalhe"
  FALHAS=$((FALHAS + 1))
fi

# 2/6: incluir_na_equipe (RPC)
# Aceita: 200 (se sucesso), 404 nao_encontrado (profissional não cadastrado), ou 403 sem_permissao (não admin).
# Falha se PGRST 404 (função inexistente) ou 500.
res_inc=$(chamar "POST" "$URL/rest/v1/rpc/incluir_na_equipe" \
  '{"estabelecimento_id":"de000000-0000-4000-8000-000000000010","profissional_id":"00000000-0000-0000-0000-000000000000"}' "$TOKEN_CASA")
st_inc=$(status_de "$res_inc")
corpo_inc=$(corpo_de "$res_inc")
cod_inc=$(campo "$corpo_inc" "code")

if [ "$st_inc" = "200" ] || { [ "$st_inc" = "404" ] && [ "$cod_inc" = "nao_encontrado" ]; } || { [ "$st_inc" = "403" ] && [ "$cod_inc" = "sem_permissao" ]; }; then
  printf '  incluir_na_equipe: PASSOU (HTTP %s)\n' "$st_inc"
else
  detalhe=$(detalhe_erro "$corpo_inc")
  printf '  incluir_na_equipe: FALHOU (HTTP %s - %s)\n' "$st_inc" "$detalhe"
  FALHAS=$((FALHAS + 1))
fi

# 3/6: pedir_revisao_despacho (RPC)
# Aceita: 200 (protocolo criado) ou 409 contestacao_ja_aberta (opção B do contrato quando reexecutado).
res_rev=$(chamar "POST" "$URL/rest/v1/rpc/pedir_revisao_despacho" \
  '{"relato":"Solicitacao de revisao de despacho operacional para teste de fumaca"}' "$TOKEN_PROF")
st_rev=$(status_de "$res_rev")
corpo_rev=$(corpo_de "$res_rev")
cod_rev=$(campo "$corpo_rev" "code")

if [ "$st_rev" = "200" ] || { [ "$st_rev" = "409" ] && [ "$cod_rev" = "contestacao_ja_aberta" ]; }; then
  printf '  pedir_revisao_despacho: PASSOU (HTTP %s)\n' "$st_rev"
else
  detalhe=$(detalhe_erro "$corpo_rev")
  printf '  pedir_revisao_despacho: FALHOU (HTTP %s - %s)\n' "$st_rev" "$detalhe"
  FALHAS=$((FALHAS + 1))
fi

# 4/6: abrir_suporte (RPC)
# Aceita: 200 (protocolo gerado ou reenvio com mesma chave) ou 404 nao_encontrado (turno inexistente).
res_sup=$(chamar "POST" "$URL/rest/v1/rpc/abrir_suporte" \
  '{"turno_id":"8108b625-143e-44f7-bc19-9347025a0141","categoria":"outro","chave":"c0000000-0000-4000-8000-000000000001"}' "$TOKEN_PROF")
st_sup=$(status_de "$res_sup")
corpo_sup=$(corpo_de "$res_sup")
cod_sup=$(campo "$corpo_sup" "code")

if [ "$st_sup" = "200" ] || { [ "$st_sup" = "404" ] && [ "$cod_sup" = "nao_encontrado" ]; }; then
  printf '  abrir_suporte: PASSOU (HTTP %s)\n' "$st_sup"
else
  detalhe=$(detalhe_erro "$corpo_sup")
  printf '  abrir_suporte: FALHOU (HTTP %s - %s)\n' "$st_sup" "$detalhe"
  FALHAS=$((FALHAS + 1))
fi

# 5/6: avisar_a_caminho (RPC)
# Aceita: 200 (aviso registrado/idempotente) ou 422 a_caminho_fora_da_janela ou 403 sem_permissao.
res_cam=$(chamar "POST" "$URL/rest/v1/rpc/avisar_a_caminho" \
  '{"turno_id":"8108b625-143e-44f7-bc19-9347025a0141"}' "$TOKEN_PROF")
st_cam=$(status_de "$res_cam")
corpo_cam=$(corpo_de "$res_cam")
cod_cam=$(campo "$corpo_cam" "code")

if [ "$st_cam" = "200" ] || { [ "$st_cam" = "422" ] && [ "$cod_cam" = "a_caminho_fora_da_janela" ]; } || { [ "$st_cam" = "403" ] && [ "$cod_cam" = "sem_permissao" ]; }; then
  printf '  avisar_a_caminho: PASSOU (HTTP %s)\n' "$st_cam"
else
  detalhe=$(detalhe_erro "$corpo_cam")
  printf '  avisar_a_caminho: FALHOU (HTTP %s - %s)\n' "$st_cam" "$detalhe"
  FALHAS=$((FALHAS + 1))
fi

# 6/6: exportar-turnos (Edge Function)
# Aceita: 200 (CSV gerado) ou 204 No Content (sem turnos no período, UC13).
res_exp=$(chamar "POST" "$URL/functions/v1/exportar-turnos" \
  '{"formato":"csv"}' "$TOKEN_PROF")
st_exp=$(status_de "$res_exp")
corpo_exp=$(corpo_de "$res_exp")

if [ "$st_exp" = "200" ] || [ "$st_exp" = "204" ]; then
  printf '  exportar-turnos: PASSOU (HTTP %s)\n' "$st_exp"
else
  detalhe=$(detalhe_erro "$corpo_exp")
  printf '  exportar-turnos: FALHOU (HTTP %s - %s)\n' "$st_exp" "$detalhe"
  FALHAS=$((FALHAS + 1))
fi

printf '\n=== Resultado ===\n'
if [ "$FALHAS" -eq 0 ]; then
  printf 'Status: PASSOU (todas as verificações foram bem-sucedidas)\n'
  exit 0
else
  printf 'Status: FALHOU (%d falha(s) encontrada(s))\n' "$FALHAS"
  exit 1
fi
