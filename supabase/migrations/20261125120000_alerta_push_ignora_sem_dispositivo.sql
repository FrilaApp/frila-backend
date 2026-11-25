-- B-119: alarme falso diário de notificacao_push_falhou.
--
-- O item 4 de privado.verificar_saude() contava toda notificação 'falhou' na última hora. No DEV, de 3 a 6 por dia
-- (desde 18/11/2026) eram motivo_falha = 'sem_dispositivo' (conta sem aparelho registrado), e o alerta acendia todo dia
-- sem que nada estivesse quebrado; no Prod acontece o mesmo com quem não ativou o push.
-- 'sem_dispositivo' e 'versao_nao_suportada' (aviso chamada_* para versão do app abaixo do mínimo) têm a mesma natureza:
-- não existe aparelho capaz de receber, e isso não é falha de entrega do Frila. Os dois saem do alarme.
-- Motivo nulo ou qualquer outro (FAILED_PRECONDITION, UNREGISTERED, NOT_FOUND, falha_envio...) continua contando:
-- por isso 'is distinct from', e não '<>' ou 'not in', que descartariam o nulo.
--
-- privado.verificar_saude(): cópia exata de 20261124190000, só o item 4 muda. Item 4b (NOT_FOUND, 15 min) e os demais
-- ficam idênticos; mesmos security definer, search_path, COMMENT, revoke e grant.

create or replace function privado.verificar_saude()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alertas               int := 0;
  v_idade_despacho        interval;
  v_idade_email           interval;
  v_falhas_cron           int;
  v_notif_falhas          int;
  v_fcm_config_falhas     int;
  v_despachos_travados    int;
  v_falhas_exec           int;
  v_moderacoes_vencidas   int;
  v_contestacoes_vencidas int;
  v_tentativas            int;
  v_pgnet_transporte_falhas int;
  v_pgnet_recusadas_falhas  int;
  v_agora                 timestamptz := privado.agora();
  v_teto_janela           interval;
  v_coleta                privado.registro_acesso_coleta%rowtype;
  v_atraso_mb             numeric;
begin
  -- 0. Autoproteção do slot do registro de acessos (20261108110000). Vem antes de qualquer alerta, porque recriar
  --    o slot exige uma transação sem escrita. Se falhar aqui, o item 11 ainda alerta pelo atraso.
  begin
    perform privado.proteger_slot_registro_acesso('verificar_saude');
  exception when others then
    null;
  end;

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

  -- 4. Notificações com estado 'falhou' na última hora, menos as que não tinham aparelho capaz de receber
  --    ('sem_dispositivo', 'versao_nao_suportada'): não são falha de entrega nossa (B-119). 'is distinct from'
  --    para motivo nulo (ou motivo novo) continuar contando.
  select count(*) into v_notif_falhas
    from public.notificacao
   where estado_entrega = 'falhou'
     and motivo_falha is distinct from 'sem_dispositivo'
     and motivo_falha is distinct from 'versao_nao_suportada'
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

  -- 7. Denúncias abertas além do prazo do tipo (Diretriz 1.2 da App Store, Item 21; regra do Cauê, 24/11/2026):
  --    a regra mora em privado.denuncia_prazo_ate (a mesma que a fila de plantão, privado.moderacao_pendente,
  --    e o console consultar-ocorrencias.sql usam): motivo 'outro' sem foto vence depois de 5 dias úteis; todo o
  --    resto (foto, risco_seguranca, assedio, discriminacao e motivo irreconhecível, falha fechada) vence em 24 h.
  select count(*) into v_moderacoes_vencidas
    from public.ocorrencia
   where tipo = 'denuncia'
     and resolvido_em is null
     and v_agora > privado.denuncia_prazo_ate(motivo, midia_id, criada_em);
  if v_moderacoes_vencidas > 0 then
    if privado.emitir_alerta('moderacao_vencida', v_moderacoes_vencidas) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 8. Contestações de suspensão abertas há mais de 5 dias úteis sem resolução (RN13, Item 21b)
  select count(*) into v_contestacoes_vencidas
    from public.ocorrencia
   where tipo = 'contestacao'
     and resolvido_em is null
     and (v_agora at time zone 'America/Sao_Paulo')::date > privado.prazo_de_resposta(criada_em);
  if v_contestacoes_vencidas > 0 then
    if privado.emitir_alerta('contestacao_vencida', v_contestacoes_vencidas) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 9. Falhas assíncronas do pg_net em net._http_response nos últimos 15 min (Item 22)
  begin
    if (
      exists (select 1 from privado.ambiente where eh_teste)
      and coalesce(current_setting('frila.simular_sem_pgnet', true), 'off') = 'on'
    ) then
      if privado.emitir_alerta('pgnet_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
    elsif exists (select 1 from pg_tables where schemaname = 'net' and tablename = '_http_response')
       and has_table_privilege('postgres', 'net._http_response', 'select') then
      if (
        exists (select 1 from privado.ambiente where eh_teste)
        and coalesce(current_setting('frila.simular_excecao_pgnet', true), 'off') = 'on'
      ) then
        raise exception 'simulacao de erro pgnet em tempo de execucao';
      end if;

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
      if privado.emitir_alerta('pgnet_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  exception
    when others then
      if privado.emitir_alerta('pgnet_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
  end;

  -- 10. Tentativas recusadas de demonstração nos últimos 15 min (demonstracao_sob_ataque)
  select count(*) into v_tentativas
    from public.entrada_demonstracao
   where aceita = false
     and em >= v_agora - interval '15 minutes';

  if v_tentativas >= 10 then
    if privado.emitir_alerta(
      'demonstracao_sob_ataque',
      jsonb_build_object(
        'tentativas_recusadas_15min', v_tentativas,
        'teto', 10
      )
    ) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 11. Registro de acessos (Marco Civil art. 15, 20261108110000), só com a coleta ligada:
  --  a) o consumidor não consome há mais de 15 minutos;
  --  b) o atraso do slot passou da metade do teto (a autoproteção derruba no teto).
  -- Os buracos já entram em privado.falha_execucao e acendem o item 6.
  begin
    select c.* into v_coleta from privado.registro_acesso_coleta c where c.unica;
    if coalesce(v_coleta.ligada, false) then
      if coalesce(v_coleta.consumido_em, v_coleta.alterada_em) < v_agora - interval '15 minutes' then
        if privado.emitir_alerta('registro_acesso_parado', jsonb_build_object(
             'valor', round(extract(epoch from v_agora - coalesce(v_coleta.consumido_em, v_coleta.alterada_em)) / 60),
             'unidade', 'minutos')) then
          v_alertas := v_alertas + 1;
        end if;
      end if;
      -- Pelo restart_lsn, que é o que retém o WAL (Lince AG 2, E7b).
      select round(pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) / 1048576.0, 1)
        into v_atraso_mb
        from pg_catalog.pg_replication_slots s
       where s.slot_name = privado.slot_registro_acesso();
      if v_atraso_mb is not null and v_atraso_mb > v_coleta.teto_wal_mb / 2.0 then
        if privado.emitir_alerta('registro_acesso_wal_atrasado', jsonb_build_object(
             'valor', v_atraso_mb, 'teto_mb', v_coleta.teto_wal_mb)) then
          v_alertas := v_alertas + 1;
        end if;
      end if;
    end if;
  exception
    when others then
      if privado.emitir_alerta('registro_acesso_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
  end;

  return v_alertas;
end $$;

comment on function privado.verificar_saude() is
  'Varre filas pgmq, falhas de cron, notificações com erro (incluindo NOT_FOUND do FCM), despachos retidos, falhas de execução, denúncias sem moderação fora do prazo do tipo (24 h; 5 dias úteis para o motivo outro sem foto) (Diretriz 1.2), contestações vencidas (RN13), falhas assíncronas do pg_net, tentativas recusadas de demonstração (Item 19) e o registro de acessos (autoproteção do slot lógico no começo; consumidor parado há mais de 15 min; atraso do slot acima da metade do teto). Emite alertas à equipe por e-mail com limite de 1/hora por tipo.';

revoke execute on function privado.verificar_saude() from public, anon, authenticated;
grant  execute on function privado.verificar_saude() to service_role;
