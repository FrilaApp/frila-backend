#!/usr/bin/env bash
# Corridas da chamada direta (T1). O pgTAP roda numa sessão só e não enxerga disputa entre
# transações abertas ao mesmo tempo. Aqui cada lado é uma conexão de verdade, que chama a
# RPC como `authenticated` e segura a transação um pouco depois da chamada, para a outra
# conexão chegar enquanto a primeira ainda tem as travas. Quem chega primeiro alterna entre
# as rodadas, para os dois ordenamentos acontecerem.
#
# Cenários (cada rodada num "mundo" próprio: casa, profissionais e vaga só dela):
#   1. Duas chamadas abertas da mesma vaga, para profissionais diferentes, aceitas ao mesmo
#      tempo: só um confirma a posição (RN32 + a trava da RN19); o outro é recusado.
#   2. Aceite do profissional x cancelamento da casa na mesma chamada: um desfecho só, e o
#      estado final combina com quem venceu.
#   3. Duas chamar_profissional simultâneas no mesmo par: uma chamada aberta só (RN34).
#   4. Exclusão da conta do profissional x aceite da chamada: a vaga direta nunca vai à fila
#      do despacho nem é despachada a terceiro, mesmo com um terceiro elegível (conserto do
#      #434). O motor é chamado no fim para provar que nada sai.
#
# Uso: ./scripts/corrida-chamada.sh        RODADAS=4 ./scripts/corrida-chamada.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB=${DB_CONTAINER:-supabase_db_frila-backend}
RODADAS=${RODADAS:-4}
psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0
RUN=$(( (RANDOM % 900) + 100 ))   # marca desta execução: reexecutar não colide com a anterior

# id <mundo> <entidade>: UUID sintético desta execução.
id() { printf '%08x-0000-4000-8000-%012d' $(( 0xc0c00000 + RUN * 1000 + $1 )) "$2"; }

recurso_antes=$(psql -c "select coalesce((select ligado from privado.recurso where chave = 'chamada_direta'), false);")
limpar() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: não restaurei o recurso chamada_direta" >&2
update privado.recurso set ligado = '${recurso_antes:-f}'::boolean where chave = 'chamada_direta';
SQL
  rm -rf "$TMP"
}
trap limpar EXIT

# Função auxiliar de cada conexão: chama como a conta dada e devolve 'ok' ou o code do erro.
AUX=$(cat <<'SQL'
create function pg_temp.tentar(conta uuid, q text) returns text language plpgsql as $f$
declare m text;
begin
  if conta is not null then
    perform set_config('request.jwt.claims', json_build_object('sub', conta, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
  end if;
  execute q;
  execute 'reset role';
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text;
  return case when m ~ '^\s*\{' then coalesce(m::jsonb->>'code', 'sem_code') else 'sqlstate:' || sqlstate end;
end $f$;
SQL
)

# lado <arquivo> <atraso_inicial> <segurar> <conta|''> <sql>: uma conexão em segundo plano.
lado() {
  local saida=$1 atraso=$2 segurar=$3 conta=$4 sql=$5
  (
    sleep "$atraso"
    psql <<SQL > "$saida" 2>&1
$AUX
begin;
select pg_temp.tentar(${conta:+'$conta'}${conta:-null}, \$q\$ $sql \$q\$);
select pg_sleep($segurar);
commit;
SQL
  ) &
}

resultado() { grep -E '^(ok|[a-z_]+|sqlstate:.*)$' "$1" | head -1; }

# Monta um mundo: casa (CNPJ sintético) e dois profissionais na equipe de confiança, com a
# função garçom, ponto a 1,3 km e disponibilidade a semana toda (o 2º é elegível ao despacho).
montar_mundo() {
  local m=$1 casa prof1 prof2 estab
  casa=$(id "$m" 1); prof1=$(id "$m" 2); prof2=$(id "$m" 3); estab=$(id "$m" 10)
  psql >/dev/null <<SQL
$AUX
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u, 'authenticated', 'authenticated',
       'corrida-chamada-$RUN-$m-' || n || '@frila.test', now(), now(), false, false
  from (values ('$casa'::uuid, 1), ('$prof1'::uuid, 2), ('$prof2'::uuid, 3)) v(u, n);
select pg_temp.tentar('$casa',  \$q\$ select public.criar_conta('contratante', 'Casa Corrida', '+5561$(printf '%03d%02d1%03d' "$RUN" "$m" 0)', '1980-01-01', '2026-09-22') \$q\$);
select pg_temp.tentar('$prof1', \$q\$ select public.criar_conta('profissional', 'Pê Um', '+5561$(printf '%03d%02d2%03d' "$RUN" "$m" 0)', '1990-01-01', '2026-09-22') \$q\$);
select pg_temp.tentar('$prof2', \$q\$ select public.criar_conta('profissional', 'Pê Dois', '+5561$(printf '%03d%02d3%03d' "$RUN" "$m" 0)', '1991-01-01', '2026-09-22') \$q\$);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('$estab', 'Casa Corrida $m', '7$(printf '%03d%010d' "$RUN" "$m")', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values ('$casa', '$estab', 'administrador');
insert into public.profissional (usuario_id, ponto_base) values
  ('$prof1', 'POINT(-47.8822 -15.7800)'::extensions.geography),
  ('$prof2', 'POINT(-47.8822 -15.7800)'::extensions.geography);
insert into public.profissional_funcao
select p.id, (select id from public.funcao where nome = 'garçom') from public.profissional p where p.usuario_id in ('$prof1', '$prof2');
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select '$estab', p.id from public.profissional p where p.usuario_id in ('$prof1', '$prof2');
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select p.id, d, '00:00', '23:59' from public.profissional p, generate_series(0, 6) d where p.usuario_id = '$prof2';
SQL
}

# SQL de chamar_profissional para o mundo m, ao profissional (usuario) dado, numa vaga nova ou existente.
sql_chamar() {
  local m=$1 prof_usuario=$2 vaga=${3:-}
  local dia=$(( 2 + m ))
  cat <<SQL
select public.chamar_profissional(chave => gen_random_uuid(),
  profissional_id => (select p.id from public.profissional p where p.usuario_id = '$prof_usuario'),
  estabelecimento_id => '$(id "$m" 10)', funcao_id => (select id from public.funcao where nome = 'garçom'),
  inicio_em => date_trunc('hour', now()) + interval '$dia days', fim_em => date_trunc('hour', now()) + interval '$dia days 5 hours',
  local => 'CLN 201', regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
  valor_centavos => 15000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false,
  responsavel_local => 'Maitre'${vaga:+, vaga_id => '$vaga'})
SQL
}

# Chama de forma serial (montagem) e devolve "chamada_id vaga_id".
chamar_serial() {
  local m=$1 prof_usuario=$2 vaga=${3:-}
  psql <<SQL | grep -E '^[0-9a-f-]{36} [0-9a-f-]{36}$'
begin;
select set_config('request.jwt.claims', json_build_object('sub', '$(id "$m" 1)', 'role', 'authenticated')::text, true) is null;
set local role authenticated;
create temp table r on commit drop as $(sql_chamar "$m" "$prof_usuario" "$vaga") as j;
reset role;
select (j->>'id') || ' ' || (j->>'vaga_id') from r;
commit;
SQL
}

echo "▸ Corridas da chamada direta: $RODADAS rodadas por cenário (marca $RUN)"
psql >/dev/null -c "update privado.recurso set ligado = true where chave = 'chamada_direta';"

# ── 1. Aceites simultâneos de duas chamadas da mesma vaga ──────────────────────
echo "▸ 1. duas chamadas da mesma vaga aceitas ao mesmo tempo"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$i; montar_mundo "$m"
  read -r c1 vaga < <(chamar_serial "$m" "$(id "$m" 2)")
  read -r c2 _ < <(chamar_serial "$m" "$(id "$m" 3)" "$vaga")
  if [ -z "${c1:-}" ] || [ -z "${c2:-}" ]; then falhou "rodada $i: não montei as duas chamadas"; erros=$((erros + 1)); continue; fi
  a=0; b=0.2; [ $((i % 2)) = 0 ] && { a=0.2; b=0; }
  lado "$TMP/1-$i-a" "$a" 1 "$(id "$m" 2)" "select public.responder_chamada('$c1', 'aceitar')"
  lado "$TMP/1-$i-b" "$b" 1 "$(id "$m" 3)" "select public.responder_chamada('$c2', 'aceitar')"
  wait
  ra=$(resultado "$TMP/1-$i-a"); rb=$(resultado "$TMP/1-$i-b")
  conf=$(psql -c "select count(*) from public.posicao where vaga_id = '$vaga' and estado = 'confirmada';")
  oks=$(printf '%s\n%s\n' "$ra" "$rb" | grep -c '^ok$')
  if [ "$oks" != 1 ] || [ "$conf" != 1 ]; then
    falhou "rodada $i: respostas '$ra'/'$rb', posições confirmadas $conf"; erros=$((erros + 1))
  fi
done
[ "$erros" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, um aceite só e uma posição confirmada"

# ── 2. Aceite x cancelamento da casa ───────────────────────────────────────────
echo "▸ 2. aceite do profissional x cancelamento da casa"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$((10 + i)); montar_mundo "$m"
  read -r c1 vaga < <(chamar_serial "$m" "$(id "$m" 2)")
  [ -z "${c1:-}" ] && { falhou "rodada $i: não montei a chamada"; erros=$((erros + 1)); continue; }
  a=0; b=0.2; [ $((i % 2)) = 0 ] && { a=0.2; b=0; }
  lado "$TMP/2-$i-a" "$a" 1 "$(id "$m" 2)" "select public.responder_chamada('$c1', 'aceitar')"
  lado "$TMP/2-$i-b" "$b" 1 "$(id "$m" 1)" "select public.cancelar_chamada('$c1')"
  wait
  ra=$(resultado "$TMP/2-$i-a"); rb=$(resultado "$TMP/2-$i-b")
  estado=$(psql -c "select estado from public.chamada where id = '$c1';")
  conf=$(psql -c "select count(*) from public.posicao where vaga_id = '$vaga' and estado = 'confirmada';")
  if [ "$ra" = ok ] && [ "$rb" != ok ] && [ "$estado" = aceita ] && [ "$conf" = 1 ]; then :
  elif [ "$rb" = ok ] && [ "$ra" != ok ] && [ "$estado" = cancelada ] && [ "$conf" = 0 ]; then :
  else
    falhou "rodada $i: aceite '$ra', cancelamento '$rb', chamada '$estado', confirmadas $conf"; erros=$((erros + 1))
  fi
done
[ "$erros" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, um desfecho só, coerente com quem venceu"

# ── 3. Duas chamar_profissional simultâneas no mesmo par ────────────────────────
echo "▸ 3. duas chamadas ao mesmo profissional ao mesmo tempo"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$((20 + i)); montar_mundo "$m"
  lado "$TMP/3-$i-a" 0 1 "$(id "$m" 1)" "$(sql_chamar "$m" "$(id "$m" 2)")"
  lado "$TMP/3-$i-b" 0 1 "$(id "$m" 1)" "$(sql_chamar "$m" "$(id "$m" 2)")"
  wait
  ra=$(resultado "$TMP/3-$i-a"); rb=$(resultado "$TMP/3-$i-b")
  abertas=$(psql -c "select count(*) from public.chamada c join public.profissional p on p.id = c.profissional_id
                      where p.usuario_id = '$(id "$m" 2)' and c.estado = 'aberta';")
  oks=$(printf '%s\n%s\n' "$ra" "$rb" | grep -c '^ok$')
  if [ "$oks" != 1 ] || [ "$abertas" != 1 ]; then
    falhou "rodada $i: respostas '$ra'/'$rb', chamadas abertas no par $abertas"; erros=$((erros + 1))
  fi
done
[ "$erros" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, uma chamada aberta só no par"

# ── 4. Exclusão de conta x aceite ──────────────────────────────────────────────
echo "▸ 4. exclusão da conta do profissional x aceite da chamada"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$((30 + i)); montar_mundo "$m"
  read -r c1 vaga < <(chamar_serial "$m" "$(id "$m" 2)")
  [ -z "${c1:-}" ] && { falhou "rodada $i: não montei a chamada"; erros=$((erros + 1)); continue; }
  a=0; b=0.2; [ $((i % 2)) = 0 ] && { a=0.2; b=0; }
  lado "$TMP/4-$i-a" "$a" 1 "$(id "$m" 2)" "select public.responder_chamada('$c1', 'aceitar')"
  lado "$TMP/4-$i-b" "$b" 1 "" "select privado.excluir_conta('$(id "$m" 2)')"
  wait
  ra=$(resultado "$TMP/4-$i-a"); rb=$(resultado "$TMP/4-$i-b")
  psql >/dev/null -c "select privado.despachar_vaga('$vaga', 'reabertura');"
  fila=$(psql -c "select count(*) from pgmq.q_despacho where message->>'vaga_id' = '$vaga';")
  desp=$(psql -c "select count(*) from public.despacho where vaga_id = '$vaga';")
  conta=$(psql -c "select estado from public.usuario where id = '$(id "$m" 2)';")
  if [ "$rb" != ok ] || [ "$conta" != anonimizada ] || [ "$fila" != 0 ] || [ "$desp" != 0 ]; then
    falhou "rodada $i: aceite '$ra', exclusão '$rb', conta '$conta', fila $fila, despachos $desp"; erros=$((erros + 1))
  fi
done
[ "$erros" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, conta excluída e nada foi à fila nem a terceiro"

exit "$falha"
