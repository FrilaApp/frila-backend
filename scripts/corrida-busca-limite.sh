#!/usr/bin/env bash
# Corrida do limite de 60 buscas por hora de buscar_profissionais (CD-B08, B-027).
#
# O pgTAP roda numa sessão só e não vê duas buscas ao mesmo tempo. Aqui cada busca é uma conexão de
# verdade, como `authenticated`, e todas largam juntas (um relógio comum, o `T`). A transação de cada
# conexão fica aberta 0,3 s depois da chamada, então a segunda busca da mesma conta chega ao contador
# quando a primeira ainda não confirmou: é a trava da linha do contador (o upsert) que as enfileira.
#
# Cenários (cada rodada numa conta nova de contratante, com o contador da hora já em N):
#   1. 58 gastas · 4 conexões   → exatamente 2 passam e 2 levam 429; o contador termina em 60
#   2. 59 gastas · 2 conexões   → exatamente 1 passa e 1 leva 429; o contador termina em 60
#   3. 50 gastas · 16 conexões  → exatamente 10 passam e 6 levam 429; o contador termina em 60
#   4.  0 gastas · 8 conexões   → as 8 passam; o contador termina em 8 (nenhum +1 se perde)
#
# Em toda rodada: nenhuma resposta fora de ok/limite_excedido (deadlock 40P01 reprova pelo nome), o contador
# nunca passa de 60 e a conta nunca recebe mais de 60 buscas na hora.
#
# Prova de vermelho: `MUTANTE=1 ./scripts/corrida-busca-limite.sh` troca, só no banco local, o upsert por
# "select, soma e insert" (a forma ingênua que perde incremento), roda os mesmos cenários e SÓ passa se
# eles falharem; no fim devolve a função original (guardada antes). A cópia do mutante fica na pasta
# temporária da execução e é apagada ao sair.
#
# Uso: ./scripts/corrida-busca-limite.sh       (10 rodadas por cenário)
#      RODADAS=20 ./scripts/corrida-busca-limite.sh
#      MUTANTE=1 RODADAS=3 ./scripts/corrida-busca-limite.sh
# O banco local é compartilhado: rode pela fila (orquestracao/scripts/fila.sh rodar banco <dono> -- ...).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB=${DB_CONTAINER:-supabase_db_frila-backend}
RODADAS=${RODADAS:-10}
MUTANTE=${MUTANTE:-0}
psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

if [ "$RODADAS" -lt 1 ] || [ "$RODADAS" -gt 99 ]; then
  echo "RODADAS vai de 1 a 99" >&2; exit 1
fi

TMP=$(mktemp -d)
falha=0
RUN=$(( (RANDOM % 900) + 100 ))   # marca desta execução: reexecutar não colide com a anterior
FUNCAO='public.buscar_profissionais(uuid, uuid, int, timestamptz, timestamptz, text, int)'
RECURSOS_ANTES=""
FUNCAO_TROCADA=0

# id <tipo> <n>: UUID sintético desta execução.  1 contratante (n = cenário*100 + rodada) · 2 conta do
# profissional · 3 perfil do profissional · 4 casa
id() { printf '%08x-0000-4000-8000-%012d' $(( 0xe0f00000 + RUN * 1000 + $1 )) "$2"; }

# shellcheck disable=SC2329 # chamada pelo trap EXIT
limpar() {
  # 1) devolve a função original, se o mutante a trocou
  if [ "$FUNCAO_TROCADA" = 1 ] && [ -s "$TMP/original.sql" ]; then
    psql < "$TMP/original.sql" >/dev/null && echo "  (função original devolvida)" \
      || echo "  AVISO: não consegui devolver a função original; rode supabase db reset" >&2
  fi
  # 2) devolve os recursos como estavam
  if [ -n "$RECURSOS_ANTES" ]; then
    psql >/dev/null <<SQL || echo "  aviso: não devolvi os recursos ao estado anterior ($RECURSOS_ANTES)" >&2
update privado.recurso r set ligado = (v.ligado = 'true')
  from (values ${RECURSOS_ANTES}) v(chave, ligado) where r.chave = v.chave;
SQL
  fi
  # 3) apaga o que a corrida criou
  psql >/dev/null <<SQL || echo "  aviso: a limpeza falhou; sobraram dados da marca $RUN" >&2
set session_replication_role = 'replica';
create temp table contas as
  select id from public.usuario
   where id::text like '$(printf '%08x' $(( 0xe0f00000 + RUN * 1000 + 1 )))-0000-4000-8000-%'
      or id = '$(id 2 0)';
delete from privado.contador_busca where usuario_id in (select id from contas);
delete from public.dispositivo where usuario_id in (select id from contas);
delete from public.membro_estabelecimento where usuario_id in (select id from contas) or estabelecimento_id = '$(id 4 0)';
delete from public.profissional_preferencia_chamada where profissional_id = '$(id 3 0)';
delete from public.profissional_servico where profissional_id = '$(id 3 0)';
delete from public.profissional_funcao where profissional_id = '$(id 3 0)';
delete from public.profissional where id = '$(id 3 0)';
delete from public.estabelecimento where id = '$(id 4 0)';
delete from public.usuario where id in (select id from contas);
set session_replication_role = 'origin';
SQL
  rm -rf "$TMP"
}
trap limpar EXIT

# ── Preparação ───────────────────────────────────────────────────────────────
# A busca só roda com busca_profissionais e chamada_direta ligadas; liga e devolve ao sair.
RECURSOS_ANTES=$(psql -c "select string_agg(format('(%L, %L)', chave, ligado), ', ') from privado.recurso
                          where chave in ('busca_profissionais', 'chamada_direta');")
if [ -z "$RECURSOS_ANTES" ]; then
  echo "A chave busca_profissionais não existe: a migração da busca não está aplicada (supabase db reset)." >&2
  RECURSOS_ANTES=""; exit 1
fi
psql >/dev/null <<SQL
update privado.recurso set ligado = true where chave in ('busca_profissionais', 'chamada_direta');
SQL

if [ "$MUTANTE" = 1 ]; then
  psql -c "select pg_get_functiondef('$FUNCAO'::regprocedure);" > "$TMP/original.sql"
  echo ";" >> "$TMP/original.sql"
  # O upsert vira "lê, soma, grava": o que se perde quando duas buscas leem o mesmo valor. O pg_sleep alarga
  # a janela (sem ele a corrida do mutante é rara demais para a prova de vermelho ser repetível).
  perl -0pe 's/insert into privado\.contador_busca as cb.*?returning cb\.total into v_total;/select cb.total into v_total from privado.contador_busca cb where cb.usuario_id = v_uid and cb.hora = date_trunc(\x27hour\x27, v_agora);\n    v_total := coalesce(v_total, 0) + 1;\n    perform pg_sleep(0.05);\n    insert into privado.contador_busca as cb (usuario_id, hora, total) values (v_uid, date_trunc(\x27hour\x27, v_agora), v_total)\n      on conflict on constraint contador_busca_pkey do update set total = excluded.total;/s' \
    "$TMP/original.sql" > "$TMP/mutante.sql"
  if cmp -s "$TMP/original.sql" "$TMP/mutante.sql"; then
    echo "O upsert do contador não foi encontrado na função: ajuste o padrão do mutante." >&2; exit 1
  fi
  psql < "$TMP/mutante.sql" >/dev/null || { echo "Não consegui aplicar o mutante." >&2; exit 1; }
  FUNCAO_TROCADA=1
  echo "▸ MUTANTE: o upsert do contador foi trocado por select + soma + insert (só neste banco local, devolvido ao sair)"
fi

# O mundo comum: uma casa e um profissional que a busca devolve (a busca devolve cartão de verdade).
psql >/dev/null <<SQL
begin;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('$(id 2 0)', 'profissional', 'Pro Corrida Busca', '+55619$(printf '%03d%05d' "$RUN" 1)00', 'corrida-busca-$RUN-pro@frila.test',
        '1990-01-01', '1.0', now());
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('$(id 4 0)', 'Casa Corrida Busca', '8$(printf '%03d%010d' "$RUN" 1)', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.profissional (id, usuario_id, ponto_base, atende_todo_df)
values ('$(id 3 0)', '$(id 2 0)', 'POINT(-47.8822 -15.7800)'::extensions.geography, true);
insert into public.profissional_funcao (profissional_id, funcao_id)
values ('$(id 3 0)', (select id from public.funcao where nome = 'garçom'));
insert into public.profissional_servico (profissional_id, funcao_id, unidade, valor_centavos)
values ('$(id 3 0)', (select id from public.funcao where nome = 'garçom'), 'hora', 4000);
insert into public.profissional_preferencia_chamada (profissional_id, aceita_chamadas, aceita_chamadas_em, versao_texto_busca)
values ('$(id 3 0)', true, now(), 'v1');
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
values ('$(id 2 0)', 'tok-corrida-busca-$RUN-0000000000', 'ios', '99.0.0');
commit;
SQL

# Cada conexão: espera o T (relógio comum), faz a busca como a conta e segura a transação aberta 0,3 s antes
# de confirmar. Imprime 'ok' ou o code do erro (sqlstate:<código> se não vier code).
AUX=$(cat <<'SQL'
create function pg_temp.tentar(conta uuid, q text) returns text language plpgsql as $f$
declare m text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  execute q;
  execute 'reset role';
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text;
  return case when m ~ '^\s*\{' then coalesce(m::jsonb->>'code', 'sem_code') else 'sqlstate:' || sqlstate end;
end $f$;
SQL
)

# busca <saida> <conta> <T>
busca() {
  local saida=$1 conta=$2 t=$3
  psql > "$saida" 2>&1 <<SQL &
$AUX
select pg_sleep(greatest(0, extract(epoch from ('$t'::timestamptz - clock_timestamp()))));
begin;
select pg_temp.tentar('$conta', \$q\$ select public.buscar_profissionais(
  estabelecimento_id => '$(id 4 0)', funcao_id => (select id from public.funcao where nome = 'garçom')) \$q\$);
select pg_sleep(0.3);
commit;
SQL
}

# cenario <n> <rótulo> <já gastas> <conexões>
cenario() {
  local n=$1 rotulo=$2 gastas=$3 conexoes=$4
  local esperado_ok=$(( 60 - gastas )) esperado_total
  [ "$esperado_ok" -gt "$conexoes" ] && esperado_ok=$conexoes
  esperado_total=$(( gastas + esperado_ok ))
  local esperado_429=$(( conexoes - esperado_ok ))
  local i c conta t n_ok n_429 outras total erros=0 f
  echo "▸ $n. $rotulo"
  for i in $(seq 1 "$RODADAS"); do
    c=$(( n * 100 + i )); conta=$(id 1 "$c")
    # Não semeia no último segundo da hora: o contador mudaria de linha no meio da rodada.
    psql >/dev/null -c "select case when extract(minute from now()) = 59 and extract(second from now()) > 50 then pg_sleep(12) end;"
    psql >/dev/null <<SQL || { falhou "rodada $i: não montei a conta"; erros=$((erros + 1)); continue; }
begin;
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('$conta', 'contratante', 'Contratante Corrida', '+55619$(printf '%03d%02d%03d' "$RUN" "$n" "$i")', 'corrida-busca-$RUN-$c@frila.test',
        '1985-01-01', '2026-11-13', now());
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values ('$conta', '$(id 4 0)', 'administrador');
insert into privado.contador_busca (usuario_id, hora, total)
select '$conta', date_trunc('hour', now()), $gastas where $gastas > 0;
commit;
SQL
    t=$(psql -c "select to_char(clock_timestamp() + interval '2 seconds', 'YYYY-MM-DD HH24:MI:SS.US TZH');")
    for f in $(seq 1 "$conexoes"); do busca "$TMP/$c-$f" "$conta" "$t"; done
    wait
    n_ok=0; n_429=0; outras=""
    for f in $(seq 1 "$conexoes"); do
      r=$(grep -E '^(ok|[a-z_0-9]+|sqlstate:.*)$' "$TMP/$c-$f" | head -1)
      case "$r" in
        ok) n_ok=$((n_ok + 1)) ;;
        limite_excedido) n_429=$((n_429 + 1)) ;;
        *) outras="$outras '${r:-sem resposta: $(head -c 200 "$TMP/$c-$f")}'" ;;
      esac
    done
    total=$(psql -c "select coalesce(sum(total), 0) from privado.contador_busca where usuario_id = '$conta';")
    if [ -n "$outras" ] || [ "$n_ok" != "$esperado_ok" ] || [ "$n_429" != "$esperado_429" ] \
       || [ "$total" != "$esperado_total" ] || [ "$total" -gt 60 ]; then
      falhou "rodada $i: passaram $n_ok (esperado $esperado_ok), 429 em $n_429 (esperado $esperado_429), contador $total (esperado $esperado_total)${outras:+, outras respostas:$outras}"
      erros=$((erros + 1))
    fi
  done
  [ "$erros" = 0 ] && ok "em $RODADAS de $RODADAS rodadas: passaram $esperado_ok, $esperado_429 levaram 429 e o contador terminou em $esperado_total"
}

echo "▸ Corrida do limite de 60 buscas por hora: $RODADAS rodadas por cenário (marca $RUN)"
inicio=$SECONDS

cenario 1 "58 gastas, 4 conexões ao mesmo tempo (a 59ª, a 60ª e duas 61ªs)" 58 4
cenario 2 "59 gastas, 2 conexões ao mesmo tempo (a 60ª e a 61ª)" 59 2
cenario 3 "50 gastas, 16 conexões ao mesmo tempo" 50 16
cenario 4 "0 gastas, 8 conexões ao mesmo tempo (nenhum +1 se perde)" 0 8

echo "▸ tempo: $(( SECONDS - inicio )) s"
if [ "$MUTANTE" = 1 ]; then
  if [ "$falha" = 1 ]; then
    echo "▸ VERMELHO CONFIRMADO: com o upsert trocado por select + insert, a corrida reprova (era o esperado)."
    exit 0
  fi
  echo "▸ O mutante NÃO foi pego: a corrida passou com o upsert trocado, então ela não prova a trava." >&2
  exit 1
fi
exit "$falha"
