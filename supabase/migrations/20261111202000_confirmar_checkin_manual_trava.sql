-- Migração: 20261111202000_confirmar_checkin_manual_trava.sql
-- Escopo: B-CHECKIN-BACK, PR7 (contrato 0.2.69, `confirmarCheckinManual`, D8; plano em
-- orquestracao/retornos/B-CHECKIN-BACK-plano.md, seção 2, PR7).
--
-- A confirmação manual ganha a trava do turno (`for update`), como o gerar e o validar do código.
-- Sem ela, a confirmação que chega enquanto a validação do código ainda segura o turno lê o retrato
-- de antes (manual, sem confirmação), espera a linha e, liberada, sobrescreve checkin_confirmado_em,
-- a hora da validação: o READ COMMITTED reavalia só o `where t.id`, que continua valendo. Com a
-- trava, quem chega depois relê o turno já `codigo` e recebe 409 checkin_ja_confirmado (0.2.69).
-- A prova é a corrida de duas conexões (scripts/corrida-checkin-codigo.sh): o pgTAP roda numa
-- sessão só e não a enxerga.
--
-- O corpo é o da confirmar_manual_so_ate_o_fim.sql do frila-backend #477 (do JP, head 9074326), que traz a
-- trava de prazo: depois do fim_em da posição, ou com o turno já nao_verificado, a confirmação recusa
-- 422 fora_da_janela. Incorporada aqui a pedido do JP, no mesmo lugar e com o mesmo comportamento,
-- para a ordem das mesclas não mudar nada. Sobre ele, só mudam o `for update`, os comentários e o
-- comment, e a recusa da posição cancelada (409 vaga_encerrada, posicao_cancelada), dita antes da
-- trava para não virar 422. A prova da trava é o 847 (os casos do 846 do #477, mais a posição cancelada).
--
-- A superfície não muda: a 0.2.69, que descreve esta recusa, já está no espelho da base (0.2.73).
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

  -- A trava do turno, a mesma do gerar e do validar do código (0.2.69).
  select * into v_t from public.turno t where t.id = confirmar_checkin_manual.turno_id for update;

  if v_t.checkin_em is null then
    perform public.erro(409, 'checkin_pendente');
  end if;

  if v_t.checkin_tipo <> 'manual' then
    -- Check-in geolocalizado já nasceu verificado, e o do código já foi validado: não há o que
    -- confirmar, e a hora da validação não muda (0.2.69).
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

  -- Posição cancelada: a mesma recusa do gatilho turno_verificacao_nunca_em_posicao_cancelada
  -- (20260930141533), dita antes da trava de prazo. O cancelamento deixa o turno nao_verificado, e
  -- sem este passo a trava responderia 422 fora_da_janela no lugar do 409 que o 480 (RN22) prova.
  -- O gatilho continua no dado, para a escrita de serviço.
  if v_pos.estado = 'cancelada' then
    perform public.erro(409, 'vaga_encerrada', 'posicao_cancelada');
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
  'Contratante confirma check-in manual do profissional (RF20). Torna o turno verificado para fins de pagamento e avaliação. Exige conta ativa e confirmação até o fim_em do turno. Trava o turno (for update, 0.2.69): o turno já verificado pelo código, mesmo numa corrida com a validação, recusa 409 checkin_ja_confirmado e não muda a hora da validação.';

revoke execute on function public.confirmar_checkin_manual(uuid) from public, anon;
grant  execute on function public.confirmar_checkin_manual(uuid) to authenticated;
