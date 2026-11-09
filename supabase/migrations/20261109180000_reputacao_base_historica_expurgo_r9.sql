-- Migração: 20261109180000_reputacao_base_historica_expurgo_r9.sql
-- Escopo: Reputação guarda a base histórica do que o expurgo de 5 anos apaga (R9, Modelagem A11, cartão 8KFuT8UP).
--
-- Aos 5 anos do fim do turno, o expurgo legal (CF art. 7º XXIX, CC art. 206 § 3º V, LGPD art. 16)
-- apaga turnos, posições expiradas e avaliações. Para preservar a reputação conquistada pelo
-- profissional, esta migração introduz a tabela privada de base histórica agregada e anonimizada
-- e atualiza a rotina de expurgo, a reconciliação diária e a leitura de perfil público para somarem
-- o histórico vivo a esses agregados históricos.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Tabela privado.profissional_reputacao_expurgada
-- ─────────────────────────────────────────────────────────────────────────────
-- Base agregada e anonimizada: NÃO contém colunas de id de turno, vaga, casa nem datas.
create table privado.profissional_reputacao_expurgada (
  profissional_id   uuid primary key references public.profissional(id) on delete cascade,
  turnos_realizados integer not null default 0,
  presencas         integer not null default 0,
  faltas            integer not null default 0,
  aval_positivas    integer not null default 0,
  aval_total        integer not null default 0,
  constraint turnos_realizados_nao_negativo check (turnos_realizados >= 0),
  constraint presencas_nao_negativo check (presencas >= 0),
  constraint faltas_nao_negativo check (faltas >= 0),
  constraint aval_positivas_nao_negativo check (aval_positivas >= 0),
  constraint aval_total_nao_negativo check (aval_total >= 0),
  constraint aval_coerente check (aval_positivas <= aval_total)
);

comment on table privado.profissional_reputacao_expurgada is
  'Base histórica agregada e anonimizada da reputação de profissionais expurgada aos 5 anos (R9, LGPD art. 16, Modelagem A11). Não contém ids de turno, vaga, estabelecimento nem datas.';

comment on column privado.profissional_reputacao_expurgada.profissional_id is
  'Profissional dono dos contadores históricos expurgados.';
comment on column privado.profissional_reputacao_expurgada.turnos_realizados is
  'Total acumulado de turnos realizados (verificados) já expurgados.';
comment on column privado.profissional_reputacao_expurgada.presencas is
  'Total acumulado de presenças já expurgadas (sinônimo de turnos realizados).';
comment on column privado.profissional_reputacao_expurgada.faltas is
  'Total acumulado de faltas de turnos/posições já expurgados.';
comment on column privado.profissional_reputacao_expurgada.aval_positivas is
  'Total acumulado de avaliações positivas de turnos já expurgados.';
comment on column privado.profissional_reputacao_expurgada.aval_total is
  'Total acumulado de avaliações recebidas de turnos já expurgados.';

revoke all on table privado.profissional_reputacao_expurgada from public, anon, authenticated;
grant all on table privado.profissional_reputacao_expurgada to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Atualização de privado.expurgar_turnos_antigos (acumulação R9 antes de apagar)
-- ─────────────────────────────────────────────────────────────────────────────
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
      count(*) filter (where pos.falta)::int as faltas
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
    aval_positivas,
    aval_total
  )
  select
    d.profissional_id,
    d.turnos_realizados,
    d.presencas,
    d.faltas,
    d.aval_positivas,
    d.aval_total
  from delta d
  where exists (select 1 from public.profissional p where p.id = d.profissional_id)
    and (d.turnos_realizados > 0 or d.presencas > 0 or d.faltas > 0 or d.aval_total > 0)
  on conflict (profissional_id) do update
  set turnos_realizados = privado.profissional_reputacao_expurgada.turnos_realizados + excluded.turnos_realizados,
      presencas         = privado.profissional_reputacao_expurgada.presencas + excluded.presencas,
      faltas            = privado.profissional_reputacao_expurgada.faltas + excluded.faltas,
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

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Atualização de privado.reconciliar_comparecimento (A11 canônico + R9)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.reconciliar_comparecimento()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_divergencias integer := 0;
  v_taxa_canonico numeric(4,3);
  v_turnos_canonico integer;
  v_faltas_canonico integer;
  v_aval_pos_canonico integer;
  v_aval_tot_canonico integer;
  v_agora timestamptz := privado.agora();
begin
  for r in
    select p.id,
           p.taxa_comparecimento,
           p.turnos_realizados,
           p.aval_positivas,
           p.aval_total
      from public.profissional p
  loop
    -- Definição canônica (A11 da Modelagem de Banco de Dados):
    -- Presença = check-in geolocalizado, manual confirmado ou código validado (RN22) -> t.verificacao = 'verificado'
    -- Falta = não aparecer ou cancelar com menos de 24 h -> pos.falta = true
    -- Numerador = turnos com presença (vivo + expurgado)
    -- Denominador = turnos com presença + faltas (vivo + expurgado)
    select
      coalesce(count(*) filter (where t.verificacao = 'verificado'), 0),
      coalesce(count(*) filter (where pos.falta), 0)
      into v_turnos_canonico, v_faltas_canonico
      from public.posicao pos
      left join public.turno t on t.posicao_id = pos.id
     where pos.profissional_id = r.id;

    -- Avaliações canônicas calculadas sobre o histórico vivo de avaliacao
    select
      coalesce(count(*) filter (where a.resposta), 0),
      coalesce(count(*), 0)
      into v_aval_pos_canonico, v_aval_tot_canonico
      from public.avaliacao a
     where a.alvo_tipo = 'profissional'
       and a.alvo_id = r.id;

    -- R9: Soma os contadores agregados da base histórica expurgada (aos 5 anos)
    select
      v_turnos_canonico + coalesce(h.turnos_realizados, 0),
      v_faltas_canonico + coalesce(h.faltas, 0),
      v_aval_pos_canonico + coalesce(h.aval_positivas, 0),
      v_aval_tot_canonico + coalesce(h.aval_total, 0)
      into v_turnos_canonico, v_faltas_canonico, v_aval_pos_canonico, v_aval_tot_canonico
      from (select 1) _
      left join privado.profissional_reputacao_expurgada h on h.profissional_id = r.id;

    if v_turnos_canonico + v_faltas_canonico = 0 then
      v_taxa_canonico := null;
    else
      v_taxa_canonico := round(v_turnos_canonico::numeric / (v_turnos_canonico + v_faltas_canonico), 3);
    end if;

    -- Compara cache desnormalizado com a fonte da verdade
    if r.taxa_comparecimento is distinct from v_taxa_canonico
       or r.turnos_realizados is distinct from v_turnos_canonico
       or r.aval_positivas is distinct from v_aval_pos_canonico
       or r.aval_total is distinct from v_aval_tot_canonico
    then
      -- 1. Registra a divergência encontrada
      insert into privado.divergencia_reputacao (
        profissional_id,
        taxa_anterior, taxa_corrigida,
        turnos_anterior, turnos_corrigido,
        aval_pos_anterior, aval_pos_corrigido,
        aval_tot_anterior, aval_tot_corrigido,
        registrado_em
      ) values (
        r.id,
        r.taxa_comparecimento, v_taxa_canonico,
        r.turnos_realizados, v_turnos_canonico,
        r.aval_positivas, v_aval_pos_canonico,
        r.aval_total, v_aval_tot_canonico,
        v_agora
      );

      -- 2. Atualiza o cache em profissional: o histórico canônico ganha
      update public.profissional
         set taxa_comparecimento = v_taxa_canonico,
             turnos_realizados   = v_turnos_canonico,
             aval_positivas      = v_aval_pos_canonico,
             aval_total          = v_aval_tot_canonico
       where id = r.id;

      v_divergencias := v_divergencias + 1;
    end if;
  end loop;

  return v_divergencias;
end $$;

comment on function privado.reconciliar_comparecimento() is
  'Job diário de reconciliação com a definição canônica da Modelagem (A11, R9). Compara o cache em profissional com o histórico vivo somado à base histórica expurgada (privado.profissional_reputacao_expurgada) e registra divergências.';

revoke execute on function privado.reconciliar_comparecimento() from public, anon, authenticated;
grant execute on function privado.reconciliar_comparecimento() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Atualização de privado.recalcular_comparecimento
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.recalcular_comparecimento(prof uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_verificados int;
  v_faltas      int;
  v_h_verif     int := 0;
  v_h_faltas    int := 0;
  v_tot_verif   int;
  v_tot_faltas  int;
begin
  select count(*) into v_verificados
    from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where p.profissional_id = prof and t.verificacao = 'verificado';

  select count(*) into v_faltas
    from public.posicao p
   where p.profissional_id = prof and p.falta;

  select coalesce(h.presencas, 0), coalesce(h.faltas, 0)
    into v_h_verif, v_h_faltas
    from privado.profissional_reputacao_expurgada h
   where h.profissional_id = prof;

  v_tot_verif := v_verificados + coalesce(v_h_verif, 0);
  v_tot_faltas := v_faltas + coalesce(v_h_faltas, 0);

  update public.profissional
     set turnos_realizados = v_tot_verif,
         taxa_comparecimento = case when v_tot_verif + v_tot_faltas = 0 then null
                                    else round(v_tot_verif::numeric
                                               / (v_tot_verif + v_tot_faltas), 3) end
   where id = prof;
end $$;

comment on function privado.recalcular_comparecimento(uuid) is
  'Recalcula turnos_realizados e taxa_comparecimento somando histórico vivo e base histórica expurgada (A11, R9).';

revoke execute on function privado.recalcular_comparecimento(uuid) from public, anon, authenticated;
grant execute on function privado.recalcular_comparecimento(uuid) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Atualização de privado.perfil_publico_profissional
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.perfil_publico_profissional(prof uuid)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid         uuid := (select auth.uid());
  v_res         jsonb;
  p             public.profissional%rowtype;
  u             public.usuario%rowtype;
  v_tem_f2      boolean;
  v_bloqueado   boolean;
begin
  select * into p from public.profissional where id = prof;
  if not found then return null; end if;
  select * into u from public.usuario where id = p.usuario_id;

  v_res := jsonb_build_object(
    'id',   p.id,
    'tipo', 'profissional',
    'nome', case when u.estado = 'anonimizada' then 'Conta encerrada' else u.nome end,
    'funcoes', coalesce((select jsonb_agg(f.nome order by f.nome)
                           from public.profissional_funcao pf
                           join public.funcao f on f.id = pf.funcao_id
                          where pf.profissional_id = p.id), '[]'::jsonb),
    'reputacao', jsonb_build_object(
      'positivas',           p.aval_positivas,
      'total',               p.aval_total,
      'taxa_comparecimento', p.taxa_comparecimento,
      'turnos_realizados',   p.turnos_realizados,
      'turnos_considerados', p.turnos_realizados
                             + (select count(*) from public.posicao x
                                 where x.profissional_id = p.id and x.falta)
                             + coalesce((select h.faltas
                                           from privado.profissional_reputacao_expurgada h
                                          where h.profissional_id = p.id), 0))
  );

  -- Bloqueio mútuo em qualquer direção com o leitor ou estabelecimentos do leitor:
  if v_uid is not null then
    v_bloqueado := exists (
      select 1 from public.bloqueio b
       where (b.autor_id = v_uid and b.bloqueado_id = p.usuario_id)
          or (b.autor_id = p.usuario_id and b.bloqueado_id = v_uid)
    ) or exists (
      select 1 from public.membro_estabelecimento me
       where me.usuario_id = v_uid
         and privado.bloqueado_com_estabelecimento(p.usuario_id, me.estabelecimento_id)
    );
  else
    v_bloqueado := false;
  end if;

  -- Se o alvo NÃO está anonimizado/encerrado, o leitor está autenticado,
  -- NÃO há bloqueio mútuo, o leitor possui vínculo legítimo e o profissional preencheu dados F2:
  -- Perfil rico desligado (contrato 0.2.60): PerfilPublico só com a base, sem os campos da F2.
  if u.estado <> 'anonimizada'
     and privado.recurso_ligado('perfil_rico')
     and v_uid is not null
     and not v_bloqueado
     and privado.contratante_com_vinculo_leitura(p.id, v_uid) then

    v_tem_f2 := (
      p.apresentacao is not null
      or p.onde_trabalhei is not null
      or p.experiencia_faixa is not null
      or (p.cursos is not null and cardinality(p.cursos) > 0)
      or (p.idiomas is not null and cardinality(p.idiomas) > 0)
      or p.atende_todo_df
      or exists (select 1 from public.profissional_servico where profissional_id = p.id)
      or exists (select 1 from public.profissional_regiao where profissional_id = p.id)
    );

    if v_tem_f2 then
      v_res := v_res || jsonb_build_object(
        'apresentacao', p.apresentacao,
        'onde_trabalhei', p.onde_trabalhei,
        'experiencia_faixa', p.experiencia_faixa,
        'cursos', to_jsonb(coalesce(p.cursos, '{}'::text[])),
        'idiomas', to_jsonb(coalesce(p.idiomas, '{}'::text[])),
        'atende_todo_df', p.atende_todo_df,
        'no_frila_desde', to_char(u.criado_em, 'YYYY-MM'),
        'regioes', coalesce((select jsonb_agg(to_jsonb(r) order by r.id)
                               from public.profissional_regiao pr
                               join public.regiao_administrativa r on r.id = pr.regiao_id
                              where pr.profissional_id = p.id), '[]'::jsonb),
        'servicos', coalesce((select jsonb_agg(jsonb_strip_nulls(to_jsonb(s) - array['profissional_id','funcao_id','extras','atualizado_em']) ||
                             jsonb_build_object('funcao', to_jsonb(f) - 'ativo', 'especialidades', coalesce((select jsonb_agg(to_jsonb(e) order by e.nome)
                               from public.profissional_servico_especialidade se join public.especialidade e on e.id = se.especialidade_id
                               where se.profissional_id = s.profissional_id and se.funcao_id = s.funcao_id), '[]'::jsonb)) order by f.nome)
                             from public.profissional_servico s join public.funcao f on f.id = s.funcao_id
                            where s.profissional_id = p.id), '[]'::jsonb)
      );
    end if;
  end if;

  return v_res;
end $$;

comment on function privado.perfil_publico_profissional(uuid) is
  'Gera o json de perfil público de profissional, somando histórico vivo e base histórica expurgada (R9). Inclui campos F2 se recurso perfil_rico estiver ligado e houver vínculo legítimo.';

revoke execute on function privado.perfil_publico_profissional(uuid) from public, anon;
grant execute on function privado.perfil_publico_profissional(uuid) to authenticated, service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Atualização de public.perfil_publico
-- ─────────────────────────────────────────────────────────────────────────────
-- contrato: corpo-sem-mudanca-de-superficie public.perfil_publico 0.2.68
create or replace function public.perfil_publico(id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid       uuid := (select auth.uid());
  v_prof_user uuid;
  v_perfil    jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'anonimizada') then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- 1. Perfil profissional
  v_prof_user := privado.usuario_do_profissional(perfil_publico.id);
  if v_prof_user is not null then
    -- RF26: bloqueio nos dois sentidos entre quem chama e o profissional,
    -- ou entre o profissional e qualquer estabelecimento do qual quem chama é membro.
    if exists (
      select 1 from public.bloqueio b
       where (b.autor_id = v_uid and b.bloqueado_id = v_prof_user)
          or (b.autor_id = v_prof_user and b.bloqueado_id = v_uid)
    ) or exists (
      select 1 from public.membro_estabelecimento m
       where m.usuario_id = v_uid
         and privado.bloqueado_com_estabelecimento(v_prof_user, m.estabelecimento_id)
    ) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.perfil_publico_profissional(perfil_publico.id);

  -- 2. Perfil de estabelecimento
  elsif exists (select 1 from public.estabelecimento e where e.id = perfil_publico.id) then
    -- RF26: bloqueio com qualquer membro do estabelecimento nos dois sentidos.
    if privado.bloqueado_com_estabelecimento(v_uid, perfil_publico.id) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.estabelecimento_publico(perfil_publico.id);
  end if;

  -- 3. Id que não é profissional nem estabelecimento (ou não encontrado)
  if v_perfil is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return v_perfil;
end $$;

comment on function public.perfil_publico(uuid) is
  'Perfil público de profissional ou estabelecimento por id. Profissional reflete histórico vivo e base histórica expurgada (R9). Devolve 404 para id inexistente e para bloqueio mútuo.';

revoke execute on function public.perfil_publico(uuid) from public, anon;
grant  execute on function public.perfil_publico(uuid) to authenticated;
