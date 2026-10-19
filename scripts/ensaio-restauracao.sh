#!/usr/bin/env bash
# Ensaio de restauração de backup lógico e verificação de integridade (Cartão mwdFSEHe).
#
# Executa o ciclo de contingência e recuperação do Frila:
#   1. Gera o dump de esquema e dados (ou consome dump existente via parâmetros);
#   2. Cifra o pacote com AES-256 (OpenSSL) e valida decifragem (chave fora do repositório);
#   3. Cria banco temporário de ensaio (`frila_ensaio_restauracao`);
#   4. Restaura esquemas e dados;
#   5. Conta linhas por tabela em todos os esquemas da aplicação e valida integridade;
#   6. Executa bateria de testes pgTAP no banco restaurado;
#   7. Mede e documenta o tempo gasto de restauração para anotação no cartão;
#   8. Limpa o banco e arquivos temporários (salvo com --manter-banco).
#
# Uso:
#   ./scripts/ensaio-restauracao.sh                     # Ensaio completo ponta a ponta
#   ./scripts/ensaio-restauracao.sh --apenas-dump      # Só gera os arquivos de dump
#   ./scripts/ensaio-restauracao.sh --sem-pgtap        # Pula pgTAP completo, roda só contagem
#   ./scripts/ensaio-restauracao.sh --manter-banco     # Mantém o banco temporário após o teste
#   ./scripts/ensaio-restauracao.sh --dir-dump <dir>   # Salva ou lê dump de diretório específico
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"
DB_PORT="${DB_PORT:-54322}"
DB_ORIGEM="${DB_ORIGEM:-postgres}"
DB_ENSAIO="${DB_ENSAIO:-frila_ensaio_restauracao}"

APENAS_DUMP=0
APENAS_RESTAURAR=0
SEM_PGTAP=0
COMPARAR_ORIGEM=0
MANTER_BANCO=0
DIR_DUMP=""
ARQ_SCHEMA=""
ARQ_DADOS=""
CHAVE_CIFRA="${BACKUP_ENCRYPTION_KEY:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --apenas-dump)      APENAS_DUMP=1; shift ;;
    --apenas-restaurar) APENAS_RESTAURAR=1; shift ;;
    --sem-pgtap)        SEM_PGTAP=1; shift ;;
    --comparar-origem)  COMPARAR_ORIGEM=1; shift ;;
    --manter-banco)     MANTER_BANCO=1; shift ;;
    --dir-dump)         DIR_DUMP="${2:?uso: --dir-dump <caminho>}"; shift 2 ;;
    --dump-schema)      ARQ_SCHEMA="${2:?uso: --dump-schema <caminho>}"; shift 2 ;;
    --dump-dados)       ARQ_DADOS="${2:?uso: --dump-dados <caminho>}"; shift 2 ;;
    --banco-ensaio)     DB_ENSAIO="${2:?uso: --banco-ensaio <nome>}"; shift 2 ;;
    --chave-cifra)      CHAVE_CIFRA="${2:?uso: --chave-cifra <chave>}"; shift 2 ;;
    -h|--help)
      echo "Uso: ./scripts/ensaio-restauracao.sh [opções]"
      echo "  --apenas-dump       Gera os arquivos de dump e encerra"
      echo "  --apenas-restaurar  Restaura a partir dos dumps informados"
      echo "  --sem-pgtap         Pula a execução da suíte pgTAP"
      echo "  --comparar-origem   Com --apenas-restaurar, compara a contagem com a origem também"
      echo "  --manter-banco      Não exclui o banco $DB_ENSAIO ao final"
      echo "  --dir-dump <dir>    Diretório de saída/leitura dos dumps"
      echo "  --dump-schema <arq> Caminho do arquivo de schema"
      echo "  --dump-dados <arq>  Caminho do arquivo de dados"
      echo "  --banco-ensaio <n>  Nome do banco temporário (padrão: frila_ensaio_restauracao)"
      exit 0
      ;;
    *)
      echo "Opção desconhecida: $1" >&2
      exit 2
      ;;
  esac
done

case "$DB_ENSAIO" in
  frila_ensaio*) ;;
  *) echo "ERRO: o banco de ensaio precisa começar com 'frila_ensaio' (ele é apagado ao final): $DB_ENSAIO" >&2; exit 2 ;;
esac

# Garante que o container Postgres local está no ar
if ! docker exec -i "$DB_CONTAINER" psql -U postgres -d "$DB_ORIGEM" -tAc "SELECT 1" >/dev/null 2>&1; then
  echo "ERRO: Container Postgres local '$DB_CONTAINER' não está acessível." >&2
  echo "Execute 'supabase start' a partir da raiz do repositório antes de rodar o ensaio." >&2
  exit 1
fi

TMP_CRIADO=0
if [ -z "$DIR_DUMP" ]; then
  DIR_DUMP=$(mktemp -d "/tmp/frila-backup-ensaio.XXXXXX")
  TMP_CRIADO=1
else
  mkdir -p "$DIR_DUMP"
fi

limpar() {
  local exit_code=$?
  if [ "$MANTER_BANCO" -eq 0 ] && [ "$APENAS_DUMP" -eq 0 ]; then
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS $DB_ENSAIO;" >/dev/null 2>&1 || true
  fi
  if [ "$TMP_CRIADO" -eq 1 ] && [ -d "$DIR_DUMP" ]; then
    rm -rf "$DIR_DUMP"
  fi
  exit "$exit_code"
}
trap limpar EXIT

T_INICIO=$(date +%s)
T_DUMP_DURACAO=0
T_CIFRA_DURACAO=0
T_REST_DURACAO=0
T_PGTAP_DURACAO=0

echo "================================================================================"
echo "  Frila Backend — Ensaio de Restauração de Backup Lógico (mwdFSEHe)"
echo "  Data/Hora: $(date -u '+%Y-%m-%d %H:%M:%SZ') | Executor: ${USER:-operador}"
echo "================================================================================"

# ------------------------------------------------------------------------------
# 1. GERAÇÃO DO DUMP
# ------------------------------------------------------------------------------
if [ "$APENAS_RESTAURAR" -eq 0 ]; then
  echo ""
  echo "--> [1/5] Gerando dump lógico do banco '$DB_ORIGEM'..."
  T0=$(date +%s)

  ARQ_SCHEMA="$DIR_DUMP/schema.sql"
  ARQ_DADOS="$DIR_DUMP/dados.sql"
  ARQ_AUTH_SCHEMA="$DIR_DUMP/auth_schema.sql"
  ARQ_AUTH_DADOS="$DIR_DUMP/auth_dados.sql"

  # Dump dos schemas da aplicação (public, privado, metrica, requisicao)
  if command -v supabase >/dev/null 2>&1; then
    supabase db dump --local -s public,privado,metrica,requisicao -f "$ARQ_SCHEMA" >/dev/null
    supabase db dump --local --data-only -s public,privado,metrica,requisicao -f "$ARQ_DADOS" >/dev/null
  else
    docker exec -i "$DB_CONTAINER" pg_dump -U postgres -d "$DB_ORIGEM" \
      --schema=public --schema=privado --schema=metrica --schema=requisicao \
      --schema-only > "$ARQ_SCHEMA"
    docker exec -i "$DB_CONTAINER" pg_dump -U postgres -d "$DB_ORIGEM" \
      --schema=public --schema=privado --schema=metrica --schema=requisicao \
      --data-only --column-inserts > "$ARQ_DADOS"
  fi

  # Dump do schema auth para preservar integridade de chaves estrangeiras
  docker exec -i "$DB_CONTAINER" pg_dump -U postgres -d "$DB_ORIGEM" \
    --schema=auth --schema-only > "$ARQ_AUTH_SCHEMA"
  docker exec -i "$DB_CONTAINER" pg_dump -U postgres -d "$DB_ORIGEM" \
    --schema=auth --data-only --column-inserts > "$ARQ_AUTH_DADOS"

  T1=$(date +%s)
  T_DUMP_DURACAO=$((T1 - T0))

  TAM_SCHEMA=$(wc -c < "$ARQ_SCHEMA" | tr -d ' ')
  TAM_DADOS=$(wc -c < "$ARQ_DADOS" | tr -d ' ')
  SHA_SCHEMA=$(shasum -a 256 "$ARQ_SCHEMA" | awk '{print $1}')
  SHA_DADOS=$(shasum -a 256 "$ARQ_DADOS" | awk '{print $1}')

  echo "    ✓ Schema dump: $TAM_SCHEMA bytes (SHA-256: ${SHA_SCHEMA:0:16}...)"
  echo "    ✓ Dados dump:  $TAM_DADOS bytes (SHA-256: ${SHA_DADOS:0:16}...)"
  echo "    Tempo de dump: ${T_DUMP_DURACAO}s"

  if [ "$APENAS_DUMP" -eq 1 ]; then
    echo "Dump concluído com sucesso em $DIR_DUMP."
    exit 0
  fi
else
  echo ""
  echo "--> [1/5] Utilizando dumps pré-existentes fornecidos por parâmetro..."
  [ -f "${ARQ_SCHEMA:?informe --dump-schema}" ] || { echo "Arquivo de schema não encontrado: $ARQ_SCHEMA" >&2; exit 1; }
  [ -f "${ARQ_DADOS:?informe --dump-dados}" ] || { echo "Arquivo de dados não encontrado: $ARQ_DADOS" >&2; exit 1; }
  # Restaurar um dump é restaurar o dump: o auth também vem do diretório, e não do banco vivo.
  ARQ_AUTH_SCHEMA="$DIR_DUMP/auth_schema.sql"
  ARQ_AUTH_DADOS="$DIR_DUMP/auth_dados.sql"
  for a in "$ARQ_AUTH_SCHEMA" "$ARQ_AUTH_DADOS"; do
    [ -f "$a" ] || { echo "Arquivo do auth não encontrado em --dir-dump: $a" >&2; exit 1; }
  done
fi

# ------------------------------------------------------------------------------
# 2. PROVA DE CIFRA E INTEGRIDADE (Critério 3: Dump cifrado com chave fora do repo)
# ------------------------------------------------------------------------------
echo ""
echo "--> [2/5] Testando empacotamento cifrado (AES-256-CBC via OpenSSL)..."
T0=$(date +%s)
CHAVE="${CHAVE_CIFRA:-$(openssl rand -hex 32)}"
PACOTE_TAR="$DIR_DUMP/frila-backup.tar.gz"
PACOTE_ENC="$DIR_DUMP/frila-backup.tar.gz.enc"
PACOTE_DEC="$DIR_DUMP/frila-backup-decifrado.tar.gz"

tar -czf "$PACOTE_TAR" -C "$DIR_DUMP" "$(basename "$ARQ_SCHEMA")" "$(basename "$ARQ_DADOS")" auth_schema.sql auth_dados.sql
openssl enc -aes-256-cbc -salt -pbkdf2 -in "$PACOTE_TAR" -out "$PACOTE_ENC" -pass "pass:$CHAVE"
openssl enc -d -aes-256-cbc -pbkdf2 -in "$PACOTE_ENC" -out "$PACOTE_DEC" -pass "pass:$CHAVE"

SHA_ORIG=$(shasum -a 256 "$PACOTE_TAR" | awk '{print $1}')
SHA_DEC=$(shasum -a 256 "$PACOTE_DEC" | awk '{print $1}')

if [ "$SHA_ORIG" != "$SHA_DEC" ]; then
  echo "ERRO: O pacote decifrado divergiu do original! Cifragem inconsistente." >&2
  exit 1
fi

T1=$(date +%s)
T_CIFRA_DURACAO=$((T1 - T0))
echo "    ✓ Pacote cifrado com sucesso (${T_CIFRA_DURACAO}s, SHA-256 íntegro após decifragem)"

# ------------------------------------------------------------------------------
# 3. RESTAURAÇÃO NO BANCO DE ENSAIO
# ------------------------------------------------------------------------------
echo ""
echo "--> [3/5] Restaurando no banco temporário de ensaio '$DB_ENSAIO'..."
T0=$(date +%s)

# Recria o banco temporário
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS $DB_ENSAIO;" >/dev/null 2>&1
docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -c "CREATE DATABASE $DB_ENSAIO WITH TEMPLATE template1;" >/dev/null

# Inicializa extensões de plataforma do Supabase no banco de ensaio
docker exec -i "$DB_CONTAINER" psql -U postgres -d "$DB_ENSAIO" -v ON_ERROR_STOP=1 << 'EOF' >/dev/null 2>&1
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS vault;
CREATE SCHEMA IF NOT EXISTS graphql;
CREATE SCHEMA IF NOT EXISTS realtime;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
END $$;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pgcrypto" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "btree_gist" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "citext" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "postgis" SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pgmq" CASCADE;
CREATE EXTENSION IF NOT EXISTS pgtap SCHEMA extensions;
EOF

# Aplica schema e dados. Erros de restauração não derrubam o psql (extensões e papéis do
# Supabase geram avisos esperados), mas vão para um log e a conferência abaixo compara a
# contagem de linhas com a origem: restauração que perde dado não passa calada.
LOG_REST="$DIR_DUMP/restauracao.log"
: > "$LOG_REST"
for arq in "$ARQ_AUTH_SCHEMA" "$ARQ_SCHEMA" "$ARQ_AUTH_DADOS" "$ARQ_DADOS"; do
  docker exec -i "$DB_CONTAINER" psql -U postgres -d "$DB_ENSAIO" -v ON_ERROR_STOP=0 < "$arq" \
    >/dev/null 2>>"$LOG_REST" || true
done
ERROS_REST=$(grep -c "ERROR:" "$LOG_REST" || true)

T1=$(date +%s)
T_REST_DURACAO=$((T1 - T0))
echo "    ✓ Esquemas e dados carregados com sucesso em ${T_REST_DURACAO}s"

# ------------------------------------------------------------------------------
# 4. VALIDAÇÃO DE CONTAGEM DE LINHAS POR TABELA
# ------------------------------------------------------------------------------
echo ""
echo "--> [4/5] Conferindo contagem de linhas das tabelas restauradas..."
TABELAS_REST=$(docker exec -i "$DB_CONTAINER" psql -U postgres -d "$DB_ENSAIO" -tAc "
SELECT count(*) FROM information_schema.tables
WHERE table_schema IN ('public', 'privado', 'metrica', 'requisicao')
  AND table_type = 'BASE TABLE';
")

echo "    Tabelas base encontradas: $TABELAS_REST"
echo ""
printf "    %-42s %s\n" "TABELA" "LINHAS"
printf "    %-42s %s\n" "------------------------------------------" "------"

read -r -d '' SQL_CONTAGEM <<'SQLEND' || true
CREATE OR REPLACE FUNCTION pg_temp.contar_tabelas()
RETURNS TABLE (tabela text, linhas bigint) LANGUAGE plpgsql AS $$
DECLARE
  r RECORD;
  c bigint;
BEGIN
  FOR r IN (
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_schema IN ('public', 'privado', 'metrica', 'requisicao')
      AND table_type = 'BASE TABLE'
    ORDER BY 1, 2
  ) LOOP
    EXECUTE format('SELECT count(*) FROM %I.%I', r.table_schema, r.table_name) INTO c;
    tabela := r.table_schema || '.' || r.table_name;
    linhas := c;
    RETURN NEXT;
  END LOOP;
END $$;
SELECT tabela || '|' || linhas FROM pg_temp.contar_tabelas() ORDER BY 1;
SQLEND
contar() {  # contar <banco>: linhas "schema.tabela|n", sem as mensagens do DDL
  printf '%s\n' "$SQL_CONTAGEM" | docker exec -i "$DB_CONTAINER" psql -U postgres -d "$1" -tA \
    | grep '|' || true
}

CONTAGEM_SAIDA=$(contar "$DB_ENSAIO")

TOTAL_LINHAS=0
while IFS='|' read -r tab cnt; do
  [ -n "$tab" ] || continue
  # Ignora mensagens de DDL
  [ "$tab" != "CREATE FUNCTION" ] || continue
  printf "    %-42s %d\n" "$tab" "$cnt"
  TOTAL_LINHAS=$((TOTAL_LINHAS + cnt))
done <<< "$CONTAGEM_SAIDA"

printf "    %-42s %s\n" "------------------------------------------" "------"
printf "    %-42s %d\n" "TOTAL DE LINHAS RESTAURADAS" "$TOTAL_LINHAS"

if [ "$APENAS_RESTAURAR" -eq 0 ] || [ "$COMPARAR_ORIGEM" -eq 1 ]; then
  CONTAGEM_ORIGEM=$(contar "$DB_ORIGEM")
  if [ "$CONTAGEM_ORIGEM" != "$CONTAGEM_SAIDA" ]; then
    echo "ERRO: a contagem de linhas restaurada diverge da origem ('$DB_ORIGEM')." >&2
    diff <(printf '%s\n' "$CONTAGEM_ORIGEM") <(printf '%s\n' "$CONTAGEM_SAIDA") | sed 's/^/    /' >&2 || true
    echo "    Erros do psql na restauração: $ERROS_REST (veja $LOG_REST)" >&2
    exit 1
  fi
  echo "    ✓ Contagem por tabela idêntica à origem (erros de psql na restauração: $ERROS_REST)"
fi

if [ "$TABELAS_REST" -lt 20 ]; then
  echo "ERRO: Quantidade de tabelas restauradas ($TABELAS_REST) abaixo do esperado!" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# 5. EXECUÇÃO DE SUÍTE PGTAP NO BANCO RESTAURADO
# ------------------------------------------------------------------------------
if [ "$SEM_PGTAP" -eq 0 ]; then
  echo ""
  echo "--> [5/5] Executando validação pgTAP contra o banco restaurado..."
  T0=$(date +%s)

  # Executa bateria de pgTAP contra o banco de ensaio
  TEST_RESULT=$(docker exec -i "$DB_CONTAINER" psql -U postgres -d "$DB_ENSAIO" -v ON_ERROR_STOP=1 << 'EOF'
BEGIN;
SELECT plan(6);

-- 1. Verifica schemas
SELECT has_schema('public', 'schema public existe');
SELECT has_schema('privado', 'schema privado existe');
SELECT has_schema('metrica', 'schema metrica existe');

-- 2. Verifica tabelas nucleares
SELECT has_table('public', 'usuario', 'tabela public.usuario operacional');
SELECT has_table('public', 'vaga', 'tabela public.vaga operacional');
SELECT has_table('public', 'posicao', 'tabela public.posicao operacional');

SELECT * FROM finish();
ROLLBACK;
EOF
  )
  T1=$(date +%s)
  T_PGTAP_DURACAO=$((T1 - T0))

  echo "$TEST_RESULT" | sed 's/^/    /'
  if printf '%s\n' "$TEST_RESULT" | grep -Eq '^not ok|Looks like you failed'; then
    echo "ERRO: asserção pgTAP falhou no banco restaurado." >&2
    exit 1
  fi

  if [ -f "supabase/tests/000_estrutura.sql" ]; then
    echo "    Executando 000_estrutura.sql no banco restaurado..."
    SAIDA_TESTE=$(docker exec -i "$DB_CONTAINER" psql -U postgres -d "$DB_ENSAIO" -v ON_ERROR_STOP=1 < supabase/tests/000_estrutura.sql 2>&1) || {
      printf '%s\n' "$SAIDA_TESTE" | tail -20 | sed 's/^/    /' >&2
      echo "ERRO: 000_estrutura.sql abortou no banco restaurado." >&2
      exit 1
    }
    if printf '%s\n' "$SAIDA_TESTE" | grep -Eq '^not ok|Looks like you failed'; then
      printf '%s\n' "$SAIDA_TESTE" | grep -E '^not ok|Looks like' | sed 's/^/    /' >&2
      echo "ERRO: asserção pgTAP falhou em 000_estrutura.sql no banco restaurado." >&2
      exit 1
    fi
    echo "    ✓ 000_estrutura.sql passou (todas as tabelas e colunas conferidas)"
  fi

  if [ -f "supabase/tests/005_rls_fechado.sql" ]; then
    echo "    Executando 005_rls_fechado.sql no banco restaurado..."
    SAIDA_TESTE=$(docker exec -i "$DB_CONTAINER" psql -U postgres -d "$DB_ENSAIO" -v ON_ERROR_STOP=1 < supabase/tests/005_rls_fechado.sql 2>&1) || {
      printf '%s\n' "$SAIDA_TESTE" | tail -20 | sed 's/^/    /' >&2
      echo "ERRO: 005_rls_fechado.sql abortou no banco restaurado." >&2
      exit 1
    }
    if printf '%s\n' "$SAIDA_TESTE" | grep -Eq '^not ok|Looks like you failed'; then
      printf '%s\n' "$SAIDA_TESTE" | grep -E '^not ok|Looks like' | sed 's/^/    /' >&2
      echo "ERRO: asserção pgTAP falhou em 005_rls_fechado.sql no banco restaurado." >&2
      exit 1
    fi
    echo "    ✓ 005_rls_fechado.sql passou (RLS ativo e seguro em todas as tabelas)"
  fi

  echo "    ✓ pgTAP de integridade do banco restaurado passou com sucesso (${T_PGTAP_DURACAO}s)"
else
  echo ""
  echo "--> [5/5] Validação pgTAP ignorada por parâmetro (--sem-pgtap)."
fi

T_FIM=$(date +%s)
T_TOTAL=$((T_FIM - T_INICIO))

echo ""
echo "================================================================================"
echo "  RESULTADO DO ENSAIO DE RESTAURAÇÃO (mwdFSEHe)"
echo "================================================================================"
echo "  Status da Restauração:     SUCESSO"
if [ "$SEM_PGTAP" -eq 0 ]; then echo "  Validação pgTAP:           executada e sem falhas"; else echo "  Validação pgTAP:           IGNORADA (--sem-pgtap)"; fi
echo "  Executor:                  ${USER:-operador}"
echo "  Tabelas Restauradas:       $TABELAS_REST tabelas"
echo "  Total de Linhas:           $TOTAL_LINHAS linhas"
echo "  Tempo de Dump:             ${T_DUMP_DURACAO}s"
echo "  Tempo de Cifra/Decifra:    ${T_CIFRA_DURACAO}s"
echo "  Tempo de Restauração:      ${T_REST_DURACAO}s"
echo "  Tempo de Validação:        ${T_PGTAP_DURACAO}s"
echo "  Tempo Total de Ensaio:     ${T_TOTAL}s"
echo "================================================================================"
echo ""
