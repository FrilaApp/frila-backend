-- Migração: 20261112100000_confirmacao_tardia_24h.sql
-- Escopo: Confirmação tardia de presença pela casa (até 24 horas após fim_em da posição).
--
-- Decisão do JP (12/11/2026): A casa pode confirmar o check-in manual até 24 horas depois do fim
-- do turno. Nesse período de tolerância o turno segue `pendente`. Passadas as 24 h, o job
-- privado.fechar_turnos_passados marca o turno como `nao_verificado` de vez e a confirmação é
-- recusada com 422 fora_da_janela. A regra vale para todas as casas.
--
-- Alterações atômicas na mesma migração para evitar janela de inconsistência entre função e job:
--   1. privado.prazo_da_confirmacao_tardia(): centraliza o prazo (interval '24 hours').
--   2. public.confirmar_checkin_manual(uuid): aceita enquanto agora <= fim_em + prazo e não nao_verificado.
--   3. privado.fechar_turnos_passados(): só fecha check-in manual pendente após fim_em + prazo.
--   4. public.painel_estabelecimento: checkins_pendentes só lista turnos com verificacao = 'pendente'.
--

-- ── 1. Prazo centralizado da confirmação tardia ─────────────────────────────────

create or replace function privado.prazo_da_confirmacao_tardia()
returns interval
language sql
immutable
security definer
set search_path = ''
as $$
  select interval '24 hours';
$$;

comment on function privado.prazo_da_confirmacao_tardia() is
  'Prazo limite após o fim_em do turno durante o qual a confirmação manual do check-in pela casa é permitida (24 horas).';

revoke execute on function privado.prazo_da_confirmacao_tardia() from public, anon, authenticated;
grant execute on function privado.prazo_da_confirmacao_tardia() to service_role;

-- ── 2. public.confirmar_checkin_manual com tolerância tardia de 24h ─────────────

create or replace function public.confirmar_checkin_manual(turno_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_pos public.posicao%rowtype;
  v_t   public.turno%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if confirmar_checkin_manual.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  select p.* into v_pos
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = confirmar_checkin_manual.turno_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RF20: quem confirma é a casa.
  if not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- A trava do turno (0.2.69).
  select * into v_t from public.turno t where t.id = confirmar_checkin_manual.turno_id for update;

  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  if v_t.checkin_tipo <> 'manual' then
    perform public.erro(409, 'checkin_ja_confirmado');
  end if;

  if v_t.checkin_confirmado_em is not null then
    return jsonb_build_object(
      'turno_id',      v_t.id,
      'tipo',          v_t.checkin_tipo,
      'verificacao',   v_t.verificacao,
      'registrado_em', v_t.checkin_em,
      'distancia_m',   v_t.checkin_distancia_m);
  end if;

  -- Posição cancelada vem antes da trava de prazo (409 vaga_encerrada, posicao_cancelada).
  if v_pos.estado = 'cancelada' then
    perform public.erro(409, 'vaga_encerrada', 'posicao_cancelada');
  end if;

  -- Trava de prazo com tolerância tardia de 24 horas (Decisão JP 12/11/2026).
  if privado.agora() > v_pos.fim_em + privado.prazo_da_confirmacao_tardia() or v_t.verificacao = 'nao_verificado' then
    perform public.erro(422, 'fora_da_janela');
  end if;

  update public.turno t
     set checkin_confirmado_em = privado.agora(),
         verificacao           = 'verificado'
   where t.id = confirmar_checkin_manual.turno_id
  returning * into v_t;

  perform privado.recalcular_comparecimento(v_pos.profissional_id);

  return jsonb_build_object(
    'turno_id',      v_t.id,
    'tipo',          v_t.checkin_tipo,
    'verificacao',   v_t.verificacao,
    'registrado_em', v_t.checkin_em,
    'distancia_m',   v_t.checkin_distancia_m);
end $$;

comment on function public.confirmar_checkin_manual(uuid) is
  'Contratante confirma check-in manual do profissional (RF20). Torna o turno verificado para fins de pagamento e avaliação. Exige conta ativa e confirmação até o fim_em + 24 horas (confirmação tardia). Trava o turno (for update, 0.2.69): o turno já verificado pelo código, mesmo numa corrida com a validação, recusa 409 checkin_ja_confirmado e não muda a hora da validação.';

revoke execute on function public.confirmar_checkin_manual(uuid) from public, anon;
grant  execute on function public.confirmar_checkin_manual(uuid) to authenticated;

-- ── 3. privado.fechar_turnos_passados: fechamento tardio em fim_em + 24h ─────────

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
  -- Trava atômica com FOR UPDATE OF t SKIP LOCKED garante que execuções concorrentes não processem o mesmo turno
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
  'Job pós-fim de turno: fecha check-ins manuais não confirmados como nao_verificado após o fim_em + 24 horas (confirmação tardia), cumpre turnos com presença e cancela turnos confirmados sem check-in por no-show (falta = true). Dispara turno_nao_verificado aos dois lados com trava atômica (0.2.62, RN15, RN22) e recalcula comparecimento.';

revoke execute on function privado.fechar_turnos_passados() from public, anon, authenticated;
grant execute on function privado.fechar_turnos_passados() to service_role;

-- ── 4. public.painel_estabelecimento: checkins_pendentes apenas com verificacao pendente ──

create or replace function public.painel_estabelecimento(
  estabelecimento_id uuid,
  de                 timestamptz,
  ate                timestamptz
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_estab     uuid := painel_estabelecimento.estabelecimento_id;
  v_de        timestamptz := painel_estabelecimento.de;
  v_ate       timestamptz := painel_estabelecimento.ate;
  v_agora     timestamptz;
  v_vagas     jsonb;
  v_pendentes jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'anonimizada') then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if v_estab is null or not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  if v_de is null then
    perform public.erro(422, 'campo_obrigatorio', 'de');
  end if;
  if v_ate is null then
    perform public.erro(422, 'campo_obrigatorio', 'ate');
  end if;

  v_agora := privado.agora();

  select coalesce(jsonb_agg(jsonb_build_object(
           'vaga', jsonb_build_object(
              'id',                    v.id,
              'funcao',                f.nome,
              'local',                 v.local,
              'regiao_administrativa', v.regiao_administrativa,
              'inicio_em',             v.inicio_em,
              'fim_em',                v.fim_em,
              'valor_centavos',        v.valor_centavos),
           'modo',   v.modo,
           'estado', v.estado,
           -- 0.2.41: Quantas posições republicar_posicoes_restantes republicaria agora (ou nulo)
           'republicavel_em_urgencia',
              (select case when r.restantes > 0 and r.motivo is null then r.restantes else null end
                 from privado.republicacao_da_selecao(v.id) r),
           -- A casa vê "oculta pela Equipe"; o estado segue o do ciclo de vida (0.2.23).
           'oculta', privado.vaga_oculta(v.id),
           'alerta_vaga_vazia',
              v.estado = 'publicada'
              and v_agora >= v.inicio_em - v.alerta_antecedencia
              and v_agora <  v.inicio_em
              and exists (select 1 from public.posicao pa
                           where pa.vaga_id = v.id and pa.estado = 'aberta'),
           'candidatos_pendentes',
              (select count(distinct c.profissional_id)
                 from public.candidatura c
                 join public.posicao pc on pc.id = c.posicao_id
                where pc.vaga_id = v.id
                  and c.estado = 'pendente'
                  and not privado.bloqueado_com_estabelecimento(
                            privado.usuario_do_profissional(c.profissional_id), v_estab)),
           'posicoes',
              (select coalesce(jsonb_agg(jsonb_build_object(
                        'id',                    p.id,
                        'estado',                p.estado,
                        'profissional',          case when p.profissional_id is null then null
                                                      else privado.perfil_publico_profissional(p.profissional_id) end,
                        'turno_id',              t.id,
                        'verificacao',           t.verificacao,
                        'em_atraso',             p.estado = 'confirmada'
                                                 and t.checkin_em is null
                                                 and v_agora >= p.inicio_em + interval '15 minutes'
                                                 and v_agora <  p.fim_em,
                        'a_caminho_em',          t.a_caminho_em,
                        'checkin_em',            t.checkin_em,
                        'checkin_tipo',          t.checkin_tipo,
                        'checkin_confirmado_em', t.checkin_confirmado_em,
                        'cancelamento',          case
                          when p.estado = 'cancelada' and p.profissional_id is not null then
                            (select jsonb_build_object(
                               'causa', case
                                 when o.motivo = 'reabertura_por_atraso' then 'reabertura_por_atraso'
                                 when o.motivo = 'no_show_sem_checkin' then 'no_show_sem_checkin'
                                 when o.motivo in ('exclusão de conta', 'suspensão de conta') then 'outro'
                                 when o.motivo = 'vaga_cancelada' then 'estabelecimento'
                                 when o.autor_id = privado.usuario_do_profissional(p.profissional_id) then 'profissional'
                                 else 'estabelecimento'
                               end,
                               'falta', p.falta,
                               'motivo', case
                                 when o.motivo in ('reabertura_por_atraso', 'no_show_sem_checkin', 'exclusão de conta', 'suspensão de conta', 'vaga_cancelada')
                                   then null
                                 else o.motivo
                               end,
                               'cancelada_em', o.criada_em)
                               from public.ocorrencia o
                              where o.posicao_id = p.id
                                and o.tipo = 'cancelamento'
                              order by o.criada_em desc
                              limit 1)
                          else null end)
                      order by p.id), '[]'::jsonb)
                 from public.posicao p
                 left join public.turno t on t.posicao_id = p.id
                where p.vaga_id = v.id))
         order by v.inicio_em, v.id), '[]'::jsonb)
    into v_vagas
    from public.vaga v
    join public.funcao f on f.id = v.funcao_id
   where v.estabelecimento_id = v_estab
     and v.inicio_em < v_ate
     and v.fim_em    > v_de;

  select coalesce(jsonb_agg(t.id order by t.checkin_em, t.id), '[]'::jsonb)
    into v_pendentes
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
    join public.vaga v    on v.id = p.vaga_id
   where v.estabelecimento_id = v_estab
     and v.inicio_em < v_ate
     and v.fim_em    > v_de
     and p.estado in ('confirmada', 'cumprida')
     and t.checkin_tipo = 'manual'
     and t.verificacao = 'pendente'
     and t.checkin_confirmado_em is null;

  return jsonb_build_object(
    'estabelecimento_id', v_estab,
    'vagas',              v_vagas,
    'checkins_pendentes', v_pendentes);
end $$;

comment on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) is
  'Vagas, candidatos, contratados, check-ins, cancelamentos e republicável em urgência do estabelecimento (RF20, RF13, RF14, RN12, UC07, D1-C). Contrato 0.2.41. checkins_pendentes lista apenas turnos com verificacao = pendente.';

revoke execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) from public, anon;
grant  execute on function public.painel_estabelecimento(uuid, timestamptz, timestamptz) to authenticated;
