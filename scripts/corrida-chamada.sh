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
#      3b. Duas simultâneas sem vaga_id para o MESMO trabalho (segundos diferentes, o mesmo minuto),
#          a profissionais diferentes: uma vaga só; a outra recebe 409 trabalho_ja_aberto com o
#          vaga_id que a primeira criou, e nenhuma erro de concorrência (0.2.95, #520).
#      3c. A mesma chave enviada duas vezes ao mesmo tempo: as duas devolvem a mesma chamada
#          (a chave é relida depois da trava da casa; antes, a 2ª recebia chamada_ja_aberta).
#   4. Exclusão da conta do profissional x aceite da chamada: a vaga direta nunca vai à fila
#      do despacho nem é despachada a terceiro, mesmo com um terceiro elegível (conserto do
#      #434). O motor é chamado no fim para provar que nada sai.
#   5. A mesma disputa com a ordem forçada por uma terceira conexão, nas três ordens em que o
#      impasse fechava (#522): nenhum 40P01, e a conta excluída termina sem chamada aberta e
#      sem turno confirmado.
#   6. Cancelamento da vaga direta x aceite da chamada (B-035): nunca sobra chamada aberta nem
#      turno de pé numa vaga cancelada, e ninguém recebe 40P01. Em ordem livre e com a ordem
#      forçada em que o impasse fechava (o aceite com a vaga e a chamada, o cancelamento com a
#      posição).
#   7. Mais uma chamada (com vaga_id) x cancelamento da vaga direta (B-040, #543): nunca nasce
#      chamada aberta numa vaga cancelada, e ninguém recebe 40P01. Nas duas ordens, forçadas.
#   8. Mais uma chamada (com vaga_id) x a expiração da 1ª chamada da vaga direta (B-053, #550):
#      nunca sobra chamada aberta numa vaga encerrada, e ninguém recebe 40P01. Em ordem livre e
#      com a ordem forçada em que a vaga encerrava (a chamada nova com a vaga, o job depois).
#   9 a 12. Suspensão e bloqueio contra o aceite e a exclusão da mesma conta (#526), com a ordem
#      forçada por uma terceira conexão, como no 5: nenhum 40P01, e cada desfecho é o de quem
#      chegou primeiro. 9: suspensão x aceite; 10: suspensão x exclusão; 11: bloqueio x
#      exclusão; 12: bloqueio x aceite (este não fechava ciclo; fica como guarda).
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
# 0.2.66: só se chama quem tem aparelho na versão mínima de chamada_direta (#451). A corrida guarda o
# mínimo do iOS que havia antes, para devolvê-lo na limpeza.
minimo_antes=$(psql -c "select versao_minima from privado.recurso_versao_minima where recurso = 'chamada_direta' and plataforma = 'ios';")
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
delete from public.bloqueio where autor_id in (select id from contas) or bloqueado_id in (select id from contas);
delete from public.equipe_confianca where estabelecimento_id in (select id from casas) or profissional_id in (select id from profs);
delete from public.membro_estabelecimento where usuario_id in (select id from contas) or estabelecimento_id in (select id from casas);
delete from public.estabelecimento where id in (select id from casas);
delete from public.disponibilidade where profissional_id in (select id from profs);
delete from public.dispositivo where usuario_id in (select id from contas);
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
delete from privado.recurso_versao_minima where recurso = 'chamada_direta' and plataforma = 'ios';
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
select 'chamada_direta', 'ios', nullif('${minimo_antes:-}', '') where nullif('${minimo_antes:-}', '') is not null;
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
select pg_temp.tentar('$casa',  \$q\$ select public.criar_conta('contratante', 'Casa Corrida', '+5561$(printf '%03d%03d1%02d' "$RUN" "$m" 0)', '1980-01-01', '2026-09-22') \$q\$);
select pg_temp.tentar('$prof1', \$q\$ select public.criar_conta('profissional', 'Pê Um', '+5561$(printf '%03d%03d2%02d' "$RUN" "$m" 0)', '1990-01-01', '2026-09-22') \$q\$);
select pg_temp.tentar('$prof2', \$q\$ select public.criar_conta('profissional', 'Pê Dois', '+5561$(printf '%03d%03d3%02d' "$RUN" "$m" 0)', '1991-01-01', '2026-09-22') \$q\$);
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
-- Aparelho na versão mínima de chamada_direta para os dois profissionais (0.2.66, #451).
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app) values
  ('$prof1', 'tok-corrida-$prof1', 'ios', '1.2.0'), ('$prof2', 'tok-corrida-$prof2', 'ios', '1.2.0');
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
  local dia=${4:-$(( 2 + m ))}
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

# Chama de forma serial (montagem) e devolve "chamada_id vaga_id". O 4º argumento, opcional, é o
# dia da vaga nova (padrão: 2 + mundo).
chamar_serial() {
  local m=$1 prof_usuario=$2 vaga=${3:-} dia=${4:-}
  psql <<SQL | grep -E '^[0-9a-f-]{36} [0-9a-f-]{36}$'
begin;
select set_config('request.jwt.claims', json_build_object('sub', '$(id "$m" 1)', 'role', 'authenticated')::text, true) is null;
set local role authenticated;
create temp table r on commit drop as $(sql_chamar "$m" "$prof_usuario" "$vaga" "$dia") as j;
reset role;
select (j->>'id') || ' ' || (j->>'vaga_id') from r;
commit;
SQL
}

echo "▸ Corridas da chamada direta: $RODADAS rodadas por cenário (marca $RUN)"
psql >/dev/null -c "update privado.recurso set ligado = true where chave = 'chamada_direta';"
psql >/dev/null -c "insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0') on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;"

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

# ── 3b e 3c. O mesmo trabalho e a mesma chave ao mesmo tempo (0.2.95) ─────────
# Os mundos vão de 71 a 90 (RODADAS até 10, como os outros cenários). O horário é calculado uma
# vez, aqui, e vai literal nas duas conexões: as duas caem no mesmo minuto com segundos diferentes.
# lado_det: como `lado`, e devolve "code details" (ou 'ok' e o id da chamada criada).
AUX_DET=$(cat <<'SQL'
create function pg_temp.tentar_det(conta uuid, q text) returns text language plpgsql as $f$
declare m text; r jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute q into r;
  execute 'reset role';
  return 'ok ' || coalesce(r->>'id', '');
exception when others then
  get stacked diagnostics m = message_text;
  return case when m ~ '^\s*\{' then coalesce(m::jsonb->>'code', 'sem_code') || ' ' || coalesce(m::jsonb->>'details', '')
              else 'sqlstate:' || sqlstate end;
end $f$;
SQL
)
lado_det() {
  local saida=$1 conta=$2 sql=$3
  (
    psql <<SQL > "$saida" 2>&1
$AUX_DET
begin;
select pg_temp.tentar_det('$conta', \$q\$ $sql \$q\$);
select pg_sleep(1);
commit;
SQL
  ) &
}
resultado_det() { grep -E '^(ok|[a-z_]+|sqlstate:[^ ]*)( [0-9a-f-]*)?$' "$1" | head -1; }
# sql_trabalho <mundo> <prof_usuario> <segundos> <chave>: chamada sem vaga_id para o trabalho do mundo.
sql_trabalho() {
  local m=$1 prof_usuario=$2 seg=$3 chave=$4 prof
  prof=$(prof_id "$prof_usuario")
  cat <<SQL
select public.chamar_profissional(chave => '$chave', profissional_id => '$prof',
  estabelecimento_id => '$(id "$m" 10)', funcao_id => (select id from public.funcao where nome = 'garçom'),
  inicio_em => '$INICIO_3B'::timestamptz + interval '$seg seconds', fim_em => '$INICIO_3B'::timestamptz + interval '5 hours $seg seconds',
  local => 'CLN 201', regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
  valor_centavos => 15000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false,
  responsavel_local => 'Maitre')
SQL
}
INICIO_3B=$(psql -c "select date_trunc('minute', now()) + interval '3 days';")

echo "▸ 3b. duas chamadas sem vaga_id ao mesmo tempo para o mesmo trabalho, a profissionais diferentes"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$((70 + i)); montar_mundo "$m"
  lado_det "$TMP/3b-$i-a" "$(id "$m" 1)" "$(sql_trabalho "$m" "$(id "$m" 2)" 5 "$(id "$m" 901)")"
  lado_det "$TMP/3b-$i-b" "$(id "$m" 1)" "$(sql_trabalho "$m" "$(id "$m" 3)" 41 "$(id "$m" 902)")"
  wait
  ra=$(resultado_det "$TMP/3b-$i-a"); rb=$(resultado_det "$TMP/3b-$i-b")
  vagas=$(psql -c "select count(*) from public.vaga where estabelecimento_id = '$(id "$m" 10)';")
  vaga=$(psql -c "select string_agg(id::text, ',') from public.vaga where estabelecimento_id = '$(id "$m" 10)';")
  abertas=$(psql -c "select count(*) from public.chamada where estabelecimento_id = '$(id "$m" 10)' and estado = 'aberta';")
  # Um lado criou ('ok <chamada>'), o outro recebeu o 409 com a vaga que existe.
  case "${ra%% *} ${rb%% *}" in
    "ok trabalho_ja_aberto") recusa=${rb#* } ;;
    "trabalho_ja_aberto ok") recusa=${ra#* } ;;
    *) recusa=x ;;
  esac
  if [ "$vagas" != 1 ] || [ "$abertas" != 1 ] || [ "$recusa" != "$vaga" ]; then
    falhou "rodada $i: respostas '$ra'/'$rb', vagas $vagas ($vaga), chamadas abertas $abertas"; erros=$((erros + 1))
  fi
done
[ "$erros" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, uma vaga só e um 409 trabalho_ja_aberto com o vaga_id dela"

echo "▸ 3c. a mesma chave enviada duas vezes ao mesmo tempo"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$((80 + i)); montar_mundo "$m"
  sql=$(sql_trabalho "$m" "$(id "$m" 2)" 5 "$(id "$m" 903)")
  lado_det "$TMP/3c-$i-a" "$(id "$m" 1)" "$sql"
  lado_det "$TMP/3c-$i-b" "$(id "$m" 1)" "$sql"
  wait
  ra=$(resultado_det "$TMP/3c-$i-a"); rb=$(resultado_det "$TMP/3c-$i-b")
  chamadas=$(psql -c "select count(*) from public.chamada where estabelecimento_id = '$(id "$m" 10)';")
  vagas=$(psql -c "select count(*) from public.vaga where estabelecimento_id = '$(id "$m" 10)';")
  if [ "${ra%% *}" != ok ] || [ "$ra" != "$rb" ] || [ "$chamadas" != 1 ] || [ "$vagas" != 1 ]; then
    falhou "rodada $i: respostas '$ra'/'$rb', chamadas $chamadas, vagas $vagas"; erros=$((erros + 1))
  fi
done
[ "$erros" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, as duas devolvem a mesma chamada, e só ela existe"

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

# ── 5. Exclusão x aceite, com a ordem forçada (#522) ──────────────────────────
# O cenário 4 sorteia quem chega primeiro e quase nunca cai na janela do impasse (B-027: 0 em
# 30 rodadas com o sorteio dele; na CI, 1 em 4). Aqui uma terceira conexão (X) segura uma trava
# do caminho, e o script só a solta depois de ver em pg_stat_activity cada lado parado na
# espera em que o ciclo fechava. Nada depende de tempo: a ordem é a mesma em toda rodada, e
# antes da 20261117010000 toda rodada das três ordens terminava em 40P01.
#   a. a exclusão primeiro: X segura o aparelho do profissional; a exclusão para no delete do
#      aparelho com as travas dela tomadas, e o aceite chega depois.
#   b. o aceite primeiro: X segura a posição da vaga; o aceite para no update dela com a vaga e
#      a chamada travadas, e a exclusão chega depois. Ela tem de reabrir o turno confirmado.
#   c. outro profissional aceita a mesma vaga: X segura o aparelho do excluído; o aceite do
#      outro encerraria a chamada dele e o avisaria.
# Os mundos vão de 41 a 69 (RODADAS até 9, como os outros cenários até 10).

# segurar <nome> <sql>: a conexão X. Trava e fica parada até `soltar` cancelar a espera dela,
# o que desfaz a transação e libera a trava na hora.
segurar() {
  local nome=$1 sql=$2
  ( psql <<SQL > "$TMP/$nome" 2>&1
set application_name = '$nome';
begin;
$sql;
select pg_sleep(60);
commit;
SQL
  ) &
}
soltar() { psql >/dev/null -c "select pg_cancel_backend(pid) from pg_stat_activity where application_name like '$1';"; }

# lado_nomeado <nome> <conta|''> <sql>: como `lado`, sem atraso nem espera, com nome visível
# em pg_stat_activity para o script saber onde ele parou.
lado_nomeado() {
  local nome=$1 conta=$2 sql=$3 conta_sql=null
  [ -n "$conta" ] && conta_sql="'$conta'"
  ( psql <<SQL > "$TMP/$nome" 2>&1
set application_name = '$nome';
$AUX
begin;
select pg_temp.tentar($conta_sql, \$q\$ $sql \$q\$);
commit;
SQL
  ) &
}

# aguardar <nome> <segurando|travado>: até X estar no pg_sleep (com a trava tomada) ou até o
# lado estar parado numa trava. Desiste em 15 s.
aguardar() {
  local nome=$1 onde=$2 cond n=0
  case "$onde" in
    segurando) cond="query like 'select pg_sleep%'" ;;
    travado)   cond="wait_event_type = 'Lock'" ;;
  esac
  until [ "$(psql -c "select count(*) from pg_stat_activity where application_name = '$nome' and $cond;")" = 1 ]; do
    n=$((n + 1)); [ "$n" -ge 150 ] && return 1
    sleep 0.1
  done
}

# Conta as posições confirmadas de quem foi excluído: a exclusão reabre todas.
confirmadas_de() { psql -c "select count(*) from public.posicao p join public.profissional f on f.id = p.profissional_id where f.usuario_id = '$1' and p.estado = 'confirmada';"; }

echo "▸ 5. exclusão x aceite com a ordem forçada (a: exclusão primeiro, b: aceite primeiro, c: outro aceita a mesma vaga)"
erros=0; impasses=0
for i in $(seq 1 "$RODADAS"); do
  for ordem in a b c; do
    case "$ordem" in a) m=$((40 + i)) ;; b) m=$((50 + i)) ;; c) m=$((60 + i)) ;; esac
    montar_mundo "$m"
    p1=$(id "$m" 2); p2=$(id "$m" 3)
    read -r c1 vaga < <(chamar_serial "$m" "$p1")
    c2=
    [ "$ordem" = c ] && [ -n "${vaga:-}" ] && read -r c2 _ < <(chamar_serial "$m" "$p2" "$vaga")
    if [ -z "${c1:-}" ] || { [ "$ordem" = c ] && [ -z "${c2:-}" ]; }; then
      falhou "rodada $i ($ordem): não montei a chamada"; erros=$((erros + 1)); continue
    fi
    n="cc-$RUN-$m"
    case "$ordem" in
      a)
        segurar "$n-x" "select 1 from public.dispositivo where usuario_id = '$p1' for update"
        passos=("$n-x segurando" "excluir" "$n-b travado" "aceitar1" "$n-a travado") ;;
      b)
        segurar "$n-x" "select 1 from public.posicao where vaga_id = '$vaga' for update"
        passos=("$n-x segurando" "aceitar1" "$n-a travado" "excluir" "$n-b travado") ;;
      c)
        segurar "$n-x" "select 1 from public.dispositivo where usuario_id = '$p1' for update"
        passos=("$n-x segurando" "excluir" "$n-b travado" "aceitar2" "$n-a travado") ;;
    esac
    parou=
    for passo in "${passos[@]}"; do
      case "$passo" in
        excluir)  lado_nomeado "$n-b" "" "select privado.excluir_conta('$p1')" ;;
        aceitar1) lado_nomeado "$n-a" "$p1" "select public.responder_chamada('$c1', 'aceitar')" ;;
        aceitar2) lado_nomeado "$n-a" "$p2" "select public.responder_chamada('$c2', 'aceitar')" ;;
        *) aguardar ${passo% *} ${passo#* } || { parou=$passo; break; } ;;
      esac
    done
    if [ -n "$parou" ]; then
      # A ordem não se formou: solta todo mundo da rodada, para o `wait` não ficar no pg_sleep.
      soltar "$n-%"; wait
      falhou "rodada $i ($ordem): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
      erros=$((erros + 1)); continue
    fi
    soltar "$n-x"
    wait
    ra=$(resultado "$TMP/$n-a"); rb=$(resultado "$TMP/$n-b")
    conta=$(psql -c "select estado from public.usuario where id = '$p1';")
    e1=$(psql -c "select estado from public.chamada where id = '$c1';")
    conf1=$(confirmadas_de "$p1")
    case "$ra$rb" in *40P01*) impasses=$((impasses + 1)) ;; esac
    case "$ordem" in
      a) esperado="aceite 'chamada_indisponivel', exclusão 'ok', conta 'anonimizada', chamada 'cancelada', confirmadas 0"
         obtido="aceite '$ra', exclusão '$rb', conta '$conta', chamada '$e1', confirmadas $conf1" ;;
      b) fila=$(psql -c "select count(*) from pgmq.q_despacho where message->>'vaga_id' = '$vaga';")
         esperado="aceite 'ok', exclusão 'ok', conta 'anonimizada', chamada 'aceita', confirmadas 0, fila 0"
         obtido="aceite '$ra', exclusão '$rb', conta '$conta', chamada '$e1', confirmadas $conf1, fila $fila" ;;
      c) e2=$(psql -c "select estado from public.chamada where id = '$c2';")
         conf2=$(confirmadas_de "$p2")
         esperado="aceite do outro 'ok', exclusão 'ok', conta 'anonimizada', chamada 'cancelada', a do outro 'aceita', confirmadas 0 e 1"
         obtido="aceite do outro '$ra', exclusão '$rb', conta '$conta', chamada '$e1', a do outro '$e2', confirmadas $conf1 e $conf2" ;;
    esac
    if [ "$obtido" != "$esperado" ]; then
      falhou "rodada $i ($ordem): $obtido"; erros=$((erros + 1))
    fi
  done
done
if [ "$erros" = 0 ]; then
  ok "em $RODADAS de $RODADAS rodadas das três ordens, nenhum 40P01 e a conta excluída sem chamada aberta nem turno confirmado"
else
  printf '  (%s das rodadas com 40P01)\n' "$impasses" >&2
fi

# ── 6. Cancelamento da vaga direta x aceite (B-035) ───────────────────────────
# Dois desfechos legítimos, e só eles:
#   · o cancelamento chega antes: o aceite recebe chamada_indisponivel e a chamada fica encerrada;
#   · o aceite chega antes: confirma, e o cancelamento recolhe o turno (a chamada fica aceita,
#     desfecho final do contrato, com a posição cancelada).
# Nos dois, a vaga termina cancelada, sem chamada aberta e sem posição confirmada.
#   a. ordem livre, quem chega primeiro alterna (mundos 101 a 110);
#   b. ordem forçada (mundos 111 a 120): X segura a chamada; o aceite para nela com a vaga já
#      travada, e o cancelamento chega depois. Antes da 20261117050000, o cancelamento travava a
#      posição e esperava a vaga, o aceite esperava a posição, e a rodada terminava em 40P01.
echo "▸ 6. cancelamento da vaga direta x aceite (a: ordem livre, b: o aceite com a vaga, o cancelamento depois)"
erros=0; impasses=0
desfecho_6() {   # desfecho_6 <rodada> <vaga> <chamada> <aceite> <cancelamento>
  local i=$1 vaga=$2 c1=$3 ra=$4 rb=$5 gv e1 conf abertas
  gv=$(psql -c "select estado from public.vaga where id = '$vaga';")
  e1=$(psql -c "select estado from public.chamada where id = '$c1';")
  conf=$(psql -c "select count(*) from public.posicao where vaga_id = '$vaga' and estado = 'confirmada';")
  abertas=$(psql -c "select count(*) from public.chamada where vaga_id = '$vaga' and estado = 'aberta';")
  case "$ra$rb" in *40P01*) impasses=$((impasses + 1)) ;; esac
  if [ "$rb" = ok ] && [ "$gv" = cancelada ] && [ "$abertas" = 0 ] && [ "$conf" = 0 ] \
     && { { [ "$ra" = ok ] && [ "$e1" = aceita ]; } || { [ "$ra" = chamada_indisponivel ] && [ "$e1" = encerrada ]; }; }; then :
  else
    falhou "rodada $i: aceite '$ra', cancelamento '$rb', vaga '$gv', chamada '$e1', abertas $abertas, confirmadas $conf"
    erros=$((erros + 1))
  fi
}
for i in $(seq 1 "$RODADAS"); do
  m=$((100 + i)); montar_mundo "$m"
  read -r c1 vaga < <(chamar_serial "$m" "$(id "$m" 2)")
  [ -z "${c1:-}" ] && { falhou "rodada $i (a): não montei a chamada"; erros=$((erros + 1)); continue; }
  a=0; b=0.2; [ $((i % 2)) = 0 ] && { a=0.2; b=0; }
  lado "$TMP/6a-$i-a" "$a" 1 "$(id "$m" 2)" "select public.responder_chamada('$c1', 'aceitar')"
  lado "$TMP/6a-$i-b" "$b" 1 "$(id "$m" 1)" "select public.cancelar_vaga('$vaga', 'Evento desmarcado')"
  wait
  desfecho_6 "$i (a)" "$vaga" "$c1" "$(resultado "$TMP/6a-$i-a")" "$(resultado "$TMP/6a-$i-b")"
done
for i in $(seq 1 "$RODADAS"); do
  m=$((110 + i)); montar_mundo "$m"
  read -r c1 vaga < <(chamar_serial "$m" "$(id "$m" 2)")
  [ -z "${c1:-}" ] && { falhou "rodada $i (b): não montei a chamada"; erros=$((erros + 1)); continue; }
  n="cc-$RUN-$m"
  segurar "$n-x" "select 1 from public.chamada where id = '$c1' for update"
  parou=
  aguardar "$n-x" segurando || parou="$n-x segurando"
  if [ -z "$parou" ]; then
    lado_nomeado "$n-a" "$(id "$m" 2)" "select public.responder_chamada('$c1', 'aceitar')"
    aguardar "$n-a" travado || parou="$n-a travado"
  fi
  if [ -z "$parou" ]; then
    lado_nomeado "$n-b" "$(id "$m" 1)" "select public.cancelar_vaga('$vaga', 'Evento desmarcado')"
    aguardar "$n-b" travado || parou="$n-b travado"
  fi
  if [ -n "$parou" ]; then
    soltar "$n-%"; wait
    falhou "rodada $i (b): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
    erros=$((erros + 1)); continue
  fi
  soltar "$n-x"
  wait
  desfecho_6 "$i (b)" "$vaga" "$c1" "$(resultado "$TMP/$n-a")" "$(resultado "$TMP/$n-b")"
done
if [ "$erros" = 0 ]; then
  ok "em $RODADAS de $RODADAS rodadas das duas ordens, nenhum 40P01 e a vaga cancelada sem chamada aberta nem turno de pé"
else
  printf '  (%s das rodadas com 40P01)\n' "$impasses" >&2
fi

# ── 7. Mais uma chamada (com vaga_id) x cancelamento da vaga direta (B-040, #543) ─
# A casa chama o 2º profissional para a vaga direta que já tem a chamada do 1º, enquanto cancela
# a vaga. O gatilho da vaga cancelada (20261117050000) só fecha as chamadas que já existem; antes
# da 20261117080000, chamar_profissional lia a vaga sem trava, via "publicada" e inseria a chamada
# depois do cancelamento: chamada aberta numa vaga cancelada (3 de 3 no ensaio do parecer do #540).
#   a. o cancelamento primeiro (mundos 121 a 130): X segura a posição; o cancelamento para nela
#      com a vaga travada, e a chamada chega depois. Desfecho: 409 vaga_encerrada.
#   b. a chamada primeiro (mundos 131 a 140): X segura a conta do 2º profissional; a chamada para
#      no aviso (a chave estrangeira de public.notificacao), já com a vaga, e o cancelamento chega
#      depois. Desfecho: a chamada nasce e o cancelamento a encerra.
# Nos dois, a vaga termina cancelada e sem chamada aberta.
echo "▸ 7. mais uma chamada x cancelamento da vaga direta (a: o cancelamento primeiro, b: a chamada primeiro)"
erros=0; impasses=0
for i in $(seq 1 "$RODADAS"); do
  for ordem in a b; do
    case "$ordem" in a) m=$((120 + i)) ;; b) m=$((130 + i)) ;; esac
    montar_mundo "$m"
    p2=$(id "$m" 3)
    read -r c1 vaga < <(chamar_serial "$m" "$(id "$m" 2)")
    [ -z "${c1:-}" ] && { falhou "rodada $i ($ordem): não montei a chamada"; erros=$((erros + 1)); continue; }
    n="cc-$RUN-$m"
    case "$ordem" in
      a) segurar "$n-x" "select 1 from public.posicao where vaga_id = '$vaga' for update"
         passos=("$n-x segurando" "cancelar" "$n-b travado" "chamar" "$n-c travado") ;;
      b) segurar "$n-x" "select 1 from public.usuario where id = '$p2' for update"
         passos=("$n-x segurando" "chamar" "$n-c travado" "cancelar" "$n-b travado") ;;
    esac
    parou=
    for passo in "${passos[@]}"; do
      case "$passo" in
        cancelar) lado_nomeado "$n-b" "$(id "$m" 1)" "select public.cancelar_vaga('$vaga', 'Evento desmarcado')" ;;
        chamar)   lado_nomeado "$n-c" "$(id "$m" 1)" "$(sql_chamar "$m" "$p2" "$vaga")" ;;
        *) aguardar ${passo% *} ${passo#* } || { parou=$passo; break; } ;;
      esac
    done
    if [ -n "$parou" ]; then
      soltar "$n-%"; wait
      falhou "rodada $i ($ordem): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
      erros=$((erros + 1)); continue
    fi
    soltar "$n-x"
    wait
    rb=$(resultado "$TMP/$n-b"); rc=$(resultado "$TMP/$n-c")
    gv=$(psql -c "select estado from public.vaga where id = '$vaga';")
    abertas=$(psql -c "select count(*) from public.chamada where vaga_id = '$vaga' and estado = 'aberta';")
    e2=$(psql -c "select coalesce((select c.estado from public.chamada c join public.profissional p on p.id = c.profissional_id
                                    where c.vaga_id = '$vaga' and p.usuario_id = '$p2'), 'nenhuma');")
    case "$rb$rc" in *40P01*) impasses=$((impasses + 1)) ;; esac
    case "$ordem" in
      a) esperado="cancelamento 'ok', chamada 'vaga_encerrada', vaga 'cancelada', abertas 0, a do 2º 'nenhuma'" ;;
      b) esperado="cancelamento 'ok', chamada 'ok', vaga 'cancelada', abertas 0, a do 2º 'encerrada'" ;;
    esac
    obtido="cancelamento '$rb', chamada '$rc', vaga '$gv', abertas $abertas, a do 2º '$e2'"
    if [ "$obtido" != "$esperado" ]; then
      falhou "rodada $i ($ordem): $obtido"; erros=$((erros + 1))
    fi
  done
done
if [ "$erros" = 0 ]; then
  ok "em $RODADAS de $RODADAS rodadas das duas ordens, nenhum 40P01 e nenhuma chamada aberta na vaga cancelada"
else
  printf '  (%s das rodadas com 40P01)\n' "$impasses" >&2
fi

# ── 8. Mais uma chamada (com vaga_id) x a expiração da 1ª chamada (B-053, #550) ─
# A casa chama o 2º profissional para a vaga direta enquanto o job privado.expirar_chamadas expira
# a chamada do 1º. Antes da 20261117130000, o job conferia "sem chamada aberta" sem trava: não via
# a chamada nova, ainda sem commit, esperava a vaga (que o chamar segura desde a 20261117080000) e
# a encerrava com a chamada nova aberta dentro. Dois desfechos legítimos, e só eles:
#   · a chamada chega antes: nasce aberta, e o job expira a 1ª e deixa a vaga publicada;
#   · o job chega antes: encerra a vaga, e a chamada recebe 409 vaga_encerrada.
#   a. ordem livre, quem chega primeiro alterna (mundos 141 a 150);
#   b. ordem forçada (mundos 151 a 160): X segura a conta do 2º profissional; a chamada para no
#      aviso, já com a vaga travada e a chamada inserida, e o job chega depois e para na vaga.
# A 1ª chamada é vencida à mão (expira_em no passado) logo antes da disputa. O job do pg_cron roda
# a mesma função a cada minuto: se ele passar no meio, o desfecho é um dos dois acima.
echo "▸ 8. mais uma chamada x expiração da 1ª chamada (a: ordem livre, b: a chamada com a vaga, o job depois)"
erros=0; impasses=0
vencer() { psql >/dev/null -c "update public.chamada set expira_em = now() - interval '1 minute' where id = '$1';"; }
desfecho_8() {   # desfecho_8 <rodada> <vaga> <chamada do 1º> <usuario do 2º> <chamar> <job> [só a chamada primeiro]
  local i=$1 vaga=$2 c1=$3 p2=$4 rc=$5 re=$6 so_chamada=${7:-} gv e1 e2 abertas
  gv=$(psql -c "select estado from public.vaga where id = '$vaga';")
  e1=$(psql -c "select estado from public.chamada where id = '$c1';")
  e2=$(psql -c "select coalesce((select c.estado from public.chamada c join public.profissional p on p.id = c.profissional_id
                                  where c.vaga_id = '$vaga' and p.usuario_id = '$p2'), 'nenhuma');")
  abertas=$(psql -c "select count(*) from public.chamada where vaga_id = '$vaga' and estado = 'aberta';")
  case "$rc$re" in *40P01*) impasses=$((impasses + 1)) ;; esac
  if [ "$re" = ok ] && [ "$e1" = expirada ] && [ "$rc" = ok ] && [ "$gv" = publicada ] && [ "$e2" = aberta ] && [ "$abertas" = 1 ]; then :
  elif [ -z "$so_chamada" ] && [ "$re" = ok ] && [ "$e1" = expirada ] && [ "$rc" = vaga_encerrada ] && [ "$gv" = encerrada ] \
       && [ "$e2" = nenhuma ] && [ "$abertas" = 0 ]; then :
  else
    falhou "rodada $i: chamada '$rc', job '$re', vaga '$gv', a do 1º '$e1', a do 2º '$e2', abertas $abertas"
    erros=$((erros + 1))
  fi
}
for i in $(seq 1 "$RODADAS"); do
  m=$((140 + i)); montar_mundo "$m"
  p2=$(id "$m" 3)
  read -r c1 vaga < <(chamar_serial "$m" "$(id "$m" 2)")
  [ -z "${c1:-}" ] && { falhou "rodada $i (a): não montei a chamada"; erros=$((erros + 1)); continue; }
  chamar=$(sql_chamar "$m" "$p2" "$vaga")
  a=0; b=0.2; [ $((i % 2)) = 0 ] && { a=0.2; b=0; }
  vencer "$c1"
  lado "$TMP/8a-$i-c" "$a" 1 "$(id "$m" 1)" "$chamar"
  lado "$TMP/8a-$i-e" "$b" 1 "" "select privado.expirar_chamadas()"
  wait
  desfecho_8 "$i (a)" "$vaga" "$c1" "$p2" "$(resultado "$TMP/8a-$i-c")" "$(resultado "$TMP/8a-$i-e")"
done
for i in $(seq 1 "$RODADAS"); do
  m=$((150 + i)); montar_mundo "$m"
  p2=$(id "$m" 3)
  read -r c1 vaga < <(chamar_serial "$m" "$(id "$m" 2)")
  [ -z "${c1:-}" ] && { falhou "rodada $i (b): não montei a chamada"; erros=$((erros + 1)); continue; }
  chamar=$(sql_chamar "$m" "$p2" "$vaga")
  n="cc-$RUN-$m"
  segurar "$n-x" "select 1 from public.usuario where id = '$p2' for update"
  parou=
  aguardar "$n-x" segurando || parou="$n-x segurando"
  if [ -z "$parou" ]; then
    lado_nomeado "$n-c" "$(id "$m" 1)" "$chamar"
    aguardar "$n-c" travado || parou="$n-c travado"
  fi
  if [ -z "$parou" ]; then
    vencer "$c1"
    lado_nomeado "$n-e" "" "select privado.expirar_chamadas()"
    aguardar "$n-e" travado || parou="$n-e travado"
  fi
  if [ -n "$parou" ]; then
    soltar "$n-%"; wait
    falhou "rodada $i (b): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
    erros=$((erros + 1)); continue
  fi
  soltar "$n-x"
  wait
  desfecho_8 "$i (b)" "$vaga" "$c1" "$p2" "$(resultado "$TMP/$n-c")" "$(resultado "$TMP/$n-e")" so_chamada
done
if [ "$erros" = 0 ]; then
  ok "em $RODADAS de $RODADAS rodadas das duas ordens, nenhum 40P01 e nenhuma chamada aberta numa vaga encerrada"
else
  printf '  (%s das rodadas com 40P01)\n' "$impasses" >&2
fi

# ── 9 a 12. Suspensão e bloqueio x aceite e exclusão, com a ordem forçada (#526) ─
# O molde é o do 5: X segura uma trava do caminho, e o script só solta X depois de ver cada lado
# parado onde o ciclo fechava. A regra de travas é a do aceite, vaga -> chamada -> usuario; antes
# da 20261117140000, privado.operacao_suspender_conta pegava o usuario (FOR UPDATE) antes da vaga
# e da chamada, e public.bloquear pegava o usuario (FOR KEY SHARE, a chave estrangeira do
# bloqueio) antes da chamada que o gatilho dele encerra.
#
# forcar <prefixo> <passo...>: "<lado> segurando|travado" espera o lado chegar lá; "<lado>"
# sozinho abre a conexão dele, com a conta em CONTA_<lado> e o SQL em SQL_<lado>. Se a ordem
# não se formar em 15 s, solta todo mundo e devolve 1 (o passo fica em $parou); senão solta X e
# espera os lados terminarem.
forcar() {
  local n=$1 passo c s; shift
  parou=
  for passo in "$@"; do
    case "$passo" in
      *" "*) aguardar "$n-${passo% *}" "${passo#* }" || { parou=$passo; break; } ;;
      *) c="CONTA_$passo"; s="SQL_$passo"; lado_nomeado "$n-$passo" "${!c}" "${!s}" ;;
    esac
  done
  if [ -n "$parou" ]; then soltar "$n-%"; wait; return 1; fi
  soltar "$n-x"; wait
}
# impasse <ordem> <respostas...>: conta a rodada da ordem que terminou em 40P01.
impasse() {
  local o=$1; shift
  case "$*" in *40P01*) eval "IMP_$o=\$(( \${IMP_$o:-0} + 1 ))" ;; esac
}
# resumo_impasses <variável> <ordens...>: grava "a 4/4, b 0/4" na variável e zera as contagens.
resumo_impasses() {
  local var=$1 o v r=; shift
  for o in "$@"; do v="IMP_$o"; r+="$o ${!v:-0}/$RODADAS, "; eval "IMP_$o=0"; done
  printf -v "$var" '%s' "${r%, }"
}
# turno_confirmado <mundo> <usuario do profissional>: outra vaga direta da casa, um dia antes da
# do mundo, aceita pelo profissional. Devolve a posição confirmada. É o que a suspensão do
# profissional reabre depois de pegar o usuario: segurando essa posição, X para a suspensão com
# o usuario já travado e antes do gatilho dela chegar na chamada.
turno_confirmado() {
  local m=$1 prof=$2 c0 v0 r
  read -r c0 v0 < <(chamar_serial "$m" "$prof" "" $(( 1 + m )))
  [ -n "${c0:-}" ] || return 1
  r=$(psql <<SQL
$AUX
select pg_temp.tentar('$prof', \$q\$ select public.responder_chamada('$c0', 'aceitar') \$q\$);
SQL
)
  [ "$r" = ok ] || return 1
  psql -c "select id from public.posicao where vaga_id = '$v0' and estado = 'confirmada';"
}
estado_de()    { psql -c "select estado from public.usuario where id = '$1';"; }
bloqueios_de() { psql -c "select count(*) from public.bloqueio where bloqueado_id = '$1' or autor_id = '$1';"; }
sql_suspender() { echo "select privado.operacao_suspender_conta('$1', 'Corrida da suspensão', '$2')"; }

# ── 9. Suspensão x aceite ─────────────────────────────────────────────────────
#   a. o aceite primeiro (mundos 161 a 170): X segura a posição; o aceite para nela com a vaga e a
#      chamada, e a suspensão do profissional chega depois. Ela tem de reabrir o turno confirmado.
#   b. a suspensão primeiro (mundos 171 a 180): o profissional já tem outro turno confirmado, e X
#      segura essa posição; a suspensão para nela com o usuario travado, e o aceite chega depois.
#   c. a casa suspensa (mundos 181 a 190): X segura a posição; o aceite para nela com a vaga e a
#      chamada, e a suspensão da casa (único membro) chega depois e recolhe a vaga.
# Quem assina a suspensão é o 2º profissional (qualquer conta ativa que não seja a suspensa).
echo "▸ 9. suspensão x aceite com a ordem forçada (a: o aceite primeiro, b: a suspensão primeiro, c: a casa suspensa)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  for ordem in a b c; do
    case "$ordem" in a) m=$((160 + i)) ;; b) m=$((170 + i)) ;; c) m=$((180 + i)) ;; esac
    montar_mundo "$m"
    casa=$(id "$m" 1); p1=$(id "$m" 2); p2=$(id "$m" 3); p0=
    [ "$ordem" = b ] && p0=$(turno_confirmado "$m" "$p1")
    read -r c1 vaga < <(chamar_serial "$m" "$p1")
    if [ -z "${c1:-}" ] || { [ "$ordem" = b ] && [ -z "$p0" ]; }; then
      falhou "rodada $i ($ordem): não montei a chamada"; erros=$((erros + 1)); continue
    fi
    n="cc-$RUN-$m"
    CONTA_a=$p1; SQL_a="select public.responder_chamada('$c1', 'aceitar')"
    CONTA_s=;    SQL_s=$(sql_suspender "$p1" "$p2"); alvo=$p1
    case "$ordem" in
      a) segurar "$n-x" "select 1 from public.posicao where vaga_id = '$vaga' for update"
         passos=("x segurando" a "a travado" s "s travado") ;;
      b) segurar "$n-x" "select 1 from public.posicao where id = '$p0' for update"
         passos=("x segurando" s "s travado" a "a travado") ;;
      c) segurar "$n-x" "select 1 from public.posicao where vaga_id = '$vaga' for update"
         SQL_s=$(sql_suspender "$casa" "$p2"); alvo=$casa
         passos=("x segurando" a "a travado" s "s travado") ;;
    esac
    if ! forcar "$n" "${passos[@]}"; then
      falhou "rodada $i ($ordem): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
      erros=$((erros + 1)); continue
    fi
    ra=$(resultado "$TMP/$n-a"); rs=$(resultado "$TMP/$n-s")
    impasse "$ordem" "$ra" "$rs"
    obtido="aceite '$ra', suspensão '$rs', conta '$(estado_de "$alvo")', chamada '$(psql -c "select estado from public.chamada where id = '$c1';")', confirmadas $(confirmadas_de "$p1")"
    case "$ordem" in
      a) esperado="aceite 'ok', suspensão 'ok', conta 'suspensa', chamada 'aceita', confirmadas 0" ;;
      b) esperado="aceite 'chamada_indisponivel', suspensão 'ok', conta 'suspensa', chamada 'cancelada', confirmadas 0" ;;
      c) obtido+=", vaga '$(psql -c "select estado from public.vaga where id = '$vaga';")'"
         esperado="aceite 'ok', suspensão 'ok', conta 'suspensa', chamada 'aceita', confirmadas 0, vaga 'cancelada'" ;;
    esac
    [ "$obtido" != "$esperado" ] && { falhou "rodada $i ($ordem): $obtido"; erros=$((erros + 1)); }
  done
done
resumo_impasses r9 a b c
if [ "$erros" = 0 ]; then
  ok "em $RODADAS de $RODADAS rodadas das três ordens, nenhum 40P01 e o desfecho de quem chegou primeiro"
else
  printf '  (40P01 por ordem: %s)\n' "$r9" >&2
fi

# ── 10. Suspensão x exclusão da mesma conta ───────────────────────────────────
# Mundos 191 a 200. O profissional tem outro turno confirmado, e X segura essa posição: a
# suspensão para nela com o usuario travado, e a exclusão da mesma conta chega depois. A
# suspensão termina, e a exclusão anonimiza a conta suspensa.
echo "▸ 10. suspensão x exclusão da mesma conta com a ordem forçada (a suspensão primeiro)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$((190 + i)); montar_mundo "$m"
  p1=$(id "$m" 2); p2=$(id "$m" 3)
  p0=$(turno_confirmado "$m" "$p1")
  read -r c1 vaga < <(chamar_serial "$m" "$p1")
  if [ -z "${c1:-}" ] || [ -z "$p0" ]; then falhou "rodada $i: não montei a chamada"; erros=$((erros + 1)); continue; fi
  n="cc-$RUN-$m"
  CONTA_s=; SQL_s=$(sql_suspender "$p1" "$p2")
  CONTA_e=; SQL_e="select privado.excluir_conta('$p1')"
  segurar "$n-x" "select 1 from public.posicao where id = '$p0' for update"
  if ! forcar "$n" "x segurando" s "s travado" e "e travado"; then
    falhou "rodada $i: '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
    erros=$((erros + 1)); continue
  fi
  rs=$(resultado "$TMP/$n-s"); re=$(resultado "$TMP/$n-e")
  impasse a "$rs" "$re"
  obtido="suspensão '$rs', exclusão '$re', conta '$(estado_de "$p1")', chamada '$(psql -c "select estado from public.chamada where id = '$c1';")', confirmadas $(confirmadas_de "$p1")"
  esperado="suspensão 'ok', exclusão 'ok', conta 'anonimizada', chamada 'cancelada', confirmadas 0"
  [ "$obtido" != "$esperado" ] && { falhou "rodada $i: $obtido"; erros=$((erros + 1)); }
done
resumo_impasses r10 a
if [ "$erros" = 0 ]; then
  ok "em $RODADAS de $RODADAS rodadas, nenhum 40P01, e a conta suspensa e depois anonimizada sem chamada aberta"
else
  printf '  (40P01: %s)\n' "$r10" >&2
fi

# ── 11. Bloqueio x exclusão da conta bloqueada ────────────────────────────────
# X segura o usuario da conta que se exclui em FOR KEY SHARE (o modo da chave estrangeira): a
# exclusão para no FOR UPDATE do usuario com a vaga e a chamada já travadas, e o bloqueio, que
# não conflita com X, chega depois. Antes, o bloqueio ganhava o FOR KEY SHARE e parava na
# chamada; ao soltar X, a exclusão esperava o bloqueio.
#   a. a casa bloqueia o profissional que se exclui (mundos 201 a 210): a exclusão cancela a chamada;
#   b. o profissional bloqueia a casa que se exclui (mundos 211 a 220): a exclusão cancela a vaga,
#      e o gatilho da vaga cancelada encerra a chamada antes.
# Nos dois, a exclusão termina primeiro e o bloqueio fica gravado contra a conta anonimizada.
echo "▸ 11. bloqueio x exclusão da conta bloqueada com a ordem forçada (a: a casa bloqueia, b: o profissional bloqueia)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  for ordem in a b; do
    case "$ordem" in a) m=$((200 + i)) ;; b) m=$((210 + i)) ;; esac
    montar_mundo "$m"
    casa=$(id "$m" 1); p1=$(id "$m" 2)
    read -r c1 vaga < <(chamar_serial "$m" "$p1")
    [ -z "${c1:-}" ] && { falhou "rodada $i ($ordem): não montei a chamada"; erros=$((erros + 1)); continue; }
    n="cc-$RUN-$m"
    case "$ordem" in
      a) alvo=$p1;   CONTA_b=$casa; SQL_b="select public.bloquear('profissional', '$(prof_id "$p1")')"; fim=cancelada ;;
      b) alvo=$casa; CONTA_b=$p1;   SQL_b="select public.bloquear('estabelecimento', '$(id "$m" 10)')"; fim=encerrada ;;
    esac
    CONTA_e=; SQL_e="select privado.excluir_conta('$alvo')"
    segurar "$n-x" "select 1 from public.usuario where id = '$alvo' for key share"
    if ! forcar "$n" "x segurando" e "e travado" b "b travado"; then
      falhou "rodada $i ($ordem): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
      erros=$((erros + 1)); continue
    fi
    re=$(resultado "$TMP/$n-e"); rb=$(resultado "$TMP/$n-b")
    impasse "$ordem" "$re" "$rb"
    obtido="exclusão '$re', bloqueio '$rb', conta '$(estado_de "$alvo")', chamada '$(psql -c "select estado from public.chamada where id = '$c1';")', bloqueios $(bloqueios_de "$alvo")"
    esperado="exclusão 'ok', bloqueio 'ok', conta 'anonimizada', chamada '$fim', bloqueios 1"
    [ "$obtido" != "$esperado" ] && { falhou "rodada $i ($ordem): $obtido"; erros=$((erros + 1)); }
  done
done
resumo_impasses r11 a b
if [ "$erros" = 0 ]; then
  ok "em $RODADAS de $RODADAS rodadas das duas ordens, nenhum 40P01, a conta anonimizada sem chamada aberta e o bloqueio gravado"
else
  printf '  (40P01 por ordem: %s)\n' "$r11" >&2
fi

# ── 12. Bloqueio x aceite (guarda: não fechava ciclo) ─────────────────────────
#   a. o aceite primeiro (mundos 221 a 230): X segura a posição; o aceite para nela com a vaga e a
#      chamada, e o bloqueio da casa chega depois. O turno confirmado sobrevive ao bloqueio.
#   b. o bloqueio primeiro (mundos 231 a 240): X segura o perfil do profissional; o bloqueio para
#      nele (o gatilho que tira da equipe) com a chamada já encerrada, e o aceite chega depois.
echo "▸ 12. bloqueio x aceite com a ordem forçada (a: o aceite primeiro, b: o bloqueio primeiro)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  for ordem in a b; do
    case "$ordem" in a) m=$((220 + i)) ;; b) m=$((230 + i)) ;; esac
    montar_mundo "$m"
    casa=$(id "$m" 1); p1=$(id "$m" 2)
    read -r c1 vaga < <(chamar_serial "$m" "$p1")
    [ -z "${c1:-}" ] && { falhou "rodada $i ($ordem): não montei a chamada"; erros=$((erros + 1)); continue; }
    n="cc-$RUN-$m"
    CONTA_a=$p1;   SQL_a="select public.responder_chamada('$c1', 'aceitar')"
    CONTA_b=$casa; SQL_b="select public.bloquear('profissional', '$(prof_id "$p1")')"
    case "$ordem" in
      a) segurar "$n-x" "select 1 from public.posicao where vaga_id = '$vaga' for update"
         passos=("x segurando" a "a travado" b "b travado") ;;
      b) segurar "$n-x" "select 1 from public.profissional where usuario_id = '$p1' for update"
         passos=("x segurando" b "b travado" a "a travado") ;;
    esac
    if ! forcar "$n" "${passos[@]}"; then
      falhou "rodada $i ($ordem): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
      erros=$((erros + 1)); continue
    fi
    ra=$(resultado "$TMP/$n-a"); rb=$(resultado "$TMP/$n-b")
    impasse "$ordem" "$ra" "$rb"
    obtido="aceite '$ra', bloqueio '$rb', chamada '$(psql -c "select estado from public.chamada where id = '$c1';")', confirmadas $(confirmadas_de "$p1"), bloqueios $(bloqueios_de "$p1")"
    case "$ordem" in
      a) esperado="aceite 'ok', bloqueio 'ok', chamada 'aceita', confirmadas 1, bloqueios 1" ;;
      b) esperado="aceite 'chamada_indisponivel', bloqueio 'ok', chamada 'encerrada', confirmadas 0, bloqueios 1" ;;
    esac
    [ "$obtido" != "$esperado" ] && { falhou "rodada $i ($ordem): $obtido"; erros=$((erros + 1)); }
  done
done
resumo_impasses r12 a b
if [ "$erros" = 0 ]; then
  ok "em $RODADAS de $RODADAS rodadas das duas ordens, nenhum 40P01 e o desfecho de quem chegou primeiro"
else
  printf '  (40P01 por ordem: %s)\n' "$r12" >&2
fi

exit "$falha"
