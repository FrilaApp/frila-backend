-- Alertas operacionais de moderação e contestação vencidas em privado.verificar_saude()
-- e fechamento automático de denúncia/contestação nas ações da equipe (Itens 21 e 21b, Diretriz 1.2 da App Store e RN13).
--
-- 1. Alerta 'moderacao_vencida': denúncias sem resolvido_em criadas há mais de 24 horas corridas.
-- 2. Alerta 'contestacao_vencida': contestações sem resolvido_em cujo prazo_de_resposta (5 dias úteis) já expirou.
-- 3. Fechamento das denúncias da vaga em privado.operacao_moderar_conteudo e privado.operacao_moderar_texto (resolvido_em preenchido).
-- 4. Fechamento das contestações do usuário em privado.operacao_reativar_conta (resolvido_em preenchido).
-- 5. Teto de tamanho no relato de public.contestar_suspensao (10 a 5000 caracteres).

-- ── 1. verificar_saude com novos alertas operacionais ───────────────────────────

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
    if exists (select 1 from pg_tables where schemaname = 'net' and tablename = '_http_response')
       and has_table_privilege('postgres', 'net._http_response', 'select') then
      -- 9a. Falha de transporte ou infraestrutura (timeout, erro de conexão/DNS ou 5xx)
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

      -- 9b. Resposta HTTP recusada (401/403 de autenticação ou 404 de URL/rota inexistente)
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
    end if;
  exception
    when others then
      -- Falha ao consultar net._http_response (ex.: falta de privilégios no Supabase hospedado)
      -- é registrada defensivamente em alerta opcional com rate-limit e nunca aborta os blocos 1 a 8.
      if privado.emitir_alerta('pgnet_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
  end;

  return v_alertas;
end $$;

comment on function privado.verificar_saude() is
  'Varre filas pgmq, falhas de cron, notificações com erro (incluindo NOT_FOUND do FCM), despachos retidos, falhas de execução, denúncias sem moderação após 24h (Diretriz 1.2) e contestações vencidas (RN13). Emite alertas à equipe por e-mail com limite de 1/hora por tipo.';

revoke execute on function privado.verificar_saude() from public, anon, authenticated;
grant  execute on function privado.verificar_saude() to service_role;


-- ── 2. operacao_moderar_conteudo: fecha denúncias abertas da vaga ───────────────

create or replace function privado.operacao_moderar_conteudo(
  vaga_id     uuid,
  acao        text,
  motivo      text,
  operador_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_vaga_id  uuid := operacao_moderar_conteudo.vaga_id;
  v_acao     text := pg_catalog.btrim(operacao_moderar_conteudo.acao);
  v_motivo   text := pg_catalog.btrim(operacao_moderar_conteudo.motivo);
  v_operador uuid := operacao_moderar_conteudo.operador_id;
  v_vaga     public.vaga%rowtype;
  v_agora    timestamptz := privado.agora();
  v_oc_id    uuid;
begin
  if v_vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  select * into v_vaga
    from public.vaga g
   where g.id = v_vaga_id
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_vaga.publicado_por);

  if v_acao is null or v_acao not in ('ocultar', 'reexibir') then
    perform public.erro(422, 'campo_invalido', 'acao');
  end if;

  if v_acao = 'ocultar' then
    if privado.vaga_oculta(v_vaga_id) then
      return jsonb_build_object(
        'vaga_id',          v_vaga_id,
        'estado_atual',     v_vaga.estado,
        'oculta',           true,
        'ja_estava_oculta', true
      );
    end if;

    -- Só a vaga que ainda é oferecida tem o que ocultar.
    if v_vaga.estado not in ('publicada', 'preenchida') then
      perform public.erro(422, 'campo_invalido', 'estado_da_vaga');
    end if;

    -- `suporte`, não `denuncia`: a denúncia é de quem a abriu (`denunciar`), e esta
    -- ocorrência é a ação da Equipe Frila sobre ela.
    insert into public.ocorrencia (
      tipo, usuario_id, estabelecimento_id, autor_id, motivo, criada_em, resolvido_em, resultado
    ) values (
      'suporte',
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_operador,
      'Moderação Diretriz 1.2: ' || v_motivo,
      v_agora,
      v_agora,
      'Vaga ocultada em até 24h pela Equipe Frila, sem cancelar os turnos confirmados.'
    ) returning id into v_oc_id;

    insert into privado.vaga_ocultada (vaga_id, ocorrencia_id, oculta_em)
    values (v_vaga_id, v_oc_id, v_agora);

    -- Fecha denúncias abertas associadas à vaga denunciada (Diretriz 1.2, Item 21c)
    update public.ocorrencia o
       set resolvido_em = v_agora,
           resultado    = coalesce(o.resultado, 'Conteúdo moderado em até 24h pela Equipe Frila (Diretriz 1.2).')
     where o.tipo = 'denuncia'
       and o.resolvido_em is null
       and (
         exists (
           select 1 from public.turno t
             join public.posicao p on p.id = t.posicao_id
            where p.vaga_id = v_vaga_id
              and t.id = o.turno_id
         )
         or (
           o.estabelecimento_id is not null
           and o.estabelecimento_id = v_vaga.estabelecimento_id
         )
       );

    return jsonb_build_object(
      'vaga_id',       v_vaga_id,
      'estado_atual',  v_vaga.estado,
      'oculta',        true,
      'ocorrencia_id', v_oc_id,
      'acao',          'ocultar',
      'moderado_em',   v_agora
    );
  else -- v_acao = 'reexibir'
    -- Só a vaga que a Equipe ocultou. Reexibir tira a marca e não mexe no `estado`: a
    -- vaga que a casa cancelou (antes ou depois de ocultada) segue cancelada.
    if not privado.vaga_oculta(v_vaga_id) then
      perform public.erro(422, 'campo_invalido', 'vaga_nao_ocultada');
    end if;

    delete from privado.vaga_ocultada where vaga_id = v_vaga_id;

    insert into public.ocorrencia (
      tipo, usuario_id, estabelecimento_id, autor_id, motivo, criada_em, resolvido_em, resultado
    ) values (
      'suporte',
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_operador,
      'Moderação Reexibir: ' || v_motivo,
      v_agora,
      v_agora,
      'Vaga reexibida pela Equipe Frila após análise da moderação.'
    ) returning id into v_oc_id;

    -- O despacho que chegou enquanto ela estava oculta saiu sem ninguém; esta volta a
    -- oferecê-la a quem ainda não recebeu (despacho é único por vaga e profissional).
    if v_vaga.estado = 'publicada' and v_vaga.inicio_em > v_agora then
      perform pgmq.send('despacho', jsonb_build_object(
        'vaga_id', v_vaga_id,
        'motivo',  'reexibicao'));
    end if;

    return jsonb_build_object(
      'vaga_id',       v_vaga_id,
      'estado_atual',  v_vaga.estado,
      'oculta',        false,
      'ocorrencia_id', v_oc_id,
      'acao',          'reexibir',
      'moderado_em',   v_agora
    );
  end if;
end $$;

comment on function privado.operacao_moderar_conteudo(uuid, text, text, uuid) is
  'Modera conteúdo denunciado em até 24h (Diretriz 1.2 da App Store). Ocultar tira a vaga da vitrine, do detalhe, da candidatura e do despacho sem cancelá-la (privado.vaga_ocultada) e fecha denúncias pendentes associadas. Reexibir restaura a vitrine. Restrito a service_role.';

revoke execute on function privado.operacao_moderar_conteudo(uuid, text, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_moderar_conteudo(uuid, text, text, uuid) to service_role;


-- ── 3. operacao_moderar_texto: fecha denúncias abertas da vaga ─────────────────

create or replace function privado.operacao_moderar_texto(
  vaga_id     uuid,
  acao        text,
  motivo      text,
  operador_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_vaga_id  uuid := operacao_moderar_texto.vaga_id;
  v_acao     text := pg_catalog.btrim(operacao_moderar_texto.acao);
  v_motivo   text := pg_catalog.btrim(operacao_moderar_texto.motivo);
  v_operador uuid := operacao_moderar_texto.operador_id;
  v_vaga     public.vaga%rowtype;
  v_guardado privado.texto_da_vaga_ocultado%rowtype;
  v_agora    timestamptz := privado.agora();
  v_oc_id    uuid;
begin
  if v_vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;
  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  select * into v_vaga from public.vaga g where g.id = v_vaga_id for update;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_vaga.publicado_por);

  if v_acao is null or v_acao not in ('ocultar', 'reexibir') then
    perform public.erro(422, 'campo_invalido', 'acao');
  end if;

  if v_acao = 'ocultar' then
    -- Reenvio: devolve o que já foi feito, sem gravar uma segunda ocorrência.
    if privado.texto_da_vaga_oculto(v_vaga_id) then
      return jsonb_build_object(
        'vaga_id',              v_vaga_id,
        'texto_oculto',        true,
        'ja_estava_oculto',    true);
    end if;

    insert into public.ocorrencia (
      tipo, usuario_id, estabelecimento_id, autor_id, motivo, criada_em, resolvido_em, resultado
    ) values (
      'suporte',
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_operador,
      'Moderação Diretriz 1.2 (texto): ' || v_motivo,
      v_agora,
      v_agora,
      'Texto livre da vaga ocultado em até 24h pela Equipe Frila; a vaga segue no ar.'
    ) returning id into v_oc_id;

    insert into privado.texto_da_vaga_ocultado
      (vaga_id, ocorrencia_id, oculto_em, responsavel_local, traje, observacoes)
    values
      (v_vaga_id, v_oc_id, v_agora, v_vaga.responsavel_local, v_vaga.traje, v_vaga.observacoes);

    -- O texto sai da linha. `responsavel_local` é not null e recebe o marcador neutro,
    -- como a retenção faz com o motivo da ocorrência.
    update public.vaga g
       set responsavel_local = '[removido pela moderação]',
           traje             = null,
           observacoes       = null
     where g.id = v_vaga_id;

    -- Fecha denúncias abertas associadas à vaga (Diretriz 1.2, Item 21c)
    update public.ocorrencia o
       set resolvido_em = v_agora,
           resultado    = coalesce(o.resultado, 'Texto ofensivo moderado em até 24h pela Equipe Frila (Diretriz 1.2).')
     where o.tipo = 'denuncia'
       and o.resolvido_em is null
       and (
         exists (
           select 1 from public.turno t
             join public.posicao p on p.id = t.posicao_id
            where p.vaga_id = v_vaga_id
              and t.id = o.turno_id
         )
         or (
           o.estabelecimento_id is not null
           and o.estabelecimento_id = v_vaga.estabelecimento_id
         )
       );

    return jsonb_build_object(
      'vaga_id',       v_vaga_id,
      'texto_oculto',  true,
      'ocorrencia_id', v_oc_id,
      'acao',          'ocultar',
      'moderado_em',   v_agora
    );
  else
    -- reexibir
    select * into v_guardado
      from privado.texto_da_vaga_ocultado o
     where o.vaga_id = v_vaga_id;

    if not found then
      perform public.erro(422, 'campo_invalido', 'texto_nao_ocultado');
    end if;

    delete from privado.texto_da_vaga_ocultado where vaga_id = v_vaga_id;

    update public.vaga g
       set responsavel_local = v_guardado.responsavel_local,
           traje             = v_guardado.traje,
           observacoes       = v_guardado.observacoes
     where g.id = v_vaga_id;

    insert into public.ocorrencia (
      tipo, usuario_id, estabelecimento_id, autor_id, motivo, criada_em, resolvido_em, resultado
    ) values (
      'suporte',
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_operador,
      'Moderação Reexibir (texto): ' || v_motivo,
      v_agora,
      v_agora,
      'Texto livre da vaga reexibido pela Equipe Frila após análise.'
    ) returning id into v_oc_id;

    return jsonb_build_object(
      'vaga_id',       v_vaga_id,
      'texto_oculto',  false,
      'ocorrencia_id', v_oc_id,
      'acao',          'reexibir',
      'moderado_em',   v_agora
    );
  end if;
end $$;

comment on function privado.operacao_moderar_texto(uuid, text, text, uuid) is
  'Oculta ou restaura o texto livre da vaga (responsavel_local, traje, observacoes) preservando o original em privado.texto_da_vaga_ocultado e fechando denúncias pendentes associadas. Restrito a service_role.';

revoke execute on function privado.operacao_moderar_texto(uuid, text, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_moderar_texto(uuid, text, text, uuid) to service_role;


-- ── 4. operacao_reativar_conta: fecha contestações abertas do usuário ───────────

create or replace function privado.operacao_reativar_conta(
  usuario_id    uuid,
  justificativa text,
  operador_id   uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid      uuid := operacao_reativar_conta.usuario_id;
  v_just     text := pg_catalog.btrim(operacao_reativar_conta.justificativa);
  v_operador uuid := operacao_reativar_conta.operador_id;
  v_usuario  public.usuario%rowtype;
  v_agora    timestamptz := privado.agora();
  v_oc_id    uuid;
begin
  if v_uid is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if v_just is null or v_just = '' then
    perform public.erro(422, 'campo_obrigatorio', 'justificativa');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_uid);

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_usuario.estado = 'anonimizada' then
    perform public.erro(409, 'conta_ja_anonimizada');
  end if;

  if v_usuario.estado = 'ativa' then
    return jsonb_build_object(
      'usuario_id',      v_uid,
      'estado_anterior', 'ativa',
      'estado_atual',    'ativa',
      'ja_estava_ativa', true
    );
  end if;

  update public.usuario
     set estado = 'ativa'
   where id = v_uid;

  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    criada_em,
    resolvido_em,
    resultado
  ) values (
    'suporte',
    v_uid,
    v_operador,
    'Reativação de conta: ' || v_just,
    v_agora,
    v_agora,
    'Conta reativada pela Equipe Frila via procedimento operacional.'
  ) returning id into v_oc_id;

  -- RN15 / Card BsXIZHOw: notificação sem motivo no push
  perform privado.notificar(
    v_uid,
    'reativacao'::public.tipo_notificacao,
    v_oc_id,
    '{}'::jsonb
  );

  -- Fecha contestações abertas do usuário (Item 21b)
  update public.ocorrencia o
     set resolvido_em = v_agora,
         resultado    = coalesce(o.resultado, 'Conta reativada pela Equipe Frila via procedimento operacional.')
   where o.usuario_id = v_uid
     and o.tipo = 'contestacao'
     and o.resolvido_em is null;

  return jsonb_build_object(
    'usuario_id',      v_uid,
    'estado_anterior', 'suspensa',
    'estado_atual',    'ativa',
    'ocorrencia_id',   v_oc_id,
    'reativado_em',    v_agora
  );
end $$;

comment on function privado.operacao_reativar_conta(uuid, text, uuid) is
  'Reativa conta suspensa com registro de ocorrência assinada pelo operador da Equipe Frila, notificação push sem motivo e fechamento de contestações pendentes. Restrito a service_role.';

revoke execute on function privado.operacao_reativar_conta(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_reativar_conta(uuid, text, uuid) to service_role;


-- ── 5. contestar_suspensao: teto de 5000 caracteres no relato (Item 21b) ───────

-- contrato: corpo-sem-mudanca-de-superficie public.contestar_suspensao 0.2.44
create or replace function public.contestar_suspensao(relato text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid      uuid := (select auth.uid());
  v_usuario  public.usuario%rowtype;
  v_relato   text := pg_catalog.btrim(contestar_suspensao.relato);
  v_agora    timestamptz := privado.agora();
  v_susp     public.ocorrencia%rowtype;
  v_oc       public.ocorrencia%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid;

  if not found or v_usuario.estado = 'anonimizada' then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if v_usuario.estado <> 'suspensa' then
    perform public.erro(422, 'sem_suspensao_ativa');
  end if;

  if v_relato is null or v_relato = '' then
    perform public.erro(422, 'campo_obrigatorio', 'relato');
  end if;

  if pg_catalog.length(v_relato) < 10 or pg_catalog.length(v_relato) > 5000 then
    perform public.erro(422, 'campo_invalido', 'relato');
  end if;

  -- J1=B: relato lido apenas pela Equipe Frila; não filtra por termos bloqueados

  select * into v_susp
    from public.ocorrencia o
   where o.usuario_id = v_uid
     and o.tipo = 'suspensao'
   order by o.criada_em desc
   limit 1;

  if exists (
    select 1
      from public.ocorrencia c
     where c.usuario_id = v_uid
       and c.tipo = 'contestacao'
       and c.criada_em >= coalesce(v_susp.criada_em, '-infinity'::timestamptz)
  ) then
    perform public.erro(409, 'contestacao_ja_aberta');
  end if;

  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    relato,
    criada_em
  ) values (
    'contestacao',
    v_uid,
    v_uid,
    'Contestação de suspensão',
    v_relato,
    v_agora
  ) returning * into v_oc;

  -- Enfileira o aviso de e-mail à Equipe Frila, só com o ID (RN15: sem relato nem dado pessoal na fila)
  perform pgmq.send('email', jsonb_build_object(
    'tipo',          'contestacao',
    'ocorrencia_id', v_oc.id
  ));

  return jsonb_build_object(
    'ocorrencia_id',      v_oc.id,
    'tipo',               'contestacao',
    'criada_em',          v_oc.criada_em,
    'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em)
  );
end $$;

comment on function public.contestar_suspensao(text) is
  'Contestar a suspensão com envio de protocolo à Equipe Frila e prazo de 5 dias úteis (RF24, RN13, UC15). Relato limitado de 10 a 5000 caracteres.';

revoke execute on function public.contestar_suspensao(text) from public, anon;
grant  execute on function public.contestar_suspensao(text) to authenticated;
