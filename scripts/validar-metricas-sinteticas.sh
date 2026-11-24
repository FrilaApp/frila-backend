#!/usr/bin/env bash
# scripts/validar-metricas-sinteticas.sh
# Valida o MECANISMO das métricas do Frila com dados sintéticos: semeia 10 empregadores, 50 trabalhadores,
# 20 vagas, 80 candidaturas e 15 contratações (com abandono, recusa e desistência), roda os 4 indicadores
# sobre as views `metrica.*` e compara com o que foi semeado. Não mede desempenho real: a amostra é inventada.
#
# O que cada indicador significa e de onde sai: docs/academy/PlanoDeMetricas-Mentor.md.
#
# Uso:
#   ./scripts/validar-metricas-sinteticas.sh              # semeia, mede, compara e desfaz (rollback)
#   ./scripts/validar-metricas-sinteticas.sh --commitar   # grava de verdade e deixa o trap EXIT apagar (exercita a limpeza)
#
# Saída 0: todas as comparações OK e nenhum resíduo. Saída 1: alguma FALHA, erro de SQL ou resíduo no banco.
#
# Segurança: prefixo de ids isolado (fb000000-0000-4000-), nada de `supabase db reset`, trap EXIT que apaga tudo,
# e trava fail-closed contra DATABASE_URL remoto (mesmo padrão de scripts/medir-rnf.sh).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# A senha da DATABASE_URL vai só no ambiente do psql, nunca na linha de comando (B-027.j).
# shellcheck source=/dev/null
. scripts/pg-sem-senha.sh

DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"
st=0
SQL_ARQUIVO="${SQL_ARQUIVO:-scripts/validar-metricas-sinteticas.sql}"
FIM="rollback"

# Trava de segurança: host remoto exige confirmação explícita.
if [ -n "${DATABASE_URL:-}" ]; then
  if ! db_check=$(python3 - <<'PY'
import os, re, sys, urllib.parse
url = os.environ.get("DATABASE_URL", "").strip()
if not url:
    print("local")
    sys.exit(0)

host = ""
try:
    if "://" not in url and re.search(r"\bhost\s*=", url):
        m = re.search(r"\bhost\s*=\s*([^\s;]+)", url)
        if m:
            host = m.group(1)
    else:
        p = urllib.parse.urlparse(url)
        host = p.hostname or ""
        if not host and p.query:
            q = urllib.parse.parse_qs(p.query)
            if "host" in q:
                host = q["host"][0]
except Exception:
    host = ""

host_lower = host.lower() if host else ""
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "docker"}

if host_lower in LOCAL_HOSTS or host_lower.startswith("supabase_db") or host_lower.endswith(".internal"):
    print("local")
    sys.exit(0)

if host_lower.startswith("/") or host_lower.startswith("@/"):
    print("local")
    sys.exit(0)

print(host or "desconhecido/remoto")
sys.exit(1)
PY
); then
    if [ "${EU_SEI_QUE_E_PRODUCAO:-0}" != "1" ]; then
      echo "✗ DATABASE_URL aponta para host remoto ('$db_check'). Este script só semeia dados sintéticos em banco local." >&2
      echo "  Para executar mesmo assim, defina EU_SEI_QUE_E_PRODUCAO=1." >&2
      exit 1
    fi
  fi
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --commitar)
      FIM="commit"
      shift
      ;;
    -h|--ajuda|--help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Opção inválida: $1" >&2
      exit 1
      ;;
  esac
done

[ -f "$SQL_ARQUIVO" ] || { echo "✗ Não achei $SQL_ARQUIVO." >&2; exit 1; }

exec_psql() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql_url "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DB_CONTAINER}$"; then
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
  else
    PGPASSWORD="${PGPASSWORD:-postgres}" psql -h localhost -p 54322 -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
  fi
}

# Apaga a amostra pelo prefixo, na ordem das chaves estrangeiras, e confere que não sobrou nada.
APAGAR_SQL="
delete from public.turno where posicao_id::text like 'fb000000-0000-4000-%';
delete from public.posicao where id::text like 'fb000000-0000-4000-%';
delete from privado.auditoria_ciclo where entidade_id::text like 'fb000000-0000-4000-%';
delete from public.vaga where id::text like 'fb000000-0000-4000-%';
delete from public.membro_estabelecimento where estabelecimento_id::text like 'fb000000-0000-4000-%';
delete from public.estabelecimento where id::text like 'fb000000-0000-4000-%';
delete from public.profissional where id::text like 'fb000000-0000-4000-%';
delete from public.usuario where id::text like 'fb000000-0000-4000-%';
"
RESIDUO_SQL="
select (select count(*) from public.usuario where id::text like 'fb000000-0000-4000-%')
     + (select count(*) from public.profissional where id::text like 'fb000000-0000-4000-%')
     + (select count(*) from public.estabelecimento where id::text like 'fb000000-0000-4000-%')
     + (select count(*) from public.membro_estabelecimento where estabelecimento_id::text like 'fb000000-0000-4000-%')
     + (select count(*) from public.vaga where id::text like 'fb000000-0000-4000-%')
     + (select count(*) from public.posicao where id::text like 'fb000000-0000-4000-%')
     + (select count(*) from public.candidatura where id::text like 'fb000000-0000-4000-%')
     + (select count(*) from public.turno where id::text like 'fb000000-0000-4000-%')
     + (select count(*) from privado.auditoria_ciclo where entidade_id::text like 'fb000000-0000-4000-%');
"

TMP_SAIDA=""
# shellcheck disable=SC2329
limpar() {
  local status_saida="${1:-$?}" antes residuo
  [ -n "$TMP_SAIDA" ] && rm -f "$TMP_SAIDA"
  antes=$(exec_psql -At -c "$RESIDUO_SQL")
  if ! exec_psql -c "$APAGAR_SQL" >/dev/null; then
    echo "✗ Erro ao apagar a amostra sintética do banco." >&2
    exit 1
  fi
  residuo=$(exec_psql -At -c "$RESIDUO_SQL")
  if [ "$residuo" != "0" ]; then
    echo "✗ Resíduo da amostra sintética no banco: $residuo linha(s)." >&2
    exit 1
  fi
  echo "Limpeza: $antes linha(s) com o prefixo fb000000-0000-4000- antes de apagar, 0 depois."
  exit "$status_saida"
}
trap 'st=$?; limpar "$st"' EXIT

echo "================================================================================"
echo "     FRILA — VALIDAÇÃO SINTÉTICA DAS MÉTRICAS (valida o mecanismo, não o desempenho)"
echo "================================================================================"
ativas=$(exec_psql -At -c "select count(*) from pg_stat_activity where datname = current_database() and state = 'active' and pid <> pg_backend_pid()")
echo "Consultas ativas de outras sessões no banco: $ativas (o banco local é compartilhado)"
echo "Modo: $FIM"
echo ""

# Se uma execução anterior morreu no meio, começa limpo (o prefixo é só desta amostra).
exec_psql -c "$APAGAR_SQL" >/dev/null

TMP_SAIDA=$(mktemp)
exec_psql -v "fim=$FIM" <"$SQL_ARQUIVO" >"$TMP_SAIDA"
cat "$TMP_SAIDA"

echo ""
if grep -q "FALHA" "$TMP_SAIDA"; then
  echo "✗ Alguma comparação deu FALHA: o que as views contam não bate com o que foi semeado." >&2
  exit 1
fi
oks=$(grep -c "| OK" "$TMP_SAIDA" || true)
echo "✓ $oks comparações OK, nenhuma FALHA."
exit 0
