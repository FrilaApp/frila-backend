#!/usr/bin/env bash
# Autoteste de scripts/medir-painel-volume.sh (cartão 1zojatYG).
#
# Um medidor com furo imprime número bonito sem ter medido. Este autoteste prova que o script:
#   1. Resume uma saída REAL (scripts/fixtures/medir-painel-volume-real.txt, capturada de uma
#      execução contra o Postgres local) e imprime p50/p95 de 7 e 31 dias com 100 amostras,
#      no formato da linha RESULTADO.
#   2. Calcula o percentil certo (verificado com 100 amostras 1..100, cujo p50 é 50,50 e o
#      p95 é 95,05, contas feitas à mão).
#   3. Compara o p95 com a meta e sai 0 nos dois casos, escrevendo ATENDE ou NAO_ATENDE.
#   4. Sai 2, nunca 0, e não imprime RESULTADO quando não mediu: arquivo ausente ou vazio,
#      amostra faltando, amostra extra, tempo não numérico, tempo zero, janela sem vaga,
#      resposta do painel com menos vagas que o banco, volume diferente do pedido, erro de
#      SQL no arquivo, divergência do percentil contra o Postgres, p95 com poucas amostras.
#   5. Recusa parâmetro inválido e banco inexistente com saída 2.
#   6. Acompanha o SQL: cada marcador da fixture real ainda sai, com os mesmos campos, de
#      scripts/medir-painel-volume.sql (ou do .sh, no caso de PLANO). Se o SQL mudar o
#      formato, a fixture e este teste ficam vermelhos em vez de testar um formato velho.
#
# Não precisa de Docker nem de Postgres: alimenta o script com a opção `--resumir`.
#
# Uso:  ./scripts/teste-medir-painel-volume.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCRIPT="$PWD/scripts/medir-painel-volume.sh"
SQL="$PWD/scripts/medir-painel-volume.sql"
REAL="$PWD/scripts/fixtures/medir-painel-volume-real.txt"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

# caso NOME ESPERADO FRASE [VAR=valor ...] -- ARGS...
# Passa se a saída (stdout + stderr) tem o código esperado e contém a frase.
caso() {
  local nome="$1" esperado="$2" frase="$3"
  shift 3
  local ambiente=()
  while [ "$1" != "--" ]; do ambiente+=("$1"); shift; done
  shift
  casos=$((casos + 1))
  local saida codigo
  saida=$(env ${ambiente[@]+"${ambiente[@]}"} "$SCRIPT" "$@" 2>&1)
  codigo=$?
  if [ "$codigo" = "$esperado" ] && printf '%s\n' "$saida" | grep -qF -- "$frase"; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperava saída $esperado com \"$frase\", veio $codigo:"
    printf '%s\n' "$saida" | head -8 | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

# Quando não mediu, nenhuma linha RESULTADO pode ter saído: número sem medição é o defeito.
caso_sem_resultado() {
  local nome="$1" frase="$2" arquivo="$3"
  casos=$((casos + 1))
  local saida codigo
  saida=$("$SCRIPT" --resumir "$arquivo" 2>&1)
  codigo=$?
  if [ "$codigo" = 2 ] && printf '%s\n' "$saida" | grep -qF -- "$frase" \
     && ! printf '%s\n' "$saida" | grep -q '^RESULTADO'; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperava saída 2 com \"$frase\" e sem RESULTADO, veio $codigo:"
    printf '%s\n' "$saida" | head -8 | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

[ -f "$REAL" ] || { echo "✗ fixture real ausente: $REAL"; exit 2; }

echo "▸ Autoteste de medir-painel-volume.sh"

# ── 1. Saída real ────────────────────────────────────────────────────────────────
echo "  saída real"
caso "resume a saída real: 7 dias, p50 e p95 com 100 amostras" 0 \
  "RESULTADO janela_dias=7 amostras=100 casas=5 p50_ms=154.47 p95_ms=161.67 min_ms=150.80 max_ms=177.18 meta_p95_ms=1000 meta=ATENDE" \
  -- --resumir "$REAL"
caso "resume a saída real: 31 dias, p50 e p95 com 100 amostras" 0 \
  "RESULTADO janela_dias=31 amostras=100 casas=5 p50_ms=681.50 p95_ms=707.03 min_ms=666.38 max_ms=721.29 meta_p95_ms=1000 meta=ATENDE" \
  -- --resumir "$REAL"
caso "registra o volume carregado e o da janela" 0 \
  "volume: 5 casas x 200 vagas x 10 posições x 6 candidaturas por posição" -- --resumir "$REAL"
caso "registra o volume da janela de 31 dias (93 vagas, 930 posições)" 0 \
  "vagas=93 posicoes=930" -- --resumir "$REAL"
caso "registra a configuração do planejador (enable_seqscan)" 0 \
  "enable_seqscan=on" -- --resumir "$REAL"
caso "registra o plano das consultas internas" 0 "seq_scan_posicao=" -- --resumir "$REAL"

# ── 2. Percentil conferido à mão ─────────────────────────────────────────────────
# Troca os tempos da janela de 7 dias por 1..100 e acerta a linha do Postgres (50,50 e 95,05).
echo "  percentil"
awk '
  /^AMOSTRA janela_dias=7 / { n++; sub(/ ms=.*/, " ms=" n) }
  /^PG_PERCENTIL janela_dias=7 / { sub(/p50_ms=[0-9.]+/, "p50_ms=50.50"); sub(/p95_ms=[0-9.]+/, "p95_ms=95.05") }
  { print }' "$REAL" > "$TMP/um-a-cem.txt"
caso "100 amostras 1..100: p50 = 50,50 e p95 = 95,05" 0 \
  "RESULTADO janela_dias=7 amostras=100 casas=5 p50_ms=50.50 p95_ms=95.05 min_ms=1.00 max_ms=100.00" \
  -- --resumir "$TMP/um-a-cem.txt"

# ── 3. Meta ──────────────────────────────────────────────────────────────────────
echo "  meta"
caso "p95 acima da meta: sai 0 e escreve NAO_ATENDE" 0 \
  "p95_ms=161.67 min_ms=150.80 max_ms=177.18 meta_p95_ms=100 meta=NAO_ATENDE" \
  META_P95_MS=100 -- --resumir "$REAL"
caso "p95 igual à meta atende" 0 "p95_ms=161.67 min_ms=150.80 max_ms=177.18 meta_p95_ms=161.67 meta=ATENDE" \
  META_P95_MS=161.67 -- --resumir "$REAL"

# ── 4. Não mediu: sai 2, sem RESULTADO ───────────────────────────────────────────
echo "  não mediu"
caso "arquivo inexistente" 2 "NÃO MEDI: arquivo de amostras não existe" -- --resumir "$TMP/nao-existe.txt"
: > "$TMP/vazio.txt"
caso_sem_resultado "arquivo vazio" "arquivo de amostras vazio" "$TMP/vazio.txt"

# Uma amostra a menos (a primeira da janela de 31 dias, casa 3).
awk '/^AMOSTRA janela_dias=31 casa=3 / && !feito { feito = 1; next } { print }' "$REAL" > "$TMP/falta-amostra.txt"
caso_sem_resultado "falta uma amostra" "janela 31, casa 3: 19 amostras, o pedido era 20" "$TMP/falta-amostra.txt"

# Uma amostra a mais, de uma casa que não existe no pedido.
{ cat "$REAL"; echo "AMOSTRA janela_dias=7 casa=9 i=1 ms=10.000"; } > "$TMP/amostra-extra.txt"
caso_sem_resultado "amostra de casa fora do pedido" "linhas AMOSTRA, mas só" "$TMP/amostra-extra.txt"

awk '/^AMOSTRA janela_dias=7 casa=2 i=5 / { sub(/ms=.*/, "ms=abc") } { print }' "$REAL" > "$TMP/ms-texto.txt"
caso_sem_resultado "tempo que não é número" "janela 7: há amostra que não é um número" "$TMP/ms-texto.txt"
# Tempo vazio: a linha ainda conta como amostra, e o valor não é número.
awk '/^AMOSTRA janela_dias=7 casa=2 i=5 / { sub(/ms=.*/, "ms=") } { print }' "$REAL" > "$TMP/ms-vazio.txt"
caso_sem_resultado "tempo em branco" "janela 7: há amostra que não é um número" "$TMP/ms-vazio.txt"

awk '/^AMOSTRA janela_dias=7 casa=2 i=5 / { sub(/ms=.*/, "ms=0.000") } { print }' "$REAL" > "$TMP/ms-zero.txt"
caso_sem_resultado "tempo zero" "janela 7: há amostra com tempo zero ou negativo" "$TMP/ms-zero.txt"

# A janela de 7 dias da casa 4 sem vaga, e o painel devolvendo vazio: o tempo seria o de uma
# resposta vazia.
awk '/^VOLUME_JANELA janela_dias=7 casa=4 / { sub(/vagas=[0-9]+/, "vagas=0"); sub(/posicoes=[0-9]+/, "posicoes=0") }
     /^BLOCO janela_dias=7 casa=4 /        { sub(/vagas_resposta=[0-9]+/, "vagas_resposta=0"); sub(/posicoes_resposta=[0-9]+/, "posicoes_resposta=0") }
     { print }' "$REAL" > "$TMP/janela-vazia.txt"
caso_sem_resultado "janela sem nenhuma vaga" "a janela de 7 dias da casa 4 não tem nenhuma vaga" "$TMP/janela-vazia.txt"

awk '/^BLOCO janela_dias=31 casa=1 / { sub(/vagas_resposta=[0-9]+/, "vagas_resposta=50") } { print }' "$REAL" > "$TMP/resposta-curta.txt"
caso_sem_resultado "painel devolveu menos vagas que o banco" "janela 31, casa 1: o painel devolveu 50 vagas, o banco tem 93" "$TMP/resposta-curta.txt"

awk '/^VOLUME_CASA casa=3 / { sub(/vagas=[0-9]+/, "vagas=150") } { print }' "$REAL" > "$TMP/volume-menor.txt"
caso_sem_resultado "casa carregada com volume diferente do pedido" "casa 3 tem 150 vagas, o pedido era 200" "$TMP/volume-menor.txt"

awk '/^VOLUME_JANELA janela_dias=31 casa=5 / { next } { print }' "$REAL" > "$TMP/sem-volume-janela.txt"
caso_sem_resultado "falta o volume da janela de uma casa" "esperava exatamente uma linha VOLUME_JANELA da janela 31, casa 5" "$TMP/sem-volume-janela.txt"

awk '/^PG_PERCENTIL janela_dias=31 / { sub(/p95_ms=[0-9.]+/, "p95_ms=500.00") } { print }' "$REAL" > "$TMP/pg-diverge.txt"
caso_sem_resultado "p95 diverge do percentile_cont do Postgres" "janela 31: p50/p95 deste script (681.50/707.03) divergem do percentile_cont do Postgres (681.50/500.00)" "$TMP/pg-diverge.txt"

{ cat "$REAL"; echo 'psql:<stdin>:600: ERROR:  canceling statement due to statement timeout'; } > "$TMP/com-erro.txt"
caso_sem_resultado "erro de SQL registrado no arquivo" "registra erro do SQL" "$TMP/com-erro.txt"

grep -v '^PARAMETROS ' "$REAL" > "$TMP/sem-parametros.txt"
caso_sem_resultado "sem a linha de parâmetros" "esperava exatamente uma linha PARAMETROS" "$TMP/sem-parametros.txt"

# Poucas amostras: 1 casa x 5 amostras (pedido coerente, mas sem p95 que se sustente).
awk '/^PARAMETROS / { sub(/casas=[0-9]+/, "casas=1"); sub(/amostras=[0-9]+/, "amostras=5") }
     /^VOLUME_CASA casa=[2-5] / { next } /^VOLUME_JANELA .* casa=[2-5] / { next } /^BLOCO .* casa=[2-5] / { next }
     /^AMOSTRA .* casa=[2-5] / { next }
     /^AMOSTRA / { split($4, a, "="); if (a[2] > 5) next }
     /^PG_PERCENTIL / { sub(/amostras=[0-9]+/, "amostras=5") }
     { print }' "$REAL" > "$TMP/poucas.txt"
caso_sem_resultado "5 amostras: p95 seria o máximo da amostra" "p95 com menos de 20 amostras é o máximo da amostra" "$TMP/poucas.txt"

# ── 5. Parâmetros e banco ────────────────────────────────────────────────────────
echo "  parâmetros e banco"
caso "AMOSTRAS não numérico" 2 "NÃO MEDI: AMOSTRAS precisa ser um inteiro >= 1" AMOSTRAS=abc -- --resumir "$REAL"
caso "JANELAS com vírgula dupla" 2 "NÃO MEDI: JANELAS precisa ser uma lista" JANELAS=7,,31 -- --resumir "$REAL"
caso "META_P95_MS não numérico" 2 "NÃO MEDI: META_P95_MS precisa ser um número" META_P95_MS=mil -- --resumir "$REAL"
caso "mais de 3 vagas por dia" 2 "o gerador aceita no máximo 3 vagas por dia" DIAS_HISTORICO=60 -- --resumir "$REAL"
caso "argumento desconhecido" 2 "NÃO MEDI: argumento desconhecido" -- --nada
# Sem o contêiner (ou sem o docker) o script não mede nada e diz que não mediu.
caso "contêiner inexistente" 2 "NÃO MEDI" DB_CONTAINER=contêiner-que-nao-existe-1zojatyg -- --saida "$TMP/saida"

# ── 6. O SQL ainda emite o que a fixture real tem ────────────────────────────────
echo "  formato do SQL"
for marcador in PARAMETROS CONFIG VOLUME_CASA VOLUME_JANELA BLOCO AMOSTRA PG_PERCENTIL PLANO; do
  casos=$((casos + 1))
  linha=$(grep -m1 "^$marcador " "$REAL")
  # Campos da linha real, na ordem em que aparecem: nome=...
  campos=$(printf '%s\n' "$linha" | tr ' ' '\n' | sed -n 's/^\([a-z_0-9]*\)=.*/\1/p')
  if [ "$marcador" = PLANO ]; then fonte="$SCRIPT"; else fonte="$SQL"; fi
  ok=1
  [ -n "$campos" ] || ok=0
  # Cada campo aparece no código que emite o marcador, depois do nome do marcador.
  trecho=$(grep -m1 -A3 "'$marcador " "$fonte"; grep -m1 -A3 "'$marcador " "$fonte" >/dev/null || true)
  [ -n "$trecho" ] || ok=0
  for c in $campos; do
    # PLANO tem campos opcionais por tabela; os demais têm de bater todos.
    if ! printf '%s\n' "$trecho" | grep -q "$c="; then
      if [ "$marcador" = PLANO ] && [ "$c" != janela_dias ] && [ "$c" != planos ]; then continue; fi
      ok=0
    fi
  done
  if [ "$ok" = 1 ]; then
    echo "  ✓ $marcador: campos da fixture presentes no código que o emite"
  else
    echo "  ✗ $marcador: a fixture real tem campos que $(basename "$fonte") não emite mais (atualize os dois)"
    falhas=$((falhas + 1))
  fi
done

echo
if [ "$falhas" -gt 0 ]; then
  echo "✗ $falhas de $casos casos falharam"
  exit 1
fi
echo "✓ $casos casos verdes"
