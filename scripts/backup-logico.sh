#!/bin/bash
# Backup lógico cifrado. Configuração e uso: docs/BackupDoProd.md.
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C

etapa='validar configuração'
temporario=''
trava=''
tem_trava=0
falhar() { printf 'ERRO: %s\n' "$1" >&2; exit 1; }
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
for comando in pg_dump git; do
  command -v "$comando" >/dev/null 2>&1 || falhar "dependência ausente: $comando."
done
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
etapa='gerar dump (confira conexão, permissões e versão do pg_dump)'
# Não usa Docker, link do Supabase ou credencial guardada no repositório.
# O formato custom inclui esquema, dados, sequências, ACLs e large objects.
PGSSLMODE="${PGSSLMODE:-require}" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-15}" \
  pg_dump --dbname "$BACKUP_DB_URL" --no-password --format=custom \
    --file "$temporario/banco.dump" >/dev/null 2>&1
[[ -s "$temporario/banco.dump" ]] || falhar 'pg_dump não gerou conteúdo.'
tempo_dump=$((SECONDS - inicio))

etapa='cifrar dump'
inicio_cifra=$SECONDS
extensao=age
[[ "$cifra" != openssl ]] || extensao=cms
cifrar "$temporario/banco.dump" "$temporario/backup.cifrado"
[[ -s "$temporario/backup.cifrado" ]] || falhar 'a cifra não gerou conteúdo.'
tempo_cifra=$((SECONDS - inicio_cifra))
etapa='apagar dump em claro'
rm -- "$temporario/banco.dump"

etapa='publicar arquivo cifrado'
nome="frila-backup-$(date -u +%Y%m%dT%H%M%SZ)-${temporario##*.}.dump.$extensao"
[[ ! -e "$destino/$nome" ]] || falhar 'nome de backup já existe; tente novamente.'
mv -- "$temporario/backup.cifrado" "$destino/$nome"

etapa='aplicar retenção'
arquivos=()
shopt -s nullglob
for arquivo in "$destino"/frila-backup-*.dump.*; do
  base=${arquivo##*/}
  if [[ -f "$arquivo" && ! -L "$arquivo" && "$base" =~ ^frila-backup-[0-9]{8}T[0-9]{6}Z-[a-zA-Z0-9]{6}\.dump\.(age|cms)$ ]]; then
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
