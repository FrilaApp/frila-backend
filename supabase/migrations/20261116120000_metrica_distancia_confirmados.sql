-- 20261116120000_metrica_distancia_confirmados.sql
-- Views SQL de distância dos profissionais confirmados (D02, Cartão imAEq801).
--
-- 1. metrica.distancia_confirmados:
--    - Distância em metros entre o ponto base do profissional (profissional.ponto_base)
--      e o local da vaga (vaga.ponto) para posições confirmadas ou cumpridas.
--    - Exclui contas de demonstração (usuario.demonstracao) e equipe Frila (privado.conta_equipe)
--      tanto do publicador da vaga quanto do profissional confirmado.
--    - Não contém PII (somente IDs, timestamps, dia em America/Sao_Paulo, estado e distância numérica).
--    - Restrito exclusivamente a service_role (sem acesso a anon / authenticated).
--
-- 2. metrica.distancia_confirmados_resumo:
--    - Resumo estatístico (p50, p90, p99, min, max, média e total) da distância dos confirmados
--      para posições cujo início ocorreu nos últimos 28 dias a partir de privado.agora().
--    - Restrito exclusivamente a service_role.

-- ── 1. metrica.distancia_confirmados ──────────────────────────────────────────
create or replace view metrica.distancia_confirmados as
select
  p.id as posicao_id,
  v.id as vaga_id,
  v.estabelecimento_id,
  prof.id as profissional_id,
  (v.publicado_em at time zone 'America/Sao_Paulo')::date as dia,
  v.publicado_em,
  p.confirmado_em,
  p.inicio_em,
  p.estado as estado_posicao,
  round(extensions.ST_Distance(prof.ponto_base::extensions.geography, v.ponto::extensions.geography)::numeric, 2) as distancia_metros
from public.posicao p
join public.vaga v on v.id = p.vaga_id
join public.usuario uv on uv.id = v.publicado_por
join public.profissional prof on prof.id = p.profissional_id
join public.usuario up on up.id = prof.usuario_id
where p.estado in ('confirmada', 'cumprida')
  and prof.ponto_base is not null
  and v.ponto is not null
  and not coalesce(uv.demonstracao, false)
  and not exists (select 1 from privado.conta_equipe ce where ce.usuario_id = uv.id)
  and not coalesce(up.demonstracao, false)
  and not exists (select 1 from privado.conta_equipe ce where ce.usuario_id = up.id);

comment on view metrica.distancia_confirmados is
  'Distância em metros entre o ponto base do profissional e o local da vaga para posições confirmadas/cumpridas. Exclui contas de demonstração e equipe Frila (D02, imAEq801). Restrito a service_role.';

comment on column metrica.distancia_confirmados.posicao_id is
  'Identificador único da posição na vaga.';

comment on column metrica.distancia_confirmados.vaga_id is
  'Identificador único da vaga vinculada.';

comment on column metrica.distancia_confirmados.estabelecimento_id is
  'Identificador único do estabelecimento contratante.';

comment on column metrica.distancia_confirmados.profissional_id is
  'Identificador único do profissional confirmado.';

comment on column metrica.distancia_confirmados.dia is
  'Data de publicação da vaga no fuso America/Sao_Paulo.';

comment on column metrica.distancia_confirmados.publicado_em is
  'Instante em que a vaga foi publicada.';

comment on column metrica.distancia_confirmados.confirmado_em is
  'Instante em que a posição foi confirmada.';

comment on column metrica.distancia_confirmados.inicio_em is
  'Instante previsto de início do turno/posição.';

comment on column metrica.distancia_confirmados.estado_posicao is
  'Estado atual da posição (confirmada ou cumprida).';

comment on column metrica.distancia_confirmados.distancia_metros is
  'Distância geográfica em metros entre profissional.ponto_base e vaga.ponto.';

revoke all on table metrica.distancia_confirmados from public, anon, authenticated;
grant select on table metrica.distancia_confirmados to service_role;

-- ── 2. metrica.distancia_confirmados_resumo ───────────────────────────────────
create or replace view metrica.distancia_confirmados_resumo as
select
  count(*)::bigint as total_confirmados,
  percentile_disc(0.50) within group (order by distancia_metros) as p50_metros,
  percentile_disc(0.90) within group (order by distancia_metros) as p90_metros,
  percentile_disc(0.99) within group (order by distancia_metros) as p99_metros,
  min(distancia_metros) as min_metros,
  max(distancia_metros) as max_metros,
  round(avg(distancia_metros)::numeric, 2) as avg_metros
from metrica.distancia_confirmados
where inicio_em >= privado.agora() - interval '28 days';

comment on view metrica.distancia_confirmados_resumo is
  'Resumo estatístico (p50, p90, p99, min, max, média e total) da distância dos confirmados nos últimos 28 dias a partir de privado.agora(). Exclui demonstração e equipe (D02, imAEq801). Restrito a service_role.';

comment on column metrica.distancia_confirmados_resumo.total_confirmados is
  'Total de posições confirmadas/cumpridas consideradas na janela de 28 dias.';

comment on column metrica.distancia_confirmados_resumo.p50_metros is
  'Mediana (percentil 50) da distância em metros dos confirmados.';

comment on column metrica.distancia_confirmados_resumo.p90_metros is
  'Percentil 90 da distância em metros dos confirmados.';

comment on column metrica.distancia_confirmados_resumo.p99_metros is
  'Percentil 99 da distância em metros dos confirmados.';

comment on column metrica.distancia_confirmados_resumo.min_metros is
  'Distância mínima em metros observada entre os confirmados.';

comment on column metrica.distancia_confirmados_resumo.max_metros is
  'Distância máxima em metros observada entre os confirmados.';

comment on column metrica.distancia_confirmados_resumo.avg_metros is
  'Distância média em metros observada entre os confirmados.';

revoke all on table metrica.distancia_confirmados_resumo from public, anon, authenticated;
grant select on table metrica.distancia_confirmados_resumo to service_role;
