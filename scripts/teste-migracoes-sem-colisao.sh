#!/usr/bin/env bash
# Testa o portão `migracoes-sem-colisao.sh` contra pastas de migração de mentira.
#
# O portão vizinho, `contrato-acompanha-o-codigo.sh`, tem autoteste desde que um furo dele
# deixou passar o PR #3; este nasceu sem, e o furo apareceu do mesmo jeito: a versão era
# lida como "o que vem antes do primeiro `_`", e um arquivo sem `_` no nome passava como
# versão distinta — contado como migração legítima, embora a CLI o ignore em silêncio.
#
# Cada caso abaixo monta uma pasta descartável com o portão dentro e confere o código de
# saída **e** a frase que explica o veredito. Sair 1 por um motivo qualquer não conta como
# reprovar pelo motivo certo, e é exatamente como um portão furado aprova calado.
#
#   ./scripts/teste-migracoes-sem-colisao.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PORTAO="$PWD/scripts/migracoes-sem-colisao.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

# Monta a pasta: o portão em `scripts/`, e `supabase/migrations/` vazia.
#
# Com `SEM_PASTA=1`, a pasta de migrações não é criada — é o caminho em que o portão não
# tem o que medir, e a regra do repositório é que caminho que não mediu sai diferente de
# zero.
montar_base() {
  local dir="$1"
  mkdir -p "$dir/scripts"
  cp "$PORTAO" "$dir/scripts/"
  [ "${SEM_PASTA:-0}" = "1" ] || mkdir -p "$dir/supabase/migrations"
}

# caso <nome> <saída esperada> <frase esperada> [arquivos de migração…]
caso() {
  local nome="$1" esperado="$2" frase="$3"; shift 3
  local dir="$TMP/caso$casos"
  casos=$((casos + 1))
  montar_base "$dir"
  local f
  for f in "$@"; do : > "$dir/supabase/migrations/$f"; done

  local saida codigo
  saida=$("$dir/scripts/migracoes-sem-colisao.sh" 2>&1)
  codigo=$?

  if [ "$codigo" = "$esperado" ] && printf '%s\n' "$saida" | grep -qF "$frase"; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperava saída $esperado com \"$frase\", veio $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Portão: migrações sem colisão de versão"

# ── A colisão, que é o motivo de o portão existir ──────────────────────────────
caso "duas migrações na mesma versão reprovam" 1 \
  "Duas ou mais migrações com a mesma versão" \
  20260927010000_a.sql 20260927010000_b.sql

# Nomear os arquivos é metade do portão: `uniq -d` sozinho diria que existe uma versão
# repetida sem dizer quais arquivos renomear, e quem lê o vermelho está com pressa.
caso "a saída nomeia o primeiro arquivo colidido" 1 "20260927010000_a.sql" \
  20260927010000_a.sql 20260927010000_b.sql

caso "a saída nomeia o segundo arquivo colidido" 1 "20260927010000_b.sql" \
  20260927010000_a.sql 20260927010000_b.sql

# A sugestão tem de trazer o número pronto. Com `<versao>` no lugar dele, quem conserta
# volta à lista de cima para completar o comando.
caso "a versão sugerida é a versão mais um" 1 \
  "supabase/migrations/20260927010001_<nome>.sql" \
  20260927010000_a.sql 20260927010000_b.sql

# Três na mesma versão acontece num merge de três branches, e o portão tem de listar os
# três — não os dois primeiros.
caso "três na mesma versão: o primeiro é listado" 1 "20260927010000_a.sql" \
  20260927010000_a.sql 20260927010000_b.sql 20260927010000_c.sql

caso "três na mesma versão: o segundo é listado" 1 "20260927010000_b.sql" \
  20260927010000_a.sql 20260927010000_b.sql 20260927010000_c.sql

caso "três na mesma versão: o terceiro é listado" 1 "20260927010000_c.sql" \
  20260927010000_a.sql 20260927010000_b.sql 20260927010000_c.sql

# ── Os caminhos que não mediram ────────────────────────────────────────────────
SEM_PASTA=1 caso "pasta de migrações ausente não é verde" 2 \
  "supabase/migrations não existe"

caso "pasta de migrações vazia não é verde" 2 \
  "Nenhuma migração em supabase/migrations"

# ── O caminho verde ───────────────────────────────────────────────────────────
caso "versões distintas passam" 0 "As 2 migrações têm versões distintas." \
  20260927010000_a.sql 20260927010001_b.sql

# ── O nome que a CLI ignora em silêncio ───────────────────────────────────────
#
# `MIGRATE_FILE_PATTERN` é `/^([0-9]+)_(.*)\.sql$/`: sem o `_`, a CLI não aplica o arquivo
# e não registra a versão — *"Skipping migration … (file name must match pattern
# <timestamp>_name.sql)"*. Antes deste caso, o portão lia a versão como
# `20260927010000.sql`, achava que era distinta de `20260927010000` e saía **0** dizendo
# que as duas migrações tinham versões distintas, sobre um par em que uma delas não existe
# para a CLI.
caso "arquivo sem _ no nome reprova" 1 \
  "Arquivo que a CLI do Supabase ignora em silêncio" \
  20260927010000.sql 20260927010000_b.sql

caso "o arquivo que a CLI ignoraria é nomeado" 1 "20260927010000.sql" \
  20260927010000.sql 20260927010000_b.sql

# ── A versão com zero à esquerda ───────────────────────────────────────────────
#
# `$((v + 1))` lê a versão como número, e número que começa com `0` o bash lê em base 8:
# `020260927010000` tem dígitos 8 e 9, que não existem em octal, e a expansão falha com
# *"value too great for base"*. O erro aborta o corpo do `while` **sem** disparar o
# `set -e`, a execução retoma depois do `done` e pula o `exit 1` do bloco de colisão — o
# portão imprime a colisão e sai **0** dizendo que as versões são distintas. Medido em
# bash 3.2.57 e 5.2.21.
#
# A frase conferida é a do rodapé, e não a do cabeçalho, de propósito: o cabeçalho a
# versão com o furo **imprime**, e um caso que o afirmasse seguiria verde sobre o portão
# quebrado, pego só pelo código de saída. O rodapé é a última linha antes do `exit 1`, e
# é exatamente o que o furo pula.
caso "colisão em versão com zero à esquerda reprova" 1 \
  "A versão é chave primária em supabase_migrations.schema_migrations" \
  020260927010000_a.sql 020260927010000_b.sql

echo
if [ "$falhas" -ne 0 ]; then
  echo "$falhas de $casos casos falharam."
  exit 1
fi
echo "Os $casos casos passaram."
