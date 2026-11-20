#!/usr/bin/env bash
# Mede public.painel_estabelecimento com volume de uma casa com histórico (cartão 1zojatYG).
#
# Cada casa é carregada por supabase/tests/carga/gerar_casa_pesada.sql DENTRO de uma
# transação que termina em `rollback`, e cada cenário é medido por scripts/medir-painel.sql
# na mesma transação. Nada fica no banco: depois do rollback o script conta o resíduo (deve
# dar 0) e imprime o número. Não usa `supabase db reset` e não escreve em nenhum arquivo do
# repositório; o relatório e as saídas brutas vão para um diretório de fora (--saida, ou
# mktemp).
#
# Os volumes dos cenários são HIPÓTESE do plano (plano-backend-3.md, P3.2), não dado de
# produto. Tempo local não transfere para o Prod (plano gratuito, CPU e disco compartilhados):
# serve para comparar cenários e achar plano ruim, não para prometer p95.
#
# Este script NÃO decide paginar nem criar índice. Ele registra. Não há SLA do painel no
# repositório; quem decide é o Cauê ou o Jota, com o relatório na mão.
#
# Uso:
#   ./scripts/medir-painel.sh --listar                 só imprime os cenários e sai (não toca o banco)
#   ./scripts/medir-painel.sh                          mede S1 a S6 e o controle S3_membro5
#   ./scripts/medir-painel.sh --cenarios S1,S2         mede só esses (S3_membro5 acompanha S3)
#   ./scripts/medir-painel.sh --saida DIR              grava relatório e saídas brutas em DIR
#
# Variáveis de ambiente:
#   DB_CONTAINER            contêiner do Postgres local      (padrão supabase_db_frila-backend)
#   DB_USER                 papel do psql no contêiner       (padrão supabase_admin)
#                           O auto_explain só carrega para superusuário. No Supabase local o
#                           superusuário é supabase_admin; `postgres` não é e deixa as consultas
#                           internas como NAO MEDIDO. Os cenários rodam como `authenticated`
#                           (set local role) de qualquer jeito, então RLS vale igual.
#   AMOSTRAS                chamadas medidas por cenário     (padrão 10)
#   AQUECIMENTO             chamadas descartadas antes       (padrão 3)
#   STATEMENT_TIMEOUT_MS    teto de cada comando             (padrão 600000)
#   AUTO_EXPLAIN_MIN_MS     limiar do auto_explain, em ms    (padrão 0 na casa A, 1 na casa B)
#   PERMITIR_BASE_POVOADA   'sim' aceita banco com mais de 200 usuários (padrão 'nao')
#
# Saída:
#   0  mediu (todos os cenários pedidos produziram uma linha MEDIDA)
#   2  NÃO mediu, ou mediu só parte: pré-condição ausente, erro no SQL, timeout, resíduo.
#      Nunca verde por omissão. Não existe saída 1: este script não julga.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB="${DB_CONTAINER:-supabase_db_frila-backend}"
DB_USER="${DB_USER:-supabase_admin}"
GERADOR="supabase/tests/carga/gerar_casa_pesada.sql"
MEDIDOR="scripts/medir-painel.sql"
AMOSTRAS="${AMOSTRAS:-10}"
AQUECIMENTO="${AQUECIMENTO:-3}"
TIMEOUT_MS="${STATEMENT_TIMEOUT_MS:-600000}"
PERMITIR_BASE_POVOADA="${PERMITIR_BASE_POVOADA:-nao}"
CENARIOS="S1,S2,S3,S4,S5,S6"
SAIDA=""
listar=false

# Cenário = rótulo:janela_em_dias. A casa A (200 vagas x 2 posições x 6 candidatos) serve S1
# e S2; a casa B (1000 x 3 x 10, mais 4 casas extras para o controle) serve S3, S4, S5, S6 e
# S3_membro5. O histórico tem 365 dias e a janela começa no primeiro deles.
CASA_A="200 2 6 0"
CASA_B="1000 3 10 4"

nao_medi() { printf '✗ NÃO MEDI: %s\n' "$1" >&2; exit 2; }
numero() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
pedido() { case ",$CENARIOS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --listar) listar=true; shift ;;
    --cenarios)
      [ -n "${2:-}" ] || nao_medi "--cenarios exige uma lista, por exemplo S1,S2"
      CENARIOS="$2"
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

for r in $(printf '%s' "$CENARIOS" | tr ',' ' '); do
  case "$r" in
    S1|S2|S3|S4|S5|S6) : ;;
    *) nao_medi "cenário desconhecido: '$r' (use S1, S2, S3, S4, S5, S6)" ;;
  esac
done
numero "$AMOSTRAS" && [ "$AMOSTRAS" -ge 1 ] || nao_medi "AMOSTRAS precisa ser um inteiro >= 1 (recebi '$AMOSTRAS')"
numero "$AQUECIMENTO" || nao_medi "AQUECIMENTO precisa ser um inteiro >= 0 (recebi '$AQUECIMENTO')"
numero "$TIMEOUT_MS" || nao_medi "STATEMENT_TIMEOUT_MS precisa ser um inteiro (recebi '$TIMEOUT_MS')"
case "$DB_USER" in ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) nao_medi "DB_USER precisa ser um nome de papel simples (recebi '$DB_USER')" ;; esac
case "$PERMITIR_BASE_POVOADA" in sim|nao) : ;; *) nao_medi "PERMITIR_BASE_POVOADA aceita 'sim' ou 'nao'" ;; esac

if $listar; then
  printf 'rótulo       casa  vagas x posições x candidatos   janela\n'
  printf 'S1           A     200 x 2 x 6                     1 dia\n'
  printf 'S2           A     200 x 2 x 6                     7 dias\n'
  printf 'S3           B     1000 x 3 x 10                   30 dias\n'
  printf 'S3_membro5   B     1000 x 3 x 10                   30 dias, leitor membro de 5 casas\n'
  printf 'S6           B     1000 x 3 x 10                   45 dias\n'
  printf 'S4           B     1000 x 3 x 10                   365 dias\n'
  printf 'S5           B     1000 x 3 x 10                   1825 dias (5 anos)\n'
  printf '(hipótese de volume, não dado de produto)\n'
  exit 0
fi

# ── Pré-condições. Cada uma sai 2, não 0 ──────────────────────────────────────────────
command -v docker >/dev/null 2>&1 || nao_medi "docker não está no PATH"
[ -f "$GERADOR" ] || nao_medi "$GERADOR não existe"
[ -f "$MEDIDOR" ] || nao_medi "$MEDIDOR não existe"
docker inspect -f '{{.State.Running}}' "$DB" 2>/dev/null | grep -q true \
  || nao_medi "o contêiner $DB não está de pé"

psql_() { docker exec -e PGPASSWORD=postgres -i "$DB" psql -U "$DB_USER" -d postgres -X -q "$@"; }

psql_ -At -c 'select 1' >/dev/null 2>&1 \
  || nao_medi "o Postgres em $DB não respondeu como '$DB_USER' (senha, papel ou contêiner; DB_USER=postgres volta ao papel antigo)"

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

versao_pg=$(psql_ -At -c 'show server_version' 2>/dev/null)
superusuario=$(psql_ -At -c 'select rolsuper from pg_roles where rolname = current_user' 2>/dev/null)
commit=$(git rev-parse --short HEAD 2>/dev/null || printf 'desconhecido')

linha() { printf '%s\n' "$*" | tee -a "$relatorio"; }

linha "# medir-painel.sh · $(date '+%Y-%m-%d %H:%M:%S %z')"
linha "commit do repositório: $commit · Postgres $versao_pg · usuários na base antes: $n_usuarios"
linha "papel do psql: $DB_USER (superusuário: ${superusuario:-?}; auto_explain só carrega se for 't')"
linha "amostras=$AMOSTRAS aquecimento=$AQUECIMENTO (mediana e máximo; com $AMOSTRAS amostras não se afirma p95)"
linha "volumes: HIPÓTESE do plano, não dado de produto. Tempo local não transfere para o Prod."
linha ""

# Monta o fluxo de SQL de uma casa: variáveis, begin, gerador, um bloco por cenário, rollback.
# Argumentos: vagas posicoes candidatos extras ae_min_ms "rotulo:janela_dias:ligar_extras"...
montar_sql() {
  local vagas="$1" posicoes="$2" candidatos="$3" extras="$4" ae_ms="$5"
  shift 5
  local spec rotulo janela ligar
  printf '%s\n' '\set ON_ERROR_STOP on' '\set casa_pesada 1'
  printf '\\set vagas %s\n' "$vagas"
  printf '\\set posicoes %s\n' "$posicoes"
  printf '\\set candidatos %s\n' "$candidatos"
  printf '\\set casas_extras %s\n' "$extras"
  printf '\\set permitir_base_povoada %s\n' "$PERMITIR_BASE_POVOADA"
  printf '\\set amostras %s\n' "$AMOSTRAS"
  printf '\\set aquecimento %s\n' "$AQUECIMENTO"
  printf '\\set ae_min_ms %s\n' "$ae_ms"
  printf '%s\n' 'begin;' "set local lock_timeout = '5s';" "set local statement_timeout = '${TIMEOUT_MS}ms';"
  cat "$GERADOR"
  for spec in "$@"; do
    IFS=: read -r rotulo janela ligar <<< "$spec"
    printf '\\set rotulo %s\n' "$rotulo"
    printf '\\set janela_dias %s\n' "$janela"
    printf '\\set ligar_extras %s\n' "$ligar"
    cat "$MEDIDOR"
  done
  printf '%s\n' 'rollback;'
}

# Roda uma casa. stdout (VOLUME_JANELA, explain) vai para $SAIDA/bruto-casa-<nome>.txt e
# stderr (NOTICE, LOG do auto_explain, erros) para $SAIDA/bruto-casa-<nome>.err.txt. Os dois
# ficam em arquivos separados porque o docker exec não garante a ordem entre os fluxos.
# Devolve 0 se o psql terminou sem erro.
rodar_casa() {
  local nome="$1"
  shift
  local bruto="$SAIDA/bruto-casa-$nome.txt" erros="$SAIDA/bruto-casa-$nome.err.txt"
  linha "▸ casa $nome: carregando e medindo dentro de uma transação com rollback..."
  montar_sql "$@" | psql_ -f - > "$bruto" 2> "$erros"
  local rc=${PIPESTATUS[1]}
  if [ "$rc" -ne 0 ] || grep -q 'ERROR:' "$erros" "$bruto"; then
    linha "✗ casa $nome: o SQL terminou com erro (psql saiu $rc). Primeiras linhas do erro:"
    grep -h -m3 -B1 -A3 'ERROR:' "$erros" "$bruto" | sed 's/^/    /' | tee -a "$relatorio" >&2
    return 1
  fi
  return 0
}

# Extrai o trecho entre dois marcadores de um cenário. O marcador tem de ser o FIM da linha:
# "### EXPLAIN_INICIO S3" é prefixo de "### EXPLAIN_INICIO S3_membro5", e uma busca por
# substring misturaria os dois cenários.
trecho() { # arquivo marcador_inicio marcador_fim
  awk -v ini="$2" -v fim="$3" '$0 ~ (ini "$") {on=1; next} $0 ~ (fim "$") {on=0} on' "$1"
}

resumir() { # casa rotulo
  local bruto="$SAIDA/bruto-casa-$1.txt" erros="$SAIDA/bruto-casa-$1.err.txt" rot="$2"
  local plano="$SAIDA/plano-$rot.txt" explain="$SAIDA/explain-$rot.txt"
  trecho "$erros" "### AUTO_EXPLAIN_INICIO $rot" "### AUTO_EXPLAIN_FIM $rot" > "$plano"
  trecho "$bruto" "### EXPLAIN_INICIO $rot" "### EXPLAIN_FIM $rot" > "$explain"

  local medida volume
  medida=$(grep -m1 "MEDIDA rotulo=$rot " "$erros" | sed 's/.*\(MEDIDA rotulo=.*\)$/\1/')
  volume=$(grep -m1 "^VOLUME_JANELA rotulo=$rot " "$bruto")
  if [ -z "$medida" ]; then
    linha "✗ $rot: NÃO MEDIDO (nenhuma linha MEDIDA em $erros)"
    return 1
  fi
  linha "● $rot"
  linha "  $volume"
  linha "  $medida"
  linha "  explain da chamada inteira ($explain):"
  grep -E 'Buffers:|Execution Time:|Planning Time:' "$explain" | sed 's/^/    /' | tee -a "$relatorio"

  if grep -q 'duration:' "$plano"; then
    local n_planos seq_posicao seq_ocorrencia seq_vaga max_loops
    n_planos=$(grep -c 'duration:' "$plano")
    seq_posicao=$(grep -cE 'Seq Scan on (public\.)?posicao\b' "$plano")
    seq_ocorrencia=$(grep -cE 'Seq Scan on (public\.)?ocorrencia\b' "$plano")
    seq_vaga=$(grep -cE 'Seq Scan on (public\.)?vaga\b' "$plano")
    max_loops=$(grep -oE 'loops=[0-9]+' "$plano" | sed 's/loops=//' | sort -n | tail -1)
    linha "  consultas internas (auto_explain, uma chamada extra, $plano):"
    linha "    planos registrados=$n_planos · Seq Scan em posicao=$seq_posicao, ocorrencia=$seq_ocorrencia, vaga=$seq_vaga · maior loops=${max_loops:-0}"
  else
    linha "  consultas internas: NAO MEDIDO (auto_explain não registrou nada; veja AUTO_EXPLAIN_* em $erros)"
  fi
  linha ""
  return 0
}

falhas=0

if pedido S1 || pedido S2; then
  specs_a=()
  pedido S1 && specs_a+=("S1:1:0")
  pedido S2 && specs_a+=("S2:7:0")
  # shellcheck disable=SC2086 # CASA_A é "vagas posicoes candidatos extras", palavras separadas de propósito
  if rodar_casa A $CASA_A "${AUTO_EXPLAIN_MIN_MS:-0}" "${specs_a[@]}"; then
    for spec in "${specs_a[@]}"; do resumir A "${spec%%:*}" || falhas=$((falhas + 1)); done
  else
    falhas=$((falhas + 1))
  fi
fi

if pedido S3 || pedido S4 || pedido S5 || pedido S6; then
  specs_b=()
  pedido S3 && specs_b+=("S3:30:0")
  pedido S6 && specs_b+=("S6:45:0")
  pedido S4 && specs_b+=("S4:365:0")
  pedido S5 && specs_b+=("S5:1825:0")
  # O controle liga as casas extras, então roda por último para não contaminar S4, S5 e S6.
  pedido S3 && specs_b+=("S3_membro5:30:1")
  # shellcheck disable=SC2086 # CASA_B é "vagas posicoes candidatos extras", palavras separadas de propósito
  if rodar_casa B $CASA_B "${AUTO_EXPLAIN_MIN_MS:-1}" "${specs_b[@]}"; then
    for spec in "${specs_b[@]}"; do resumir B "${spec%%:*}" || falhas=$((falhas + 1)); done
  else
    falhas=$((falhas + 1))
  fi
fi

# ── Resíduo: depois do rollback não pode sobrar nada da carga ─────────────────────────
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
linha "relatório e saídas brutas: $SAIDA"
if [ "$falhas" -gt 0 ]; then
  nao_medi "$falhas etapa(s) sem medição completa; veja $relatorio"
fi
exit 0
