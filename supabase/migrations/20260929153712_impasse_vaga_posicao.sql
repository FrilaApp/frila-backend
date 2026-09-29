-- O impasse entre o gatilho da vaga cancelada e a desistência que reabre (cartão
-- CPD2c74A, RNF14). Observado na revisão do #62.
--
-- Todos os caminhos de escrita travam a posição antes da vaga: `candidatar` (a posição
-- com `skip locked`, depois a vaga), o laço e o update das abertas de `cancelar_vaga`,
-- `reabrir_por_atraso`, `excluir_conta`, o fechamento. O gatilho do #60
-- (`vaga_cancelada_recolhe_confirmadas`) é a exceção: ele é `BEFORE UPDATE` em `vaga`,
-- então já segura a linha da vaga quando pede as posições confirmadas. A desistência
-- (`cancelar_uma_posicao` com reabertura) faz o contrário: segura a posição e pede a
-- vaga para voltá-la a `publicada`. Numa corrida a três o ciclo fecha:
--
--   cancelar_vaga (casa)       candidatar (prof)      cancelar_posicao (o mesmo prof)
--   ────────────────────       ─────────────────      ───────────────────────────────
--   laço das confirmadas:
--   não vê P (aberta)
--                              confirma P, commit
--   update das abertas:
--   não vê P (confirmada)
--                                                     trava P, cancela, abre P'
--   update da vaga (trava V)
--   gatilho: espera P
--                                                     update de V: espera V → 40P01
--
-- O Postgres aborta um dos lados, quase sempre o `cancelar_vaga` da casa, que recebe
-- 500. Medido em `scripts/corrida-ciclo.sh`: no cenário 5 (tempos sorteados) a janela é
-- de microssegundos e não abriu em 500 rodadas; no cenário 6, com duas travas de serviço
-- alargando a janela para um segundo, o impasse veio em 10 de 10 rodadas.
--
-- Pôr tudo na ordem vaga → posição exigiria recriar `candidatar`, `cancelar_vaga` e
-- `reabrir_por_atraso`, que travam a posição primeiro, e recriar função de `public`
-- passa pelo portão do contrato. A correção fica do outro lado: a ordem posição → vaga
-- passa a valer também no gatilho.
--
--   · O gatilho não espera posição travada: `for no key update skip locked`. A posição
--     que ele pula é de quem a segura para escrever nela, e o único que escreve numa
--     posição confirmada de turno futuro é um cancelamento (`cancelar_uma_posicao`), que
--     a cancela de qualquer jeito. `no key update`, e não `update`: esse modo não
--     conflita com o `key share` de quem só insere uma linha que aponta para a posição
--     (ocorrência, candidatura), e o gatilho não pula a posição por causa disso.
--   · A desistência trava a vaga antes de reabrir, e não reabre em vaga cancelada ou
--     encerrada. Ela esperava a vaga do mesmo jeito (o `update` para `publicada`); o
--     que muda é que a espera vem antes de criar a posição nova, e que ela relê a vaga
--     depois dela. Quando a casa comitou antes, a desistência vale (a falta é do
--     profissional, RN12), a posição não reabre e a casa é avisada com
--     `reaberta = false`, como em qualquer turno descoberto.
--   · O gatilho recolhe também a posição aberta. O update das abertas de
--     `cancelar_vaga` não vê a posição que uma desistência reabriu e comitou depois
--     dele; ela sobrava aberta na vaga cancelada. A aberta sai sem ocorrência, como sai
--     no update das abertas.
--
-- Limite conhecido: uma quarta transação que pegue a posição reaberta com `candidatar`
-- entre o update das abertas e o da vaga segura essa posição, o gatilho a pula, e ela
-- confirma na vaga cancelada. Fechar isso é conferir a vaga dentro de `candidatar`,
-- que é função de `public`.

-- ── 1. O gatilho da vaga cancelada ──────────────────────────────────────────

create or replace function privado.vaga_cancelada_recolhe_confirmadas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_agora timestamptz := privado.agora();
  v_pos   uuid;
begin
  -- A posição aberta que nasceu depois do update das abertas de `cancelar_vaga` (uma
  -- desistência que reabriu e comitou no meio). Não tem de quem ser ocorrência, e por
  -- isso vem antes da saída sem conta. A que outra transação segura é de uma
  -- candidatura em curso, que espera esta vaga: esperar por ela aqui seria o impasse.
  update public.posicao p
     set estado = 'cancelada'
   where p.id in (select x.id from public.posicao x
                   where x.vaga_id = new.id
                     and x.estado = 'aberta'
                   order by x.id
                     for no key update skip locked);

  -- Sem conta no JWT não há autor para a ocorrência (`autor_id not null`). O único
  -- caminho assim é o de serviço de `excluir_conta`, que cancela as confirmadas futuras
  -- ele mesmo antes de chegar aqui.
  if v_uid is null then
    return new;
  end if;

  -- Por id, e sem esperar: a posição que outra transação segura é de um cancelamento
  -- em curso, que a cancela e, ao reabrir, espera esta vaga e a encontra cancelada.
  for v_pos in
    select p.id from public.posicao p
     where p.vaga_id = new.id
       and p.estado = 'confirmada'
       and p.inicio_em > v_agora
     order by p.id
       for no key update skip locked
  loop
    -- Motivo estável, e não texto da casa: o texto dela não chega ao gatilho, e é este
    -- código que distingue na auditoria a posição recolhida depois da corrida.
    perform privado.cancelar_uma_posicao(v_pos, v_uid, 'vaga_cancelada', false);
  end loop;

  return new;
end $$;

comment on function privado.vaga_cancelada_recolhe_confirmadas() is
  'Gatilho BEFORE de vaga: ao ir para cancelada, cancela as posições ainda abertas e (sem reabrir, com ocorrência de motivo vaga_cancelada) as confirmadas cujo turno não começou. Recolhe o que confirmou ou reabriu durante cancelar_vaga (RNF14, nspP9YDU). Pula a posição que outra transação segura (skip locked), para não esperar posição segurando a vaga (CPD2c74A). Turno em andamento segue, como em excluir_conta.';

revoke execute on function privado.vaga_cancelada_recolhe_confirmadas()
  from public, anon, authenticated;
grant execute on function privado.vaga_cancelada_recolhe_confirmadas() to service_role;

-- ── 2. A desistência trava a vaga antes de reabrir ──────────────────────────

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
  v_estado_vaga public.estado_vaga;
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
    -- A vaga travada antes da posição nova (CPD2c74A), na ordem posição → vaga de todos
    -- os caminhos. Se a casa cancelou a vaga no meio, o gatilho dela pulou esta posição
    -- (que estava travada aqui) e a espera termina com a vaga cancelada: a desistência
    -- vale, e a posição não reabre numa vaga que não existe mais.
    select g.estado into v_estado_vaga
      from public.vaga g where g.id = v_pos.vaga_id for no key update;

    if v_estado_vaga in ('publicada', 'preenchida') then
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
  'Desiste de uma posição confirmada com motivo (RF14, RN12). Trava a posição e reconfere o estado: já cancelada por outro caminho, devolve 409 posicao_nao_cancelavel à desistência avulsa e nulo aos laços (xJ53t3tX). Quando é do profissional e a menos de 24 h do início, marca falta e recalcula a taxa. Se pedido e antes do início, trava a vaga e, se ela segue publicada ou preenchida, reabre a posição criando outra e redisparando o despacho (CPD2c74A). Notifica a outra parte. Exige conta ativa.';

revoke execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  to service_role;
