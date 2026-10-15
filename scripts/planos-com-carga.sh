#!/usr/bin/env bash
# Mede o PLANO das consultas quentes com o volume do Distrito Federal, e com o
# planejador livre.
#
# Por que existe. Em 28/09 `privado.elegiveis` varria `public.disponibilidade` inteira com
# o volume da praça-piloto — 185.732 linhas descartadas — e a suíte estava verde. Dois
# motivos, e os dois são frestas de medição:
#
#   1. `supabase/tests/carga/gerar_df.sql` só gera a massa com `-v carga=1`. Dentro de
#      `supabase test db` ele cai no ramo `\else` e executa um `pass()` dizendo que o
#      arquivo existe. A carga nunca rodava na CI.
#   2. `supabase/tests/310_consultas_quentes_df.sql` afere o plano com
#      `set local enable_seqscan = off`. Isso prova que o índice é utilizável; não prova
#      que o planejador o escolhe. Plano depende de estatística, e estatística depende de
#      volume.
#
# Este portão fecha as duas: gera a massa de verdade, e mede sem desligar nada.
#
# Não deixa resíduo. A carga roda dentro de uma transação que termina em `rollback`, o que
# foi medido: 130.018 usuários dentro, 18 depois. Sem `db reset`, e portanto sem apagar o
# `frila.agendador_secret` que a bateria seguinte precisa.
#
# Robustez de medição e jitter de virtualização (cartão p95/amostras):
# Com apenas 25 amostras e aquecimento tímido, p95 correspondia praticamente ao valor
# máximo amostral (amostra 24 de 25), tornando a medição suscetível a soluços de CPU e
# contenção de I/O em runners compartilhados da CI (onde vagas_abertas chegou a oscilar
# de 142 para 1.380 ms sem qualquer alteração de schema).
# Para eliminar falsos vermelhos mantendo a rede de proteção estrita contra regressões:
#   1. Aquecimento robusto prévio descartado (2 rodadas completas em elegiveis e 10
#      chamadas de vagas_abertas) para povoar buffers e cache do índice espacial;
#   2. Amostras ampliadas (50 chamadas de vagas_abertas e 36 de elegiveis por bateria);
#   3. Julgamento pelo melhor de 3 baterias consecutivas (mínimo de mediana e p95 entre
#      as 3 baterias), descartando anomalias e pausas transitórias de virtualização;
#   4. Garantias inalteradas: reprovação categórica se houver Seq Scan em tabelas grandes
#      ou se mediana/p95 excederem os tetos (os casos MUTAR do autoteste continuam reprovando).
#
# Uso:
#   ./scripts/planos-com-carga.sh              mede e reprova
#   ./scripts/planos-com-carga.sh --plano      imprime os planos inteiros
#   ./scripts/planos-com-carga.sh --julgar <f> avalia saída pré-gravada (para autoteste)
#   MUTAR=cte ./scripts/planos-com-carga.sh    prova que o portão reprova (ver abaixo)
#
# Saída:
#   0  mediu, e passou
#   1  mediu, e reprovou
#   2  NÃO mediu — pré-condição ausente. Nunca verde por omissão.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB="${DB_CONTAINER:-supabase_db_frila-backend}"
CARGA="supabase/tests/carga/gerar_df.sql"
MED_MAX_ELEGIVEIS="${MED_MAX_ELEGIVEIS:-50}"
P95_MAX_ELEGIVEIS="${P95_MAX_ELEGIVEIS:-100}"
MED_MAX_VAGAS="${MED_MAX_VAGAS:-100}"
P95_MAX_VAGAS="${P95_MAX_VAGAS:-300}"
MUTAR="${MUTAR:-}"
mostrar_plano=false
arquivo_julgar=""

while [ $# -gt 0 ]; do
  case "$1" in
    --plano) mostrar_plano=true; shift ;;
    --julgar)
      [ -n "${2:-}" ] || { printf '✗ NÃO MEDI: --julgar exige um arquivo\n' >&2; exit 2; }
      arquivo_julgar="$2"
      shift 2
      ;;
    *) shift ;;
  esac
done

# As tabelas em que uma varredura sequencial é inaceitável com o volume do DF. As pequenas
# de catálogo (funcao, equipe_confianca, bloqueio) ficam de fora de propósito: varrer 33
# funções é mais rápido que sondar um índice, e reprovar isso seria portão mentiroso.
GRANDES='usuario|profissional|profissional_funcao|disponibilidade|vaga|posicao|despacho|estabelecimento|membro_estabelecimento'

nao_medi() { printf '✗ NÃO MEDI: %s\n' "$1" >&2; exit 2; }
reprovou() { printf '✗ %s\n' "$1" >&2; }
numero() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

if [ -n "$arquivo_julgar" ]; then
  [ -f "$arquivo_julgar" ] || nao_medi "arquivo para julgar não existe: $arquivo_julgar"
  saida="$arquivo_julgar"
else
  # ── Pré-condições. Cada uma sai 2, não 0 ────────────────────────────────────────
  command -v docker >/dev/null 2>&1 || nao_medi "docker não está no PATH"
  [ -f "$CARGA" ] || nao_medi "$CARGA não existe"

  docker inspect -f '{{.State.Running}}' "$DB" 2>/dev/null | grep -q true \
    || nao_medi "o contêiner $DB não está de pé (supabase start)"

  psql_() { docker exec -e PGPASSWORD=postgres -i "$DB" psql -U postgres -d postgres -X -q "$@"; }

  psql_ -At -c 'select 1' >/dev/null 2>&1 || nao_medi "o Postgres em $DB não respondeu"

  # As contagens entram numa comparação numérica, então precisam ser dígitos. Sem esta
  # checagem, uma saída inesperada do psql faria `[ texto -gt 200 ]` errar e, como o script
  # roda sem `set -e` de propósito, o `if` seria tratado como falso e o portão seguiria como
  # se tivesse medido. É a armadilha do portão verde que não mediu, de novo.
  n_funcoes=$(psql_ -At -c 'select count(*) from public.funcao' 2>/dev/null)
  numero "$n_funcoes" || nao_medi "não consegui contar public.funcao (psql devolveu: '${n_funcoes:-vazio}')"
  [ "$n_funcoes" -gt 0 ] \
    || nao_medi "public.funcao está vazia: aplique o seed antes (supabase db reset)"

  n_usuarios=$(psql_ -At -c 'select count(*) from public.usuario' 2>/dev/null)
  numero "$n_usuarios" || nao_medi "não consegui contar public.usuario (psql devolveu: '${n_usuarios:-vazio}')"
  if [ "$n_usuarios" -gt 200 ]; then
    nao_medi "o banco já tem $n_usuarios usuários; a carga se recusa a rodar sobre base povoada. Rode supabase db reset primeiro (e regrave o frila.agendador_secret depois)."
  fi

  case "$MUTAR" in
    ''|cte|indice) : ;;
    *) nao_medi "MUTAR aceita 'cte' ou 'indice', recebi '$MUTAR'" ;;
  esac

  printf '▸ Medindo o plano com o volume do DF, planejador livre'
  [ -n "$MUTAR" ] && printf ' · MUTAÇÃO=%s' "$MUTAR"
  printf '\n'

# ── A mutação, para provar que o portão reprova ─────────────────────────────────
# `cte` desfaz a barreira de otimização de privado.elegiveis, reproduzindo a forma de
# 26/09. `indice` derruba disponibilidade_busca. As duas rodam dentro da transação que
# será desfeita, então não tocam o banco.
# `cte` desfaz a barreira de otimização de privado.elegiveis, reintroduzindo a forma
# achatada que vigorava até `20260929110000_rodada_de_despacho.sql` — a função literal
# daquela migração, e não uma versão simplificada, para o vermelho vir da forma e não de
# semântica alterada. É esta mutação que prova que o portão pega a regressão.
#
# `indice` derruba `disponibilidade_busca`. Medido em 29/09: o portão sai **0**, e isso é
# informação, não defeito. Depois da reescrita o planejador cai na chave única
# `(profissional_id, dia_semana, hora_inicio, hora_fim)`, que serve igual, e o caminho
# quente fica em p95 31,1 ms sem Seq Scan. Ou seja: o que protege este caminho é a ordem
# dos filtros, não um índice. Quem for remover `disponibilidade_busca` por outro motivo
# deve saber que este portão não vai reclamar.
mutacao_sql=""
[ "$MUTAR" = "indice" ] && mutacao_sql="drop index if exists public.disponibilidade_busca;"
if [ "$MUTAR" = "cte" ]; then
  # Reescreve a função para a forma achatada, dentro da transação.
  mutacao_sql=$(cat <<'MUT'
create or replace function privado.elegiveis(
  vaga_id       uuid,
  excluir_conta uuid default null
)
returns table (profissional_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $MUTX$
declare
  v           public.vaga%rowtype;
  v_demo      boolean;
  v_inicio_sp timestamp;
  v_dow       int;
  v_dow_ontem int;
begin
  select * into v from public.vaga g where g.id = elegiveis.vaga_id;
  if not found then
    return;
  end if;

  -- Só despacha vaga no estado 'publicada'
  if v.estado <> 'publicada' then
    return;
  end if;

  -- Isolamento de contas de demonstração (critério 6 do cartão):
  -- Vaga de conta de demonstração só notifica conta de demonstração,
  -- e vaga real só notifica conta real.
  select u.demonstracao into v_demo
    from public.usuario u
   where u.id = v.publicado_por;

  -- Horários no fuso America/Sao_Paulo (fuso canônico do DF para a grade semanal)
  v_inicio_sp := (v.inicio_em at time zone 'America/Sao_Paulo');
  v_dow       := extract(dow from v_inicio_sp)::int;
  v_dow_ontem := (v_dow + 6) % 7;

  return query
  select p.id
    from public.profissional p
    join public.usuario u on u.id = p.usuario_id and u.estado = 'ativa'
   where (v_demo is null or u.demonstracao = v_demo)
     -- Exclusão de conta (ex: quem cancelou na reabertura da posição)
     and (elegiveis.excluir_conta is null or p.usuario_id <> elegiveis.excluir_conta)
     -- 1. Função compatível (catálogo fechado)
     and exists (
       select 1 from public.profissional_funcao pf
        where pf.profissional_id = p.id and pf.funcao_id = v.funcao_id
     )
     -- 2. Até 15 km (usa índice GiST profissional_ponto), ou equipe de confiança (RF18)
     and (
       extensions.ST_DWithin(p.ponto_base, v.ponto, 15000)
       or exists (
         select 1 from public.equipe_confianca e
          where e.estabelecimento_id = v.estabelecimento_id
            and e.profissional_id = p.id
       )
     )
     -- 3. Grade cobrindo o horário integral, inclusive janela que atravessa a meia-noite
     and exists (
       select 1 from public.disponibilidade d
        where d.profissional_id = p.id
          and (
            -- Janela iniciada no mesmo dia da semana da vaga
            (
              d.dia_semana = v_dow
              and (
                -- Janela no mesmo dia (sem virar a noite)
                (d.hora_inicio < d.hora_fim
                 and tstzrange(
                       (date_trunc('day', v_inicio_sp) + d.hora_inicio) at time zone 'America/Sao_Paulo',
                       (date_trunc('day', v_inicio_sp) + d.hora_fim) at time zone 'America/Sao_Paulo'
                     ) @> tstzrange(v.inicio_em, v.fim_em))
                -- Janela que vira a noite iniciada no dia
                or (d.hora_inicio > d.hora_fim
                    and tstzrange(
                          (date_trunc('day', v_inicio_sp) + d.hora_inicio) at time zone 'America/Sao_Paulo',
                          (date_trunc('day', v_inicio_sp) + interval '1 day' + d.hora_fim) at time zone 'America/Sao_Paulo'
                        ) @> tstzrange(v.inicio_em, v.fim_em))
              )
            )
            -- Janela iniciada na véspera que vira a noite e cobre o turno na madrugada
            or (
              d.dia_semana = v_dow_ontem
              and d.hora_inicio > d.hora_fim
              and tstzrange(
                    (date_trunc('day', v_inicio_sp) - interval '1 day' + d.hora_inicio) at time zone 'America/Sao_Paulo',
                    (date_trunc('day', v_inicio_sp) + d.hora_fim) at time zone 'America/Sao_Paulo'
                  ) @> tstzrange(v.inicio_em, v.fim_em)
            )
          )
     )
     -- 4. Sem bloqueio mútuo com o estabelecimento (RF26)
     and not privado.bloqueado_com_estabelecimento(p.usuario_id, v.estabelecimento_id)
     -- 5. Sem turno sobreposto já confirmado (RN21)
     and not exists (
       select 1 from public.posicao x
        where x.profissional_id = p.id
          and x.estado in ('confirmada', 'cumprida')
          and x.vaga_id <> v.id
          and tstzrange(x.inicio_em, x.fim_em) && tstzrange(v.inicio_em, v.fim_em)
     )
     -- 6. Nesta vaga, nem quem faltou (RN12, em qualquer rodada) nem quem já trabalha nela
     and not exists (
       select 1 from public.posicao x
        where x.vaga_id = v.id
          and x.profissional_id = p.id
          and (x.falta or x.estado in ('confirmada', 'cumprida'))
     )
     -- 7. Um despacho por rodada (8zLfn0mt item 2): não despacha de novo nesta rodada
     and not exists (
       select 1 from public.despacho x
        where x.vaga_id = v.id and x.profissional_id = p.id
          and x.rodada = v.rodada_despacho
     );
     -- RN06: Sem ORDER BY por reputação, sem prioridade paga, nada patrocinado.
end $MUTX$;
MUT
)
fi

# ── O SQL: carga, mutação opcional, medição, rollback ───────────────────────────
saida=$(mktemp)
trap 'rm -f "$saida"' EXIT

{
  printf '%s\n' '\set ON_ERROR_STOP on' '\set carga 1' 'begin;'
  cat "$CARGA"
  [ -n "$mutacao_sql" ] && printf '%s\n' "$mutacao_sql"
  cat <<'SQL'
-- Uma vaga sintética do DF com elegíveis de verdade: um plano sobre conjunto vazio para
-- cedo e não mede o caminho que interessa.
select id as vaga_quente
  from public.vaga v
 where v.estado = 'publicada'
   and v.id >= 'c0000000-0000-0000-0000-000000000001'::uuid
   and (select count(*) from privado.elegiveis(v.id)) > 20
 order by v.id
 limit 1 \gset

select coalesce(:'vaga_quente', '') as tem_vaga \gset
\if :{?vaga_quente}
\else
  \echo 'SEM_VAGA_QUENTE'
\endif

\echo '--- PLANO elegiveis ---'
explain (analyze, costs off, timing off, summary off)
  select * from privado.elegiveis(:'vaga_quente');

set auto_explain.log_min_duration = 0;
set auto_explain.log_nested_statements = on;
set auto_explain.log_analyze = on;
set client_min_messages = log;
select count(*) from privado.elegiveis(:'vaga_quente');
reset client_min_messages;
reset auto_explain.log_min_duration;

\echo '--- PLANO vagas_abertas por data ---'
explain (analyze, costs off, timing off, summary off)
  select * from public.vaga v
   where v.estado = 'publicada'
     and (v.inicio_em at time zone 'America/Sao_Paulo')::date
         = (select (min(inicio_em) at time zone 'America/Sao_Paulo')::date
              from public.vaga where estado = 'publicada')
   order by v.ponto operator(extensions.<->)
            extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8850, -15.7900), 4326)::extensions.geography
   limit 30;

\echo '--- TEMPOS ---'
do $MED$
declare
  vs uuid[]; v uuid; t0 timestamptz;
  a double precision[]; b double precision[];
  n int; r jsonb;
  prof uuid := (select id from public.usuario where perfil = 'profissional'
                 and id < 'c0000000-0000-0000-0000-000000000000'::uuid order by id limit 1);
  p95_e numeric; med_e numeric;
  p95_v numeric; p90_v numeric; med_v numeric;
  best_p95_e numeric; best_med_e numeric;
  best_p95_v numeric; best_p90_v numeric; best_med_v numeric;
begin
  select array_agg(id order by id) into vs from (
    select id from public.vaga where estado = 'publicada'
       and id >= 'c0000000-0000-0000-0000-000000000001'::uuid order by id limit 12) s;

  -- 1. Aquecimento robusto descartado de privado.elegiveis (2 rodadas completas sobre a amostra)
  for i in 1..2 loop
    foreach v in array vs loop
      select count(*) into n from privado.elegiveis(v);
    end loop;
  end loop;

  -- 2. Medição de privado.elegiveis: melhor de 3 baterias (36 amostras por bateria = 108 total)
  for rodada in 1..3 loop
    a := '{}';
    for i in 1..3 loop
      foreach v in array vs loop
        t0 := clock_timestamp();
        select count(*) into n from privado.elegiveis(v);
        a := a || (extract(epoch from (clock_timestamp() - t0)) * 1000);
      end loop;
    end loop;

    p95_e := round((select percentile_cont(0.95) within group (order by x) from unnest(a) x)::numeric, 1);
    med_e := round((select percentile_cont(0.50) within group (order by x) from unnest(a) x)::numeric, 1);

    if best_p95_e is null or p95_e < best_p95_e then
      best_p95_e := p95_e;
    end if;
    if best_med_e is null or med_e < best_med_e then
      best_med_e := med_e;
    end if;
  end loop;

  perform set_config('request.jwt.claims',
    json_build_object('sub', prof, 'role', 'authenticated')::text, true);

  -- 3. Aquecimento robusto descartado de vagas_abertas (10 chamadas para aquecer buffers e índice espacial)
  for i in 1..10 loop
    select public.vagas_abertas(-15.7900, -47.8850, null, null, null, 30, 0) into r;
  end loop;

  -- 4. Medição de vagas_abertas: melhor de 3 baterias (50 amostras por bateria = 150 total)
  for rodada in 1..3 loop
    b := '{}';
    for i in 1..50 loop
      t0 := clock_timestamp();
      select public.vagas_abertas(-15.7900, -47.8850, null, null, null, 30, 0) into r;
      b := b || (extract(epoch from (clock_timestamp() - t0)) * 1000);
    end loop;

    p95_v := round((select percentile_cont(0.95) within group (order by x) from unnest(b) x)::numeric, 1);
    p90_v := round((select percentile_cont(0.90) within group (order by x) from unnest(b) x)::numeric, 1);
    med_v := round((select percentile_cont(0.50) within group (order by x) from unnest(b) x)::numeric, 1);

    if best_p95_v is null or p95_v < best_p95_v then
      best_p95_v := p95_v;
    end if;
    if best_p90_v is null or p90_v < best_p90_v then
      best_p90_v := p90_v;
    end if;
    if best_med_v is null or med_v < best_med_v then
      best_med_v := med_v;
    end if;
  end loop;

  raise notice 'P95_ELEGIVEIS=%', best_p95_e;
  raise notice 'MEDIANA_ELEGIVEIS=%', best_med_e;
  raise notice 'P95_VAGAS_ABERTAS=%', best_p95_v;
  raise notice 'P90_VAGAS_ABERTAS=%', best_p90_v;
  raise notice 'MEDIANA_VAGAS_ABERTAS=%', best_med_v;
end $MED$;

\echo '--- VOLUME ---'
select 'VOL usuario='||(select count(*) from public.usuario)
    ||' profissional='||(select count(*) from public.profissional)
    ||' vaga='||(select count(*) from public.vaga)
    ||' disponibilidade='||(select count(*) from public.disponibilidade);
SQL
  printf '%s\n' 'rollback;'
} | psql_ -f - > "$saida" 2>&1
fi

if grep -q "^ERROR" "$saida" || grep -q "SEM_VAGA_QUENTE" "$saida"; then
  sed -n '1,25p' "$saida" >&2
  nao_medi "a carga ou a medição não completou (veja acima)"
fi

$mostrar_plano && cat "$saida"

# ── O veredito ──────────────────────────────────────────────────────────────────
falhou=0

grep -o "VOL .*" "$saida" | head -1 | sed 's/^/  /'

# Um `Seq Scan` só é notícia quando ele toca linhas. Varrer uma tabela vazia — `despacho`
# antes da primeira rodada, por exemplo — é o plano certo e custa zero, e reprovar isso
# faria o portão gritar por motivo que não é regressão. O que conta é quanto foi lido:
# linhas devolvidas mais linhas descartadas pelo filtro, acima de LINHAS_MIN.
LINHAS_MIN="${LINHAS_MIN:-1000}"
seq_scans=$(awk -v lista="$GRANDES" -v lim="$LINHAS_MIN" '
  BEGIN { n = split(lista, v, "|"); for (i = 1; i <= n; i++) grande[v[i]] = 1 }
  function emitir(   _) {
    if (tabela != "" && lidas >= lim) printf "%s (%d linhas lidas)\n", tabela, lidas
    tabela = ""; lidas = 0
  }
  /Seq Scan on/ {
    emitir()
    t = $0
    sub(/.*Seq Scan on +/, "", t)
    sub(/[^A-Za-z0-9_].*/, "", t)          # o nome da tabela, sem o alias nem o resto
    if (t in grande) {
      tabela = t
      if (match($0, /rows=[0-9]+/)) { r = substr($0, RSTART + 5, RLENGTH - 5) + 0; lidas += r }
    }
    next
  }
  /Rows Removed by Filter:/ {
    if (tabela != "") {
      r = $0; sub(/.*Rows Removed by Filter: /, "", r); sub(/[^0-9].*/, "", r); lidas += r + 0
    }
    next
  }
  END { emitir() }' "$saida" | sort -u | sed 's/^/    /')
if [ -n "$seq_scans" ]; then
  reprovou "varredura sequencial em tabela grande do caminho quente:"
  printf '%s\n' "$seq_scans" | sed 's/^/  /' >&2
  printf '  O plano inteiro sai com --plano.\n' >&2
  falhou=1
else
  printf '  nenhuma varredura sequencial acima de %s linhas nas tabelas do caminho quente\n' "$LINHAS_MIN"
fi

le() { # le <valor> <teto> -> 0 se valor <= teto
  awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<=b)}'
}

p95e=$(grep -o 'P95_ELEGIVEIS=[0-9.]*' "$saida" | head -1 | cut -d= -f2)
mede=$(grep -o 'MEDIANA_ELEGIVEIS=[0-9.]*' "$saida" | head -1 | cut -d= -f2)
p95v=$(grep -o 'P95_VAGAS_ABERTAS=[0-9.]*' "$saida" | head -1 | cut -d= -f2)
p90v=$(grep -o 'P90_VAGAS_ABERTAS=[0-9.]*' "$saida" | head -1 | cut -d= -f2)
medv=$(grep -o 'MEDIANA_VAGAS_ABERTAS=[0-9.]*' "$saida" | head -1 | cut -d= -f2)

[ -n "$p95e" ] && [ -n "$mede" ] && [ -n "$p95v" ] && [ -n "$medv" ] || nao_medi "não achei os tempos na saída da medição"

printf '  privado.elegiveis: mediana %s ms (teto %s ms) · p95 %s ms (teto %s ms)\n' "$mede" "$MED_MAX_ELEGIVEIS" "$p95e" "$P95_MAX_ELEGIVEIS"
if [ -n "$p90v" ]; then
  printf '  vagas_abertas:     mediana %s ms (teto %s ms) · p90 %s ms · p95 %s ms (teto %s ms)\n' "$medv" "$MED_MAX_VAGAS" "$p90v" "$p95v" "$P95_MAX_VAGAS"
else
  printf '  vagas_abertas:     mediana %s ms (teto %s ms) · p95 %s ms (teto %s ms)\n' "$medv" "$MED_MAX_VAGAS" "$p95v" "$P95_MAX_VAGAS"
fi

le "$mede" "$MED_MAX_ELEGIVEIS" || { reprovou "mediana de privado.elegiveis em $mede ms, acima do teto de $MED_MAX_ELEGIVEIS ms"; falhou=1; }
le "$p95e" "$P95_MAX_ELEGIVEIS" || { reprovou "p95 de privado.elegiveis em $p95e ms, acima do teto de $P95_MAX_ELEGIVEIS ms"; falhou=1; }
le "$medv" "$MED_MAX_VAGAS"     || { reprovou "mediana de vagas_abertas em $medv ms, acima do teto de $MED_MAX_VAGAS ms";     falhou=1; }
le "$p95v" "$P95_MAX_VAGAS"     || { reprovou "p95 de vagas_abertas em $p95v ms, acima do teto de $P95_MAX_VAGAS ms";         falhou=1; }

if [ "$falhou" -ne 0 ]; then
  printf '\n✗ O caminho quente regrediu com o volume do DF.\n' >&2
  exit 1
fi

printf '\n✓ Caminho quente medido com o volume do DF: nenhum Seq Scan em tabela grande, e medianas/p95 dentro do teto.\n'
