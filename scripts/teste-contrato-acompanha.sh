#!/usr/bin/env bash
# Testa o portão `contrato-acompanha-o-codigo.sh` contra repositórios de mentira.
#
# Um portão que ninguém testa é um portão que ninguém sabe se ainda fecha: o furo da
# quebra de linha ficou aberto até o PR #3 passar por ele sem ser visto. Cada caso
# abaixo monta um repositório git descartável com uma base (contrato + migrações), um
# commit de PR por cima, e confere o código de saída **e** a frase que explica o
# veredito — sair 1 por um motivo qualquer não conta como reprovar pelo motivo certo.
#
#   ./scripts/teste-contrato-acompanha.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PORTAO="$PWD/scripts/contrato-acompanha-o-codigo.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

CONTRATO_BASE='openapi: 3.1.0
info:
  title: Frila API
  version: 0.2.17
paths:
  /rpc/ja_no_ar:
    post:
      operationId: jaNoAr
  /rpc/declarada_sem_codigo:
    post:
      operationId: declaradaSemCodigo'

# Monta a base: o contrato acima e uma migração que já cria `public.ja_no_ar`.
#
# Com `CONTRATO_GRANDE=1`, o contrato ganha milhares de linhas depois das rotas, como o
# de verdade (2 mil e tantas). Um `printf | grep -q` sob `pipefail` passa num contrato
# pequeno e falha num grande: o `grep -q` sai no primeiro acerto, o `printf` que ainda
# escrevia leva SIGPIPE, e o pipeline vira 141 — falso. Foi assim que a primeira versão
# da isenção passou em todos os casos daqui e reprovou o PR #43 que devia destravar.
montar_base() {
  local dir="$1"
  mkdir -p "$dir/scripts" "$dir/contrato" "$dir/supabase/migrations"
  cp "$PORTAO" "$dir/scripts/"
  printf '%s\n' "$CONTRATO_BASE" > "$dir/contrato/openapi.yaml"
  if [ "${CONTRATO_GRANDE:-0}" = "1" ]; then
    for i in $(seq 1 5000); do
      printf '  /rpc/enchimento_%s:\n    post:\n      operationId: enchimento%s\n' "$i" "$i"
    done >> "$dir/contrato/openapi.yaml"
  fi
  printf '%s\n' 'create or replace function public.ja_no_ar() returns int language sql as $$ select 1 $$;' \
    > "$dir/supabase/migrations/20260901000000_base.sql"
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.name=t -c user.email=t@t add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q -m base
  git -C "$dir" branch -q base
}

# caso <nome> <saída esperada> <frase esperada> <sql da migração do PR> [versão nova do contrato]
caso() {
  local nome="$1" esperado="$2" frase="$3" sql="$4" versao="${5:-}"
  local dir="$TMP/caso$casos"
  casos=$((casos + 1))
  montar_base "$dir"
  printf '%s\n' "$sql" > "$dir/supabase/migrations/20260926999999_pr.sql"
  if [ -n "$versao" ]; then
    sed -i.bak "s/^  version: .*/  version: $versao/" "$dir/contrato/openapi.yaml"
    rm -f "$dir/contrato/openapi.yaml.bak"
  fi
  git -C "$dir" -c user.name=t -c user.email=t@t add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q -m pr

  local saida codigo
  saida=$("$dir/scripts/contrato-acompanha-o-codigo.sh" base 2>&1)
  codigo=$?

  if [ "$codigo" = "$esperado" ] && printf '%s\n' "$saida" | grep -qF "$frase"; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperava saída $esperado com \"$frase\", veio $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Portão: o contrato acompanhou o código"

caso "função nova sem contrato reprova" 1 "O contrato não acompanhou o código." \
'create or replace function public.nova_sem_contrato() returns int language sql as $$ select 1 $$;'

caso "função já declarada no contrato da base, primeira implementação, passa" 0 \
"Nada a exigir do contrato." \
'create or replace function public.declarada_sem_codigo(token text) returns jsonb language sql as $$ select null::jsonb $$;'

caso "declaração com quebra de linha antes do nome é detectada" 1 "public.nova_quebrada" \
'create or replace function
  public.nova_quebrada(p uuid)
returns int language sql as $$ select 1 $$;'

caso "quebra de linha e espaços em volta do ponto são detectados" 1 "public.nova_espacada" \
'create   or   replace
function
    public . nova_espacada() returns int language sql as $$ select 1 $$;'

caso "declarada com quebra de linha, primeira implementação, passa" 0 \
"public.declarada_sem_codigo" \
'create or replace function
  public.declarada_sem_codigo(token text)
returns jsonb language sql as $$ select null::jsonb $$;'

caso "mudar RPC já implementada na base continua exigindo o contrato" 1 \
"O contrato não acompanhou o código." \
'create or replace function public.ja_no_ar(p int) returns int language sql as $$ select p $$;'

caso "reimplementação de RPC já no ar com mesma assinatura passa sem mexer no contrato" 0 \
"Nada a exigir do contrato." \
'create or replace function public.ja_no_ar() returns int language sql as $$ select 2 $$;'

caso "drop de RPC declarada continua exigindo o contrato" 1 \
"O contrato não acompanhou o código." \
'drop function public.declarada_sem_codigo(text);'

caso "função nova com contrato atualizado e versão subindo passa" 0 \
"O contrato acompanhou o código." \
'create or replace function public.nova_com_contrato() returns int language sql as $$ select 1 $$;' \
'0.2.18'

CONTRATO_GRANDE=1 caso "contrato do tamanho do real, primeira implementação, passa" 0 \
"Nada a exigir do contrato." \
'create or replace function public.declarada_sem_codigo(token text) returns jsonb language sql as $$ select null::jsonb $$;'

caso "comentário de linha entre function e o nome é detectado" 1 "public.nova_comentada" \
'create or replace function -- a RPC do cartão
  public.nova_comentada() returns int language sql as $$ select 1 $$;'

caso "comentário de bloco entre function e o nome é detectado" 1 "public.nova_em_bloco" \
'create or replace function /* nota
   de duas linhas */ public.nova_em_bloco() returns int language sql as $$ select 1 $$;'

caso "comentário com create function não conta" 0 "Nenhuma função de public tocada" \
'-- create or replace function public.so_no_comentario() era o plano'

echo
if [ "$falhas" -ne 0 ]; then
  echo "$falhas de $casos casos falharam."
  exit 1
fi
echo "Os $casos casos passaram."
