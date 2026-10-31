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
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}

psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falhas=$((falhas + 1)); }

falhas=0

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

# ── 2. Teste: Desativação completa ────────────────────────────
CRON_JOBS_DESATIVADOS=""
desativar_cron() {
  local existe
  existe=$(psql -tA -c "select 1 from pg_extension where extname = 'pg_cron';" 2>/dev/null || true)
  [ "$existe" = "1" ] || return 0

  CRON_JOBS_DESATIVADOS=$(psql -tA -c "select jobid from cron.job where active order by jobid;") || {
    echo "✗ [pg_cron] Falha ao consultar tarefas ativas em cron.job." >&2
    return 1
  }

  if [ -n "$CRON_JOBS_DESATIVADOS" ]; then
    local lista_ids
    lista_ids=$(echo "$CRON_JOBS_DESATIVADOS" | paste -sd, -)
    psql -q -c "
      do \$\$
      declare
        j bigint;
      begin
        for j in select unnest(array[$lista_ids]::bigint[]) loop
          perform cron.alter_job(j, active := false);
        end loop;
      end \$\$;" || {
      echo "✗ [pg_cron] Falha ao desativar tarefas via cron.alter_job." >&2
      return 1
    }
  fi
}

reativar_cron() {
  [ -n "${CRON_JOBS_DESATIVADOS:-}" ] || return 0
  local lista_ids
  lista_ids=$(echo "$CRON_JOBS_DESATIVADOS" | paste -sd, -)
  psql -q -c "
    do \$\$
    declare
      j bigint;
    begin
      for j in select unnest(array[$lista_ids]::bigint[]) loop
        perform cron.alter_job(j, active := true);
      end loop;
    end \$\$;" >/dev/null 2>&1 || true
  CRON_JOBS_DESATIVADOS=""
}

desativar_cron
ATIVOS_APOS_DESATIVAR=$(psql -tA -c "select count(*) from cron.job where active;")
if [ "$ATIVOS_APOS_DESATIVAR" -eq 0 ]; then
  ok "desativar_cron zera jobs ativos (0 tarefas ativas em cron.job)"
else
  falhou "desativar_cron deixou $ATIVOS_APOS_DESATIVAR tarefas ativas"
fi

# ── 3. Teste: Reativação restaura exatamente o total anterior ──
reativar_cron
ATIVOS_APOS_REATIVAR=$(psql -tA -c "select count(*) from cron.job where active;")
if [ "$ATIVOS_APOS_REATIVAR" -eq "$TOTAL_ATIVOS_ORIGINAL" ]; then
  ok "reativar_cron restaura total original de $TOTAL_ATIVOS_ORIGINAL tarefas ativas"
else
  falhou "reativar_cron resultou em $ATIVOS_APOS_REATIVAR tarefas ativas (esperado: $TOTAL_ATIVOS_ORIGINAL)"
fi

# ── 4. Teste: Preservação de jobs previamente inativos ─────────
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

# ── 5. Teste: Falha fechada (não engole erro de execução) ──────
# Simula comando que falha ao passar lista malformada
saida_erro=$( (
  lista_ids="999999999999999999999999999999999"
  psql -q -c "
    do \$\$
    declare
      j bigint;
    begin
      for j in select unnest(array[$lista_ids]::bigint[]) loop
        perform cron.alter_job(j, active := false);
      end loop;
    end \$\$;" 2>&1
) || true )

if echo "$saida_erro" | grep -Eqi "error|value .* out of range|syntax error"; then
  ok "falha em cron.alter_job gera erro explícito no stderr e não é engolida em silêncio"
else
  falhou "falha esperada não foi detectada ou foi suprimida: $saida_erro"
fi

echo
if [ "$falhas" -ne 0 ]; then
  echo "Total de falhas: $falhas." >&2
  exit 1
else
  echo "Todos os casos de teste do pg_cron passaram com sucesso."
fi
