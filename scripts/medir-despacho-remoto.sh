#!/usr/bin/env bash
# Medição remota do motor de despacho (cartão 7XS6MQGg).
#
# Avalia os critérios de aceite que exigem ambiente remoto (frila-dev):
#   - Critério 4: Job do pg_cron (reprocessar_despacho) roda por 24 h sem erro.
#   - Critério 5: p95 entre publicação e despacho < 30 s em 20 publicações (RNF03).
#
# Suporta execução via Management API da Supabase (com project_ref e SUPABASE_ACCESS_TOKEN)
# ou conexão direta via DATABASE_URL / psql local.
#
# Uso:
#   ./scripts/medir-despacho-remoto.sh <project_ref>
#   DATABASE_URL="postgres://..." ./scripts/medir-despacho-remoto.sh
#   ./scripts/medir-despacho-remoto.sh --local
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

REF="${1:-}"
LOCAL=0

if [ "$REF" = "--local" ]; then
  LOCAL=1
  REF=""
elif [ -z "$REF" ] && [ -z "${DATABASE_URL:-}" ]; then
  # Se nada foi passado, verifica se há .env com REF ou chave remota
  if [ -f .env ]; then
    set -a; source .env; set +a
  fi
  REF="${FRILA_DEV_PROJECT_REF:-}"
fi

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }
info()   { printf '  ℹ %s\n' "$1"; }
falha=0

# Função de execução de SQL
executar_sql() {
  local sql="$1"
  if [ "$LOCAL" -eq 1 ] || [ -z "$REF" ]; then
    if [ -n "${DATABASE_URL:-}" ]; then
      psql "$DATABASE_URL" -X -q -t -A -c "$sql"
    else
      docker exec -i "${DB_CONTAINER:-supabase_db_frila-backend}" \
        psql -U postgres -d postgres -X -q -t -A -c "$sql"
    fi
  else
    : "${SUPABASE_ACCESS_TOKEN:?falta SUPABASE_ACCESS_TOKEN para consultar projeto remoto via API}"
    local resposta
    resposta=$(python3 - "$REF" "$sql" <<'PY'
import json, os, sys, urllib.request

ref = sys.argv[1]
sql = sys.argv[2]
api_url = f"https://api.supabase.com/v1/projects/{ref}/database/query"

req = urllib.request.Request(
    api_url,
    data=json.dumps({"query": sql}).encode(),
    headers={
        "Authorization": "Bearer " + os.environ["SUPABASE_ACCESS_TOKEN"],
        "Content-Type": "application/json"
    },
    method="POST"
)

try:
    with urllib.request.urlopen(req, timeout=120) as resp:
        print(resp.read().decode())
except urllib.error.HTTPError as e:
    print("ERRO_HTTP " + e.read().decode())
    sys.exit(1)
PY
)
    if printf '%s' "$resposta" | grep -q '^ERRO_HTTP\|"message":"Failed to run sql'; then
      printf '%s\n' "$resposta" >&2
      return 1
    fi
    printf '%s' "$resposta"
  fi
}

echo "================================================================="
echo " Medição Remota · Motor de Despacho (Critérios 4 e 5)"
echo "================================================================="
if [ "$LOCAL" -eq 1 ]; then
  echo "Ambiente: Local (Docker / test db)"
elif [ -n "$REF" ]; then
  echo "Ambiente: Remoto (Projeto $REF via Management API)"
else
  echo "Ambiente: Remoto via DATABASE_URL"
fi
echo

# ── 1. Critério 4: Execução do pg_cron por 24 h sem erro ───────────────────────
echo "▸ Critério 4: Estabilidade do job pg_cron (reprocessar_despacho nas últimas 24 h)"

SQL_CRON="
select json_build_object(
  'total', count(*),
  'sucessos', count(*) filter (where status = 'succeeded'),
  'falhas', count(*) filter (where status <> 'succeeded'),
  'primeira', min(start_time),
  'ultima', max(end_time)
)::text
from cron.job_run_details d
join cron.job j on j.jobid = d.jobid
where j.jobname = 'reprocessar_despacho'
  and d.start_time >= now() - interval '24 hours';
"

RES_CRON=$(executar_sql "$SQL_CRON" 2>/dev/null || echo '{"erro": "falha_ao_consultar"}')

if ! python3 - "$RES_CRON" <<'PY'; then
import json, sys

raw = sys.argv[1].strip()
try:
    if raw.startswith("["):
        # API json response
        data = json.loads(raw)[0]
        if isinstance(data, dict) and "json_build_object" in data:
            data = json.loads(data["json_build_object"])
    else:
        data = json.loads(raw)
except Exception as e:
    print(f"  ✗ Não foi possível ler histórico do cron: {raw}")
    sys.exit(1)

total = data.get("total", 0)
sucessos = data.get("sucessos", 0)
falhas = data.get("falhas", 0)
primeira = data.get("primeira")
ultima = data.get("ultima")

print(f"  Execuções registradas: {total}")
print(f"  Sucessos: {sucessos} | Falhas: {falhas}")
if primeira and ultima:
    print(f"  Período observado: {primeira} → {ultima}")

if total == 0:
    print("  ✗ Nenhum histórico de execução do job reprocessar_despacho nas últimas 24h.")
    print("    Nota: O job deve ser ativado no frila-dev após a implantação para iniciar a janela de 24h.")
    sys.exit(1)
elif falhas > 0:
    print(f"  ✗ Houve {falhas} falha(s) nas execuções do job nas últimas 24h.")
    sys.exit(1)
else:
    print("  ✓ Job reprocessar_despacho rodou sem erros nas últimas 24 h.")
PY
  falha=1
fi

echo

# ── 2. Critério 5: p95 entre publicação e aceite pelo FCM < 30 s em 20 vagas ──
echo "▸ Critério 5: p95 entre publicação e aceite pelo FCM (RNF03: < 30 s em 20 publicações)"

SQL_P95="
with amostras as (
  select
    v.id as vaga_id,
    v.publicado_em,
    min(d.criado_em) as primeiro_despacho_em,
    min(n.aceita_em) as primeiro_aceite_fcm_em,
    extract(epoch from (min(d.criado_em) - v.publicado_em)) as latencia_despacho_s,
    extract(epoch from (min(n.aceita_em) - v.publicado_em)) as latencia_fcm_s
  from public.vaga v
  join public.despacho d on d.vaga_id = v.id
  left join public.notificacao n on n.id = d.notificacao_id
  where v.estado in ('publicada', 'preenchida', 'concluida')
  group by v.id, v.publicado_em
  order by v.publicado_em desc
  limit 20
)
select json_build_object(
  'amostras_vagas', count(*),
  'amostras_com_fcm', count(*) filter (where primeiro_aceite_fcm_em is not null),
  'p50_despacho_s', round(coalesce(percentile_cont(0.50) within group (order by latencia_despacho_s)::numeric, 0), 3),
  'p95_despacho_s', round(coalesce(percentile_cont(0.95) within group (order by latencia_despacho_s)::numeric, 0), 3),
  'p50_fcm_s', round(coalesce(percentile_cont(0.50) within group (order by latencia_fcm_s) filter (where latencia_fcm_s is not null)::numeric, 0), 3),
  'p95_fcm_s', round(coalesce(percentile_cont(0.95) within group (order by latencia_fcm_s) filter (where latencia_fcm_s is not null)::numeric, 0), 3),
  'max_fcm_s', round(coalesce(max(latencia_fcm_s), 0)::numeric, 3)
)::text
from amostras;
"

RES_P95=$(executar_sql "$SQL_P95" 2>/dev/null || echo '{"erro": "falha_ao_consultar"}')

if ! python3 - "$RES_P95" <<'PY'; then
import json, sys

raw = sys.argv[1].strip()
try:
    if raw.startswith("["):
        data = json.loads(raw)[0]
        if isinstance(data, dict) and "json_build_object" in data:
            data = json.loads(data["json_build_object"])
    else:
        data = json.loads(raw)
except Exception as e:
    print(f"  ✗ Não foi possível calcular p95 das publicações: {raw}")
    sys.exit(1)

vagas = data.get("amostras_vagas", 0)
fcm_amostras = data.get("amostras_com_fcm", 0)
p50_despacho = float(data.get("p50_despacho_s", 0))
p95_despacho = float(data.get("p95_despacho_s", 0))
p50_fcm = float(data.get("p50_fcm_s", 0))
p95_fcm = float(data.get("p95_fcm_s", 0))
max_fcm = float(data.get("max_fcm_s", 0))

print(f"  Vagas amostradas: {vagas}/20 publicações")
print(f"  Despacho interno no banco (vaga → despacho): p50 = {p50_despacho:.3f} s | p95 = {p95_despacho:.3f} s")
print(f"  Amostras com aceite real do provedor (FCM aceita_em): {fcm_amostras}/20")

if fcm_amostras < 20:
    print(f"  ✗ Amostras insuficientes de aceite pelo FCM ({fcm_amostras}/20 válidas com aceita_em preenchido).")
    print("    FONTE DE ENTREGA PENDENTE: A gravação de `public.notificacao.aceita_em` é atribuição do cartão")
    print("    paralelo 'S2 · Backend · Envio de push pelo FCM, registro do aparelho e estado de entrega'.")
    print("    Enquanto o worker de envio FCM não estiver ativo no frila-dev consumindo a fila de notificações,")
    print("    o critério 5 permanece pendente de homologação ponta-a-ponta.")
    sys.exit(1)
elif p95_fcm >= 30.0:
    print(f"  ✗ p95 até o aceite pelo FCM ({p95_fcm:.3f} s) excede o teto de 30.0 s de RNF03.")
    sys.exit(1)
else:
    print(f"  ✓ p95 até aceite pelo FCM ({p95_fcm:.3f} s) abaixo de 30 s em {fcm_amostras} publicações (RNF03 atendido).")
PY
  falha=1
fi

echo
echo "================================================================="
if [ "$falha" -eq 0 ]; then
  echo " Resultado: TODOS OS CRITÉRIOS REMOTOS APROVADOS"
  exit 0
else
  echo " Resultado: PENDENTE DE IMPLANTAÇÃO / EXECUÇÃO NO FRILA-DEV"
  echo " (Critérios 4 e 5 devem ser revalidados após o deploy no ambiente frila-dev)"
  exit 1
fi
