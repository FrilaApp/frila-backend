#!/usr/bin/env bash
# Corridas da equipe de confiança com o bloqueio e a entrada de membro (D-14, RF26; B-022).
#
# O pgTAP roda numa sessão só e não enxerga uma inclusão que ainda não tem commit. Aqui cada
# lado é uma conexão de verdade que chama a RPC como `authenticated`. A sessão que SEGURA faz a
# chamada e não confirma; só depois disso a sessão que CHEGA começa. A que segura espera até ver
# a outra presa numa trava (pg_stat_activity) ou terminada, e só então dá COMMIT. Assim a ordem
# de cada cenário é garantida, e não sorte de agenda.
#
# Cenários (cada rodada num mundo próprio: casa, administrador, profissional com turno
# verificado na casa, duas contas de contratante com convite, e a 1ª delas com bloqueio prévio
# com o profissional, num sentido nas rodadas pares e no outro nas ímpares):
#   1. inclui e segura  · o administrador bloqueia o profissional
#   2. o administrador bloqueia e segura · inclui
#   3. inclui e segura  · o profissional bloqueia a casa
#   4. o profissional bloqueia a casa e segura · inclui
#   5. inclui e segura  · entra na casa (aceitar_convite_membro) quem tem bloqueio prévio
#   6. entra na casa quem tem bloqueio prévio e segura · inclui
#   7. dois membros entram na mesma casa ao mesmo tempo pelo aceitar_convite_membro
#   8. dois membros entram na mesma casa ao mesmo tempo por insert direto (como a demonstração)
#
# Em toda rodada: nenhuma linha de equipe_confianca da casa com
# privado.bloqueado_com_estabelecimento(conta do profissional, casa) verdadeiro, nenhuma
# resposta fora das esperadas (deadlock 40P01 reprova pelo nome), e a sessão que chega ficou
# presa numa trava enquanto a outra segurava. Se não ficou, a corrida não aconteceu e a rodada
# não prova nada: reprova.
#
# Uso: ./scripts/corrida-equipe-bloqueio.sh        RODADAS=5 ./scripts/corrida-equipe-bloqueio.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB=${DB_CONTAINER:-supabase_db_frila-backend}
RODADAS=${RODADAS:-20}
psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

if [ "$RODADAS" -lt 1 ] || [ "$RODADAS" -gt 99 ]; then
  echo "RODADAS vai de 1 a 99" >&2; exit 1
fi

TMP=$(mktemp -d)
falha=0
RUN=$(( (RANDOM % 900) + 100 ))   # marca desta execução: reexecutar não colide com a anterior

# id <mundo> <entidade>: UUID sintético desta execução.
#   1 administrador · 2 profissional (conta) · 3 e 4 contratantes que entram · 10 casa · 20 perfil
id() { printf '%08x-0000-4000-8000-%012d' $(( 0xe0e00000 + RUN * 1000 + $1 )) "$2"; }
email() { printf 'corrida-equipe-%s-%s-%s@frila.test' "$RUN" "$1" "$2"; }
token() { printf 'corrida-equipe-%s-%s-%s' "$RUN" "$1" "$2"; }

MUNDOS=()   # cada montar_mundo se registra aqui, para a limpeza saber o que apagar

# shellcheck disable=SC2329 # chamada pelo trap EXIT
limpar() {
  if [ "${#MUNDOS[@]}" -gt 0 ]; then
    local m contas="" casas=""
    for m in "${MUNDOS[@]}"; do
      contas+="('$(id "$m" 1)'::uuid),('$(id "$m" 2)'::uuid),('$(id "$m" 3)'::uuid),('$(id "$m" 4)'::uuid),"
      casas+="('$(id "$m" 10)'::uuid),"
    done
    psql >/dev/null <<SQL || echo "  aviso: a limpeza falhou; sobraram dados da marca $RUN" >&2
set session_replication_role = 'replica';
create temp table contas as select * from (values ${contas%,}) v(id);
create temp table casas as select * from (values ${casas%,}) v(id);
create temp table profs as select id from public.profissional where usuario_id in (select id from contas);
create temp table vagas as select id from public.vaga where estabelecimento_id in (select id from casas);
create temp table posicoes as select id from public.posicao where vaga_id in (select id from vagas);
delete from public.notificacao where usuario_id in (select id from contas);
do \$\$
begin
  if to_regclass('privado.marca_notificacao') is not null then
    delete from privado.marca_notificacao where usuario_id in (select id from contas);
  end if;
end \$\$;
delete from public.bloqueio where autor_id in (select id from contas) or bloqueado_id in (select id from contas);
delete from public.equipe_confianca where estabelecimento_id in (select id from casas) or profissional_id in (select id from profs);
delete from privado.convite_membro where estabelecimento_id in (select id from casas);
delete from public.turno where posicao_id in (select id from posicoes);
delete from public.posicao where id in (select id from posicoes);
delete from public.vaga where id in (select id from vagas);
delete from public.membro_estabelecimento where usuario_id in (select id from contas) or estabelecimento_id in (select id from casas);
delete from public.estabelecimento where id in (select id from casas);
delete from public.profissional where id in (select id from profs);
delete from public.usuario where id in (select id from contas);
delete from auth.users where id in (select id from contas);
set session_replication_role = 'origin';
SQL
  fi
  rm -rf "$TMP"
}
trap limpar EXIT

# Função auxiliar de cada conexão: chama como a conta dada (ou como postgres, sem conta) e
# devolve 'ok' ou o code do erro; erro sem code sai como sqlstate:<código>.
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

# montar_mundo <m> <prof_na_equipe: sim|nao>
montar_mundo() {
  local m=$1 na_equipe=$2 adm prof c1 c2 estab perfil bloqueio
  MUNDOS+=("$m")
  adm=$(id "$m" 1); prof=$(id "$m" 2); c1=$(id "$m" 3); c2=$(id "$m" 4)
  estab=$(id "$m" 10); perfil=$(id "$m" 20)
  if [ $((m % 2)) = 0 ]; then
    bloqueio="('$c1', '$prof', now())"    # quem vai entrar bloqueou o profissional
  else
    bloqueio="('$prof', '$c1', now())"    # o profissional bloqueou quem vai entrar
  fi
  psql >/dev/null <<SQL
begin;
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at, raw_app_meta_data,
                        raw_user_meta_data, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', u, 'authenticated', 'authenticated', e, now(),
       '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
  from (values ('$adm'::uuid, '$(email "$m" 1)'), ('$prof'::uuid, '$(email "$m" 2)'),
               ('$c1'::uuid, '$(email "$m" 3)'), ('$c2'::uuid, '$(email "$m" 4)')) v(u, e);
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values ('$adm',  'contratante',  'Adm Corrida',   '+55619$(printf '%03d%03d%02d' "$RUN" "$m" 1)', '$(email "$m" 1)', '1980-01-01', '1.0', now(), false),
       ('$prof', 'profissional', 'Pro Corrida',   '+55619$(printf '%03d%03d%02d' "$RUN" "$m" 2)', '$(email "$m" 2)', '1990-01-01', '1.0', now(), false),
       ('$c1',   'contratante',  'Entra Um',      '+55619$(printf '%03d%03d%02d' "$RUN" "$m" 3)', '$(email "$m" 3)', '1985-01-01', '1.0', now(), false),
       ('$c2',   'contratante',  'Entra Dois',    '+55619$(printf '%03d%03d%02d' "$RUN" "$m" 4)', '$(email "$m" 4)', '1986-01-01', '1.0', now(), false);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('$estab', 'Casa Corrida Equipe $m', '8$(printf '%03d%010d' "$RUN" "$m")', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values ('$adm', '$estab', 'administrador');
insert into public.profissional (id, usuario_id, ponto_base) values ('$perfil', '$prof', 'POINT(-47.8822 -15.7800)'::extensions.geography);
-- Turno cumprido com presença verificada na casa: sem ele, incluir_na_equipe recusa.
with v as (
  insert into public.vaga (estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
                           responsavel_local, modo, chave_cliente, publicado_em, estado)
  values ('$estab', (select id from public.funcao where nome = 'garçom'), '$adm',
          now() - interval '3 days', now() - interval '3 days' + interval '5 hours', 'CLN 201',
          'POINT(-47.8822 -15.7942)'::extensions.geography, 15000, 1, true, false, false, 'Maitre',
          'urgencia', gen_random_uuid(), now() - interval '5 days', 'encerrada')
  returning id, inicio_em, fim_em
), p as (
  insert into public.posicao (vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  select v.id, '$perfil', 'cumprida', v.inicio_em - interval '1 day', false, v.inicio_em, v.fim_em from v
  returning id, inicio_em, fim_em
)
insert into public.turno (posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
select p.id, p.inicio_em, p.fim_em, 'geolocalizado', 50, 'verificado', 15000 from p;
insert into privado.convite_membro (estabelecimento_id, email, papel, convidado_por, token_hash, expira_em)
values ('$estab', '$(email "$m" 3)', 'operador', '$adm', encode(sha256(convert_to('$(token "$m" 3)', 'UTF8')), 'hex'), now() + interval '7 days'),
       ('$estab', '$(email "$m" 4)', 'operador', '$adm', encode(sha256(convert_to('$(token "$m" 4)', 'UTF8')), 'hex'), now() + interval '7 days');
insert into public.bloqueio (autor_id, bloqueado_id, criado_em) values $bloqueio;
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select '$estab', '$perfil' where '$na_equipe' = 'sim';
commit;
SQL
}

# segura <nome> <saida> <conta|''> <sql> <nome_de_quem_chega>: faz a chamada, não confirma e
# espera (até 3 s) a outra sessão ficar presa numa trava ou terminar. Imprime a resposta da
# chamada e 'visto:espera' ou 'visto:nao'.
segura() {
  local nome=$1 saida=$2 conta=$3 sql=$4 chega=$5 conta_sql=null
  [ -n "$conta" ] && conta_sql="'$conta'"
  psql > "$saida" 2>&1 <<SQL &
set application_name = '$nome';
$AUX
begin;
select pg_temp.tentar($conta_sql, \$q\$ $sql \$q\$);
select set_config('application_name', '${nome}_segurando', true) is null;
do \$d\$
begin
  perform set_config('corrida.visto', 'nao', true);
  for i in 1..150 loop
    perform pg_stat_clear_snapshot();
    if exists (select 1 from pg_stat_activity where application_name = '$chega' and wait_event_type = 'Lock') then
      perform set_config('corrida.visto', 'espera', true);
      exit;
    end if;
    exit when exists (select 1 from pg_stat_activity where application_name = '${chega}_fim');
    perform pg_sleep(0.02);
  end loop;
end \$d\$;
select 'visto:' || current_setting('corrida.visto', true);
commit;
SQL
}

# chega <nome> <saida> <conta|''> <sql>: faz a chamada e confirma; depois se anuncia terminada.
chega() {
  local nome=$1 saida=$2 conta=$3 sql=$4 conta_sql=null
  [ -n "$conta" ] && conta_sql="'$conta'"
  psql > "$saida" 2>&1 <<SQL &
set application_name = '$nome';
$AUX
begin;
select pg_temp.tentar($conta_sql, \$q\$ $sql \$q\$);
commit;
set application_name = '${nome}_fim';
select pg_sleep(0.3);
SQL
}

# Espera a sessão que segura chegar ao ponto de segurar (a chamada já rodou).
esperar_segurando() {
  local nome=$1 n
  for _ in $(seq 1 100); do
    n=$(psql -c "select count(*) from pg_stat_activity where application_name = '${nome}_segurando';")
    [ "$n" = 1 ] && return 0
    sleep 0.05
  done
  return 1
}

resposta() { grep -E '^(ok|[a-z_]+|sqlstate:.*)$' "$1" | head -1; }
visto() { grep -E '^visto:' "$1" | head -1; }

# Respostas aceitas: incluir pode ser ok ou 404 nao_encontrado (viu o bloqueio); o resto, ok.
aceita() { # resposta permitidas...
  local r=$1; shift
  local p
  for p in "$@"; do [ "$r" = "$p" ] && return 0; done
  return 1
}

# sql_de <m> <ação[:n]>: o SQL da ação no mundo m; n é a conta que entra (3 ou 4).
sql_de() {
  local m=$1 f=${2%%:*} n=${2#*:}
  case "$f" in
    incluir)   echo "select public.incluir_na_equipe('$(id "$m" 10)', '$(id "$m" 20)')" ;;
    bloq_prof) echo "select public.bloquear('profissional', '$(id "$m" 20)')" ;;
    bloq_casa) echo "select public.bloquear('estabelecimento', '$(id "$m" 10)')" ;;
    aceitar)   echo "select public.aceitar_convite_membro('$(token "$m" "$n")')" ;;
    inserir)   echo "insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values ('$(id "$m" "$n")', '$(id "$m" 10)', 'operador')" ;;
  esac
}

# cenario <n> <rótulo> <na_equipe> <conta_a> <sql_a> <aceitas_a> <conta_b> <sql_b> <aceitas_b>
#   conta_*: adm | prof | c1 | c2 | pg (postgres, sem JWT); sql_*: ação do sql_de acima;
#   aceitas_*: respostas aceitas, separadas por ','.
conta_de() { case "$2" in adm) id "$1" 1 ;; prof) id "$1" 2 ;; c1) id "$1" 3 ;; c2) id "$1" 4 ;; pg) echo "" ;; esac; }

cenario() {
  local n=$1 rotulo=$2 na_equipe=$3 ca=$4 sa=$5 aa=$6 cb=$7 sb=$8 ab=$9
  local i m erros=0 nome_a nome_b ra rb va inv dead
  echo "▸ $n. $rotulo"
  for i in $(seq 1 "$RODADAS"); do
    m=$(( n * 100 + i ))
    montar_mundo "$m" "$na_equipe" || { falhou "rodada $i: não montei o mundo"; erros=$((erros + 1)); continue; }
    nome_a="ceq_${RUN}_${m}_a"; nome_b="ceq_${RUN}_${m}_b"
    segura "$nome_a" "$TMP/$m-a" "$(conta_de "$m" "$ca")" "$(sql_de "$m" "$sa")" "$nome_b"
    if ! esperar_segurando "$nome_a"; then
      wait; falhou "rodada $i: a sessão que segura não chegou a segurar ($(head -c 300 "$TMP/$m-a"))"
      erros=$((erros + 1)); continue
    fi
    chega "$nome_b" "$TMP/$m-b" "$(conta_de "$m" "$cb")" "$(sql_de "$m" "$sb")"
    wait
    ra=$(resposta "$TMP/$m-a"); rb=$(resposta "$TMP/$m-b"); va=$(visto "$TMP/$m-a")
    inv=$(psql -c "select count(*) from public.equipe_confianca e join public.profissional p on p.id = e.profissional_id
                    where e.estabelecimento_id = '$(id "$m" 10)'
                      and privado.bloqueado_com_estabelecimento(p.usuario_id, e.estabelecimento_id);")
    dead=""
    { [ "$ra" = sqlstate:40P01 ] || [ "$rb" = sqlstate:40P01 ]; } && dead=" DEADLOCK (40P01)"
    # shellcheck disable=SC2086 # as respostas aceitas são uma lista separada por vírgula
    if [ "$inv" != 0 ] || [ -n "$dead" ] || [ "$va" != visto:espera ] \
       || ! aceita "$ra" ${aa//,/ } || ! aceita "$rb" ${ab//,/ }; then
      falhou "rodada $i:$dead primeira '$ra', segunda '$rb', $va, linhas bloqueadas na equipe $inv"
      erros=$((erros + 1))
    fi
  done
  [ "$erros" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, ninguém bloqueado na equipe, sem deadlock, e a segunda esperou a trava"
}

echo "▸ Corridas da equipe × bloqueio × membro novo: $RODADAS rodadas por cenário (marca $RUN)"
inicio=$SECONDS

cenario 1 "inclui e segura · o administrador bloqueia o profissional" nao \
  adm incluir ok        adm bloq_prof ok
cenario 2 "o administrador bloqueia e segura · inclui" nao \
  adm bloq_prof ok      adm incluir nao_encontrado
cenario 3 "inclui e segura · o profissional bloqueia a casa" nao \
  adm incluir ok        prof bloq_casa ok
cenario 4 "o profissional bloqueia a casa e segura · inclui" nao \
  prof bloq_casa ok     adm incluir nao_encontrado
cenario 5 "inclui e segura · entra na casa quem tem bloqueio prévio (aceitar_convite_membro)" nao \
  adm incluir ok        c1 aceitar:3 ok
cenario 6 "entra na casa quem tem bloqueio prévio e segura · inclui" nao \
  c1 aceitar:3 ok       adm incluir nao_encontrado
cenario 7 "dois membros entram na mesma casa ao mesmo tempo (aceitar_convite_membro)" sim \
  c1 aceitar:3 ok       c2 aceitar:4 ok
cenario 8 "dois membros entram na mesma casa ao mesmo tempo (insert direto)" sim \
  pg inserir:3 ok       pg inserir:4 ok

echo "▸ tempo: $(( SECONDS - inicio )) s"
exit "$falha"
