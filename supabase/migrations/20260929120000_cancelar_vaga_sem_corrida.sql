-- `cancelar_vaga × candidatar` sem corrida (cartão nspP9YDU, RNF14).
--
-- Medido em `scripts/corrida-ciclo.sh`, cenário 2: com a casa cancelando a vaga no mesmo
-- instante em que um profissional aceita a última posição, 19 de 50 rodadas terminavam
-- com a vaga `cancelada` e a posição do candidato `confirmada` — o turno de pé numa vaga
-- que não existe mais, sem aviso a ninguém. O contrato (0.2.20) promete o contrário:
-- `cancelar_vaga` cancela as abertas **e as confirmadas**, e avisa os confirmados.
--
-- O caminho: `candidatar` confirma a posição e segura a linha até o commit. O laço das
-- confirmadas de `cancelar_vaga` lê um snapshot que ainda não tem essa confirmação. O
-- `update` das abertas chega à linha, espera o commit do candidato, relê a linha, vê que
-- ela já não é `aberta` e a pula. A vaga é cancelada por cima.
--
-- A correção não recria `public.cancelar_vaga`: a superfície da RPC não muda, e o que
-- falta é um passo depois da espera. O último comando dela é o `update` da vaga, e ele
-- roda depois de o `update` das abertas ter esperado cada candidatura em curso
-- terminar. Um gatilho nesse `update` lê as posições num snapshot novo, enxerga a
-- confirmação que comitou no meio, e a cancela pelo mesmo caminho do laço
-- (`privado.cancelar_uma_posicao`, sem reabrir). Não sobra posição aberta para outra
-- candidatura pegar: as que existiam, o `update` das abertas travou e cancelou.
--
-- O alcance é o turno que **não começou**. É o mesmo corte de `excluir_conta`, o outro
-- caminho que cancela vaga: ele cancela antes as confirmadas futuras e deixa o turno em
-- andamento seguir até o fim, por decisão de produto registrada lá. O gatilho não mexe
-- nesse turno.
--
-- Limites conhecidos, fora do alcance sem recriar a RPC:
--   · a resposta de `cancelar_vaga` conta em `posicoes_canceladas` só o que o laço e o
--     `update` das abertas viram; a posição recolhida pelo gatilho não entra na conta;
--   · a posição reaberta por atraso, que aceita candidato depois do início (0.2.19), não
--     é recolhida se a corrida acontecer com o turno já começado.

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
  -- Sem conta no JWT não há autor para a ocorrência (`autor_id not null`). O único
  -- caminho assim é o de serviço de `excluir_conta`, que cancela as confirmadas futuras
  -- ele mesmo antes de chegar aqui.
  if v_uid is null then
    return new;
  end if;

  -- Por id, a mesma ordem de aquisição de `cancelar_vaga` e `candidatar`.
  for v_pos in
    select p.id from public.posicao p
     where p.vaga_id = new.id
       and p.estado = 'confirmada'
       and p.inicio_em > v_agora
     order by p.id
       for update
  loop
    -- Motivo estável, e não texto da casa: o texto dela não chega ao gatilho, e é este
    -- código que distingue na auditoria a posição recolhida depois da corrida.
    perform privado.cancelar_uma_posicao(v_pos, v_uid, 'vaga_cancelada', false);
  end loop;

  return new;
end $$;

comment on function privado.vaga_cancelada_recolhe_confirmadas() is
  'Gatilho BEFORE de vaga: ao ir para cancelada, cancela (sem reabrir) as posições ainda confirmadas cujo turno não começou, com ocorrência de motivo vaga_cancelada. Recolhe a candidatura que confirmou durante cancelar_vaga (RNF14, nspP9YDU). Turno em andamento segue, como em excluir_conta.';

revoke execute on function privado.vaga_cancelada_recolhe_confirmadas()
  from public, anon, authenticated;
grant execute on function privado.vaga_cancelada_recolhe_confirmadas() to service_role;

create trigger vaga_cancelada_recolhe_confirmadas
  before update of estado on public.vaga
  for each row
  when (new.estado = 'cancelada' and old.estado is distinct from 'cancelada')
  execute function privado.vaga_cancelada_recolhe_confirmadas();
