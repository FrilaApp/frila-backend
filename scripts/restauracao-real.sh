#!/usr/bin/env bash
# Restauração real de um backup cifrado do Prod (pacote v2 .tar.age) num Postgres descartável em contêiner SEM REDE
# (cartão U3RlsJF7, B-039). Mede os tempos (RTO) e confere as contagens de linhas por tabela.
#
# Uso (os segredos ficam em arquivo ou no ambiente, nunca na linha de comando):
#   ARQUIVO_CIFRADO=<caminho do .tar.age> CHAVE_PRIVADA=<caminho da identidade age> SAIDA=<pasta> \
#     [PROD_DB_URL=<conexão, só no ambiente>] ./scripts/restauracao-real.sh
#
# O que faz:
#   1. sobe o Postgres da imagem do Supabase num contêiner com `--network none` (sem porta e sem saída para a rede:
#      os jobs do pg_cron e o pg_net restaurados não alcançam nada) e com `cron.launch_active_jobs = off`;
#   2. decifra com age numa pasta temporária 0700 e confere o formato v2;
#   3. conta as linhas que o próprio pacote traz (COPY do banco.dump + suplemento extensoes.sql), sem mostrar linha;
#   4. restaura (`pg_restore --single-transaction --exit-on-error --no-owner` + suplemento) e regenera a chave dos
#      links de foto (privado.chave_cursor_busca), para a cópia não conseguir cunhar link vivo do Prod;
#   5. conta as linhas do restaurado e, com PROD_DB_URL, as do Prod numa transação REPEATABLE READ READ ONLY;
#   6. apaga o decifrado (também na falha, pelo trap) e remove o contêiner.
#
# Nunca conta nem lê `privado.registro_acesso*` (decisão do Cauê, 08/11/2026): essas tabelas ficam fora do TOC da
# contagem e da consulta. A SAIDA recebe só nomes de tabela, números e tempos (nada de linha, chave ou conexão).
set +x
set -Eeuo pipefail
umask 077

: "${ARQUIVO_CIFRADO:?defina ARQUIVO_CIFRADO (caminho do .tar.age)}"
: "${CHAVE_PRIVADA:?defina CHAVE_PRIVADA (caminho da identidade age)}"
: "${SAIDA:?defina SAIDA (pasta para tempos e contagens, fora do Git)}"
IMAGEM="${IMAGEM:-public.ecr.aws/supabase/postgres:17.6.1.075}"
BANCO=ensaio
C="frila-restauracao-$(date +%Y%m%d%H%M%S)"

case "$ARQUIVO_CIFRADO" in *.tar.age) ;; *) echo "ERRO: só pacote v2 .tar.age" >&2; exit 2 ;; esac
[ -s "$ARQUIVO_CIFRADO" ] || { echo "ERRO: arquivo cifrado ausente ou vazio" >&2; exit 2; }
[ -s "$CHAVE_PRIVADA" ] || { echo "ERRO: identidade age ausente" >&2; exit 2; }
for cmd in age docker pg_restore tar perl awk openssl shasum; do
  command -v "$cmd" >/dev/null || { echo "ERRO: falta $cmd no PATH" >&2; exit 2; }
done
# O pg_restore do Mac lê o archive do pg_dump 17: precisa ser 17 ou mais novo (ponha o postgresql@17 antes no PATH).
versao_pg=$(pg_restore --version | awk '{ print $3 }'); versao_pg=${versao_pg%%.*}
[ "$versao_pg" -ge 17 ] || { echo "ERRO: pg_restore $versao_pg; use o 17 ou mais novo" >&2; exit 2; }
mkdir -p "$SAIDA"
if git -C "$SAIDA" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERRO: SAIDA está dentro de um repositório Git" >&2; exit 2
fi

agora() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
TEMPOS="$SAIDA/tempos.tsv"
: > "$TEMPOS"
marcar() { awk -v a="$2" -v b="$3" -v e="$1" 'BEGIN { printf "%s\t%.3f\n", e, b - a }' >> "$TEMPOS"; }
# Erro de ferramenta sem dado: só as linhas de erro, cortadas, com valores entre aspas mascarados (menos nome de papel).
erro_seguro() { grep -E 'error|ERROR' "$1" | sed -E '/role "/!s/"[^"]*"/"…"/g' | cut -c1-240 | head -8 >&2 || true; }

tmp=""
criou_conteiner=0
limpar() {
  local codigo=$?
  set +e
  if [ -n "$tmp" ] && [ -d "$tmp" ]; then
    rm -rf -- "${tmp:?}"/* "${tmp:?}"/.[!.]* 2>/dev/null
    echo "pasta temporária do decifrado depois da limpeza (ls -A): [$(ls -A "$tmp")]"
    rmdir -- "$tmp" && echo "pasta temporária removida: $( [ -e "$tmp" ] && echo NÃO || echo sim)"
  fi
  if [ "$criou_conteiner" -eq 1 ]; then
    docker rm -f "$C" >/dev/null 2>&1
    echo "contêineres com o nome $C depois da limpeza: $(docker ps -a --filter "name=^${C}\$" --format '{{.Names}}' | wc -l | tr -d ' ')"
  fi
  exit "$codigo"
}
trap limpar EXIT
trap 'exit 130' INT TERM

tmp=$(mktemp -d "${TMPDIR:-/tmp}/frila-restauracao.XXXXXX")
chmod 700 "$tmp"
psql_c() { docker exec -i "$C" psql -X -q -h localhost -U supabase_admin -v ON_ERROR_STOP=1 "$@"; }
esperar_pronto() {
  local fim=$(( $(date +%s) + 180 ))
  until docker exec "$C" pg_isready -q -h localhost -U supabase_admin -d postgres 2>/dev/null; do
    [ "$(date +%s)" -lt "$fim" ] || { echo "ERRO: Postgres do contêiner não ficou pronto" >&2; return 1; }
    sleep 0.5
  done
}

echo "arquivo: $(basename "$ARQUIVO_CIFRADO") · $(wc -c < "$ARQUIVO_CIFRADO" | tr -d ' ') bytes · sha256 $(shasum -a 256 "$ARQUIVO_CIFRADO" | cut -c1-16)…"
T_INICIO=$(agora)

# 1. Destino descartável sem rede.
t0=$(agora)
printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 24)" > "$tmp/env"
docker run -d --name "$C" --network none --env-file "$tmp/env" "$IMAGEM" >/dev/null
criou_conteiner=1
rm -f -- "$tmp/env"
fim=$(( $(date +%s) + 180 ))
until docker logs "$C" 2>&1 | grep -q 'init process complete'; do
  [ "$(date +%s)" -lt "$fim" ] || { echo "ERRO: a imagem não terminou o init" >&2; exit 1; }
  sleep 0.5
done
esperar_pronto
psql_c -d postgres >/dev/null <<SQL
do \$\$ begin
  if not exists (select 1 from pg_roles where rolname = 'supabase_functions_admin') then create role supabase_functions_admin nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'supabase_realtime_admin') then create role supabase_realtime_admin nologin; end if;
end \$\$;
create database $BANCO;
alter system set cron.database_name = '$BANCO';
alter system set cron.launch_active_jobs = off;
SQL
docker restart "$C" >/dev/null
esperar_pronto
[ "$(psql_c -d postgres -Atc 'show cron.launch_active_jobs')" = off ] || { echo "ERRO: jobs do pg_cron não desligaram" >&2; exit 1; }
[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$C")" = none ] || { echo "ERRO: contêiner com rede" >&2; exit 1; }
t1=$(agora); marcar provisionar_destino "$t0" "$t1"

# 2. Decifrar e conferir o formato (sem pipe para o banco: o age só garante a autenticação no fim).
t0=$(agora)
age --decrypt --identity "$CHAVE_PRIVADA" --output "$tmp/pacote" "$ARQUIVO_CIFRADO" >/dev/null 2>&1 \
  || { echo "ERRO: age não decifrou (chave errada ou arquivo adulterado)" >&2; exit 1; }
t1=$(agora); marcar decifrar "$t0" "$t1"
t0=$(agora)
tar -xf "$tmp/pacote" -C "$tmp" formato.txt banco.dump extensoes.sql
rm -f -- "$tmp/pacote"
[ "$(cat "$tmp/formato.txt")" = frila-backup-v2 ] || { echo "ERRO: formato do pacote não é frila-backup-v2" >&2; exit 1; }
t1=$(agora); marcar extrair_pacote "$t0" "$t1"
echo "formato: $(cat "$tmp/formato.txt") · banco.dump $(wc -c < "$tmp/banco.dump" | tr -d ' ') bytes · extensoes.sql $(wc -c < "$tmp/extensoes.sql" | tr -d ' ') bytes"

# 3. O que o próprio pacote traz: linhas de cada COPY (o texto do COPY tem uma linha por registro).
# O suplemento escreve `TRUNCATE ONLY x; COPY x (...) FROM stdin;` na mesma linha; o dump, `COPY x (...) FROM stdin;`.
contar_copy() { awk '!dentro && /COPY [^ ]+ .*FROM stdin;$/ { t = $0; sub(/.*COPY /, "", t); sub(/ .*/, "", t); gsub(/"/, "", t); n = 0; dentro = 1; next }
                     dentro && /^\\\.$/ { print t "\t" n; dentro = 0; next }
                     dentro { n++ }'; }
pg_restore -l "$tmp/banco.dump" > "$tmp/toc"
grep -c ' TABLE DATA ' "$tmp/toc" | sed 's/^/itens TABLE DATA no TOC: /'
{ grep -E ' TABLE DATA privado registro_acesso' "$tmp/toc" || true; } | awk '{ print "fora da contagem (regra do registro de acesso): " $(NF-2) "." $(NF-1) }'
grep -v -E ' TABLE DATA privado registro_acesso' "$tmp/toc" > "$tmp/toc-contagem"
pg_restore -L "$tmp/toc-contagem" --data-only -f - "$tmp/banco.dump" | contar_copy | sort > "$SAIDA/contagem-dump.tsv"
contar_copy < "$tmp/extensoes.sql" | sort > "$SAIDA/contagem-suplemento.tsv"

# 4. Restaurar.
t0=$(agora)
docker exec "$C" sh -c 'mkdir -m 700 /tmp/restauracao'
docker cp "$tmp/banco.dump" "$C:/tmp/restauracao/banco.dump" >/dev/null
docker cp "$tmp/extensoes.sql" "$C:/tmp/restauracao/extensoes.sql" >/dev/null
rm -f -- "$tmp/banco.dump" "$tmp/extensoes.sql"
t1=$(agora); marcar copiar_para_destino "$t0" "$t1"
t0=$(agora)
docker exec "$C" pg_restore -h localhost -U supabase_admin -d "$BANCO" --exit-on-error --single-transaction --no-owner \
  /tmp/restauracao/banco.dump >/dev/null 2>"$tmp/erro" || { echo "ERRO: pg_restore falhou:" >&2; erro_seguro "$tmp/erro"; exit 1; }
t1=$(agora); marcar pg_restore "$t0" "$t1"
t0=$(agora)
psql_c -d "$BANCO" --single-transaction -f /tmp/restauracao/extensoes.sql >/dev/null 2>"$tmp/erro" \
  || { echo "ERRO: suplemento falhou:" >&2; erro_seguro "$tmp/erro"; exit 1; }
t1=$(agora); marcar suplemento "$t0" "$t1"
docker exec "$C" rm -rf /tmp/restauracao
T_FIM_RESTAURO=$(agora)
psql_c -d "$BANCO" >/dev/null <<'SQL'
do $$ begin
  if to_regclass('privado.chave_cursor_busca') is not null then
    update privado.chave_cursor_busca set chave = extensions.gen_random_bytes(32);
  end if;
end $$;
SQL

# 5. Contagens (tabela comum, fora do catálogo; sem privado.registro_acesso*).
CONSULTA="select n.nspname || '.' || c.relname,
  case when has_table_privilege(c.oid, 'SELECT')
    then (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', n.nspname, c.relname), false, true, '')))[1]::text
    else 'sem_privilegio' end
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind = 'r' and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname !~ '^pg_toast'
  and not (n.nspname = 'privado' and c.relname like 'registro\\_acesso%')
order by 1;"
psql_c -d "$BANCO" -At -F $'\t' -c "$CONSULTA" | sort > "$SAIDA/contagem-restaurado.tsv"
# Tabelas que pertencem a uma extensão: o CREATE EXTENSION pode trazer linhas próprias (o spatial_ref_sys do PostGIS),
# que o pg_dump não exporta (só as linhas que o usuário acrescentou, pelo filtro do extconfig).
psql_c -d "$BANCO" -At -c "select n.nspname || '.' || c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
  join pg_depend d on d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e' where c.relkind = 'r' order by 1" \
  > "$SAIDA/tabelas-de-extensao.txt"

if [ -n "${PROD_DB_URL:-}" ]; then
  command -v psql >/dev/null || { echo "ERRO: falta psql" >&2; exit 2; }
  # shellcheck source=/dev/null
  . "$(dirname -- "${BASH_SOURCE[0]}")/pg-sem-senha.sh"
  separar_senha_da_url "$PROD_DB_URL"
  unset PROD_DB_URL
  printf '%s\n' "begin isolation level repeatable read read only;" "set local row_security = off;" \
    "set local statement_timeout = '120s';" \
    "select 'momento', to_char(now() at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"');" \
    "$CONSULTA" "commit;" > "$tmp/prod.sql"
  com_senha_da_url psql "$PG_URL_SEM_SENHA" -X -q -At -F $'\t' -v ON_ERROR_STOP=1 -f "$tmp/prod.sql" \
    > "$tmp/prod.out" 2>"$tmp/erro" || { echo "ERRO: leitura do Prod falhou (a conexão não é mostrada)" >&2; erro_seguro "$tmp/erro"; exit 1; }
  unset PG_SENHA PG_URL_SEM_SENHA
  echo "Prod lido (READ ONLY) em $(awk -F '\t' '$1 == "momento" { print $2 }' "$tmp/prod.out")"
  awk -F '\t' 'NF == 2 && $1 != "momento"' "$tmp/prod.out" | sort > "$SAIDA/contagem-prod.tsv"
fi

# 6. Comparação: o esperado do pacote é o COPY do dump, trocado pelo suplemento onde ele repõe a tabela.
touch "$SAIDA/contagem-prod.tsv"
{ printf 'tabela\tpacote\trestaurado\tprod_agora\tsituacao\tprod_x_restaurado\n'
awk -F '\t' -v OFS='\t' '
  FILENAME ~ /tabelas-de-extensao/ { ext[$1] = 1; next }
  FILENAME ~ /contagem-dump/       { pac[$1] = $2; tem[$1] = 1; next }
  FILENAME ~ /contagem-suplemento/ { pac[$1] = $2; tem[$1] = 1; sup[$1] = 1; next }
  FILENAME ~ /contagem-restaurado/ { res[$1] = $2; tem[$1] = 1; next }
  FILENAME ~ /contagem-prod/       { prod[$1] = $2; tem[$1] = 1; next }
  END {
    for (t in tem) {
      p = (t in pac) ? pac[t] : "-"; r = (t in res) ? res[t] : "-"; q = (t in prod) ? prod[t] : "-"
      if (p != "-" && r == p) s = "igual"
      else if (p == "-" && r == "0") s = "vazia_sem_dados_no_pacote"
      else if (p == "-" && r == "-") s = "so_no_prod"
      else if ((t in ext) && r == q && p + 0 < r + 0) s = "linhas_do_create_extension"
      else if ((t in ext) && q == "-" && p + 0 < r + 0) s = "linhas_do_create_extension_sem_prod"
      else s = "DIFERENTE"
      if (t in sup) s = s "(suplemento)"
      print t, p, r, q, s, (q == "-" ? "-" : (q == r ? "igual" : "difere"))
    }
  }' "$SAIDA/tabelas-de-extensao.txt" "$SAIDA/contagem-dump.tsv" "$SAIDA/contagem-suplemento.tsv" \
     "$SAIDA/contagem-restaurado.tsv" "$SAIDA/contagem-prod.tsv" | sort; } > "$SAIDA/comparacao.tsv"

awk -v a="$T_INICIO" -v b="$T_FIM_RESTAURO" 'BEGIN { printf "rto_sem_download\t%.3f\n", b - a }' >> "$TEMPOS"
echo "--- tempos (s)"; cat "$TEMPOS"
echo "--- resumo das contagens"
awk -F '\t' 'NR > 1 { n++; c[$5]++; if ($2 ~ /^[0-9]+$/) sp += $2; if ($3 ~ /^[0-9]+$/) sr += $3; if ($4 ~ /^[0-9]+$/) sq += $4 }
  NR > 1 && $6 == "difere" { d = d " " $1 "(" $3 "→" $4 ")" }
  END { printf "tabelas: %d · linhas no pacote: %d · no restaurado: %d · no Prod agora: %d\n", n, sp, sr, sq
        for (k in c) printf "  %s: %d\n", k, c[k]
        printf "Prod agora difere do restaurado em:%s\n", (d == "" ? " nenhuma" : d) }' \
  "$SAIDA/comparacao.tsv"
if awk -F '\t' 'NR > 1 && $5 ~ /^DIFERENTE/ { achou = 1 } END { exit achou ? 0 : 1 }' "$SAIDA/comparacao.tsv"; then
  echo "ERRO: pacote e restaurado divergem; veja $SAIDA/comparacao.tsv" >&2; exit 1
fi
echo "OK: restaurado igual ao pacote em todas as tabelas contadas"
