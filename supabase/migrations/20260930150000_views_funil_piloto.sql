-- 20260930150000_views_funil_piloto.sql
-- Views SQL do funil do piloto por dia e por estabelecimento (Cartão 1MK1CGyF, T-0017, T-0020).
--
-- O ciclo que este repositório fecha:
--   publicar → notificar → candidatar → confirmar → executar (check-in) → avaliar
--
-- Restrito a service_role (sem acesso de anon / authenticated).
-- Exclui contas de demonstração (usuario.demonstracao = true).

create schema if not exists metrica;

comment on schema metrica is
  'Schema isolado para métricas e telemetria operacional do piloto (T-0017, T-0020, 1MK1CGyF). Restrito a service_role.';

revoke all on schema metrica from public, anon, authenticated;
grant usage on schema metrica to service_role;

-- ── 1. metrica.funil_por_vaga (base de cálculo detalhada) ─────────────────────
-- Base de apoio: métricas desagregadas por vaga, exposta em metrica para consultas
-- aprofundadas ou auditoria de cada publicação do piloto.
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
  ) as candidaturas,
  -- Confirmações
  (
    select count(distinct p.id)
      from public.posicao p
      join public.profissional prof on prof.id = p.profissional_id
      join public.usuario up on up.id = prof.usuario_id
     where p.vaga_id = v.id
       and p.confirmado_em is not null
       and not coalesce(up.demonstracao, false)
  ) as confirmacoes,
  -- Check-ins
  (
    select count(distinct t.id)
      from public.posicao p
      join public.turno t on t.posicao_id = p.id
      join public.profissional prof on prof.id = p.profissional_id
      join public.usuario ut on ut.id = prof.usuario_id
     where p.vaga_id = v.id
       and t.checkin_em is not null
       and not coalesce(ut.demonstracao, false)
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
  ) as avaliacoes
from public.vaga v
join public.estabelecimento e on e.id = v.estabelecimento_id
join public.usuario uv on uv.id = v.publicado_por
where not coalesce(uv.demonstracao, false);

comment on view metrica.funil_por_vaga is
  'Funil por vaga individual: contagem de notificações, candidaturas, confirmações, check-ins e avaliações. Exclui contas de demonstração.';

-- ── 2. metrica.funil_confirmacoes (base de tempos de confirmação) ───────────────
create or replace view metrica.funil_confirmacoes as
select
  p.id as posicao_id,
  v.id as vaga_id,
  v.estabelecimento_id,
  (v.publicado_em at time zone 'America/Sao_Paulo')::date as dia,
  v.publicado_em,
  p.confirmado_em,
  extract(epoch from (p.confirmado_em - v.publicado_em)) as duracao_confirmacao_segundos
from public.posicao p
join public.vaga v on v.id = p.vaga_id
join public.usuario uv on uv.id = v.publicado_por
join public.profissional prof on prof.id = p.profissional_id
join public.usuario up on up.id = prof.usuario_id
where p.confirmado_em is not null
  and not coalesce(uv.demonstracao, false)
  and not coalesce(up.demonstracao, false);

comment on view metrica.funil_confirmacoes is
  'Posições confirmadas com duração em segundos entre a publicação da vaga e a confirmação. Exclui contas de demonstração.';

-- ── 3. metrica.funil_por_dia ───────────────────────────────────────────────────
create or replace view metrica.funil_por_dia as
with metricas_vaga as (
  select
    dia,
    count(distinct vaga_id) as vagas_publicadas,
    sum(notificacoes_enviadas)::bigint as notificacoes_enviadas,
    sum(candidaturas)::bigint as candidaturas,
    sum(confirmacoes)::bigint as confirmacoes,
    sum(checkins)::bigint as checkins,
    sum(avaliacoes)::bigint as avaliacoes
  from metrica.funil_por_vaga
  group by dia
),
medianas as (
  select
    dia,
    (percentile_cont(0.5) within group (
      order by duracao_confirmacao_segundos
    ) * interval '1 second') as tempo_mediano_confirmacao,
    percentile_cont(0.5) within group (
      order by duracao_confirmacao_segundos
    )::numeric(12,2) as tempo_mediano_confirmacao_segundos
  from metrica.funil_confirmacoes
  group by dia
)
select
  m.dia,
  m.vagas_publicadas,
  m.notificacoes_enviadas,
  m.candidaturas,
  m.confirmacoes,
  m.checkins,
  m.avaliacoes,
  med.tempo_mediano_confirmacao,
  med.tempo_mediano_confirmacao_segundos
from metricas_vaga m
left join medianas med on med.dia = m.dia
order by m.dia desc;

comment on view metrica.funil_por_dia is
  'Funil do piloto consolidado por dia (data da publicação): vagas publicadas, notificações enviadas, candidaturas, confirmações, check-ins, avaliações e tempo mediano de confirmação. Exclui demonstração.';

-- ── 4. metrica.funil_por_estabelecimento ───────────────────────────────────────
create or replace view metrica.funil_por_estabelecimento as
with metricas_vaga as (
  select
    estabelecimento_id,
    count(distinct vaga_id) as vagas_publicadas,
    sum(notificacoes_enviadas)::bigint as notificacoes_enviadas,
    sum(candidaturas)::bigint as candidaturas,
    sum(confirmacoes)::bigint as confirmacoes,
    sum(checkins)::bigint as checkins,
    sum(avaliacoes)::bigint as avaliacoes
  from metrica.funil_por_vaga
  group by estabelecimento_id
),
medianas as (
  select
    estabelecimento_id,
    (percentile_cont(0.5) within group (
      order by duracao_confirmacao_segundos
    ) * interval '1 second') as tempo_mediano_confirmacao,
    percentile_cont(0.5) within group (
      order by duracao_confirmacao_segundos
    )::numeric(12,2) as tempo_mediano_confirmacao_segundos
  from metrica.funil_confirmacoes
  group by estabelecimento_id
)
select
  e.id as estabelecimento_id,
  e.nome as estabelecimento_nome,
  coalesce(m.vagas_publicadas, 0)::bigint as vagas_publicadas,
  coalesce(m.notificacoes_enviadas, 0)::bigint as notificacoes_enviadas,
  coalesce(m.candidaturas, 0)::bigint as candidaturas,
  coalesce(m.confirmacoes, 0)::bigint as confirmacoes,
  coalesce(m.checkins, 0)::bigint as checkins,
  coalesce(m.avaliacoes, 0)::bigint as avaliacoes,
  med.tempo_mediano_confirmacao,
  med.tempo_mediano_confirmacao_segundos
from public.estabelecimento e
left join metricas_vaga m on m.estabelecimento_id = e.id
left join medianas med on med.estabelecimento_id = e.id
where not exists (
  select 1
    from public.membro_estabelecimento me
    join public.usuario u on u.id = me.usuario_id
   where me.estabelecimento_id = e.id
     and me.papel = 'administrador'
     and coalesce(u.demonstracao, false) = true
)
order by vagas_publicadas desc, e.nome asc;

comment on view metrica.funil_por_estabelecimento is
  'Funil do piloto consolidado por estabelecimento: vagas publicadas, notificações enviadas, candidaturas, confirmações, check-ins, avaliações e tempo mediano de confirmação. Exclui demonstração.';

-- ── 5. metrica.funil_geral (resumo consolidado do piloto) ─────────────────────
create or replace view metrica.funil_geral as
with totais as (
  select
    count(distinct vaga_id) as vagas_publicadas,
    sum(notificacoes_enviadas)::bigint as notificacoes_enviadas,
    sum(candidaturas)::bigint as candidaturas,
    sum(confirmacoes)::bigint as confirmacoes,
    sum(checkins)::bigint as checkins,
    sum(avaliacoes)::bigint as avaliacoes
  from metrica.funil_por_vaga
),
mediana as (
  select
    (percentile_cont(0.5) within group (
      order by duracao_confirmacao_segundos
    ) * interval '1 second') as tempo_mediano_confirmacao,
    percentile_cont(0.5) within group (
      order by duracao_confirmacao_segundos
    )::numeric(12,2) as tempo_mediano_confirmacao_segundos
  from metrica.funil_confirmacoes
)
select
  coalesce(t.vagas_publicadas, 0)::bigint as vagas_publicadas,
  coalesce(t.notificacoes_enviadas, 0)::bigint as notificacoes_enviadas,
  coalesce(t.candidaturas, 0)::bigint as candidaturas,
  coalesce(t.confirmacoes, 0)::bigint as confirmacoes,
  coalesce(t.checkins, 0)::bigint as checkins,
  coalesce(t.avaliacoes, 0)::bigint as avaliacoes,
  m.tempo_mediano_confirmacao,
  m.tempo_mediano_confirmacao_segundos
from totais t
cross join mediana m;

comment on view metrica.funil_geral is
  'Resumo global do funil do piloto: totais de vagas, notificações, candidaturas, confirmações, check-ins, avaliações e tempo mediano geral. Exclui demonstração.';

-- ── Permissões: restrito exclusivamente a service_role ────────────────────────
revoke all on schema metrica from public, anon, authenticated;
grant usage on schema metrica to service_role;

revoke all on all tables in schema metrica from public, anon, authenticated;
grant select on all tables in schema metrica to service_role;

alter default privileges in schema metrica grant select on tables to service_role;
alter default privileges in schema metrica revoke all on tables from public, anon, authenticated;
