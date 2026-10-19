-- Tarefa B10 (Cartão kT7NhMGV · RNF08, RN10, RF25, LGPD):
-- Fecha public.contato_do_turno contra token de conta excluída/anonimizada (ou suspensa).
--
-- A verificação `privado.exigir_conta_ativa()` roda no início da função, antes de
-- qualquer leitura de dados no banco, garantindo que um JWT emitido antes da exclusão
-- não consiga acessar números de telefone ou dados da contraparte.
-- O erro resultante para conta anonimizada é 401 nao_autenticado (e 403 sem_permissao
-- para suspensa), ambos já previstos e prometidos no contrato.

-- contrato: corpo-sem-mudanca-de-superficie public.contato_do_turno 0.2.33
create or replace function public.contato_do_turno(turno_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_pos    public.posicao%rowtype;
  v_estab  uuid;
  v_dono   uuid;
  v_sou_prof boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if contato_do_turno.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  select p.* into v_pos
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = contato_do_turno.turno_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Sem confirmação não há contrato a executar, e sem contrato a base legal não existe.
  if v_pos.estado not in ('confirmada', 'cumprida') then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_estab := privado.estabelecimento_da_vaga(v_pos.vaga_id);
  v_sou_prof := privado.usuario_do_profissional(v_pos.profissional_id) = v_uid;
  v_dono := privado.usuario_do_profissional(v_pos.profissional_id);

  -- Quem não é nenhum dos dois lados não fica sabendo que este turno existe.
  if not v_sou_prof and not privado.eh_membro(v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RF26. O bloqueio entre as partes fecha o contato nos dois sentidos, e responde o
  -- mesmo 404: quem bloqueou alguém não recebe prova de que a outra parte continua ali.
  if privado.bloqueado_com_estabelecimento(case when v_sou_prof then v_uid else v_dono end,
                                           v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RN10, pelo relógio do produto. O prazo é o mesmo que `meus_turnos` publica em
  -- `contato_visivel_ate`, para que a tela não precise pedir o contato só para
  -- descobrir se pode.
  if privado.agora() > v_pos.fim_em + interval '7 days' then
    perform public.erro(403, 'contato_expirado');
  end if;

  return case when v_sou_prof
              then privado.contato_do_estabelecimento(v_pos.vaga_id)
              else privado.contato_do_profissional(v_pos.id) end;
end $$;

comment on function public.contato_do_turno(uuid) is
  'Contato da outra parte do turno (RF11, RN10). Só depois da confirmação e só até 7 dias depois do fim; depois disso, 403 contato_expirado. Antes da confirmação, fora do turno ou com bloqueio entre as partes, 404. Conta inativa ou anonimizada é recusada no início (B10).';

revoke execute on function public.contato_do_turno(uuid) from public, anon;
grant execute on function public.contato_do_turno(uuid) to authenticated;
