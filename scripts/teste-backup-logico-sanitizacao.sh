#!/bin/bash
# Teste automatizado de classificação fechada de erros e relatório seguro do backup lógico.
# Opção A: nenhuma linha de stderr livre é exposta no console, no GITHUB_STEP_SUMMARY ou em artefatos.
# Valida contra 6 vetores de vazamento sintéticos e garante grep -F negativo para todos os tokens.
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

printf '=== Teste de Classificação Fechada de Erros do Backup Lógico ===\n'

diretorio_teste=$(mktemp -d "${TMPDIR:-/tmp}/frila-teste-backup-classificacao.XXXXXX")
script_backup="scripts/backup-logico.sh"
[[ -f "$script_backup" ]] || falhar "Script $script_backup não encontrado."

# 1. Carrega função classificar_erro diretamente do script
eval "$(sed -n '/^classificar_erro() {/,/^}/p' "$script_backup")"

# 2. Testes unitários com entradas sintéticas contra vetores de vazamento
printf '1. Validando classificação fechada contra vetores de vazamento sintéticos...\n'

# Vetor 1: IPv4 sem parênteses (libpq novo)
printf '   -> Vetor 1: IPv4 sem parênteses (libpq novo)...\n'
err_ipv4='psql: error: connection to server at "54.232.123.45", port 5432 failed: Connection refused'
res_ipv4=$(classificar_erro "$err_ipv4")
cod_ipv4="${res_ipv4%%|*}"
msg_ipv4="${res_ipv4#*|}"
[[ "$cod_ipv4" == "host_inalcancavel" ]] || falhar "Vetor 1: esperado host_inalcancavel, obteve $cod_ipv4."
[[ -n "$msg_ipv4" ]] || falhar "Vetor 1: mensagem vazia."
if printf '%s\n' "$res_ipv4" | grep -F -q "54.232.123.45"; then
  falhar "Vetor 1: IPv4 vazou na saída classificada."
fi
printf '      ✓ Código: host_inalcancavel; IPv4 54.232.123.45 ausente (grep -F negativo).\n'

# Vetor 2: IPv6
printf '   -> Vetor 2: Endereço IPv6...\n'
err_ipv6='psql: error: connection to server at "2804:14d:5c73:8900::1", port 5432 failed: Connection refused'
res_ipv6=$(classificar_erro "$err_ipv6")
cod_ipv6="${res_ipv6%%|*}"
[[ "$cod_ipv6" == "host_inalcancavel" ]] || falhar "Vetor 2: esperado host_inalcancavel, obteve $cod_ipv6."
if printf '%s\n' "$res_ipv6" | grep -F -q "2804:14d:5c73:8900::1"; then
  falhar "Vetor 2: IPv6 vazou na saída classificada."
fi
printf '      ✓ Código: host_inalcancavel; IPv6 ausente (grep -F negativo).\n'

# Vetor 3: Project ref do Supabase em postgres.PROJECT_REF
printf '   -> Vetor 3: Project ref do Supabase (postgres.PROJECT_REF)...\n'
err_proj='FATAL: password authentication failed for user "postgres.abcdefghijklmnop"'
res_proj=$(classificar_erro "$err_proj")
cod_proj="${res_proj%%|*}"
[[ "$cod_proj" == "autenticacao_recusada" ]] || falhar "Vetor 3: esperado autenticacao_recusada, obteve $cod_proj."
if printf '%s\n' "$res_proj" | grep -F -q "abcdefghijklmnop"; then
  falhar "Vetor 3: project ref vazou na saída classificada."
fi
printf '      ✓ Código: autenticacao_recusada; project ref ausente (grep -F negativo).\n'

# Vetor 4: Senha URL-encoded decodificada pelo psql
printf '   -> Vetor 4: Senha decodificada pelo cliente psql...\n'
err_senha='FATAL: password authentication failed for user "backup_ro": token "SenhaDecodificada@123#ComArroba" unexpected'
res_senha=$(classificar_erro "$err_senha")
cod_senha="${res_senha%%|*}"
[[ "$cod_senha" == "autenticacao_recusada" ]] || falhar "Vetor 4: esperado autenticacao_recusada, obteve $cod_senha."
if printf '%s\n' "$res_senha" | grep -F -q "SenhaDecodificada@123#ComArroba"; then
  falhar "Vetor 4: senha decodificada vazou na saída classificada."
fi
printf '      ✓ Código: autenticacao_recusada; senha decodificada ausente (grep -F negativo).\n'

# Vetor 5: Host com maiúsculas
printf '   -> Vetor 5: Hostname com maiúsculas...\n'
err_host='could not translate host name "AWS-0-SA-EAST-1.POOLER.SUPABASE.COM" to address: Name or service not known'
res_host=$(classificar_erro "$err_host")
cod_host="${res_host%%|*}"
[[ "$cod_host" == "host_inalcancavel" ]] || falhar "Vetor 5: esperado host_inalcancavel, obteve $cod_host."
if printf '%s\n' "$res_host" | grep -F -q "AWS-0-SA-EAST-1.POOLER.SUPABASE.COM"; then
  falhar "Vetor 5: host com maiúsculas vazou na saída classificada."
fi
printf '      ✓ Código: host_inalcancavel; host maiúsculo ausente (grep -F negativo).\n'

# Vetor 6: Nomes de tabela/coluna em DETAIL e HINT
printf '   -> Vetor 6: Nomes de tabela e coluna em DETAIL/HINT...\n'
err_detalhe=$(printf 'ERROR: permission denied for table "usuarios_privados"\nDETAIL: User backup_ro does not have SELECT on column "cpf_criptografado"\nHINT: Check role privileges in table "usuarios_privados"')
res_detalhe=$(classificar_erro "$err_detalhe")
cod_detalhe="${res_detalhe%%|*}"
[[ "$cod_detalhe" == "permissao_negada" ]] || falhar "Vetor 6: esperado permissao_negada, obteve $cod_detalhe."
if printf '%s\n' "$res_detalhe" | grep -F -q "usuarios_privados"; then
  falhar "Vetor 6: nome de tabela vazou na saída classificada."
fi
if printf '%s\n' "$res_detalhe" | grep -F -q "cpf_criptografado"; then
  falhar "Vetor 6: nome de coluna vazou na saída classificada."
fi
printf '      ✓ Código: permissao_negada; tabelas/colunas ausentes (grep -F negativo).\n'

# Vetor 7: Código "outro" para erro não catalogado
printf '   -> Vetor 7: Código "outro" para erro desconhecido...\n'
err_outro='pg_dump: error: unexpected internal system malfunction 0xDEADBEEF in core engine'
res_outro=$(classificar_erro "$err_outro")
cod_outro="${res_outro%%|*}"
msg_outro="${res_outro#*|}"
[[ "$cod_outro" == "outro" ]] || falhar "Vetor 7: esperado código outro, obteve $cod_outro."
[[ "$msg_outro" == "Erro não classificado durante a execução do pg_dump." ]] || falhar "Vetor 7: mensagem incorreta."
if printf '%s\n' "$res_outro" | grep -F -q "0xDEADBEEF"; then
  falhar "Vetor 7: token do erro vazou na saída classificada."
fi
printf '      ✓ Código: outro; mensagem fixa correta; token 0xDEADBEEF ausente (grep -F negativo).\n'

# 3. Validação dos demais códigos da lista fixa
printf '2. Validando demais categorias da lista fechada...\n'

res_timeout=$(classificar_erro 'canceling statement due to statement timeout')
[[ "${res_timeout%%|*}" == "timeout_conexao" ]] || falhar "Falha ao classificar timeout_conexao."

res_ssl=$(classificar_erro 'server does not support SSL, but SSL was required')
[[ "${res_ssl%%|*}" == "ssl_exigido" ]] || falhar "Falha ao classificar ssl_exigido."

res_disco=$(classificar_erro 'pg_dump: error: could not write to output file: No space left on device')
[[ "${res_disco%%|*}" == "espaco_em_disco" ]] || falhar "Falha ao classificar espaco_em_disco."

res_ver=$(classificar_erro 'pg_dump: error: server version mismatch: 17 vs 16')
[[ "${res_ver%%|*}" == "versao_incompativel" ]] || falhar "Falha ao classificar versao_incompativel."

res_snap=$(classificar_erro 'ERROR: exported snapshot "00000003-00000001-1" does not exist')
[[ "${res_snap%%|*}" == "snapshot_indisponivel" ]] || falhar "Falha ao classificar snapshot_indisponivel."

printf '   ✓ Todas as categorias fechadas mapeadas com sucesso (timeout, ssl, disco, versao, snapshot).\n'

# 4. Teste integrado simulando falha do pg_dump e registro seguro no GITHUB_STEP_SUMMARY
printf '3. Testando integração com execução real, stderr seguro e GITHUB_STEP_SUMMARY...\n'

arquivo_summary="$diretorio_teste/step_summary.md"
export GITHUB_STEP_SUMMARY="$arquivo_summary"
: > "$arquivo_summary"

pasta_backup="$diretorio_teste/backup_dir"
mkdir -p "$pasta_backup"

bin_mock="$diretorio_teste/bin"
mkdir -p "$bin_mock"

cat << 'EOF' > "$bin_mock/psql"
#!/bin/bash
if [[ "$*" == *"server_version_num"* ]]; then
  printf '170006\n'
  exit 0
fi
if [[ -n "${BACKUP_WORK_DIR:-}" ]]; then
  export BACKUP_SNAPSHOT="00000003-00000001-1"
  pg_dump --dbname "$BACKUP_DB_URL" 2>"$BACKUP_WORK_DIR/pg_dump.err" || true
fi
exit 0
EOF
chmod +x "$bin_mock/psql"

# pg_dump mock emite stderr com múltiplos vetores de vazamento juntos
cat << 'EOF' > "$bin_mock/pg_dump"
#!/bin/bash
if [[ "$*" == *"--version"* ]]; then
  printf 'pg_dump (PostgreSQL) 17.6\n'
  exit 0
fi
printf 'pg_dump: error: connection to server at "54.232.123.45", port 5432 failed\n' >&2
printf 'FATAL: password authentication failed for user "postgres.abcdefghijklmnop"\n' >&2
printf 'psql: error: token "SenhaDecodificada@123#ComArroba" unexpected\n' >&2
printf 'ERROR: permission denied for table "usuarios_privados"\n' >&2
printf 'DETAIL: User backup_ro does not have SELECT on column "cpf_criptografado"\n' >&2
exit 1
EOF
chmod +x "$bin_mock/pg_dump"

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
export BACKUP_DB_URL="postgresql://backup_ro:SenhaDecodificada%40123%23ComArroba@AWS-0-SA-EAST-1.POOLER.SUPABASE.COM:5432/postgres"
export BACKUP_PUBLIC_KEY="age1mockdestinationkey000000000000000000000000000000000000000000000"
export BACKUP_DIR="$pasta_backup"
export BACKUP_CIPHER="age"

set +e
saida_exec=$("$script_backup" 2>&1)
codigo_exec=$?
set -e

# Asserções de segurança na saída da execução
if (( codigo_exec != 1 )); then
  falhar "Script deveria falhar com exit code 1, obteve $codigo_exec."
fi

tokens_sensiveis=(
  "54.232.123.45"
  "postgres.abcdefghijklmnop"
  "abcdefghijklmnop"
  "SenhaDecodificada@123#ComArroba"
  "usuarios_privados"
  "cpf_criptografado"
  "AWS-0-SA-EAST-1.POOLER.SUPABASE.COM"
)

for token in "${tokens_sensiveis[@]}"; do
  if printf '%s\n' "$saida_exec" | grep -F -q "$token"; then
    falhar "Token sensível '$token' vazou no log de execução do script!"
  fi
done

if [[ "$saida_exec" != *"Diagnóstico do erro: ["* ]]; then
  falhar "Diagnóstico do erro seguro ausente no log de execução."
fi
if [[ "$saida_exec" != *"pg_dump falhou; suplemento não publicado."* ]]; then
  falhar "Mensagem de falha padrão ausente."
fi

printf '   ✓ Log de execução seguro: nenhum token sensível vazou (grep -F negativo).\n'

# Asserções de segurança no GITHUB_STEP_SUMMARY
conteudo_summary=$(cat "$arquivo_summary")
[[ -n "$conteudo_summary" ]] || falhar "GITHUB_STEP_SUMMARY vazio."

for token in "${tokens_sensiveis[@]}"; do
  if printf '%s\n' "$conteudo_summary" | grep -F -q "$token"; then
    falhar "Token sensível '$token' vazou no GITHUB_STEP_SUMMARY!"
  fi
done

if [[ "$conteudo_summary" != *"### ❌ Falha no Backup Lógico (pg_dump)"* ]]; then
  falhar "Cabeçalho seguro ausente no GITHUB_STEP_SUMMARY."
fi
if [[ "$conteudo_summary" != *"- **Código:** \`"* ]]; then
  falhar "Formato de código seguro ausente no GITHUB_STEP_SUMMARY."
fi
if [[ "$conteudo_summary" != *"- **Descrição:** "* ]]; then
  falhar "Formato de descrição seguro ausente no GITHUB_STEP_SUMMARY."
fi

printf '   ✓ GITHUB_STEP_SUMMARY seguro: cabeçalho e diagnóstico presentes, zero vazamento.\n'

# 5. Resiliência sem GITHUB_STEP_SUMMARY
printf '4. Testando resiliência sem GITHUB_STEP_SUMMARY...\n'
unset GITHUB_STEP_SUMMARY
set +e
saida_sem_summary=$("$script_backup" 2>&1)
codigo_sem_summary=$?
set -e

if (( codigo_sem_summary != 1 )); then
  falhar "Script deveria falhar com código 1 sem GITHUB_STEP_SUMMARY."
fi
for token in "${tokens_sensiveis[@]}"; do
  if printf '%s\n' "$saida_sem_summary" | grep -F -q "$token"; then
    falhar "Token sensível '$token' vazou no log sem GITHUB_STEP_SUMMARY!"
  fi
done
printf '   ✓ Resiliente e seguro sem GITHUB_STEP_SUMMARY.\n'

printf '=== Todos os testes de classificação fechada passaram com SUCESSO! ===\n'
