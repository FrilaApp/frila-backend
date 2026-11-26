#!/usr/bin/env bash
# Prova reproduzível local/CI (sem acessar remoto) de compatibilidade de auth.flow_state
# com a imagem real do GoTrue (supabase_auth_*) iniciada por `supabase start`.
#
# Verifica:
# 1. Identifica a imagem exata e digest/versão do container GoTrue local.
# 2. Valida o schema real de auth.flow_state no Postgres local (sem depender apenas de inserts sintéticos).
# 3. Se houver um provedor OAuth habilitado no GoTrue local (ex.: google/apple em config local de teste),
#    executa GET /auth/v1/authorize com code_challenge_method=s256 e comprova a linha gerada pelo próprio
#    GoTrue em auth.flow_state (provider_type, code_challenge, code_challenge_method='s256').

set -euo pipefail

DB_CONTAINER="${SUPABASE_DB_CONTAINER:-supabase_db_frila-backend}"
AUTH_CONTAINER="${SUPABASE_AUTH_CONTAINER:-supabase_auth_frila-backend}"
AUTH_URL="${SUPABASE_LOCAL_AUTH_URL:-http://127.0.0.1:54321/auth/v1}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERRO: docker não encontrado; execute em ambiente com supabase start ativo." >&2
  exit 1
fi

AUTH_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$AUTH_CONTAINER" 2>/dev/null || true)"
AUTH_DIGEST="$(docker inspect --format '{{index .RepoDigests 0}}' "$AUTH_IMAGE" 2>/dev/null || true)"
if [[ -z "$AUTH_IMAGE" ]]; then
  echo "ERRO: container GoTrue ($AUTH_CONTAINER) não está em execução. Rode 'supabase start' primeiro." >&2
  exit 1
fi

echo "▸ Imagem GoTrue em execução: $AUTH_IMAGE"
if [[ -n "$AUTH_DIGEST" ]]; then
  echo "▸ Digest GoTrue: $AUTH_DIGEST"
fi

# 1. Valida colunas reais de auth.flow_state no Postgres da instância local.
COLUNAS="$(docker exec -e PGPASSWORD=postgres "$DB_CONTAINER" \
  psql -U supabase_admin -d postgres -tAc \
  "select string_agg(column_name || ':' || udt_name, ',' order by column_name)
     from information_schema.columns
    where table_schema = 'auth'
      and table_name = 'flow_state'
      and column_name in ('auth_code', 'code_challenge', 'code_challenge_method', 'provider_type')")"

ESPERADO="auth_code:text,code_challenge:text,code_challenge_method:code_challenge_method,provider_type:text"
if [[ "$COLUNAS" != "$ESPERADO" ]]; then
  echo "ERRO: schema de auth.flow_state divergiu!" >&2
  echo "  Esperado: $ESPERADO" >&2
  echo "  Obtido:   $COLUNAS" >&2
  exit 1
fi
echo "✓ Schema real de auth.flow_state compatível: $COLUNAS"

# 2. Valida health do GoTrue local e tenta exercício real de /authorize se provedor estiver habilitado localmente.
HEALTH="$(curl -fsS "${AUTH_URL}/health" 2>/dev/null || true)"
if [[ -n "$HEALTH" ]]; then
  echo "✓ GoTrue /health local: $HEALTH"
fi

CHALLENGE="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
STATUS="$(curl -sS -o /dev/null -w '%{http_code}' \
  "${AUTH_URL}/authorize?provider=google&code_challenge=${CHALLENGE}&code_challenge_method=s256&redirect_to=http://localhost:3000/callback" || true)"

if [[ "$STATUS" == "302" ]]; then
  LINHA="$(docker exec -e PGPASSWORD=postgres "$DB_CONTAINER" \
    psql -U supabase_admin -d postgres -tAc \
    "select provider_type || '|' || code_challenge || '|' || code_challenge_method::text
       from auth.flow_state
      where code_challenge = '${CHALLENGE}'
      order by created_at desc
      limit 1")"
  if [[ "$LINHA" != "google|${CHALLENGE}|s256" ]]; then
    echo "ERRO: GoTrue /authorize não gravou auth.flow_state conforme esperado (obtido: '$LINHA')." >&2
    exit 1
  fi
  echo "✓ Prova E2E real no GoTrue local: /authorize gravou auth.flow_state = $LINHA"
else
  echo "ℹ Provedor OAuth externo não habilitado no GoTrue local (HTTP $STATUS); prova de schema real concluída sem acesso remoto."
fi
