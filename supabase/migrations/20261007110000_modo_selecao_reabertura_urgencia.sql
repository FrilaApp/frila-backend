-- 20261007110000_modo_selecao_reabertura_urgencia.sql
--
-- D4=C e D5=A: reposição de vaga de seleção dentro das 24 h do início vira urgência.
--
-- Quando uma posição de vaga de seleção é reaberta a menos de 24 h do início (por
-- cancelamento do profissional/casa ou por falta/atraso aos 15 minutos), a vaga é
-- convertida para o modo 'urgencia':
--   1. O job fechar_selecoes (que roda a cada minuto para vagas em modo selecao com
--      inicio_em - 24 h <= agora) não cancela a posição recém-reaberta;
--   2. Candidatos conseguem se candidatar e o primeiro elegível confirma na hora
--      (princípio da RN24: menos de 24 h é urgência por natureza);
--   3. O turno não fica descoberto.
--
-- Acima de 24 h de antecedência, o cancelamento mantém o modo 'selecao'.

-- ── 1. privado.cancelar_uma_posicao (D4=C) ──────────────────────────────────────

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
     and coalesce(current_setting('frila.exclusao_de_conta', true), 'off') <> 'on' then
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

    perform pgmq.send('despacho', jsonb_build_object(
      'vaga_id',        v_pos.vaga_id,
      'posicao_id',     v_nova,
      'motivo',         'reabertura',
      -- Quem cancelou não é notificado de novo da própria vaga. Receber a notificação
      -- da vaga que se acabou de largar é o tipo de detalhe que faz desinstalar o app.
      'excluir_conta',  autor));
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

comment on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean) is
  'Desiste de uma posição confirmada com motivo (RF14, RN12). Turno futuro: trava a vaga antes da posição (ordem vaga → posição, CPD2c74A). Trava a posição e reconfere o estado: já cancelada por outro caminho, devolve 409 posicao_nao_cancelavel à desistência avulsa e nulo aos laços (xJ53t3tX). Quando é do profissional e a menos de 24 h do início, marca falta e recalcula a taxa. Se pedido, antes do início e com a vaga publicada ou preenchida, reabre a posição criando outra e redisparando o despacho; se a menos de 24 h em vaga de seleção, converte o preenchimento para urgência (D4=C). Notifica a outra parte. Exige conta ativa.';

revoke execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  to service_role;


-- ── 2. reabrir_por_atraso (D5=A) ──────────────────────────────────────────────

-- contrato: corpo-sem-mudanca-de-superficie public.reabrir_por_atraso 0.2.38
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

  -- RN12: reabrir por atraso é declarar que o profissional não veio. Conta como falta,
  -- com a mesma posição guardando de quem ela era.
  update public.posicao p
     set estado = 'cancelada',
         falta  = true
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
    perform pgmq.send('despacho', jsonb_build_object(
      'vaga_id',       v_pos.vaga_id,
      'posicao_id',    v_nova,
      'motivo',        'reabertura',
      'excluir_conta', v_usr));
  end if;

  perform privado.recalcular_comparecimento(v_pos.profissional_id);

  -- O profissional é avisado; a casa, que decidiu, não.
  perform privado.notificar(v_usr, 'cancelamento', v_pos.id,
    jsonb_build_object('posicao_id', v_pos.id, 'vaga_id', v_pos.vaga_id,
                       'reaberta', v_nova is not null));

  return jsonb_build_object(
    'posicao_id',      v_pos.id,
    'falta',           true,
    'reaberta',        v_nova is not null,
    'nova_posicao_id', v_nova);
end $$;

comment on function public.reabrir_por_atraso(uuid) is
  'Aos 15 minutos do início sem check-in, a casa declara o não comparecimento (D06, RN12): cancela a posição com falta, cria posição nova marcada como reaberta por atraso, volta a vaga a publicada e enfileira o despacho. Se a vaga era de seleção, converte o preenchimento para urgência (D5=A). A menos de 1 h do fim, marca a falta sem reabrir. Reenviar devolve o mesmo resultado.';

revoke execute on function public.reabrir_por_atraso(uuid) from public, anon;
grant execute on function public.reabrir_por_atraso(uuid) to authenticated;
