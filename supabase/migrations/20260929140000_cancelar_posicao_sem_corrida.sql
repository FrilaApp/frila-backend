-- `cancelar_vaga × cancelar_posicao` sem corrida (cartão xJ53t3tX, RNF14).
--
-- Medido na revisão do PR #60 e agora em `scripts/corrida-ciclo.sh`, cenário 4: com a
-- casa segurando o `cancelar_vaga` e o profissional chamando `cancelar_posicao` no mesmo
-- instante, o profissional esperava o commit da casa, recancelava a posição já
-- cancelada e **abria uma posição nova na vaga cancelada**, com despacho enfileirado.
--
-- O caminho: `cancelar_posicao` lê a posição sem trava e confere `confirmada` num
-- snapshot anterior ao commit da casa. `privado.cancelar_uma_posicao` relia sem trava e
-- fazia o `update` sem reconferir o estado; o `update` esperava a linha, e sob READ
-- COMMITTED seguia com ela porque o filtro era só o id. Depois reabria, porque o turno
-- ainda não começou. O gatilho `vaga_cancelada_recolhe_confirmadas` (#60) não alcança:
-- a reabertura acontece depois do commit do cancelamento da vaga.
--
-- Na ordem inversa, o laço das confirmadas de `cancelar_vaga` recancelava a posição que
-- o profissional acabara de largar: ocorrência dobrada, aviso ao profissional de um
-- cancelamento pela casa que não aconteceu, e a falta dele (RN12) apagada, porque o
-- `update` gravava `falta = false` calculado sobre a linha velha.
--
-- A correção não recria função de `public` (a superfície das RPCs não muda): a trava e
-- a reconferência entram em `privado.cancelar_uma_posicao`, que todos os caminhos de
-- cancelamento usam. Ela trava a posição com `for update` antes de ler, e se a linha que
-- encontra depois da espera já não está confirmada:
--   · a desistência avulsa (`cancelar_posicao`: reabre, fora da exclusão de conta)
--     recebe 409 `posicao_nao_cancelavel`, o mesmo código de quem chega depois do
--     commit;
--   · os laços (`cancelar_vaga`, o gatilho da vaga cancelada, `excluir_conta`) seguem
--     sem mexer nela, e a função devolve nulo — eles a chamam com `perform`.
--
-- A ordem de aquisição não muda: a posição antes da vaga, como em `cancelar_vaga` e
-- `candidatar`.
--
-- Limite conhecido, fora do alcance sem recriar a RPC: na rodada em que o profissional
-- desiste primeiro, `posicoes_canceladas` na resposta de `cancelar_vaga` conta a posição
-- dele, que o laço leu confirmada, além da que ele reabriu.

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
begin
  perform privado.exigir_conta_ativa();

  -- A trava e a reconferência (xJ53t3tX). Quem chama já conferiu que a posição estava
  -- confirmada, mas num snapshot sem trava: com o outro lado cancelando no mesmo
  -- instante, a linha que chega aqui depois da espera pode já estar cancelada. O
  -- `for update` espera o commit dele e devolve a linha como ficou.
  select * into v_pos from public.posicao p where p.id = posicao for update;

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
  -- o contratante.
  if reabrir and v_pos.inicio_em > v_agora then
    insert into public.posicao (vaga_id, inicio_em, fim_em)
    values (v_pos.vaga_id, v_pos.inicio_em, v_pos.fim_em)
    returning id into v_nova;

    -- A vaga estava preenchida e volta a ter posição aberta.
    update public.vaga g set estado = 'publicada'
     where g.id = v_pos.vaga_id and g.estado = 'preenchida';

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
  'Desiste de uma posição confirmada com motivo (RF14, RN12). Trava a posição e reconfere o estado: já cancelada por outro caminho, devolve 409 posicao_nao_cancelavel à desistência avulsa e nulo aos laços (xJ53t3tX). Quando é do profissional e a menos de 24 h do início, marca falta e recalcula a taxa. Se pedido e antes do início, reabre a posição criando outra e redisparando o despacho. Notifica a outra parte. Exige conta ativa.';

revoke execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  to service_role;

