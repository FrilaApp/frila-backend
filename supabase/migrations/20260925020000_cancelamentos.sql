-- `cancelar_posicao` e `cancelar_vaga`: desistir sem virar castigo.
--
-- Qualquer um dos dois lados cancela, com motivo (RN12). O que muda entre eles é o que
-- fica registrado: cancelamento do profissional com menos de 24 horas conta como falta
-- na taxa de comparecimento; com mais de 24 horas, sai da conta. O cancelamento do
-- contratante não gera falta para ninguém.
--
-- **Nenhum cancelamento muda o estado da conta** (RN13). Suspender por desistência
-- transformaria uma regra de reputação numa punição automática, e reputação com
-- denominador já diz o que precisa ser dito.
--
-- A posição cancelada **não volta** para `aberta`: ela guarda de quem foi a falta e
-- quem cancelou, que é o que RN12 exige registrar e a taxa de comparecimento precisa
-- ler. A vaga ganha uma posição **nova**, e é isso que `nova_posicao_id` devolve.

-- ── O registro do cancelamento ────────────────────────────────────────────────

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
begin
  select * into v_pos from public.posicao p where p.id = posicao;

  v_eh_prof := v_pos.profissional_id is not null
               and privado.usuario_do_profissional(v_pos.profissional_id) = autor;

  -- RN12. A falta é do profissional que desiste em cima da hora, e só dele: o
  -- contratante que cancela não gera falta para ninguém, e a posição que nunca foi
  -- confirmada não tem de quem ser falta.
  if v_eh_prof and v_pos.estado = 'confirmada'
     and v_pos.inicio_em - v_agora < interval '24 hours' then
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
    insert into public.posicao (vaga_id, inicio_em, fim_em)
    values (v_pos.vaga_id, v_pos.inicio_em, v_pos.fim_em)
    returning id into v_nova;

    -- A vaga estava `preenchida` e volta a ter posição aberta.
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

  return jsonb_build_object(
    'posicao_id',      posicao,
    'falta',           v_falta,
    'reaberta',        v_nova is not null,
    'nova_posicao_id', v_nova);
end $$;

comment on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean) is
  'Cancela uma posição, registra a ocorrência e, antes do início, cria a posição nova e enfileira o despacho da reabertura (RN12, RF14). A posição cancelada não volta para aberta: ela guarda de quem foi a falta.';

-- ── cancelar_posicao ──────────────────────────────────────────────────────────

create or replace function public.cancelar_posicao(posicao_id uuid, motivo text)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_motivo text := btrim(cancelar_posicao.motivo);
  v_pos    public.posicao%rowtype;
  v_estab  uuid;
  v_eh_prof boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if cancelar_posicao.posicao_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'posicao_id');
  end if;

  -- O motivo não é burocracia: ele é o que a outra parte lê, e o que a auditoria tem
  -- para distinguir o imprevisto do descaso. O contrato pede pelo menos três letras.
  if v_motivo is null or length(v_motivo) < 3 then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  if not privado.texto_aceitavel(v_motivo) then
    perform public.erro(422, 'campo_invalido', 'motivo');
  end if;

  select * into v_pos from public.posicao p where p.id = cancelar_posicao.posicao_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_estab := privado.estabelecimento_da_vaga(v_pos.vaga_id);
  v_eh_prof := v_pos.profissional_id is not null
               and privado.usuario_do_profissional(v_pos.profissional_id) = v_uid;

  if not v_eh_prof and not privado.eh_membro(v_estab) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_pos.estado <> 'confirmada' then
    -- Posição aberta não tem o que cancelar, e cumprida ou já cancelada não volta atrás.
    perform public.erro(409, 'posicao_nao_cancelavel');
  end if;

  return privado.cancelar_uma_posicao(cancelar_posicao.posicao_id, v_uid, v_motivo, true);
end $$;

comment on function public.cancelar_posicao(uuid, text) is
  'Cancela uma posição confirmada, de qualquer um dos dois lados, com motivo (RF14, RN12). Antes do início, a vaga ganha posição nova e o despacho sai de novo. Nenhum cancelamento muda o estado da conta (RN13).';

-- ── cancelar_vaga ─────────────────────────────────────────────────────────────
--
-- Só o contratante. O profissional que quer sair cancela a **própria posição**; cancelar
-- a vaga inteira tiraria o turno de outras pessoas.

create or replace function public.cancelar_vaga(vaga_id uuid, motivo text)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid    uuid := (select auth.uid());
  v_motivo text := btrim(cancelar_vaga.motivo);
  v        public.vaga%rowtype;
  v_pos    uuid;
  v_abertas int := 0;
  v_confirmadas int := 0;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('contratante');

  if cancelar_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;
  if v_motivo is null or length(v_motivo) < 3 then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;
  if not privado.texto_aceitavel(v_motivo) then
    perform public.erro(422, 'campo_invalido', 'motivo');
  end if;

  select * into v from public.vaga g where g.id = cancelar_vaga.vaga_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not privado.eh_membro(v.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v.estado in ('cancelada', 'encerrada') then
    perform public.erro(409, 'vaga_encerrada');
  end if;

  -- As confirmadas passam pelo mesmo caminho do cancelamento avulso, e **sem** reabrir:
  -- a vaga inteira está saindo do ar. Cancelamento pelo contratante não gera falta para
  -- ninguém, e é o autor que decide isso lá dentro.
  for v_pos in select p.id from public.posicao p
                where p.vaga_id = cancelar_vaga.vaga_id and p.estado = 'confirmada'
  loop
    perform privado.cancelar_uma_posicao(v_pos, v_uid, v_motivo, false);
    v_confirmadas := v_confirmadas + 1;
  end loop;

  update public.posicao p
     set estado = 'cancelada'
   where p.vaga_id = cancelar_vaga.vaga_id and p.estado = 'aberta';
  get diagnostics v_abertas = row_count;

  update public.vaga g set estado = 'cancelada' where g.id = cancelar_vaga.vaga_id;

  -- Os três campos do contrato, e só eles. `confirmadas_avisadas` seria informação
  -- útil e fora do schema: quem precisa saber quantas pessoas foram avisadas é o
  -- registro de ocorrência, não a resposta da chamada.
  return jsonb_build_object(
    'vaga_id',             v.id,
    'estado',              'cancelada',
    'posicoes_canceladas', v_abertas + v_confirmadas);
end $$;

comment on function public.cancelar_vaga(uuid, text) is
  'Cancela a vaga inteira, com motivo (RF14, RN12). Só o contratante membro da casa; as posições confirmadas são canceladas sem reabrir, e sem gerar falta para ninguém.';

revoke execute on function public.cancelar_posicao(uuid, text) from public, anon;
revoke execute on function public.cancelar_vaga(uuid, text)    from public, anon;
grant execute on function public.cancelar_posicao(uuid, text) to authenticated;
grant execute on function public.cancelar_vaga(uuid, text)    to authenticated;
