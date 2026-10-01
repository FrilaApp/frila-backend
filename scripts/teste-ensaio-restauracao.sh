#!/usr/bin/env bash
# Autoteste do script de ensaio de restauração (`scripts/ensaio-restauracao.sh`).
#
# Valida:
#   1. Flag --help: saída amigável e código 0;
#   2. Flag --apenas-dump: geração isolada de schema.sql e dados.sql em pasta temporária;
#   3. Flag --sem-pgtap: restauração e contagem de tabelas sem executar a suíte pgTAP;
#   4. Execução completa ponta a ponta: dump, cifra, decifra, restauração e pgTAP com SUCESSO;
#   5. Idempotência e limpeza: o banco temporário frila_ensaio_restauracao é removido ao final.
#
# Uso:
#   ./scripts/teste-ensaio-restauracao.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SCRIPT="./scripts/ensaio-restauracao.sh"
[ -x "$SCRIPT" ] || { echo "ERRO: Script $SCRIPT não encontrado ou sem permissão de execução." >&2; exit 1; }

echo "=== Autoteste: Ensaio de Restauração (mwdFSEHe) ==="

# 1. Flag --help
echo -n "  1. Testando flag --help... "
saida=$("$SCRIPT" --help)
echo "$saida" | grep -q "Uso: ./scripts/ensaio-restauracao.sh" || {
  echo "FALHOU: Saída de help inesperada." >&2
  exit 1
}
echo "OK"

# 2. Flag --apenas-dump
echo -n "  2. Testando flag --apenas-dump em diretório dedicado... "
TMP_DUMP=$(mktemp -d "/tmp/frila-teste-dump.XXXXXX")
trap 'rm -rf "$TMP_DUMP"' EXIT
"$SCRIPT" --apenas-dump --dir-dump "$TMP_DUMP" >/dev/null

[ -s "$TMP_DUMP/schema.sql" ] || { echo "FALHOU: schema.sql não foi gerado ou está vazio." >&2; exit 1; }
[ -s "$TMP_DUMP/dados.sql" ] || { echo "FALHOU: dados.sql não foi gerado ou está vazio." >&2; exit 1; }
[ -s "$TMP_DUMP/auth_schema.sql" ] || { echo "FALHOU: auth_schema.sql não foi gerado." >&2; exit 1; }
echo "OK (arquivos de schema e dados gerados com sucesso)"

# 3. Flag --sem-pgtap com dump pré-existente
echo -n "  3. Testando restauração com --sem-pgtap... "
saida=$("$SCRIPT" --sem-pgtap --dir-dump "$TMP_DUMP" --dump-schema "$TMP_DUMP/schema.sql" --dump-dados "$TMP_DUMP/dados.sql")
echo "$saida" | grep -q "SUCESSO (100% íntegro)" || {
  echo "FALHOU: Restauração com --sem-pgtap não concluiu com sucesso." >&2
  exit 1
}
echo "$saida" | grep -q "Validação pgTAP ignorada por parâmetro" || {
  echo "FALHOU: Mensagem de pgTAP ignorado não encontrada." >&2
  exit 1
}
echo "OK"

# 4. Execução completa ponta a ponta
echo -n "  4. Testando execução completa ponta a ponta com pgTAP... "
saida_completa=$("$SCRIPT")
echo "$saida_completa" | grep -q "SUCESSO (100% íntegro)" || {
  echo "FALHOU: Execução completa não acusou SUCESSO." >&2
  exit 1
}
echo "$saida_completa" | grep -q "TOTAL DE LINHAS RESTAURADAS" || {
  echo "FALHOU: Total de linhas não computado." >&2
  exit 1
}
echo "$saida_completa" | grep -q "pgTAP de integridade do banco restaurado passou com sucesso" || {
  echo "FALHOU: Validação pgTAP não passou." >&2
  exit 1
}
echo "OK"

# 5. Verifica se o banco temporário foi limpo
echo -n "  5. Conferindo limpeza do banco temporário... "
DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"
if docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'frila_ensaio_restauracao';" | grep -q "1"; then
  echo "FALHOU: Banco frila_ensaio_restauracao ainda existe após término!" >&2
  exit 1
fi
echo "OK (banco temporário limpo)"

echo ""
echo "Todos os 5 casos do autoteste do ensaio de restauração passaram com sucesso!"
