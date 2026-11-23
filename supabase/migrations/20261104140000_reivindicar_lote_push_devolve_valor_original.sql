-- privado.reivindicar_lote_push devolve a proxima_tentativa_em de ANTES da reivindicação.
--
-- A 20261018050000 avança `proxima_tentativa_em` em 5 minutos (lease) e devolvia, no
-- RETURNING, o valor NOVO. A Edge Function `enviar-push` pula o item cuja
-- `proxima_tentativa_em` está no futuro (aguardando_backoff, que é o backoff de uma falha
-- transitória). O resultado, medido no Prod com o TestFlight 1.0.0: todo item recém
-- reivindicado era pulado, e o lote nunca enviava nada.
--
-- O lease continua gravado na tabela, que é o que impede outro worker de pegar o mesmo
-- item. O que muda é o que a função devolve a quem a chamou: o valor que a linha tinha
-- antes, que é o único que diz algo sobre backoff. Corrigir aqui, e não só na Edge Function,
-- faz o conserto valer mesmo antes de a função ser publicada de novo.
--
-- Mesma assinatura e mesmos privilégios: `create or replace` basta.

create or replace function privado.reivindicar_lote_push(
  p_limite int default 10
)
returns table (
  id uuid,
  usuario_id uuid,
  tipo public.tipo_notificacao,
  referencia_id uuid,
  payload jsonb,
  tentativas int,
  estado_entrega public.estado_entrega,
  proxima_tentativa_em timestamptz,
  urgente boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_timeout interval    := interval '5 minutes';
begin
  return query
  with lote as (
    select n.id, n.proxima_tentativa_em as proxima_original
      from public.notificacao n
     where n.estado_entrega = 'pendente'
       and (n.proxima_tentativa_em is null or n.proxima_tentativa_em <= v_agora)
     order by n.enviada_em asc
     limit p_limite
     for update skip locked
  ), reivindicadas as (
    update public.notificacao n
       set proxima_tentativa_em = v_agora + v_timeout
      from lote
     where n.id = lote.id
    returning
      n.id,
      n.usuario_id,
      n.tipo,
      n.referencia_id,
      n.payload,
      n.tentativas,
      n.estado_entrega,
      n.urgente
  )
  select r.id,
         r.usuario_id,
         r.tipo,
         r.referencia_id,
         r.payload,
         r.tentativas,
         r.estado_entrega,
         lote.proxima_original,
         r.urgente
    from reivindicadas r
    join lote on lote.id = r.id;
end $$;

comment on function privado.reivindicar_lote_push(int) is
  'Reivindica lote de notificações push pendentes com SKIP LOCKED e avança proxima_tentativa_em por 5 minutos (lease no banco). Devolve a proxima_tentativa_em de ANTES da reivindicação, para que o lease recém-gravado não seja lido como backoff por quem envia (cartão hQDlvpHi).';

revoke execute on function privado.reivindicar_lote_push(int) from public, anon, authenticated;
grant  execute on function privado.reivindicar_lote_push(int) to service_role;
