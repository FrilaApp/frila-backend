-- Histórico de faltas por tipo só para o titular. Aguarda desenho do Fabrício.
-- Não muda regra de falta, taxa, perfil público ou autorização de anulação.
-- R9 agregado sem tipos só é migrável se não houver faltas já expurgadas.
-- Se houver, falha em vez de inventar classificação: exige investigação antes do deploy.
do $$ begin
  if exists (select 1 from privado.profissional_reputacao_expurgada where faltas <> 0) then
    raise exception 'R9 contém faltas sem tipo; investigar antes de aplicar histórico tipado';
  end if;
end $$;

alter table privado.profissional_reputacao_expurgada
  add column nao_compareceu integer not null default 0,
  add column cancelou_menos_24h integer not null default 0,
  add constraint faltas_tipos_nao_negativos check (nao_compareceu >= 0 and cancelou_menos_24h >= 0),
  add constraint faltas_tipos_coerentes check (faltas = nao_compareceu + cancelou_menos_24h);

-- Reutiliza a classificação canônica e a flag vigente: anulação retira a falta.
create or replace function privado.tipo_da_falta(posicao uuid)
returns text language sql stable security definer set search_path = '' as $$
  select case when not p.falta then null
    when privado.cancelamento_da_posicao(p.id)->>'causa' in ('no_show_sem_checkin', 'reabertura_por_atraso')
      then 'nao_compareceu'
    when privado.cancelamento_da_posicao(p.id)->>'causa' = 'profissional' then 'cancelou_menos_24h'
    else null end
  from public.posicao p where p.id = posicao
$$;
revoke all on function privado.tipo_da_falta(uuid) from public, anon, authenticated;
grant execute on function privado.tipo_da_falta(uuid) to service_role;

create or replace function privado.historico_faltas(prof uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'nao_compareceu', (select count(*) from public.posicao p
      where p.profissional_id = prof and privado.tipo_da_falta(p.id) = 'nao_compareceu')
      + coalesce((select h.nao_compareceu from privado.profissional_reputacao_expurgada h where h.profissional_id = prof), 0),
    'cancelou_menos_24h', (select count(*) from public.posicao p
      where p.profissional_id = prof and privado.tipo_da_falta(p.id) = 'cancelou_menos_24h')
      + coalesce((select h.cancelou_menos_24h from privado.profissional_reputacao_expurgada h where h.profissional_id = prof), 0))
$$;
revoke all on function privado.historico_faltas(uuid) from public, anon, authenticated;
grant execute on function privado.historico_faltas(uuid) to service_role;

create or replace function public.perfil_profissional_em_json(prof public.profissional)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id',         prof.id,
    'usuario_id', prof.usuario_id,
    'ponto_base', privado.ponto_em_json(prof.ponto_base),
    'funcoes', coalesce(
      (select jsonb_agg(jsonb_build_object('id', f.id, 'nome', f.nome, 'categoria', f.categoria)
                        order by f.nome)
         from public.profissional_funcao pf
         join public.funcao f on f.id = pf.funcao_id
        where pf.profissional_id = prof.id), '[]'::jsonb),
    'disponibilidades', coalesce(
      (select jsonb_agg(jsonb_build_object(
                'dia_semana',  d.dia_semana,
                'hora_inicio', to_char(d.hora_inicio, 'HH24:MI'),
                'hora_fim',    to_char(d.hora_fim,    'HH24:MI'))
                order by d.dia_semana, d.hora_inicio)
         from public.disponibilidade d
        where d.profissional_id = prof.id), '[]'::jsonb),
    'historico_faltas', privado.historico_faltas(prof.id),
    'reputacao', jsonb_build_object(
      'positivas',           prof.aval_positivas,
      'total',               prof.aval_total,
      'taxa_comparecimento', prof.taxa_comparecimento,
      'turnos_considerados', prof.turnos_realizados
                             + (select count(*) from public.posicao p
                                 where p.profissional_id = prof.id and p.falta),
      'turnos_realizados',   prof.turnos_realizados))
$$;

revoke execute on function public.perfil_profissional_em_json(public.profissional)
  from public, anon, authenticated;


create or replace function privado.expurgar_turnos_antigos(
  p_anos integer default 5,
  p_limite integer default 500
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite_data       timestamptz;
  v_turnos_ids        uuid[];
  v_posicoes_ids      uuid[];
  v_vagas_candidatas  uuid[];
  v_vagas_expiradas   uuid[];
  v_candidaturas_ids  uuid[];
  v_avaliacoes_ids    uuid[];
  v_total             integer := 0;
begin
  -- Salvaguarda: piso de 5 anos, que nenhum parâmetro encurta
  if p_anos is null or p_anos < 5 then
    p_anos := 5;
  end if;
  if p_limite is null or p_limite < 1 then
    p_limite := 500;
  end if;

  -- Calendário civil (anos bissextos incluídos)
  v_limite_data := privado.agora() - (p_anos || ' years')::interval;

  -- Lote limitado, travando os turnos com FOR UPDATE SKIP LOCKED
  select coalesce(array_agg(sub.id), '{}'),
         coalesce(array_agg(sub.posicao_id), '{}'),
         coalesce(array_agg(distinct sub.vaga_id), '{}')
    into v_turnos_ids, v_posicoes_ids, v_vagas_candidatas
    from (
      select t.id, t.posicao_id, pos.vaga_id
        from public.turno t
        join public.posicao pos on pos.id = t.posicao_id
       where pos.fim_em <= v_limite_data
       order by pos.fim_em asc
       limit p_limite
       for update of t skip locked
    ) sub;

  if cardinality(v_turnos_ids) = 0 then
    return 0;
  end if;

  perform set_config('privado.retencao', 'on', true);

  -- R9: acumula contadores de reputação na base histórica expurgada antes de apagar
  with dados_turno as (
    select
      pos.profissional_id,
      count(*) filter (where t.verificacao = 'verificado')::int as presencas,
      count(*) filter (where pos.falta)::int as faltas,
      count(*) filter (where privado.tipo_da_falta(pos.id) = 'nao_compareceu')::int as nao_compareceu,
      count(*) filter (where privado.tipo_da_falta(pos.id) = 'cancelou_menos_24h')::int as cancelou_menos_24h
    from public.turno t
    join public.posicao pos on pos.id = t.posicao_id
    where t.id = any(v_turnos_ids)
      and pos.profissional_id is not null
    group by pos.profissional_id
  ),
  dados_aval as (
    select
      a.alvo_id as profissional_id,
      count(*) filter (where a.resposta)::int as aval_positivas,
      count(*)::int as aval_total
    from public.avaliacao a
    where a.turno_id = any(v_turnos_ids)
      and a.alvo_tipo = 'profissional'
    group by a.alvo_id
  ),
  delta as (
    select
      coalesce(t.profissional_id, a.profissional_id) as profissional_id,
      coalesce(t.presencas, 0) as turnos_realizados,
      coalesce(t.presencas, 0) as presencas,
      coalesce(t.faltas, 0) as faltas,
      coalesce(t.nao_compareceu, 0) as nao_compareceu,
      coalesce(t.cancelou_menos_24h, 0) as cancelou_menos_24h,
      coalesce(a.aval_positivas, 0) as aval_positivas,
      coalesce(a.aval_total, 0) as aval_total
    from dados_turno t
    full outer join dados_aval a on a.profissional_id = t.profissional_id
  )
  insert into privado.profissional_reputacao_expurgada (
    profissional_id,
    turnos_realizados,
    presencas,
    faltas,
    nao_compareceu,
    cancelou_menos_24h,
    aval_positivas,
    aval_total
  )
  select
    d.profissional_id,
    d.turnos_realizados,
    d.presencas,
    d.faltas,
    d.nao_compareceu,
    d.cancelou_menos_24h,
    d.aval_positivas,
    d.aval_total
  from delta d
  where exists (select 1 from public.profissional p where p.id = d.profissional_id)
    and (d.turnos_realizados > 0 or d.presencas > 0 or d.faltas > 0 or d.aval_total > 0)
  on conflict (profissional_id) do update
  set turnos_realizados = privado.profissional_reputacao_expurgada.turnos_realizados + excluded.turnos_realizados,
      presencas         = privado.profissional_reputacao_expurgada.presencas + excluded.presencas,
      faltas            = privado.profissional_reputacao_expurgada.faltas + excluded.faltas,
      nao_compareceu    = privado.profissional_reputacao_expurgada.nao_compareceu + excluded.nao_compareceu,
      cancelou_menos_24h = privado.profissional_reputacao_expurgada.cancelou_menos_24h + excluded.cancelou_menos_24h,
      aval_positivas    = privado.profissional_reputacao_expurgada.aval_positivas + excluded.aval_positivas,
      aval_total        = privado.profissional_reputacao_expurgada.aval_total + excluded.aval_total;

  select coalesce(array_agg(c.id), '{}')
    into v_candidaturas_ids
    from public.candidatura c
   where c.posicao_id = any(v_posicoes_ids);

  select coalesce(array_agg(a.id), '{}')
    into v_avaliacoes_ids
    from public.avaliacao a
   where a.turno_id = any(v_turnos_ids);

  -- R7: trilha do turno, da posição, das candidaturas e das avaliações que saem
  delete from privado.auditoria_ciclo
   where (entidade = 'turno' and entidade_id = any(v_turnos_ids))
      or (entidade = 'posicao' and entidade_id = any(v_posicoes_ids))
      or (entidade = 'candidatura' and entidade_id = any(v_candidaturas_ids))
      or (entidade = 'avaliacao' and entidade_id = any(v_avaliacoes_ids));

  -- Desvincula ocorrências antes de apagar o turno e a posição (FKs)
  update public.ocorrencia
     set turno_id = null
   where turno_id = any(v_turnos_ids);

  update public.ocorrencia
     set posicao_id = null
   where posicao_id = any(v_posicoes_ids);

  -- A posição reaberta por atraso aponta para a original (FK sem ON DELETE). Sem desfazer o
  -- vínculo, apagar a original derrubaria o lote e, com ele, a rotina diária inteira.
  update public.posicao
     set reaberta_por_atraso_de = null
   where reaberta_por_atraso_de = any(v_posicoes_ids)
     and not (id = any(v_posicoes_ids));

  -- Turnos: avaliacao sai em cascata; evento_app vira NULL
  delete from public.turno
   where id = any(v_turnos_ids);

  get diagnostics v_total = row_count;

  -- Posições dos turnos expurgados: candidatura sai em cascata
  delete from public.posicao
   where id = any(v_posicoes_ids);

  -- R1 a R5: vaga do lote que expirou de vez, travada sem esperar quem a segura
  select coalesce(array_agg(sub.id), '{}')
    into v_vagas_expiradas
    from (
      select v.id
        from public.vaga v
       where v.id = any(v_vagas_candidatas)
         and privado.vaga_expirada(v.id, v_limite_data)
       order by v.id
       for update of v skip locked
    ) sub;

  perform privado.anonimizar_contexto_das_vagas(v_vagas_expiradas);

  perform set_config('privado.retencao', 'off', true);
  return v_total;
end $$;

comment on function privado.expurgar_turnos_antigos(integer, integer) is
  'Expurga turnos concluídos há mais de 5 anos (calendário civil, piso não encurtável) em lotes com SKIP LOCKED: consolida os contadores na base histórica privada (privado.profissional_reputacao_expurgada, R9) antes de apagar turno, avaliação, posição, candidatura e a trilha de todos eles; desliga a ocorrência e anonimiza o contexto da vaga que expirou de vez. Os contadores de reputação do profissional ficam: o expurgo não recalcula (R9), e a reconciliação diária soma o histórico vivo com a base expurgada (cartão 8KFuT8UP). CF art. 7º XXIX, CC art. 206 § 3º V, LGPD art. 16.';

revoke all on function privado.expurgar_turnos_antigos(integer, integer) from public, anon, authenticated;
grant execute on function privado.expurgar_turnos_antigos(integer, integer) to service_role;


comment on column privado.profissional_reputacao_expurgada.nao_compareceu is
  'Faltas expurgadas por no-show ou reabertura por atraso, sem contexto de turno.';
comment on column privado.profissional_reputacao_expurgada.cancelou_menos_24h is
  'Faltas expurgadas por desistência do profissional a menos de 24 horas.';
