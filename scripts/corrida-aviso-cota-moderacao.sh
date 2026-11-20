#!/usr/bin/env bash
# Prova de concorrência do aviso de cota mensal da moderação de mídia (cartão yPhXgTCY).
# O pgTAP usa uma sessão e não enxerga corrida. Aqui duas conexões chamam
# privado.reservar_chamada_moderacao ao mesmo tempo, com o consumo do mês no limiar de 80%, e só uma
# pode receber avisar_cota. Sem a trava (pg_advisory_xact_lock) as duas leem o mesmo consumo, e as
# duas avisam. O que se exige em cada rodada:
#   1. as duas conexões terminam com status 0 e devolvem `ok`;
#   2. exatamente uma recebe avisar_cota = t;
#   3. existe uma única marca em privado.moderacao_aviso_cota para o provedor da rodada.
#
# Uso:  ./scripts/corrida-aviso-cota-moderacao.sh
# DB_CONTAINER, DB_NAME e DB_USER trocam o alvo (o padrão é o banco local do Supabase).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB=${DB_CONTAINER:-supabase_db_frila-backend}
DB_NAME=${DB_NAME:-postgres}
DB_USER=${DB_USER:-postgres}
psql() { docker exec -i "$DB" psql -U "$DB_USER" -d "$DB_NAME" -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0
U_ID="f0000000-0000-4000-8000-000000000891"
MES="2099-01"
PREFIXO="corrida-aviso-cota"
RODADAS=20
# Mídias 0 a 200: a 0 recebe o consumo prévio e as outras são as reservas de cada conexão.
MIDIA_BASE="89100000-0000-4000-8000-000000000000"

mid() { printf '89100000-0000-4000-8000-%012d' "$1"; }

limpar() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza falhou na corrida do aviso de cota" >&2
delete from privado.moderacao_aviso_cota where provedor like '$PREFIXO%';
delete from privado.moderacao_chamada where provedor like '$PREFIXO%';
delete from privado.midia where dono_usuario_id = '$U_ID';
delete from public.usuario where id = '$U_ID';
delete from auth.users where id = '$U_ID';
SQL
  rm -rf "$TMP"
}
trap limpar EXIT

echo "▸ Montando o cenário da corrida do aviso de cota"
psql >/dev/null <<SQL || { echo "✗ não montou o cenário" >&2; exit 1; }
delete from privado.moderacao_aviso_cota where provedor like '$PREFIXO%';
delete from privado.moderacao_chamada where provedor like '$PREFIXO%';
delete from privado.midia where dono_usuario_id = '$U_ID';
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data,
                        raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', '$U_ID', 'authenticated', 'authenticated',
        'corrida_aviso_cota@frila.test', now(), '{"provider":"email"}'::jsonb,
        '{}'::jsonb, now(), now(), false, false)
on conflict do nothing;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('$U_ID', 'profissional', 'Corrida Aviso Cota', '+5561988880891',
        'corrida_aviso_cota@frila.test', '1990-01-01', '2026-09-22', now())
on conflict do nothing;
-- 'removida' fica fora do índice de foto única por dono, então uma conta tem quantas mídias for preciso.
insert into privado.midia (id, dono_usuario_id, dono_tipo, tipo, storage_path, mime, bytes, estado)
select ('89100000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid, '$U_ID', 'profissional', 'foto_perfil',
       'corrida-aviso-cota/' || n || '.jpg', 'image/jpeg', 1000, 'removida'
  from generate_series(0, 200) n;
SQL

# gastar <provedor> <quantas>: consumo já feito no mês, todo na mídia-base.
gastar() {
  psql >/dev/null <<SQL
insert into privado.moderacao_chamada (midia_id, provedor, mes)
select '$MIDIA_BASE', '$1', '$MES' from generate_series(1, $2);
SQL
}

# reserva <arquivo-saída> <arquivo-status> <provedor> <midia> <teto> <espera>: uma conexão que reserva,
# segura a transação aberta por <espera> s e termina.
reserva() {
  local saida=$1 status=$2 prov=$3 midia=$4 teto=$5 espera=$6
  (
    psql >"$saida" 2>"$saida.err" <<SQL
begin;
select resultado || '|' || consumo_mes || '|' || avisar_cota
  from privado.reservar_chamada_moderacao('$midia', '$prov', '$MES', $teto, 1);
select pg_sleep($espera);
commit;
SQL
    echo $? >"$status"
  )
}

echo "▸ 1. A segura a trava; B chega no meio"
PROV="$PREFIXO-espera"
gastar "$PROV" 7
inicio=$(date +%s)
reserva "$TMP/a.out" "$TMP/a.status" "$PROV" "$(mid 1)" 10 2 &
pid_a=$!
sleep 0.5
reserva "$TMP/b.out" "$TMP/b.status" "$PROV" "$(mid 2)" 10 0
wait "$pid_a"
fim=$(date +%s)
sa=$(cat "$TMP/a.status" 2>/dev/null || echo ausente)
sb=$(cat "$TMP/b.status" 2>/dev/null || echo ausente)
ra=$(grep -E '^ok\|' "$TMP/a.out" | head -1)
rb=$(grep -E '^ok\|' "$TMP/b.out" | head -1)
[ "$sa" = 0 ] && [ "$sb" = 0 ] && ok "as duas conexões terminaram sem erro (A=$sa, B=$sb)" \
  || falhou "conexão com erro (A=$sa, B=$sb): sem as duas, a disputa não prova nada: $(cat "$TMP/a.out.err" "$TMP/b.out.err" 2>/dev/null)"
[ "$ra" = "ok|8|true" ] && ok "A chegou a 8 de 10 e recebeu o aviso" || falhou "A deveria receber ok|8|true (veio '$ra')"
[ "$rb" = "ok|9|false" ] && ok "B, depois de A, chegou a 9 e não avisou" || falhou "B deveria receber ok|9|false (veio '$rb')"
[ $((fim - inicio)) -ge 1 ] && ok "B esperou a trava de A ($((fim - inicio)) s)" \
  || falhou "B não esperou a trava de A: a corrida não aconteceu"

verificar_rodada() {
  # $1 = índice, $2 = provedor; confere as duas saídas $TMP/$1-x.out e $TMP/$1-y.out
  local i=$1 prov=$2 sx sy rx ry avisos marcas
  sx=$(cat "$TMP/$i-x.status" 2>/dev/null || echo ausente)
  sy=$(cat "$TMP/$i-y.status" 2>/dev/null || echo ausente)
  rx=$(grep -E '^ok\|' "$TMP/$i-x.out" | head -1)
  ry=$(grep -E '^ok\|' "$TMP/$i-y.out" | head -1)
  avisos=$(printf '%s\n%s\n' "$rx" "$ry" | grep -c '|true$' || true)
  marcas=$(psql -c "select count(*) from privado.moderacao_aviso_cota where provedor = '$prov' and mes = '$MES' and limiar_percentual = 80;")
  printf '    rodada %02d  x: %s (status %s)  y: %s (status %s)  marcas: %s\n' \
    "$i" "${rx:--}" "$sx" "${ry:--}" "$sy" "$marcas"
  # Conexão que morre não disputa nada: sem as duas em status 0 e com `ok`, a rodada não conta.
  [ "$sx" = 0 ] && [ "$sy" = 0 ] && [ -n "$rx" ] && [ -n "$ry" ] && [ "$avisos" = 1 ] && [ "$marcas" = 1 ]
}

echo "▸ 2. $RODADAS rodadas, duas conexões juntas, o consumo do mês indo de 7 para 8 e 9 de 10"
ruins=0
for i in $(seq 1 "$RODADAS"); do
  PROV="$PREFIXO-r$i"
  gastar "$PROV" 7
  reserva "$TMP/$i-x.out" "$TMP/$i-x.status" "$PROV" "$(mid $((i * 2 + 10)))" 10 0.2 &
  reserva "$TMP/$i-y.out" "$TMP/$i-y.status" "$PROV" "$(mid $((i * 2 + 11)))" 10 0.2 &
  wait
  verificar_rodada "$i" "$PROV" || ruins=$((ruins + 1))
done
[ "$ruins" = 0 ] && ok "em $RODADAS de $RODADAS rodadas as duas conexões terminaram em 0 e só uma recebeu o aviso" \
  || falhou "$ruins de $RODADAS rodadas sem as duas conexões em status 0 e com exatamente um aviso e uma marca"

echo "▸ 3. $RODADAS rodadas com o teto mudando entre as duas conexões (6 e 5, consumo 3: nas duas ordens as duas chegam a >= 80% do próprio teto)"
ruins=0
for i in $(seq 1 "$RODADAS"); do
  PROV="$PREFIXO-t$i"
  gastar "$PROV" 3
  reserva "$TMP/t$i-x.out" "$TMP/t$i-x.status" "$PROV" "$(mid $((i * 2 + 100)))" 6 0.2 &
  reserva "$TMP/t$i-y.out" "$TMP/t$i-y.status" "$PROV" "$(mid $((i * 2 + 101)))" 5 0.2 &
  wait
  verificar_rodada "t$i" "$PROV" || ruins=$((ruins + 1))
done
[ "$ruins" = 0 ] && ok "em $RODADAS de $RODADAS rodadas com teto diferente por conexão saiu um único aviso" \
  || falhou "$ruins de $RODADAS rodadas com teto diferente sem exatamente um aviso e uma marca"

exit "$falha"
