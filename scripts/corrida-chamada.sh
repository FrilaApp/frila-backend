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
#  13. Suspensão da casa (único membro, depois de remover o administrador antigo) x bloqueio da
#      casa pelo profissional que o antigo chamou (#526): nenhum 40P01, a vaga cancelada e a
#      chamada do ex-membro encerrada.
#  14 a 18. O job privado.expirar_chamadas x quem pega a vaga antes da chamada (#562), com a ordem
#      forçada por uma terceira conexão: 14, o aceite da mesma chamada; 15, o cancelamento da vaga
#      direta; 16, mais uma chamada com vaga_id (guarda); 17, a exclusão da conta do profissional;
#      18, a suspensão do profissional e a da casa. Nenhum 40P01, e o desfecho de quem chegou primeiro.
#  19. Os dois jobs, privado.expirar_chamadas x privado.lembrar_chamadas, com duas chamadas vencidas
#      e de lembrete pendente em que a ordem de id é a inversa da de lembrete_em e expira_em, e a
#      ordem forçada por uma terceira conexão (#562): nenhum 40P01, e as duas chamadas expiradas.
#  20. O job x publicar_a_partir_da_chamada com irmãs (parecer do Lince r2 no #563): duas vagas diretas
#      irmãs publicadas G1 < G2, cada uma com uma chamada vencida e outra no prazo; a conversão de G2.
#      a: X segura G1, o job espera G1, a conversão espera G1; b: a conversão na frente (guarda).
#      Nenhum 40P01: as vencidas expiradas, as do prazo encerradas e as duas irmãs encerradas.
#  21. O job x publicar_a_partir_da_chamada sem irmãs (guarda): uma vaga só, as duas ordens.
#  22. Dois expirar_chamadas ao mesmo tempo, em duas vagas, com a ordem forçada (guarda).
#  23. O job x quem pega só a chamada (guarda): cancelar_chamada, bloquear e a recusa, com X segurando
#      a chamada; a: o outro lado primeiro, b: o job primeiro. Desfecho de quem chegou primeiro.
#  24. O job x a conversão x reabrir_por_atraso de uma irmã preenchida, entre a trava da conversão e o
#      update das irmãs (guarda): a reabertura espera a conversão, nenhum 40P01, a conversão feita e a
#      irmã reaberta depois dela.
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
    contas+="('$(id "$m" 1)'::uuid),('$(id "$m" 2)'::uuid),('$(id "$m" 3)'::uuid),('$(id "$m" 4)'::uuid),('$(id "$m" 5)'::uuid),"
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
# A conversão (cenários 20, 21 e 24) enfileira o despacho e quer o segredo do agendador, lido do Vault
# ou, na falta dele, de frila.agendador_secret (privado.disparar_despacho, 20261103120000). O passo da CI
# não o tem (o reset apaga o do banco), e o roteiro não depende do ambiente: cada conexão nomeada põe um
# valor aleatório só na própria sessão. Nada vai ao banco, ao Vault nem à saída; o Vault, se houver,
# continua valendo antes dele.
SEGREDO_SESSAO=$(openssl rand -hex 32)
lado_nomeado() {
  local nome=$1 conta=$2 sql=$3 conta_sql=null
  [ -n "$conta" ] && conta_sql="'$conta'"
  ( psql <<SQL > "$TMP/$nome" 2>&1
set application_name = '$nome';
do \$s\$ begin perform set_config('frila.agendador_secret', '$SEGREDO_SESSAO', false); end \$s\$;
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

aguardar_fim_ou_trava() {   # devolve 0 com $onde = terminou|travado; 1 em 15 s sem nenhum dos dois.
  local nome=$1 arq=$2 n=0
  onde=
  until [ -n "$onde" ]; do
    if [ "$(psql -c "select count(*) from pg_stat_activity where application_name = '$nome' and wait_event_type = 'Lock';")" = 1 ]; then
      onde=travado
    elif [ -s "$arq" ] && [ "$(psql -c "select count(*) from pg_stat_activity where application_name = '$nome';")" = 0 ]; then
      onde=terminou
    else
      n=$((n + 1)); [ "$n" -ge 150 ] && return 1
      sleep 0.1
    fi
  done
}

# cron_cai <prefixo>: com EXPIRAR_FORCADO=1, o expirar_chamadas do pg_cron "cai aqui". É o ponto da
# montagem em que as chamadas já estão vencidas e o cron, a cada minuto, podia passar (#568). Roda o
# job numa conexão nomeada (<prefixo>-k) e espera ela terminar ou parar numa trava: terminou, o cron
# ganhou a corrida e o cenário já não acha o que esperar; parada, ele é mais um na fila. Sem a variável,
# não faz nada: é só a prova da exposição (o expirar forçado antes da disputa).
cron_cai() {
  [ -n "${EXPIRAR_FORCADO:-}" ] || return 0
  lado_nomeado "$1-k" "" "select privado.expirar_chamadas()"
  aguardar_fim_ou_trava "$1-k" "$TMP/$1-k"
}
# longe_do_cron: até o segundo do relógio do banco ficar entre 3 e 35 e a execução deste minuto do
# expirar_chamadas (e do fechar_turnos_e_vagas, no minuto múltiplo de 5) ter terminado, se o pg_cron a
# registrou (cron.job_run_details): um cron atrasado não cai no meio da rodada. Sem registro em 70 s,
# fica só a janela. (A mesma do #567, que a usa nos cenários 25 a 27.)
longe_do_cron() {
  local n=0
  until [ "$(psql -c "select extract(second from clock_timestamp()) between 3 and 35
      and ($n >= 70 or not exists (
        select 1 from cron.job j
         where j.active and (j.jobname = 'expirar_chamadas_diretas'
                             or (j.jobname = 'fechar_turnos_e_vagas' and extract(minute from clock_timestamp())::int % 5 = 0))
           and not exists (select 1 from cron.job_run_details d
                            where d.jobid = j.jobid and d.start_time >= date_trunc('minute', clock_timestamp())
                              and d.end_time is not null)));")" = t ]; do
    n=$((n + 1)); sleep 1
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
  vencer "$c1"; cron_cai "cc-$RUN-$m"
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
    vencer "$c1"; cron_cai "$n"
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

# ── 13. Suspensão da casa x bloqueio, com a chamada de um ex-membro (#526, Lince) ─
# Mundos 241 a 250, e 251 a 260 só para a conta do administrador novo. A chamada é do
# administrador antigo; o novo (a casa do mundo 250 + i) entra, remove o antigo e fica como único
# membro. X segura a posição da vaga: a suspensão do novo para no update dela, e o profissional
# bloqueia a casa depois. Na 1ª versão da 20261117140000, a suspensão não pré-travava a chamada
# do ex-membro (ela não é da conta suspensa), o bloqueio a pegava e parava na chave estrangeira do
# usuario, e o gatilho vaga_cancelada_fecha_chamadas pedia a chamada a ele: 40P01 no bloqueio.
echo "▸ 13. suspensão da casa x bloqueio, com a chamada do ex-membro, com a ordem forçada (a suspensão primeiro)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$((240 + i)); montar_mundo "$m"; montar_mundo $((250 + i))
  antigo=$(id "$m" 1); novo=$(id $((250 + i)) 1); p1=$(id "$m" 2); p2=$(id "$m" 3); estab=$(id "$m" 10)
  read -r c1 vaga < <(chamar_serial "$m" "$p1")
  [ -z "${c1:-}" ] && { falhou "rodada $i: não montei a chamada"; erros=$((erros + 1)); continue; }
  troca=$(psql <<SQL
$AUX
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values ('$novo', '$estab', 'administrador');
select pg_temp.tentar('$novo', \$q\$ select public.remover_membro('$estab', '$antigo') \$q\$);
select string_agg(usuario_id::text, ',') from public.membro_estabelecimento where estabelecimento_id = '$estab';
SQL
)
  [ "$troca" != "$(printf 'ok\n%s' "$novo")" ] && { falhou "rodada $i: a troca de administrador não deixou o novo sozinho ($troca)"; erros=$((erros + 1)); continue; }
  n="cc-$RUN-$m"
  CONTA_s=;    SQL_s=$(sql_suspender "$novo" "$p2")
  CONTA_b=$p1; SQL_b="select public.bloquear('estabelecimento', '$estab')"
  segurar "$n-x" "select 1 from public.posicao where vaga_id = '$vaga' for update"
  if ! forcar "$n" "x segurando" s "s travado" b "b travado"; then
    falhou "rodada $i: '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
    erros=$((erros + 1)); continue
  fi
  rs=$(resultado "$TMP/$n-s"); rb=$(resultado "$TMP/$n-b")
  impasse a "$rs" "$rb"
  obtido="suspensão '$rs', bloqueio '$rb', conta '$(estado_de "$novo")', chamada '$(psql -c "select estado from public.chamada where id = '$c1';")', vaga '$(psql -c "select estado from public.vaga where id = '$vaga';")', bloqueios $(bloqueios_de "$novo")"
  esperado="suspensão 'ok', bloqueio 'ok', conta 'suspensa', chamada 'encerrada', vaga 'cancelada', bloqueios 1"
  [ "$obtido" != "$esperado" ] && { falhou "rodada $i: $obtido"; erros=$((erros + 1)); }
done
resumo_impasses r13 a
if [ "$erros" = 0 ]; then
  ok "em $RODADAS de $RODADAS rodadas, nenhum 40P01, a vaga cancelada com a chamada do ex-membro encerrada e o bloqueio gravado"
else
  printf '  (40P01: %s)\n' "$r13" >&2
fi

# ── 14 a 18. O job privado.expirar_chamadas x quem pega a vaga antes da chamada (#562) ─
# Antes da 20261117170000, o job pegava a chamada vencida (FOR UPDATE) e só depois a vaga, para
# encerrar a vaga direta que ficou sem chamada aberta; o resto pega vaga -> chamada. Em todos, X
# segura a vaga, e os dois lados param nela, sem sorteio:
#   · o outro lado chega primeiro, sem nenhuma trava; a 1ª chamada vence; o job chega depois (antes
#     da 20261117170000, já com a chamada vencida travada). Ao soltar X, o outro lado pega a vaga e
#     quer a chamada que o job segura, e o job quer a vaga: era aqui que o ciclo fechava.
#   · no 16, a ordem é a outra: o job primeiro.
# Cada cenário diz o desfecho de quem chegou primeiro, e ninguém pode receber 40P01.
#   14. o aceite da mesma chamada, que fez a conferência do prazo antes de ela vencer (mundos 261 a 270);
#   15. o cancelamento da vaga direta, que começou antes do vencimento: o gatilho dele quer a chamada
#       ainda no prazo (mundos 271 a 280). A chamada vence pelo relógio de parede, entre o começo do
#       cancelamento e o do job;
#   16. mais uma chamada (com vaga_id) ao 2º profissional, com o job na frente dela na fila da vaga: a
#       outra ordem do 8b (mundos 281 a 290). Ela não pede a chamada do job; fica como guarda;
#   17. a exclusão da conta do profissional da chamada (mundos 291 a 300);
#   18. a suspensão: a. do profissional da chamada (mundos 301 a 310); b. da casa, único membro (311 a 320).
# O job do pg_cron roda a mesma função a cada minuto: se ele passar no meio, é mais um na fila da vaga.
vencer_agora() { psql >/dev/null -c "update public.chamada set expira_em = clock_timestamp() where id = '$1';"; }
estado_vaga()  { psql -c "select estado from public.vaga where id = '$1';"; }
abertas_vaga() { psql -c "select count(*) from public.chamada where vaga_id = '$1' and estado = 'aberta';"; }

# corrida_job <cenário> <mundo> <aceitar|cancelar|chamar|excluir|suspender|suspender_casa>
#             <vencer|vencer_agora> [job_primeiro]
# Monta o mundo, força a ordem e espera os dois lados terminarem. Deixa c1, vaga, p1, p2, casa,
# ro (o outro lado) e re (o job) prontos; devolve 1 se não montou ou se a ordem não se formou.
corrida_job() {
  local cen=$1 m=$2 tipo=$3 venc=$4 job_primeiro=${5:-}
  montar_mundo "$m"
  casa=$(id "$m" 1); p1=$(id "$m" 2); p2=$(id "$m" 3)
  read -r c1 vaga < <(chamar_serial "$m" "$p1")
  [ -z "${c1:-}" ] && { falhou "rodada $i ($cen): não montei a chamada"; erros=$((erros + 1)); return 1; }
  n="cc-$RUN-$m"
  # shellcheck disable=SC2034  # CONTA_* e SQL_* são lidas pelo nome, no laço abaixo
  case "$tipo" in
    aceitar)        CONTA_o=$p1;   SQL_o="select public.responder_chamada('$c1', 'aceitar')" ;;
    cancelar)       CONTA_o=$casa; SQL_o="select public.cancelar_vaga('$vaga', 'Evento desmarcado')" ;;
    chamar)         CONTA_o=$casa; SQL_o=$(sql_chamar "$m" "$p2" "$vaga") ;;
    excluir)        CONTA_o=;      SQL_o="select privado.excluir_conta('$p1')" ;;
    suspender)      CONTA_o=;      SQL_o=$(sql_suspender "$p1" "$p2") ;;
    suspender_casa) CONTA_o=;      SQL_o=$(sql_suspender "$casa" "$p2") ;;
  esac
  # shellcheck disable=SC2034
  CONTA_e=
  # shellcheck disable=SC2034
  SQL_e="select privado.expirar_chamadas()"
  segurar "$n-x" "select 1 from public.vaga where id = '$vaga' for update"
  if [ -n "$job_primeiro" ]; then
    passos=("x segurando" vencer e "e travado" o "o travado")
  else
    passos=("x segurando" o "o travado" vencer e "e travado")
  fi
  # Como no forcar: cada lado abre pelo nome; o "vencer" entre eles vence a 1ª chamada.
  parou=
  local passo
  for passo in "${passos[@]}"; do
    case "$passo" in
      vencer) "$venc" "$c1"; cron_cai "$n" ;;
      *" "*)  aguardar "$n-${passo% *}" "${passo#* }" || { parou=$passo; break; } ;;
      *)      local c="CONTA_$passo" s="SQL_$passo"; lado_nomeado "$n-$passo" "${!c}" "${!s}" ;;
    esac
  done
  if [ -n "$parou" ]; then
    soltar "$n-%"; wait
    falhou "rodada $i ($cen): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
    erros=$((erros + 1)); return 1
  fi
  soltar "$n-x"; wait
  ro=$(resultado "$TMP/$n-o"); re=$(resultado "$TMP/$n-e")
}
# fim_job <cenário> <descrição do ok> <ordens...>: a linha de ok ou a contagem de 40P01 por ordem.
fim_job() {
  local v="r$1" d=$2; shift 2
  resumo_impasses "$v" "$@"
  if [ "$erros" = 0 ]; then
    ok "em $RODADAS de $RODADAS rodadas, nenhum 40P01 e $d"
  else
    printf '  (40P01 por ordem: %s)\n' "${!v}" >&2
  fi
}
# confere_job <obtido> <esperado...>: falha a rodada se o obtido não for nenhum dos esperados.
confere_job() {
  local obtido=$1 e; shift
  for e in "$@"; do [ "$obtido" = "$e" ] && return 0; done
  falhou "rodada $i: $obtido"; erros=$((erros + 1))
}

echo "▸ 14. job x aceite da mesma chamada, com a ordem forçada (o aceite antes do vencimento, o job depois)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  corrida_job 14 $((260 + i)) aceitar vencer || continue
  impasse a "$ro" "$re"
  confere_job "aceite '$ro', job '$re', chamada '$(psql -c "select estado from public.chamada where id = '$c1';")', vaga '$(estado_vaga "$vaga")', confirmadas $(confirmadas_de "$p1")" \
    "aceite 'ok', job 'ok', chamada 'aceita', vaga 'preenchida', confirmadas 1"
done
fim_job 14 "o aceite confirmado (ele começou no prazo)" a

echo "▸ 15. job x cancelamento da vaga direta, com a ordem forçada (o cancelamento antes do vencimento, o job depois)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  corrida_job 15 $((270 + i)) cancelar vencer_agora || continue
  impasse a "$ro" "$re"
  confere_job "cancelamento '$ro', job '$re', chamada '$(psql -c "select estado from public.chamada where id = '$c1';")', vaga '$(estado_vaga "$vaga")', abertas $(abertas_vaga "$vaga")" \
    "cancelamento 'ok', job 'ok', chamada 'encerrada', vaga 'cancelada', abertas 0"
done
fim_job 15 "a vaga cancelada com a chamada encerrada" a

echo "▸ 16. job x mais uma chamada (com vaga_id), com a ordem forçada (o job primeiro; guarda)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  corrida_job 16 $((280 + i)) chamar vencer job_primeiro || continue
  impasse a "$ro" "$re"
  e2=$(psql -c "select coalesce((select c.estado from public.chamada c join public.profissional p on p.id = c.profissional_id
                                  where c.vaga_id = '$vaga' and p.usuario_id = '$p2'), 'nenhuma');")
  confere_job "chamada '$ro', job '$re', a do 1º '$(psql -c "select estado from public.chamada where id = '$c1';")', a do 2º '$e2', vaga '$(estado_vaga "$vaga")', abertas $(abertas_vaga "$vaga")" \
    "chamada 'vaga_encerrada', job 'ok', a do 1º 'expirada', a do 2º 'nenhuma', vaga 'encerrada', abertas 0"
done
fim_job 16 "a vaga encerrada pelo job e a chamada nova recusada com vaga_encerrada" a

echo "▸ 17. job x exclusão da conta do profissional, com a ordem forçada (a exclusão primeiro, o job depois)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  corrida_job 17 $((290 + i)) excluir vencer || continue
  impasse a "$ro" "$re"
  confere_job "exclusão '$ro', job '$re', conta '$(estado_de "$p1")', chamada '$(psql -c "select estado from public.chamada where id = '$c1';")', abertas $(abertas_vaga "$vaga")" \
    "exclusão 'ok', job 'ok', conta 'anonimizada', chamada 'cancelada', abertas 0"
done
fim_job 17 "a conta anonimizada sem chamada aberta" a

echo "▸ 18. job x suspensão, com a ordem forçada (a: do profissional, b: da casa; a suspensão primeiro, o job depois)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  for ordem in a b; do
    case "$ordem" in
      a) corrida_job 18a $((300 + i)) suspender vencer || continue; alvo=$p1 ;;
      b) corrida_job 18b $((310 + i)) suspender_casa vencer || continue; alvo=$casa ;;
    esac
    impasse "$ordem" "$ro" "$re"
    obtido="suspensão '$ro', job '$re', conta '$(estado_de "$alvo")', chamada '$(psql -c "select estado from public.chamada where id = '$c1';")', abertas $(abertas_vaga "$vaga")"
    case "$ordem" in
      a) confere_job "$obtido" "suspensão 'ok', job 'ok', conta 'suspensa', chamada 'cancelada', abertas 0" ;;
      b) confere_job "$obtido, vaga '$(estado_vaga "$vaga")'" \
           "suspensão 'ok', job 'ok', conta 'suspensa', chamada 'encerrada', abertas 0, vaga 'cancelada'" ;;
    esac
  done
done
fim_job 18 "a conta suspensa sem chamada aberta" a b


# ── 19. Os dois jobs: expirar_chamadas x lembrar_chamadas (#562, parecer do Lince) ─
# Desde a 20261117170000 o expirar pega as chamadas por id. O lembrete pegava por lembrete_em,
# inclusive as vencidas (o prazo só é olhado depois da trava). Com duas chamadas A e B, A.id < B.id
# mas B com lembrete_em e expira_em antes dos de A (os jobs retomando depois de um atraso), X segura
# B; o lembrete (L) para em B sem nada; o expirar (E) pega A e para em B, atrás de L. Ao soltar X, L
# pega B e quer A, que é de E; E quer B, que é de L: o ciclo. Com os dois por id, L pega A primeiro
# e E espera L em A sem segurar nada que L queira.
# O lembrete não dispara no silêncio (22h às 7h de Brasília), e a CI roda a qualquer hora: a
# conexão de L marca privado.ambiente como teste e congela frila.agora no meio-dia de amanhã, só
# dentro da transação dela, que termina em rollback (como o scripts/contrato-respostas.sql). E segue
# no relógio de verdade. Mundos 321 a 330.
lado_lembrete() {
  local nome=$1
  ( psql <<SQL > "$TMP/$nome" 2>&1
set application_name = '$nome';
$AUX
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
do \$\$ begin
  perform set_config('frila.agora', ((date_trunc('day', now() at time zone 'America/Sao_Paulo') + interval '1 day 12 hours') at time zone 'America/Sao_Paulo')::text, true);
end \$\$;
select pg_temp.tentar(null, \$q\$ select privado.lembrar_chamadas() \$q\$);
rollback;
SQL
  ) &
}

echo "▸ 19. os dois jobs: expirar_chamadas x lembrar_chamadas, com a ordem de id inversa à do lembrete e à do prazo"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$((320 + i))
  montar_mundo "$m"
  casa=$(id "$m" 1); p1=$(id "$m" 2); p2=$(id "$m" 3)
  read -r c1 vaga < <(chamar_serial "$m" "$p1")
  [ -z "${c1:-}" ] && { falhou "rodada $i (19): não montei a 1ª chamada"; erros=$((erros + 1)); continue; }
  read -r c2 _ < <(chamar_serial "$m" "$p2" "$vaga")
  [ -z "${c2:-}" ] && { falhou "rodada $i (19): não montei a 2ª chamada"; erros=$((erros + 1)); continue; }
  # A é a de id menor; B, a de id maior, vence e lembra antes.
  if [[ "$c1" < "$c2" ]]; then ca=$c1; cb=$c2; else ca=$c2; cb=$c1; fi
  n="cc-$RUN-$m"
  # B tem de estar vencida antes de X a segurar (X a trava de B, e o update esperaria): o cron não pode
  # cair entre o vencimento e X. Vence-se longe do cron, e a rodada cabe na janela dele (#568).
  cron_cai "$n"; longe_do_cron
  psql >/dev/null <<SQL
update public.chamada set lembrete_em = now() - interval '2 minutes', expira_em = now() - interval '1 minute' where id = '$ca';
update public.chamada set lembrete_em = now() - interval '3 minutes', expira_em = now() - interval '2 minutes' where id = '$cb';
SQL
  segurar "$n-x" "select 1 from public.chamada where id = '$cb' for update"
  parou=
  aguardar "$n-x" segurando || parou="x segurando"
  if [ -z "$parou" ]; then lado_lembrete "$n-l"; aguardar "$n-l" travado || parou="l travado"; fi
  if [ -z "$parou" ]; then
    lado_nomeado "$n-e" "" "select privado.expirar_chamadas()"
    aguardar "$n-e" travado || parou="e travado"
  fi
  if [ -n "$parou" ]; then
    soltar "$n-%"; wait
    falhou "rodada $i (19): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
    erros=$((erros + 1)); continue
  fi
  soltar "$n-x"; wait
  rl=$(resultado "$TMP/$n-l"); re=$(resultado "$TMP/$n-e")
  impasse a "$rl" "$re"
  confere_job "lembrete '$rl', job '$re', A '$(psql -c "select estado from public.chamada where id = '$ca';")', B '$(psql -c "select estado from public.chamada where id = '$cb';")', abertas $(abertas_vaga "$vaga")" \
    "lembrete 'ok', job 'ok', A 'expirada', B 'expirada', abertas 0"
done
fim_job 19 "as duas chamadas expiradas" a

# ── 20 e 21. O job x publicar_a_partir_da_chamada (parecer do Lince r2 no #563) ─────────
# Desde a 20261117170000 o job trava as vagas por id. A conversão travava a origem e só depois, no
# update, as irmãs (as outras vagas diretas da casa para o mesmo trabalho, ainda publicadas), sem
# ordem; a trava da casa não serializa com o job, que não a pega. Duas irmãs G1 < G2, cada uma com
# uma chamada vencida (o job pede as duas vagas) e outra no prazo (a vaga não encerra sozinha):
#   a. X segura G1; o job (E) para em G1; a conversão de G2 (C) para em G1. Antes do conserto, C já
#      segurava G2: ao soltar X, E pega G1 e quer G2, de C; C quer G1, de E: o ciclo. Com a origem e
#      as irmãs travadas por id, C espera G1 sem segurar G2.
#   b. a conversão na frente (C, depois E): guarda.
# Duas irmãs do mesmo trabalho não nascem mais pela RPC (trabalho_ja_aberto, #520), mas as antigas
# existem (20261117020000; 874 C9): a montagem as grava direto, como o 874. Mundos 331 a 350.
# 21. sem irmãs, uma vaga com uma chamada vencida e outra no prazo, nas duas ordens (guarda; 351 a 370).
vaga_direta() {   # vaga_direta <mundo> <entidade> <dia>: uma vaga direta publicada, gravada direto.
  local m=$1 e=$2 dia=$3
  psql >/dev/null <<SQL
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, regiao_administrativa, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
                         modo, chave_cliente, publicado_em, estado, origem)
values ('$(id "$m" "$e")', '$(id "$m" 10)', (select id from public.funcao where nome = 'garçom'), '$(id "$m" 1)',
        date_trunc('hour', now()) + interval '$dia days', date_trunc('hour', now()) + interval '$dia days 5 hours',
        'CLN 201', 'Plano Piloto', 'POINT(-47.8822 -15.7942)'::extensions.geography, 15000, 1, true, false, false, 'Maitre',
        'urgencia', gen_random_uuid(), now() - interval '1 hour', 'publicada', 'chamada_direta');
insert into public.posicao (vaga_id, inicio_em, fim_em)
select id, inicio_em, fim_em from public.vaga where id = '$(id "$m" "$e")';
SQL
}
chamada_direta() {   # chamada_direta <mundo> <vaga> <usuario do profissional> <vencida|prazo>: devolve o id.
  local m=$1 v=$2 u=$3 prazo="now() + interval '2 hours'"
  [ "$4" = vencida ] && prazo="now() - interval '1 minute'"
  psql -c "insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, chave)
           values ('$v', (select id from public.profissional where usuario_id = '$u'), '$(id "$m" 10)', '$(id "$m" 1)', $prazo, gen_random_uuid())
           returning id;"
}
mais_prof() {   # mais_prof <mundo> <4|5>: mais um profissional no mundo (só a conta e o perfil).
  local m=$1 k=$2 u
  u=$(id "$m" "$k")
  psql >/dev/null <<SQL
$AUX
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', '$u', 'authenticated', 'authenticated', 'corrida-chamada-$RUN-$m-$k@frila.test', now(), now(), false, false);
select pg_temp.tentar('$u', \$q\$ select public.criar_conta('profissional', 'Pê Mais', '+5561$(printf '%03d%03d%01d%02d' "$RUN" "$m" "$k" 0)', '1992-01-01', '2026-09-22') \$q\$);
insert into public.profissional (usuario_id, ponto_base) values ('$u', 'POINT(-47.8822 -15.7800)'::extensions.geography);
SQL
}
estado_chamada() { psql -c "select estado from public.chamada where id = '$1';"; }
# ordem_conv <prefixo> <job_primeiro|conv_primeiro> <vaga segurada>: X segura a vaga, os dois lados
# param nela na ordem dada, X solta. Devolve 1 (com $parou) se a ordem não se formou.
ordem_conv() {
  local n=$1 ordem=$2 alvo=$3 passos passo c s
  segurar "$n-x" "select 1 from public.vaga where id = '$alvo' for update"
  if [ "$ordem" = job_primeiro ]; then passos=("x segurando" e "e travado" o "o travado")
  else passos=("x segurando" o "o travado" e "e travado"); fi
  parou=
  for passo in "${passos[@]}"; do
    case "$passo" in
      *" "*) aguardar "$n-${passo% *}" "${passo#* }" || { parou=$passo; break; } ;;
      *) c="CONTA_$passo"; s="SQL_$passo"; lado_nomeado "$n-$passo" "${!c}" "${!s}" ;;
    esac
  done
  if [ -n "$parou" ]; then soltar "$n-%"; wait; return 1; fi
  soltar "$n-x"; wait
}

echo "▸ 20. job x publicar_a_partir_da_chamada com duas irmãs (a: o job primeiro em G1; b: a conversão primeiro)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  for ordem in a b; do
    case "$ordem" in a) m=$((330 + i)) ;; b) m=$((340 + i)) ;; esac
    montar_mundo "$m"; mais_prof "$m" 4; mais_prof "$m" 5
    casa=$(id "$m" 1); p1=$(id "$m" 2); p2=$(id "$m" 3); p3=$(id "$m" 4); p4=$(id "$m" 5)
    g1=$(id "$m" 20); g2=$(id "$m" 21)   # g1 < g2 pelo id
    vaga_direta "$m" 20 3; vaga_direta "$m" 21 3
    v1=$(chamada_direta "$m" "$g1" "$p1" vencida); a1=$(chamada_direta "$m" "$g1" "$p2" prazo)
    # Uma chamada aberta por par casa e profissional (RN34): quatro profissionais.
    v2=$(chamada_direta "$m" "$g2" "$p3" vencida); a2=$(chamada_direta "$m" "$g2" "$p4" prazo)
    [ -n "$v1" ] && [ -n "$a1" ] && [ -n "$v2" ] && [ -n "$a2" ] || { falhou "rodada $i (20$ordem): não montei as chamadas"; erros=$((erros + 1)); continue; }
    n="cc-$RUN-$m"
    # shellcheck disable=SC2034
    CONTA_e=
    # shellcheck disable=SC2034
    SQL_e="select privado.expirar_chamadas()"
    # shellcheck disable=SC2034
    CONTA_o=$casa; SQL_o="select public.publicar_a_partir_da_chamada('$g2', gen_random_uuid(), 'urgencia')"
    case "$ordem" in a) o=job_primeiro ;; b) o=conv_primeiro ;; esac
    if ! ordem_conv "$n" "$o" "$g1"; then
      falhou "rodada $i (20$ordem): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
      erros=$((erros + 1)); continue
    fi
    ro=$(resultado "$TMP/$n-o"); re=$(resultado "$TMP/$n-e")
    impasse "$ordem" "$ro" "$re"
    nova=$(psql -c "select count(*) from public.vaga where vaga_origem_id = '$g2' and estado = 'publicada';")
    confere_job "conversão '$ro', job '$re', vencidas '$(estado_chamada "$v1")'/'$(estado_chamada "$v2")', no prazo '$(estado_chamada "$a1")'/'$(estado_chamada "$a2")', G1 '$(estado_vaga "$g1")', G2 '$(estado_vaga "$g2")', nova $nova" \
      "conversão 'ok', job 'ok', vencidas 'expirada'/'expirada', no prazo 'encerrada'/'encerrada', G1 'encerrada', G2 'encerrada', nova 1" \
      "conversão 'ok', job 'ok', vencidas 'encerrada'/'encerrada', no prazo 'encerrada'/'encerrada', G1 'encerrada', G2 'encerrada', nova 1"
  done
done
fim_job 20 "a conversão feita, as irmãs encerradas e nenhuma chamada aberta" a b

echo "▸ 21. job x publicar_a_partir_da_chamada sem irmãs (guarda; a: o job primeiro, b: a conversão primeiro)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  for ordem in a b; do
    case "$ordem" in a) m=$((350 + i)) ;; b) m=$((360 + i)) ;; esac
    montar_mundo "$m"
    casa=$(id "$m" 1); p1=$(id "$m" 2); p2=$(id "$m" 3)
    g1=$(id "$m" 20); vaga_direta "$m" 20 3
    v1=$(chamada_direta "$m" "$g1" "$p1" vencida); a1=$(chamada_direta "$m" "$g1" "$p2" prazo)
    [ -n "$v1" ] && [ -n "$a1" ] || { falhou "rodada $i (21$ordem): não montei as chamadas"; erros=$((erros + 1)); continue; }
    n="cc-$RUN-$m"
    # shellcheck disable=SC2034
    CONTA_e=
    # shellcheck disable=SC2034
    SQL_e="select privado.expirar_chamadas()"
    # shellcheck disable=SC2034
    CONTA_o=$casa; SQL_o="select public.publicar_a_partir_da_chamada('$g1', gen_random_uuid(), 'urgencia')"
    case "$ordem" in a) o=job_primeiro ;; b) o=conv_primeiro ;; esac
    if ! ordem_conv "$n" "$o" "$g1"; then
      falhou "rodada $i (21$ordem): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
      erros=$((erros + 1)); continue
    fi
    ro=$(resultado "$TMP/$n-o"); re=$(resultado "$TMP/$n-e")
    impasse "$ordem" "$ro" "$re"
    nova=$(psql -c "select count(*) from public.vaga where vaga_origem_id = '$g1' and estado = 'publicada';")
    confere_job "conversão '$ro', job '$re', vencida '$(estado_chamada "$v1")', no prazo '$(estado_chamada "$a1")', vaga '$(estado_vaga "$g1")', nova $nova" \
      "conversão 'ok', job 'ok', vencida 'expirada', no prazo 'encerrada', vaga 'encerrada', nova 1" \
      "conversão 'ok', job 'ok', vencida 'encerrada', no prazo 'encerrada', vaga 'encerrada', nova 1"
  done
done
fim_job 21 "a conversão feita e nenhuma chamada aberta" a b

# ── 22. Dois expirar_chamadas ao mesmo tempo (guarda) ──────────────────────────────
# Duas vagas G1 < G2, cada uma com uma chamada vencida. X segura G2; o 1º job (E) pega G1 e para em
# G2; o 2º (F) para em G1, atrás de E. Ao soltar X, E termina e F não acha mais nada. Mundos 371 a 380.
echo "▸ 22. dois expirar_chamadas ao mesmo tempo, em duas vagas, com a ordem forçada"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$((370 + i))
  montar_mundo "$m"
  p1=$(id "$m" 2); p2=$(id "$m" 3)
  g1=$(id "$m" 20); g2=$(id "$m" 21)
  vaga_direta "$m" 20 3; vaga_direta "$m" 21 3
  v1=$(chamada_direta "$m" "$g1" "$p1" prazo); v2=$(chamada_direta "$m" "$g2" "$p2" prazo)
  [ -n "$v1" ] && [ -n "$v2" ] || { falhou "rodada $i (22): não montei as chamadas"; erros=$((erros + 1)); continue; }
  n="cc-$RUN-$m"
  segurar "$n-x" "select 1 from public.vaga where id = '$g2' for update"
  parou=
  aguardar "$n-x" segurando || parou="x segurando"
  # As chamadas vencem com X já segurando G2 (#568): vencidas desde a montagem, o expirar_chamadas do
  # pg_cron podia expirá-las antes, e o 1º job não achava o que esperar. Agora o do cron só entra na fila.
  if [ -z "$parou" ]; then
    psql >/dev/null -c "update public.chamada set expira_em = now() - interval '1 minute' where id in ('$v1', '$v2');"
    cron_cai "$n"
  fi
  if [ -z "$parou" ]; then lado_nomeado "$n-e" "" "select privado.expirar_chamadas()"; aguardar "$n-e" travado || parou="e travado"; fi
  if [ -z "$parou" ]; then lado_nomeado "$n-f" "" "select privado.expirar_chamadas()"; aguardar "$n-f" travado || parou="f travado"; fi
  if [ -n "$parou" ]; then
    soltar "$n-%"; wait
    falhou "rodada $i (22): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
    erros=$((erros + 1)); continue
  fi
  soltar "$n-x"; wait
  re=$(resultado "$TMP/$n-e"); rf=$(resultado "$TMP/$n-f")
  impasse a "$re" "$rf"
  confere_job "1º job '$re', 2º job '$rf', chamadas '$(estado_chamada "$v1")'/'$(estado_chamada "$v2")', vagas '$(estado_vaga "$g1")'/'$(estado_vaga "$g2")'" \
    "1º job 'ok', 2º job 'ok', chamadas 'expirada'/'expirada', vagas 'encerrada'/'encerrada'"
done
fim_job 22 "as duas chamadas expiradas e as duas vagas encerradas" a

# ── 23. O job x quem pega só a chamada (guarda) ────────────────────────────────────
# cancelar_chamada (a casa), bloquear (o profissional bloqueia a casa) e a recusa travam a chamada e
# não pedem a vaga depois. X segura a chamada:
#   a. o outro lado chega primeiro (a chamada ainda no prazo, para a recusa passar da conferência do
#      prazo), a chamada vence pelo relógio de parede, e o job chega depois, já com a vaga;
#   b. a chamada vencida, o job primeiro (com a vaga), o outro lado depois.
# Mundos 381 a 440.
echo "▸ 23. job x cancelar_chamada, bloquear e a recusa, com X segurando a chamada (a: o outro primeiro; b: o job primeiro)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  for tipo in cancelar bloquear recusar; do
    for ordem in a b; do
      case "$tipo" in cancelar) base=380 ;; bloquear) base=400 ;; recusar) base=420 ;; esac
      case "$ordem" in a) m=$((base + i)) ;; b) m=$((base + 10 + i)) ;; esac
      montar_mundo "$m"
      casa=$(id "$m" 1); p1=$(id "$m" 2)
      g1=$(id "$m" 20); vaga_direta "$m" 20 3
      c1=$(chamada_direta "$m" "$g1" "$p1" prazo)
      [ -n "$c1" ] || { falhou "rodada $i (23 $tipo $ordem): não montei a chamada"; erros=$((erros + 1)); continue; }
      case "$tipo" in
        cancelar) CONTA_o=$casa; SQL_o="select public.cancelar_chamada('$c1')" ;;
        bloquear) CONTA_o=$p1;   SQL_o="select public.bloquear('estabelecimento', '$(id "$m" 10)')" ;;
        recusar)  CONTA_o=$p1;   SQL_o="select public.responder_chamada('$c1', 'recusar')" ;;
      esac
      n="cc-$RUN-$m"
      if [ "$ordem" = a ]; then
        psql >/dev/null -c "update public.chamada set expira_em = clock_timestamp() + interval '2 seconds' where id = '$c1';"
      else
        # X segura a chamada: ela tem de vencer antes, e o cron não pode cair entre o vencimento e X (#568).
        cron_cai "$n"; longe_do_cron
        vencer "$c1"
      fi
      segurar "$n-x" "select 1 from public.chamada where id = '$c1' for update"
      parou=
      aguardar "$n-x" segurando || parou="x segurando"
      if [ "$ordem" = a ]; then
        if [ -z "$parou" ]; then lado_nomeado "$n-o" "$CONTA_o" "$SQL_o"; aguardar "$n-o" travado || parou="o travado"; fi
        [ -z "$parou" ] && until [ "$(psql -c "select clock_timestamp() > expira_em from public.chamada where id = '$c1';")" = t ]; do sleep 0.2; done
        cron_cai "$n"
        if [ -z "$parou" ]; then lado_nomeado "$n-e" "" "select privado.expirar_chamadas()"; aguardar "$n-e" travado || parou="e travado"; fi
      else
        if [ -z "$parou" ]; then lado_nomeado "$n-e" "" "select privado.expirar_chamadas()"; aguardar "$n-e" travado || parou="e travado"; fi
        if [ -z "$parou" ]; then lado_nomeado "$n-o" "$CONTA_o" "$SQL_o"; aguardar "$n-o" travado || parou="o travado"; fi
      fi
      if [ -n "$parou" ]; then
        soltar "$n-%"; wait
        falhou "rodada $i (23 $tipo $ordem): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
        erros=$((erros + 1)); continue
      fi
      soltar "$n-x"; wait
      ro=$(resultado "$TMP/$n-o"); re=$(resultado "$TMP/$n-e")
      impasse "${tipo}_$ordem" "$ro" "$re"
      obtido="$tipo '$ro', job '$re', chamada '$(estado_chamada "$c1")', vaga '$(estado_vaga "$g1")'"
      case "$tipo$ordem" in
        cancelara) confere_job "$obtido" "cancelar 'ok', job 'ok', chamada 'cancelada', vaga 'publicada'" ;;
        bloqueara) confere_job "$obtido" "bloquear 'ok', job 'ok', chamada 'encerrada', vaga 'publicada'" ;;
        recusara)  confere_job "$obtido" "recusar 'ok', job 'ok', chamada 'recusada', vaga 'publicada'" ;;
        cancelarb) confere_job "$obtido" "cancelar 'chamada_indisponivel', job 'ok', chamada 'expirada', vaga 'encerrada'" ;;
        bloquearb) confere_job "$obtido" "bloquear 'ok', job 'ok', chamada 'expirada', vaga 'encerrada'" ;;
        recusarb)  confere_job "$obtido" "recusar 'chamada_indisponivel', job 'ok', chamada 'expirada', vaga 'encerrada'" ;;
      esac
    done
  done
done
fim_job 23 "o desfecho de quem chegou primeiro na chamada" cancelar_a cancelar_b bloquear_a bloquear_b recusar_a recusar_b

# ── 24. O job x a conversão x reabrir_por_atraso de uma irmã preenchida (guarda) ─────
# reabrir_por_atraso não pede a trava da casa e devolve a vaga preenchida a publicada (20261108070000:520).
# Com a trava da conversão só pelas irmãs publicadas, a preenchida ficava de fora: se ela fosse reaberta
# entre a trava e o update das irmãs, o update a pegaria fora de ordem, depois da origem. Duas irmãs
# G1 < G2: G1 preenchida (o p1 confirmado, sem check-in), G2 publicada, cada uma com uma chamada vencida
# (o job pede as duas vagas).
#   · X segura uma candidatura pendente de G2. A conversão de G2 (C) trava e para no gatilho
#     vaga_fechada_expira_candidaturas, que roda depois do encerramento da origem e antes do update das
#     irmãs: o meio exato, sem sorteio.
#   · R reabre G1; o job (E) chega depois; X solta.
# Se R terminasse antes de E, E pegaria G1 e esperaria G2 (de C), e C, no update, quereria G1: o ciclo.
# Medido: R não termina. Desde antes do conserto (no eb21daf), ele para na casa, porque o update de
# :520 confere a chave estrangeira vaga -> estabelecimento (FOR KEY SHARE), e a casa é de C até o fim;
# com o conserto, a G1 já é de C. Por isso o cenário é guarda: o caminho que fecharia o ciclo não se
# forma de forma determinística. A conferência só falha se R terminar antes de E ou se alguém receber 40P01.
# O reabrir conta a tolerância pelo horário da posição (v_pos.inicio_em, 15 min), não pelo da vaga: a
# montagem grava a posição de G1 com início 30 min atrás, e a vaga continua no futuro, do mesmo trabalho
# que G2. É o mesmo que a conversão durar além do início + 15 min. A candidatura pendente numa vaga
# direta também é montagem (candidatar recusa a direta). Mundos 441 a 450.

echo "▸ 24. job x publicar_a_partir_da_chamada x reabrir_por_atraso de uma irmã preenchida, no meio da conversão"
erros=0
for i in $(seq 1 "$RODADAS"); do
  m=$((440 + i))
  montar_mundo "$m"; mais_prof "$m" 4
  casa=$(id "$m" 1); p1=$(id "$m" 2); p2=$(id "$m" 3); p3=$(id "$m" 4)
  g1=$(id "$m" 20); g2=$(id "$m" 21)
  vaga_direta "$m" 20 3; vaga_direta "$m" 21 3
  pos1=$(psql <<SQL
update public.vaga set estado = 'preenchida' where id = '$g1';
update public.posicao set estado = 'confirmada', profissional_id = (select id from public.profissional where usuario_id = '$p1'),
       confirmado_em = now() - interval '1 hour', inicio_em = now() - interval '30 minutes', fim_em = now() + interval '5 hours'
 where vaga_id = '$g1' returning id;
SQL
)
  psql >/dev/null -c "insert into public.turno (posicao_id, valor_acordado_centavos) values ('$pos1', 15000);"
  cand=$(psql -c "insert into public.candidatura (posicao_id, profissional_id)
                  select x.id, (select id from public.profissional where usuario_id = '$p3') from public.posicao x where x.vaga_id = '$g2'
                  returning id;")
  v1=$(chamada_direta "$m" "$g1" "$p2" prazo); v2=$(chamada_direta "$m" "$g2" "$p1" prazo)
  [ -n "$pos1" ] && [ -n "$cand" ] && [ -n "$v1" ] && [ -n "$v2" ] || { falhou "rodada $i (24): não montei"; erros=$((erros + 1)); continue; }
  n="cc-$RUN-$m"
  # As chamadas vencem com X já segurando, antes da conversão (#568). X segura só a candidatura, e a
  # conversão trava as chamadas de G2 depois de começar: o vencimento não pode esperar por ela. O cron,
  # aqui, não ficaria na fila de nenhuma vaga, então o vencimento e o começo da conversão (menos de
  # 1 s) ficam longe do cron.
  cron_cai "$n"; longe_do_cron
  segurar "$n-x" "select 1 from public.candidatura where id = '$cand' for update"
  parou=
  aguardar "$n-x" segurando || parou="x segurando"
  [ -z "$parou" ] && psql >/dev/null -c "update public.chamada set expira_em = now() - interval '1 minute' where id in ('$v1', '$v2');"
  if [ -z "$parou" ]; then
    lado_nomeado "$n-c" "$casa" "select public.publicar_a_partir_da_chamada('$g2', gen_random_uuid(), 'urgencia')"
    aguardar "$n-c" travado || parou="c travado"
  fi
  if [ -z "$parou" ]; then
    lado_nomeado "$n-r" "$casa" "select public.reabrir_por_atraso('$pos1')"
    aguardar_fim_ou_trava "$n-r" "$TMP/$n-r" || parou="r terminou ou travado"
  fi
  r_antes=$onde
  if [ -z "$parou" ]; then
    lado_nomeado "$n-e" "" "select privado.expirar_chamadas()"
    aguardar "$n-e" travado || parou="e travado"
  fi
  if [ -n "$parou" ]; then
    soltar "$n-%"; wait
    falhou "rodada $i (24): '${parou% *}' não chegou a '${parou#* }' em 15 s (a ordem não foi forçada)"
    erros=$((erros + 1)); continue
  fi
  soltar "$n-x"; wait
  rc=$(resultado "$TMP/$n-c"); rr=$(resultado "$TMP/$n-r"); re=$(resultado "$TMP/$n-e")
  impasse a "$rc" "$rr" "$re"
  nova=$(psql -c "select count(*) from public.vaga where vaga_origem_id = '$g2' and estado = 'publicada';")
  confere_job "conversão '$rc', reabertura '$rr' ($r_antes antes do job), job '$re', G1 '$(estado_vaga "$g1")', G2 '$(estado_vaga "$g2")', nova $nova, chamadas '$(estado_chamada "$v1")'/'$(estado_chamada "$v2")'" \
    "conversão 'ok', reabertura 'ok' (travado antes do job), job 'ok', G1 'publicada', G2 'encerrada', nova 1, chamadas 'expirada'/'encerrada'"
done
fim_job 24 "a reabertura à espera da conversão, a conversão feita e G1 reaberta depois dela" a

exit "$falha"
