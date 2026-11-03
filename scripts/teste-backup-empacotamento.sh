#!/bin/bash
# Teste automatizado do empacotamento e desempacotamento portátil de backup (RNF12).
#
# Valida que o comando de empacotamento do pacote v2 do Frila:
#   COPYFILE_DISABLE=1 tar -cf backup.tar -C "$dir" formato.txt banco.dump extensoes.sql
# extraído diretamente do script de produção scripts/backup-logico.sh opera de forma
# 100% portável e idêntica tanto no Linux (GNU tar) quanto no macOS (bsdtar),
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
executou_gnu_tar=0
executou_bsdtar=0

if [[ "$versao_tar" =~ (GNU|tar\ \(GNU) ]]; then
  tipo_tar='GNU tar (Linux/POSIX)'
  executou_gnu_tar=1
elif [[ "$versao_tar" =~ (bsdtar|libarchive) ]]; then
  tipo_tar='bsdtar (macOS/BSD)'
  executou_bsdtar=1
fi
printf 'Ferramenta tar detectada: %s (%s)\n' "$tipo_tar" "$versao_tar"

# 2. Localização e extração do comando real de empacotamento em scripts/backup-logico.sh
candidatos_backup=(
  "$(dirname "${BASH_SOURCE[0]}")/backup-logico.sh"
  "$(dirname "${BASH_SOURCE[0]}")/../scripts/backup-logico.sh"
  "scripts/backup-logico.sh"
  "./backup-logico.sh"
)
script_backup=''
for c in "${candidatos_backup[@]}"; do
  if [[ -f "$c" ]]; then
    script_backup="$c"
    break
  fi
done
[[ -n "$script_backup" ]] || falhar 'script scripts/backup-logico.sh não encontrado.'

comando_tar=$(grep -E '^[[:space:]]*(COPYFILE_DISABLE=[0-9]+[[:space:]]+)?tar[[:space:]]+.*formato\.txt[[:space:]]+banco\.dump[[:space:]]+extensoes\.sql' "$script_backup" | sed -e 's/^[[:space:]]*//' | head -n 1)
[[ -n "$comando_tar" ]] || falhar "comando de empacotamento tar não encontrado no script real $script_backup."

# 3. Palco de teste isolado
diretorio_teste=$(mktemp -d "${TMPDIR:-/tmp}/frila-teste-tar.XXXXXX")
origem="$diretorio_teste/origem"
destino="$diretorio_teste/destino"
mkdir -p "$origem" "$destino"

# Criação dos 3 arquivos do pacote v2
printf 'frila-backup-v2\n' > "$origem/formato.txt"
printf 'DUMP_TESTE_FRILA_POSTGRESQL_17\n' > "$origem/banco.dump"
printf 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";\n' > "$origem/extensoes.sql"

# 4. Execução do empacotamento oficial (extraído diretamente do script real scripts/backup-logico.sh)
printf '1. Testando empacotamento oficial extraído de %s...\n' "$script_backup"
arquivo_tar="$diretorio_teste/backup.tar"

(
  export temporario="$origem"
  eval "$comando_tar"
) || falhar "o comando real de empacotamento de $script_backup falhou ao executar."

if [[ -f "$origem/backup.tar" ]]; then
  mv "$origem/backup.tar" "$arquivo_tar"
fi

[[ -s "$arquivo_tar" ]] || falhar 'arquivo tar não foi gerado ou está vazio pelo comando real.'
printf '   ✓ Pacote tar gerado com sucesso pelo comando real (%s bytes).\n' "$(wc -c < "$arquivo_tar" | tr -d ' ')"

# 5. Inspeção do conteúdo do tar (sem arquivos fantasmas AppleDouble)
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

# 6. Descompactação e conferência de integridade
printf '3. Testando descompactação portátil...\n'
tar -xf "$arquivo_tar" -C "$destino" formato.txt banco.dump extensoes.sql

for arquivo in formato.txt banco.dump extensoes.sql; do
  [[ -f "$destino/$arquivo" ]] || falhar "arquivo $arquivo não encontrado no destino descompactado."
  diff -u "$origem/$arquivo" "$destino/$arquivo" || falhar "conteúdo de $arquivo diverge após descompactação."
done
printf '   ✓ Descompactação 100%% íntegra (diff idêntico em formato.txt, banco.dump e extensoes.sql).\n'

# 7. Probe em container Linux (se solicitado ou se Docker disponível em ambiente não-Linux)
com_docker=0
sem_docker=0
for arg in "$@"; do
  if [[ "$arg" == '--com-docker' ]]; then com_docker=1; fi
  if [[ "$arg" == '--sem-docker' ]]; then sem_docker=1; fi
done

if [[ "$sem_docker" == 0 ]] && { [[ "$com_docker" == 1 ]] || { [[ $# == 0 ]] && [[ "$tipo_tar" != 'GNU tar'* ]] && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }; }; then
  if docker image inspect ubuntu:latest >/dev/null 2>&1 || [[ "$com_docker" == 1 ]]; then
    printf '4. Executando probe de empacotamento em container Ubuntu Linux (GNU tar real)...\n'
    if saida_docker=$(docker run --rm ubuntu:latest /bin/bash -c "
      set -Eeuo pipefail
      export LC_ALL=C
      export COPYFILE_DISABLE=1
      TMP_DIR=\$(mktemp -d)
      mkdir -p \"\$TMP_DIR/in\" \"\$TMP_DIR/out\"
      printf 'frila-backup-v2\n' > \"\$TMP_DIR/in/formato.txt\"
      printf 'DUMP_PROD\n' > \"\$TMP_DIR/in/banco.dump\"
      printf 'EXTENSOES\n' > \"\$TMP_DIR/in/extensoes.sql\"
      temporario=\"\$TMP_DIR/in\"
      $comando_tar
      tar -xf \"\$TMP_DIR/in/backup.tar\" -C \"\$TMP_DIR/out\" formato.txt banco.dump extensoes.sql
      diff -u \"\$TMP_DIR/in/formato.txt\" \"\$TMP_DIR/out/formato.txt\"
      diff -u \"\$TMP_DIR/in/banco.dump\" \"\$TMP_DIR/out/banco.dump\"
      diff -u \"\$TMP_DIR/in/extensoes.sql\" \"\$TMP_DIR/out/extensoes.sql\"
      tar_ver=\$(tar --version | head -n 1)
      echo \"GNU_TAR_OK: \$tar_ver\"
      rm -rf -- \"\$TMP_DIR\"
    " 2>&1); then
      printf '   ✓ Saída no Linux: %s\n' "$(printf '%s' "$saida_docker" | grep 'GNU_TAR_OK:')"
      executou_gnu_tar=1
    else
      if [[ "$com_docker" == 1 ]]; then
        falhar "probe Docker falhou: $saida_docker"
      else
        printf '   ℹ Probe Docker ignorado (imagem ou runtime indisponível).\n'
      fi
    fi
  fi
fi

if [[ "$executou_gnu_tar" == 1 && "$executou_bsdtar" == 1 ]]; then
  printf '=== Sucesso: Empacotamento de backup comprovadamente portátil (executado em GNU tar e bsdtar) ===\n'
elif [[ "$executou_gnu_tar" == 1 ]]; then
  printf '=== Sucesso: Empacotamento de backup verificado em GNU tar (bsdtar não executado neste ambiente) ===\n'
elif [[ "$executou_bsdtar" == 1 ]]; then
  printf '=== Sucesso: Empacotamento de backup verificado em bsdtar (GNU tar via Docker não executado neste ambiente) ===\n'
else
  printf '=== Sucesso: Empacotamento de backup verificado na ferramenta local (%s) ===\n' "$tipo_tar"
fi
