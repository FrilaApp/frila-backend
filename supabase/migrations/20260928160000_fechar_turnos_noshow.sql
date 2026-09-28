-- S2 · Backend · Turnos não verificados, faltas e reconciliação da taxa de comparecimento
-- Critério 2 (Decisão 8zLfn0mt Opção 2): Turno confirmado sem check-in até o fim vira
-- cancelamento por no-show com falta.
--
-- Cartão: https://trello.com/c/NDx7TJ4d
-- Decisão: 8zLfn0mt — Opção 2 aprovada pela PO e liderança.
--
-- Redefine privado.fechar_turnos_passados() para incluir o passo 3:
--   posição confirmada cujo turno terminou sem check-in →
--     estado = 'cancelada', falta = true,
--     turno.verificacao = 'nao_verificado',
--     ocorrencia (tipo = 'cancelamento', motivo = 'no_show_sem_checkin'),
--     recalcula comparecimento.

create or replace function privado.fechar_turnos_passados()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora    timestamptz := privado.agora();
  v_profs    uuid[] := '{}'::uuid[];
  v_novos    uuid[];
  v_prof     uuid;
  v_afetados integer := 0;
begin
  perform set_config('frila.em_lote', 'true', true);

  -- 1. Check-in manual não confirmado até o fim do turno vira nao_verificado (Critério 1).
  with turnos_a_fechar as (
    select t.id, p.profissional_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
     where p.fim_em <= v_agora
       and t.verificacao = 'pendente'
       and t.checkin_tipo = 'manual'
  ),
  atualizados as (
    update public.turno t
       set verificacao = 'nao_verificado'
      from turnos_a_fechar taf
     where t.id = taf.id
    returning taf.profissional_id
  )
  select coalesce(
     array_agg(distinct profissional_id) filter (where profissional_id is not null),
     '{}'::uuid[]
  )
     into v_novos
     from atualizados;
  v_profs := v_profs || v_novos;
  v_afetados := v_afetados + cardinality(v_novos);

  -- 2. Transição de posição: confirmada -> cumprida quando o turno terminou e teve check-in registrado
  with posicoes_a_fechar as (
    select p.id, p.profissional_id
      from public.posicao p
      join public.turno t on t.posicao_id = p.id
     where p.estado = 'confirmada'
       and p.fim_em <= v_agora
       and t.checkin_em is not null
  ),
  pos_atualizadas as (
    update public.posicao p
       set estado = 'cumprida'
      from posicoes_a_fechar paf
     where p.id = paf.id
    returning paf.profissional_id
  )
  select coalesce(
     array_agg(distinct profissional_id) filter (where profissional_id is not null),
     '{}'::uuid[]
  )
     into v_novos
     from pos_atualizadas;
  v_profs := v_profs || v_novos;
  v_afetados := v_afetados + cardinality(v_novos);

  -- 3. Critério 2 (Decisão 8zLfn0mt Opção 2): Turno confirmado sem check-in até o fim vira cancelamento por no-show com falta
  with noshow_a_cancelar as (
    select p.id as posicao_id, p.profissional_id, t.id as turno_id
      from public.posicao p
      left join public.turno t on t.posicao_id = p.id
     where p.estado = 'confirmada'
       and p.fim_em <= v_agora
       and (t.checkin_em is null or t.id is null)
  ),
  canceladas as (
    update public.posicao p
       set estado = 'cancelada',
           falta  = true
      from noshow_a_cancelar n
     where p.id = n.posicao_id
    returning n.posicao_id, n.profissional_id, n.turno_id
  ),
  turnos_cancelados as (
    update public.turno t
       set verificacao = 'nao_verificado'
      from canceladas c
     where t.posicao_id = c.posicao_id
       and t.verificacao = 'pendente'
  ),
  ocorrencias_gravadas as (
    insert into public.ocorrencia (tipo, posicao_id, turno_id, usuario_id, autor_id, motivo)
    select 'cancelamento',
           c.posicao_id,
           c.turno_id,
           privado.usuario_do_profissional(c.profissional_id),
           privado.usuario_do_profissional(c.profissional_id),
           'no_show_sem_checkin'
      from canceladas c
     where c.profissional_id is not null
  )
  select coalesce(
     array_agg(distinct profissional_id) filter (where profissional_id is not null),
     '{}'::uuid[]
  )
     into v_novos
     from canceladas;
  v_profs := v_profs || v_novos;
  v_afetados := v_afetados + cardinality(v_novos);

  -- 4. Recalcula o histórico canônico UMA VEZ por profissional afetado no lote
  for v_prof in select distinct unnest(v_profs)
  loop
     perform privado.recalcular_comparecimento(v_prof);
  end loop;

  perform set_config('frila.em_lote', '', true);

  return v_afetados;
end $$;

comment on function privado.fechar_turnos_passados() is
  'Job pós-fim de turno: fecha check-ins manuais não confirmados como nao_verificado, cumpre turnos com presença e cancela turnos confirmados sem check-in por no-show (falta = true). Recalcula comparecimento.';

revoke execute on function privado.fechar_turnos_passados() from public, anon, authenticated;
grant execute on function privado.fechar_turnos_passados() to service_role;
