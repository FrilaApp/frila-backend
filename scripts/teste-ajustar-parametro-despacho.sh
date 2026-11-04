#!/usr/bin/env bash
# O ajuste de parâmetro do despacho recusa valor inválido, ensaia sem gravar e grava o
# que confirmou.
#
# O banco de teste é um banco NOVO no mesmo Postgres local, criado e destruído aqui.
# O banco compartilhado (`supabase_db_frila-backend`, de pé entre as worktrees) não é
# tocado: rodar o teste de escrita nele mudaria o raio do despacho debaixo de quem
# estivesse no meio de outro cartão.
#
#   ./scripts/teste-ajustar-parametro-despacho.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ALVO=scripts/ajustar-parametro-despacho.sh
DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"
BANCO="teste_param_despacho_$$"

falhas=0
ok()    { printf '  ✓ %s\n' "$1"; }
falha() { printf '  ✗ %s\n' "$1" >&2; falhas=$((falhas+1)); }

limpar() {
  docker exec -i "$DB_CONTAINER" dropdb -U postgres --if-exists "$BANCO" >/dev/null 2>&1 || true
}
trap limpar EXIT

echo "=== Testes do ajuste de parâmetro do despacho ==="

if ! docker exec -i "$DB_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
  echo "✗ o Postgres local ($DB_CONTAINER) não respondeu: supabase start antes" >&2
  exit 1
fi

docker exec -i "$DB_CONTAINER" createdb -U postgres "$BANCO" >/dev/null 2>&1 \
  || { echo "✗ não criei o banco de teste $BANCO" >&2; exit 1; }

# Só a parte da migração que este script usa: a tabela e a chave do raio. A função e o
# privado.elegiveis são do teste pgTAP 787, que roda sobre a migração inteira.
docker exec -i "$DB_CONTAINER" psql -U postgres -d "$BANCO" -X -q -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
create schema privado;
create table privado.parametro_despacho (
  chave        text primary key,
  valor_metros integer not null,
  descricao    text not null,
  constraint parametro_despacho_positivo check (valor_metros > 0),
  constraint parametro_despacho_teto     check (valor_metros <= 200000),
  constraint parametro_despacho_descrito check (length(btrim(descricao)) > 0)
);
insert into privado.parametro_despacho (chave, valor_metros, descricao)
values ('raio_maximo_metros', 15000, 'RN05: raio do despacho.');
SQL

export DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/$BANCO"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; limpar' EXIT

rodar() {
  "$ALVO" "$@" >"$TMP/saida" 2>&1
  codigo=$?
  saida="$(cat "$TMP/saida")"
  return 0
}

valor_no_banco() {
  psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 \
    -c "select valor_metros from privado.parametro_despacho where chave = 'raio_maximo_metros'"
}

# ── 1. Leitura ───────────────────────────────────────────────────────────────
echo "▸ 1. leitura"
rodar ler raio_maximo_metros
[ "$codigo" -eq 0 ] && ok "ler sai 0" || falha "ler: esperava 0, veio $codigo"
[ "$saida" = "15000" ] && ok "ler imprime só o valor em metros (15000)" || falha "ler imprimiu '$saida'"

rodar ler
[ "$codigo" -eq 0 ] && ok "ler sem chave lista tudo e sai 0" || falha "ler sem chave: esperava 0, veio $codigo"
case "$saida" in
  *raio_maximo_metros*15000*) ok "a listagem mostra a chave e o valor" ;;
  *) falha "a listagem não mostrou a chave: $saida" ;;
esac

rodar ler chave_que_nao_existe
[ "$codigo" -eq 1 ] && ok "chave ausente na leitura sai 1" || falha "chave ausente: esperava 1, veio $codigo"
case "$saida" in
  *"padrão da RN05"*) ok "diz que a função cai no padrão da RN05" ;;
  *) falha "não explicou o fallback da RN05" ;;
esac

# ── 2. Uso errado ────────────────────────────────────────────────────────────
echo "▸ 2. uso errado não escreve"
rodar definir
[ "$codigo" -eq 1 ] && ok "definir sem argumento sai 1" || falha "definir sem argumento: esperava 1, veio $codigo"
case "$saida" in
  *"uso: ajustar-parametro-despacho.sh"*) ok "imprime o uso" ;;
  *) falha "não imprimiu o uso" ;;
esac

rodar definir raio_maximo_metros doze-mil
[ "$codigo" -eq 1 ] && ok "valor não numérico sai 1" || falha "valor não numérico: esperava 1, veio $codigo"

rodar definir raio_maximo_metros 0 --sim
[ "$codigo" -eq 1 ] && ok "zero sai 1" || falha "zero: esperava 1, veio $codigo"

rodar definir raio_maximo_metros 250000 --sim
[ "$codigo" -eq 1 ] && ok "acima de 200 km sai 1" || falha "250000: esperava 1, veio $codigo"
case "$saida" in
  *"zero a mais"*) ok "explica por que existe teto" ;;
  *) falha "não explicou o teto" ;;
esac

rodar definir chave_que_nao_existe 12000 --sim
[ "$codigo" -eq 1 ] && ok "chave inexistente não é criada por este script" || falha "chave inexistente: esperava 1, veio $codigo"

[ "$(valor_no_banco)" = "15000" ] && ok "depois de todo uso errado, o banco segue em 15000" \
  || falha "o banco mudou durante o uso errado: $(valor_no_banco)"

# ── 3. Ensaio não grava ──────────────────────────────────────────────────────
echo "▸ 3. --seco não grava"
rodar definir raio_maximo_metros 12000 --seco
[ "$codigo" -eq 0 ] && ok "--seco sai 0" || falha "--seco: esperava 0, veio $codigo"
case "$saida" in
  *"nada foi gravado"*) ok "diz que não gravou" ;;
  *) falha "--seco não avisou que não grava" ;;
esac
[ "$(valor_no_banco)" = "15000" ] && ok "o banco segue em 15000 depois do ensaio" \
  || falha "--seco gravou: $(valor_no_banco)"

# ── 4. Escrita confirmada ────────────────────────────────────────────────────
echo "▸ 4. --sim grava e confere o que gravou"
rodar definir raio_maximo_metros 12000 --sim
[ "$codigo" -eq 0 ] && ok "--sim sai 0" || falha "--sim: esperava 0, veio $codigo"
[ "$(valor_no_banco)" = "12000" ] && ok "o banco lê 12000" || falha "o banco lê $(valor_no_banco), esperava 12000"
case "$saida" in
  *"era 15000 m"*) ok "a saída diz de onde veio e para onde foi" ;;
  *) falha "a saída não citou o valor anterior" ;;
esac

rodar definir raio_maximo_metros 12000 --sim
[ "$codigo" -eq 0 ] && ok "gravar o mesmo valor sai 0" || falha "mesmo valor: esperava 0, veio $codigo"
case "$saida" in
  *"já está nesse valor"*) ok "reconhece que não há o que fazer" ;;
  *) falha "não reconheceu o valor repetido" ;;
esac

# ── 5. Sem terminal, não grava em silêncio ───────────────────────────────────
echo "▸ 5. sem terminal e sem --sim, não grava"
"$ALVO" definir raio_maximo_metros 9000 >"$TMP/saida" 2>&1 </dev/null
codigo=$?
saida="$(cat "$TMP/saida")"
[ "$codigo" -eq 1 ] && ok "sem terminal para confirmar, sai 1" || falha "sem terminal: esperava 1, veio $codigo"
[ "$(valor_no_banco)" = "12000" ] && ok "o banco não mudou sem confirmação" \
  || falha "gravou sem confirmação: $(valor_no_banco)"

# ── 6. Tabela ausente é erro claro ───────────────────────────────────────────
echo "▸ 6. banco sem a migração"
psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -c "alter table privado.parametro_despacho rename to parametro_despacho_guardado" >/dev/null
rodar ler raio_maximo_metros
[ "$codigo" -eq 1 ] && ok "sem a tabela, sai 1" || falha "sem a tabela: esperava 1, veio $codigo"
case "$saida" in
  *20261104030000_parametros_despacho_configuraveis*) ok "diz qual migração aplicar" ;;
  *) falha "não citou a migração" ;;
esac

echo
if [ "$falhas" -eq 0 ]; then
  echo "✓ todos os casos passaram"
  exit 0
fi
echo "✗ $falhas verificação(ões) falharam" >&2
exit 1
