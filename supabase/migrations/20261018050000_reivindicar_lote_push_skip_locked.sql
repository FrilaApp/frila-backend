-- Reivindicação atômica de notificações push em lote com SKIP LOCKED (Item 15)
--
-- Evita envio duplicado de notificações ao FCM em execuções concorrentes do agendador/cron.
-- Utiliza `FOR UPDATE SKIP LOCKED` para que dois workers simultâneos nunca reivindiquem
-- a mesma notificação da fila.
--
-- Aplica um visibility timeout (lease) de 5 minutos em `proxima_tentativa_em`:
-- 1. Se o envio tiver sucesso, `gravar_aceite_push` transiciona para `estado_entrega = 'enviada'` e limpa `proxima_tentativa_em`.
-- 2. Se o envio falhar com erro permanente, `gravar_falha_push` define `estado_entrega = 'falhou'` e limpa `proxima_tentativa_em`.
-- 3. Se o envio falhar com erro transitório, `gravar_falha_push` recalcula e sobrescreve `proxima_tentativa_em` com o backoff exponencial (10s, 20s, 40s...).
-- 4. Se o worker cair antes de concluir, o lease expira em 5 minutos e a notificação volta a ser elegível sem colisão nem bloqueio perpétuo.

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
    select n.id
      from public.notificacao n
     where n.estado_entrega = 'pendente'
       and (n.proxima_tentativa_em is null or n.proxima_tentativa_em <= v_agora)
     order by n.enviada_em asc
     limit p_limite
     for update skip locked
  )
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
    n.proxima_tentativa_em,
    n.urgente;
end $$;

comment on function privado.reivindicar_lote_push(int) is
  'Reivindica lote de notificações push pendentes com SKIP LOCKED e avança proxima_tentativa_em por 5 minutos (visibility timeout/lease), evitando corridas e envios duplicados ao FCM (Item 15).';

revoke execute on function privado.reivindicar_lote_push(int) from public, anon, authenticated;
grant  execute on function privado.reivindicar_lote_push(int) to service_role;
