-- 20261018163000_metrica_north_star_semanal.sql
-- View metrica.north_star_semanal e atualização de metrica.funil_por_vaga (Cartão SDeFULxG, Sprint 4, T-0017).
-- PlanoDeMetricas.md: seção 2.3 (North Star semanal), seção 3 (KPI 3 - Show-up rate) e seção 4.3.
--
-- 1. Cria a view metrica.north_star_semanal:
--    - Agrupa por date_trunc('week', p.fim_em AT TIME ZONE 'America/Sao_Paulo')::date
--    - Filtra p.estado = 'cumprida' e t.verificacao = 'verificado'
--    - Exclui contas de demonstração (usuario.demonstracao) e equipe Frila (privado.conta_equipe)
--      tanto do profissional quanto de quem publicou a vaga (vaga.publicado_por).
--    - Restrito exclusivamente a service_role.
--
-- 2. Atualiza metrica.funil_por_vaga:
--    - checkins passa a exigir t.verificacao = 'verificado', refletindo o comparecimento real
--      para cálculo do show-up rate (KPI 3).
--    - Decisão sobre confirmacoes: mantido contando posições com confirmado_em IS NOT NULL
--      como evento histórico de conversão no funil, mesmo em posições canceladas posteriormente
--      (conforme documentado em PlanoDeMetricas.md seções 3 e 4.3).

-- ── 1. metrica.funil_por_vaga com check-ins verificados ───────────────────────
create or replace view metrica.funil_por_vaga as
select
  v.id as vaga_id,
  v.estabelecimento_id,
  e.nome as estabelecimento_nome,
  (v.publicado_em at time zone 'America/Sao_Paulo')::date as dia,
  v.publicado_em,
  v.posicoes as posicoes_ofertadas,
  -- Notificações enviadas (individuais e de vagas agrupadas) para a vaga
  (
    select count(distinct n.id)
      from public.notificacao n
      join public.usuario un on un.id = n.usuario_id
     where not coalesce(un.demonstracao, false)
       and not exists (select 1 from privado.conta_equipe ce where ce.usuario_id = un.id)
       and (
         (n.tipo = 'vaga' and n.referencia_id = v.id)
         or exists (
           select 1 from public.despacho d
            where d.vaga_id = v.id
              and d.notificacao_id = n.id
         )
       )
  ) as notificacoes_enviadas,
  -- Candidaturas
  (
    select count(distinct c.id)
      from public.posicao p
      join public.candidatura c on c.posicao_id = p.id
      join public.profissional prof on prof.id = c.profissional_id
      join public.usuario uc on uc.id = prof.usuario_id
     where p.vaga_id = v.id
       and not coalesce(uc.demonstracao, false)
       and not exists (select 1 from privado.conta_equipe ce where ce.usuario_id = uc.id)
  ) as candidaturas,
  -- Confirmações (evento de funil: conta posições confirmadas mesmo que canceladas depois)
  (
    select count(distinct p.id)
      from public.posicao p
      join public.profissional prof on prof.id = p.profissional_id
      join public.usuario up on up.id = prof.usuario_id
     where p.vaga_id = v.id
       and p.confirmado_em is not null
       and not coalesce(up.demonstracao, false)
       and not exists (select 1 from privado.conta_equipe ce where ce.usuario_id = up.id)
  ) as confirmacoes,
  -- Check-ins (com presença verificada: geolocalizado ou manual confirmado pelo contratante)
  (
    select count(distinct t.id)
      from public.posicao p
      join public.turno t on t.posicao_id = p.id
      join public.profissional prof on prof.id = p.profissional_id
      join public.usuario ut on ut.id = prof.usuario_id
     where p.vaga_id = v.id
       and t.checkin_em is not null
       and t.verificacao = 'verificado'
       and not coalesce(ut.demonstracao, false)
       and not exists (select 1 from privado.conta_equipe ce where ce.usuario_id = ut.id)
  ) as checkins,
  -- Avaliações
  (
    select count(distinct a.id)
      from public.posicao p
      join public.turno t on t.posicao_id = p.id
      join public.avaliacao a on a.turno_id = t.id
      join public.usuario ua on ua.id = a.autor_id
     where p.vaga_id = v.id
       and not coalesce(ua.demonstracao, false)
       and not exists (select 1 from privado.conta_equipe ce where ce.usuario_id = ua.id)
  ) as avaliacoes
from public.vaga v
join public.estabelecimento e on e.id = v.estabelecimento_id
join public.usuario uv on uv.id = v.publicado_por
where not coalesce(uv.demonstracao, false)
  and not exists (select 1 from privado.conta_equipe ce where ce.usuario_id = uv.id);

comment on view metrica.funil_por_vaga is
  'Funil por vaga individual: contagem de notificações, candidaturas, confirmações, check-ins verificados e avaliações. Decisão de produto (PlanoDeMetricas.md seções 3 e 4.3): confirmacoes conta posições com confirmado_em IS NOT NULL como evento histórico de funil, preservando o estágio mesmo se houver cancelamento posterior; checkins filtra t.verificacao = ''verificado'' para refletir o comparecimento real (KPI 3). Exclui demonstração e contas da equipe.';

comment on column metrica.funil_por_vaga.confirmacoes is
  'Contagem de posições com confirmado_em IS NOT NULL: registra o evento histórico de confirmação no funil (mesmo que a posição seja cancelada posteriormente, conforme PlanoDeMetricas.md seções 3 e 4.3).';

comment on column metrica.funil_por_vaga.checkins is
  'Contagem de turnos com check-in e presença efetivamente verificada (t.verificacao = ''verificado''), excluindo check-in manual pendente de confirmação ou turnos não verificados (KPI 3, PlanoDeMetricas.md).';

revoke all on table metrica.funil_por_vaga from public, anon, authenticated;
grant select on table metrica.funil_por_vaga to service_role;

-- ── 2. metrica.north_star_semanal ─────────────────────────────────────────────
create or replace view metrica.north_star_semanal as
select
  date_trunc('week', p.fim_em at time zone 'America/Sao_Paulo')::date as semana_inicio,
  count(*)::bigint as turnos_concluidos_com_presenca_verificada
from public.turno t
join public.posicao p       on p.id = t.posicao_id
join public.vaga v          on v.id = p.vaga_id
join public.profissional pr on pr.id = p.profissional_id
join public.usuario up      on up.id = pr.usuario_id
join public.usuario uc      on uc.id = v.publicado_por
where p.estado = 'cumprida'
  and t.verificacao = 'verificado'
  and not coalesce(up.demonstracao, false)
  and not coalesce(uc.demonstracao, false)
  and not exists (
    select 1 from privado.conta_equipe ce
     where ce.usuario_id in (up.id, uc.id)
  )
group by 1
order by 1 desc;

comment on view metrica.north_star_semanal is
  'North Star Metric do Frila: turnos concluídos (posicao.estado = ''cumprida'') com presença verificada (turno.verificacao = ''verificado'') por semana (início na segunda-feira, fuso America/Sao_Paulo). Exclui contas de demonstração e equipe Frila (T-0017, Cartão SDeFULxG, PlanoDeMetricas.md seção 2.3).';

comment on column metrica.north_star_semanal.semana_inicio is
  'Data de início da semana (segunda-feira) calculada a partir de posicao.fim_em no fuso America/Sao_Paulo.';

comment on column metrica.north_star_semanal.turnos_concluidos_com_presenca_verificada is
  'Contagem de posições concluídas com presença verificada na semana.';

revoke all on table metrica.north_star_semanal from public, anon, authenticated;
grant select on table metrica.north_star_semanal to service_role;
