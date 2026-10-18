-- Alerta operacional de falhas assíncronas do pg_net em privado.verificar_saude() (Item 22).
--
-- O pg_net despacha requisições em background e grava respostas em net._http_response.
-- Esta migração atualiza privado.verificar_saude() para vigiar a tabela nos últimos 15 minutos:
-- 1. 'pgnet_falha_transporte': quando timed_out = true, error_msg is not null ou status_code >= 500 (queda/indisponibilidade).
-- 2. 'pgnet_resposta_recusada': quando status_code in (401, 403, 404) (segredo descompassado ou rota inexistente).
-- A consulta lê estritamente status e metadados de erro, nunca headers ou corpo (sigilo absoluto).
-- Possui guarda defensiva para não falhar caso a extensão/tabela net._http_response não esteja presente.

create or replace function privado.verificar_saude()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alertas                  int := 0;
  v_idade_despacho           interval;
  v_idade_email              interval;
  v_falhas_cron              int;
  v_notif_falhas             int;
  v_despachos_travados       int;
  v_falhas_exec              int;
  v_fcm_config_falhas        int;
  v_pgnet_transporte_falhas  int;
  v_pgnet_recusadas_falhas   int;
  v_agora                    timestamptz := privado.agora();
  v_teto_janela              interval;
begin
  -- 1. Job de despacho ativo (RNF12)
  if not exists (
    select 1 from cron.job
     where jobname = 'reprocessar_despacho' and active = true
  ) then
    if privado.emitir_alerta('job_despacho_parado', 1) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 2. Idade da mensagem mais velha nas filas pgmq (teto de 15 minutos)
  if exists (select 1 from pg_tables where schemaname = 'pgmq' and tablename = 'q_despacho') then
    select v_agora - min(enqueued_at) into v_idade_despacho from pgmq.q_despacho;
    if v_idade_despacho is not null and v_idade_despacho > interval '15 minutes' then
      if privado.emitir_alerta('fila_despacho_antiga', extract(epoch from v_idade_despacho)::numeric) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  end if;

  if exists (select 1 from pg_tables where schemaname = 'pgmq' and tablename = 'q_email') then
    select v_agora - min(enqueued_at) into v_idade_email from pgmq.q_email;
    if v_idade_email is not null and v_idade_email > interval '15 minutes' then
      if privado.emitir_alerta('fila_email_antiga', extract(epoch from v_idade_email)::numeric) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  end if;

  -- 3. Falhas recentes em cron.job_run_details (últimos 15 minutos)
  if exists (select 1 from pg_tables where schemaname = 'cron' and tablename = 'job_run_details') then
    select count(*) into v_falhas_cron
      from cron.job_run_details
     where status = 'failed'
       and end_time > v_agora - interval '15 minutes';
    if v_falhas_cron > 0 then
      if privado.emitir_alerta('job_cron_falhou', v_falhas_cron) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  end if;

  -- 4. Notificações com estado 'falhou' na última hora
  select count(*) into v_notif_falhas
    from public.notificacao
   where estado_entrega = 'falhou'
     and enviada_em > v_agora - interval '1 hour';
  if v_notif_falhas > 0 then
    if privado.emitir_alerta('notificacao_push_falhou', v_notif_falhas) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 4b. Falha de configuração do FCM (projeto inexistente ou URL incorreta):
  -- Notificações que falharam com motivo 'NOT_FOUND' nos últimos 15 minutos (sugestão do Oráculo).
  select count(*) into v_fcm_config_falhas
    from public.notificacao
   where motivo_falha = 'NOT_FOUND'
     and estado_entrega = 'falhou'
     and enviada_em > v_agora - interval '15 minutes';
  if v_fcm_config_falhas > 0 then
    if privado.emitir_alerta('fcm_configuracao_suspeita', v_fcm_config_falhas) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 5. Despachos esperando além do teto de RN23
  v_teto_janela := coalesce(privado.parametro_de_notificacao('teto_janela'), interval '30 minutes');
  select count(*) into v_despachos_travados
    from public.despacho d
    join public.vaga v on v.id = d.vaga_id
   where d.notificacao_id is null
     and v.estado = 'publicada'
     and v.inicio_em > v_agora
     and d.criado_em < v_agora - (v_teto_janela + interval '15 minutes');
  if v_despachos_travados > 0 then
    if privado.emitir_alerta('despacho_esperando_alem_do_teto', v_despachos_travados) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 6. Falhas de execução registradas por Edge Functions nos últimos 15 minutos
  select count(*) into v_falhas_exec
    from privado.falha_execucao
   where criada_em > v_agora - interval '15 minutes';
  if v_falhas_exec > 0 then
    if privado.emitir_alerta('falha_execucao_edge_function', v_falhas_exec) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 7. Falhas assíncronas do pg_net em net._http_response nos últimos 15 min (Item 22)
  begin
    if exists (select 1 from pg_tables where schemaname = 'net' and tablename = '_http_response')
       and has_table_privilege('postgres', 'net._http_response', 'select') then
      -- 7a. Falha de transporte ou infraestrutura (timeout, erro de conexão/DNS ou 5xx)
      -- Limiar >= 3 na janela de 15 min para evitar falso alerta em timeouts transitórios de deploy
      execute $dyn$
        select count(*)
          from net._http_response
         where created > $1 - interval '15 minutes'
           and (
             timed_out = true
             or error_msg is not null
             or status_code >= 500
           )
      $dyn$ into v_pgnet_transporte_falhas using v_agora;

      if v_pgnet_transporte_falhas >= 3 then
        if privado.emitir_alerta('pgnet_falha_transporte', v_pgnet_transporte_falhas) then
          v_alertas := v_alertas + 1;
        end if;
      end if;

      -- 7b. Resposta HTTP recusada (401/403 de autenticação ou 404 de URL/rota inexistente)
      -- Limiar > 0 mantido: 401/403/404 em chamada da nossa infraestrutura indica erro imediato de configuração
      execute $dyn$
        select count(*)
          from net._http_response
         where created > $1 - interval '15 minutes'
           and status_code in (401, 403, 404)
      $dyn$ into v_pgnet_recusadas_falhas using v_agora;

      if v_pgnet_recusadas_falhas > 0 then
        if privado.emitir_alerta('pgnet_resposta_recusada', v_pgnet_recusadas_falhas) then
          v_alertas := v_alertas + 1;
        end if;
      end if;
    else
      -- Ramo sem tabela net._http_response ou sem privilégio de SELECT pelo papel postgres:
      -- Emite alerta operacional com rate-limit para avisar que o monitoramento do pg_net está inativo
      if privado.emitir_alerta('pgnet_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  exception
    when others then
      -- Falha ao consultar net._http_response (ex.: falta de privilégios no Supabase hospedado)
      -- é registrada defensivamente em alerta opcional com rate-limit e nunca aborta os blocos 1 a 6.
      if privado.emitir_alerta('pgnet_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
  end;

  return v_alertas;
end $$;

comment on function privado.verificar_saude() is
  'Varre filas pgmq, falhas de jobs do pg_cron, notificações com erro, falhas de configuração do FCM, despachos retidos, falhas de execução e falhas assíncronas de transporte/recusa do pg_net. Emite alertas à equipe por e-mail com limite de 1/hora por tipo.';

revoke execute on function privado.verificar_saude() from public, anon, authenticated;
grant  execute on function privado.verificar_saude() to service_role;
