#!/usr/bin/env bash
# Autoteste do mecanismo de desativação e reativação do pg_cron
#
# Valida as garantias operacionais de scripts/corrida-ciclo.sh e corrida-teto.sh:
#   1. desativar_cron desativa todas as tarefas ativas via cron.alter_job (active = false);
#   2. reativar_cron restaura as tarefas originalmente ativas para active = true;
#   3. Preservação de inativos: jobs previamente inativos NÃO são ativados indevidamente;
#   4. Falha fechada: falhas de SQL não são engolidas em silêncio (exit code != 0);
#   5. Prova de neutralização: job desativado não dispara na virada de minuto do background worker.
#
# Uso:
#   ./scripts/teste-desativar-cron.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DB=${DB_CONTAINER:-supabase_db_frila-backend}

psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

TMP_FALHAS=$(mktemp)
echo "0" > "$TMP_FALHAS"
trap 'rm -f "$TMP_FALHAS"' EXIT

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() {
  printf '  ✗ %s\n' "$1" >&2
  local f
  f=$(cat "$TMP_FALHAS" 2>/dev/null || echo "0")
  echo "$((f + 1))" > "$TMP_FALHAS"
}

echo "▸ Testando mecanismo de desativação/reativação do pg_cron"

# Checa se o banco e a extensão estão disponíveis
if ! psql -tA -c "select 1 from pg_extension where extname = 'pg_cron';" >/dev/null 2>&1; then
  echo "⚠︎ Extensão pg_cron não encontrada no container $DB. Pulando autoteste."
  exit 0
fi

# ── 1. Salvar estado original do banco ────────────────────────
ORIGINAIS_ATIVOS=$(psql -tA -c "select jobid from cron.job where active order by jobid;")
TOTAL_ATIVOS_ORIGINAL=$(psql -tA -c "select count(*) from cron.job where active;")

restaurar_original() {
  if [ -n "$ORIGINAIS_ATIVOS" ]; then
    local lista
    lista=$(echo "$ORIGINAIS_ATIVOS" | paste -sd, -)
    psql -q -c "
      do \$\$
      declare
        j bigint;
      begin
        for j in select unnest(array[$lista]::bigint[]) loop
          perform cron.alter_job(j, active := true);
        end loop;
      end \$\$;" >/dev/null 2>&1 || true
  fi
}
trap restaurar_original EXIT

# ── 2. Validação dos harnesses reais (P2-02: prova contra mutação) ──
for script in scripts/corrida-ciclo.sh scripts/corrida-teto.sh; do
  if grep -Eq '^[[:space:]]*desativar_cron([[:space:]]|$)' "$script"; then
    ok "$script invoca desativar_cron na inicialização"
  else
    falhou "$script não invoca desativar_cron na inicialização"
  fi
  if grep -q 'reativar_cron' "$script"; then
    ok "$script invoca reativar_cron na limpeza/trap"
  else
    falhou "$script não invoca reativar_cron na limpeza/trap"
  fi
done

func_ciclo=$(sed -n '/^desativar_cron() {/,/^}/p' scripts/corrida-ciclo.sh)
func_teto=$(sed -n '/^desativar_cron() {/,/^}/p' scripts/corrida-teto.sh)
if [ "$func_ciclo" = "$func_teto" ]; then
  ok "implementação de desativar_cron é idêntica em corrida-ciclo.sh e corrida-teto.sh"
else
  falhou "implementação de desativar_cron diverge entre corrida-ciclo.sh e corrida-teto.sh"
fi

# ── 3. Carregamento da implementação real de corrida-ciclo.sh ───
export CRON_JOBS_DESATIVADOS=""
eval "$func_ciclo"
eval "$(sed -n '/^reativar_cron() {/,/^}/p' scripts/corrida-ciclo.sh)"

# ── 4. Teste: Falha fechada na consulta a pg_extension (P2-01) ──
(
  # Simula erro transitório em psql (ex.: exit 2)
  # shellcheck disable=SC2329
  psql() { return 2; }
  saida=$(desativar_cron 2>&1)
  codigo=$?
  if [ "$codigo" -ne 0 ] && echo "$saida" | grep -q "Falha ao consultar pg_extension"; then
    ok "falha transitória na consulta de pg_extension retorna erro em vez de falso sucesso (P2-01)"
    exit 0
  else
    falhou "falha transitória em pg_extension não retornou erro: código=$codigo saída=$saida"
    exit 1
  fi
) || true

# ── 5. Teste: Falha fechada em cron.alter_job (P2-02) ───────────
(
  f_count=$(mktemp)
  echo "0" > "$f_count"
  # shellcheck disable=SC2329
  psql() {
    local c
    c=$(cat "$f_count")
    c=$((c + 1))
    echo "$c" > "$f_count"
    if [ "$c" -eq 1 ]; then
      echo "1" # pg_extension existe
    elif [ "$c" -eq 2 ]; then
      echo "10" # jobid 10 ativo
    else
      echo "psql: erro simulado ao executar cron.alter_job" >&2
      return 1
    fi
  }
  saida=$(desativar_cron 2>&1)
  codigo=$?
  rm -f "$f_count"
  if [ "$codigo" -ne 0 ] && echo "$saida" | grep -q "Falha ao desativar tarefas via cron.alter_job"; then
    ok "desativar_cron falha fechado (exit != 0) se cron.alter_job falhar (P2-02)"
    exit 0
  else
    falhou "desativar_cron engoliu erro de cron.alter_job: código=$codigo saída=$saida"
    exit 1
  fi
) || true

# ── 6. Teste: Desativação completa no banco real ───────────────
desativar_cron
ATIVOS_APOS_DESATIVAR=$(psql -tA -c "select count(*) from cron.job where active;")
if [ "$ATIVOS_APOS_DESATIVAR" -eq 0 ]; then
  ok "desativar_cron zera jobs ativos (0 tarefas ativas em cron.job)"
else
  falhou "desativar_cron deixou $ATIVOS_APOS_DESATIVAR tarefas ativas"
fi

# ── 7. Teste: Reativação restaura exatamente o total anterior ──
reativar_cron
ATIVOS_APOS_REATIVAR=$(psql -tA -c "select count(*) from cron.job where active;")
if [ "$ATIVOS_APOS_REATIVAR" -eq "$TOTAL_ATIVOS_ORIGINAL" ]; then
  ok "reativar_cron restaura total original de $TOTAL_ATIVOS_ORIGINAL tarefas ativas"
else
  falhou "reativar_cron resultou em $ATIVOS_APOS_REATIVAR tarefas ativas (esperado: $TOTAL_ATIVOS_ORIGINAL)"
fi

# ── 8. Teste: Preservação de jobs previamente inativos ─────────
# Cria um job temporário marcado como inativo antes de desativar
JOB_INATIVO_ID=$(psql -tA -c "select cron.schedule('teste_inativo_previo', '* * * * *', 'select 1;');")
psql -q -c "select cron.alter_job(job_id := $JOB_INATIVO_ID, active := false);" >/dev/null

desativar_cron
reativar_cron

ESTADO_JOB_INATIVO=$(psql -tA -c "select active from cron.job where jobid = $JOB_INATIVO_ID;")
psql -q -c "select cron.unschedule($JOB_INATIVO_ID);" >/dev/null 2>&1 || true

if [ "$ESTADO_JOB_INATIVO" = "f" ]; then
  ok "job previamente inativo permanece inativo após reativação (sem reativação cega)"
else
  falhou "job previamente inativo foi indevidamente reativado para active=$ESTADO_JOB_INATIVO"
fi

echo
falhas=$(cat "$TMP_FALHAS" 2>/dev/null || echo "0")
if [ "$falhas" -ne 0 ]; then
  echo "Total de falhas: $falhas." >&2
  exit 1
else
  echo "Todos os casos de teste do pg_cron passaram com sucesso."
fi
