-- Expira as notificações push pendentes antigas antes de o agendador ligar (hQDlvpHi).
--
-- No Prod nenhum job chamava `enviar-push`: as notificações ficaram em `pendente` por dias
-- (54 medidas). Quando o job de um minuto da 20261104140200 ligar, elas sairiam todas de
-- uma vez, para gente que já viu o evento acontecer ou passar. Esta migração as retira da
-- fila antes, e a de numeração seguinte liga o agendador.
--
-- `estado_entrega` não tem `expirada` (o enum é pendente, enviada, entregue, falhou), e
-- acrescentar valor a enum em uso é mudança de contrato que o cartão não pede. A notificação
-- vira `falhou`, com `motivo_falha = 'expirada_sem_agendador'`: é a mesma saída que o envio
-- dá a quem perdeu a hora (`vaga_ou_turno_ja_iniciado`), e o motivo deixa o caso separável.
--
-- Escrita como função para ser testável e reaproveitável; a migração a chama uma vez, com a
-- idade padrão de 1 hora. Notificações mais novas que isso são legítimas e saem normalmente.

create or replace function privado.expirar_notificacoes_pendentes_antigas(
  p_idade interval default interval '1 hour'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_expiradas integer;
begin
  update public.notificacao
     set estado_entrega       = 'falhou',
         motivo_falha         = 'expirada_sem_agendador',
         proxima_tentativa_em = null
   where estado_entrega = 'pendente'
     and enviada_em < privado.agora() - p_idade;

  get diagnostics v_expiradas = row_count;
  return v_expiradas;
end $$;

comment on function privado.expirar_notificacoes_pendentes_antigas(interval) is
  'Marca como falhou (motivo expirada_sem_agendador) as notificações pendentes com mais de p_idade (padrão 1 hora). Usada uma vez, antes de ligar o agendador do push (hQDlvpHi), para que o acúmulo legado não saia em massa. Devolve quantas expirou.';

revoke execute on function privado.expirar_notificacoes_pendentes_antigas(interval) from public, anon, authenticated;
grant  execute on function privado.expirar_notificacoes_pendentes_antigas(interval) to service_role;

select privado.expirar_notificacoes_pendentes_antigas();
