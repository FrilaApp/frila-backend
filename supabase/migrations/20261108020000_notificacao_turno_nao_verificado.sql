-- 20261108020000_notificacao_turno_nao_verificado.sql
--
-- Contrato 0.2.62 / RN15, RN22:
-- Aviso de turno não verificado aos dois lados (turno_nao_verificado).
-- Disparado pelo encerramento de turno sem presença verificada:
-- 1) Check-in manual pendente sem confirmação até o fim do turno.
-- 2) Turno confirmado sem check-in até o fim (cancelamento por no-show).
--
-- Título: "Turno não verificado"
-- Corpo:  "A presença no turno não foi confirmada dentro do prazo. O turno foi encerrado como não verificado."

-- ── 1. Adiciona o tipo turno_nao_verificado ao enum public.tipo_notificacao ─────

alter type public.tipo_notificacao add value if not exists 'turno_nao_verificado';

comment on type public.tipo_notificacao is
  'Tipos de notificações do sistema (0.2.62). Inclui aviso de turno não verificado (turno_nao_verificado) aos dois lados (RN15, RN22).';

-- ── 2. Atualiza privado.notificar() para incluir turno_nao_verificado na marca atômica ──

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

  if p_tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                'vaga', 'turno_nao_verificado') then
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
  'Envia ou atualiza uma notificação ao usuário com payload estruturado (RN15). Inclui marca atômica para turno_nao_verificado (0.2.62).';

revoke execute on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb) from public, anon, authenticated;
grant  execute on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb) to service_role;

-- ── 3. Atualiza privado.fechar_turnos_passados() para emitir turno_nao_verificado ──

create or replace function privado.fechar_turnos_passados()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora    timestamptz := privado.agora();
  v_profs    uuid[] := '{}'::uuid[];
  v_novos    uuid[];
  v_prof     uuid;
  v_afetados integer := 0;
  v_rec      record;
begin
  perform set_config('frila.em_lote', 'true', true);

  -- 1. Check-in manual não confirmado até o fim do turno vira nao_verificado (Critério 1).
  with turnos_a_fechar as (
    select t.id as turno_id, p.profissional_id, v.estabelecimento_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v on v.id = p.vaga_id
     where p.fim_em <= v_agora
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

  -- Dispara notificação turno_nao_verificado aos dois lados para check-in manual expirado (0.2.62, RN15, RN22)
  -- Trava atômica com FOR UPDATE OF t SKIP LOCKED garante que execuções concorrentes não processem o mesmo turno
  for v_rec in
    select t.id as turno_id, p.profissional_id, v.estabelecimento_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v on v.id = p.vaga_id
     where p.fim_em <= v_agora
       and p.fim_em >= v_agora - interval '7 days'
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
  -- Trava atômica com FOR UPDATE OF p SKIP LOCKED garante que execuções concorrentes não processem a mesma posição
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

  -- 4. Recalcula o histórico canônico UMA VEZ por profissional afetado no lote
  for v_prof in select distinct unnest(v_profs)
  loop
     perform privado.recalcular_comparecimento(v_prof);
  end loop;

  perform set_config('frila.em_lote', '', true);

  return v_afetados;
end $$;

comment on function privado.fechar_turnos_passados() is
  'Job pós-fim de turno: fecha check-ins manuais não confirmados como nao_verificado, cumpre turnos com presença e cancela turnos confirmados sem check-in por no-show (falta = true). Dispara turno_nao_verificado aos dois lados com trava atômica (0.2.62, RN15, RN22) e recalcula comparecimento.';

revoke execute on function privado.fechar_turnos_passados() from public, anon, authenticated;
grant execute on function privado.fechar_turnos_passados() to service_role;
