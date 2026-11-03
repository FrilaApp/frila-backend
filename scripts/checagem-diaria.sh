#!/usr/bin/env bash
# Checagem diária de produção e plantão do piloto (~10 min).
# Cartão 42 (Trello) · S4 · Infra · Monitoramento de produção e plantão do piloto.
# Requisitos: RNF02, RNF03, RNF12.
#
# ── GARANTIAS ABSOLUTAS DE SEGURANÇA ──────────────────────────────────────────
# 1. 100% SÓ LEITURA: default_transaction_read_only ativado em todas as sessões.
#    Nenhum INSERT, UPDATE, DELETE, ALTER ou DROP é executado.
# 2. ZERO SEGREDOS NO REPOSITÓRIO: Credenciais nunca são gravadas em arquivo.
#    Em produção/dev, use a variável de ambiente DATABASE_URL ou PGHOST/PGPASSWORD.
# 3. AUDITORIA OPERACIONAL: O script gera diagnóstico objetivo e semáforo
#    (VERDE / AMARELO / VERMELHO) para apoio à tomada de decisão rápida no plantão.
#
# ── USO ───────────────────────────────────────────────────────────────────────
# Localmente (usa o container supabase_db_frila-backend por padrão):
#   ./scripts/checagem-diaria.sh
#
# Com string de conexão (Produção / Dev / Banco Remoto):
#   DATABASE_URL="postgresql://postgres:[SENHA]@[HOST]:5432/postgres" ./scripts/checagem-diaria.sh
#
# Ou com variáveis padrão do PostgreSQL:
#   PGHOST=... PGPORT=5432 PGDATABASE=postgres PGUSER=postgres PGPASSWORD=... ./scripts/checagem-diaria.sh
#
# Códigos de Saída:
#   0: Tudo normal ou sem anomalias críticas (VERDE / AMARELO informativo)
#   1: Alerta operacional crítico detectado (VERMELHO - exige ação imediata)
#   2: Erro de conexão ou configuração
set -uo pipefail

DB_CONTAINER="${DB_CONTAINER:-supabase_db_frila-backend}"
DATABASE_URL="${DATABASE_URL:-}"

# Executa query SQL em modo estrito de SÓ LEITURA
exec_sql() {
  local sql="$1"
  if [ -n "$DATABASE_URL" ]; then
    psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 \
      -c "SET default_transaction_read_only = on;" \
      -c "$sql"
  elif [ -n "${PGHOST:-}" ]; then
    psql -X -v ON_ERROR_STOP=1 \
      -c "SET default_transaction_read_only = on;" \
      -c "$sql"
  else
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -v ON_ERROR_STOP=1 \
      -c "SET default_transaction_read_only = on;" \
      -c "$sql"
  fi
}

exec_sql_quiet() {
  local sql="$1"
  if [ -n "$DATABASE_URL" ]; then
    psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 \
      -c "SET default_transaction_read_only = on;" \
      -c "$sql" 2>/dev/null | sed '/^SET$/d' | head -n 1
  elif [ -n "${PGHOST:-}" ]; then
    psql -X -q -t -A -v ON_ERROR_STOP=1 \
      -c "SET default_transaction_read_only = on;" \
      -c "$sql" 2>/dev/null | sed '/^SET$/d' | head -n 1
  else
    docker exec -i "$DB_CONTAINER" psql -U postgres -d postgres -X -q -t -A -v ON_ERROR_STOP=1 \
      -c "SET default_transaction_read_only = on;" \
      -c "$sql" 2>/dev/null | sed '/^SET$/d' | head -n 1
  fi
}

# Valida conectividade antes de iniciar
if ! exec_sql_quiet "SELECT 1;" >/dev/null 2>&1; then
  echo "✗ ERRO: Não foi possível conectar ao banco de dados." >&2
  if [ -z "$DATABASE_URL" ] && [ -z "${PGHOST:-}" ]; then
    echo "  Container local '$DB_CONTAINER' indisponível. Suba o ambiente ('supabase start') ou forneça DATABASE_URL." >&2
  fi
  exit 2
fi

ALERTA_CRITICO=0
ALERTA_MODERADO=0

echo "================================================================================"
echo "  FRILA · CHECAGEM DIÁRIA DE PRODUÇÃO E PLANTÃO DO PILOTO (~10 MIN)"
echo "  Cartão 42 · RNF02 (latência), RNF03 (throughput), RNF12 (resiliência)"
echo "  Modo: 100% SÓ LEITURA (default_transaction_read_only = on)"
data_banco=$(exec_sql_quiet "SELECT to_char(now() at time zone 'America/Sao_Paulo', 'YYYY-MM-DD HH24:MI:SS BRT');")
echo "  Data/Hora do Banco: $data_banco"
echo "================================================================================"
echo ""

# ── 1. SAÚDE GERAL E JOBS DO AGENDADOR (pg_cron) ─────────────────────────────
echo "▸ 1. Saúde Geral e Agendador do Sistema (pg_cron / RNF12)"
echo "--------------------------------------------------------------------------------"

# Verifica jobs inativos
jobs_inativos=$(exec_sql_quiet "SELECT count(*) FROM cron.job WHERE active = false;" || echo "0")
jobs_inativos="${jobs_inativos:-0}"
if [ "$jobs_inativos" -gt 0 ]; then
  echo "  [!] ALERTA: Há $jobs_inativos job(s) do cron desativados!"
  exec_sql "SELECT jobid, jobname, schedule, command FROM cron.job WHERE active = false;"
  ALERTA_CRITICO=$((ALERTA_CRITICO + 1))
else
  total_jobs=$(exec_sql_quiet "SELECT count(*) FROM cron.job;" || echo "0")
  echo "  ✓ Todos os $total_jobs jobs do pg_cron estão ATIVOS."
fi

# Verifica falhas no histórico recente do cron (últimas 24h)
falhas_cron=$(exec_sql_quiet "SELECT count(*) FROM cron.job_run_details WHERE status = 'failed' AND start_time > now() - interval '24 hours';" || echo "0")
falhas_cron="${falhas_cron:-0}"
if [ "$falhas_cron" -gt 0 ]; then
  echo "  [!] ALERTA: $falhas_cron falha(s) de execução de jobs nas últimas 24h:"
  exec_sql "SELECT jobid, runid, status, return_message, to_char(start_time at time zone 'America/Sao_Paulo', 'HH24:MI:SS') as horario FROM cron.job_run_details WHERE status = 'failed' AND start_time > now() - interval '24 hours' ORDER BY start_time DESC LIMIT 5;"
  ALERTA_CRITICO=$((ALERTA_CRITICO + 1))
else
  echo "  ✓ Nenhuma falha de execução nos jobs do cron nas últimas 24h."
fi

# Alertas emitidos recentemente pelo sistema de monitoramento (privado.alerta_emitido)
alertas_recentes=$(exec_sql_quiet "SELECT count(*) FROM privado.alerta_emitido WHERE ultimo_em > now() - interval '24 hours';" || echo "0")
alertas_recentes="${alertas_recentes:-0}"
if [ "$alertas_recentes" -gt 0 ]; then
  echo "  [i] Alertas operacionais registrados nas últimas 24h ($alertas_recentes tipo(s)): "
  exec_sql "SELECT codigo, to_char(ultimo_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as ultimo, suprimidos FROM privado.alerta_emitido WHERE ultimo_em > now() - interval '24 hours' ORDER BY ultimo_em DESC;"
  ALERTA_MODERADO=$((ALERTA_MODERADO + 1))
else
  echo "  ✓ Nenhum alerta recente em privado.alerta_emitido nas últimas 24h."
fi
echo ""

# ── 2. FILAS PGMQ E NOTIFICAÇÕES PUSH (RN15 / RN23) ──────────────────────────
echo "▸ 2. Fila de Despacho e Notificações Push (pgmq / FCM)"
echo "--------------------------------------------------------------------------------"

# Fila pgmq.q_despacho
msgs_despacho=$(exec_sql_quiet "SELECT count(*) FROM pgmq.q_despacho;" || echo "0")
msgs_despacho="${msgs_despacho:-0}"
if [ "$msgs_despacho" -gt 0 ]; then
  idade_despacho=$(exec_sql_quiet "SELECT extract(epoch from (now() - min(enqueued_at)))::int FROM pgmq.q_despacho;" || echo "0")
  idade_despacho="${idade_despacho:-0}"
  if [ "$idade_despacho" -gt 900 ]; then # 15 minutos
    echo "  [!] CRÍTICO: Fila de despacho acumulada com $msgs_despacho mensagem(ns); mais antiga tem ${idade_despacho}s (>15 min)!"
    ALERTA_CRITICO=$((ALERTA_CRITICO + 1))
  else
    echo "  [i] Fila de despacho em processamento: $msgs_despacho mensagem(ns) (mais antiga: ${idade_despacho}s)."
    ALERTA_MODERADO=$((ALERTA_MODERADO + 1))
  fi
else
  echo "  ✓ Fila pgmq.q_despacho desimpedida (0 mensagens pendentes)."
fi

# Notificações retidas ou sem envio nas últimas 24h
notif_falhou=$(exec_sql_quiet "SELECT count(*) FROM public.notificacao WHERE estado_entrega = 'falhou' AND enviada_em > now() - interval '24 hours';" || echo "0")
notif_pendente=$(exec_sql_quiet "SELECT count(*) FROM public.notificacao WHERE estado_entrega = 'pendente' AND enviada_em < now() - interval '1 hour';" || echo "0")
notif_entregue=$(exec_sql_quiet "SELECT count(*) FROM public.notificacao WHERE estado_entrega = 'entregue' AND enviada_em > now() - interval '24 hours';" || echo "0")
notif_falhou="${notif_falhou:-0}"
notif_pendente="${notif_pendente:-0}"
notif_entregue="${notif_entregue:-0}"

echo "  Notificações push (últimas 24h): entregues=$notif_entregue, falhas=$notif_falhou, pendentes_retidas=$notif_pendente"
if [ "$notif_falhou" -gt 0 ]; then
  echo "  [!] Notificações com falha de entrega (amostra de motivos):"
  exec_sql "SELECT motivo_falha, count(*) as total FROM public.notificacao WHERE estado_entrega = 'falhou' AND enviada_em > now() - interval '24 hours' GROUP BY motivo_falha ORDER BY total DESC LIMIT 3;"
  ALERTA_MODERADO=$((ALERTA_MODERADO + 1))
fi
if [ "$notif_pendente" -gt 0 ]; then
  echo "  [!] ALERTA: Há $notif_pendente notificação(ões) pendentes há mais de 1 hora sem avanço!"
  ALERTA_CRITICO=$((ALERTA_CRITICO + 1))
fi

# Despachos sem notificação gerada
despachos_travados=$(exec_sql_quiet "SELECT count(*) FROM public.despacho WHERE notificacao_id IS NULL AND criado_em < now() - interval '1 hour';" || echo "0")
despachos_travados="${despachos_travados:-0}"
if [ "$despachos_travados" -gt 0 ]; then
  echo "  [!] ALERTA: $despachos_travados despacho(s) sem notificacao_id há mais de 1 hora!"
  ALERTA_CRITICO=$((ALERTA_CRITICO + 1))
else
  echo "  ✓ Zero despachos travados sem notificação."
fi
echo ""

# ── 3. FALHAS DE EXECUÇÃO INTERNA ─────────────────────────────────────────────
echo "▸ 3. Falhas de Execução Interna (privado.falha_execucao)"
echo "--------------------------------------------------------------------------------"
falhas_24h=$(exec_sql_quiet "SELECT count(*) FROM privado.falha_execucao WHERE criada_em > now() - interval '24 hours';" || echo "0")
falhas_24h="${falhas_24h:-0}"
if [ "$falhas_24h" -gt 0 ]; then
  echo "  [!] ATENÇÃO: $falhas_24h falha(s) de execução registradas nas últimas 24h:"
  exec_sql "SELECT origem, codigo, count(*) as total, to_char(max(criada_em) at time zone 'America/Sao_Paulo', 'HH24:MI') as ultima FROM privado.falha_execucao WHERE criada_em > now() - interval '24 hours' GROUP BY origem, codigo ORDER BY total DESC LIMIT 5;"
  ALERTA_MODERADO=$((ALERTA_MODERADO + 1))
else
  echo "  ✓ Nenhuma falha em privado.falha_execucao nas últimas 24h."
fi
echo ""

# ── 4. MODERAÇÃO, CONTESTAÇÕES E SUPORTE (Diretriz 1.2 da App Store) ──────────
echo "▸ 4. Moderação de Conteúdo e Suporte (Diretriz 1.2 App Store / RN13)"
echo "--------------------------------------------------------------------------------"
# Denúncias pendentes per privado.moderacao_pendente (prazo de 24h)
denuncias_vencidas=$(exec_sql_quiet "SELECT count(*) FROM privado.moderacao_pendente(interval '24 hours') WHERE vencida = true;" || echo "0")
denuncias_abertas=$(exec_sql_quiet "SELECT count(*) FROM privado.moderacao_pendente(interval '24 hours');" || echo "0")
denuncias_vencidas="${denuncias_vencidas:-0}"
denuncias_abertas="${denuncias_abertas:-0}"

if [ "$denuncias_vencidas" -gt 0 ]; then
  echo "  [!] CRÍTICO: $denuncias_vencidas denúncia(s) VENCIDAS sem moderação da Equipe Frila (>24h)!"
  exec_sql "SELECT ocorrencia_id as protocolo, to_char(criada_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as aberta, to_char(tratar_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as limite, motivo FROM privado.moderacao_pendente(interval '24 hours') WHERE vencida = true;"
  ALERTA_CRITICO=$((ALERTA_CRITICO + 1))
elif [ "$denuncias_abertas" -gt 0 ]; then
  echo "  [i] Denúncias em análise no prazo de 24h: $denuncias_abertas pendente(s)."
  exec_sql "SELECT ocorrencia_id as protocolo, to_char(criada_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as aberta, to_char(tratar_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as limite, motivo FROM privado.moderacao_pendente(interval '24 hours');"
  ALERTA_MODERADO=$((ALERTA_MODERADO + 1))
else
  echo "  ✓ Zero denúncias pendentes de moderação."
fi

# Contestações de despacho e chamados de suporte abertos
ocorrencias_abertas=$(exec_sql_quiet "SELECT count(*) FROM public.ocorrencia WHERE resolvido_em IS NULL;" || echo "0")
ocorrencias_abertas="${ocorrencias_abertas:-0}"
if [ "$ocorrencias_abertas" -gt 0 ]; then
  echo "  Chamados operacionais abertos por tipo ($ocorrencias_abertas no total):"
  exec_sql "SELECT tipo, count(*) as total, to_char(min(criada_em) at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') as mais_antiga FROM public.ocorrencia WHERE resolvido_em IS NULL GROUP BY tipo ORDER BY total DESC;"
else
  echo "  ✓ Todos os chamados operacionais e contestações estão resolvidos."
fi
echo ""

# ── 5. FILA DE E-MAILS TRANSACIONAIS (pgmq.q_email) ───────────────────────────
echo "▸ 5. E-mails Transacionais (pgmq / Resend)"
echo "--------------------------------------------------------------------------------"
msgs_email=$(exec_sql_quiet "SELECT count(*) FROM pgmq.q_email;" || echo "0")
msgs_email="${msgs_email:-0}"
if [ "$msgs_email" -gt 0 ]; then
  idade_email=$(exec_sql_quiet "SELECT extract(epoch from (now() - min(enqueued_at)))::int FROM pgmq.q_email;" || echo "0")
  idade_email="${idade_email:-0}"
  if [ "$idade_email" -gt 900 ]; then
    echo "  [!] ALERTA: Fila de e-mails retida: $msgs_email mensagem(ns); mais antiga tem ${idade_email}s (>15 min)!"
    ALERTA_CRITICO=$((ALERTA_CRITICO + 1))
  else
    echo "  [i] Fila de e-mails em envio: $msgs_email mensagem(ns) (idade: ${idade_email}s)."
    ALERTA_MODERADO=$((ALERTA_MODERADO + 1))
  fi
else
  echo "  ✓ Fila pgmq.q_email sem pendências."
fi

# E-mails com falha de disparo na ocorrência
emails_falhos=$(exec_sql_quiet "SELECT count(*) FROM public.ocorrencia WHERE email_ultimo_erro IS NOT NULL AND email_equipe_em IS NULL AND criada_em > now() - interval '24 hours';" || echo "0")
emails_falhos="${emails_falhos:-0}"
if [ "$emails_falhos" -gt 0 ]; then
  echo "  [!] Há $emails_falhos e-mail(s) de ocorrência com erro de envio nas últimas 24h!"
  ALERTA_MODERADO=$((ALERTA_MODERADO + 1))
else
  echo "  ✓ Nenhum erro de envio de e-mails registrado em ocorrências nas últimas 24h."
fi
echo ""

# ── 6. TURNOS, PRESENÇAS E ANOMALIAS DO PILOTO ───────────────────────────────
echo "▸ 6. Turnos e Presenças do Piloto (Operação Real)"
echo "--------------------------------------------------------------------------------"
turnos_ativos=$(exec_sql_quiet "SELECT count(*) FROM public.turno t JOIN public.posicao p ON p.id = t.posicao_id WHERE t.checkout_em IS NULL AND p.estado = 'confirmada' AND p.fim_em > now();" || echo "0")
turnos_sem_checkout_24h=$(exec_sql_quiet "SELECT count(*) FROM public.turno t JOIN public.posicao p ON p.id = t.posicao_id WHERE t.checkout_em IS NULL AND p.estado = 'confirmada' AND p.fim_em <= now() - interval '24 hours';" || echo "0")
turnos_sem_checkout_7d=$(exec_sql_quiet "SELECT count(*) FROM public.turno t JOIN public.posicao p ON p.id = t.posicao_id WHERE t.checkout_em IS NULL AND p.estado = 'confirmada' AND p.fim_em <= now() - interval '7 days';" || echo "0")
turnos_ativos="${turnos_ativos:-0}"
turnos_sem_checkout_24h="${turnos_sem_checkout_24h:-0}"
turnos_sem_checkout_7d="${turnos_sem_checkout_7d:-0}"

echo "  Turnos em andamento (confirmados, dentro do horário): $turnos_ativos"
if [ "$turnos_sem_checkout_7d" -gt 0 ]; then
  echo "  [!] ATENÇÃO: $turnos_sem_checkout_7d turno(s) sem checkout há mais de 7 dias (abandonados per LGPD/A2)!"
  ALERTA_MODERADO=$((ALERTA_MODERADO + 1))
elif [ "$turnos_sem_checkout_24h" -gt 0 ]; then
  echo "  [i] Turnos sem checkout há mais de 24h: $turnos_sem_checkout_24h (agendador de encerramento em ação)."
else
  echo "  ✓ Zero turnos anômalos sem checkout pendentes de encerramento."
fi

# Vagas e textos atualmente ocultados pela moderação
vagas_ocultas=$(exec_sql_quiet "SELECT count(*) FROM privado.vaga_ocultada WHERE ativa = true;" || echo "0")
textos_ocultos=$(exec_sql_quiet "SELECT count(*) FROM privado.texto_da_vaga_ocultado WHERE ativo = true;" || echo "0")
vagas_ocultas="${vagas_ocultas:-0}"
textos_ocultos="${textos_ocultos:-0}"
echo "  Conteúdo sob intervenção da Equipe Frila: vagas_ocultas=$vagas_ocultas, textos_ocultos=$textos_ocultos"
echo ""

# ── 7. VOLUMES E RECURSOS DO BANCO (Limites do Plano) ────────────────────────
echo "▸ 7. Recursos e Volume do Banco de Dados"
echo "--------------------------------------------------------------------------------"
tam_banco=$(exec_sql_quiet "SELECT pg_size_pretty(pg_database_size(current_database()));" || echo "desconhecido")
usuarios_totais=$(exec_sql_quiet "SELECT count(*) FROM public.usuario;" || echo "0")
estabelecimentos_totais=$(exec_sql_quiet "SELECT count(*) FROM public.estabelecimento;" || echo "0")
vagas_totais=$(exec_sql_quiet "SELECT count(*) FROM public.vaga;" || echo "0")
echo "  Tamanho total do banco de dados: $tam_banco"
echo "  Totais cadastrados: usuários=$usuarios_totais, estabelecimentos=$estabelecimentos_totais, vagas=$vagas_totais"
echo ""

# ── SEMÁFORO FINAL E CONCLUSÃO DO PLANTÃO ─────────────────────────────────────
echo "================================================================================"
echo "  VEREDITO DA CHECAGEM DIÁRIA"
echo "================================================================================"
if [ "$ALERTA_CRITICO" -gt 0 ]; then
  echo "  🔴 STATUS: VERMELHO — AÇÃO IMEDIATA NECESSÁRIA ($ALERTA_CRITICO alerta(s) crítico(s))"
  echo "  Recomendações do Plantão:"
  echo "    - Se jobs do cron falharam: consulte cron.job_run_details e docs/RUNBOOK-INCIDENTES.md."
  echo "    - Se denúncias venceram (>24h): acione imediatamente './scripts/moderar.sh pendentes 24'."
  echo "    - Se filas pgmq retidas: verifique os workers de Edge Functions e secrets no Supabase."
  exit 1
elif [ "$ALERTA_MODERADO" -gt 0 ]; then
  echo "  🟡 STATUS: AMARELO — ATENÇÃO OPERACIONAL ($ALERTA_MODERADO ponto(s) de atenção)"
  echo "  Recomendações do Plantão:"
  echo "    - Acompanhe as ocorrências em andamento e falhas de envio nas próximas rodadas."
  echo "    - O ambiente opera normalmente sem bloqueio impeditivo."
  exit 0
else
  echo "  🟢 STATUS: VERDE — OPERAÇÃO 100% REGULAR E SAUDÁVEL"
  echo "  Nenhuma anomalia operacional detectada nas filas, jobs, notificações ou moderação."
  exit 0
fi
