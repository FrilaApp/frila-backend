#!/usr/bin/env bash
# Corrida da escala de evento (publicar_escala, contrato 0.2.96; B-031). O pgTAP roda numa sessão só e
# não enxerga dois envios abertos ao mesmo tempo. Aqui cada lado é uma conexão de verdade, que chama a
# RPC como `authenticated` com a MESMA chave e segura a transação um pouco depois da chamada, para a
# outra conexão chegar enquanto a primeira ainda não confirmou. Quem chega primeiro alterna entre as
# rodadas, para os dois ordenamentos acontecerem.
#
# Esperado em cada rodada: os dois envios respondem com o mesmo evento_id, e o banco tem UMA escala com
# aquela chave (um evento, as três vagas dos itens e as seis posições). Sem a unique
# (estabelecimento_id, chave) do evento, os dois gravam; sem a captura do unique_violation, o segundo
# recebe 23505. Nos dois casos a corrida sai vermelha.
#
# A fila de despacho não é contada aqui: o agendador do pg_cron pode consumir a mensagem entre o commit
# e a leitura. Uma mensagem por vaga é do pgTAP (supabase/tests/876_publicar_escala.sql).
#
# Uso: ./scripts/corrida-escala.sh        RODADAS=4 ./scripts/corrida-escala.sh
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

# id <entidade>: UUID sintético desta execução.
id() { printf '%08x-0000-4000-8000-%012d' $(( 0xe5ca0000 + RUN )) "$1"; }
CASA=$(id 1)     # a conta da casa
ESTAB=$(id 10)   # o estabelecimento

# Apaga o que esta execução criou, por id. A suíte e a mutação rodam depois no mesmo banco, e o motor
# de despacho pode ter avisado alguém das vagas daqui.
limpar() {
  psql >/dev/null <<SQL || echo "  aviso: a limpeza falhou; sobraram dados da marca $RUN" >&2
set session_replication_role = 'replica';
create temp table vagas as select id from public.vaga where estabelecimento_id = '$ESTAB';
create temp table posicoes as select id from public.posicao where vaga_id in (select id from vagas);
delete from public.notificacao
 where referencia_id in (select id from vagas union all select id from posicoes);
do \$\$
begin
  if to_regclass('privado.marca_notificacao') is not null then
    delete from privado.marca_notificacao
     where referencia_id in (select id from vagas union all select id from posicoes);
  end if;
end \$\$;
delete from pgmq.q_despacho where (message->>'vaga_id')::uuid in (select id from vagas);
delete from public.despacho where vaga_id in (select id from vagas);
delete from public.candidatura where posicao_id in (select id from posicoes);
delete from public.posicao where id in (select id from posicoes);
delete from public.vaga where id in (select id from vagas);
delete from public.evento where estabelecimento_id = '$ESTAB';
delete from public.membro_estabelecimento where estabelecimento_id = '$ESTAB';
delete from public.estabelecimento where id = '$ESTAB';
delete from public.usuario where id = '$CASA';
delete from auth.users where id = '$CASA';
set session_replication_role = 'origin';
SQL
  rm -rf "$TMP"
}
trap limpar EXIT

# A casa, sozinha no estabelecimento. Dado sintético.
psql >/dev/null <<SQL
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', '$CASA', 'authenticated', 'authenticated',
        'corrida-escala-$RUN@frila.test', now(), now(), false, false);
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('$CASA', 'contratante', 'Casa Corrida Escala', '+556190$(printf '%03d' "$RUN")0001',
        'corrida-escala-$RUN@frila.test', '1980-01-01', '2026-11-13', now());
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('$ESTAB', 'Casa Corrida Escala $RUN', '5$(printf '%03d' "$RUN")0000001', 'evento', 'SHN Quadra 5',
        'POINT(-47.8890 -15.7840)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('$CASA', '$ESTAB', 'administrador');
SQL

# A chamada de publicar_escala da rodada: três vagas (garçom, bartender e copeiro, duas posições cada),
# daqui a três dias, sempre com a chave dada.
sql_escala() {
  cat <<SQL
select public.publicar_escala(estabelecimento_id => '$ESTAB'::uuid,
  evento => jsonb_build_object('nome', 'Formatura da corrida', 'data', (now() + interval '3 days')::date,
    'local', 'SHN Quadra 5, Salão Nobre', 'regiao_administrativa', 'Plano Piloto',
    'ponto', jsonb_build_object('latitude', -15.7840, 'longitude', -47.8890)),
  vagas => (select jsonb_agg(jsonb_build_object(
      'funcao_id', (select f.id from public.funcao f where f.nome = n),
      'inicio_em', date_trunc('hour', now()) + interval '3 days',
      'fim_em', date_trunc('hour', now()) + interval '3 days 6 hours',
      'valor_centavos', 18000, 'posicoes', 2, 'inclui_refeicao', true, 'inclui_transporte', false,
      'exige_material_proprio', false, 'responsavel_local', 'Cerimonial', 'modo', 'urgencia') order by o)
    from unnest(array['garçom', 'bartender', 'copeiro']) with ordinality as t(n, o)),
  chave => '$1'::uuid)
SQL
}

# Função auxiliar de cada conexão: chama como a casa e devolve 'ok <evento_id>' ou o code do erro.
AUX=$(cat <<SQL
create function pg_temp.tentar(q text) returns text language plpgsql as \$f\$
declare r jsonb; m text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', '$CASA', 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute q into r;
  execute 'reset role';
  return 'ok ' || (r->>'evento_id');
exception when others then
  get stacked diagnostics m = message_text;
  return case when m ~ '^\s*\{' then coalesce(m::jsonb->>'code', 'sem_code') else 'sqlstate:' || sqlstate end;
end \$f\$;
SQL
)

# lado <arquivo> <atraso_inicial> <chave>: uma conexão em segundo plano, que segura a transação 1 s.
lado() {
  local saida=$1 atraso=$2 chave=$3
  (
    sleep "$atraso"
    psql <<SQL > "$saida" 2>&1
$AUX
-- O despacho pós-commit (privado.disparar_despacho) exige o segredo do agendador. Na CI ele já vem do
-- banco; na máquina, a sessão usa um de mentira, só se não houver outro.
select set_config('frila.agendador_secret', 'segredo-da-corrida', false)
 where nullif(current_setting('frila.agendador_secret', true), '') is null;
begin;
select pg_temp.tentar(\$q\$ $(sql_escala "$chave") \$q\$);
select pg_sleep(1);
commit;
SQL
  ) &
}

resultado() { grep -E '^(ok [0-9a-f-]{36}|[a-z_]+|sqlstate:.*)$' "$1" | head -1; }

echo "▸ Corrida da escala: dois envios simultâneos com a mesma chave, $RODADAS rodadas (marca $RUN)"
erros=0
for i in $(seq 1 "$RODADAS"); do
  chave=$(id $((100 + i)))
  a=0; b=0.2; [ $((i % 2)) = 0 ] && { a=0.2; b=0; }
  lado "$TMP/$i-a" "$a" "$chave"
  lado "$TMP/$i-b" "$b" "$chave"
  wait
  ra=$(resultado "$TMP/$i-a"); rb=$(resultado "$TMP/$i-b")
  eventos=$(psql -c "select count(*) from public.evento where estabelecimento_id = '$ESTAB' and chave = '$chave';")
  vagas=$(psql -c "select count(*) from public.vaga v join public.evento e on e.id = v.evento_id
                    where e.estabelecimento_id = '$ESTAB' and e.chave = '$chave';")
  posicoes=$(psql -c "select count(*) from public.posicao p join public.vaga v on v.id = p.vaga_id
                       join public.evento e on e.id = v.evento_id
                      where e.estabelecimento_id = '$ESTAB' and e.chave = '$chave';")
  if [ "${ra%% *}" = ok ] && [ "$ra" = "$rb" ] && [ "$eventos" = 1 ] && [ "$vagas" = 3 ] && [ "$posicoes" = 6 ]; then :
  else
    falhou "rodada $i: respostas '$ra' / '$rb', eventos $eventos, vagas $vagas, posições $posicoes"
    erros=$((erros + 1))
    sed 's/^/      /' "$TMP/$i-a" "$TMP/$i-b" >&2
  fi
done
[ "$erros" = 0 ] && ok "em $RODADAS de $RODADAS rodadas, os dois envios devolvem a mesma escala, e o banco tem uma só"

exit "$falha"
