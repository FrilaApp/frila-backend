-- Consultas SQL para medição dos requisitos não-funcionais de Push:
-- RNF02 (taxa de notificações aceitas pelo provedor em até 60 s nos últimos 7 dias)
-- RNF03 (envio da notificação de vaga em até 30 s após a publicação).
-- Cartão 36fU0CEO.

-- ── 1. RNF02: Taxa de notificações aceitas em até 60 s nos últimos 7 dias ───────
-- Meta do requisito: >= 99% das notificações aceitas pelo FCM em até 60 s do despacho.
-- A medição é no servidor (aceita_em - enviada_em <= 60 s).

select
  count(*) as total_despachadas,
  count(*) filter (
    where aceita_em is not null and aceita_em - enviada_em <= interval '60 seconds'
  ) as aceitas_em_60s,
  count(*) filter (where estado_entrega = 'falhou') as falhas,
  case
    when count(*) = 0 then 0.0
    else round(
      100.0 * count(*) filter (
        where aceita_em is not null and aceita_em - enviada_em <= interval '60 seconds'
      ) / count(*),
      2
    )
  end as taxa_aceite_60s_pct
from public.notificacao
where enviada_em >= privado.agora() - interval '7 days';


-- ── 2. RNF02: Detalhamento dos motivos de falha (últimos 7 dias) ───────────────
-- Toda falha registra o motivo (ex.: UNREGISTERED, sem_dispositivo, erro_transitorio).

select
  coalesce(motivo_falha, 'sem_motivo_registrado') as motivo_falha,
  count(*) as quantidade,
  round(100.0 * count(*) / sum(count(*)) over (), 2) as percentual_das_falhas
from public.notificacao
where estado_entrega = 'falhou'
  and enviada_em >= privado.agora() - interval '7 days'
group by motivo_falha
order by quantidade desc;


-- ── 3. RNF03: Envio ao provedor em até 30 s da publicação da vaga ───────────────
-- A notificação da vaga deve ser enviada ao provedor em até 30 s após a publicação.

select
  v.id as vaga_id,
  v.publicado_em as vaga_publicada_em,
  n.id as notificacao_id,
  n.enviada_em as notificacao_enfileirada_em,
  n.aceita_em as fcm_aceite_em,
  round(extract(epoch from (n.enviada_em - v.publicado_em))::numeric, 2) as segundos_ate_despacho,
  case
    when extract(epoch from (n.enviada_em - v.publicado_em)) <= 30 then 'DENTRO_DO_LIMITE'
    else 'ACIMA_DO_LIMITE'
  end as conformidade_rnf03
from public.notificacao n
join public.despacho d on d.notificacao_id = n.id
join public.vaga v on v.id = d.vaga_id
where n.tipo in ('vaga', 'vagas_agrupadas')
  and n.enviada_em >= privado.agora() - interval '7 days'
order by n.enviada_em desc;
