-- S2 · Backend · Alerta de vaga vazia na janela crítica (RF20, UC07, D4/B18)
-- Cartão: https://trello.com/c/vUR0Ltkb
--
-- Com a posição ainda vaga na antecedência escolhida na publicação (padrão 3 h), a casa
-- recebe um alerta. O Frila não intervém: quem decide o que fazer é o contratante.
--
-- O painel já mostrava o alerta, calculado na leitura (`alerta_vaga_vazia`). Aqui ele
-- vira push: um agendador a cada cinco minutos enfileira `vaga_vazia` na fila de
-- `notificacao`, e o envio pelo FCM é o da `enviar-push`, que monta o texto na hora.
--
-- A referência do aviso é a **posição**, não a vaga: o critério é um alerta por posição,
-- e a marca de envio (`notificacao_marca_de_envio`, tipo + referência + conta) é o que
-- faz a segunda rodada do agendador não ser um segundo push.

-- ── O agendador ──────────────────────────────────────────────────────────────

create or replace function privado.alertar_vagas_vazias()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora timestamptz := privado.agora();
  v_pos   record;
  v_n     integer := 0;
begin
  -- A janela vai de `inicio_em - alerta_antecedencia` até o início, a mesma regra do
  -- painel. Depois do início ninguém mais se candidata, e o alerta não tem o que pedir.
  --
  -- A vaga precisa estar publicada: a cancelada pode deixar posição marcada como
  -- aberta, e a preenchida não tem posição aberta. Não importa se o despacho achou
  -- elegível: a vaga sem elegíveis é justamente a que mais precisa do alerta (US07,
  -- cenário 4), e `vaga_sem_elegiveis` é outro aviso, do motor de despacho.
  --
  -- O `not exists` poupa o trabalho de reenfileirar o que já saiu. Quem garante que não
  -- há duplicata é a marca de envio, dentro de `privado.notificar`: por isso uma rodada
  -- do pg_cron que se sobreponha a outra também não duplica.
  for v_pos in
    select p.id as posicao_id, g.id as vaga_id, g.estabelecimento_id
      from public.vaga g
      join public.posicao p on p.vaga_id = g.id
     where g.estado = 'publicada'
       and g.inicio_em > v_agora
       and g.inicio_em - g.alerta_antecedencia <= v_agora
       and p.estado = 'aberta'
       and not exists (select 1 from public.notificacao n
                        where n.tipo = 'vaga_vazia' and n.referencia_id = p.id)
     order by g.inicio_em, p.id
  loop
    perform privado.notificar_membros(
      v_pos.estabelecimento_id, 'vaga_vazia', v_pos.posicao_id,
      jsonb_build_object('vaga_id', v_pos.vaga_id, 'posicao_id', v_pos.posicao_id));
    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

comment on function privado.alertar_vagas_vazias() is
  'Agendador do alerta de vaga vazia (RF20): para cada posição aberta de vaga publicada que já entrou na janela crítica (início menos a antecedência escolhida na publicação) e ainda não começou, enfileira `vaga_vazia` para cada membro da casa, uma vez por posição. Devolve quantas posições foram alertadas. Rodado a cada cinco minutos pelo pg_cron.';

revoke execute on function privado.alertar_vagas_vazias() from public, anon, authenticated;
grant  execute on function privado.alertar_vagas_vazias() to service_role;

-- ── O alerta enfileirado deixa de valer ──────────────────────────────────────
--
-- `notificacao_expirada` é a pergunta que a `enviar-push` faz antes de mandar. Ela lia a
-- referência do `vaga_vazia` como vaga; aqui a referência é a posição, e sem esta troca
-- o alerta nunca expiraria. E há um segundo motivo, próprio deste aviso: a posição
-- preenchida entre o enfileiramento e o envio faria o push dizer "ainda não foi
-- preenchida" sobre uma posição preenchida.
create or replace function privado.notificacao_expirada(p_notificacao_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notif  public.notificacao%rowtype;
  v_inicio timestamptz;
  v_agora  timestamptz := privado.agora();
begin
  select * into v_notif from public.notificacao where id = p_notificacao_id;
  if not found then
    return true;
  end if;

  if v_notif.tipo = 'vaga_vazia' then
    select g.inicio_em into v_inicio
      from public.posicao p
      join public.vaga g on g.id = p.vaga_id
     where p.id = v_notif.referencia_id;

    if exists (select 1 from public.posicao p
                where p.id = v_notif.referencia_id and p.estado <> 'aberta') then
      return true;
    end if;

    -- Linha antiga, de antes deste cartão, com a vaga como referência.
    if v_inicio is null then
      select g.inicio_em into v_inicio from public.vaga g where g.id = v_notif.referencia_id;
    end if;
  elsif v_notif.tipo in ('vaga', 'vagas_agrupadas', 'vaga_sem_elegiveis') then
    select g.inicio_em into v_inicio from public.vaga g where g.id = v_notif.referencia_id;
  elsif v_notif.tipo in ('confirmacao', 'cancelamento') then
    select g.inicio_em into v_inicio
      from public.posicao p
      join public.vaga g on g.id = p.vaga_id
     where p.id = v_notif.referencia_id;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.turno t
        join public.posicao p on p.id = t.posicao_id
        join public.vaga g on g.id = p.vaga_id
       where t.id = v_notif.referencia_id;
    end if;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.vaga g
       where g.id = v_notif.referencia_id;
    end if;
  elsif v_notif.tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin',
                         'atraso_15min', 'fim_sem_checkout', 'checkin',
                         'checkin_manual_pendente') then
    select g.inicio_em into v_inicio
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga g on g.id = p.vaga_id
     where t.id = v_notif.referencia_id;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.posicao p
        join public.vaga g on g.id = p.vaga_id
       where p.id = v_notif.referencia_id;
    end if;
  end if;

  if v_inicio is not null and v_inicio <= v_agora then
    return true;
  end if;

  return false;
end $$;

comment on function privado.notificacao_expirada(uuid) is
  'Verifica se o início do turno ou da vaga associada à notificação já passou, impedindo reenvio após o início. O `vaga_vazia` tem a posição como referência e expira também quando a posição deixa de estar aberta.';

revoke execute on function privado.notificacao_expirada(uuid) from public, anon, authenticated;
grant  execute on function privado.notificacao_expirada(uuid) to service_role;

-- ── A cada cinco minutos ─────────────────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('alertar_vagas_vazias')
      where exists (select 1 from cron.job where jobname = 'alertar_vagas_vazias');
    perform cron.schedule(
      'alertar_vagas_vazias',
      '*/5 * * * *',
      'select privado.alertar_vagas_vazias()'
    );
  end if;
end $$;
