-- Regra 4 proposta: aguarda decisão do JP (Regra 4).
-- Parâmetros únicos: antecedência15min, arrependimento10min, tempo hábil45min.
-- Sem configuração/remoto/ativação em Prod. Mantém contratos de retorno existentes.
create or replace function privado.parametros_aceite_tardio()
returns table (antecedencia interval, carencia interval, tempo_habil interval)
language sql stable set search_path = '' as $$
  select interval '15 minutes', interval '10 minutes', interval '45 minutes'
$$;
revoke all on function privado.parametros_aceite_tardio() from public, anon, authenticated;
grant execute on function privado.parametros_aceite_tardio() to service_role;

create or replace function privado.aceite_tardio(inicio timestamptz, confirmado timestamptz)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(confirmado >= inicio - (select antecedencia from privado.parametros_aceite_tardio()), false)
$$;
revoke all on function privado.aceite_tardio(timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function privado.aceite_tardio(timestamptz, timestamptz) to service_role;

create or replace function privado.cancelar_uma_posicao(
  posicao uuid,
  autor   uuid,
  motivo  text,
  reabrir boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos   public.posicao%rowtype;
  v_agora timestamptz := privado.agora();
  v_falta boolean := false;
  v_nova  uuid;
  v_eh_prof boolean;
  v_vaga  uuid;
  v_inicio timestamptz;
  v_estado_vaga public.estado_vaga;
begin
  perform privado.exigir_conta_ativa();

  -- A ordem das travas (CPD2c74A): a vaga antes da posição, quando o turno não começou.
  -- A vaga e o início de uma posição não mudam depois de ela existir, então a leitura
  -- sem trava basta para saber qual vaga travar. O turno começado fica na ordem antiga
  -- (posição → vaga), a de `reabrir_por_atraso`; ali não se reabre e o gatilho não
  -- entra.
  select p.vaga_id, p.inicio_em into v_vaga, v_inicio
    from public.posicao p where p.id = posicao;

  if v_inicio > v_agora then
    select g.estado into v_estado_vaga
      from public.vaga g where g.id = v_vaga for no key update;
  end if;

  -- A trava e a reconferência (xJ53t3tX). Quem chama já conferiu que a posição estava
  -- confirmada, mas num snapshot sem trava: com o outro lado cancelando no mesmo
  -- instante, a linha que chega aqui depois da espera pode já estar cancelada. A trava
  -- espera o commit dele e devolve a linha como ficou. `no key update`: só estado e
  -- falta mudam, e esse modo não espera quem insere uma linha que aponta para a posição.
  select * into v_pos from public.posicao p where p.id = posicao for no key update;

  if v_pos.estado is distinct from 'confirmada' then
    -- A desistência do profissional (`cancelar_posicao`, que reabre fora da exclusão de
    -- conta) recebe o que receberia chegando depois do commit: não há o que cancelar.
    if reabrir and coalesce(current_setting('frila.exclusao_de_conta', true), 'off') <> 'on' then
      perform public.erro(409, 'posicao_nao_cancelavel');
    end if;
    -- Os laços (`cancelar_vaga`, o gatilho da vaga cancelada, `excluir_conta`) seguem:
    -- a posição já saiu por outro caminho, com a ocorrência e o aviso dele. Recancelá-la
    -- dobraria a ocorrência, avisaria de um cancelamento que não aconteceu e apagaria a
    -- falta de quem desistiu de fato.
    return null;
  end if;

  v_eh_prof := v_pos.profissional_id is not null
               and privado.usuario_do_profissional(v_pos.profissional_id) = autor;

  -- RN12. A falta é do profissional que desiste em cima da hora, e só dele: o
  -- contratante que cancela não gera falta para ninguém, e a posição que nunca foi
  -- confirmada não tem de quem ser falta. Na exclusão de conta (sinalizada via
  -- frila.exclusao_de_conta), não há falta.
  if v_eh_prof and v_pos.estado = 'confirmada'
     and v_pos.inicio_em - v_agora < interval '24 hours'
     and coalesce(current_setting('frila.exclusao_de_conta', true), 'off') <> 'on'
     and not (privado.aceite_tardio(v_pos.inicio_em, v_pos.confirmado_em)
              and v_agora <= v_pos.confirmado_em + (select carencia from privado.parametros_aceite_tardio())) then
    v_falta := true;
  end if;

  update public.posicao p
     set estado = 'cancelada',
         falta  = v_falta
   where p.id = posicao;

  -- O turno cancelado sai junto. Ele não é apagado: o registro do que foi combinado
  -- sobrevive ao cancelamento, e é o que a auditoria lê.
  update public.turno t
     set verificacao = 'nao_verificado'
   where t.posicao_id = posicao and t.verificacao = 'pendente';

  insert into public.ocorrencia (tipo, posicao_id, usuario_id, autor_id, motivo)
  values ('cancelamento', posicao,
          privado.usuario_do_profissional(v_pos.profissional_id), autor, motivo);

  -- Antes do início, a vaga ganha uma posição nova e o despacho sai de novo. Depois do
  -- início não há o que reabrir: o turno ficou descoberto, e quem precisa saber disso é
  -- o contratante. A vaga já está travada desde o começo, e o estado dela é o que ficou
  -- depois da espera: cancelada ou encerrada, não se reabre numa vaga que não existe
  -- mais.
  if reabrir and v_pos.inicio_em > v_agora
     and v_estado_vaga in ('publicada', 'preenchida') then
    insert into public.posicao (vaga_id, inicio_em, fim_em)
    values (v_pos.vaga_id, v_pos.inicio_em, v_pos.fim_em)
    returning id into v_nova;

    -- A vaga estava preenchida e volta a ter posição aberta.
    update public.vaga g set estado = 'publicada'
     where g.id = v_pos.vaga_id and g.estado = 'preenchida';

    -- D4=C: a menos de 24 h do início, a reposição passa para urgência (RN24).
    -- O primeiro candidato elegível confirma na hora e o fechar_selecoes não cancela a vaga.
    if v_pos.inicio_em - interval '24 hours' <= v_agora then
      update public.vaga g set modo = 'urgencia'
       where g.id = v_pos.vaga_id and g.modo = 'selecao';
    end if;

    -- RN35: vaga direta reabre sem despacho. Ela nasceu de uma chamada a uma pessoa só, e
    -- oferecê-la a terceiro levaria o endereço da casa a quem nunca foi chamado. "Publicar
    -- para todos" é a única porta para fora.
    if not exists (select 1 from public.vaga g where g.id = v_pos.vaga_id and g.origem = 'chamada_direta') then
      perform pgmq.send('despacho', jsonb_build_object(
        'vaga_id',        v_pos.vaga_id,
        'posicao_id',     v_nova,
        'motivo',         'reabertura',
        -- Quem cancelou não é notificado de novo da própria vaga. Receber a notificação
        -- da vaga que se acabou de largar é o tipo de detalhe que faz desinstalar o app.
        'excluir_conta',  autor));
    end if;
  end if;

  if v_falta then
    perform privado.recalcular_comparecimento(v_pos.profissional_id);
  end if;

  -- Avisa a **outra parte**, e só ela: quem cancelou sabe. O profissional cancelou, a
  -- casa toda é avisada; a casa cancelou, o profissional é. `reaberta = false` é o turno
  -- descoberto — vaga inteira cancelada, ou início já passado —, que a casa precisa
  -- distinguir da posição que voltou para a fila.
  if v_eh_prof then
    perform privado.notificar_membros(
      privado.estabelecimento_da_vaga(v_pos.vaga_id), 'cancelamento', posicao,
      jsonb_build_object('posicao_id', posicao, 'vaga_id', v_pos.vaga_id,
                         'reaberta', v_nova is not null));
  elsif v_pos.profissional_id is not null then
    perform privado.notificar(privado.usuario_do_profissional(v_pos.profissional_id),
      'cancelamento', posicao,
      jsonb_build_object('posicao_id', posicao, 'vaga_id', v_pos.vaga_id,
                         'reaberta', v_nova is not null));
  end if;

  return jsonb_build_object(
    'posicao_id',      posicao,
    'falta',           v_falta,
    'reaberta',        v_nova is not null,
    'nova_posicao_id', v_nova);
end $$;

create or replace function public.reabrir_por_atraso(posicao_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := (select auth.uid());
  v_agora   timestamptz;
  v_pos     public.posicao%rowtype;
  v_t       public.turno%rowtype;
  v_usr     uuid;
  v_nova    uuid;
  v_falta   boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('contratante');

  if reabrir_por_atraso.posicao_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'posicao_id');
  end if;

  -- A trava vem antes de qualquer leitura de estado: posição e depois turno, a mesma
  -- ordem para toda chamada. O check-in simultâneo espera aqui ou é esperado.
  select * into v_pos from public.posicao p
   where p.id = reabrir_por_atraso.posicao_id
     for update;

  -- Posição que não existe e posição de outra casa respondem igual: um 404 diria a
  -- quem não é da casa que aquela posição existe.
  if not found or not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then
    perform public.erro(403, 'sem_permissao');
  end if;

  select * into v_t from public.turno t where t.posicao_id = v_pos.id for update;

  -- Reenvio: a rede caiu depois do commit. A falta já foi marcada; devolve o que a
  -- primeira chamada devolveu, sem segunda posição nem segundo aviso.
  if v_pos.estado = 'cancelada'
     and exists (select 1 from public.ocorrencia o
                  where o.posicao_id = v_pos.id and o.tipo = 'cancelamento'
                    and o.motivo = 'reabertura_por_atraso') then
    select p.id into v_nova from public.posicao p where p.reaberta_por_atraso_de = v_pos.id;
    return jsonb_build_object(
      'posicao_id',      v_pos.id,
      'falta',           v_pos.falta,
      'reaberta',        v_nova is not null,
      'nova_posicao_id', v_nova);
  end if;

  if v_pos.estado <> 'confirmada' then
    perform public.erro(409, 'posicao_nao_cancelavel');
  end if;

  if v_t.checkin_em is not null then
    perform public.erro(409, 'posicao_nao_cancelavel', 'checkin_registrado');
  end if;

  v_agora := privado.agora();

  -- D06: a tolerância é de 15 minutos a partir do início previsto. O substituto que
  -- confirmou uma posição reaberta com o turno já em andamento ganha os mesmos 15
  -- minutos, contados da confirmação: sem isso a casa poderia declarar falta de quem
  -- acabou de aceitar.
  if v_agora < greatest(v_pos.inicio_em, v_pos.confirmado_em) + interval '15 minutes' then
    perform public.erro(422, 'reabertura_antes_da_tolerancia');
  end if;

  v_usr := privado.usuario_do_profissional(v_pos.profissional_id);

  v_falta := not privado.aceite_tardio(v_pos.inicio_em, v_pos.confirmado_em);

  -- Regra 4: reabrir encerra sem falta no aceite tardio; fora dele mantém RN12.
  -- A mesma posição preserva vínculo e causa para auditoria.
  update public.posicao p
     set estado = 'cancelada',
         falta  = v_falta
   where p.id = v_pos.id;

  update public.turno t
     set verificacao = 'nao_verificado'
   where t.posicao_id = v_pos.id and t.verificacao = 'pendente';

  -- Motivo estável, e não texto da casa: é o que distingue esta falta das outras na
  -- auditoria e no texto do aviso ao profissional.
  insert into public.ocorrencia (tipo, posicao_id, turno_id, usuario_id, autor_id, motivo)
  values ('cancelamento', v_pos.id, v_t.id, v_usr, v_uid, 'reabertura_por_atraso');

  -- 8zLfn0mt item 5: a posição reaberta aceita candidato até 1 h antes do fim. Depois
  -- disso ninguém chega a tempo, e reabrir seria só um despacho inútil.
  if v_agora < v_pos.fim_em - interval '1 hour' then
    insert into public.posicao (vaga_id, inicio_em, fim_em, reaberta_por_atraso_de)
    values (v_pos.vaga_id, v_pos.inicio_em, v_pos.fim_em, v_pos.id)
    returning id into v_nova;

    update public.vaga g set estado = 'publicada'
     where g.id = v_pos.vaga_id and g.estado = 'preenchida';

    -- D5=A: reabertura por atraso acontece após o início (portanto a menos de 24 h).
    -- Em vaga de seleção, a reposição passa para urgência para que o primeiro elegível confirme na hora.
    update public.vaga g set modo = 'urgencia'
     where g.id = v_pos.vaga_id and g.modo = 'selecao';

    -- O mesmo despacho da reabertura por cancelamento. Quem faltou não é notificado da
    -- vaga que deixou de cumprir.
    -- RN35: vaga direta reabre por atraso sem despacho (ver cancelar_uma_posicao).
    if not exists (select 1 from public.vaga g where g.id = v_pos.vaga_id and g.origem = 'chamada_direta') then
      perform pgmq.send('despacho', jsonb_build_object(
        'vaga_id',       v_pos.vaga_id,
        'posicao_id',    v_nova,
        'motivo',        'reabertura',
        'excluir_conta', v_usr));
    end if;
  end if;

  perform privado.recalcular_comparecimento(v_pos.profissional_id);

  -- O profissional é avisado; a casa, que decidiu, não.
  perform privado.notificar(v_usr, 'cancelamento', v_pos.id,
    jsonb_build_object('posicao_id', v_pos.id, 'vaga_id', v_pos.vaga_id,
                       'reaberta', v_nova is not null));

  return jsonb_build_object(
    'posicao_id',      v_pos.id,
    'falta',           v_falta,
    'reaberta',        v_nova is not null,
    'nova_posicao_id', v_nova);
end $$;

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

  -- 3. Sem check-in: encerra por no-show; no aceite tardio só conta falta se o fim previsto concedeu tempo hábil.
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
           falta  = case
             when privado.aceite_tardio(p.inicio_em, p.confirmado_em) then
               p.fim_em >= p.confirmado_em + (select tempo_habil from privado.parametros_aceite_tardio())
             else true end
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
revoke all on function privado.cancelar_uma_posicao(uuid,uuid,text,boolean) from public, anon, authenticated;
grant execute on function privado.cancelar_uma_posicao(uuid,uuid,text,boolean) to service_role;
revoke execute on function public.reabrir_por_atraso(uuid) from public, anon;
grant execute on function public.reabrir_por_atraso(uuid) to authenticated;
revoke execute on function privado.fechar_turnos_passados() from public, anon, authenticated;
grant execute on function privado.fechar_turnos_passados() to service_role;
