-- 20261112220000_lembrete_casa_fim_turno.sql
--
-- Contrato 0.2.77 / RF20, RN15, RN22:
-- Lembretes à casa sobre chegada não confirmada (30 min antes do fim e no fim).
-- Disparados aos membros do estabelecimento (administradores e operadores)
-- quando há vaga com chegada registrada e presença ainda pendente de confirmação.
--
-- 1. lembrete_30min_fim_turno: 30 minutos antes do término (janela [fim_em - 30 min, fim_em)).
--    "Ainda há chegada sem confirmar nesta vaga. O turno termina em 30 minutos."
-- 2. lembrete_fim_turno: no término do turno (janela curta [fim_em, fim_em + 1 h)).
--    "O turno terminou e ainda há chegada sem confirmar. Você tem até 24 horas."
--
-- Enviados uma única vez por vaga e membro (referencia_id = vaga_id, payload com vaga_id).
-- Não saem sem check-in registrado, com presença já verificada, turno já nao_verificado,
-- ou com vaga ou posição cancelada.

-- ── 1. Adiciona os tipos ao enum public.tipo_notificacao ─────────────────────

alter type public.tipo_notificacao add value if not exists 'lembrete_30min_fim_turno';
alter type public.tipo_notificacao add value if not exists 'lembrete_fim_turno';

comment on type public.tipo_notificacao is
  'Tipos de notificações do sistema (0.2.77). Inclui lembretes à casa sobre chegada não confirmada (lembrete_30min_fim_turno e lembrete_fim_turno) (RN15, RN22, RF20).';

-- ── 2. Atualiza trigger para capturar novos tipos em privado.marca_notificacao ─

create or replace function privado.gravar_marca_notificacao()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if NEW.tipo::text in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                        'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                        'vaga', 'turno_nao_verificado', 'lembrete_30min_fim_turno', 'lembrete_fim_turno') then
    insert into privado.marca_notificacao (tipo, referencia_id, usuario_id, rodada, criada_em)
    values (NEW.tipo, NEW.referencia_id, NEW.usuario_id, coalesce(NEW.rodada, 1), coalesce(NEW.enviada_em, privado.agora()))
    on conflict (tipo, referencia_id, usuario_id, rodada) do nothing;
  end if;
  return NEW;
end $$;

-- ── 3. Atualiza privado.notificar() com os novos tipos na marca atômica ──────

create or replace function privado.notificar(
  p_usuario     uuid,
  p_tipo        public.tipo_notificacao,
  p_referencia  uuid,
  p_payload     jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id            uuid;
  v_prof          uuid;
  v_par           record;
  v_rodada        integer := 1;
  v_marca_criada  integer;
begin
  -- RN15: o payload é estrutura, não texto livre.
  for v_par in select key, value from jsonb_each(coalesce(p_payload, '{}'::jsonb)) loop
    if not (
      (v_par.key = 'reaberta' and jsonb_typeof(v_par.value) = 'boolean')
      or (v_par.key in ('vaga_id', 'posicao_id', 'turno_id', 'estabelecimento_id', 'chamada_id', 'midia_id')
          and jsonb_typeof(v_par.value) = 'string'
          and (v_par.value #>> '{}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    ) then
      raise exception 'payload_invalido' using errcode = '22023', detail = v_par.key;
    end if;
  end loop;

  if p_tipo in ('vaga', 'vagas_agrupadas') then
    select p.id into v_prof from public.profissional p where p.usuario_id = p_usuario;
  end if;

  if p_tipo = 'vaga' then
    select g.rodada_despacho into v_rodada from public.vaga g where g.id = p_referencia;
    v_rodada := coalesce(v_rodada, 1);
  end if;

  if p_tipo::text in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                      'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                      'vaga', 'turno_nao_verificado', 'lembrete_30min_fim_turno', 'lembrete_fim_turno') then
    insert into privado.marca_notificacao (tipo, referencia_id, usuario_id, rodada, criada_em)
    values (p_tipo, p_referencia, p_usuario, v_rodada, privado.agora())
    on conflict (tipo, referencia_id, usuario_id, rodada) do nothing
    returning 1 into v_marca_criada;

    if v_marca_criada is null then
      select n.id into v_id
        from public.notificacao n
       where n.tipo = p_tipo
         and n.referencia_id = p_referencia
         and n.usuario_id = p_usuario
         and n.rodada = v_rodada;

      return v_id;
    end if;
  end if;

  insert into public.notificacao (usuario_id, profissional_id, tipo, referencia_id, payload,
                                  enviada_em, rodada)
  values (p_usuario, v_prof, p_tipo, p_referencia,
          coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('tipo', p_tipo),
          privado.agora(), v_rodada)
  on conflict (tipo, referencia_id, usuario_id, rodada)
    where tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                   'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                   'vaga')
    do nothing
  returning id into v_id;

  if v_id is null then
    select n.id into v_id from public.notificacao n
     where n.tipo = p_tipo and n.referencia_id = p_referencia and n.usuario_id = p_usuario
       and n.rodada = v_rodada;
  end if;

  return v_id;
end $$;

comment on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb) is
  'Envia ou atualiza uma notificação ao usuário com payload estruturado (RN15). Inclui marca atômica para lembrete_30min_fim_turno e lembrete_fim_turno (0.2.77).';

revoke execute on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb) from public, anon, authenticated;
grant  execute on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb) to service_role;

-- ── 4. Atualiza privado.fechar_turnos_passados() com os dois lembretes ─────────

create or replace function privado.fechar_turnos_passados()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora    timestamptz := privado.agora();
  v_prazo    interval := privado.prazo_da_confirmacao_tardia();
  v_profs    uuid[] := '{}'::uuid[];
  v_novos    uuid[];
  v_prof     uuid;
  v_afetados integer := 0;
  v_rec      record;
begin
  -- Serialização atômica para evitar corridas entre execuções concorrentes (cron vs invocador operacional)
  perform pg_advisory_xact_lock(hashtext('privado.fechar_turnos_passados'));

  perform set_config('frila.em_lote', 'true', true);

  -- 1. Check-in manual não confirmado até o fim do turno + prazo vira nao_verificado (Critério 1, confirmação tardia 24h).
  with turnos_a_fechar as (
    select t.id as turno_id, p.profissional_id, v.estabelecimento_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v on v.id = p.vaga_id
     where p.fim_em + v_prazo <= v_agora
       and t.verificacao = 'pendente'
       and t.checkin_tipo = 'manual'
  ),
  atualizados as (
    update public.turno t
       set verificacao = 'nao_verificado'
      from turnos_a_fechar taf
     where t.id = taf.turno_id
    returning taf.turno_id, taf.profissional_id, taf.estabelecimento_id
  )
  select coalesce(
     array_agg(distinct profissional_id) filter (where profissional_id is not null),
     '{}'::uuid[]
  )
     into v_novos
     from atualizados;
  v_profs := v_profs || v_novos;
  v_afetados := v_afetados + cardinality(v_novos);

  -- Dispara notificação turno_nao_verificado aos dois lados para check-in manual expirado após o prazo (0.2.62, RN15, RN22)
  for v_rec in
    select t.id as turno_id, p.profissional_id, v.estabelecimento_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v on v.id = p.vaga_id
     where p.fim_em + v_prazo <= v_agora
       and p.fim_em + v_prazo >= v_agora - interval '7 days'
       and t.verificacao = 'nao_verificado'
       and t.checkin_tipo = 'manual'
       and not exists (
         select 1 from public.notificacao n
          where n.tipo = 'turno_nao_verificado'
            and n.referencia_id = t.id
       )
     for update of t skip locked
  loop
    if v_rec.profissional_id is not null then
      perform privado.notificar(
        privado.usuario_do_profissional(v_rec.profissional_id),
        'turno_nao_verificado',
        v_rec.turno_id,
        jsonb_build_object('turno_id', v_rec.turno_id)
      );
    end if;
    if v_rec.estabelecimento_id is not null then
      perform privado.notificar_membros(
        v_rec.estabelecimento_id,
        'turno_nao_verificado',
        v_rec.turno_id,
        jsonb_build_object('turno_id', v_rec.turno_id)
      );
    end if;
  end loop;

  -- 2. Transição de posição: confirmada -> cumprida quando o turno terminou e teve check-in registrado
  with posicoes_a_fechar as (
    select p.id, p.profissional_id
      from public.posicao p
      join public.turno t on t.posicao_id = p.id
     where p.estado = 'confirmada'
       and p.fim_em <= v_agora
       and t.checkin_em is not null
  ),
  pos_atualizadas as (
    update public.posicao p
       set estado = 'cumprida'
      from posicoes_a_fechar paf
     where p.id = paf.id
    returning paf.profissional_id
  )
  select coalesce(
     array_agg(distinct profissional_id) filter (where profissional_id is not null),
     '{}'::uuid[]
  )
     into v_novos
     from pos_atualizadas;
  v_profs := v_profs || v_novos;
  v_afetados := v_afetados + cardinality(v_novos);

  -- 3. Critério 2 (Decisão 8zLfn0mt Opção 2): Turno confirmado sem check-in até o fim vira cancelamento por no-show com falta
  with noshow_a_cancelar as (
    select p.id as posicao_id, p.profissional_id, t.id as turno_id, v.estabelecimento_id
      from public.posicao p
      join public.vaga v on v.id = p.vaga_id
      left join public.turno t on t.posicao_id = p.id
     where p.estado = 'confirmada'
       and p.fim_em <= v_agora
       and (t.checkin_em is null or t.id is null)
  ),
  canceladas as (
    update public.posicao p
       set estado = 'cancelada',
           falta  = true
      from noshow_a_cancelar n
     where p.id = n.posicao_id
    returning n.posicao_id, n.profissional_id, n.turno_id, n.estabelecimento_id
  ),
  turnos_cancelados as (
    update public.turno t
       set verificacao = 'nao_verificado'
      from canceladas c
     where t.posicao_id = c.posicao_id
       and t.verificacao = 'pendente'
  ),
  ocorrencias_gravadas as (
    insert into public.ocorrencia (tipo, posicao_id, turno_id, usuario_id, autor_id, motivo)
    select 'cancelamento',
           c.posicao_id,
           c.turno_id,
           privado.usuario_do_profissional(c.profissional_id),
           privado.usuario_do_profissional(c.profissional_id),
           'no_show_sem_checkin'
      from canceladas c
     where c.profissional_id is not null
  )
  select coalesce(
     array_agg(distinct profissional_id) filter (where profissional_id is not null),
     '{}'::uuid[]
  )
     into v_novos
     from canceladas;
  v_profs := v_profs || v_novos;
  v_afetados := v_afetados + cardinality(v_novos);

  -- Dispara notificação turno_nao_verificado aos dois lados para no-show sem check-in (0.2.62, RN15, RN22)
  for v_rec in
    select coalesce(t.id, p.id) as ref_id,
           t.id as turno_id,
           p.id as posicao_id,
           p.profissional_id,
           v.estabelecimento_id
      from public.posicao p
      join public.vaga v on v.id = p.vaga_id
      left join public.turno t on t.posicao_id = p.id
     where p.estado = 'cancelada'
       and p.falta = true
       and p.fim_em <= v_agora
       and p.fim_em >= v_agora - interval '7 days'
       and exists (
         select 1 from public.ocorrencia o
          where o.posicao_id = p.id
            and o.tipo = 'cancelamento'
            and o.motivo = 'no_show_sem_checkin'
       )
       and not exists (
         select 1 from public.notificacao n
          where n.tipo = 'turno_nao_verificado'
            and (n.referencia_id = t.id or n.referencia_id = p.id)
       )
     for update of p skip locked
  loop
    declare
      v_payload jsonb := case
        when v_rec.turno_id is not null then jsonb_build_object('turno_id', v_rec.turno_id)
        else jsonb_build_object('posicao_id', v_rec.posicao_id)
      end;
    begin
      if v_rec.profissional_id is not null then
        perform privado.notificar(
          privado.usuario_do_profissional(v_rec.profissional_id),
          'turno_nao_verificado',
          v_rec.ref_id,
          v_payload
        );
      end if;
      if v_rec.estabelecimento_id is not null then
        perform privado.notificar_membros(
          v_rec.estabelecimento_id,
          'turno_nao_verificado',
          v_rec.ref_id,
          v_payload
        );
      end if;
    end;
  end loop;

  -- 4. Lembrete à casa 30 minutos antes do fim: 1 por vaga com chegada pendente (0.2.77, RF20, RN15, RN22)
  for v_rec in
    select v.id as vaga_id, v.estabelecimento_id
      from public.vaga v
     where v.estado <> 'cancelada'
       and exists (
         select 1
           from public.posicao p
           join public.turno t on t.posicao_id = p.id
          where p.vaga_id = v.id
            and p.estado in ('confirmada', 'cumprida')
            and t.checkin_em is not null
            and t.verificacao = 'pendente'
            and p.fim_em - interval '30 minutes' <= v_agora
            and v_agora < p.fim_em
       )
       and not exists (
         select 1 from public.notificacao n
          where n.tipo = 'lembrete_30min_fim_turno'
            and n.referencia_id = v.id
       )
     for update of v skip locked
  loop
    if v_rec.estabelecimento_id is not null then
      perform privado.notificar_membros(
        v_rec.estabelecimento_id,
        'lembrete_30min_fim_turno',
        v_rec.vaga_id,
        jsonb_build_object('vaga_id', v_rec.vaga_id)
      );
    end if;
  end loop;

  -- 5. Lembrete à casa no fim do turno: 1 por vaga com chegada pendente (0.2.77, janela curta [fim, fim + 1h))
  for v_rec in
    select v.id as vaga_id, v.estabelecimento_id
      from public.vaga v
     where v.estado <> 'cancelada'
       and exists (
         select 1
           from public.posicao p
           join public.turno t on t.posicao_id = p.id
          where p.vaga_id = v.id
            and p.estado in ('confirmada', 'cumprida')
            and t.checkin_em is not null
            and t.verificacao = 'pendente'
            and p.fim_em <= v_agora
            and v_agora < p.fim_em + interval '1 hour'
       )
       and not exists (
         select 1 from public.notificacao n
          where n.tipo = 'lembrete_fim_turno'
            and n.referencia_id = v.id
       )
     for update of v skip locked
  loop
    if v_rec.estabelecimento_id is not null then
      perform privado.notificar_membros(
        v_rec.estabelecimento_id,
        'lembrete_fim_turno',
        v_rec.vaga_id,
        jsonb_build_object('vaga_id', v_rec.vaga_id)
      );
    end if;
  end loop;

  -- 6. Recalcula o histórico canônico UMA VEZ por profissional afetado no lote
  for v_prof in select distinct unnest(v_profs)
  loop
     perform privado.recalcular_comparecimento(v_prof);
  end loop;

  perform set_config('frila.em_lote', '', true);

  return v_afetados;
end $$;

comment on function privado.fechar_turnos_passados() is
  'Job pós-fim de turno: fecha check-ins manuais não confirmados como nao_verificado após o fim_em + 24 horas (confirmação tardia), cumpre turnos com presença, cancela turnos confirmados sem check-in por no-show (falta = true), emite lembretes de chegada pendente à casa em [fim - 30m, fim) e [fim, fim + 1h) (0.2.77) e recalcula comparecimento.';

revoke execute on function privado.fechar_turnos_passados() from public, anon, authenticated;
grant execute on function privado.fechar_turnos_passados() to service_role;
