#!/bin/bash
# Teste automatizado de sanitização de stderr e relatório de erro do backup lógico.
# Valida que credenciais (URLs, senhas, parâmetros) nunca vazam no stderr ou no GITHUB_STEP_SUMMARY.
set -Eeuo pipefail
umask 077
export LC_ALL=C
cd "$(dirname "${BASH_SOURCE[0]}")/.."

diretorio_teste=''
limpar() {
  local codigo=$?
  if [[ -n "$diretorio_teste" && -d "$diretorio_teste" ]]; then
    rm -rf -- "$diretorio_teste" 2>/dev/null || true
  fi
  exit "$codigo"
}
trap limpar EXIT INT TERM

falhar() {
  printf 'ERRO [teste-backup-logico-sanitizacao]: %s\n' "$1" >&2
  exit 1
}

printf '=== Teste de Sanitização de Erros do Backup Lógico ===\n'

diretorio_teste=$(mktemp -d "${TMPDIR:-/tmp}/frila-teste-backup-sanitizacao.XXXXXX")
script_backup="scripts/backup-logico.sh"
[[ -f "$script_backup" ]] || falhar "Script $script_backup não encontrado."

# 1. Validação unitária da função de sanitização extraída do script real
printf '1. Validando função de sanitização com credenciais sintéticas...\n'

url_sensivel="postgresql://backup_ro:SenhaSuperSecreta%23123@aws-0-sa-east-1.pooler.supabase.com:5432/postgres"
senha_pura="SenhaSuperSecreta%23123"

eval "$(sed -n '/^sanitizar_texto() {/,/^}/p' "$script_backup")"

# Caso 1.1: URL completa em mensagem de erro
saida_1=$(BACKUP_DB_URL="$url_sensivel" sanitizar_texto "pg_dump: error: connection to database \"$url_sensivel\" failed")
if [[ "$saida_1" == *"$senha_pura"* ]]; then
  falhar "Senha pura vazou na saída sanitizada (caso 1.1)."
fi
if [[ "$saida_1" == *"aws-0-sa-east-1.pooler.supabase.com"* ]]; then
  falhar "Host sensível vazou na saída sanitizada (caso 1.1)."
fi
if [[ "$saida_1" != *"[REDACTED_DB_URL]"* && "$saida_1" != *"[REDACTED"* ]]; then
  falhar "URL não foi devidamente redigida (caso 1.1)."
fi
printf '   ✓ Caso 1.1: URL PostgreSQL sanitizada sem vazamento de senha ou host.\n'

# Caso 1.2: Parâmetros password= e host= isolados
saida_2=$(BACKUP_DB_URL="$url_sensivel" sanitizar_texto "connection failed: password=SenhaSuperSecreta%23123 host=aws.pooler")
if [[ "$saida_2" == *"$senha_pura"* ]]; then
  falhar "Senha pura vazou em parâmetro password= (caso 1.2)."
fi
if [[ "$saida_2" == *"aws.pooler"* ]]; then
  falhar "Host vazou em parâmetro host= (caso 1.2)."
fi
if [[ "$saida_2" != *"password=[REDACTED]"* ]]; then
  falhar "Parâmetro password=[REDACTED] não aplicado (caso 1.2)."
fi
if [[ "$saida_2" != *"host=[REDACTED_HOST]"* ]]; then
  falhar "Parâmetro host=[REDACTED_HOST] não aplicado (caso 1.2)."
fi
printf '   ✓ Caso 1.2: Parâmetros password= e host= mascarados com sucesso.\n'

# Caso 1.3: Senha literal isolada no corpo de uma mensagem
saida_3=$(BACKUP_DB_URL="$url_sensivel" sanitizar_texto "fatal error: token SenhaSuperSecreta%23123 unexpected")
if [[ "$saida_3" == *"$senha_pura"* ]]; then
  falhar "Senha pura vazou no caso de ocorrência literal (caso 1.3)."
fi
if [[ "$saida_3" != *"[REDACTED_PASSWORD]"* ]]; then
  falhar "Senha literal não foi substituída por [REDACTED_PASSWORD] (caso 1.3)."
fi
printf '   ✓ Caso 1.3: Ocorrência literal da senha mascarada com [REDACTED_PASSWORD].\n'

# Caso 1.4: Formato user:password@host genérico
saida_4=$(sanitizar_texto "error connecting to admin_user:p%40ssw0rd!@10.0.0.1:5432/db")
if [[ "$saida_4" == *"p%40ssw0rd!"* ]]; then
  falhar "Senha genérica vazou (caso 1.4)."
fi
if [[ "$saida_4" == *"10.0.0.1"* ]]; then
  falhar "Host genérico vazou (caso 1.4)."
fi
if [[ "$saida_4" != *"[REDACTED_AUTH]@[REDACTED_HOST]:5432/db"* ]]; then
  falhar "Autoridade user:password@host não foi sanitizada (caso 1.4)."
fi
printf '   ✓ Caso 1.4: user:password@host genérico sanitizado sem vazar senha ou host.\n'

# Caso 1.5: Erro de conexão com servidor e IP resolvido em parênteses
saida_5=$(BACKUP_DB_URL="$url_sensivel" sanitizar_texto "pg_dump: error: connection to server at \"aws-0-sa-east-1.pooler.supabase.com\" (18.231.10.20), port 5432 failed: timeout")
if [[ "$saida_5" == *"aws-0-sa-east-1.pooler.supabase.com"* ]]; then
  falhar "Host do servidor vazou na mensagem de erro (caso 1.5)."
fi
if [[ "$saida_5" == *"18.231.10.20"* ]]; then
  falhar "IP do servidor vazou na mensagem de erro (caso 1.5)."
fi
if [[ "$saida_5" != *"server at \"[REDACTED_HOST]\" ([REDACTED_IP])"* ]]; then
  falhar "Host ou IP resolvido não foram substituídos por marcadores (caso 1.5)."
fi
printf '   ✓ Caso 1.5: Erro com server at host e IP resolvido mascarados.\n'

# 2. Teste integrado simulando falha do pg_dump e registro no GITHUB_STEP_SUMMARY
printf '2. Testando integração com GITHUB_STEP_SUMMARY e captura de erro...\n'

arquivo_summary="$diretorio_teste/step_summary.md"
export GITHUB_STEP_SUMMARY="$arquivo_summary"
: > "$arquivo_summary"

pasta_backup="$diretorio_teste/backup_dir"
mkdir -p "$pasta_backup"

bin_mock="$diretorio_teste/bin"
mkdir -p "$bin_mock"

# Cria mock de psql que executa normalmente para exportar versão e snapshot, mas falha no pg_dump
cat << 'EOF' > "$bin_mock/psql"
#!/bin/bash
if [[ "$*" == *"server_version_num"* ]]; then
  printf '170006\n'
  exit 0
fi
# Quando chamado no bloco de dump, simula execução do script SQL
# Cria psql.err se necessário ou deixa pg_dump falhar
if [[ -n "${BACKUP_WORK_DIR:-}" ]]; then
  # Executa o comando \! pg_dump que foi passado
  export BACKUP_SNAPSHOT="00000003-00000001-1"
  pg_dump --dbname "$BACKUP_DB_URL" 2>"$BACKUP_WORK_DIR/pg_dump.err" || true
fi
exit 0
EOF
chmod +x "$bin_mock/psql"

# Cria mock de pg_dump que simula falha com erro contendo credenciais
cat << EOF > "$bin_mock/pg_dump"
#!/bin/bash
if [[ "\$*" == *"--version"* ]]; then
  printf 'pg_dump (PostgreSQL) 17.6\n'
  exit 0
fi
# Simula erro de permissão com URL e senha no stderr
printf 'pg_dump: error: connection to database "%s" failed: FATAL: password authentication failed for user "backup_ro"\n' "\$BACKUP_DB_URL" >&2
printf 'pg_dump: error: query failed: ERROR: permission denied for table "segredos"\n' >&2
exit 1
EOF
chmod +x "$bin_mock/pg_dump"

# Cria mock de age que responde à versão e cria arquivo de saída solicitado
cat << 'EOF' > "$bin_mock/age"
#!/bin/bash
if [[ "$*" == *"--version"* ]]; then
  printf 'age 1.2.0\n'
  exit 0
fi
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--output" ]]; then
    touch "$arg"
  fi
  prev="$arg"
done
exit 0
EOF
chmod +x "$bin_mock/age"

PATH="$bin_mock:$PATH"
export PATH
export BACKUP_DB_URL="$url_sensivel"
export BACKUP_PUBLIC_KEY="age1mockdestinationkey000000000000000000000000000000000000000000000"
export BACKUP_DIR="$pasta_backup"
export BACKUP_CIPHER="age"

set +e
saida_exec=$("$script_backup" 2>&1)
codigo_exec=$?
set -e

# Asserções da execução
if (( codigo_exec != 1 )); then
  falhar "Script deveria falhar com exit code 1, obteve $codigo_exec."
fi

if [[ "$saida_exec" == *"$senha_pura"* ]]; then
  falhar "Senha pura vazou na saída capturada da execução."
fi

if [[ "$saida_exec" != *"pg_dump falhou; suplemento não publicado."* ]]; then
  falhar "Mensagem de falha esperada ausente na saída."
fi

if [[ "$saida_exec" != *"stderr sanitizado"* ]]; then
  falhar "Seção de stderr sanitizado ausente na saída."
fi

if [[ "$saida_exec" != *"permission denied for table \"segredos\""* ]]; then
  falhar "Detalhes do erro do pg_dump não apareceram na saída sanitizada."
fi
printf '   ✓ Execução falha com código 1 e emite stderr 100%% sanitizado.\n'

# 3. Conferência do GITHUB_STEP_SUMMARY
printf '3. Conferindo integridade do GITHUB_STEP_SUMMARY gerado...\n'

conteudo_summary=$(cat "$arquivo_summary")

if [[ -z "$conteudo_summary" ]]; then
  falhar "GITHUB_STEP_SUMMARY vazio após falha."
fi

if [[ "$conteudo_summary" == *"$senha_pura"* ]]; then
  falhar "Senha pura vazou no GITHUB_STEP_SUMMARY."
fi

if [[ "$conteudo_summary" != *"### ❌ Falha no Backup Lógico"* ]]; then
  falhar "Cabeçalho de erro ausente no GITHUB_STEP_SUMMARY."
fi

if [[ "$conteudo_summary" != *"permission denied for table \"segredos\""* ]]; then
  falhar "Última linha de erro ausente no GITHUB_STEP_SUMMARY."
fi
printf '   ✓ GITHUB_STEP_SUMMARY preenchido com cabeçalho, última linha e sem segredos.\n'

# 4. Resiliência sem GITHUB_STEP_SUMMARY
printf '4. Testando resiliência quando GITHUB_STEP_SUMMARY está ausente...\n'
unset GITHUB_STEP_SUMMARY
set +e
saida_sem_summary=$("$script_backup" 2>&1)
codigo_sem_summary=$?
set -e

if (( codigo_sem_summary != 1 )); then
  falhar "Script deveria falhar com código 1 mesmo sem GITHUB_STEP_SUMMARY."
fi
if [[ "$saida_sem_summary" == *"$senha_pura"* ]]; then
  falhar "Senha vazou na execução sem GITHUB_STEP_SUMMARY."
fi
printf '   ✓ Resiliente e seguro na ausência de GITHUB_STEP_SUMMARY.\n'

printf '=== Todos os testes de sanitização e relatório de erro passaram com SUCESSO! ===\n'
