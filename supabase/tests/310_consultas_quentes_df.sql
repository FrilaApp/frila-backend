-- 310_consultas_quentes_df.sql
-- Validação de índices do caminho quente e ausência de varredura sequencial (RNF11)
-- Cartão IYAb8v1i

begin;
select plan(11);

-- Helper para inspecionar planos de consulta sem executar
create function pg_temp.explicar(p_sql text) returns text
language plpgsql as $$
declare
  linha text;
  saida text := '';
begin
  for linha in execute 'explain ' || p_sql loop
    saida := saida || E'\n' || linha;
  end loop;
  return saida;
end $$;

-- ── 1. Existência e integridade do índice funcional vaga_data_publicada ─────────

-- 1.1 Expressão funcional sobre a data no fuso de Brasília (America/Sao_Paulo)
select ok(
  (select indexdef from pg_indexes
    where schemaname = 'public' and tablename = 'vaga' and indexname = 'vaga_data_publicada')
    ~* 'inicio_em.*America/Sao_Paulo.*date',
  'RNF11: índice funcional vaga_data_publicada existe com timezone America/Sao_Paulo'
);

-- 1.2 Condição parcial restrita ao estado publicada
select ok(
  (select indexdef from pg_indexes
    where schemaname = 'public' and tablename = 'vaga' and indexname = 'vaga_data_publicada')
    ~* 'WHERE.*publicada',
  'RNF11: índice vaga_data_publicada é parcial para estado = publicada'
);

-- 1.3 Comentário descritivo documentando o índice
select ok(
  (select description from pg_description
    where objoid = 'public.vaga_data_publicada'::regclass) is not null,
  'RNF11: índice vaga_data_publicada possui comentário documentando a finalidade'
);

-- ── 2. Ausência de varredura sequencial nos caminhos quentes com volume controlado ─
-- Geramos 500 vagas fictícias distribuídas em dias diferentes dentro da transação.
-- Isso fornece volume controlado ao planejador sem poluir o banco (rollback ao final).
-- enable_seqscan = off assegura que o teste afere a usabilidade técnica do índice
-- sem quebrar sob oscilações de estatísticas de autoanalyze da CI.

insert into public.vaga
select
  gen_random_uuid(),
  v.estabelecimento_id,
  v.evento_id,
  v.funcao_id,
  '2026-10-01 10:00:00+00'::timestamptz + (i || ' hours')::interval,
  '2026-10-01 16:00:00+00'::timestamptz + (i || ' hours')::interval,
  v.local,
  extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8850 + (i * 0.001), -15.7900 + (i * 0.001)), 4326)::extensions.geography,
  v.valor_centavos,
  v.posicoes,
  v.inclui_refeicao,
  v.inclui_transporte,
  v.exige_material_proprio,
  v.responsavel_local,
  v.traje,
  v.participa_rateio,
  v.observacoes,
  v.modo,
  v.alerta_antecedencia,
  'publicada',
  v.publicado_em,
  gen_random_uuid(),
  v.publicado_por
from generate_series(1, 500) i
-- A vaga-modelo em modo urgência, e escolhida por id. Sem o filtro, `limit 1` pegava a
-- primeira da ordem física da tabela; se fosse a d…05 do cenário, em modo seleção, o
-- CHECK `selecao_com_antecedencia` compara as datas fixas de outubro com o
-- `publicado_em` dela, que anda com o dia do reset — e o teste passaria a falhar a
-- partir de 01/10/2026, dependendo de qual linha o agendador tivesse regravado antes.
cross join (select * from public.vaga
             where estado = 'publicada' and modo = 'urgencia'
             order by id limit 1) v;

analyze public.vaga;

set local enable_seqscan = off;

-- 2.1 Consulta de vagas abertas por data (sem funcao_id)
select ok(
  pg_temp.explicar($$
    select * from public.vaga v
     where v.estado = 'publicada'
       and (v.inicio_em at time zone 'America/Sao_Paulo')::date = '2026-10-05'::date
     order by v.ponto operator(extensions.<->) extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8850, -15.7900), 4326)::extensions.geography
     limit 30
  $$) ~* 'vaga_data_publicada',
  'RNF11: vagas_abertas por data utiliza o índice vaga_data_publicada'
);

select ok(
  pg_temp.explicar($$
    select * from public.vaga v
     where v.estado = 'publicada'
       and (v.inicio_em at time zone 'America/Sao_Paulo')::date = '2026-10-05'::date
     order by v.ponto operator(extensions.<->) extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8850, -15.7900), 4326)::extensions.geography
     limit 30
  $$) !~* 'Seq Scan on vaga',
  'RNF11: vagas_abertas por data não faz Seq Scan em vaga'
);

-- 2.2 Consulta de vagas abertas com funcao_id e data
select ok(
  pg_temp.explicar($$
    select * from public.vaga v
     where v.estado = 'publicada'
       and v.funcao_id = '8f084926-2256-4c68-9b98-3855297f03e3'::uuid
       and (v.inicio_em at time zone 'America/Sao_Paulo')::date = '2026-10-05'::date
     order by v.ponto operator(extensions.<->) extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8850, -15.7900), 4326)::extensions.geography
     limit 30
  $$) ~* 'vaga_data_publicada',
  'RNF11: vagas_abertas por funcao e data utiliza vaga_data_publicada'
);

select ok(
  pg_temp.explicar($$
    select * from public.vaga v
     where v.estado = 'publicada'
       and v.funcao_id = '8f084926-2256-4c68-9b98-3855297f03e3'::uuid
       and (v.inicio_em at time zone 'America/Sao_Paulo')::date = '2026-10-05'::date
     order by v.ponto operator(extensions.<->) extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8850, -15.7900), 4326)::extensions.geography
     limit 30
  $$) !~* 'Seq Scan on vaga',
  'RNF11: vagas_abertas por funcao e data não faz Seq Scan em vaga'
);

-- 2.3 Consulta de disponibilidade em privado.elegiveis (formato canônico da RPC: profissional_id + dia_semana)
select ok(
  pg_temp.explicar($$
    select 1 from public.disponibilidade d
     where d.profissional_id = '5520d830-4a17-4300-9117-cb2fedcee638'::uuid
       and d.dia_semana = 5
  $$) ~* 'disponibilidade_busca|disponibilidade_pkey|disponibilidade_profissional_id',
  'RNF11: consulta de disponibilidade em elegiveis utiliza índice cobrindo profissional e dia'
);

select ok(
  pg_temp.explicar($$
    select 1 from public.disponibilidade d
     where d.profissional_id = '5520d830-4a17-4300-9117-cb2fedcee638'::uuid
       and d.dia_semana = 5
  $$) !~* 'Seq Scan on disponibilidade',
  'RNF11: consulta de disponibilidade em elegiveis não faz Seq Scan em disponibilidade'
);

-- 2.4 Consulta do teto de notificações (RN23)
select ok(
  pg_temp.explicar($$
    select enviada_em from public.notificacao
     where profissional_id = '5520d830-4a17-4300-9117-cb2fedcee638'::uuid
       and tipo in ('vaga', 'vagas_agrupadas')
     order by enviada_em desc
     limit 1
  $$) ~* 'notificacao_teto',
  'RNF11: consulta do teto de notificações (RN23) utiliza índice notificacao_teto'
);

select ok(
  pg_temp.explicar($$
    select enviada_em from public.notificacao
     where profissional_id = '5520d830-4a17-4300-9117-cb2fedcee638'::uuid
       and tipo in ('vaga', 'vagas_agrupadas')
     order by enviada_em desc
     limit 1
  $$) !~* 'Seq Scan on notificacao',
  'RNF11: consulta do teto de notificações não faz Seq Scan em notificacao'
);

select * from finish();
rollback;
