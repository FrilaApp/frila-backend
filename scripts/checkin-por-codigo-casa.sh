#!/usr/bin/env bash
# Consulta o estado do check-in por código para um estabelecimento específico (RN46).
#
# Ferramenta estritamente de leitura (auditoria operacional).
# Inclusão e remoção de estabelecimentos no piloto ocorrem exclusivamente via migração
# linear forward-only (com PR, revisão e CI), conforme modelos em docs/operacao/templates/.
#
# Uso:
#   ./scripts/checkin-por-codigo-casa.sh estado <estabelecimento_id>
#
# Alvo do banco:
#   DATABASE_URL se exportada; senão o contêiner local (${DB_CONTAINER:-supabase_db_frila-backend}).
#   Credenciais e segredos nunca são impressos no terminal ou logs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"

uso() {
  cat >&2 <<'TXT'
uso: checkin-por-codigo-casa.sh estado <estabelecimento_id>

Comandos:
  estado <uuid>      consulta o estado do recurso para o estabelecimento (somente leitura)

Opções:
  -h, --help         mostra esta ajuda

Nota: Por governança e LGPD, casas entram e saem do check-in por código
exclusivamente via migração linear forward-only no repositório.
Consulte o roteiro completo em docs/operacao/checkin-por-codigo-casa.md.
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

# Alvo sem segredos/senhas para exibição segura
alvo() {
  if [ -n "${DATABASE_URL:-}" ]; then
    python3 - "$DATABASE_URL" <<'PY'
import sys
from urllib.parse import urlsplit
u = urlsplit(sys.argv[1])
host = u.hostname or '?'
port = f":{u.port}" if u.port else ""
path = u.path or ''
print(f"{host}{port}{path} (DATABASE_URL)")
PY
  else
    printf 'contêiner %s (banco local)\n' "$DB_CONTAINER"
  fi
}

validar_uuid() {
  local id="$1"
  if ! [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    printf '✗ UUID inválido para estabelecimento_id: %s\n' "$id" >&2
    exit 1
  fi
}

obter_nome_estabelecimento() {
  local id="$1"
  local id_escapado
  id_escapado="$(printf '%s' "$id" | sed "s/'/''/g")"
  psql_q -c "select nome from public.estabelecimento where id = '$id_escapado'"
}

verificar_tabelas() {
  local res
  res="$(psql_q -c "
    select (to_regclass('privado.recurso') is not null
            and to_regclass('privado.recurso_estabelecimento') is not null
            and to_regclass('privado.recurso_versao_minima') is not null)::text
  ")"
  if [ "$res" != "true" ]; then
    printf '✗ Tabelas de controle de recurso não encontradas neste banco.\n' >&2
    printf '  Aplique as migrações 20261108150000, 20261109101000 e 20261111203000 antes.\n' >&2
    exit 1
  fi
}

ler_estado() {
  local id="$1"
  local id_escapado
  id_escapado="$(printf '%s' "$id" | sed "s/'/''/g")"
  psql_q -c "
    select coalesce((select ligado::text from privado.recurso where chave = 'checkin_por_codigo'), 'false')
           || '|' ||
           coalesce((select versao_minima from privado.recurso_versao_minima where recurso = 'checkin_por_codigo' and plataforma = 'ios'), 'ausente')
           || '|' ||
           exists(select 1 from privado.recurso_estabelecimento where chave = 'checkin_por_codigo' and estabelecimento_id = '$id_escapado')::text
           || '|' ||
           privado.recurso_ligado_para('checkin_por_codigo', '$id_escapado')::text
  "
}

exibir_estado_formatado() {
  local raw="$1"
  local global v_ios na_casa consolidado
  IFS='|' read -r global v_ios na_casa consolidado <<< "$raw"

  if [ "$consolidado" = "true" ]; then
    printf '  Estado consolidado: ATIVO (check-in por código em vigor para esta casa)\n'
  else
    printf '  Estado consolidado: INATIVO (fluxo legado em vigor para esta casa)\n'
  fi
  printf '    • Chave global (privado.recurso):                  %s\n' "$([ "$global" = "true" ] && echo "ligada (true)" || echo "desligada ($global)")"
  printf '    • Versão mínima iOS (privado.recurso_versao_minima): %s\n' "$v_ios"
  printf '    • Casa no piloto (privado.recurso_estabelecimento):  %s\n' "$([ "$na_casa" = "true" ] && echo "cadastrada (true)" || echo "não cadastrada (false)")"
}

# ── Parse de Argumentos ────────────────────────────────────────────────────────

[ $# -ge 1 ] || uso

case "$1" in
  -h|--help)
    uso
    ;;
  ligar|desligar)
    printf '✗ O comando '\''%s'\'' não é permitido via script: casas entram e saem do piloto\n' "$1" >&2
    printf '  exclusivamente por migração com PR, revisão e CI.\n' >&2
    printf '  Consulte os templates em docs/operacao/templates/ e o roteiro em docs/operacao/checkin-por-codigo-casa.md.\n' >&2
    exit 1
    ;;
  estado)
    ;;
  *)
    printf '✗ Comando desconhecido: %s\n' "$1" >&2
    uso
    ;;
esac

[ $# -eq 2 ] || uso
estab_id="$2"

validar_uuid "$estab_id"
verificar_tabelas

estab_nome="$(obter_nome_estabelecimento "$estab_id")"
if [ -z "$estab_nome" ]; then
  printf '✗ Estabelecimento não encontrado: %s\n' "$estab_id" >&2
  printf '  Verifique o ID em public.estabelecimento em %s.\n' "$(alvo)" >&2
  exit 1
fi

printf 'Estabelecimento: %s (%s)\n' "$estab_nome" "$estab_id"
printf 'Alvo: %s\n' "$(alvo)"
raw_estado="$(ler_estado "$estab_id")"
exibir_estado_formatado "$raw_estado"
exit 0
