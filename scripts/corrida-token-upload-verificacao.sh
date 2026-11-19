#!/usr/bin/env bash
# Prova de concorrência do token opaco de upload da verificação de identidade (RN14).
# O pgTAP usa uma sessão; aqui duas conexões disputam o mesmo UPDATE condicional.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB=${DB_CONTAINER:-supabase_db_frila-backend}
psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0
U_ID="f0000000-0000-4000-8000-000000000890"
V_ID="89000000-0000-4000-8000-000000009000"
RODADAS=20

limpar() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza falhou na corrida RN14" >&2
delete from privado.verificacao_identidade where id = '$V_ID';
delete from public.usuario where id = '$U_ID';
delete from auth.users where id = '$U_ID';
SQL
  rm -rf "$TMP"
}
trap limpar EXIT

novo_token() {
  local id=$1 parte=$2 token=$3 caminho=$4
  psql >/dev/null <<SQL
insert into privado.upload_verificacao_identidade
  (id, verificacao_id, parte, storage_path, token_hash, expira_em, usado_em)
values ('$id', '$V_ID', '$parte', '$caminho',
        encode(sha256(convert_to('$token', 'UTF8')), 'hex'), now() + interval '2 hours', null)
on conflict (verificacao_id, parte) do update
set id = excluded.id, storage_path = excluded.storage_path,
    token_hash = excluded.token_hash, expira_em = excluded.expira_em, usado_em = null;
SQL
}

echo "▸ Montando cenário da corrida do token de upload RN14"
psql >/dev/null <<SQL
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data,
                        raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', '$U_ID', 'authenticated', 'authenticated',
        'corrida_token_upload_verificacao@frila.test', now(), '{"provider":"email"}'::jsonb,
        '{}'::jsonb, now(), now(), false, false)
on conflict do nothing;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('$U_ID', 'profissional', 'Corrida Token RN14', '+5561988880890',
        'corrida_token_upload_verificacao@frila.test', '1990-01-01', '2026-09-22', now())
on conflict do nothing;
insert into privado.verificacao_identidade
  (id, usuario_id, nivel, status, documento_tipo, storage_path_frente,
   storage_path_verso, storage_path_selfie, expurgo_midia_em)
values ('$V_ID', '$U_ID', 3, 'pendente', 'rg', 'corrida/$V_ID/frente.jpg',
        'corrida/$V_ID/verso.jpg', 'corrida/$V_ID/selfie.jpg', now() + interval '15 days');
SQL

echo "▸ 1. A segura a trava; B chega no meio"
ID="89000000-0000-4000-8000-$(printf '%012d' 900)"
TOKEN=$(openssl rand -hex 32)
novo_token "$ID" frente "$TOKEN" "corrida/$V_ID/frente.jpg"
( psql <<SQL > "$TMP/a.out"
begin;
select privado.consumir_token_upload_verificacao('$ID', '$TOKEN') is not null;
select pg_sleep(2);
commit;
SQL
) &
pid_a=$!
sleep 0.5
inicio=$(date +%s)
psql -c "select privado.consumir_token_upload_verificacao('$ID', '$TOKEN') is not null;" > "$TMP/b.out"
status_b=$?
fim=$(date +%s)
wait "$pid_a"
status_a=$?
a=$(grep -E '^[tf]$' "$TMP/a.out" | head -1)
b=$(grep -E '^[tf]$' "$TMP/b.out" | head -1)
[ "$status_a" = 0 ] && [ "$status_b" = 0 ] && ok "as duas conexões terminaram sem erro (A=$status_a, B=$status_b)" \
  || falhou "conexão com erro (A=$status_a, B=$status_b): sem as duas, a disputa não prova nada"
[ "$a" = t ] && ok "A recebeu o destino" || falhou "A deveria receber o destino (veio '$a')"
[ "$b" = f ] && ok "B, depois de A, não recebeu destino" || falhou "B recebeu o destino também (veio '$b')"
[ $((fim - inicio)) -ge 1 ] && ok "B esperou a trava de A ($((fim - inicio)) s)" \
  || falhou "B não esperou a trava de A: a corrida não aconteceu"

echo "▸ 2. $RODADAS rodadas com duas conexões juntas"
rodadas_ruins=0
for i in $(seq 1 "$RODADAS"); do
  ID="89000000-0000-4000-8000-$(printf '%012d' "$i")"
  TOKEN=$(openssl rand -hex 32)
  case $((i % 3)) in
    1) PARTE=frente ;;
    2) PARTE=verso ;;
    0) PARTE=selfie ;;
  esac
  novo_token "$ID" "$PARTE" "$TOKEN" "corrida/$V_ID/$PARTE.jpg"
  for lado in x y; do
    ( psql <<SQL > "$TMP/$i-$lado.out"
begin;
select privado.consumir_token_upload_verificacao('$ID', '$TOKEN') is not null;
select pg_sleep(0.2);
commit;
SQL
      echo $? > "$TMP/$i-$lado.status" ) &
  done
  wait
  # Conexão que morre não disputa nada: sem as duas terminando em 0, uma t e uma f, a
  # rodada não conta, mesmo que sobre exatamente um vencedor.
  status_x=$(cat "$TMP/$i-x.status" 2>/dev/null || echo ausente)
  status_y=$(cat "$TMP/$i-y.status" 2>/dev/null || echo ausente)
  res_x=$(grep -E '^[tf]$' "$TMP/$i-x.out" | head -1)
  res_y=$(grep -E '^[tf]$' "$TMP/$i-y.out" | head -1)
  printf '    rodada %02d  x: %s (status %s)  y: %s (status %s)\n' \
    "$i" "${res_x:--}" "$status_x" "${res_y:--}" "$status_y"
  if [ "$status_x" != 0 ] || [ "$status_y" != 0 ] \
     || { [ "$res_x$res_y" != tf ] && [ "$res_x$res_y" != ft ]; }; then
    rodadas_ruins=$((rodadas_ruins + 1))
  fi
done
[ "$rodadas_ruins" = 0 ] && ok "em $RODADAS de $RODADAS rodadas as duas conexões terminaram sem erro, com um t e um f" \
  || falhou "$rodadas_ruins de $RODADAS rodadas sem as duas conexões em status 0 e com exatamente um t e um f"

usados=$(psql -c "select count(*) from privado.upload_verificacao_identidade where verificacao_id = '$V_ID' and usado_em is not null;")
[ "$usados" = 3 ] && ok "cada slot vigente registra um único consumo ($usados de 3)" \
  || falhou "slots vigentes consumidos: $usados, esperado 3"

exit "$falha"
