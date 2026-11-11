#!/usr/bin/env bash
# Corridas do check-in por código (contrato 0.2.68 e 0.2.69; PR7 do B-CHECKIN-BACK). O pgTAP roda
# numa sessão só e não enxerga disputa entre transações abertas ao mesmo tempo. Aqui cada lado é uma
# conexão de verdade, que chama a RPC como `authenticated` e segura a transação depois da chamada,
# para a outra chegar enquanto a primeira ainda tem a trava do turno.
#
# Cenários (cada um num "mundo" próprio: casa, profissional, vaga e turno só dele; check-in manual e
# pendente, chave checkin_por_codigo ligada para a casa):
#   1. Duas validações do mesmo código: uma 200, a outra 409 checkin_ja_confirmado, sem contar errada.
#   2. Validação (A segura) x confirmação manual (B): B recebe 409 checkin_ja_confirmado e a hora da
#      validação não muda. Sem a trava no confirmar_checkin_manual, B sobrescrevia essa hora com 200.
#   3. Confirmação manual (A segura) x validação (B): B recebe 409 e nenhuma tentativa é gravada.
#   4. Dois gerar_codigo_checkin no mesmo turno: os dois devolvem o mesmo código.
#   5. Validação (A segura) x gerar (B): B recebe 409 checkin_ja_confirmado e nenhum código novo fica
#      gravado. Sem a trava do turno no gerar, B lia o turno ainda pendente e sorteava um código.
#   6. e 7. Disputa: RODADAS rodadas de validar x validar e de validar x confirmar disparados juntos;
#      em todas, um só vence, e o estado final combina com quem venceu.
#
# O relógio é o real: privado.ambiente.eh_teste não é gravado fora de teste, e o turno de cada mundo
# começa 30 minutos antes de agora.
#
# Uso: ./scripts/corrida-checkin-codigo.sh        RODADAS=4 ./scripts/corrida-checkin-codigo.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB=${DB_CONTAINER:-supabase_db_frila-backend}
RODADAS=${RODADAS:-10}
psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0
RUN=$(( (RANDOM % 900) + 100 ))   # marca desta execução: reexecutar não colide com a anterior

# id <mundo> <entidade>: UUID sintético desta execução.
id() { printf '%08x-0000-4000-8000-%012d' $(( 0xc0d00000 + RUN * 1000 + $1 )) "$2"; }

recurso_antes=$(psql -c "select coalesce((select ligado from privado.recurso where chave = 'checkin_por_codigo'), false);")
MUNDOS=()

# Apaga tudo o que os mundos desta execução criaram. A suíte e a mutação rodam depois no mesmo banco.
limpar_mundos() {
  [ "${#MUNDOS[@]}" -gt 0 ] || return 0
  local m contas="" casas=""
  for m in "${MUNDOS[@]}"; do
    contas+="('$(id "$m" 1)'::uuid),('$(id "$m" 2)'::uuid),"
    casas+="('$(id "$m" 10)'::uuid),"
  done
  psql >/dev/null <<SQL
set session_replication_role = 'replica';
create temp table contas as select * from (values ${contas%,}) v(id);
create temp table casas as select * from (values ${casas%,}) v(id);
create temp table vagas as select id from public.vaga where estabelecimento_id in (select id from casas);
create temp table posicoes as select id from public.posicao where vaga_id in (select id from vagas);
create temp table turnos as select id from public.turno where posicao_id in (select id from posicoes);
delete from privado.checkin_codigo_tentativa where turno_id in (select id from turnos);
delete from privado.checkin_codigo where turno_id in (select id from turnos);
delete from public.notificacao where usuario_id in (select id from contas) or referencia_id in (select id from turnos);
do \$\$
begin
  if to_regclass('privado.marca_notificacao') is not null then
    delete from privado.marca_notificacao where usuario_id in (select id from contas) or referencia_id in (select id from turnos);
  end if;
end \$\$;
delete from public.turno where id in (select id from turnos);
delete from public.posicao where id in (select id from posicoes);
delete from public.vaga where id in (select id from vagas);
delete from privado.recurso_estabelecimento where estabelecimento_id in (select id from casas);
delete from public.membro_estabelecimento where estabelecimento_id in (select id from casas);
delete from public.estabelecimento where id in (select id from casas);
delete from public.profissional where usuario_id in (select id from contas);
delete from public.usuario where id in (select id from contas);
set session_replication_role = 'origin';
SQL
}

limpar() {
  limpar_mundos || echo "  aviso: a limpeza dos mundos falhou; sobraram dados da marca $RUN" >&2
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: não restaurei o recurso checkin_por_codigo" >&2
update privado.recurso set ligado = '${recurso_antes:-f}'::boolean where chave = 'checkin_por_codigo';
SQL
  rm -rf "$TMP"
}
trap limpar EXIT

# Auxiliar de cada conexão: chama como a conta dada e devolve "status:code". O status vem do
# response.status quando a função o pôs (a recusa que grava, D2), do DETAIL do raise de public.erro,
# ou 200. No 200, o code é o tipo do registro (codigo, manual) ou os 6 dígitos do gerar.
AUX=$(cat <<'SQL'
create function pg_temp.tentar(conta uuid, q text) returns text language plpgsql as $f$
declare r jsonb; m text; d text;
begin
  perform set_config('response.status', '', true);
  perform set_config('request.jwt.claims', json_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute q into r;
  execute 'reset role';
  return coalesce(nullif(current_setting('response.status', true), ''), '200') || ':'
         || coalesce(r->>'code', r->>'codigo', r->>'tipo', 'sem_code');
exception when others then
  get stacked diagnostics m = message_text, d = pg_exception_detail;
  return case when m ~ '^\s*\{' then coalesce(d::jsonb->>'status', '?') || ':' || coalesce(m::jsonb->>'code', 'sem_code')
              else 'sqlstate:' || sqlstate end;
end $f$;
SQL
)

# lado <arquivo> <atraso_inicial> <segurar> <conta> <sql>: uma conexão em segundo plano.
lado() {
  local saida=$1 atraso=$2 segurar=$3 conta=$4 sql=$5
  (
    sleep "$atraso"
    psql <<SQL > "$saida" 2>&1
$AUX
begin;
select pg_temp.tentar('$conta', \$q\$ $sql \$q\$);
select pg_sleep($segurar);
commit;
SQL
  ) &
}

resultado() { grep -E '^([0-9]{3}|\?):|^sqlstate:' "$1" | head -1; }

# O código é lido pelo postgres antes da corrida e vai como literal: o authenticated não lê privado.
codigo_de() { psql -c "select coalesce(codigo, '') from privado.checkin_codigo where turno_id = '$(id "$1" 40)';"; }

# As chamadas de cada mundo (o turno, a casa e o profissional saem do número do mundo).
sql_validar()   { echo "select public.validar_codigo_checkin('$(id "$1" 40)'::uuid, '$(codigo_de "$1")', 40)"; }
sql_confirmar() { echo "select public.confirmar_checkin_manual('$(id "$1" 40)'::uuid)"; }
sql_gerar()     { echo "select public.gerar_codigo_checkin('$(id "$1" 40)'::uuid)"; }

# montar_mundo <m> [sem_codigo]: casa, profissional, vaga de agora, posição confirmada, check-in
# manual a 500 m e, sem o segundo argumento, o código gerado pela casa.
montar_mundo() {
  local m=$1 casa prof estab vaga pos turno
  MUNDOS+=("$m")
  casa=$(id "$m" 1); prof=$(id "$m" 2); estab=$(id "$m" 10); vaga=$(id "$m" 20); pos=$(id "$m" 30); turno=$(id "$m" 40)
  psql >/dev/null <<SQL
$AUX
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('$casa', 'contratante', 'Casa Corrida Código', '+5561999998331',
   'corrida-codigo-$RUN-$m-1@frila.test', '1980-01-01', '1.0', now()),
  ('$prof', 'profissional', 'Pê Corrida Código', '+5561999998332',
   'corrida-codigo-$RUN-$m-2@frila.test', '1990-01-01', '1.0', now());
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('$estab', 'Casa Corrida Código $m', '8$(printf '%03d%010d' "$RUN" "$m")', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography);
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values ('$casa', '$estab', 'administrador');
insert into public.profissional (usuario_id, ponto_base) values ('$prof', 'POINT(-47.8822 -15.7800)'::extensions.geography);
insert into privado.recurso_estabelecimento (chave, estabelecimento_id) values ('checkin_por_codigo', '$estab');
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes, inclui_refeicao,
  inclui_transporte, exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
values ('$vaga', '$estab', (select id from public.funcao limit 1),
        date_trunc('minute', now()) - interval '30 minutes', date_trunc('minute', now()) + interval '4 hours 30 minutes',
        'CLN 201', 'POINT(-47.8822 -15.7942)', 15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada',
        now() - interval '33 hours', gen_random_uuid(), '$casa');
insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select '$pos', '$vaga', 'confirmada', p.id, now() - interval '32 hours', v.inicio_em, v.fim_em
  from public.profissional p, public.vaga v where p.usuario_id = '$prof' and v.id = '$vaga';
insert into public.turno (id, posicao_id, valor_acordado_centavos) values ('$turno', '$pos', 15000);
select pg_temp.tentar('$prof', \$q\$ select public.fazer_checkin('$turno'::uuid, 500, now()) \$q\$);
SQL
  if [ "${2:-}" != sem_codigo ]; then
    psql >/dev/null <<SQL
$AUX
select pg_temp.tentar('$casa', \$q\$ $(sql_gerar "$m") \$q\$);
SQL
  fi
}

# estado <m>: tipo, verificação, erros, tentativas aceitas e se a hora confirmada é a da aceita.
estado() {
  psql -c "select t.checkin_tipo || '|' || t.verificacao || '|' || coalesce(c.erros, 0) || '|'
                  || (select count(*) from privado.checkin_codigo_tentativa k where k.turno_id = t.id and k.resultado = 'aceita') || '|'
                  || coalesce((select (k.em = t.checkin_confirmado_em)::text from privado.checkin_codigo_tentativa k
                                where k.turno_id = t.id and k.resultado = 'aceita'), 'sem_aceita') || '|'
                  || (coalesce(c.codigo, '') <> '')::text
             from public.turno t left join privado.checkin_codigo c on c.turno_id = t.id where t.id = '$(id "$1" 40)';"
}

echo "▸ Corridas do check-in por código (marca $RUN)"
psql >/dev/null -c "update privado.recurso set ligado = true where chave = 'checkin_por_codigo';"

# Um cenário determinístico: A chama e segura 2 s; B chega 0,5 s depois e precisa esperar a trava.
duelo() {
  local m=$1 conta_a=$2 sql_a=$3 conta_b=$4 sql_b=$5
  lado "$TMP/$m-a.out" 0 2 "$conta_a" "$sql_a"
  local pid_a=$!
  sleep 0.5
  local inicio fim
  inicio=$(date +%s)
  lado "$TMP/$m-b.out" 0 0 "$conta_b" "$sql_b"
  wait $!
  fim=$(date +%s)
  wait "$pid_a"
  A=$(resultado "$TMP/$m-a.out"); B=$(resultado "$TMP/$m-b.out"); ESPEROU=$((fim - inicio))
}

echo "▸ 1. Duas validações do mesmo código"
montar_mundo 1
duelo 1 "$(id 1 2)" "$(sql_validar 1)" "$(id 1 2)" "$(sql_validar 1)"
[ "$A" = 200:codigo ] && ok "A validou (200)" || falhou "A deveria validar com 200 (veio '$A')"
[ "$B" = 409:checkin_ja_confirmado ] && ok "B recebeu 409 checkin_ja_confirmado" || falhou "B deveria receber 409 checkin_ja_confirmado (veio '$B')"
[ "$ESPEROU" -ge 1 ] && ok "B esperou a trava de A ($ESPEROU s)" || falhou "B não esperou a trava de A: a corrida não aconteceu"
e=$(estado 1)
[ "$e" = "codigo|verificado|0|1|true|false" ] && ok "uma tentativa aceita, nenhuma errada contada, o valor apagado" \
  || falhou "estado inesperado depois das duas validações: $e"

echo "▸ 2. Validação (A segura) x confirmação manual (B)"
montar_mundo 2
duelo 2 "$(id 2 2)" "$(sql_validar 2)" "$(id 2 1)" "$(sql_confirmar 2)"
[ "$A" = 200:codigo ] && ok "A validou (200)" || falhou "A deveria validar com 200 (veio '$A')"
[ "$B" = 409:checkin_ja_confirmado ] && ok "a confirmação que chega depois recebe 409 checkin_ja_confirmado" \
  || falhou "a confirmação deveria receber 409 checkin_ja_confirmado (veio '$B')"
[ "$ESPEROU" -ge 1 ] && ok "B esperou a trava de A ($ESPEROU s)" || falhou "B não esperou a trava de A: a corrida não aconteceu"
e=$(estado 2)
[ "$e" = "codigo|verificado|0|1|true|false" ] && ok "a hora confirmada segue a da validação" \
  || falhou "a confirmação mexeu no turno validado: $e"

echo "▸ 3. Confirmação manual (A segura) x validação (B)"
montar_mundo 3
duelo 3 "$(id 3 1)" "$(sql_confirmar 3)" "$(id 3 2)" "$(sql_validar 3)"
[ "$A" = 200:manual ] && ok "A confirmou à mão (200)" || falhou "A deveria confirmar com 200 (veio '$A')"
[ "$B" = 409:checkin_ja_confirmado ] && ok "a validação que chega depois recebe 409 checkin_ja_confirmado" \
  || falhou "a validação deveria receber 409 checkin_ja_confirmado (veio '$B')"
e=$(estado 3)
[ "$e" = "manual|verificado|0|0|sem_aceita|true" ] && ok "nenhuma tentativa gravada, nenhuma errada contada" \
  || falhou "estado inesperado depois da confirmação: $e"

echo "▸ 4. Dois gerar no mesmo turno"
montar_mundo 4 sem_codigo
duelo 4 "$(id 4 1)" "$(sql_gerar 4)" "$(id 4 1)" "$(sql_gerar 4)"
[[ "$A" =~ ^200:[0-9]{6}$ ]] && [ "$A" = "$B" ] && ok "os dois devolveram o mesmo código" \
  || falhou "os dois gerar deveriam devolver o mesmo código (A '${A%%:*}', B '${B%%:*}', iguais: $([ "$A" = "$B" ] && echo sim || echo não))"
[ "$ESPEROU" -ge 1 ] && ok "B esperou a trava de A ($ESPEROU s)" || falhou "B não esperou a trava de A: a corrida não aconteceu"
[ "200:$(codigo_de 4)" = "$A" ] && ok "o gravado é o código devolvido" || falhou "o código gravado não é o devolvido"

echo "▸ 5. Validação (A segura) x gerar (B)"
montar_mundo 5
duelo 5 "$(id 5 2)" "$(sql_validar 5)" "$(id 5 1)" "$(sql_gerar 5)"
[ "$A" = 200:codigo ] && ok "A validou (200)" || falhou "A deveria validar com 200 (veio '$A')"
[ "$B" = 409:checkin_ja_confirmado ] && ok "o gerar que chega depois recebe 409 checkin_ja_confirmado" \
  || falhou "o gerar deveria receber 409 checkin_ja_confirmado (veio '${B%%:*}')"
[ -z "$(codigo_de 5)" ] && ok "nenhum código novo ficou gravado no turno verificado" \
  || falhou "o gerar gravou um código novo num turno já verificado"

echo "▸ 6. $RODADAS rodadas de validar x validar, disparados juntos"
erradas=0
for i in $(seq 1 "$RODADAS"); do
  m=$((100 + i)); montar_mundo "$m"
  lado "$TMP/$m-x.out" 0 0.2 "$(id "$m" 2)" "$(sql_validar "$m")"
  lado "$TMP/$m-y.out" 0 0.2 "$(id "$m" 2)" "$(sql_validar "$m")"
  wait
  par=$(printf '%s\n%s\n' "$(resultado "$TMP/$m-x.out")" "$(resultado "$TMP/$m-y.out")" | sort | paste -sd ' ' -)
  e=$(estado "$m")
  { [ "$par" = "200:codigo 409:checkin_ja_confirmado" ] && [ "$e" = "codigo|verificado|0|1|true|false" ]; } \
    || { erradas=$((erradas + 1)); echo "    rodada $i: $par · $e" >&2; }
done
[ "$erradas" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, uma validação venceu e a outra recebeu 409, sem errada contada" \
  || falhou "$erradas de $RODADAS rodadas fugiram de um vencedor só"

echo "▸ 7. $RODADAS rodadas de validar x confirmar, disparados juntos"
erradas=0
for i in $(seq 1 "$RODADAS"); do
  m=$((200 + i)); montar_mundo "$m"
  lado "$TMP/$m-v.out" 0 0.2 "$(id "$m" 2)" "$(sql_validar "$m")"
  lado "$TMP/$m-c.out" 0 0.2 "$(id "$m" 1)" "$(sql_confirmar "$m")"
  wait
  v=$(resultado "$TMP/$m-v.out"); c=$(resultado "$TMP/$m-c.out"); e=$(estado "$m")
  if [ "$v" = 200:codigo ] && [ "$c" = 409:checkin_ja_confirmado ] && [ "$e" = "codigo|verificado|0|1|true|false" ]; then :
  elif [ "$c" = 200:manual ] && [ "$v" = 409:checkin_ja_confirmado ] && [ "$e" = "manual|verificado|0|0|sem_aceita|true" ]; then :
  else erradas=$((erradas + 1)); echo "    rodada $i: validar $v · confirmar $c · $e" >&2
  fi
done
[ "$erradas" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, um caminho venceu e o turno combina com ele" \
  || falhou "$erradas de $RODADAS rodadas terminaram com dois vencedores ou turno incoerente"

exit "$falha"
