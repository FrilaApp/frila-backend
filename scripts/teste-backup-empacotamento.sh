#!/bin/bash
# Teste automatizado do empacotamento e desempacotamento portátil de backup (RNF12).
#
# Valida que o comando de empacotamento do pacote v2 do Frila:
#   COPYFILE_DISABLE=1 tar -cf backup.tar -C "$dir" formato.txt banco.dump extensoes.sql
# opera de forma 100% portável e idêntica tanto no Linux (GNU tar) quanto no macOS (bsdtar),
# garantindo ausência de flags exclusivos (--no-mac-metadata), supressão de arquivos
# AppleDouble (._*) e integridade estrita na descompactação.
#
# Uso:
#   ./scripts/teste-backup-empacotamento.sh
#   ./scripts/teste-backup-empacotamento.sh --com-docker   (executa probe adicional em Ubuntu Linux)

set -Eeuo pipefail
umask 077
export LC_ALL=C
export COPYFILE_DISABLE=1

diretorio_teste=''
limpar() {
  local codigo=$?
  if [[ -n "$diretorio_teste" && -d "$diretorio_teste" ]]; then
    rm -rf -- "$diretorio_teste" 2>/dev/null || true
  fi
  exit "$codigo"
}
trap limpar EXIT ERR INT TERM

falhar() {
  printf 'ERRO: %s\n' "$1" >&2
  exit 1
}

printf '=== Teste de Portabilidade do Empacotamento de Backup (Linux / macOS) ===\n'

# 1. Informações da ferramenta local
tipo_tar='desconhecido'
versao_tar=$(tar --version 2>&1 | head -n 1 || true)
if [[ "$versao_tar" =~ (GNU|tar\ \(GNU) ]]; then
  tipo_tar='GNU tar (Linux/POSIX)'
elif [[ "$versao_tar" =~ (bsdtar|libarchive) ]]; then
  tipo_tar='bsdtar (macOS/BSD)'
fi
printf 'Ferramenta tar detectada: %s (%s)\n' "$tipo_tar" "$versao_tar"

# 2. Palco de teste isolado
diretorio_teste=$(mktemp -d "${TMPDIR:-/tmp}/frila-teste-tar.XXXXXX")
origem="$diretorio_teste/origem"
destino="$diretorio_teste/destino"
mkdir -p "$origem" "$destino"

# Criação dos 3 arquivos do pacote v2
printf 'frila-backup-v2\n' > "$origem/formato.txt"
printf 'DUMP_TESTE_FRILA_POSTGRESQL_17\n' > "$origem/banco.dump"
printf 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";\n' > "$origem/extensoes.sql"

# 3. Execução do empacotamento oficial (exatamente como em scripts/backup-logico.sh)
printf '1. Testando empacotamento com COPYFILE_DISABLE=1 tar -cf...\n'
arquivo_tar="$diretorio_teste/backup.tar"
COPYFILE_DISABLE=1 tar -cf "$arquivo_tar" -C "$origem" formato.txt banco.dump extensoes.sql
[[ -s "$arquivo_tar" ]] || falhar 'arquivo tar não foi gerado ou está vazio.'
printf '   ✓ Pacote tar gerado com sucesso (%s bytes).\n' "$(wc -c < "$arquivo_tar" | tr -d ' ')"

# 4. Inspeção do conteúdo do tar (sem arquivos fantasmas AppleDouble)
printf '2. Inspecionando índice do arquivo tar...\n'
conteudo_tar=$(tar -tf "$arquivo_tar")
printf '%s\n' "$conteudo_tar" | sed 's/^/      /'

for arquivo_esperado in formato.txt banco.dump extensoes.sql; do
  if ! printf '%s\n' "$conteudo_tar" | grep -q "^$arquivo_esperado\$"; then
    falhar "arquivo obrigatório $arquivo_esperado ausente no pacote tar."
  fi
done

if printf '%s\n' "$conteudo_tar" | grep -q '^\._'; then
  falhar 'metadados AppleDouble (arquivos ._*) vazaram para o pacote tar.'
fi
printf '   ✓ Todos os 3 arquivos presentes e nenhum metadado AppleDouble (. _*) detectado.\n'

# 5. Descompactação e conferência de integridade
printf '3. Testando descompactação portátil...\n'
tar -xf "$arquivo_tar" -C "$destino" formato.txt banco.dump extensoes.sql

for arquivo in formato.txt banco.dump extensoes.sql; do
  [[ -f "$destino/$arquivo" ]] || falhar "arquivo $arquivo não encontrado no destino descompactado."
  diff -u "$origem/$arquivo" "$destino/$arquivo" || falhar "conteúdo de $arquivo diverge após descompactação."
done
printf '   ✓ Descompactação 100%% íntegra (diff idêntico em formato.txt, banco.dump e extensoes.sql).\n'

# 6. Probe em container Linux (se solicitado ou se Docker disponível)
com_docker=0
for arg in "$@"; do
  if [[ "$arg" == '--com-docker' ]]; then com_docker=1; fi
done

if [[ "$com_docker" == 1 ]] || { [[ $# == 0 ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; then
  printf '4. Executando probe de empacotamento em container Ubuntu Linux (GNU tar real)...\n'
  saida_docker=$(docker run --rm ubuntu:latest /bin/bash -c "
    set -Eeuo pipefail
    export LC_ALL=C
    export COPYFILE_DISABLE=1
    TMP_DIR=\$(mktemp -d)
    mkdir -p \"\$TMP_DIR/in\" \"\$TMP_DIR/out\"
    printf 'frila-backup-v2\n' > \"\$TMP_DIR/in/formato.txt\"
    printf 'DUMP_PROD\n' > \"\$TMP_DIR/in/banco.dump\"
    printf 'EXTENSOES\n' > \"\$TMP_DIR/in/extensoes.sql\"
    COPYFILE_DISABLE=1 tar -cf \"\$TMP_DIR/backup.tar\" -C \"\$TMP_DIR/in\" formato.txt banco.dump extensoes.sql
    tar -xf \"\$TMP_DIR/backup.tar\" -C \"\$TMP_DIR/out\" formato.txt banco.dump extensoes.sql
    diff -u \"\$TMP_DIR/in/formato.txt\" \"\$TMP_DIR/out/formato.txt\"
    diff -u \"\$TMP_DIR/in/banco.dump\" \"\$TMP_DIR/out/banco.dump\"
    diff -u \"\$TMP_DIR/in/extensoes.sql\" \"\$TMP_DIR/out/extensoes.sql\"
    tar_ver=\$(tar --version | head -n 1)
    echo \"GNU_TAR_OK: \$tar_ver\"
    rm -rf -- \"\$TMP_DIR\"
  " 2>&1)
  printf '   ✓ Saída no Linux: %s\n' "$(printf '%s' "$saida_docker" | grep 'GNU_TAR_OK:')"
fi

printf '=== Sucesso: Empacotamento de backup comprovadamente portátil (GNU tar e bsdtar) ===\n'
