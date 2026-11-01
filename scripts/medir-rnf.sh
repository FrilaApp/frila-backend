#!/usr/bin/env bash
# scripts/medir-rnf.sh
# Medição de latência de despacho e push do Frila:
#   - tempo de despachar_vaga (parcial): mede só o tempo de despachar_vaga; pula a fila, o cron e o FCM; NÃO é o RNF03 de ponta a ponta (meta <= 30 s)
#   - RNF02: Despacho -> push aceito pelo provedor (meta <= 60 s, não mensurável localmente)
#
# Cartão 6ab26a53 (B-005) · Alinhado com supabase/consultas/rnf02_rnf03_push.sql
#
# Uso:
#   ./scripts/medir-rnf.sh             # Executa 5 repetições (padrão)
#   ./scripts/medir-rnf.sh 10          # Executa 10 repetições
#   ./scripts/medir-rnf.sh -n 20       # Executa 20 repetições
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"
REPETICOES=5
META_RNF03="${META_RNF03:-30.0}"
st=0

# Trava de segurança: se apontar para host remoto, exige confirmação explícita
if [ -n "${DATABASE_URL:-}" ]; then
  if ! db_check=$(python3 - <<'PY'
import os, re, sys, urllib.parse
url = os.environ.get("DATABASE_URL", "").strip()
if not url:
    print("local")
    sys.exit(0)

host = ""
try:
    if "://" not in url and re.search(r"\bhost\s*=", url):
        m = re.search(r"\bhost\s*=\s*([^\s;]+)", url)
        if m:
            host = m.group(1)
    else:
        p = urllib.parse.urlparse(url)
        host = p.hostname or ""
        if not host and p.query:
            q = urllib.parse.parse_qs(p.query)
            if "host" in q:
                host = q["host"][0]
except Exception:
    host = ""

host_lower = host.lower() if host else ""
LOCAL_HOSTS = {"localhost", "127.0.0.1", "::1", "docker"}

if host_lower in LOCAL_HOSTS or host_lower.startswith("supabase_db") or host_lower.endswith(".internal"):
    print("local")
    sys.exit(0)

if host_lower.startswith("/") or host_lower.startswith("@/"):
    print("local")
    sys.exit(0)

print(host or "desconhecido/remoto")
sys.exit(1)
PY
); then
    if [ "${EU_SEI_QUE_E_PRODUCAO:-0}" != "1" ]; then
      echo "✗ DATABASE_URL aponta para host remoto ('$db_check'). Para executar, defina EU_SEI_QUE_E_PRODUCAO=1." >&2
      exit 1
    fi
  fi
fi

# Processa argumentos
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--repeticoes)
      REPETICOES="$2"
      shift 2
      ;;
    -h|--ajuda|--help)
      echo "Uso: $0 [N] [-n|--repeticoes N]"
      echo ""
      echo "Opções:"
      echo "  -n, --repeticoes N   Número de repetições da medição (padrão: 5)"
      echo "  -h, --ajuda          Exibe esta mensagem de ajuda"
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        REPETICOES="$1"
        shift
      else
        echo "Opção inválida: $1" >&2
        exit 1
      fi
      ;;
  esac
done

if [ "$REPETICOES" -le 0 ]; then
  echo "Erro: o número de repetições deve ser maior que 0." >&2
  exit 1
fi

if [ "$REPETICOES" -lt 5 ]; then
  echo "⚠ Aviso: N=$REPETICOES é pequeno; com poucas amostras o p95 aproxima-se do valor máximo." >&2
fi

exec_psql() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DB_CONTAINER}$"; then
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
  else
    PGPASSWORD="${PGPASSWORD:-postgres}" psql -h localhost -p 54322 -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
  fi
}

# shellcheck disable=SC2329
limpar() {
  local status_saida="${1:-$?}"
  if ! exec_psql <<'SQL' >/dev/null
set session_replication_role = 'replica';
delete from privado.auditoria_ciclo where entidade_id::text like 'e0000000-0000-4000-8000-%';
delete from privado.texto_da_vaga_ocultado where vaga_id::text like 'e0000000-0000-4000-8000-%';
delete from public.despacho where vaga_id in (select id from public.vaga where id::text like 'e0000000-0000-4000-8000-%');
delete from public.notificacao where referencia_id in (select id from public.vaga where id::text like 'e0000000-0000-4000-8000-%');
delete from public.vaga where id::text like 'e0000000-0000-4000-8000-%';
set session_replication_role = 'origin';
SQL
  then
    echo "✗ Erro na limpeza dos dados de teste no banco de dados." >&2
    exit 1
  fi
  exit "$status_saida"
}
trap 'st=$?; limpar "$st"' EXIT

echo "================================================================================"
echo "          FRILA — MEDIÇÃO DE REQUISITOS NÃO-FUNCIONAIS (RNF02 e RNF03)          "
echo "================================================================================"
echo "Meta tempo de despachar_vaga (parcial) : <= ${META_RNF03} s"
echo "  (mede só o tempo de despachar_vaga; pula a fila, o cron e o FCM; NÃO é o RNF03 de ponta a ponta)"
echo "Meta RNF02 : Despacho -> Push aceito pelo provedor <= 60.0 s (Depende de prod)"
echo "Repetições : $REPETICOES"
echo ""

# Executa limpeza prévia sem ignorar falhas
exec_psql <<'SQL' >/dev/null
set session_replication_role = 'replica';
delete from privado.auditoria_ciclo where entidade_id::text like 'e0000000-0000-4000-8000-%';
delete from privado.texto_da_vaga_ocultado where vaga_id::text like 'e0000000-0000-4000-8000-%';
delete from public.despacho where vaga_id in (select id from public.vaga where id::text like 'e0000000-0000-4000-8000-%');
delete from public.notificacao where referencia_id in (select id from public.vaga where id::text like 'e0000000-0000-4000-8000-%');
delete from public.vaga where id::text like 'e0000000-0000-4000-8000-%';
set session_replication_role = 'origin';
SQL

TMP_SAIDA=$(mktemp)
trap 'st=$?; rm -f "$TMP_SAIDA"; limpar "$st"' EXIT

exec_psql <<SQL > "$TMP_SAIDA"
create temp table pg_temp.medicao_rnf (
  repeticao int primary key,
  vaga_id uuid not null,
  despachos_criados int not null,
  notificacoes_criadas int not null,
  despachar_vaga_segundos numeric not null
);

do \$\$
declare
  v_n int := $REPETICOES;
  v_vaga_id uuid;
  v_ini timestamptz;
  v_fim timestamptz;
  v_t_pub timestamptz;
  v_t_desp timestamptz;
  v_despachos int;
  v_notif_count int;
  v_hex text;
begin
  -- Âncora com profissionais elegíveis definida em supabase/cenarios.sql
  select inicio_em, fim_em into v_ini, v_fim
    from public.vaga where id = 'd0000000-0000-4000-8000-000000000001';

  if v_ini is null then
    raise exception 'Âncora d0000000-0000-4000-8000-000000000001 ausente em public.vaga (cenarios.sql nasce na próxima sexta 18h após db reset).';
  end if;
  if v_ini < clock_timestamp() then
    raise exception 'Âncora d0000000-0000-4000-8000-000000000001 está no passado (%). Re-semeie com supabase/cenarios.sql.', v_ini;
  end if;

  for i in 1..v_n loop
    v_hex := lpad(to_hex(i), 12, '0');
    v_vaga_id := ('e0000000-0000-4000-8000-' || v_hex)::uuid;

    -- 1. Publicação da vaga (início da medição de despachar_vaga)
    v_t_pub := clock_timestamp();

    insert into public.vaga (
      id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
      exige_material_proprio, responsavel_local, publicado_por, modo, estado, chave_cliente,
      publicado_em
    ) values (
      v_vaga_id,
      'c0000000-0000-4000-8000-000000000001',
      (select id from public.funcao where nome = 'garçom'),
      v_ini, v_fim,
      'CLN 208, Bloco B', 'POINT(-47.8869 -15.7620)'::extensions.geography,
      15000, 1, false, false, false, 'Gerente Teste',
      'a0000000-0000-4000-8000-000000000001', 'urgencia', 'publicada', gen_random_uuid(),
      v_t_pub
    );

    -- 2. Despacho (término da medição parcial)
    v_despachos := privado.despachar_vaga(v_vaga_id);
    v_t_desp := clock_timestamp();

    select count(*) into v_notif_count from public.notificacao where referencia_id = v_vaga_id;

    insert into pg_temp.medicao_rnf (
      repeticao, vaga_id, despachos_criados, notificacoes_criadas, despachar_vaga_segundos
    ) values (
      i,
      v_vaga_id,
      v_despachos,
      v_notif_count,
      round(extract(epoch from (v_t_desp - v_t_pub))::numeric, 4)
    );

    -- Afasta timestamp no relógio do teto de RN23 (> 30 min atrás)
    -- para a próxima repetição encontrar a janela aberta sem ser barrada
    update public.notificacao
       set enviada_em = v_t_desp - interval '40 minutes'
     where referencia_id = v_vaga_id;
  end loop;
end \$\$;

\echo '=== TABELA_AMOSTRAS ==='
select
  repeticao,
  vaga_id,
  despachos_criados,
  notificacoes_criadas,
  despachar_vaga_segundos,
  case when despachar_vaga_segundos <= $META_RNF03 then 'OK (<= ' || '$META_RNF03' || 's)' else 'FALHA (> ' || '$META_RNF03' || 's)' end as status_parcial
from pg_temp.medicao_rnf
order by repeticao;

\echo '=== METRICAS_JSON ==='
select json_build_object(
  'amostras', count(*),
  'vagas', count(distinct vaga_id),
  'notificacoes', coalesce(sum(notificacoes_criadas), 0),
  'repeticoes_sem_notificacao', count(*) filter (where notificacoes_criadas = 0 or despachos_criados = 0),
  'p50_rnf03', round(coalesce(percentile_cont(0.50) within group (order by despachar_vaga_segundos)::numeric, 0), 4),
  'p95_rnf03', round(coalesce(percentile_cont(0.95) within group (order by despachar_vaga_segundos)::numeric, 0), 4)
)::text
from pg_temp.medicao_rnf;
SQL

echo "── 1. Amostras Coletadas ($REPETICOES repetições) ────────────────────────────────────────"
sed -n '/=== TABELA_AMOSTRAS ===/,/=== METRICAS_JSON ===/p' "$TMP_SAIDA" | sed '1d;$d'

echo ""
echo "── 2. Consulta RNF02 (Taxa de Aceite em 60s - rnf02_rnf03_push.sql) ────────────"
echo "Status: NÃO MENSURÁVEL LOCALMENTE [INFORMATIVO / NÃO EXECUTADO]"
echo "Ressalva: A medição de RNF02 (aceita_em - enviada_em <= 60 s) depende do envio real"
echo "aos provedores FCM/APNs e do recebimento em aparelhos físicos. Em ambiente local,"
echo "não há credenciais reais nem provedor externo ativo."
echo ""
echo "Consulta executada no banco atual:"
exec_psql -c "
select
  count(*) as total_despachadas,
  count(*) filter (
    where aceita_em is not null and aceita_em - enviada_em <= interval '60 seconds'
  ) as aceitas_em_60s,
  count(*) filter (where estado_entrega = 'falhou') as falhas,
  case
    when count(*) = 0 then 0.0
    else round(
      100.0 * count(*) filter (
        where aceita_em is not null and aceita_em - enviada_em <= interval '60 seconds'
      ) / count(*),
      2
    )
  end as taxa_aceite_60s_pct
from public.notificacao
where enviada_em >= privado.agora() - interval '7 days'
  and referencia_id::text not like 'e0000000%';
"

echo ""
echo "── 3. Estatísticas Agregadas e Validação do Gate ───────────────────────────────"

METRICAS_JSON=$(grep -E '^[[:space:]]*\{.*"p50_rnf03".*\}' "$TMP_SAIDA" | head -n 1)

STATUS_CODE=0

python3 - "$METRICAS_JSON" "$META_RNF03" "$REPETICOES" <<'PY'
import json, sys

raw = sys.argv[1].strip()
meta_rnf03 = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
repeticoes_esperadas = int(sys.argv[3]) if len(sys.argv) > 3 else 5

if not raw:
    print("✗ Nenhuma amostra válida encontrada", file=sys.stderr)
    sys.exit(1)

try:
    data = json.loads(raw)
except Exception as e:
    print(f"✗ Erro ao processar métricas JSON: {e}", file=sys.stderr)
    sys.exit(1)

amostras = data.get("amostras", 0)
vagas = data.get("vagas", 0)
notificacoes = data.get("notificacoes", 0)
repeticoes_sem_notificacao = data.get("repeticoes_sem_notificacao", 0)
p50_rnf03 = float(data.get("p50_rnf03", 0))
p95_rnf03 = float(data.get("p95_rnf03", 0))

# Prevenção rigorosa de falso-verde: sem amostras é erro
if amostras == 0 or vagas == 0:
    print("✗ Nenhuma amostra válida encontrada", file=sys.stderr)
    sys.exit(1)

if amostras != repeticoes_esperadas:
    print(f"✗ Falha: número de repetições coletadas ({amostras}) difere do total esperado ({repeticoes_esperadas})", file=sys.stderr)
    sys.exit(1)

if repeticoes_sem_notificacao > 0:
    print(f"✗ Falha: {repeticoes_sem_notificacao} repetição(ões) não geraram despachos ou notificações válidas", file=sys.stderr)
    sys.exit(1)

print(f"Total de repetições testadas  : {amostras} (esperadas: {repeticoes_esperadas})")
print(f"Total de vagas testadas       : {vagas}")
print(f"Total de notificações criadas : {notificacoes}")
print()

status_rnf03 = "APROVADO" if p95_rnf03 <= meta_rnf03 else "REPROVADO"
print("tempo de despachar_vaga (parcial):")
print("  Nota: mede só o tempo de despachar_vaga; pula a fila, o cron e o FCM; NÃO é o RNF03 de ponta a ponta.")
print(f"  p50 = {p50_rnf03:.4f} s | p95 = {p95_rnf03:.4f} s (Meta: <= {meta_rnf03:.4f} s) -> [{status_rnf03}]")
print()
print("RNF02 (Despacho -> Aceite pelo provedor FCM/APNs):")
print("  Status: NÃO MENSURÁVEL LOCALMENTE [INFORMATIVO / NÃO EXECUTADO]")
print("  Nota  : Aferição ponta-a-ponta depende de ambiente com credenciais e tráfego real.")
print()

if p95_rnf03 > meta_rnf03:
    print(f"✗ FALHA: tempo de despachar_vaga (parcial) p95 ({p95_rnf03:.4f} s) excedeu o limite de {meta_rnf03} s", file=sys.stderr)
    sys.exit(1)

print("✓ MEDIÇÃO PARCIAL DE DESPACHO APROVADA")
sys.exit(0)
PY
STATUS_CODE=$?

exit "$STATUS_CODE"
