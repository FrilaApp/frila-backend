#!/usr/bin/env bash
# Lê e ajusta os parâmetros do despacho (RN05, RN23) sem migração e sem `update` à mão.
#
#   ./scripts/ajustar-parametro-despacho.sh                            lista tudo
#   ./scripts/ajustar-parametro-despacho.sh ler raio_maximo_metros     um valor
#   ./scripts/ajustar-parametro-despacho.sh definir raio_maximo_metros 12000
#   ./scripts/ajustar-parametro-despacho.sh definir raio_maximo_metros 12000 --seco
#   ./scripts/ajustar-parametro-despacho.sh definir raio_maximo_metros 12000 --sim
#
# `--seco` mostra o que faria e não escreve. `--sim` dispensa a confirmação, para uso em
# script; sem ele, a escrita pergunta. A decisão por trás dos valores está em
# `docs/decisoes/D02-parametros-do-despacho.md`, e mudar um número aqui muda o conjunto
# de elegíveis da PRÓXIMA rodada de despacho — não reprocessa notificação já enviada.
#
# Alvo do banco, na ordem: `DATABASE_URL`, se exportada; senão o contêiner local
# (`DB_CONTAINER`, por padrão `supabase_db_frila-backend`), como os outros scripts de
# operação deste repositório.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"
TETO_METROS=200000

uso() {
  cat >&2 <<'TXT'
uso: ajustar-parametro-despacho.sh [ler [<chave>] | definir <chave> <metros> [--seco] [--sim]]

  ler                     lista todos os parâmetros métricos do despacho
  ler <chave>             imprime só o valor, em metros
  definir <chave> <n>     grava o valor (1 a 200000 metros), com confirmação
    --seco                mostra o que faria e não escreve
    --sim                 não pergunta (para uso em script)
TXT
  exit 1
}

psql_q() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 "$@"
  else
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 "$@"
  fi
}

# Host e banco sem credencial, para a confirmação dizer onde vai escrever.
alvo() {
  if [ -n "${DATABASE_URL:-}" ]; then
    python3 - "$DATABASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit
u = urlsplit(sys.argv[1])
print(f"{u.hostname or '?'}:{u.port or 5432}{u.path or ''} (DATABASE_URL)")
PY
  else
    printf 'contêiner %s (banco local)\n' "$DB_CONTAINER"
  fi
}

tabela_existe() {
  [ "$(psql_q -c "select to_regclass('privado.parametro_despacho') is not null")" = "t" ]
}

comando="${1:-ler}"
case "$comando" in
  ler|definir) shift || true ;;
  -h|--help)   uso ;;
  *)           printf '✗ comando desconhecido: %s\n' "$comando" >&2; uso ;;
esac

if ! tabela_existe; then
  printf '✗ privado.parametro_despacho não existe neste banco.\n' >&2
  printf '  Aplique a migração 20261104030000_parametros_despacho_configuraveis.sql antes.\n' >&2
  exit 1
fi

if [ "$comando" = "ler" ]; then
  chave="${1:-}"
  if [ -z "$chave" ]; then
    printf 'Parâmetros do despacho em %s\n' "$(alvo)"
    psql_q -c "select chave || ' = ' || valor_metros || ' m  (' || descricao || ')' from privado.parametro_despacho order by chave"
    exit 0
  fi
  valor="$(psql_q -c "select valor_metros from privado.parametro_despacho where chave = '$(printf '%s' "$chave" | sed "s/'/''/g")'")"
  if [ -z "$valor" ]; then
    printf '✗ chave ausente: %s\n' "$chave" >&2
    printf '  privado.elegiveis cai no padrão da RN05 (15000 m) enquanto ela não existir.\n' >&2
    exit 1
  fi
  printf '%s\n' "$valor"
  exit 0
fi

# ── definir ───────────────────────────────────────────────────────────────────
chave="${1:-}"
valor_novo="${2:-}"
[ -n "$chave" ] || uso
[ -n "$valor_novo" ] || uso
shift 2 || true

seco=0
sim=0
for argumento in "$@"; do
  case "$argumento" in
    --seco) seco=1 ;;
    --sim)  sim=1 ;;
    *)      printf '✗ opção desconhecida: %s\n' "$argumento" >&2; uso ;;
  esac
done

case "$valor_novo" in
  ''|*[!0-9]*)
    printf '✗ valor inválido: %s. O parâmetro é inteiro, em metros.\n' "$valor_novo" >&2
    exit 1 ;;
esac

if [ "$valor_novo" -lt 1 ] || [ "$valor_novo" -gt "$TETO_METROS" ]; then
  printf '✗ fora da faixa: %s m. O aceito é de 1 a %s m.\n' "$valor_novo" "$TETO_METROS" >&2
  printf '  O teto existe porque um zero a mais em 15000 notificaria o país inteiro.\n' >&2
  exit 1
fi

chave_sql="$(printf '%s' "$chave" | sed "s/'/''/g")"
valor_atual="$(psql_q -c "select valor_metros from privado.parametro_despacho where chave = '$chave_sql'")"
if [ -z "$valor_atual" ]; then
  printf '✗ chave ausente: %s. Este script ajusta parâmetro que existe, não cria parâmetro novo.\n' "$chave" >&2
  printf '  Parâmetro novo nasce em migração, com a descrição do que ele decide.\n' >&2
  exit 1
fi

printf 'Alvo:    %s\n' "$(alvo)"
printf 'Chave:   %s\n' "$chave"
printf 'De:      %s m\n' "$valor_atual"
printf 'Para:    %s m\n' "$valor_novo"
printf 'Efeito:  muda o conjunto de elegíveis da próxima rodada de despacho; não reprocessa notificação enviada.\n'

if [ "$valor_atual" = "$valor_novo" ]; then
  printf '● já está nesse valor: nada a fazer.\n'
  exit 0
fi

if [ "$seco" -eq 1 ]; then
  printf '● Ensaio (--seco): nada foi gravado.\n'
  exit 0
fi

if [ "$sim" -ne 1 ]; then
  if [ ! -t 0 ]; then
    printf '✗ sem terminal para confirmar. Use --sim para gravar sem pergunta, ou --seco para ensaiar.\n' >&2
    exit 1
  fi
  printf 'Confirma a gravação? [s/N] '
  read -r resposta
  case "$resposta" in
    s|S|sim|SIM) ;;
    *) printf '● cancelado: nada foi gravado.\n'; exit 0 ;;
  esac
fi

psql_q -c "update privado.parametro_despacho set valor_metros = $valor_novo where chave = '$chave_sql'" >/dev/null
valor_depois="$(psql_q -c "select valor_metros from privado.parametro_despacho where chave = '$chave_sql'")"

if [ "$valor_depois" != "$valor_novo" ]; then
  printf '✗ a gravação não ficou: o banco lê %s m.\n' "$valor_depois" >&2
  exit 1
fi

printf '✓ %s = %s m (era %s m)\n' "$chave" "$valor_depois" "$valor_atual"
printf '  Registre a mudança no cartão e na D02: parâmetro alterado sem registro é número órfão.\n'
