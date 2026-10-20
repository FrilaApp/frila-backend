-- Alerta operacional 'demonstracao_sob_ataque' em privado.verificar_saude() (Item 19).
--
-- Vigia tentativas com código incorreto registradas em public.entrada_demonstracao (aceita = false)
-- nos últimos 15 minutos. Se o total atingir ou superar o teto de 10 tentativas, emite alerta
-- operacional estruturado via privado.emitir_alerta('demonstracao_sob_ataque', ...).

-- ── 1. Suporte a payload jsonb estruturado em privado.emitir_alerta ───────────

create or replace function privado.emitir_alerta(
  p_codigo   text,
  p_detalhes jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ultimo timestamptz;
  v_agora  timestamptz := privado.agora();
  v_valor  numeric;
begin
  if p_codigo is null or p_codigo !~ '^[a-z0-9_]{1,60}$' then
    raise exception 'codigo_de_alerta_invalido' using errcode = '22023';
  end if;

  select ultimo_em into v_ultimo
    from privado.alerta_emitido
   where codigo = p_codigo;

  -- Respeita o teto: no máximo um por hora por tipo
  if v_ultimo is not null and v_ultimo > v_agora - interval '1 hour' then
    update privado.alerta_emitido
       set suprimidos = suprimidos + 1
     where codigo = p_codigo;
    return false;
  end if;

  insert into privado.alerta_emitido (codigo, ultimo_em, suprimidos)
  values (p_codigo, v_agora, 0)
  on conflict (codigo) do update
    set ultimo_em = v_agora,
        suprimidos = 0;

  if jsonb_typeof(p_detalhes->'tentativas_recusadas_15min') = 'number' then
    v_valor := (p_detalhes->>'tentativas_recusadas_15min')::numeric;
  elsif jsonb_typeof(p_detalhes->'valor') = 'number' then
    v_valor := (p_detalhes->>'valor')::numeric;
  end if;

  perform pgmq.send('email', jsonb_build_object(
    'tipo', 'alerta',
    'codigo', p_codigo,
    'detalhes', p_detalhes,
    'valor', v_valor
  ));

  return true;
end $$;

comment on function privado.emitir_alerta(text, jsonb) is
  'Enfileira alerta à equipe com payload jsonb estruturado na fila email respeitando teto de 1 por hora por tipo.';

revoke execute on function privado.emitir_alerta(text, jsonb) from public, anon, authenticated;
grant  execute on function privado.emitir_alerta(text, jsonb) to service_role;


-- ── 2. privado.verificar_saude() com alerta demonstracao_sob_ataque ───────────

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

  -- 7. Denúncias abertas há mais de 24h sem resolução (Diretriz 1.2 da App Store, Item 21)
  select count(*) into v_moderacoes_vencidas
    from public.ocorrencia
   where tipo = 'denuncia'
     and resolvido_em is null
     and criada_em < v_agora - interval '24 hours';
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

  return v_alertas;
end $$;

comment on function privado.verificar_saude() is
  'Varre filas pgmq, falhas de cron, notificações com erro (incluindo NOT_FOUND do FCM), despachos retidos, falhas de execução, denúncias sem moderação após 24h (Diretriz 1.2), contestações vencidas (RN13), falhas assíncronas do pg_net e tentativas recusadas de demonstração (Item 19). Emite alertas à equipe por e-mail com limite de 1/hora por tipo.';

revoke execute on function privado.verificar_saude() from public, anon, authenticated;
grant  execute on function privado.verificar_saude() to service_role;
