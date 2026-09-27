-- 310_consultas_quentes_df.sql
-- Validação de índices do caminho quente e ausência de varredura sequencial (RNF11)
-- Cartão IYAb8v1i

begin;
select plan(8);

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

-- ── 1. Existência e integridade dos novos índices ───────────────────────────────

-- 1.1 Índice funcional para filtro por data em vagas publicadas
select ok(
  (select indexdef from pg_indexes
    where schemaname = 'public' and tablename = 'vaga' and indexname = 'vaga_data_publicada')
    ~* 'inicio_em.*America/Sao_Paulo.*date',
  'RNF11: índice funcional vaga_data_publicada existe com timezone America/Sao_Paulo'
);

select ok(
  (select indexdef from pg_indexes
    where schemaname = 'public' and tablename = 'vaga' and indexname = 'vaga_data_publicada')
    ~* 'WHERE.*publicada',
  'RNF11: índice vaga_data_publicada é parcial para estado = publicada'
);

-- 1.2 Índice composto para filtro por funcao_id e data em vagas publicadas
select ok(
  (select indexdef from pg_indexes
    where schemaname = 'public' and tablename = 'vaga' and indexname = 'vaga_publicada_busca')
    ~* 'funcao_id.*inicio_em',
  'RNF11: índice composto vaga_publicada_busca existe cobrindo funcao_id e data'
);

select ok(
  (select indexdef from pg_indexes
    where schemaname = 'public' and tablename = 'vaga' and indexname = 'vaga_publicada_busca')
    ~* 'WHERE.*publicada',
  'RNF11: índice vaga_publicada_busca é parcial para estado = publicada'
);

-- 1.3 Índice para consulta semanal de disponibilidade (privado.elegiveis)
select ok(
  (select indexdef from pg_indexes
    where schemaname = 'public' and tablename = 'disponibilidade' and indexname = 'disponibilidade_dia_horario')
    ~* 'dia_semana.*hora_inicio.*hora_fim.*profissional_id',
  'RNF11: índice disponibilidade_dia_horario cobre dia_semana, horários e profissional_id'
);

-- ── 2. Ausência de varredura sequencial nos caminhos quentes ───────────────────

-- 2.1 Consulta de vagas abertas por data (sem funcao_id)
select ok(
  pg_temp.explicar($$
    select * from public.vaga v
     where v.estado = 'publicada'
       and (v.inicio_em at time zone 'America/Sao_Paulo')::date = '2026-10-02'::date
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
       and (v.inicio_em at time zone 'America/Sao_Paulo')::date = '2026-10-02'::date
     order by v.ponto operator(extensions.<->) extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8850, -15.7900), 4326)::extensions.geography
     limit 30
  $$) !~* 'Seq Scan on vaga',
  'RNF11: vagas_abertas por funcao e data não faz Seq Scan em vaga'
);

-- 2.3 Consulta de disponibilidade em privado.elegiveis
select ok(
  pg_temp.explicar($$
    select d.profissional_id
      from public.disponibilidade d
     where d.dia_semana = 5
       and d.hora_inicio > d.hora_fim
  $$) !~* 'Seq Scan on disponibilidade',
  'RNF11: filtro semanal de disponibilidade não faz Seq Scan em disponibilidade'
);

select * from finish();
rollback;
