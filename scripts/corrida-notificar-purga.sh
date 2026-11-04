#!/usr/bin/env bash
# Prova determinística de concorrência entre notificar e expurgo (K-001k/K-001l/K-001n, Risco N1).
#
# O pgTAP roda numa única sessão SQL e não consegue reproduzir a corrida onde
# `privado.notificar` consulta a tabela antes do expurgo, uma sessão concorrente
# purga a notificação antiga (60 dias) e comita, e a primeira sessão tenta inserir
# novamente a mesma chave.
#
# Este script abre DUAS sessões concorrentes com sincronização verificável (K-001n):
#   - Sessão 1 (Purga): abre transação, adquire lock SHARE em public.notificacao e
#     aguarda sinal via FIFO.
#   - O coordenador confirma que a Sessão 1 possui o lock SHARE ativo.
#   - Sessão 2 (Notificar): disparada concorrentemente contra o banco.
#   - O coordenador monitora as sessões via pg_stat_activity e pg_locks com timeout:
#       * Na função com defeito (antiga): notificar tenta INSERT em public.notificacao
#         e fica bloqueada em wait_event = 'Lock:relation'. O coordenador detecta o bloqueio,
#         ordena a purga e o commit da Sessão 1. A Sessão 2 desbloqueia e recria o aviso (falha).
#       * Na função corrigida (nova): a marca durável é a autoridade atômica. A Sessão 2
#         apenas consulta notificacao (AccessShareLock, compatível com SHARE) e termina
#         com sucesso ANTES da purga, sem tentar INSERT.
#       * Se a Sessão 2 atrasar (ex: atraso de 1.8s) ou não atingir o ponto crítico antes
#         do término da janela de intercalação, o teste FALHA por ausência de intercalação.
#
# O que o script exige ao final:
#   1. A intercalação foi efetivamente verificada antes da purga.
#   2. A notificação antiga com mais de 60 dias é purgada pela Sessão 1.
#   3. Notificar não re-insere o aviso expurgado (aviso_recriado = 0).
#   4. A marca durável em privado.marca_notificacao permanece intacta (marca_preservada = 1).
#
# Uso: ./scripts/corrida-notificar-purga.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

DB=${DB_CONTAINER:-supabase_db_frila-backend}

psql() { docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

ok()     { printf '  ✓ %s\n' "$1"; }
falhou() { printf '  ✗ %s\n' "$1" >&2; falha=1; }

TMP=$(mktemp -d)
falha=0

U_ID="784b0000-0000-4000-8000-000000000001"
REF_ID="784b0000-0000-4000-8000-000000000002"

limpar_dados() {
  psql >/dev/null 2>&1 <<SQL || echo "  aviso: a limpeza falhou na corrida de notificar/purga" >&2
set session_replication_role = 'replica';
delete from public.notificacao where usuario_id = '$U_ID';
do \$\$
begin
  if to_regclass('privado.marca_notificacao') is not null then
    delete from privado.marca_notificacao where usuario_id = '$U_ID';
  end if;
end \$\$;
delete from public.usuario where id = '$U_ID';
set session_replication_role = 'origin';
SQL
}

limpar_tudo() {
  # Fecha descritor de escrita da Sessão 1 se ainda aberto
  exec 3>&- 2>/dev/null || true
  if [ -n "${PID_SESSAO1:-}" ] && kill -0 "$PID_SESSAO1" 2>/dev/null; then
    kill "$PID_SESSAO1" 2>/dev/null || true
    wait "$PID_SESSAO1" 2>/dev/null || true
  fi
  if [ -n "${PID_SESSAO2:-}" ] && kill -0 "$PID_SESSAO2" 2>/dev/null; then
    kill "$PID_SESSAO2" 2>/dev/null || true
    wait "$PID_SESSAO2" 2>/dev/null || true
  fi
  limpar_dados
  rm -rf "$TMP"
}
trap limpar_tudo EXIT

echo "▸ Montando cenário de corrida entre notificar e purga (N1)"

# Limpa resíduos prévios se houver
limpar_dados >/dev/null 2>&1 || true

# Cria usuário de teste e notificação expirada (70 dias atrás)
psql >/dev/null <<SQL
insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado
) values (
  '$U_ID', 'profissional', 'Teste Concorrência Purga', '+5561984400001',
  'corrida_notificar_purga@frila.test', '1995-05-10', '1.0', now(), 'ativa'
) on conflict do nothing;

insert into public.notificacao (
  usuario_id, tipo, referencia_id, enviada_em
) values (
  '$U_ID', 'lembrete_24h', '$REF_ID', privado.agora() - interval '70 days'
);
SQL

# Garante que a notificação e a marca foram criadas
marca_inicial=$(psql -tAc "select count(*) from privado.marca_notificacao where usuario_id = '$U_ID' and referencia_id = '$REF_ID';")
if [ "$marca_inicial" -ne 1 ]; then
  falhou "marca inicial não foi registrada"
  exit 1
fi

echo "▸ Disparando Sessão 1 (Purga) com lock SHARE em public.notificacao"

FIFO1="$TMP/sessao1.fifo"
mkfifo "$FIFO1"

# Abre processo da Sessão 1 ouvindo o FIFO (com ON_ERROR_STOP=1 para propagar erros SQL)
docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 < "$FIFO1" > "$TMP/sessao1.out" 2> "$TMP/sessao1.err" &
PID_SESSAO1=$!

# Abre descritor 3 para manter o pipe aberto sem fechar a entrada do psql
exec 3> "$FIFO1"

# Sessão 1: adquire lock SHARE e sinaliza prontidão
printf "set application_name = 'corrida_purga_sessao1';\nbegin;\nset local statement_timeout = '15s';\nlock public.notificacao in share mode;\nselect 'LOCK_SHARE_ADQUIRIDO';\n" >&3

lock_adquirido=0
for i in $(seq 1 60); do # até 3.0s
  if grep -q "LOCK_SHARE_ADQUIRIDO" "$TMP/sessao1.out" 2>/dev/null; then
    lock_adquirido=1
    break
  fi
  sleep 0.05
done

if [ "$lock_adquirido" -ne 1 ]; then
  falhou "Sessão 1 não conseguiu adquirir lock SHARE em public.notificacao: $(cat "$TMP/sessao1.err" 2>/dev/null)"
  exit 1
fi

ok "Sessão 1 segurando lock SHARE ativo em public.notificacao"

echo "▸ Disparando Sessão 2 (Notificar) concorrentemente"

# Permite injeção de atraso para teste de sensibilidade à ausência de concorrência
ATRASO_SQL=""
if [ -n "${ATRASO_SESSAO2:-}" ]; then
  ATRASO_SQL="select pg_sleep($ATRASO_SESSAO2);"
fi

# Sessão 2: executa com -v ON_ERROR_STOP=1 para garantir que qualquer erro SQL seja propagado (N-003)
docker exec -i "$DB" psql -U postgres -d postgres -X -q -v ON_ERROR_STOP=1 -t -A <<SQL >"$TMP/sessao2.out" 2>"$TMP/sessao2.err" &
set application_name = 'corrida_notificar_sessao2';
set statement_timeout = '12s';
$ATRASO_SQL
select privado.notificar('$U_ID', 'lembrete_24h', '$REF_ID');
SQL
PID_SESSAO2=$!

echo "▸ Monitorando intercalação verificável das duas sessões"

intercalacao_detectada=""
s2_erro_precoce=0

# Limite de espera para a intercalação (15 rodadas ~1.2s)
for i in $(seq 1 15); do
  # 1. Verifica se a Sessão 2 bloqueou aguardando lock na tabela notificacao
  # (comportamento da função com defeito, que tenta INSERT e conflita com SHARE lock)
  wait_event=$(psql -tAc "select coalesce(wait_event_type,'')||':'||coalesce(wait_event,'') from pg_stat_activity where application_name = 'corrida_notificar_sessao2' and state = 'active';" 2>/dev/null || true)
  if [ "$wait_event" = "Lock:relation" ]; then
    intercalacao_detectada="bloqueado_no_insert"
    break
  fi

  # 2. Verifica se a Sessão 2 terminou
  if ! kill -0 "$PID_SESSAO2" 2>/dev/null; then
    wait "$PID_SESSAO2" 2>/dev/null || S2_EXIT=$?
    S2_EXIT=${S2_EXIT:-0}
    if [ "$S2_EXIT" -ne 0 ] || grep -qE "(ERROR|FATAL|PANIC):" "$TMP/sessao2.err" 2>/dev/null; then
      intercalacao_detectada="sessao2_falhou"
      s2_erro_precoce=1
      break
    fi

    # Sessão 2 terminou com sucesso. Verifica se Sessão 1 AINDA está segurando o lock SHARE
    lock_ativo=$(psql -tAc "select count(*) from pg_locks l join pg_stat_activity a on l.pid = a.pid where a.application_name = 'corrida_purga_sessao1' and l.relation = 'public.notificacao'::regclass and l.mode = 'ShareLock' and l.granted = true;" 2>/dev/null || echo 0)
    if [ "$lock_ativo" -eq 1 ]; then
      intercalacao_detectada="terminou_antes_da_purga"
      break
    else
      intercalacao_detectada="sessao2_apos_purga"
      break
    fi
  fi

  sleep 0.05
done

if [ "$intercalacao_detectada" = "bloqueado_no_insert" ]; then
  ok "Intercalação verificada: Sessão 2 aguardando lock de notificacao (tentativa de INSERT bloqueada)"
elif [ "$intercalacao_detectada" = "terminou_antes_da_purga" ]; then
  ok "Intercalação verificada: Sessão 2 terminou antes da purga sem tentar INSERT (marca atômica)"
elif [ "$intercalacao_detectada" = "sessao2_falhou" ]; then
  falhou "Sessão 2 (notificar) falhou com erro SQL antes da purga (exit=${S2_EXIT:-3}): $(cat "$TMP/sessao2.err" 2>/dev/null)"
elif [ "$intercalacao_detectada" = "sessao2_apos_purga" ]; then
  falhou "Intercalação inválida: Sessão 2 só executou depois que a purga já havia sido concluída."
else
  falhou "Intercalação não ocorreu dentro do tempo limite: Sessão 2 não atingiu o lock enquanto Sessão 1 segurava SHARE."
fi

# Se a intercalação foi válida e sem erro de Sessão 2, comanda a Sessão 1 a purgar e commitar
if [ "$intercalacao_detectada" = "bloqueado_no_insert" ] || [ "$intercalacao_detectada" = "terminou_antes_da_purga" ]; then
  printf "select 'purgados=' || privado.limpar_notificacoes_antigas(60, 5000);\ncommit;\n" >&3
  exec 3>&- # Fecha FIFO para que psql encerre

  wait $PID_SESSAO1 2>/dev/null || S1_EXIT=$?
  S1_EXIT=${S1_EXIT:-0}
  if [ -n "${PID_SESSAO2:-}" ] && kill -0 "$PID_SESSAO2" 2>/dev/null; then
    wait $PID_SESSAO2 2>/dev/null || S2_EXIT=$?
    S2_EXIT=${S2_EXIT:-0}
  fi

  if [ "$S1_EXIT" -ne 0 ] || grep -qE "(ERROR|FATAL|PANIC):" "$TMP/sessao1.err" 2>/dev/null; then
    falhou "Sessão 1 (purga) falhou (exit=$S1_EXIT): $(cat "$TMP/sessao1.err" 2>/dev/null)"
  fi
  if [ "${S2_EXIT:-0}" -ne 0 ] || grep -qE "(ERROR|FATAL|PANIC):" "$TMP/sessao2.err" 2>/dev/null; then
    falhou "Sessão 2 (notificar) falhou (exit=${S2_EXIT:-0}): $(cat "$TMP/sessao2.err" 2>/dev/null)"
  fi
else
  exec 3>&- 2>/dev/null || true
  wait $PID_SESSAO1 2>/dev/null || true
  if [ -n "${PID_SESSAO2:-}" ] && kill -0 "$PID_SESSAO2" 2>/dev/null; then
    wait $PID_SESSAO2 2>/dev/null || true
  fi
fi

echo "▸ Verificando resultado da corrida"

recriado=$(psql -tAc "select count(*) from public.notificacao where usuario_id = '$U_ID' and referencia_id = '$REF_ID';")
marca_final=$(psql -tAc "select count(*) from privado.marca_notificacao where usuario_id = '$U_ID' and referencia_id = '$REF_ID';")

if [ "$recriado" -eq 0 ]; then
  ok "Aviso expurgado não foi recriado concorrentemente (recriado = 0)"
else
  falhou "Aviso expurgado foi recriado indevidamente (recriado = $recriado)"
fi

if [ "$marca_final" -eq 1 ]; then
  ok "Marca durável foi preservada (marca = 1)"
else
  falhou "Marca durável foi perdida (marca = $marca_final)"
fi

echo
if [ "$falha" -eq 0 ]; then
  echo "✓ Prova de concorrência notificar x purga aprovada: marca impede recriação."
  exit 0
else
  echo "✗ Falha na prova de concorrência notificar x purga."
  exit 1
fi
