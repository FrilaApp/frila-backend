#!/usr/bin/env bash
# Mede p50 e p95 de public.painel_estabelecimento com várias casas pesadas (cartão 1zojatYG).
#
# Complementa scripts/medir-painel.sh, que mede UMA casa com 10 amostras (mediana, mínimo e
# máximo, sem p95). Este mede 5 casas, cada uma com 200 vagas x 10 posições, nas janelas de 7
# e de 31 dias, com amostras suficientes para um p95 que não seja o máximo da amostra.
#
# Cada casa é lida pelo seu próprio dono (membro só dela), como `authenticated`. A carga
# (supabase/tests/carga/gerar_casa_pesada.sql) e a medição ficam na MESMA transação, que
# termina em `rollback`: nada fica no banco, não há `db reset`, e o script conta o resíduo e
# imprime o número. O relatório e as saídas brutas vão para um diretório de fora do
# repositório (--saida, ou mktemp).
#
# Plano e volume. O portão supabase/tests/310_consultas_quentes_df.sql aprova o plano com
# `enable_seqscan = off`, e a carga nunca roda na CI. Este script mede com o planejador LIVRE
# e registra no relatório: a configuração do planejador (linha CONFIG), o volume total e o
# volume dentro de cada janela, por casa (VOLUME_CASA e VOLUME_JANELA), o `explain (analyze,
# buffers)` da chamada e, via auto_explain, os planos das consultas internas (linha PLANO).
#
# Os volumes são HIPÓTESE do cartão, não dado de produto. Tempo local não transfere para o
# Prod (plano gratuito, CPU e disco compartilhados). A META p95 abaixo é PROPOSTA, não SLA do
# repositório: o script a imprime ao lado do resultado e não reprova por ela. Quem decide
# índice, janela limitada ou paginação é o Cauê ou o Jota, com o relatório na mão.
#
# Limite do gerador: no máximo 3 vagas por dia. Com 200 vagas por casa, o histórico tem de
# ter pelo menos 67 dias (o padrão). A janela de 7 dias fica com 21 vagas e a de 31 dias com
# 93 (DEDUZIDO da fórmula do gerador; o relatório traz as contagens MEDIDAS). Não há como
# pôr as 200 vagas dentro de 7 ou 31 dias com este gerador.
#
# Uso:
#   ./scripts/medir-painel-volume.sh --saida DIR     carrega, mede e escreve o relatório em DIR
#   ./scripts/medir-painel-volume.sh --resumir ARQ   só confere e resume um arquivo de amostras
#                                                    (amostras.txt de uma execução anterior);
#                                                    não toca o banco nem o Docker
#
# Variáveis de ambiente (os padrões são o cenário do cartão):
#   DB_CONTAINER           contêiner do Postgres local       (padrão supabase_db_frila-backend)
#   DB_USER                papel do psql no contêiner        (padrão supabase_admin; o
#                          auto_explain só carrega para superusuário)
#   CASAS                  casas carregadas                  (padrão 5)
#   VAGAS                  vagas por casa                    (padrão 200)
#   POSICOES               posições por vaga                 (padrão 10)
#   CANDIDATOS             candidaturas por posição          (padrão 6, hipótese)
#   DIAS_HISTORICO         dias do histórico                 (padrão 67; mínimo ceil(VAGAS/3))
#   JANELAS                janelas, em dias, por vírgula     (padrão 7,31)
#   AMOSTRAS               chamadas medidas por casa e janela (padrão 20; p95 sobre CASAS x AMOSTRAS)
#   AQUECIMENTO            rodadas descartadas antes         (padrão 3)
#   META_P95_MS            meta proposta de p95, em ms       (padrão 1000)
#   STATEMENT_TIMEOUT_MS   teto de cada comando              (padrão 600000)
#   PERMITIR_BASE_POVOADA  'sim' aceita banco com mais de 200 usuários (padrão 'nao')
#
# O p50 e o p95 são calculados aqui, pelo método de percentile_cont (interpolação linear), e
# conferidos contra o percentile_cont do próprio Postgres sobre as mesmas amostras; se
# divergirem, o script não mede.
#
# Saída:
#   0  mediu: todas as janelas têm amostras completas, volume conferido e p50/p95 impressos.
#      Estourar a meta NÃO muda a saída; aparece como meta=NAO_ATENDE na linha RESULTADO.
#   2  NÃO mediu, ou mediu só parte: pré-condição ausente, erro no SQL, timeout, amostra
#      faltando, volume diferente do pedido, resíduo. Nunca 0 por omissão. Não existe saída 1.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB="${DB_CONTAINER:-supabase_db_frila-backend}"
DB_USER="${DB_USER:-supabase_admin}"
GERADOR="supabase/tests/carga/gerar_casa_pesada.sql"
MEDIDOR="scripts/medir-painel-volume.sql"
CASAS="${CASAS:-5}"
VAGAS="${VAGAS:-200}"
POSICOES="${POSICOES:-10}"
CANDIDATOS="${CANDIDATOS:-6}"
DIAS_HISTORICO="${DIAS_HISTORICO:-67}"
JANELAS="${JANELAS:-7,31}"
AMOSTRAS="${AMOSTRAS:-20}"
AQUECIMENTO="${AQUECIMENTO:-3}"
META_P95_MS="${META_P95_MS:-1000}"
TIMEOUT_MS="${STATEMENT_TIMEOUT_MS:-600000}"
PERMITIR_BASE_POVOADA="${PERMITIR_BASE_POVOADA:-nao}"
SAIDA=""
ARQUIVO_RESUMIR=""

nao_medi() { printf '✗ NÃO MEDI: %s\n' "$1" >&2; exit 2; }
numero() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
decimal() { case "${1:-}" in ''|*[!0-9.]*|*.*.*|.|*.) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --resumir)
      [ -n "${2:-}" ] || nao_medi "--resumir exige um arquivo"
      ARQUIVO_RESUMIR="$2"
      shift 2
      ;;
    --saida)
      [ -n "${2:-}" ] || nao_medi "--saida exige um diretório"
      SAIDA="$2"
      shift 2
      ;;
    *) nao_medi "argumento desconhecido: $1" ;;
  esac
done

# ── Validação dos parâmetros: vale nos dois modos, e vem antes de qualquer Docker ─────────
numero "$CASAS" && [ "$CASAS" -ge 1 ] || nao_medi "CASAS precisa ser um inteiro >= 1 (recebi '$CASAS')"
numero "$VAGAS" && [ "$VAGAS" -ge 1 ] || nao_medi "VAGAS precisa ser um inteiro >= 1 (recebi '$VAGAS')"
numero "$POSICOES" && [ "$POSICOES" -ge 1 ] && [ "$POSICOES" -le 200 ] || nao_medi "POSICOES precisa ser um inteiro entre 1 e 200 (recebi '$POSICOES')"
numero "$CANDIDATOS" && [ "$CANDIDATOS" -ge 1 ] || nao_medi "CANDIDATOS precisa ser um inteiro >= 1 (recebi '$CANDIDATOS')"
numero "$DIAS_HISTORICO" && [ "$DIAS_HISTORICO" -ge 30 ] || nao_medi "DIAS_HISTORICO precisa ser um inteiro >= 30 (recebi '$DIAS_HISTORICO')"
numero "$AMOSTRAS" && [ "$AMOSTRAS" -ge 1 ] || nao_medi "AMOSTRAS precisa ser um inteiro >= 1 (recebi '$AMOSTRAS')"
numero "$AQUECIMENTO" || nao_medi "AQUECIMENTO precisa ser um inteiro >= 0 (recebi '$AQUECIMENTO')"
numero "$TIMEOUT_MS" || nao_medi "STATEMENT_TIMEOUT_MS precisa ser um inteiro (recebi '$TIMEOUT_MS')"
decimal "$META_P95_MS" || nao_medi "META_P95_MS precisa ser um número (recebi '$META_P95_MS')"
case "$JANELAS" in
  ''|*[!0-9,]*|,*|*,|*,,*) nao_medi "JANELAS precisa ser uma lista de dias separada por vírgula, por exemplo 7,31 (recebi '$JANELAS')" ;;
esac
case "$DB_USER" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) nao_medi "DB_USER precisa ser um nome de papel simples (recebi '$DB_USER')" ;; esac
case "$PERMITIR_BASE_POVOADA" in sim|nao) : ;; *) nao_medi "PERMITIR_BASE_POVOADA aceita 'sim' ou 'nao'" ;; esac
if [ $(( (VAGAS + DIAS_HISTORICO - 1) / DIAS_HISTORICO )) -gt 3 ]; then
  nao_medi "o gerador aceita no máximo 3 vagas por dia: com VAGAS=$VAGAS use DIAS_HISTORICO >= $(( (VAGAS + 2) / 3 ))"
fi
for j in $(printf '%s' "$JANELAS" | tr ',' ' '); do
  [ "$j" -ge 1 ] || nao_medi "toda janela precisa ser >= 1 dia (recebi '$j')"
done

# Valor de um campo `nome=valor` numa linha do arquivo de amostras.
campo() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n1; }

# ── Confere e resume um arquivo de amostras. Sai 2 a qualquer inconsistência ───────────────
# O arquivo tem as linhas PARAMETROS, CONFIG, VOLUME_CASA, VOLUME_JANELA, BLOCO, AMOSTRA e
# PG_PERCENTIL escritas por scripts/medir-painel-volume.sql, e PLANO, escritas pelo .sh.
resumir_arquivo() {
  local arq="$1"
  [ -f "$arq" ] || nao_medi "arquivo de amostras não existe: $arq"
  [ -s "$arq" ] || nao_medi "arquivo de amostras vazio: $arq"
  if grep -qE '(^|[^A-Za-z_])ERROR:' "$arq"; then
    nao_medi "o arquivo $arq registra erro do SQL: $(grep -m1 -E 'ERROR:' "$arq")"
  fi

  local param
  param=$(grep -E '^PARAMETROS ' "$arq")
  [ "$(printf '%s\n' "$param" | grep -c .)" -eq 1 ] || nao_medi "esperava exatamente uma linha PARAMETROS em $arq"
  local casas vagas posicoes candidatos janelas amostras dias
  casas=$(campo "$param" casas); vagas=$(campo "$param" vagas); posicoes=$(campo "$param" posicoes)
  candidatos=$(campo "$param" candidatos); janelas=$(campo "$param" janelas)
  amostras=$(campo "$param" amostras); dias=$(campo "$param" dias_historico)
  local v
  for v in "$casas" "$vagas" "$posicoes" "$candidatos" "$amostras" "$dias"; do
    numero "$v" || nao_medi "linha PARAMETROS com campo ausente ou não numérico: $param"
  done
  case "$janelas" in ''|*[!0-9,]*) nao_medi "linha PARAMETROS sem janelas válidas: $param" ;; esac

  local total=$((casas * amostras))
  [ "$total" -ge 20 ] || nao_medi "$total amostras por janela (casas=$casas x amostras=$amostras): p95 com menos de 20 amostras é o máximo da amostra, não um p95"

  local c j linha
  # Volume total de cada casa: o que foi carregado tem de ser o que foi pedido.
  for c in $(seq 1 "$casas"); do
    linha=$(grep -E "^VOLUME_CASA casa=$c " "$arq")
    [ "$(printf '%s\n' "$linha" | grep -c .)" -eq 1 ] || nao_medi "esperava exatamente uma linha VOLUME_CASA da casa $c"
    [ "$(campo "$linha" vagas)" = "$vagas" ] \
      || nao_medi "casa $c tem $(campo "$linha" vagas) vagas, o pedido era $vagas"
    [ "$(campo "$linha" posicoes)" = "$((vagas * posicoes))" ] \
      || nao_medi "casa $c tem $(campo "$linha" posicoes) posições, o pedido era $((vagas * posicoes))"
    [ "$(campo "$linha" candidaturas)" = "$((vagas * posicoes * candidatos))" ] \
      || nao_medi "casa $c tem $(campo "$linha" candidaturas) candidaturas, o pedido era $((vagas * posicoes * candidatos))"
  done

  # Volume dentro de cada janela, resposta do painel e contagem de amostras, por casa.
  local n_amostras=0
  for j in $(printf '%s' "$janelas" | tr ',' ' '); do
    for c in $(seq 1 "$casas"); do
      linha=$(grep -E "^VOLUME_JANELA janela_dias=$j casa=$c " "$arq")
      [ "$(printf '%s\n' "$linha" | grep -c .)" -eq 1 ] || nao_medi "esperava exatamente uma linha VOLUME_JANELA da janela $j, casa $c"
      local vj pj
      vj=$(campo "$linha" vagas); pj=$(campo "$linha" posicoes)
      numero "$vj" && numero "$pj" || nao_medi "VOLUME_JANELA ilegível (janela $j, casa $c): $linha"
      [ "$vj" -ge 1 ] || nao_medi "a janela de $j dias da casa $c não tem nenhuma vaga: o tempo medido seria o de uma resposta vazia"
      [ "$pj" -eq $((vj * posicoes)) ] || nao_medi "janela $j, casa $c: $pj posições para $vj vagas de $posicoes posições"

      linha=$(grep -E "^BLOCO janela_dias=$j casa=$c " "$arq")
      [ "$(printf '%s\n' "$linha" | grep -c .)" -eq 1 ] || nao_medi "esperava exatamente uma linha BLOCO da janela $j, casa $c"
      [ "$(campo "$linha" vagas_resposta)" = "$vj" ] \
        || nao_medi "janela $j, casa $c: o painel devolveu $(campo "$linha" vagas_resposta) vagas, o banco tem $vj na janela"
      [ "$(campo "$linha" posicoes_resposta)" = "$pj" ] \
        || nao_medi "janela $j, casa $c: o painel devolveu $(campo "$linha" posicoes_resposta) posições, o banco tem $pj na janela"

      local n
      n=$(grep -cE "^AMOSTRA janela_dias=$j casa=$c i=[0-9]+ ms=" "$arq")
      [ "$n" -eq "$amostras" ] || nao_medi "janela $j, casa $c: $n amostras, o pedido era $amostras"
      n_amostras=$((n_amostras + n))
    done
  done
  local n_linhas
  n_linhas=$(grep -cE '^AMOSTRA ' "$arq")
  [ "$n_linhas" -eq "$n_amostras" ] || nao_medi "$n_linhas linhas AMOSTRA, mas só $n_amostras pertencem às janelas e casas pedidas"

  local tmp
  tmp=$(mktemp -d) || nao_medi "mktemp -d falhou"
  # shellcheck disable=SC2064 # expande $tmp agora, de propósito
  trap "rm -rf '$tmp'" RETURN

  # Nada vai para a saída até a última janela passar nas conferências: um RESULTADO de 7 dias
  # seguido de "NÃO MEDI" na janela de 31 é número sem medição completa.
  exec 3>&1 1>"$tmp/saida"

  printf 'volume: %s casas x %s vagas x %s posições x %s candidaturas por posição, histórico de %s dias (HIPÓTESE do cartão, não dado de produto)\n' \
    "$casas" "$vagas" "$posicoes" "$candidatos" "$dias"
  linha=$(grep -m1 -E '^CONFIG ' "$arq")
  printf 'planejador: %s\n' "${linha:-CONFIG NAO MEDIDO (linha CONFIG ausente)}"
  printf 'amostras por janela: %s (%s casas x %s) depois de %s rodadas de aquecimento descartadas\n' \
    "$total" "$casas" "$amostras" "$(campo "$param" aquecimento)"
  printf 'método do percentil: interpolação linear, igual a percentile_cont; conferido contra o Postgres\n'
  printf '\n'

  local p50 p95 mn mx pg pg50 pg95 meta
  for j in $(printf '%s' "$janelas" | tr ',' ' '); do
    grep -E "^AMOSTRA janela_dias=$j casa=" "$arq" | sed 's/.* ms=//' > "$tmp/bruto-$j"
    if grep -qvE '^[0-9]+(\.[0-9]+)?$' "$tmp/bruto-$j"; then
      nao_medi "janela $j: há amostra que não é um número ($(grep -m1 -vE '^[0-9]+(\.[0-9]+)?$' "$tmp/bruto-$j"))"
    fi
    sort -n "$tmp/bruto-$j" > "$tmp/ord-$j"
    if awk '$1 <= 0 { r = 1 } END { exit r + 0 }' "$tmp/ord-$j"; then :; else
      nao_medi "janela $j: há amostra com tempo zero ou negativo"
    fi
    read -r p50 p95 mn mx < <(awk '
      { a[NR] = $1 }
      function pct(p,   r, lo, f) { r = (NR - 1) * p; lo = int(r); f = r - lo
        return (lo + 1 < NR) ? a[lo + 1] + f * (a[lo + 2] - a[lo + 1]) : a[lo + 1] }
      END { printf "%.2f %.2f %.2f %.2f\n", pct(0.5), pct(0.95), a[1], a[NR] }' "$tmp/ord-$j")

    pg=$(grep -E "^PG_PERCENTIL janela_dias=$j " "$arq")
    [ "$(printf '%s\n' "$pg" | grep -c .)" -eq 1 ] || nao_medi "esperava exatamente uma linha PG_PERCENTIL da janela $j"
    pg50=$(campo "$pg" p50_ms); pg95=$(campo "$pg" p95_ms)
    [ "$(campo "$pg" amostras)" = "$total" ] || nao_medi "janela $j: o Postgres contou $(campo "$pg" amostras) amostras, este script contou $total"
    if ! awk -v a="$p50" -v b="$pg50" -v c="$p95" -v d="$pg95" 'BEGIN { exit !(a - b <= 0.01 && b - a <= 0.01 && c - d <= 0.01 && d - c <= 0.01) }'; then
      nao_medi "janela $j: p50/p95 deste script ($p50/$p95) divergem do percentile_cont do Postgres ($pg50/$pg95)"
    fi

    meta=$(awk -v p="$p95" -v m="$META_P95_MS" 'BEGIN { print (p <= m) ? "ATENDE" : "NAO_ATENDE" }')
    printf 'RESULTADO janela_dias=%s amostras=%s casas=%s p50_ms=%s p95_ms=%s min_ms=%s max_ms=%s meta_p95_ms=%s meta=%s\n' \
      "$j" "$total" "$casas" "$p50" "$p95" "$mn" "$mx" "$META_P95_MS" "$meta"
    linha=$(grep -m1 -E "^VOLUME_JANELA janela_dias=$j casa=1 " "$arq")
    printf '  volume da janela (por casa, casa 1): %s\n' "${linha#VOLUME_JANELA }"
    for c in $(seq 1 "$casas"); do
      grep -E "^AMOSTRA janela_dias=$j casa=$c " "$arq" | sed 's/.* ms=//' | sort -n \
        | awk -v c="$c" '{ a[NR] = $1 } END { printf "  casa %s: n=%d mediana=%.2f ms max=%.2f ms\n", c, NR, (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2, a[NR] }'
    done
    linha=$(grep -m1 -E "^PLANO janela_dias=$j " "$arq")
    printf '  plano das consultas internas (casa 1): %s\n' "${linha#PLANO janela_dias=$j }"
    [ -n "$linha" ] || printf '  plano das consultas internas: NAO MEDIDO (linha PLANO ausente)\n'
    printf '\n'
  done
  exec 1>&3 3>&-
  cat "$tmp/saida"
  return 0
}

if [ -n "$ARQUIVO_RESUMIR" ]; then
  resumir_arquivo "$ARQUIVO_RESUMIR"
  exit 0
fi

# ── Pré-condições da medição. Cada uma sai 2, não 0 ───────────────────────────────────────
command -v docker >/dev/null 2>&1 || nao_medi "docker não está no PATH"
[ -f "$GERADOR" ] || nao_medi "$GERADOR não existe"
[ -f "$MEDIDOR" ] || nao_medi "$MEDIDOR não existe"
docker inspect -f '{{.State.Running}}' "$DB" 2>/dev/null | grep -q true \
  || nao_medi "o contêiner $DB não está de pé"

psql_() { docker exec -e PGPASSWORD=postgres -i "$DB" psql -U "$DB_USER" -d postgres -X -q "$@"; }

psql_ -At -c 'select 1' >/dev/null 2>&1 \
  || nao_medi "o Postgres em $DB não respondeu como '$DB_USER' (senha, papel ou contêiner)"

n_funcoes=$(psql_ -At -c 'select count(*) from public.funcao' 2>/dev/null)
numero "$n_funcoes" || nao_medi "não consegui contar public.funcao (psql devolveu: '${n_funcoes:-vazio}')"
[ "$n_funcoes" -gt 0 ] || nao_medi "public.funcao está vazia: o seed não foi aplicado neste banco"

n_usuarios=$(psql_ -At -c 'select count(*) from public.usuario' 2>/dev/null)
numero "$n_usuarios" || nao_medi "não consegui contar public.usuario (psql devolveu: '${n_usuarios:-vazio}')"
if [ "$n_usuarios" -gt 200 ] && [ "$PERMITIR_BASE_POVOADA" != "sim" ]; then
  nao_medi "o banco tem $n_usuarios usuários; os números incluiriam essa massa. Rode com PERMITIR_BASE_POVOADA=sim se isso for aceitável (a carga some no rollback)."
fi

if [ -z "$SAIDA" ]; then
  SAIDA=$(mktemp -d) || nao_medi "mktemp -d falhou"
fi
mkdir -p "$SAIDA" || nao_medi "não consegui criar $SAIDA"
relatorio="$SAIDA/relatorio.txt"
: > "$relatorio" || nao_medi "não consegui escrever em $relatorio"
bruto="$SAIDA/bruto.txt"
erros="$SAIDA/bruto.err.txt"
amostras_txt="$SAIDA/amostras.txt"

versao_pg=$(psql_ -At -c 'show server_version' 2>/dev/null)
superusuario=$(psql_ -At -c 'select rolsuper from pg_roles where rolname = current_user' 2>/dev/null)
commit=$(git rev-parse --short HEAD 2>/dev/null || printf 'desconhecido')

linha() { printf '%s\n' "$*" | tee -a "$relatorio"; }

linha "# medir-painel-volume.sh · $(date '+%Y-%m-%d %H:%M:%S %z')"
linha "commit do repositório: $commit · Postgres $versao_pg · contêiner $DB · usuários na base antes: $n_usuarios"
linha "papel do psql: $DB_USER (superusuário: ${superusuario:-?}; auto_explain só carrega se for 't')"
linha "meta de p95 PROPOSTA: ${META_P95_MS} ms (não é SLA do repositório; o script não reprova por ela)"
linha "volumes: HIPÓTESE do cartão, não dado de produto. Tempo local não transfere para o Prod."
linha ""

montar_sql() {
  printf '%s\n' '\set ON_ERROR_STOP on' '\set casa_pesada 1'
  printf '\\set vagas %s\n' "$VAGAS"
  printf '\\set posicoes %s\n' "$POSICOES"
  printf '\\set candidatos %s\n' "$CANDIDATOS"
  printf '\\set dias %s\n' "$DIAS_HISTORICO"
  printf '\\set casas_extras %s\n' "$((CASAS - 1))"
  printf '\\set vagas_extras %s\n' "$VAGAS"
  printf '\\set posicoes_extras %s\n' "$POSICOES"
  printf '\\set candidatos_extras %s\n' "$CANDIDATOS"
  printf '\\set permitir_base_povoada %s\n' "$PERMITIR_BASE_POVOADA"
  printf '\\set casas %s\n' "$CASAS"
  printf '\\set janelas %s\n' "$JANELAS"
  printf '\\set amostras %s\n' "$AMOSTRAS"
  printf '\\set aquecimento %s\n' "$AQUECIMENTO"
  printf "set statement_timeout = '%sms';\n" "$TIMEOUT_MS"
  printf "set lock_timeout = '5s';\n"
  printf 'begin;\n'
  cat "$GERADOR"
  cat "$MEDIDOR"
  printf 'rollback;\n'
}

linha "carregando $CASAS casas e medindo (a carga e a medição ficam numa transação que termina em rollback)..."
montar_sql | psql_ -f - > "$bruto" 2> "$erros"
rc=${PIPESTATUS[1]}
if [ "$rc" -ne 0 ] || grep -qE '(^|[^A-Za-z_])ERROR:' "$erros" "$bruto"; then
  linha "✗ o SQL terminou com erro (psql saiu $rc). Primeiras linhas do erro:"
  grep -h -m3 -B1 -A3 'ERROR:' "$erros" "$bruto" | sed 's/^/    /' | tee -a "$relatorio" >&2
  nao_medi "o SQL falhou; veja $erros"
fi

# Extrai o trecho entre dois marcadores. O marcador tem de ser o FIM da linha: "janela_dias=7"
# é prefixo de "janela_dias=70".
trecho() { # arquivo marcador_inicio marcador_fim
  awk -v ini="$2" -v fim="$3" '$0 ~ (ini "$") {on=1; next} $0 ~ (fim "$") {on=0} on' "$1"
}

# Linhas de dados: as do SQL (NOTICE) sem o prefixo do psql, mais uma linha PLANO por janela.
sed -nE 's/^.*NOTICE:  ((PARAMETROS|CONFIG|VOLUME_CASA|VOLUME_JANELA|BLOCO|AMOSTRA|PG_PERCENTIL) .*)$/\1/p' "$erros" > "$amostras_txt"

for j in $(printf '%s' "$JANELAS" | tr ',' ' '); do
  plano="$SAIDA/plano-janela-$j.txt"
  explain="$SAIDA/explain-janela-$j.txt"
  trecho "$erros" "### AUTO_EXPLAIN_INICIO janela_dias=$j" "### AUTO_EXPLAIN_FIM janela_dias=$j" > "$plano"
  trecho "$bruto" "### EXPLAIN_INICIO janela_dias=$j" "### EXPLAIN_FIM janela_dias=$j" > "$explain"
  if grep -q 'duration:' "$plano"; then
    n_planos=$(grep -c 'duration:' "$plano")
    seqs=""
    for t in posicao ocorrencia vaga candidatura turno; do
      # Conta só os nós que rodaram: "(never executed)" é ramo do plano que não foi percorrido.
      n=$(grep -E "Seq Scan on (public\.)?$t\b" "$plano" | grep -vc 'never executed')
      seqs="$seqs seq_scan_$t=$n"
    done
    max_loops=$(grep -oE 'loops=[0-9]+' "$plano" | sed 's/loops=//' | sort -n | tail -1)
    printf 'PLANO janela_dias=%s planos=%s%s maior_loops=%s\n' \
      "$j" "$n_planos" "$seqs" "${max_loops:-0}" >> "$amostras_txt"
  else
    printf 'PLANO janela_dias=%s NAO_MEDIDO (auto_explain não registrou nada; veja AUTO_EXPLAIN_* em %s)\n' "$j" "$erros" >> "$amostras_txt"
  fi
done

falhas=0

# Resíduo: depois do rollback não pode sobrar nada da carga.
residuo=$(psql_ -At -c "select count(*) from public.estabelecimento where nome like 'Casa pesada %'" 2>/dev/null)
usuarios_depois=$(psql_ -At -c 'select count(*) from public.usuario' 2>/dev/null)
if numero "$residuo" && numero "$usuarios_depois"; then
  linha "resíduo após rollback: $residuo estabelecimentos 'Casa pesada' · usuários $n_usuarios antes, $usuarios_depois depois"
  [ "$residuo" -eq 0 ] || { linha "✗ sobrou massa da carga no banco"; falhas=$((falhas + 1)); }
else
  linha "✗ não consegui contar o resíduo (psql devolveu: '${residuo:-vazio}' / '${usuarios_depois:-vazio}')"
  falhas=$((falhas + 1))
fi
linha ""

# O resumo roda num subshell: o nao_medi dele sai 2 sem encerrar este script antes da hora.
resumo=$(resumir_arquivo "$amostras_txt" 2>&1); rc_resumo=$?
if [ "$rc_resumo" -ne 0 ]; then
  falhas=$((falhas + 1))
fi
printf '%s\n' "$resumo" | tee -a "$relatorio"

linha "relatório e saídas brutas: $SAIDA"
if [ "$falhas" -gt 0 ]; then
  nao_medi "$falhas etapa(s) sem medição completa; veja $relatorio"
fi
exit 0
