-- Migração: 20261108100000_lgpd_j6_fase2_contexto_expurgado.sql
-- Escopo: LGPD-J6, fase 2 (cartão BewEzEOJ). Depois de 5 anos do fim do turno, nada no banco
-- liga o profissional ao endereço ou à casa daquele turno.
--
-- A 20261108030000 (#429) apaga turno, avaliação, posição e candidatura aos 5 anos, mas deixava
-- o contexto: endereço e texto livre da vaga, chamada aceita, despacho, ocorrência e trilha
-- (bloqueio B3 do Lince Codex no #429; inventário em orquestracao/lancamento-1-1/j6-fase-2-residuos.md).
-- Base: J6 põe "turno, inclusive trilha de estados, endereço do local" nos 5 anos (CF art. 7º XXIX,
-- CC art. 206 § 3º V); passado o prazo, LGPD art. 16 manda eliminar ou anonimizar.
--
-- Decisões do Cauê de 08/11/2026 (brief B-T5):
--   R6  ocorrência de denúncia e cancelamento fica 5 anos; depois o relato vira NULL e o motivo
--       vira 'Expurgado (LGPD)'. Não é o '[removido por exclusão de conta]' da exclusão: numa
--       conta ativa ele seria falso, e o motivo sai na exportação de dados do titular.
--   R7  a trilha (privado.auditoria_ciclo) sai junto com a entidade expurgada.
--   R9  os contadores de reputação do profissional ficam: o expurgo não recalcula. A
--       reconciliação diária ainda recalcula do histórico; isso é o cartão 8KFuT8UP.
--   Q3  a posição que nunca virou turno, na vaga expirada, sai com as candidaturas e a trilha.
--
-- Os dois marcadores, 'Expurgado (LGPD)' e '[removido por exclusão de conta]', valem como já
-- anonimizado. Sem isso, esta rotina e privado.limpar_contas_anonimizadas (que reescreve todo
-- motivo e todo local diferentes do marcador dela) desfariam uma à outra todos os dias.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. O ponto neutro fixo
-- ─────────────────────────────────────────────────────────────────────────────
-- vaga.ponto é NOT NULL (RN02) e assim fica. O ponto expurgado é um só para todas as vagas,
-- num lugar público: a Rodoviária do Plano Piloto. Não é endereço de ninguém e não carrega a
-- região da vaga original.
create or replace function privado.ponto_expurgado()
returns extensions.geography
language sql
immutable
set search_path = ''
as $$
  select 'SRID=4326;POINT(-47.8825 -15.7942)'::extensions.geography
$$;

comment on function privado.ponto_expurgado() is
  'Ponto neutro fixo que substitui vaga.ponto quando a vaga expira (LGPD-J6 fase 2). Rodoviária do Plano Piloto: lugar público, igual para todas as vagas. vaga.ponto continua NOT NULL (RN02).';

revoke all on function privado.ponto_expurgado() from public, anon, authenticated;
grant execute on function privado.ponto_expurgado() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Vaga expirada
-- ─────────────────────────────────────────────────────────────────────────────
-- Expirada: a vaga e todas as posições dela terminaram até p_limite, e nenhum turno sobra nela.
-- O turno é expurgado primeiro (privado.expurgar_turnos_antigos); a vaga só expira depois, para
-- que a anonimização nunca alcance o contexto de um turno que ainda está no prazo.
create or replace function privado.vaga_expirada(p_vaga uuid, p_limite timestamptz)
returns boolean
language sql
stable
set search_path = ''
as $$
  select exists (
    select 1
      from public.vaga v
     where v.id = p_vaga
       and v.fim_em <= p_limite
       and not exists (select 1 from public.posicao p
                        where p.vaga_id = v.id and p.fim_em > p_limite)
       and not exists (select 1 from public.posicao p
                         join public.turno t on t.posicao_id = p.id
                        where p.vaga_id = v.id)
  )
$$;

comment on function privado.vaga_expirada(uuid, timestamptz) is
  'Verdadeiro quando a vaga e todas as posições dela terminaram até p_limite e nenhum turno sobra nela (LGPD-J6 fase 2).';

revoke all on function privado.vaga_expirada(uuid, timestamptz) from public, anon, authenticated;
grant execute on function privado.vaga_expirada(uuid, timestamptz) to service_role;

-- Anonimiza o contexto das vagas recebidas que estão expiradas há 5 anos; as outras são
-- ignoradas, então nenhum chamador consegue encurtar o prazo por aqui. Quem chama já travou as
-- linhas da vaga (FOR UPDATE SKIP LOCKED).
create or replace function privado.anonimizar_contexto_das_vagas(p_vagas uuid[])
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_retencao_antes text := current_setting('privado.retencao', true);
  v_limite_data    timestamptz := privado.agora() - interval '5 years';
  v_vagas          uuid[];
  v_posicoes       uuid[];
  v_candidaturas   uuid[];
  v_total          integer := 0;
begin
  select coalesce(array_agg(v.id), '{}')
    into v_vagas
    from public.vaga v
   where v.id = any(p_vagas)
     and privado.vaga_expirada(v.id, v_limite_data);

  if cardinality(v_vagas) = 0 then
    return 0;
  end if;

  perform set_config('privado.retencao', 'on', true);

  -- Q3: posição que nunca virou turno (aberta, ou cancelada sem confirmação). A com falta fica:
  -- ela entra na leitura de reputação (perfil_publico) e falta sem turno não acontece no fluxo.
  select coalesce(array_agg(p.id), '{}')
    into v_posicoes
    from public.posicao p
   where p.vaga_id = any(v_vagas)
     and not p.falta
     and not exists (select 1 from public.turno t where t.posicao_id = p.id);

  select coalesce(array_agg(c.id), '{}')
    into v_candidaturas
    from public.candidatura c
   where c.posicao_id = any(v_posicoes);

  -- R3/R7: trilha da vaga, das posições sem turno e das candidaturas delas.
  delete from privado.auditoria_ciclo a
   where (a.entidade = 'vaga' and a.entidade_id = any(v_vagas))
      or (a.entidade = 'posicao' and a.entidade_id = any(v_posicoes))
      or (a.entidade = 'candidatura' and a.entidade_id = any(v_candidaturas));

  update public.ocorrencia
     set posicao_id = null
   where posicao_id = any(v_posicoes);

  update public.posicao
     set reaberta_por_atraso_de = null
   where reaberta_por_atraso_de = any(v_posicoes)
     and not (id = any(v_posicoes));

  -- As candidaturas vão em cascata (candidatura_posicao_id_fkey).
  delete from public.posicao
   where id = any(v_posicoes);

  -- R4: a chamada aceita virou turno, e o turno já saiu. As não aceitas saem aos 90 dias
  -- (privado.limpar_chamadas_expurgadas); a que sobrar aqui sai junto.
  delete from public.chamada
   where vaga_id = any(v_vagas);

  -- R5: quem foi avisado de qual vaga. Imutável: passa pela exceção privado.retencao.
  delete from public.despacho
   where vaga_id = any(v_vagas);

  -- R3: ocultações da moderação. O texto original guardado aqui sai também.
  delete from privado.vaga_ocultada
   where vaga_id = any(v_vagas);

  delete from privado.texto_da_vaga_ocultado
   where vaga_id = any(v_vagas);

  -- R1/R2: endereço, ponto e texto livre. publicado_por e estabelecimento_id ficam (FK NOT NULL).
  update public.vaga v
     set local             = case when v.local in ('Expurgado (LGPD)', '[removido por exclusão de conta]')
                                  then v.local else 'Expurgado (LGPD)' end,
         responsavel_local = case when v.responsavel_local in ('Expurgado (LGPD)', '[removido por exclusão de conta]')
                                  then v.responsavel_local else 'Expurgado (LGPD)' end,
         observacoes       = null,
         traje             = null,
         ponto             = privado.ponto_expurgado()
   where v.id = any(v_vagas);

  get diagnostics v_total = row_count;

  perform set_config('privado.retencao', coalesce(nullif(v_retencao_antes, ''), 'off'), true);
  return v_total;
end $$;

comment on function privado.anonimizar_contexto_das_vagas(uuid[]) is
  'Anonimiza o contexto das vagas expiradas há 5 anos (LGPD-J6 fase 2): local e responsavel_local viram marcador, observacoes e traje viram NULL, ponto vira o ponto neutro; apaga chamada, despacho, ocultações, posições sem turno (candidaturas em cascata) e a trilha delas. Ignora vaga que não está expirada. Uso interno do expurgo.';

revoke all on function privado.anonimizar_contexto_das_vagas(uuid[]) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Expurgo de turnos: trilha completa e vínculo da reabertura
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
  'Expurga turnos concluídos há mais de 5 anos (calendário civil, piso não encurtável) em lotes com SKIP LOCKED: apaga turno, avaliação, posição, candidatura e a trilha de todos eles, desliga a ocorrência e anonimiza o contexto da vaga que expirou de vez (privado.anonimizar_contexto_das_vagas). Os contadores de reputação do profissional (turnos_realizados, taxa_comparecimento, aval_positivas, aval_total) ficam: o expurgo não recalcula (R9). A reconciliação diária ainda recalcula do histórico (cartão 8KFuT8UP). CF art. 7º XXIX, CC art. 206 § 3º V, LGPD art. 16.';

revoke all on function privado.expurgar_turnos_antigos(integer, integer) from public, anon, authenticated;
grant execute on function privado.expurgar_turnos_antigos(integer, integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Expurgo de vagas: com ou sem turno
-- ─────────────────────────────────────────────────────────────────────────────
-- O expurgo de turnos só alcança a vaga que tinha turno no lote. Este pega as outras: vaga que
-- nunca virou turno, vaga cujo turno saiu num lote anterior e vaga que ficou presa por trava.
create or replace function privado.expurgar_vagas_antigas(
  p_anos integer default 5,
  p_limite integer default 500
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite_data timestamptz;
  v_vagas       uuid[];
begin
  if p_anos is null or p_anos < 5 then
    p_anos := 5;
  end if;
  if p_limite is null or p_limite < 1 then
    p_limite := 500;
  end if;

  v_limite_data := privado.agora() - (p_anos || ' years')::interval;

  -- Só a vaga que ainda tem contexto: a já anonimizada não volta ao lote.
  select coalesce(array_agg(sub.id), '{}')
    into v_vagas
    from (
      select v.id
        from public.vaga v
       where v.fim_em <= v_limite_data
         and privado.vaga_expirada(v.id, v_limite_data)
         and (
           v.local not in ('Expurgado (LGPD)', '[removido por exclusão de conta]')
           or v.responsavel_local not in ('Expurgado (LGPD)', '[removido por exclusão de conta]')
           or v.observacoes is not null
           or v.traje is not null
           or v.ponto::text <> privado.ponto_expurgado()::text
           or exists (select 1 from public.chamada c where c.vaga_id = v.id)
           or exists (select 1 from public.despacho d where d.vaga_id = v.id)
           or exists (select 1 from privado.vaga_ocultada o where o.vaga_id = v.id)
           or exists (select 1 from privado.texto_da_vaga_ocultado o where o.vaga_id = v.id)
           or exists (select 1 from privado.auditoria_ciclo a
                       where a.entidade = 'vaga' and a.entidade_id = v.id)
           or exists (select 1 from public.posicao p
                       where p.vaga_id = v.id and not p.falta
                         and not exists (select 1 from public.turno t where t.posicao_id = p.id))
         )
       order by v.fim_em asc, v.id
       limit p_limite
       for update of v skip locked
    ) sub;

  return privado.anonimizar_contexto_das_vagas(v_vagas);
end $$;

comment on function privado.expurgar_vagas_antigas(integer, integer) is
  'Anonimiza, em lotes com SKIP LOCKED, o contexto das vagas cujas posições terminaram todas há mais de 5 anos, com ou sem turno (LGPD-J6 fase 2, R1 a R5). Piso de 5 anos não encurtável; a vaga já anonimizada não volta ao lote.';

revoke all on function privado.expurgar_vagas_antigas(integer, integer) from public, anon, authenticated;
grant execute on function privado.expurgar_vagas_antigas(integer, integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Ocorrência (R6)
-- ─────────────────────────────────────────────────────────────────────────────
-- Denúncia e cancelamento ficam 5 anos a partir de criada_em. A ocorrência ainda ligada a uma
-- posição ou turno dentro do prazo espera por eles: é contexto daquele turno. Os outros tipos
-- (suspensão, contestação, suporte, revisão de despacho) não entram: a suspensão vigente é lida
-- por situacao_da_conta.
create or replace function privado.anonimizar_ocorrencias_antigas(
  p_anos integer default 5,
  p_limite integer default 500
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite_data timestamptz;
  v_ids         uuid[];
begin
  if p_anos is null or p_anos < 5 then
    p_anos := 5;
  end if;
  if p_limite is null or p_limite < 1 then
    p_limite := 500;
  end if;

  v_limite_data := privado.agora() - (p_anos || ' years')::interval;

  select coalesce(array_agg(sub.id), '{}')
    into v_ids
    from (
      select o.id
        from public.ocorrencia o
       where o.tipo in ('denuncia', 'cancelamento')
         and o.criada_em <= v_limite_data
         and not exists (select 1 from public.posicao p
                          where p.id = o.posicao_id and p.fim_em > v_limite_data)
         and not exists (select 1 from public.turno t
                           join public.posicao p on p.id = t.posicao_id
                          where t.id = o.turno_id and p.fim_em > v_limite_data)
         and (
           o.motivo not in ('Expurgado (LGPD)', '[removido por exclusão de conta]')
           or o.relato is not null
           or exists (select 1 from privado.auditoria_ciclo a
                       where a.entidade = 'ocorrencia' and a.entidade_id = o.id)
         )
       order by o.criada_em asc, o.id
       limit p_limite
       for update of o skip locked
    ) sub;

  if cardinality(v_ids) = 0 then
    return 0;
  end if;

  -- ocorrencia é imutável: passa pela exceção privado.retencao (RF25)
  perform set_config('privado.retencao', 'on', true);

  delete from privado.auditoria_ciclo
   where entidade = 'ocorrencia'
     and entidade_id = any(v_ids);

  update public.ocorrencia o
     set motivo = case when o.motivo in ('Expurgado (LGPD)', '[removido por exclusão de conta]')
                       then o.motivo else 'Expurgado (LGPD)' end,
         relato = null
   where o.id = any(v_ids);

  perform set_config('privado.retencao', 'off', true);
  return cardinality(v_ids);
end $$;

comment on function privado.anonimizar_ocorrencias_antigas(integer, integer) is
  'R6 da LGPD-J6 fase 2: denúncia e cancelamento com mais de 5 anos (criada_em; a ligada a posição ou turno ainda no prazo espera por eles) perdem o relato, o motivo vira ''Expurgado (LGPD)'' e a trilha sai. Lotes com SKIP LOCKED, piso de 5 anos não encurtável. O marcador da exclusão de conta é mantido.';

revoke all on function privado.anonimizar_ocorrencias_antigas(integer, integer) from public, anon, authenticated;
grant execute on function privado.anonimizar_ocorrencias_antigas(integer, integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Marcas de notificação (R8)
-- ─────────────────────────────────────────────────────────────────────────────
-- A marca guarda usuario_id e o id do turno, da posição ou da vaga do aviso. Sai quando tem
-- mais de 5 anos ou quando o que ela referencia já não existe: aí não há aviso a deduplicar.
create or replace function privado.limpar_marcas_notificacao(
  p_anos integer default 5,
  p_limite integer default 1000
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite_data timestamptz;
  v_total       integer := 0;
begin
  if p_anos is null or p_anos < 5 then
    p_anos := 5;
  end if;
  if p_limite is null or p_limite < 1 then
    p_limite := 1000;
  end if;

  v_limite_data := privado.agora() - (p_anos || ' years')::interval;

  with alvo as (
    select m.tipo, m.referencia_id, m.usuario_id, m.rodada
      from privado.marca_notificacao m
     where m.criada_em <= v_limite_data
        or (    not exists (select 1 from public.turno t where t.id = m.referencia_id)
            and not exists (select 1 from public.posicao p where p.id = m.referencia_id)
            and not exists (select 1 from public.vaga g where g.id = m.referencia_id))
     order by m.criada_em asc
     limit p_limite
     for update skip locked
  )
  delete from privado.marca_notificacao m
   using alvo
   where m.tipo = alvo.tipo
     and m.referencia_id = alvo.referencia_id
     and m.usuario_id = alvo.usuario_id
     and m.rodada = alvo.rodada;

  get diagnostics v_total = row_count;
  return v_total;
end $$;

comment on function privado.limpar_marcas_notificacao(integer, integer) is
  'R8 da LGPD-J6 fase 2: apaga, em lotes com SKIP LOCKED, a marca de notificação com mais de 5 anos ou cuja referência (turno, posição ou vaga) já não existe. Piso de 5 anos não encurtável.';

revoke all on function privado.limpar_marcas_notificacao(integer, integer) from public, anon, authenticated;
grant execute on function privado.limpar_marcas_notificacao(integer, integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. Rotina diária
-- ─────────────────────────────────────────────────────────────────────────────
-- A ordem importa: o turno sai antes da vaga (que só expira sem turno), e a ocorrência e a marca
-- vêm depois, quando o expurgo do turno já as desligou.
create or replace function privado.executar_retencao_diaria()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anonimizadas      integer;
  v_higiene           jsonb;
  v_eventos_app       integer;
  v_expurgo_ident     jsonb;
  v_expurgo_perfil    integer;
  v_expurgo_chamada   integer;
  v_expurgo_turnos    integer;
  v_expurgo_vagas     integer;
  v_ocorrencias       integer;
  v_marcas            integer;
  v_expurgo_acessos   integer;
begin
  v_anonimizadas    := privado.limpar_contas_anonimizadas(15);
  v_higiene         := privado.higienizar_tabelas();
  v_eventos_app     := privado.limpar_eventos_app(90);
  v_expurgo_ident   := privado.expurgar_midias_verificacao_identidade();
  v_expurgo_perfil  := privado.expurgar_midias_recusadas();
  v_expurgo_chamada := privado.limpar_chamadas_expurgadas(90);
  v_expurgo_turnos  := privado.expurgar_turnos_antigos(5, 500);
  v_expurgo_vagas   := privado.expurgar_vagas_antigas(5, 500);
  v_ocorrencias     := privado.anonimizar_ocorrencias_antigas(5, 500);
  v_marcas          := privado.limpar_marcas_notificacao(5, 1000);
  v_expurgo_acessos := privado.limpar_registros_acesso(6, 1000);

  return jsonb_build_object(
    'executado_em',                     privado.agora(),
    'contas_anonimizadas_limpas',       v_anonimizadas,
    'higiene',                          v_higiene,
    'eventos_app_limpos',               v_eventos_app,
    'expurgo_midia_identidade',         v_expurgo_ident,
    'expurgo_midia_perfil',             v_expurgo_perfil,
    'expurgo_chamadas_nao_aceitas',     v_expurgo_chamada,
    'expurgo_turnos_antigos',           v_expurgo_turnos,
    'expurgo_vagas_antigas',            v_expurgo_vagas,
    'anonimizacao_ocorrencias_antigas', v_ocorrencias,
    'expurgo_marcas_notificacao',       v_marcas,
    'expurgo_registros_acesso',         v_expurgo_acessos
  );
end $$;

comment on function privado.executar_retencao_diaria() is
  'Rotina diária consolidada de retenção e limpeza: contas anonimizadas (15 dias), higiene de tabelas, eventos do app (90 dias), expurgo de mídias de identidade e fotos recusadas (24 h), chamadas não aceitas (90 dias), turnos com mais de 5 anos e o contexto deles (vaga, chamada, despacho, posição sem turno, ocorrência de denúncia e cancelamento, marcas de notificação e trilha; LGPD-J6 fases 1 e 2) e registros de acesso à aplicação com mais de 6 meses (Marco Civil art. 15).';

revoke execute on function privado.executar_retencao_diaria() from public, anon, authenticated;
grant  execute on function privado.executar_retencao_diaria() to service_role;
