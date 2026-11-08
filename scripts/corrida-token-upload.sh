#!/usr/bin/env bash
# Prova de concorrência do token de uso único da enviar-midia (contrato 0.2.63).
#
# O pgTAP roda numa sessão só e não enxerga corrida. Dois PUT simultâneos com o mesmo token
# chegam à Edge Function como duas conexões chamando privado.consumir_token_upload ao mesmo
# tempo. O consumo é um UPDATE condicional (`... and upload_usado_em is null ... returning`):
# quem perde espera a trava da linha e, reavaliado o WHERE, não casa mais. Mesmo defeito
# evitado no #427, em que um NOT EXISTS sem trava deixou dois avisos passarem.
#
# O que o script exige:
#   1. Determinístico: A consome e segura a transação por 2 s; B, disparada no meio, espera a
#      trava de A e volta sem caminho. Exatamente um caminho entregue.
#   2. Disputa: 20 rodadas, cada uma com um token novo e duas conexões disparadas juntas.
#      Em todas, exatamente uma conexão recebe o caminho.
#
# Uso: ./scripts/corrida-token-upload.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB=${DB_CONTAINER:-supabase_db_frila-backend}
psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0
U_ID="f0000000-0000-4000-8000-000000000816"
RODADAS=20

foto_antes=$(psql -c "select coalesce(bool_or(foto_de_perfil), false) from privado.configuracao_app;")

limpar() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza falhou na corrida do token de upload" >&2
delete from privado.midia where dono_usuario_id = '$U_ID';
delete from public.usuario where id = '$U_ID';
delete from auth.users where id = '$U_ID';
update privado.configuracao_app set foto_de_perfil = '${foto_antes:-f}'::boolean;
SQL
  rm -rf "$TMP"
}
trap limpar EXIT

# Mídia sintética em `enviando` com o hash do token dado.
nova_midia() {
  local id=$1 token=$2
  psql >/dev/null <<SQL
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado,
                           upload_token_hash, upload_expira_em)
values ('$id', '$U_ID', 'profissional', 'foto_perfil', 'perfil/$id.jpg', 'image/jpeg', 1024, 'enviando',
        encode(sha256(convert_to('$token', 'UTF8')), 'hex'), now() + interval '2 hours');
SQL
}

echo "▸ Montando cenário da corrida do token de upload"
psql >/dev/null <<SQL
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data,
                        raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', '$U_ID', 'authenticated', 'authenticated',
        'corrida_token_upload@frila.test', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
on conflict do nothing;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('$U_ID', 'profissional', 'Corrida Token', '+5561988880816', 'corrida_token_upload@frila.test',
        '1990-01-01', '2026-09-22', now())
on conflict do nothing;
update privado.configuracao_app set foto_de_perfil = true;
SQL

echo "▸ 1. A segura a trava; B chega no meio"
ID="81600000-0000-4000-8000-$(printf '%012d' 900)"
TOKEN=$(openssl rand -hex 32)
nova_midia "$ID" "$TOKEN"
( psql <<SQL > "$TMP/a.out"
begin;
select privado.consumir_token_upload('$ID', '$TOKEN') is not null;
select pg_sleep(2);
commit;
SQL
) &
pid_a=$!
sleep 0.5
inicio=$(date +%s)
psql -c "select privado.consumir_token_upload('$ID', '$TOKEN') is not null;" > "$TMP/b.out"
fim=$(date +%s)
wait "$pid_a"
a=$(grep -E '^[tf]$' "$TMP/a.out" | head -1); b=$(grep -E '^[tf]$' "$TMP/b.out" | head -1)
[ "$a" = t ] && ok "A recebeu o caminho" || falhou "A deveria receber o caminho (veio '$a')"
[ "$b" = f ] && ok "B, depois de A, não recebeu o caminho" || falhou "B recebeu o caminho também (veio '$b')"
[ $((fim - inicio)) -ge 1 ] && ok "B esperou a trava de A ($((fim - inicio)) s): a disputa foi real" \
  || falhou "B não esperou a trava de A: a corrida não aconteceu"

echo "▸ 2. $RODADAS rodadas com duas conexões juntas"
vencedores_errados=0
for i in $(seq 1 "$RODADAS"); do
  ID="81600000-0000-4000-8000-$(printf '%012d' "$i")"
  TOKEN=$(openssl rand -hex 32)
  nova_midia "$ID" "$TOKEN"
  for lado in x y; do
    ( psql <<SQL > "$TMP/$i-$lado.out"
begin;
select privado.consumir_token_upload('$ID', '$TOKEN') is not null;
select pg_sleep(0.2);
commit;
SQL
    ) &
  done
  wait
  n=$(cat "$TMP/$i-x.out" "$TMP/$i-y.out" | grep -c '^t$')
  [ "$n" = 1 ] || vencedores_errados=$((vencedores_errados + 1))
done
[ "$vencedores_errados" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, exatamente uma conexão recebeu o caminho" \
  || falhou "$vencedores_errados de $RODADAS rodadas não tiveram exatamente um vencedor"

usados=$(psql -c "select count(*) from privado.midia where dono_usuario_id = '$U_ID' and upload_usado_em is not null;")
[ "$usados" = $((RODADAS + 1)) ] && ok "cada token foi consumido uma vez ($usados de $((RODADAS + 1)))" \
  || falhou "consumos registrados: $usados, esperado $((RODADAS + 1))"

exit "$falha"
