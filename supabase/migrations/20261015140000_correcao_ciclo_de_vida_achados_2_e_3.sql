-- 20261015140000_correcao_ciclo_de_vida_achados_2_e_3.sql
--
-- Correções preventivas do ciclo de vida (Achados 2 e 3 da caçada):
--
-- 1. Achado 2: O laço de envio de avaliacao_disponivel em privado.fechar_turnos_e_vagas()
--    varria todos os turnos cumpridos da história do banco a cada 5 minutos sem filtro
--    de janela retroativa e sem conferir se a notificação já fora emitida.
--    Adiciona not exists na tabela public.notificacao e janela retroativa de 7 dias.
--
-- 2. Achado 3: A rotina de monitoramento operacional privado.verificar_saude() alertava
--    despachos com notificacao_id nulo após 45 minutos mesmo se a vaga já estivesse
--    cancelada, encerrada ou com início ultrapassado (onde o agendador deliberadamente
--    descarta o envio para não notificar vaga inativa).
--    Filtra a contagem por vaga publicada no futuro (v.estado = 'publicada' and v.inicio_em > v_agora).

-- ── 1. privado.fechar_turnos_e_vagas() ──────────────────────────────────────────

create or replace function privado.fechar_turnos_e_vagas()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora    timestamptz := privado.agora();
  v_fechados integer := 0;
  v_posicoes integer := 0;
  v_turno    record;
begin
  -- Reutiliza o fechamento de turnos manuais e a atualização dos contadores.
  v_fechados := privado.fechar_turnos_passados();

  -- A posição cumprida é o registro do turno encerrado; a verificação é atributo
  -- do turno e não impede o fechamento da posição.
  update public.posicao p
     set estado = 'cumprida'
   where p.estado = 'confirmada'
     and p.fim_em <= v_agora;
  get diagnostics v_posicoes = row_count;
  v_fechados := v_fechados + v_posicoes;

  -- Só a presença verificada abre avaliação. A chave (tipo, referência, conta)
  -- dentro de privado.notificar torna a execução idempotente.
  -- Achado 2: filtra por not exists para turnos que já receberam avaliacao_disponivel,
  -- além de janela retroativa de 7 dias, eliminando a varredura O(N) de todo o histórico.
  for v_turno in
    select t.id as turno_id,
           p.profissional_id,
           v.estabelecimento_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v on v.id = p.vaga_id
     where p.estado = 'cumprida'
       and p.fim_em <= v_agora
       and p.fim_em >= v_agora - interval '7 days'
       and t.verificacao = 'verificado'
       and not exists (
         select 1
           from public.notificacao n
          where n.tipo = 'avaliacao_disponivel'
            and n.referencia_id = t.id
       )
  loop
    perform privado.notificar(
      privado.usuario_do_profissional(v_turno.profissional_id),
      'avaliacao_disponivel',
      v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id));

    perform privado.notificar_membros(
      v_turno.estabelecimento_id,
      'avaliacao_disponivel',
      v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id));
  end loop;

  -- Cancela posições abertas cujo turno terminou sem confirmação.
  -- Sem isto, posições não preenchidas ficavam como 'aberta' indefinidamente,
  -- impedindo o encerramento da vaga e acumulando registros no índice GiST.
  update public.posicao p
     set estado = 'cancelada'
   where p.estado = 'aberta'
     and p.fim_em <= v_agora;

  -- Uma vaga só deixa de aparecer como publicada/preenchida quando não há
  -- posição aberta ou confirmada para ela.
  update public.vaga v
     set estado = 'encerrada'
   where v.estado in ('publicada', 'preenchida')
     and v.fim_em <= v_agora
     and not exists (
       select 1
         from public.posicao p
        where p.vaga_id = v.id
          and p.estado in ('aberta', 'confirmada'));

  return v_fechados;
end $$;

comment on function privado.fechar_turnos_e_vagas() is
  'Job a cada cinco minutos: reutiliza o fechamento de turnos passados, conclui posições confirmadas, cancela posições abertas cujo turno terminou, enfileira avaliacao_disponivel para os dois lados (com not exists para evitar revarredura histórica) e encerra vagas sem posição aberta ou confirmada.';

revoke execute on function privado.fechar_turnos_e_vagas() from public, anon, authenticated;
grant  execute on function privado.fechar_turnos_e_vagas() to service_role;

-- ── 2. privado.verificar_saude() ───────────────────────────────────────────────

create or replace function privado.verificar_saude()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alertas            int := 0;
  v_idade_despacho     interval;
  v_idade_email        interval;
  v_falhas_cron        int;
  v_notif_falhas       int;
  v_despachos_travados int;
  v_falhas_exec        int;
  v_agora              timestamptz := privado.agora();
  v_teto_janela        interval;
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

  -- 5. Despachos esperando além do teto de RN23
  -- Achado 3: vigia apenas despachos cuja vaga continua publicada e no futuro.
  -- Vagas canceladas, encerradas, preenchidas ou iniciadas naturalmente deixam
  -- despachos retidos com notificacao_id nulo para não enviar notificações obsoletas (RN23),
  -- o que não constitui falha operacional nem despacho travado.
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

  return v_alertas;
end $$;

comment on function privado.verificar_saude() is
  'Varre filas pgmq, falhas de jobs do pg_cron, notificações com erro e despachos retidos de vagas ativas. Emite alertas à equipe por e-mail com limite de 1/hora por tipo (cartão 5bPJvMIo).';

revoke execute on function privado.verificar_saude() from public, anon, authenticated;
grant  execute on function privado.verificar_saude() to service_role;
