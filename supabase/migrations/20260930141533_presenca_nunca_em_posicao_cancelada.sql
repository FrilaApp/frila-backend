-- Presença verificada nunca em posição cancelada (auditoria de segurança de 30/09).
--
-- O caminho, medido no banco local em 30/09:
--
--   1. o profissional faz check-in manual (longe, ou sem GPS): turno `pendente`;
--   2. desiste por `cancelar_posicao`, que não olha o check-in: a posição vai para
--      `cancelada` com falta, e o turno para `nao_verificado`;
--   3. a casa chama `confirmar_checkin_manual`, que olha só o turno: o turno vira
--      `verificado`.
--
-- Resultado: a mesma posição conta como presença **e** como falta — taxa de
-- comparecimento 0,500 em vez de 0 —, e o turno cancelado abre avaliação depois do fim
-- (RN07 exige presença verificada, e ela passou a existir). Serve tanto ao engano quanto
-- ao conluio para inflar a reputação de alguém.
--
-- O check-in já era recusado em posição cancelada, pelo gatilho
-- `turno_checkin_nunca_em_posicao_cancelada` (20260925020000). Este é o par dele para a
-- verificação, com o mesmo código: `409 vaga_encerrada`, `details: posicao_cancelada`. O
-- 409 está declarado para `confirmar_checkin_manual` no contrato, e `vaga_encerrada` é do
-- catálogo. A trava fica no dado, e não na RPC, para valer também para a escrita de
-- serviço.

create or replace function privado.verificacao_nunca_em_posicao_cancelada()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  if new.verificacao = 'verificado'
     and old.verificacao is distinct from 'verificado'
     and exists (select 1 from public.posicao p
                  where p.id = new.posicao_id and p.estado = 'cancelada') then
    perform public.erro(409, 'vaga_encerrada', 'posicao_cancelada');
  end if;
  return new;
end $$;

comment on function privado.verificacao_nunca_em_posicao_cancelada() is
  'RN22/RN07: o turno de uma posição cancelada não passa a ter presença verificada. Par de privado.checkin_nunca_em_posicao_cancelada para a confirmação do check-in manual.';

revoke execute on function privado.verificacao_nunca_em_posicao_cancelada()
  from public, anon, authenticated;
grant  execute on function privado.verificacao_nunca_em_posicao_cancelada()
  to service_role;

create trigger turno_verificacao_nunca_em_posicao_cancelada
  before update of verificacao on public.turno
  for each row execute function privado.verificacao_nunca_em_posicao_cancelada();
