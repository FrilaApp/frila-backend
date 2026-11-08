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
MUNDOS=()   # cada montar_mundo se registra aqui, para a limpeza saber o que apagar

# Apaga tudo o que os mundos desta execução criaram, como as outras corridas. A suíte e a
# mutação rodam depois no mesmo banco, e um garçom disponível a semana toda no Plano Piloto
# vira destinatário extra de todo despacho dos testes (medido: 240, 260, 370, 430, 803 e
# 809 caíram na linha de base da mutação do #448). Apaga por id, e não por e-mail, porque a
# exclusão do cenário 4 anonimiza a conta.
limpar_mundos() {
  [ "${#MUNDOS[@]}" -gt 0 ] || return 0
  local m contas="" casas=""
  for m in "${MUNDOS[@]}"; do
    contas+="('$(id "$m" 1)'::uuid),('$(id "$m" 2)'::uuid),('$(id "$m" 3)'::uuid),"
    casas+="('$(id "$m" 10)'::uuid),"
  done
  psql >/dev/null <<SQL
set session_replication_role = 'replica';
create temp table contas as select * from (values ${contas%,}) v(id);
create temp table casas as select * from (values ${casas%,}) v(id);
create temp table profs as select id from public.profissional where usuario_id in (select id from contas);
create temp table vagas as select id from public.vaga where estabelecimento_id in (select id from casas);
create temp table posicoes as select id from public.posicao where vaga_id in (select id from vagas);
create temp table chamadas as select id from public.chamada
 where vaga_id in (select id from vagas) or profissional_id in (select id from profs)
    or estabelecimento_id in (select id from casas);
delete from public.notificacao
 where usuario_id in (select id from contas)
    or referencia_id in (select id from vagas union all select id from posicoes union all select id from chamadas);
do \$\$
begin
  if to_regclass('privado.marca_notificacao') is not null then
    delete from privado.marca_notificacao
     where usuario_id in (select id from contas)
        or referencia_id in (select id from vagas union all select id from posicoes union all select id from chamadas);
  end if;
end \$\$;
delete from pgmq.q_despacho where (message->>'vaga_id')::uuid in (select id from vagas);
delete from public.despacho where vaga_id in (select id from vagas) or profissional_id in (select id from profs);
delete from public.ocorrencia where autor_id in (select id from contas) or posicao_id in (select id from posicoes);
delete from public.turno where posicao_id in (select id from posicoes);
delete from public.candidatura where profissional_id in (select id from profs) or posicao_id in (select id from posicoes);
delete from public.chamada where id in (select id from chamadas);
delete from public.posicao where vaga_id in (select id from vagas);
delete from public.vaga where id in (select id from vagas);
delete from public.equipe_confianca where estabelecimento_id in (select id from casas) or profissional_id in (select id from profs);
delete from public.membro_estabelecimento where usuario_id in (select id from contas) or estabelecimento_id in (select id from casas);
delete from public.estabelecimento where id in (select id from casas);
delete from public.disponibilidade where profissional_id in (select id from profs);
delete from public.profissional_funcao where profissional_id in (select id from profs);
delete from public.profissional where id in (select id from profs);
-- O pedido de exclusão não tem FK para usuario (sobrevive à conta): sai pelo nome.
delete from public.pedido_de_exclusao where usuario_id in (select id from contas);
delete from public.usuario where id in (select id from contas);
delete from auth.users where id in (select id from contas);
set session_replication_role = 'origin';
SQL
}

limpar() {
  limpar_mundos || echo "  aviso: a limpeza dos mundos falhou; sobraram dados da marca $RUN" >&2
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
  local conta_sql=null
  [ -n "$conta" ] && conta_sql="'$conta'"
  (
    sleep "$atraso"
    psql <<SQL > "$saida" 2>&1
$AUX
begin;
select pg_temp.tentar($conta_sql, \$q\$ $sql \$q\$);
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
  MUNDOS+=("$m")
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

# Id do perfil profissional da conta dada. Lido como postgres e passado como literal: dentro
# da chamada, a sessão é a da casa, e a RLS de public.profissional esconde a linha dela.
prof_id() { psql -c "select id from public.profissional where usuario_id = '$1';"; }

# SQL de chamar_profissional para o mundo m, ao profissional (usuario) dado, numa vaga nova ou existente.
sql_chamar() {
  local m=$1 prof_usuario=$2 vaga=${3:-} prof
  local dia=$(( 2 + m ))
  prof=$(prof_id "$prof_usuario")
  if [ -n "$vaga" ]; then
    # Com vaga_id, a RPC recusa (422 vaga_id) quem repete os campos da vaga.
    cat <<SQL
select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => '$prof',
  estabelecimento_id => '$(id "$m" 10)', vaga_id => '$vaga')
SQL
    return
  fi
  cat <<SQL
select public.chamar_profissional(chave => gen_random_uuid(),
  profissional_id => '$prof',
  estabelecimento_id => '$(id "$m" 10)', funcao_id => (select id from public.funcao where nome = 'garçom'),
  inicio_em => date_trunc('hour', now()) + interval '$dia days', fim_em => date_trunc('hour', now()) + interval '$dia days 5 hours',
  local => 'CLN 201', regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
  valor_centavos => 15000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false,
  responsavel_local => 'Maitre')
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
  # O aceite precisa ter respondido uma das três saídas legítimas da disputa: venceu (ok),
  # chegou depois da exclusão (chamada_indisponivel ou nao_autenticado). Vazio ou outro erro
  # (sqlstate:*) quer dizer que não houve corrida, e a rodada não prova nada.
  case "$ra" in ok|chamada_indisponivel|nao_autenticado) aceite_ok=1 ;; *) aceite_ok=0 ;; esac
  if [ "$aceite_ok" != 1 ] || [ "$rb" != ok ] || [ "$conta" != anonimizada ] || [ "$fila" != 0 ] || [ "$desp" != 0 ]; then
    falhou "rodada $i: aceite '$ra', exclusão '$rb', conta '$conta', fila $fila, despachos $desp"; erros=$((erros + 1))
  fi
done
[ "$erros" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, conta excluída e nada foi à fila nem a terceiro"

exit "$falha"
