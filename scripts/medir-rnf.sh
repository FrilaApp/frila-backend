#!/usr/bin/env bash
# scripts/medir-rnf.sh
# Medição reproduzível dos requisitos não-funcionais do Frila:
#   - RNF03: Publicar vaga -> despacho criado (meta <= 30 s)
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

# Trava de segurança: se apontar para host remoto, exige confirmação explícita
if [ -n "${DATABASE_URL:-}" ]; then
  db_host=$(python3 -c "import urllib.parse, os; print(urllib.parse.urlparse(os.environ['DATABASE_URL']).hostname or '')" 2>/dev/null || true)
  if [ -n "$db_host" ]; then
    case "$db_host" in
      localhost|127.0.0.1|::1|docker|supabase_db*|*.internal)
        ;;
      *)
        if [ "${EU_SEI_QUE_E_PRODUCAO:-0}" != "1" ]; then
          echo "✗ DATABASE_URL aponta para host remoto ('$db_host'). Para executar, defina EU_SEI_QUE_E_PRODUCAO=1." >&2
          exit 1
        fi
        ;;
    esac
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

exec_psql() {
  if [ -n "${DATABASE_URL:-}" ]; then
    psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 "$@"
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${DB_CONTAINER}$"; then
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
  else
    psql -h localhost -p 54322 -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
  fi
}

# shellcheck disable=SC2329
limpar() {
  local status_saida=$?
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
trap limpar EXIT

echo "================================================================================"
echo "          FRILA — MEDIÇÃO DE REQUISITOS NÃO-FUNCIONAIS (RNF02 e RNF03)          "
echo "================================================================================"
echo "Meta RNF03 : Publicar vaga -> Despacho criado <= 30.0 s"
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
trap 'rm -f "$TMP_SAIDA"; limpar' EXIT

exec_psql <<SQL > "$TMP_SAIDA"
create temp table pg_temp.medicao_rnf (
  repeticao int,
  vaga_id uuid,
  notificacao_id uuid,
  despachos_criados int,
  latencia_rnf03_s numeric
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
  v_notif record;
  v_hex text;
begin
  -- Âncora com profissionais elegíveis definida em supabase/cenarios.sql
  select inicio_em, fim_em into v_ini, v_fim
    from public.vaga where id = 'd0000000-0000-4000-8000-000000000001';

  for i in 1..v_n loop
    v_hex := lpad(to_hex(i), 12, '0');
    v_vaga_id := ('e0000000-0000-4000-8000-' || v_hex)::uuid;

    -- 1. Publicação da vaga (início da medição RNF03)
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

    -- 2. Despacho (término da medição RNF03)
    v_despachos := privado.despachar_vaga(v_vaga_id);
    v_t_desp := clock_timestamp();

    for v_notif in
      select id, enviada_em from public.notificacao where referencia_id = v_vaga_id
    loop
      insert into pg_temp.medicao_rnf (
        repeticao, vaga_id, notificacao_id, despachos_criados, latencia_rnf03_s
      ) values (
        i,
        v_vaga_id,
        v_notif.id,
        v_despachos,
        round(extract(epoch from (v_t_desp - v_t_pub))::numeric, 4)
      );
    end loop;

    -- Afasta timestamp no relógio do teto de RN23 (> 30 min atrás)
    -- para a próxima repetição encontrar a janela aberta sem ser barrada
    update public.notificacao
       set enviada_em = v_t_desp - interval '40 minutes'
     where referencia_id = v_vaga_id;
  end loop;
end \$\$;

\\echo '=== TABELA_AMOSTRAS ==='
select
  repeticao,
  vaga_id,
  despachos_criados,
  latencia_rnf03_s as rnf03_segundos,
  case when latencia_rnf03_s <= 30.0 then 'OK (<= 30s)' else 'FALHA (> 30s)' end as status_rnf03
from (
  select distinct on (repeticao)
    repeticao,
    vaga_id,
    despachos_criados,
    latencia_rnf03_s
  from pg_temp.medicao_rnf
  order by repeticao, notificacao_id
) sub
order by repeticao;

\\echo '=== METRICAS_JSON ==='
select json_build_object(
  'amostras', count(*),
  'vagas', count(distinct vaga_id),
  'p50_rnf03', round(coalesce(percentile_cont(0.50) within group (order by latencia_rnf03_s)::numeric, 0), 4),
  'p95_rnf03', round(coalesce(percentile_cont(0.95) within group (order by latencia_rnf03_s)::numeric, 0), 4)
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
where enviada_em >= privado.agora() - interval '7 days';
"

echo ""
echo "── 3. Estatísticas Agregadas e Validação do Gate ───────────────────────────────"

METRICAS_JSON=$(grep -E '^[[:space:]]*\{.*"p50_rnf03".*\}' "$TMP_SAIDA" | head -n 1)

STATUS_CODE=0

python3 - "$METRICAS_JSON" <<'PY'
import json, sys

raw = sys.argv[1].strip()
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
p50_rnf03 = float(data.get("p50_rnf03", 0))
p95_rnf03 = float(data.get("p95_rnf03", 0))

# Prevenção rigorosa de falso-verde: sem amostras é erro
if amostras == 0 or vagas == 0:
    print("✗ Nenhuma amostra válida encontrada", file=sys.stderr)
    sys.exit(1)

print(f"Total de vagas testadas       : {vagas}")
print(f"Total de notificações testadas: {amostras}")
print()

status_rnf03 = "APROVADO" if p95_rnf03 <= 30.0 else "REPROVADO"
print(f"RNF03 (Publicação da vaga -> Despacho criado):")
print(f"  p50 = {p50_rnf03:.4f} s | p95 = {p95_rnf03:.4f} s (Meta: <= 30.0000 s) -> [{status_rnf03}]")
print()
print("RNF02 (Despacho -> Aceite pelo provedor FCM/APNs):")
print("  Status: NÃO MENSURÁVEL LOCALMENTE [INFORMATIVO / NÃO EXECUTADO]")
print("  Nota  : Aferição ponta-a-ponta depende de ambiente com credenciais e tráfego real.")
print()

if p95_rnf03 > 30.0:
    print(f"✗ FALHA: RNF03 p95 ({p95_rnf03:.4f} s) excedeu o limite máximo de 30 s", file=sys.stderr)
    sys.exit(1)

print("✓ REQUISITO NÃO-FUNCIONAL RNF03 APROVADO")
sys.exit(0)
PY
STATUS_CODE=$?

exit "$STATUS_CODE"
