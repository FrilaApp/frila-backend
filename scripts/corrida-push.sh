#!/usr/bin/env bash
# Prova determinística de concorrência com SKIP LOCKED em privado.reivindicar_lote_push (Item 15).
#
# O pgTAP roda numa única sessão SQL e não consegue provar concorrência real entre transações
# abertas simultaneamente disputando as mesmas linhas antes do commit.
#
# Este script abre DUAS conexões simultâneas de banco:
#   - Conexão A abre transação, reivindica 2 notificações com SKIP LOCKED e segura o commit com pg_sleep(2).
#   - Conexão B dispara enquanto A ainda está ativa e reivindica 2 notificações.
#
# O que o script exige ao final:
#   1. Conexão B completa imediatamente sem esperar o lock de A (prova de SKIP LOCKED, não lock normal).
#   2. O lote de A e o lote de B são mutuamente exclusivos (zero sobreposição de notificações).
#   3. O total de notificações distintas processadas é exatamente 4 (2 de A + 2 de B).
#
# Uso: ./scripts/corrida-push.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB=${DB_CONTAINER:-supabase_db_frila-backend}

psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0

MARCA="74700000-0000-4000-8000"
U_ID="f0000000-0000-4000-8000-000000000747"

limpar() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza falhou na corrida de push" >&2
delete from public.notificacao where usuario_id = '$U_ID';
delete from public.usuario where id = '$U_ID';
delete from auth.users where id = '$U_ID';
SQL
  rm -rf "$TMP"
}
trap limpar EXIT

echo "▸ Montando cenário de corrida para reivindicação de push (SKIP LOCKED)"

psql >/dev/null <<SQL
insert into auth.users (
  instance_id, id, aud, role, email, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  is_sso_user, is_anonymous
) values (
  '00000000-0000-0000-0000-000000000000',
  '$U_ID', 'authenticated', 'authenticated', 'corrida_push@frila.test', now(),
  '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
) on conflict do nothing;

insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em
) values (
  '$U_ID', 'profissional', 'Corrida Push', '+5561988880747',
  'corrida_push@frila.test', '1990-01-01', '2026-09-22', now()
) on conflict do nothing;

delete from public.notificacao where usuario_id = '$U_ID';

insert into public.notificacao (
  id, usuario_id, tipo, referencia_id, payload,
  tentativas, estado_entrega, proxima_tentativa_em, enviada_em
) values
  ('${MARCA}-000000000001', '$U_ID', 'suspensao', gen_random_uuid(), '{}'::jsonb, 0, 'pendente', null, now() - interval '40 seconds'),
  ('${MARCA}-000000000002', '$U_ID', 'suspensao', gen_random_uuid(), '{}'::jsonb, 0, 'pendente', null, now() - interval '30 seconds'),
  ('${MARCA}-000000000003', '$U_ID', 'suspensao', gen_random_uuid(), '{}'::jsonb, 0, 'pendente', null, now() - interval '20 seconds'),
  ('${MARCA}-000000000004', '$U_ID', 'suspensao', gen_random_uuid(), '{}'::jsonb, 0, 'pendente', null, now() - interval '10 seconds');
SQL

echo "▸ Disparando sessões A e B concorrentes"

# Sessão A reivindica 2 e segura o commit por 2 segundos
psql -tA <<SQL >"$TMP/a.out" 2>"$TMP/a.err" &
set application_name = 'corrida_push_a';
begin;
select id from privado.reivindicar_lote_push(2);
select pg_sleep(2);
commit;
SQL
pa=$!

# Aguarda 0.3s para garantir que A abriu a transação e obteve as linhas
sleep 0.3

# Sessão B dispara enquanto A ainda está dormindo com a transação aberta
t_inicio=$(date +%s)
psql -tA <<SQL >"$TMP/b.out" 2>"$TMP/b.err" &
set application_name = 'corrida_push_b';
begin;
select id from privado.reivindicar_lote_push(2);
commit;
SQL
pb=$!

wait $pb; sb=$?
t_fim=$(date +%s)
duracao_b=$((t_fim - t_inicio))

wait $pa; sa=$?

[ $sa -eq 0 ] || falhou "Sessão A falhou: $(cat "$TMP/a.err")"
[ $sb -eq 0 ] || falhou "Sessão B falhou: $(cat "$TMP/b.err")"

# Filtra linhas retornadas por A (ignorando pg_sleep)
itens_a=$(grep -E '^[0-9a-f-]{36}$' "$TMP/a.out" | sort)
itens_b=$(grep -E '^[0-9a-f-]{36}$' "$TMP/b.out" | sort)

qtd_a=$(echo "$itens_a" | grep -c . || true)
qtd_b=$(echo "$itens_b" | grep -c . || true)

echo "  Notificações reivindicadas por A ($qtd_a):"
echo "$itens_a" | sed 's/^/    /'
echo "  Notificações reivindicadas por B ($qtd_b):"
echo "$itens_b" | sed 's/^/    /'

# Validação 1: SKIP LOCKED não bloqueou a sessão B
if [ "$duracao_b" -ge 2 ]; then
  falhou "Sessão B ficou bloqueada esperando lock de A (${duracao_b}s). SKIP LOCKED não funcionou!"
else
  ok "Sessão B executou imediatamente sem bloqueio (${duracao_b}s) via SKIP LOCKED"
fi

# Validação 2: Quantidades exatas
[ "$qtd_a" -eq 2 ] || falhou "Sessão A deveria ter recebido 2 notificações, recebeu $qtd_a"
[ "$qtd_b" -eq 2 ] || falhou "Sessão B deveria ter recebido 2 notificações, recebeu $qtd_b"

# Validação 3: Zero sobreposição
intersecao=$(comm -12 <(echo "$itens_a") <(echo "$itens_b") | grep -c . || true)
if [ "$intersecao" -gt 0 ]; then
  falhou "Notificações duplicadas encontradas entre A e B ($intersecao colisões)!"
else
  ok "Zero sobreposição entre os lotes reivindicados (corrida neutralizada)"
fi

if [ $falha -eq 0 ]; then
  ok "Prova de concorrência com SKIP LOCKED aprovada com sucesso!"
  exit 0
else
  exit 1
fi
