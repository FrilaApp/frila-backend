-- Corrige o relógio de privado.cancelamento_da_posicao (P1, develop vermelha):
-- Substitui now() por privado.agora() quando v_pos.confirmado_em é nulo e não há ocorrência.

create or replace function privado.cancelamento_da_posicao(posicao uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pos      record;
  v_oco      record;
  v_causa    text;
  v_motivo   text := null;
  v_falta    boolean;
  v_canc_em  timestamptz;
  v_prof_usr uuid;
begin
  select p.id, p.vaga_id, p.estado, p.profissional_id, p.falta, p.confirmado_em,
         v.estabelecimento_id
    into v_pos
    from public.posicao p
    join public.vaga v on v.id = p.vaga_id
   where p.id = posicao;

  if not found or v_pos.estado <> 'cancelada' or v_pos.profissional_id is null then
    return null;
  end if;

  v_falta := v_pos.falta;
  v_prof_usr := privado.usuario_do_profissional(v_pos.profissional_id);

  -- Ocorrência mais recente de cancelamento da posição
  select o.id, o.motivo, o.autor_id, o.criada_em
    into v_oco
    from public.ocorrencia o
   where o.posicao_id = v_pos.id
     and o.tipo = 'cancelamento'
   order by o.criada_em desc, o.id desc
   limit 1;

  if not found then
    return jsonb_build_object(
      'causa',        'outro',
      'falta',        v_falta,
      'motivo',       null,
      'cancelada_em', coalesce(v_pos.confirmado_em, privado.agora())
    );
  end if;

  v_canc_em := v_oco.criada_em;

  if v_oco.motivo = 'reabertura_por_atraso' then
    v_causa := 'reabertura_por_atraso';
    v_motivo := null;
  elsif v_oco.motivo = 'no_show_sem_checkin' then
    v_causa := 'no_show_sem_checkin';
    v_motivo := null;
  elsif v_oco.motivo in ('exclusão de conta', 'suspensão de conta', '[removido por exclusão de conta]') then
    v_causa := 'outro';
    v_motivo := null;
  elsif v_oco.motivo = 'vaga_cancelada' then
    v_causa := 'estabelecimento';
    v_motivo := null;
  elsif v_oco.autor_id = v_prof_usr then
    v_causa := 'profissional';
    v_motivo := v_oco.motivo;
  elsif exists (
    select 1
      from public.membro_estabelecimento m
     where m.estabelecimento_id = v_pos.estabelecimento_id
       and m.usuario_id = v_oco.autor_id
  ) then
    v_causa := 'estabelecimento';
    v_motivo := v_oco.motivo;
  else
    v_causa := 'outro';
    v_motivo := null;
  end if;

  return jsonb_build_object(
    'causa',        v_causa,
    'falta',        v_falta,
    'motivo',       v_motivo,
    'cancelada_em', v_canc_em
  );
end $$;

comment on function privado.cancelamento_da_posicao(uuid) is
  'Dedução canônica do cancelamento de uma posição (RN12). Usada pelo painel (com motivo) e pelo turno (sem motivo). Relógio 100% via privado.agora().';

revoke execute on function privado.cancelamento_da_posicao(uuid) from public, anon, authenticated;
grant  execute on function privado.cancelamento_da_posicao(uuid) to service_role;
