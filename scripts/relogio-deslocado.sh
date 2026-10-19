#!/usr/bin/env bash
# Roda a suíte pgTAP com o relógio andado desde o `db reset`.
#
# `supabase/cenarios.sql` nasce no instante do reset: a vaga em andamento começou 1 h
# antes dele, a âncora é "a próxima sexta" contada a partir dele. A suíte roda depois —
# minutos depois na CI, horas ou dias depois na máquina de quem não reseta toda hora.
# Nesse meio-tempo o pg_cron trabalha de verdade: fecha o turno que terminou, manda
# lembrete, avisa atraso. Teste que só passa logo depois do reset é bomba-relógio: fica
# verde na CI e vermelho na mesa de alguém, por um motivo que não tem nada a ver com o
# que ele mede. O revisor do #61 achou a primeira (a vaga d…08 vence 7 h após o reset).
#
# O relógio do contêiner não se mexe — é compartilhado, e não há faketime na imagem. O
# que se mexe é o instante do reset: `frila.cenarios_agora` reconstrói o cenário como
# se ele tivesse rodado no passado, e o agendador roda uma vez sobre o resultado, que
# é o que ele teria feito nesse intervalo. Aí a suíte roda, com o relógio de verdade.
#
# O que isto NÃO prova: um teste que cria os próprios dados com `now()` e depende do
# dia da semana de hoje. Para esses o `now()` é o de agora, em qualquer rodada. A
# defesa deles é congelar o relógio do produto (`frila.agora`, em `privado.agora()`)
# ou derivar a data do próprio `now()`, e é revisão, não este script.
#
# No fim o banco volta a um `db reset` comum: nenhum cenário deslocado fica para trás.
#
# Uso:  ./scripts/relogio-deslocado.sh                 8 h, 3 dias e sábado 23:30
#       ./scripts/relogio-deslocado.sh '8 hours'       um intervalo do Postgres
#       ./scripts/relogio-deslocado.sh sabado          o último sábado, 23:30 em Brasília
#       ./scripts/relogio-deslocado.sh '2026-09-26 23:30-03'   um instante qualquer
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}
psql() { docker exec -i "$DB" psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }

if ! psql -tAc 'select 1' >/dev/null 2>&1; then
  echo "✗ Não alcancei o banco no contêiner $DB. Suba o ambiente: supabase start" >&2
  exit 1
fi

[ $# -eq 0 ] && set -- '8 hours' '3 days' sabado

# O instante em que o reset "rodou", calculado pelo banco para não depender do `date`
# de cada sistema. Sábado às 23:30 em Brasília já é domingo em UTC: é a virada de dia
# que um `extract(dow ...)` sem fuso erra.
instante() {
  case "$1" in
    sabado)
      psql -tAc "with l as (select now() at time zone 'America/Sao_Paulo' as t),
                      s as (select date_trunc('day', t)
                                   - ((extract(dow from t)::int + 1) % 7) * interval '1 day'
                                   + interval '23 hours 30 minutes' as s, t from l)
                 select (case when s > t then s - interval '7 days' else s end)
                          at time zone 'America/Sao_Paulo' from s" ;;
    *[0-9][0-9][0-9][0-9]-*)
      psql -tAc "select '$1'::timestamptz" ;;
    *)
      psql -tAc "select now() - '$1'::interval" ;;
  esac
}

temp=$(mktemp -d)
restaurar() {
  rm -rf "$temp"
  echo
  echo "▸ Devolvendo o banco a um db reset comum..."
  supabase db reset >/dev/null 2>&1 && echo "  ok" || echo "  ✗ o db reset final falhou: rode supabase db reset"
}
trap restaurar EXIT

# Cópia do projeto sem os testes e sem o vínculo remoto (`.temp`), com uma linha a
# mais no começo do cenário. O `db reset` roda nela; a suíte roda na árvore de verdade.
mkdir -p "$temp/supabase"
for f in config.toml seed.sql cenarios.sql migrations templates functions; do
  cp -R "supabase/$f" "$temp/supabase/"
done

resultado=()
for desloc in "$@"; do
  r=$(instante "$desloc" | sed 's/^ *//; s/ *$//' | grep -v '^$')
  if [ -z "$r" ]; then echo "✗ Não entendi o deslocamento: $desloc" >&2; exit 2; fi
  echo
  echo "━━ reset em $r ($desloc) ━━"

  { echo "select set_config('frila.cenarios_agora', '$r', false);"
    cat supabase/cenarios.sql; } > "$temp/supabase/cenarios.sql"

  if ! supabase db reset --workdir "$temp" >"$temp/reset.log" 2>&1; then
    tail -20 "$temp/reset.log"
    echo "✗ O cenário não aplicou com o reset em $r."
    resultado+=("✗ $desloc: o cenário não aplica")
    continue
  fi

  # O agendador, uma vez, sobre o cenário envelhecido. Cada job no seu próprio
  # comando: um que falhe não esconde o efeito dos outros.
  psql -tA -F $'\t' -c "select jobname, command from cron.job where active order by jobname" |
  while IFS=$'\t' read -r job cmd; do
    [ -z "$job" ] && continue
    if printf '%s\n' "$cmd" | psql -q >/dev/null 2>"$temp/job.err"; then
      echo "  agendador: $job"
    else
      echo "  agendador: $job ✗ $(head -1 "$temp/job.err")"
    fi
  done

  saida=$(supabase test db 2>&1)
  if printf '%s\n' "$saida" | grep -q '^Result: PASS'; then
    echo "  ✓ suíte verde"
    resultado+=("✓ $desloc (reset em $r)")
  else
    printf '%s\n' "$saida" | grep -E 'not ok|Failed|Dubious|^Result' | head -40
    resultado+=("✗ $desloc (reset em $r)")
  fi
done

echo
echo "━━ resumo ━━"
printf '  %s\n' "${resultado[@]}"
printf '%s\n' "${resultado[@]}" | grep -q '^✗' && exit 1
exit 0
