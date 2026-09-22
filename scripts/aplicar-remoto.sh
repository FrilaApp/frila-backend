#!/usr/bin/env bash
# Aplica as migrações num projeto remoto pela Management API.
#
# Existe porque `supabase db push` precisa da senha do banco, e a senha do frila-dev
# está com quem criou o projeto. A API de conta alcança o mesmo banco com o access
# token, e mantém `supabase_migrations.schema_migrations` no formato que a CLI espera —
# então quem tiver a senha depois faz `db push` normalmente e a CLI vê tudo aplicado.
#
# Idempotente: pula o que já está registrado.
#
# Uso:  ./scripts/aplicar-remoto.sh <project_ref>
#       ./scripts/aplicar-remoto.sh <project_ref> --seco     mostra o que faria
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; source .env; set +a

REF="${1:?uso: aplicar-remoto.sh <project_ref> [--seco]}"
SECO="${2:-}"
API="https://api.supabase.com/v1/projects/$REF/database/query"

: "${SUPABASE_ACCESS_TOKEN:?falta SUPABASE_ACCESS_TOKEN no .env}"

# Executa SQL e devolve a resposta crua. Aborta no primeiro erro da API.
rodar() {
  local sql="$1" resposta
  resposta=$(python3 - "$sql" <<'PY'
import json, os, sys, urllib.request
sql = sys.argv[1]
req = urllib.request.Request(
    os.environ["API"],
    data=json.dumps({"query": sql}).encode(),
    headers={"Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"],
             "Content-Type": "application/json"},
    method="POST")
try:
    print(urllib.request.urlopen(req, timeout=180).read().decode())
except urllib.error.HTTPError as e:
    print("ERRO_HTTP " + e.read().decode()); sys.exit(1)
PY
)
  if printf '%s' "$resposta" | grep -q '^ERRO_HTTP\|"message":"Failed to run sql'; then
    printf '%s\n' "$resposta" >&2
    return 1
  fi
  printf '%s' "$resposta"
}
export API SUPABASE_ACCESS_TOKEN

echo "▸ Tabela de controle de migrações"
rodar "create schema if not exists supabase_migrations;
       create table if not exists supabase_migrations.schema_migrations (
         version text primary key, statements text[], name text);" >/dev/null
echo "  ✓"

aplicadas=$(rodar "select coalesce(string_agg(version, ' '), '') as v
                     from supabase_migrations.schema_migrations" \
            | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['v'])")

echo "▸ Migrações"
novas=0
for arq in supabase/migrations/*.sql; do
  base=$(basename "$arq" .sql)
  versao=${base%%_*}
  nome=${base#*_}

  case " $aplicadas " in *" $versao "*)
    printf '  %-50s já aplicada\n' "$base"; continue ;;
  esac

  if [ "$SECO" = "--seco" ]; then
    printf '  %-50s aplicaria\n' "$base"; novas=$((novas+1)); continue
  fi

  printf '  %-50s ' "$base"
  if ! rodar "$(cat "$arq")" >/dev/null; then
    echo "FALHOU"
    exit 1
  fi
  rodar "insert into supabase_migrations.schema_migrations (version, name, statements)
         values ('$versao', '$nome', array[]::text[])
         on conflict (version) do nothing" >/dev/null
  echo "aplicada ✓"
  novas=$((novas+1))
done

if [ "$SECO" = "--seco" ]; then
  echo; echo "$novas migração(ões) seriam aplicadas."
  exit 0
fi

# Só o `seed.sql`, que é o catálogo de funções e é idempotente.
#
# A conferência seguinte é redundante por desenho: o marcador de ambiente de teste não
# mora em arquivo nenhum, então não há caminho que o traga para cá. Ela fica porque é
# barata e porque a propriedade importa demais para depender de ninguém ter reintroduzido
# um arquivo de semente sem pensar.
echo "▸ Semente do catálogo"
rodar "$(cat supabase/seed.sql)" >/dev/null && echo "  ✓"

echo "▸ O relógio remoto não é sobreponível"
if rodar "select count(*) as n from privado.ambiente where eh_teste" 2>/dev/null \
     | grep -q '"n":0'; then
  echo "  ✓ privado.ambiente sem marcador de teste"
else
  echo "  ✗ ESTE AMBIENTE ESTÁ MARCADO COMO DE TESTE"
  echo
  echo "  privado.agora() aceita sobreposição aqui, e com ela todo prazo do produto"
  echo "  pode ser burlado: os 7 dias do contato (RN10), as 24 h do modo seleção"
  echo "  (RN24), o fim previsto que libera a avaliação (RN07)."
  echo "  Limpe com: delete from privado.ambiente;"
  exit 1
fi

echo
echo "▸ Conferindo"
rodar "select
  (select count(*) from pg_tables where schemaname='public')                       as tabelas,
  (select count(*) from public.funcao)                                            as funcoes,
  (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='r' and c.relrowsecurity)               as rls_ligado,
  (select count(distinct table_name) from information_schema.role_table_grants
    where grantee='anon' and table_schema='public'
      and privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE'))               as anon_escrita" \
  | python3 -m json.tool
