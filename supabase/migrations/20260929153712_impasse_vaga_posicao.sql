-- O impasse entre o gatilho da vaga cancelada e a desistência que reabre (cartão
-- CPD2c74A, RNF14). Observado na revisão do #62.
--
-- O gatilho do #60 (`vaga_cancelada_recolhe_confirmadas`) é `BEFORE UPDATE` em `vaga`:
-- ele já segura a linha da vaga quando pede as posições confirmadas. A desistência
-- (`cancelar_uma_posicao` com reabertura) fazia o contrário: segurava a posição e pedia
-- a vaga para voltá-la a `publicada`. Numa corrida a três o ciclo fechava:
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
-- O Postgres abortava um dos lados, quase sempre o `cancelar_vaga` da casa (500).
-- Medido em `scripts/corrida-ciclo.sh`: no cenário 5 (tempos sorteados) a janela é de
-- microssegundos e não abriu em 500 rodadas; no cenário 6, com duas travas de serviço
-- alargando a janela para um segundo, o impasse veio em 10 de 10 rodadas.
--
-- A correção é a ordem das travas: **a vaga antes da posição**, em todo caminho que
-- mexe nas duas e que não começou. Sem pular linha travada (`skip locked`): a versão
-- anterior deste PR pulava, e se quem segurava a posição fizesse rollback depois de o
-- gatilho passar, a posição voltava a `confirmada` numa vaga já cancelada (revisão do
-- #63, cenário 7). Com a ordem, todo mundo espera, e quem espera relê o que o outro
-- deixou, tenha ele comitado ou desfeito.
--
--   · `candidatar` trava a vaga no começo (`for update`, o mesmo modo da trava do fim
--     dela), por `privado.travar_candidatura`, a primeira trava que ela pede. A candidatura que chega durante um `cancelar_vaga` espera o
--     commit da casa e lê a vaga cancelada (`vaga_encerrada`), em vez de confirmar uma
--     posição no meio do cancelamento. As candidaturas da mesma vaga já se
--     enfileiravam na trava da vaga do fim da função; agora se enfileiram no começo.
--   · `cancelar_uma_posicao` trava a vaga antes da posição quando o turno não começou.
--     É o caminho de `cancelar_posicao`, do laço de `cancelar_vaga`, do gatilho e de
--     `excluir_conta`. A desistência que chega durante um `cancelar_vaga` espera a
--     casa e encontra a posição cancelada (409 `posicao_nao_cancelavel`).
--   · O gatilho segura a vaga (é o `update` dela) e trava as posições por id, esperando.
--
-- O turno que já começou fica de fora da ordem nova, de propósito: `reabrir_por_atraso`
-- trava a posição antes da vaga, é função de `public`, e travar a vaga antes numa
-- posição começada abriria com ela o mesmo ciclo. O gatilho não mexe em turno começado,
-- e a desistência dele não reabre; ali a ordem continua posição → vaga, como era.
--
-- O gatilho recolhe também a posição **aberta**: a que uma desistência reabriu e
-- comitou depois do update das abertas de `cancelar_vaga` sobrava viva na vaga
-- cancelada. Ele faz isso antes da saída sem conta, então vale também no caminho de
-- serviço de `excluir_conta` (que já cancelou as abertas antes; ali não há o que pegar).
--
-- Limite conhecido, fora do alcance sem recriar `public.cancelar_vaga`: quando a vaga
-- não tem confirmada futura, o laço não chama `cancelar_uma_posicao` e a primeira trava
-- de `cancelar_vaga` é o update das abertas (posição antes da vaga). Se uma candidatura
-- comita a posição enquanto esse update espera por ela, o Postgres deixa a linha
-- travada depois da reconferência, e uma desistência que pegue a vaga antes do `update`
-- da vaga (microssegundos) fecha outro ciclo. O desfecho é 40P01 e rollback — visível e
-- reenviável, sem estado inconsistente. `excluir_conta` da casa tem o mesmo desenho.

-- ── 1. candidatar trava a vaga primeiro ─────────────────────────────────────

create or replace function privado.travar_candidatura(vaga uuid, prof uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  -- A vaga antes de qualquer posição (CPD2c74A), e já em `update`, o modo da trava do
  -- fim de `candidatar`. Começar em `no key update` e subir no fim abria um impasse
  -- (revisão do #63, rodada 2, cenário 8): a subida para `update` espera o `key share`
  -- de quem inseriu uma posição na vaga — `reabrir_por_atraso` cria a reaberta —, e
  -- esse, no gatilho da rodada de despacho, espera a vaga que a candidatura segura. Em
  -- `update` desde o começo, quem insere espera a candidatura antes de pedir a vaga. O
  -- custo, esperar o `key share` de quem insere despacho ou posição na vaga, a trava do
  -- fim já tinha.
  perform 1 from public.vaga g where g.id = vaga for update;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(vaga::text), pg_catalog.hashtext(prof::text));
end $$;

comment on function privado.travar_candidatura(uuid, uuid) is
  'Primeira trava de candidatar: a linha da vaga (ordem vaga → posição, CPD2c74A) e a trava de transação por par (vaga, profissional), que impede o mesmo profissional de tomar duas posições da mesma vaga com duas chamadas em paralelo.';

revoke execute on function privado.travar_candidatura(uuid, uuid)
  from public, anon, authenticated;
grant execute on function privado.travar_candidatura(uuid, uuid) to service_role;

-- ── 2. O gatilho da vaga cancelada ──────────────────────────────────────────

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
  -- isso vem antes da saída sem conta. A vaga já está travada (é este `update`), e as
  -- posições vêm por id.
  update public.posicao p
     set estado = 'cancelada'
   where p.id in (select x.id from public.posicao x
                   where x.vaga_id = new.id
                     and x.estado = 'aberta'
                   order by x.id
                     for no key update);

  -- Sem conta no JWT não há autor para a ocorrência (`autor_id not null`). O único
  -- caminho assim é o de serviço de `excluir_conta`, que cancela as confirmadas futuras
  -- ele mesmo antes de chegar aqui.
  if v_uid is null then
    return new;
  end if;

  -- Por id, esperando quem segura a linha: todo caminho que mexe numa posição de turno
  -- futuro trava a vaga antes (CPD2c74A), então quem a segura aqui não espera esta vaga.
  -- Se ele comitou o cancelamento, `cancelar_uma_posicao` relê e segue; se desfez, a
  -- posição volta confirmada e é recolhida aqui.
  for v_pos in
    select p.id from public.posicao p
     where p.vaga_id = new.id
       and p.estado = 'confirmada'
       and p.inicio_em > v_agora
     order by p.id
       for no key update
  loop
    -- Motivo estável, e não texto da casa: o texto dela não chega ao gatilho, e é este
    -- código que distingue na auditoria a posição recolhida depois da corrida.
    perform privado.cancelar_uma_posicao(v_pos, v_uid, 'vaga_cancelada', false);
  end loop;

  return new;
end $$;

comment on function privado.vaga_cancelada_recolhe_confirmadas() is
  'Gatilho BEFORE de vaga: ao ir para cancelada, cancela as posições ainda abertas e (sem reabrir, com ocorrência de motivo vaga_cancelada) as confirmadas cujo turno não começou. Recolhe o que confirmou ou reabriu durante cancelar_vaga (RNF14, nspP9YDU). Segura a vaga e trava as posições por id, na ordem vaga → posição de todos os caminhos de turno futuro (CPD2c74A). Turno em andamento segue, como em excluir_conta.';

revoke execute on function privado.vaga_cancelada_recolhe_confirmadas()
  from public, anon, authenticated;
grant execute on function privado.vaga_cancelada_recolhe_confirmadas() to service_role;

-- ── 3. cancelar_uma_posicao trava a vaga antes da posição ───────────────────

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
  'Desiste de uma posição confirmada com motivo (RF14, RN12). Turno futuro: trava a vaga antes da posição (ordem vaga → posição, CPD2c74A). Trava a posição e reconfere o estado: já cancelada por outro caminho, devolve 409 posicao_nao_cancelavel à desistência avulsa e nulo aos laços (xJ53t3tX). Quando é do profissional e a menos de 24 h do início, marca falta e recalcula a taxa. Se pedido, antes do início e com a vaga publicada ou preenchida, reabre a posição criando outra e redisparando o despacho. Notifica a outra parte. Exige conta ativa.';

revoke execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  to service_role;
