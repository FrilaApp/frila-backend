#!/bin/bash
# Backup lógico cifrado. Configuração e uso: docs/BackupDoProd.md.
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
export COPYFILE_DISABLE=1

etapa='validar configuração'
temporario=''
trava=''
tem_trava=0
falhar() { printf 'ERRO: %s\n' "$1" >&2; exit 1; }
classificar_erro() {
  local texto="${1:-}"
  local codigo="outro"
  local mensagem="Erro não classificado durante a execução do pg_dump."

  if printf '%s\n' "$texto" | grep -E -i -q "password authentication failed|authentication failed|no password was provided|PAM authentication failed|Ident authentication failed"; then
    codigo="autenticacao_recusada"
    mensagem="Autenticação recusada: verifique usuário e senha de conexão."
  elif printf '%s\n' "$texto" | grep -E -i -q "snapshot .*does not exist|exported snapshot|invalid snapshot identifier|could not import snapshot"; then
    codigo="snapshot_indisponivel"
    mensagem="Snapshot da transação indisponível ou expirado."
  elif printf '%s\n' "$texto" | grep -E -i -q "permission denied|must be owner of|must be member of|insufficient privilege|row-level security"; then
    codigo="permissao_negada"
    mensagem="Permissão negada: privilégios insuficientes para tabelas ou objetos."
  elif printf '%s\n' "$texto" | grep -E -i -q "timeout expired|connection timed out|statement timeout|idle_in_transaction_session_timeout|canceling statement due to statement timeout"; then
    codigo="timeout_conexao"
    mensagem="Tempo limite de conexão esgotado (timeout)."
  elif printf '%s\n' "$texto" | grep -E -i -q "server does not support SSL|SSL connection has been closed|SSL error|certificate verify failed|sslmode"; then
    codigo="ssl_exigido"
    mensagem="Falha na negociação SSL/TLS com o servidor."
  elif printf '%s\n' "$texto" | grep -E -i -q "No space left on device|disk full|out of disk space"; then
    codigo="espaco_em_disco"
    mensagem="Espaço insuficiente em disco."
  elif printf '%s\n' "$texto" | grep -E -i -q "server version mismatch|server version|unsupported version"; then
    codigo="versao_incompativel"
    mensagem="Incompatibilidade de versão entre cliente e servidor."
  elif printf '%s\n' "$texto" | grep -E -i -q "could not translate host name|Name or service not known|nodename nor servname provided|No route to host|could not connect to server|connection to server.*failed|connection to database.*failed|Connection refused|server closed the connection unexpectedly"; then
    codigo="host_inalcancavel"
    mensagem="Host inalcançável: servidor ou pooler não responde no endereço configurado."
  fi

  printf '%s|%s\n' "$codigo" "$mensagem"
}
limpar() {
  local codigo=$?
  trap - EXIT
  if [[ -n "$temporario" ]] && ! rm -rf -- "$temporario" 2>/dev/null; then
    printf 'ERRO: não foi possível apagar o temporário; remova-o na pasta de backup.\n' >&2
    codigo=1
  fi
  if [[ "$tem_trava" == 1 ]] && ! rmdir "$trava" 2>/dev/null; then
    printf 'ERRO: não foi possível liberar a trava na pasta de backup.\n' >&2
    codigo=1
  fi
  exit "$codigo"
}
trap limpar EXIT
trap 'falhar "falha ao $etapa; detalhes omitidos para proteger credenciais e dados."' ERR
trap 'falhar "backup interrompido."' HUP INT TERM

[[ $# == 0 ]] || falhar 'configure por variáveis de ambiente; consulte docs/BackupDoProd.md.'
[[ -n "${BACKUP_DB_URL:-}" ]] || falhar 'defina BACKUP_DB_URL no ambiente.'
[[ -n "${BACKUP_PUBLIC_KEY:-}" ]] || falhar 'defina BACKUP_PUBLIC_KEY (destinatário age ou caminho do certificado público PEM).'
[[ -n "${BACKUP_DIR:-}" ]] || falhar 'defina BACKUP_DIR, pasta dedicada fora de qualquer repositório.'
case "$BACKUP_DB_URL" in postgres://*|postgresql://*) ;; *) falhar 'BACKUP_DB_URL deve ser uma conexão PostgreSQL.' ;; esac
retencao="${BACKUP_KEEP:-14}"
[[ "$retencao" =~ ^[1-9][0-9]{0,5}$ ]] || falhar 'BACKUP_KEEP deve ser um inteiro entre 1 e 999999.'
for comando in pg_dump psql git tar; do
  command -v "$comando" >/dev/null 2>&1 || falhar "dependência ausente: $comando."
done
etapa='consultar versão do servidor (somente leitura)'
versao_servidor=$(PGSSLMODE="${PGSSLMODE:-require}" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}" \
  psql -X -qAt --no-password --set ON_ERROR_STOP=1 --dbname "$BACKUP_DB_URL" \
    --command "BEGIN READ ONLY; SELECT current_setting('server_version_num'); COMMIT;" 2>/dev/null)
[[ "$versao_servidor" =~ ^[0-9]{5,6}$ ]] || falhar 'não foi possível validar a versão do servidor.'
etapa='consultar versão do pg_dump'
versao_cliente=$(pg_dump --version 2>/dev/null)
[[ "$versao_cliente" =~ PostgreSQL\)\ ([0-9]+)\.([0-9]+) ]] || falhar 'não foi possível validar a versão do pg_dump.'
cliente_principal=${BASH_REMATCH[1]}
cliente_secundaria=${BASH_REMATCH[2]}
servidor_principal=$((versao_servidor / 10000))
if (( servidor_principal < 10 )); then
  servidor_principal=$((versao_servidor / 100))
  cliente_principal=$((cliente_principal * 100 + cliente_secundaria))
fi
(( cliente_principal >= servidor_principal )) || falhar 'pg_dump mais antigo que o servidor; instale um cliente com versão principal igual ou superior.'
cifra="${BACKUP_CIPHER:-auto}"
if [[ "$cifra" == auto ]]; then
  if command -v age >/dev/null 2>&1; then cifra=age; else cifra=openssl; fi
fi
case "$cifra" in
  age|openssl) command -v "$cifra" >/dev/null 2>&1 || falhar "dependência ausente: $cifra." ;;
  *) falhar 'BACKUP_CIPHER deve ser auto, age ou openssl.' ;;
esac
if [[ "$cifra" == openssl ]]; then
  [[ -r "$BACKUP_PUBLIC_KEY" && -f "$BACKUP_PUBLIC_KEY" ]] || falhar 'certificado público PEM não encontrado ou ilegível.'
fi
[[ "$BACKUP_DIR" == /* ]] || falhar 'BACKUP_DIR deve ser um caminho absoluto.'
etapa='preparar pasta de backup'
mkdir -p -- "$BACKUP_DIR" 2>/dev/null
destino=$(cd -- "$BACKUP_DIR" 2>/dev/null && pwd -P)
[[ "$destino" != / ]] || falhar 'use uma pasta dedicada para BACKUP_DIR.'
raiz=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
case "$destino/" in "$raiz/"*) falhar 'BACKUP_DIR precisa ficar fora do repositório.' ;; esac
if git -C "$destino" rev-parse --git-dir >/dev/null 2>&1; then
  falhar 'BACKUP_DIR está dentro de um repositório Git (inclusive por link simbólico).'
fi
chmod 700 "$destino" 2>/dev/null
trava="$destino/.backup-logico.lock"
mkdir "$trava" 2>/dev/null || falhar 'há uma execução ou trava pendente na pasta de backup; confira antes de removê-la.'
tem_trava=1
temporario=$(mktemp -d "$destino/.backup-logico.XXXXXX" 2>/dev/null)

cifrar() {
  if [[ "$cifra" == age ]]; then
    age --encrypt --recipient "$BACKUP_PUBLIC_KEY" --output "$2" "$1" >/dev/null 2>&1
  else
    # CMS AuthEnvelopedData: AES-GCM autentica o conteúdo; RSA-OAEP protege a chave de sessão.
    openssl cms -encrypt -binary -aes-256-gcm -outform DER \
      -recip "$BACKUP_PUBLIC_KEY" -keyopt rsa_padding_mode:oaep \
      -in "$1" -out "$2" >/dev/null 2>&1
  fi
}
etapa='validar destinatário da cifra (OpenSSL exige versão 3 e certificado RSA)'
cifrar /dev/null "$temporario/verificacao"
rm -- "$temporario/verificacao"

inicio=$SECONDS
etapa='gerar dump e suplemento de extensões no mesmo snapshot'
# A sessão psql mantém o snapshot vivo enquanto seu filho pg_dump o utiliza.
# O catálogo define o suplemento; só o log transitório autorizado é excluído.
export BACKUP_WORK_DIR="$temporario"
if ! PGSSLMODE="${PGSSLMODE:-require}" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}" \
  psql -X -qAt --no-password --set ON_ERROR_STOP=1 --dbname "$BACKUP_DB_URL" \
    --set suplemento="$temporario/extensoes.sql" 2>"$temporario/psql.err" >/dev/null <<'SQL'
BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;
SET LOCAL DateStyle = 'ISO';
SET LOCAL IntervalStyle = 'postgres';
SET LOCAL extra_float_digits = 3;
SET LOCAL bytea_output = 'hex';
SET LOCAL client_encoding = 'UTF8';
SET LOCAL row_security = off;
SELECT pg_export_snapshot() AS snapshot \gset
\setenv BACKUP_SNAPSHOT :snapshot
\o :suplemento
SELECT 'SET DateStyle = ''ISO''; SET IntervalStyle = ''postgres''; SET client_encoding = ''UTF8'';';
SELECT format('SELECT %L; COPY (SELECT %s FROM ONLY %I.%I) TO STDOUT; SELECT %L;',
    format('TRUNCATE ONLY %I.%I; COPY %I.%I (%s) FROM stdin;',
      n.nspname, c.relname, n.nspname, c.relname, colunas.lista),
    colunas.lista, n.nspname, c.relname, E'\\.')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_depend d ON d.classid = 'pg_class'::regclass AND d.objid = c.oid
    AND d.refclassid = 'pg_extension'::regclass AND d.deptype = 'e'
JOIN pg_extension e ON e.oid = d.refobjid
CROSS JOIN LATERAL (
    SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum) AS lista
    FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0
      AND NOT a.attisdropped AND a.attgenerated = ''
) colunas
WHERE c.relkind = 'r' AND NOT c.oid = ANY(coalesce(e.extconfig, ARRAY[]::oid[]))
  AND NOT (n.nspname = 'net' AND c.relname = '_http_response')
  AND ((xpath('/row/tem/text()', query_to_xml(
    format('SELECT EXISTS(SELECT 1 FROM ONLY %I.%I) AS tem', n.nspname, c.relname),
    false, true, '')))[1]::text)::boolean
ORDER BY n.nspname, c.relname
\gexec
\o
\! pg_dump --dbname "$BACKUP_DB_URL" --no-password --format=custom --snapshot="$BACKUP_SNAPSHOT" --exclude-table-data=net._http_response --file "$BACKUP_WORK_DIR/banco.dump" 2>"$BACKUP_WORK_DIR/pg_dump.err" >/dev/null && touch "$BACKUP_WORK_DIR/dump-concluido"
COMMIT;
SQL
then
  : # Falha do psql capturada via psql.err e verificada abaixo
fi

if [[ ! -f "$temporario/dump-concluido" ]]; then
  erro_coletado=''
  if [[ -s "$temporario/pg_dump.err" ]]; then
    erro_coletado=$(cat "$temporario/pg_dump.err")
  fi
  if [[ -s "$temporario/psql.err" ]]; then
    if [[ -n "$erro_coletado" ]]; then
      erro_coletado=$(printf '%s\n--- psql ---\n%s' "$erro_coletado" "$(cat "$temporario/psql.err")")
    else
      erro_coletado=$(cat "$temporario/psql.err")
    fi
  fi

  classificacao=$(classificar_erro "$erro_coletado")
  codigo_erro="${classificacao%%|*}"
  mensagem_erro="${classificacao#*|}"

  printf 'Diagnóstico do erro: [%s] %s\n' "$codigo_erro" "$mensagem_erro" >&2

  if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -w "$GITHUB_STEP_SUMMARY" ]]; then
    {
      echo "### ❌ Falha no Backup Lógico (pg_dump)"
      echo
      echo "**Diagnóstico seguro:**"
      echo "- **Código:** \`$codigo_erro\`"
      echo "- **Descrição:** $mensagem_erro"
    } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi

  falhar 'pg_dump falhou; suplemento não publicado.'
fi

if [[ ! -s "$temporario/banco.dump" ]]; then
  printf 'Diagnóstico do erro: [outro] pg_dump não gerou conteúdo.\n' >&2
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" && -w "$GITHUB_STEP_SUMMARY" ]]; then
    {
      echo "### ❌ Falha no Backup Lógico (pg_dump)"
      echo
      echo "**Diagnóstico seguro:**"
      echo "- **Código:** \`outro\`"
      echo "- **Descrição:** pg_dump não gerou conteúdo."
    } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
  fi
  falhar 'pg_dump não gerou conteúdo.'
fi
tempo_dump=$((SECONDS - inicio))

etapa='empacotar dump e suplemento'
printf 'frila-backup-v2\n' > "$temporario/formato.txt"
COPYFILE_DISABLE=1 tar -cf "$temporario/backup.tar" -C "$temporario" formato.txt banco.dump extensoes.sql
etapa='cifrar pacote'
inicio_cifra=$SECONDS
extensao=age
[[ "$cifra" != openssl ]] || extensao=cms
cifrar "$temporario/backup.tar" "$temporario/backup.cifrado"
[[ -s "$temporario/backup.cifrado" ]] || falhar 'a cifra não gerou conteúdo.'
tempo_cifra=$((SECONDS - inicio_cifra))
etapa='apagar dump em claro'
rm -- "$temporario/banco.dump" "$temporario/extensoes.sql" "$temporario/backup.tar"

etapa='publicar arquivo cifrado'
nome="frila-backup-$(date -u +%Y%m%dT%H%M%SZ)-${temporario##*.}.tar.$extensao"
[[ ! -e "$destino/$nome" ]] || falhar 'nome de backup já existe; tente novamente.'
mv -- "$temporario/backup.cifrado" "$destino/$nome"

etapa='aplicar retenção'
arquivos=()
shopt -s nullglob
for arquivo in "$destino"/frila-backup-*.*.*; do
  base=${arquivo##*/}
  if [[ -f "$arquivo" && ! -L "$arquivo" && "$base" =~ ^frila-backup-[0-9]{8}T[0-9]{6}Z-[a-zA-Z0-9]{6}\.(dump|tar)\.(age|cms)$ ]]; then
    arquivos+=("$arquivo")
  fi
done
# Compara mtime, inclusive quando dois backups saem no mesmo segundo.
restantes=${#arquivos[@]}
while (( restantes > retencao )); do
  mais_antigo=''
  for arquivo in "${arquivos[@]}"; do
    [[ -f "$arquivo" && "$arquivo" != "$destino/$nome" ]] || continue
    if [[ -z "$mais_antigo" || "$arquivo" -ot "$mais_antigo" ]]; then mais_antigo=$arquivo; fi
  done
  [[ -n "$mais_antigo" ]] || falhar 'não foi possível selecionar o backup antigo.'
  rm -- "$mais_antigo" 2>/dev/null
  restantes=$((restantes - 1))
done
printf 'OK: %s; dump=%ss; cifra=%ss; total=%ss; retidos=%s.\n' \
  "$nome" "$tempo_dump" "$tempo_cifra" "$((SECONDS - inicio))" "$restantes"
