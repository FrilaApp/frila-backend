-- scripts/validar-metricas-sinteticas.sql
-- Semeia uma amostra sintética e confere os 4 indicadores do mentor da Academy contra o que foi semeado.
-- Quem chama é scripts/validar-metricas-sinteticas.sh (trava de host remoto, limpeza no trap EXIT). Não rode à mão.
--
-- Tudo roda numa transação só. Variável de psql `fim`: `rollback` (padrão, nada fica no banco) ou `commit`
-- (só para exercitar a limpeza do trap).
--
-- Prefixo isolado dos ids sintéticos: fb000000-0000-4000-8KKK-NNNNNNNNNNNN, com KKK pela classe da linha:
--   001 empregador (usuario)   002 trabalhador (usuario)   003 estabelecimento   004 profissional
--   005 vaga                   006 posicao                 007 candidatura        008 turno
--
-- A amostra (1 posição por vaga, 20 vagas, 10 estabelecimentos, 50 profissionais, 80 candidaturas):
--
--   grupo  vagas  modo       desfecho da posição                          candidaturas (aceita + resto)
--   G1     3      urgência   confirmada, turno no futuro                  1 (só a vencedora tem linha)
--   G2     6      seleção    confirmada, turno no futuro                  33 (6 aceitas + 27 recusadas)
--   G3     3      mista      cumprida, check-in verificado                11 (3 aceitas + 8 recusadas)
--   G4     1      seleção    no-show: cancelada, falta, sem check-in      4 (1 aceita + 3 recusadas)
--   G5     2      seleção    desistência: cancelada + posição reaberta    10 (2 aceitas + 8 recusadas)
--                            (uma com 24 h ou mais, sem falta; uma com menos de 24 h, com falta)
--   G6     2      seleção    sem escolha da casa: vaga cancelada          9 expiradas
--   G7     1      seleção    encerrada, candidatos retiraram              5 retiradas
--   G8     2      seleção    ainda aberta, sem decisão                    5 pendentes
--
--   15 posições com confirmado_em (G1 a G5); as 5 vagas de G6 a G8 nunca tiveram confirmação.

begin;

-- Antes: o que as views já enxergam no banco (outros dados locais entram nesta conta; a diferença é a amostra).
create temp table pg_temp.antes on commit drop as select * from metrica.funil_geral;

-- ── Contas, casas e vínculos ───────────────────────────────────────────────────
-- Os defaults de public.usuario já deixam `demonstracao = false`, e nada entra em privado.conta_equipe:
-- as duas exclusões das views `metrica` não pegam a amostra.
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
select ('fb000000-0000-4000-8001-' || lpad(n::text, 12, '0'))::uuid, 'contratante',
       'Sintético Empregador ' || lpad(n::text, 2, '0'), '+5561988' || lpad(n::text, 6, '0'),
       'sint-emp-' || lpad(n::text, 2, '0') || '@frila.test', date '1990-01-01', 'ativa', '2026-09-22', now()
  from generate_series(1, 10) n;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
select ('fb000000-0000-4000-8002-' || lpad(n::text, 12, '0'))::uuid, 'profissional',
       'Sintético Trabalhador ' || lpad(n::text, 2, '0'), '+5561977' || lpad(n::text, 6, '0'),
       'sint-pro-' || lpad(n::text, 2, '0') || '@frila.test', date '1995-01-01', 'ativa', '2026-09-22', now()
  from generate_series(1, 50) n;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select ('fb000000-0000-4000-8003-' || lpad(n::text, 12, '0'))::uuid, 'Casa Sintética ' || lpad(n::text, 2, '0'),
       '99' || lpad(n::text, 12, '0'), 'food_service', 'Endereço sintético ' || lpad(n::text, 2, '0'),
       'POINT(-47.8869 -15.7620)'::extensions.geography
  from generate_series(1, 10) n;

insert into public.membro_estabelecimento (usuario_id, perfil, estabelecimento_id, papel)
select ('fb000000-0000-4000-8001-' || lpad(n::text, 12, '0'))::uuid, 'contratante',
       ('fb000000-0000-4000-8003-' || lpad(n::text, 12, '0'))::uuid, 'administrador'
  from generate_series(1, 10) n;

insert into public.profissional (id, usuario_id, ponto_base)
select ('fb000000-0000-4000-8004-' || lpad(n::text, 12, '0'))::uuid,
       ('fb000000-0000-4000-8002-' || lpad(n::text, 12, '0'))::uuid,
       'POINT(-47.8869 -15.7620)'::extensions.geography
  from generate_series(1, 50) n;

-- ── O plano das 20 vagas ───────────────────────────────────────────────────────
-- inicio e pub são deslocamentos a partir de `t0` (a hora cheia de agora). `nc` é o número de candidaturas;
-- `resto` é o estado das candidaturas que não são a vencedora; `vaga_estado` é o que a vaga tem no fim.
create temp table pg_temp.plano on commit drop as
select n, grupo, modo, vaga_estado, inicio, pub, nc, resto, desfecho
  from (values
    ( 1, 'G1', 'urgencia', 'preenchida', interval '3 days',   interval '-1 day',  1, null::text,  'confirmada'),
    ( 2, 'G1', 'urgencia', 'preenchida', interval '4 days',   interval '-1 day',  1, null,        'confirmada'),
    ( 3, 'G1', 'urgencia', 'preenchida', interval '5 days',   interval '-1 day',  1, null,        'confirmada'),
    ( 4, 'G2', 'selecao',  'preenchida', interval '5 days',   interval '-2 days', 6, 'recusada',  'confirmada'),
    ( 5, 'G2', 'selecao',  'preenchida', interval '6 days',   interval '-2 days', 5, 'recusada',  'confirmada'),
    ( 6, 'G2', 'selecao',  'preenchida', interval '7 days',   interval '-2 days', 6, 'recusada',  'confirmada'),
    ( 7, 'G2', 'selecao',  'preenchida', interval '8 days',   interval '-2 days', 5, 'recusada',  'confirmada'),
    ( 8, 'G2', 'selecao',  'preenchida', interval '9 days',   interval '-2 days', 6, 'recusada',  'confirmada'),
    ( 9, 'G2', 'selecao',  'preenchida', interval '10 days',  interval '-2 days', 5, 'recusada',  'confirmada'),
    (10, 'G3', 'selecao',  'encerrada',  interval '-3 days',  interval '-7 days', 5, 'recusada',  'cumprida'),
    (11, 'G3', 'selecao',  'encerrada',  interval '-4 days',  interval '-8 days', 5, 'recusada',  'cumprida'),
    (12, 'G3', 'urgencia', 'encerrada',  interval '-5 days',  interval '-6 days', 1, null,        'cumprida'),
    (13, 'G4', 'selecao',  'encerrada',  interval '-2 days',  interval '-6 days', 4, 'recusada',  'noshow'),
    (14, 'G5', 'selecao',  'publicada',  interval '6 days',   interval '-2 days', 5, 'recusada',  'desistencia_antecipada'),
    (15, 'G5', 'urgencia', 'publicada',  interval '10 hours', interval '-2 days', 5, 'recusada',  'desistencia_tardia'),
    (16, 'G6', 'selecao',  'cancelada',  interval '-2 days',  interval '-6 days', 5, 'expirada',  'sem_escolha'),
    (17, 'G6', 'selecao',  'cancelada',  interval '-3 days',  interval '-7 days', 4, 'expirada',  'sem_escolha'),
    (18, 'G7', 'selecao',  'encerrada',  interval '-4 days',  interval '-9 days', 5, 'retirada',  'sem_escolha'),
    (19, 'G8', 'selecao',  'publicada',  interval '8 days',   interval '-1 day',  3, 'pendente',  'aberta'),
    (20, 'G8', 'selecao',  'publicada',  interval '9 days',   interval '-1 day',  2, 'pendente',  'aberta')
  ) as p(n, grupo, modo, vaga_estado, inicio, pub, nc, resto, desfecho);

-- ── Vagas e posições ───────────────────────────────────────────────────────────
-- A vaga n é da casa ((n-1) mod 10) + 1: duas por casa. Quem publica é o administrador dela.
-- confirmado_em: 20 minutos depois da publicação na urgência, 20 horas depois na seleção.
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes,
                         inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, publicado_por,
                         modo, estado, chave_cliente, publicado_em)
select ('fb000000-0000-4000-8005-' || lpad(p.n::text, 12, '0'))::uuid,
       ('fb000000-0000-4000-8003-' || lpad((((p.n - 1) % 10) + 1)::text, 12, '0'))::uuid,
       (select id from public.funcao where nome = 'garçom'),
       date_trunc('hour', now()) + p.inicio, date_trunc('hour', now()) + p.inicio + interval '4 hours',
       'Endereço sintético', 'POINT(-47.8869 -15.7620)'::extensions.geography, 15000, 1,
       false, false, false, 'Sintético',
       ('fb000000-0000-4000-8001-' || lpad((((p.n - 1) % 10) + 1)::text, 12, '0'))::uuid,
       p.modo::public.modo_preenchimento, p.vaga_estado::public.estado_vaga, gen_random_uuid(),
       date_trunc('hour', now()) + p.pub
  from pg_temp.plano p;

-- O trabalhador j (0 = o vencedor) da vaga n é o ((n*7 + j*3) mod 50) + 1: sem repetir dentro da vaga, e os 15
-- vencedores são 15 pessoas diferentes (a regra de não sobrepor turnos exige).
create temp table pg_temp.cand_plano on commit drop as
select p.n, j,
       ('fb000000-0000-4000-8004-' || lpad(((((p.n * 7) + (j * 3)) % 50) + 1)::text, 12, '0'))::uuid as profissional_id,
       case when j = 0 and p.desfecho <> 'sem_escolha' and p.desfecho <> 'aberta' then 'aceita' else p.resto end as estado
  from pg_temp.plano p, lateral generate_series(0, p.nc - 1) j;

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em)
select ('fb000000-0000-4000-8006-' || lpad(p.n::text, 12, '0'))::uuid,
       ('fb000000-0000-4000-8005-' || lpad(p.n::text, 12, '0'))::uuid,
       case p.desfecho
         when 'confirmada' then 'confirmada' when 'cumprida' then 'cumprida'
         when 'aberta' then 'aberta' else 'cancelada' end::public.estado_posicao,
       c.profissional_id,
       case when c.profissional_id is not null
            then date_trunc('hour', now()) + p.pub + case p.modo when 'urgencia' then interval '20 minutes' else interval '20 hours' end end,
       p.desfecho in ('noshow', 'desistencia_tardia'),
       date_trunc('hour', now()) + p.inicio, date_trunc('hour', now()) + p.inicio + interval '4 hours'
  from pg_temp.plano p
  left join pg_temp.cand_plano c on c.n = p.n and c.j = 0 and c.estado = 'aceita';

-- A posição que a desistência reabre (a função real insere uma nova, aberta, e devolve a vaga a `publicada`).
insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
select ('fb000000-0000-4000-8016-' || lpad(p.n::text, 12, '0'))::uuid,
       ('fb000000-0000-4000-8005-' || lpad(p.n::text, 12, '0'))::uuid, 'aberta',
       date_trunc('hour', now()) + p.inicio, date_trunc('hour', now()) + p.inicio + interval '4 hours'
  from pg_temp.plano p where p.desfecho like 'desistencia%';

insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado)
select ('fb000000-0000-4000-8007-' || lpad((row_number() over (order by c.n, c.j))::text, 12, '0'))::uuid,
       ('fb000000-0000-4000-8006-' || lpad(c.n::text, 12, '0'))::uuid, c.profissional_id,
       date_trunc('hour', now()) + p.pub + ((c.j + 1) * interval '10 minutes'),
       c.estado::public.estado_candidatura
  from pg_temp.cand_plano c join pg_temp.plano p on p.n = c.n;

-- O turno nasce com a confirmação. Só o cumprido tem check-in, e verificado.
insert into public.turno (id, posicao_id, valor_acordado_centavos, verificacao, checkin_em, checkin_tipo,
                          checkin_distancia_m, checkin_recebido_em, checkout_em)
select ('fb000000-0000-4000-8008-' || lpad(p.n::text, 12, '0'))::uuid,
       ('fb000000-0000-4000-8006-' || lpad(p.n::text, 12, '0'))::uuid, 15000,
       case p.desfecho when 'cumprida' then 'verificado' when 'confirmada' then 'pendente' else 'nao_verificado' end::public.verificacao_turno,
       case when p.desfecho = 'cumprida' then date_trunc('hour', now()) + p.inicio + interval '5 minutes' end,
       case when p.desfecho = 'cumprida' then 'geolocalizado'::public.tipo_registro end,
       case when p.desfecho = 'cumprida' then 40 end,
       case when p.desfecho = 'cumprida' then date_trunc('hour', now()) + p.inicio + interval '5 minutes' end,
       case when p.desfecho = 'cumprida' then date_trunc('hour', now()) + p.inicio + interval '3 hours 55 minutes' end
  from pg_temp.plano p
 where p.desfecho in ('confirmada', 'cumprida', 'noshow', 'desistencia_antecipada', 'desistencia_tardia');

-- ── O que ficou no banco (contagem direta nas tabelas, sem passar pelas views) ──
\echo '=== SEMEADURA (contagem nas tabelas) ==='
select 'empregadores' as item, count(*) as total from public.usuario where id::text like 'fb000000-%' and perfil = 'contratante'
union all select 'trabalhadores', count(*) from public.usuario where id::text like 'fb000000-%' and perfil = 'profissional'
union all select 'estabelecimentos', count(*) from public.estabelecimento where id::text like 'fb000000-%'
union all select 'vagas', count(*) from public.vaga where id::text like 'fb000000-%'
union all select 'candidaturas', count(*) from public.candidatura where id::text like 'fb000000-%'
union all select 'posicoes com confirmado_em', count(*) from public.posicao where id::text like 'fb000000-%' and confirmado_em is not null;

-- ── As consultas dos 4 indicadores, sobre as views (sem view nova) ──────────────
-- Base: metrica.funil_por_vaga, filtrada pelo prefixo. É a mesma conta de metrica.funil_geral, restrita à amostra.
create temp table pg_temp.medido on commit drop as
with f as (select * from metrica.funil_por_vaga where vaga_id::text like 'fb000000-%'),
     tot as (
       select count(*) as vagas, coalesce(sum(candidaturas), 0) as cand, coalesce(sum(confirmacoes), 0) as conf,
              count(*) filter (where confirmacoes >= posicoes_ofertadas) as vagas_com_confirmacao
         from f),
     vig as (
       -- Preenchimento efetivo: a vaga tem hoje posição confirmada ou cumprida para todas as posições ofertadas.
       select count(*) filter (where vigentes >= v.posicoes) as vagas_vigentes
         from public.vaga v
         cross join lateral (select count(*) as vigentes from public.posicao p
                              where p.vaga_id = v.id and p.estado in ('confirmada', 'cumprida')) x
        where v.id::text like 'fb000000-%')
select
  tot.vagas, tot.cand, tot.conf, tot.vagas_com_confirmacao, vig.vagas_vigentes,
  round(tot.cand::numeric / nullif(tot.vagas, 0), 2)                         as cand_por_vaga,
  round(100.0 * tot.vagas_com_confirmacao / nullif(tot.vagas, 0), 2)         as preenchimento_bruto_pct,
  tot.vagas - tot.vagas_com_confirmacao                                       as nao_preenchidas_bruto,
  round(100.0 * (tot.vagas - tot.vagas_com_confirmacao) / nullif(tot.vagas, 0), 2) as nao_preenchidas_bruto_pct,
  round(100.0 * tot.conf / nullif(tot.cand, 0), 2)                           as conversao_bruta_pct,
  round(100.0 * vig.vagas_vigentes / nullif(tot.vagas, 0), 2)                as preenchimento_efetivo_pct,
  tot.vagas - vig.vagas_vigentes                                              as nao_preenchidas_efetivo,
  round(100.0 * vig.vagas_vigentes / nullif(tot.cand, 0), 2)                 as conversao_efetiva_pct
from tot, vig;

-- Contra-prova da view geral: a diferença de metrica.funil_geral (depois menos antes) é a amostra.
create temp table pg_temp.delta_geral on commit drop as
select (g.vagas_publicadas - a.vagas_publicadas) as vagas, (g.candidaturas - a.candidaturas) as cand,
       (g.confirmacoes - a.confirmacoes) as conf
  from metrica.funil_geral g, pg_temp.antes a;

-- ── A comparação: medido contra o que foi semeado ──────────────────────────────
-- Os esperados são literais deste arquivo (o plano acima), nunca lidos das tabelas.
\echo '=== INDICADORES (medido x semeado) ==='
select ordem, indicador, medido, esperado, case when medido = esperado then 'OK' else 'FALHA' end as resultado
from (
  select 1 as ordem, 'vagas publicadas (funil_por_vaga)' as indicador, m.vagas::numeric as medido, 20::numeric as esperado from pg_temp.medido m
  union all select 2,  'candidaturas (funil_por_vaga)', m.cand::numeric, 80 from pg_temp.medido m
  union all select 3,  'contratações = posições com confirmado_em (funil_por_vaga)', m.conf::numeric, 15 from pg_temp.medido m
  union all select 4,  'funil_geral: vagas (depois - antes)', d.vagas::numeric, 20 from pg_temp.delta_geral d
  union all select 5,  'funil_geral: candidaturas (depois - antes)', d.cand::numeric, 80 from pg_temp.delta_geral d
  union all select 6,  'funil_geral: confirmações (depois - antes)', d.conf::numeric, 15 from pg_temp.delta_geral d
  union all select 10, 'I1 candidaturas por vaga', m.cand_por_vaga, 4.00 from pg_temp.medido m
  union all select 11, 'I2 taxa de preenchimento, bruta (%)', m.preenchimento_bruto_pct, 75.00 from pg_temp.medido m
  union all select 12, 'I3 vagas não preenchidas, bruto (vagas)', m.nao_preenchidas_bruto::numeric, 5 from pg_temp.medido m
  union all select 13, 'I3 vagas não preenchidas, bruto (%)', m.nao_preenchidas_bruto_pct, 25.00 from pg_temp.medido m
  union all select 14, 'I4 conversão candidatura→contratação, bruta (%)', m.conversao_bruta_pct, 18.75 from pg_temp.medido m
  union all select 20, 'I2 taxa de preenchimento, efetiva (%)', m.preenchimento_efetivo_pct, 60.00 from pg_temp.medido m
  union all select 21, 'I3 vagas não preenchidas, efetivo (vagas)', m.nao_preenchidas_efetivo::numeric, 8 from pg_temp.medido m
  union all select 22, 'I4 conversão candidatura→contratação, efetiva (%)', m.conversao_efetiva_pct, 15.00 from pg_temp.medido m
) x order by ordem;

-- ── A amostra não é limpa: abandono, recusa e desistência, contados nas tabelas ──
\echo '=== VARIEDADE (medido x semeado) ==='
select ordem, caso, medido, esperado, case when medido = esperado then 'OK' else 'FALHA' end as resultado
from (
  select 1 as ordem, 'no-show: cancelada, com falta, fim passado, sem check-in' as caso, count(*) as medido, 1 as esperado
    from public.posicao p left join public.turno t on t.posicao_id = p.id
   where p.id::text like 'fb000000-%' and p.estado = 'cancelada' and p.falta and p.fim_em < now() and t.checkin_em is null
  union all
  select 2, 'cancelamento tardio: cancelada, com falta, turno ainda por vir', count(*), 1
    from public.posicao p where p.id::text like 'fb000000-%' and p.estado = 'cancelada' and p.falta and p.fim_em > now()
  union all
  select 3, 'desistência antecipada: cancelada, sem falta, tinha profissional', count(*), 1
    from public.posicao p where p.id::text like 'fb000000-%' and p.estado = 'cancelada' and not p.falta and p.profissional_id is not null
  union all
  select 4, 'candidaturas recusadas (candidatura que não vira confirmação)', count(*), 46
    from public.candidatura c where c.id::text like 'fb000000-%' and c.estado = 'recusada'
  union all
  select 5, 'candidaturas expiradas (a vaga fechou sem escolha)', count(*), 9
    from public.candidatura c where c.id::text like 'fb000000-%' and c.estado = 'expirada'
  union all
  select 6, 'candidaturas retiradas (o candidato desistiu antes)', count(*), 5
    from public.candidatura c where c.id::text like 'fb000000-%' and c.estado = 'retirada'
  union all
  select 7, 'candidaturas pendentes (sem decisão ainda)', count(*), 5
    from public.candidatura c where c.id::text like 'fb000000-%' and c.estado = 'pendente'
  union all
  select 8, 'candidaturas aceitas', count(*), 15
    from public.candidatura c where c.id::text like 'fb000000-%' and c.estado = 'aceita'
  union all
  select 9, 'vagas com estado = preenchida (retrato de agora, só vale antes do fim do turno)', count(*), 9
    from public.vaga v where v.id::text like 'fb000000-%' and v.estado = 'preenchida'
) y order by ordem;

-- ── Contra-prova das exclusões: a amostra só aparece porque ficou fora delas ────
-- Marca a casa 1 como demonstração e a casa 2 como equipe, conta de novo e desfaz (savepoint).
savepoint exclusoes;
update public.usuario set demonstracao = true where id = 'fb000000-0000-4000-8001-000000000001';
insert into privado.conta_equipe (usuario_id) values ('fb000000-0000-4000-8001-000000000002');
\echo '=== EXCLUSOES (vagas da amostra visíveis em metrica.funil_por_vaga) ==='
select ordem, caso, medido, esperado, case when medido = esperado then 'OK' else 'FALHA' end as resultado
from (
  select 1 as ordem, 'com a casa 1 em demonstração e a casa 2 na equipe' as caso, count(*) as medido, 16 as esperado
    from metrica.funil_por_vaga where vaga_id::text like 'fb000000-%'
) z;
rollback to savepoint exclusoes;
select 'depois de desfazer' as caso, count(*) as medido, 20 as esperado,
       case when count(*) = 20 then 'OK' else 'FALHA' end as resultado
  from metrica.funil_por_vaga where vaga_id::text like 'fb000000-%';

:fim;
