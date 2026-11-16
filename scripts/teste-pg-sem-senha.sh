#!/usr/bin/env bash
# Teste do scripts/pg-sem-senha.sh e dos 8 scripts que dão source nele (B-027.j): a senha da URL do banco nunca
# vai na linha de comando do psql, do pg_dump ou do python; vai só em PGPASSWORD, decodificada. Sem senha na URL,
# nada muda. Sem banco e sem rede: psql, pg_dump, docker, age e python3 de mentira no PATH guardam a linha de
# comando e o PGPASSWORD que receberam. Todas as URLs e senhas daqui são falsas (exemplo). Bash 3.2 e 5.
#
#   ./scripts/teste-pg-sem-senha.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
exec </dev/null   # nenhum psql de mentira espera a entrada do terminal
# shellcheck source=/dev/null
. scripts/pg-sem-senha.sh

casos=0
falhas=0
ok()    { casos=$((casos + 1)); printf '  ✓ %s\n' "$1"; }
falha() { casos=$((casos + 1)); falhas=$((falhas + 1)); printf '  ✗ %s\n' "$1" >&2; }
igual() { if [ "$2" = "$3" ]; then ok "$1"; else falha "$1: veio [$2], esperava [$3]"; fi; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/frila-teste-pg-sem-senha.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
H=db.exemplo.invalid

# ── 1. separar_senha_da_url ───────────────────────────────────────────────────
echo "▸ 1. separar_senha_da_url"
caso() { # caso <nome> <url> <url sem senha esperada> <senha esperada>
  if separar_senha_da_url "$2" 2>"$TMP/erro"; then
    igual "$1: URL sem senha" "$PG_URL_SEM_SENHA" "$3"
    igual "$1: senha" "$PG_SENHA" "$4"
  else
    falha "$1: recusou ($(cat "$TMP/erro"))"
  fi
}
recusa() { # recusa <nome> <url> <trecho da senha, que não pode aparecer no erro>
  if separar_senha_da_url "$2" 2>"$TMP/erro"; then
    falha "$1: aceitou"
  elif [ -n "$PG_URL_SEM_SENHA$PG_SENHA" ]; then
    falha "$1: recusou, mas deixou valor nas variáveis"
  elif grep -F -q -- "$3" "$TMP/erro"; then
    falha "$1: o erro mostrou a senha"
  else
    ok "$1: recusou sem mostrar a URL"
  fi
}
caso "com senha" "postgresql://u_exemplo:exemplo-senha@$H:5432/postgres" "postgresql://u_exemplo@$H:5432/postgres" "exemplo-senha"
caso "sem senha (não mexe)" "postgresql://u_exemplo@$H:5432/postgres" "postgresql://u_exemplo@$H:5432/postgres" ""
caso "sem usuário (não mexe)" "postgresql://$H/postgres" "postgresql://$H/postgres" ""
caso "senha vazia (não mexe)" "postgresql://u_exemplo:@$H/postgres" "postgresql://u_exemplo:@$H/postgres" ""
caso "%40 e %3A na senha" "postgresql://u_exemplo:exemplo%40com%3Adois@$H:6543/postgres" "postgresql://u_exemplo@$H:6543/postgres" "exemplo@com:dois"
caso "%25 %2F %3F %23 %5C na senha" "postgresql://u_exemplo:exemplo%25%2F%3F%23%5C@$H/postgres" "postgresql://u_exemplo@$H/postgres" "exemplo%/?#\\"
caso "UTF-8 codificado" "postgresql://u_exemplo:exemplo%C3%A9@$H/postgres" "postgresql://u_exemplo@$H/postgres" "exemploé"
caso ": cru na senha (o libpq aceita)" "postgresql://u_exemplo:exemplo:cru@$H/postgres" "postgresql://u_exemplo@$H/postgres" "exemplo:cru"
caso "porta e ?sslmode" "postgresql://u_exemplo:exemplo-p@$H:6543/frila?sslmode=require&connect_timeout=5" \
     "postgresql://u_exemplo@$H:6543/frila?sslmode=require&connect_timeout=5" "exemplo-p"
caso "postgres:// e sem barra" "postgres://u_exemplo:exemplo-s@$H:5432" "postgres://u_exemplo@$H:5432" "exemplo-s"
recusa "% sem dois dígitos" "postgresql://u_exemplo:exemplo%zz@$H/postgres" "exemplo%zz"
recusa "%00" "postgresql://u_exemplo:exemplo%00@$H/postgres" "exemplo%00"
recusa "password= nos parâmetros" "postgresql://u_exemplo@$H/postgres?sslmode=require&password=exemplo-q" "exemplo-q"
recusa "não é postgres" "mysql://u_exemplo:exemplo-m@$H/db" "exemplo-m"

# ── psql, pg_dump, docker, age e python3 de mentira ───────────────────────────
mkdir -p "$TMP/bin"
PYTHON_REAL=$(command -v python3)
cat > "$TMP/bin/psql" <<'EOF'
#!/usr/bin/env bash
printf 'psql %s\n' "$*" >> "$TESTE_LINHAS"
printf '%s\n' "${PGPASSWORD-<ausente>}" >> "$TESTE_SENHAS"
case "$*" in *server_version_num*) echo 170006; exit 0 ;; esac
# Como o \! do psql de verdade: roda a linha do shell com o ambiente do psql (o backup lógico usa).
if [ ! -t 0 ]; then
  while IFS= read -r linha; do
    case "$linha" in '\! '*) BACKUP_SNAPSHOT=00000003-00000001-1 sh -c "${linha#\\! }" ;; esac
  done
fi
exit 0
EOF
cat > "$TMP/bin/pg_dump" <<'EOF'
#!/usr/bin/env bash
case "$*" in *--version*) echo 'pg_dump (PostgreSQL) 17.6'; exit 0 ;; esac
printf 'pg_dump %s\n' "$*" >> "$TESTE_LINHAS"
printf '%s\n' "${PGPASSWORD-<ausente>}" >> "$TESTE_SENHAS"
exit 0
EOF
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$TESTE_LINHAS"
exit 1
EOF
cat > "$TMP/bin/age" <<'EOF'
#!/usr/bin/env bash
case "$*" in *--version*) echo 'age 1.2.0'; exit 0 ;; esac
anterior=""
for a in "$@"; do [ "$anterior" = --output ] && : > "$a"; anterior=$a; done
exit 0
EOF
printf '#!/usr/bin/env bash\nprintf "python3 %%s\\n" "$*" >> "$TESTE_PYTHON"\nexec "%s" "$@"\n' "$PYTHON_REAL" > "$TMP/bin/python3"
chmod +x "$TMP/bin/"*
export TESTE_LINHAS="$TMP/linhas" TESTE_SENHAS="$TMP/senhas" TESTE_PYTHON="$TMP/python"
zerar() { : > "$TESTE_LINHAS"; : > "$TESTE_SENHAS"; : > "$TESTE_PYTHON"; }

# ── 2. psql_url e com_senha_da_url ────────────────────────────────────────────
echo "▸ 2. psql_url (a senha só no ambiente do filho)"
URL_TESTE="postgresql://u_exemplo:exemplo%40com%3Adois@$H:6543/postgres?sslmode=require"
zerar
( unset PGPASSWORD; PATH="$TMP/bin:$PATH" psql_url "$URL_TESTE" -X -c "select 1" )
igual "com senha: a linha do psql leva a URL sem a senha" "$(cat "$TESTE_LINHAS")" \
      "psql postgresql://u_exemplo@$H:6543/postgres?sslmode=require -X -c select 1"
igual "com senha: PGPASSWORD decodificado" "$(cat "$TESTE_SENHAS")" "exemplo@com:dois"
zerar
( unset PGPASSWORD; PATH="$TMP/bin:$PATH" psql_url "postgresql://u_exemplo@$H/postgres" -c "select 1" )
igual "sem senha: a URL vai igual" "$(cat "$TESTE_LINHAS")" "psql postgresql://u_exemplo@$H/postgres -c select 1"
igual "sem senha: PGPASSWORD continua ausente" "$(cat "$TESTE_SENHAS")" "<ausente>"
zerar
( export PGPASSWORD=exemplo-herdada; PATH="$TMP/bin:$PATH" psql_url "postgresql://u_exemplo@$H/postgres" -c "select 1" )
igual "sem senha: vale o PGPASSWORD de quem chamou" "$(cat "$TESTE_SENHAS")" "exemplo-herdada"
zerar
depois=$( export PGPASSWORD=exemplo-herdada; PATH="$TMP/bin:$PATH" psql_url "$URL_TESTE" -c "select 1"; printf '%s' "$PGPASSWORD" )
igual "com senha e PGPASSWORD herdado: vale a senha da URL (como no libpq)" "$(cat "$TESTE_SENHAS")" "exemplo@com:dois"
igual "com senha: depois da chamada o PGPASSWORD do shell não mudou" "$depois" "exemplo-herdada"

# ── 3. os 8 scripts, com o mesmo psql de mentira ──────────────────────────────
echo "▸ 3. os 8 scripts: nenhuma senha na linha de comando, PGPASSWORD decodificado"
SENHA_COD="exemplo%40senha%3Afalsa"
SENHA="exemplo@senha:falsa"
URL_SCRIPTS="postgresql://u_exemplo:$SENHA_COD@127.0.0.1:5432/postgres?sslmode=disable"
mkdir -p "$TMP/backup"
roda_script() { # roda_script <nome> <variável da URL> <script e argumentos...>
  local nome=$1 var=$2
  shift 2
  zerar
  # Num subshell com export (e não `env VAR=...`, que poria a URL na linha de comando do próprio env).
  ( export PATH="$TMP/bin:$PATH" BACKUP_PUBLIC_KEY=age1exemplo BACKUP_DIR="$TMP/backup" BACKUP_CIPHER=age \
           GITHUB_STEP_SUMMARY="$TMP/resumo"
    export "$var=$URL_SCRIPTS"
    "$@" </dev/null >"$TMP/saida" 2>&1 )
  if ! grep -q -E '^(psql|pg_dump) ' "$TESTE_LINHAS"; then
    falha "$nome: nenhum psql/pg_dump chamado (saída: $(head -c 200 "$TMP/saida"))"
    return
  fi
  if grep -F -q -e "$SENHA_COD" -e "$SENHA" "$TESTE_LINHAS" "$TESTE_PYTHON"; then
    falha "$nome: a senha foi na linha de comando"
  elif grep -q '^docker ' "$TESTE_LINHAS"; then
    falha "$nome: foi ao docker com a DATABASE_URL definida"
  elif grep -v -x -F -q "$SENHA" "$TESTE_SENHAS"; then
    falha "$nome: algum psql/pg_dump não recebeu PGPASSWORD decodificado"
  elif grep -F -q -e "$SENHA_COD" -e "$SENHA" "$TMP/saida"; then
    falha "$nome: a senha apareceu na saída do script"
  else
    ok "$nome: $(grep -c -E '^(psql|pg_dump) ' "$TESTE_LINHAS") chamada(s) sem senha na linha, PGPASSWORD certo$(
      [ -s "$TESTE_PYTHON" ] && printf ', python3 sem senha')"
  fi
}
roda_script "ajustar-parametro-despacho" DATABASE_URL ./scripts/ajustar-parametro-despacho.sh ler
roda_script "checagem-diaria" DATABASE_URL ./scripts/checagem-diaria.sh
roda_script "checkin-por-codigo-casa" DATABASE_URL ./scripts/checkin-por-codigo-casa.sh estado
roda_script "funil" DATABASE_URL ./scripts/funil.sh --json
roda_script "gerar-painel" DATABASE_URL ./scripts/gerar-painel.sh -o "$TMP/painel.html"
roda_script "medir-despacho-remoto" DATABASE_URL ./scripts/medir-despacho-remoto.sh
roda_script "medir-rnf" DATABASE_URL ./scripts/medir-rnf.sh -n 1
roda_script "backup-logico" BACKUP_DB_URL ./scripts/backup-logico.sh
if grep -q '^pg_dump .*--dbname postgresql://u_exemplo@127.0.0.1:5432/postgres?sslmode=disable' "$TESTE_LINHAS"; then
  ok "backup-logico: o pg_dump do \\! recebeu a URL sem a senha"
else
  falha "backup-logico: o pg_dump do \\! não recebeu a URL sem a senha"
fi

echo
if [ "$falhas" -eq 0 ]; then echo "Todos os $casos casos passaram."; exit 0; fi
echo "$falhas de $casos casos falharam."
exit 1
