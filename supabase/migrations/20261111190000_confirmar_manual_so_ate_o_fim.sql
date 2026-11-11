-- ── Trava de prazo em confirmar_checkin_manual ──────────────────────────────────
--
-- public.confirmar_checkin_manual não tinha trava de prazo: a casa conseguia confirmar
-- a presença do profissional mesmo após o fim previsto do turno, inclusive depois que
-- o job privado.fechar_turnos_passados já havia marcado o turno como 'nao_verificado'.
--
-- Correção: recusa com 422 fora_da_janela se privado.agora() > fim_em da posição
-- OU se a verificação do turno já for 'nao_verificado'.
--
-- contrato: corpo-sem-mudanca-de-superficie public.confirmar_checkin_manual 0.2.73

create or replace function public.confirmar_checkin_manual(turno_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid uuid := (select auth.uid());
  v_pos public.posicao%rowtype;
  v_t   public.turno%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_conta_ativa();

  if confirmar_checkin_manual.turno_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'turno_id');
  end if;

  select p.* into v_pos
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where t.id = confirmar_checkin_manual.turno_id;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- RF20: quem confirma é a casa. O profissional que tentasse confirmar o próprio
  -- check-in manual estaria declarando a própria presença, que é exatamente o que o
  -- manual existe para evitar. Aqui é 403, e não 404: ele é parte do turno e sabe que
  -- ele existe — esconder não protegeria nada e confundiria a tela.
  if not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then
    perform public.erro(403, 'sem_permissao');
  end if;

  select * into v_t from public.turno t where t.id = confirmar_checkin_manual.turno_id;

  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  if v_t.checkin_tipo <> 'manual' then
    -- Check-in geolocalizado já nasceu verificado: não há o que confirmar.
    perform public.erro(409, 'checkin_ja_confirmado');
  end if;

  if v_t.checkin_confirmado_em is not null then
    return jsonb_build_object(
      'turno_id',      v_t.id,
      'tipo',          v_t.checkin_tipo,
      'verificacao',   v_t.verificacao,
      'registrado_em', v_t.checkin_em,
      'distancia_m',   v_t.checkin_distancia_m);
  end if;

  if privado.agora() > v_pos.fim_em or v_t.verificacao = 'nao_verificado' then
    perform public.erro(422, 'fora_da_janela');
  end if;

  update public.turno t
     set checkin_confirmado_em = privado.agora(),
         verificacao           = 'verificado'
   where t.id = confirmar_checkin_manual.turno_id
  returning * into v_t;

  perform privado.recalcular_comparecimento(v_pos.profissional_id);

  return jsonb_build_object(
    'turno_id',      v_t.id,
    'tipo',          v_t.checkin_tipo,
    'verificacao',   v_t.verificacao,
    'registrado_em', v_t.checkin_em,
    'distancia_m',   v_t.checkin_distancia_m);
end $$;

comment on function public.confirmar_checkin_manual(uuid) is
  'Contratante confirma check-in manual do profissional (RF20). Torna o turno verificado para fins de pagamento e avaliação. Exige conta ativa e confirmação até o fim_em do turno.';

revoke execute on function public.confirmar_checkin_manual(uuid) from public, anon;
grant  execute on function public.confirmar_checkin_manual(uuid) to authenticated;
