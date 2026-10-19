-- 20261008100000_categoria_suporte_e_origem_ocorrencia.sql
--
-- Suporte por e-mail a partir do turno (v1.1, RF23, UC14, D1=C, D7, D10, D13).
-- Passo P1:
--   1. Enum public.categoria_suporte ('endereco', 'atraso', 'conduta', 'seguranca', 'outro')
--   2. Coluna public.ocorrencia.origem text com check (origem in ('app', 'operacao')), nullable
--   3. Função privado.limite_de_suporte_por_dia() retornando 5 (D13)

-- ── 1. Enum CategoriaSuporte ──────────────────────────────────────────────────

create type public.categoria_suporte as enum (
  'endereco',
  'atraso',
  'conduta',
  'seguranca',
  'outro'
);

comment on type public.categoria_suporte is
  'Motivo do chamado de suporte aberto a partir de um turno (UC14, contrato 0.2.40).';

-- ── 2. Coluna origem em ocorrencia ────────────────────────────────────────────
--
-- Distingue chamados abertos pelo app ('app') de ações da operação interna ('operacao').
-- Linhas antigas permanecem com origem nula (F8: imutabilidade e histórico intocados).
alter table public.ocorrencia
  add column origem text check (origem in ('app', 'operacao'));

comment on column public.ocorrencia.origem is
  'Canal de abertura da ocorrência: app (pelo usuário via abrir_suporte) ou operacao (ação interna). Nulo para ocorrências legadas.';

-- ── 3. Teto diário de chamados de suporte por conta ───────────────────────────
--
-- Quantos chamados novos de suporte ('app') uma conta pode abrir por dia no fuso
-- de Brasília antes de receber 429 limite_excedido (D10, D13, SU-RN06).
create or replace function privado.limite_de_suporte_por_dia() returns int
language sql immutable set search_path = '' as $$
  select 5
$$;

revoke execute on function privado.limite_de_suporte_por_dia() from public, anon, authenticated;
grant  execute on function privado.limite_de_suporte_por_dia() to service_role;

comment on function privado.limite_de_suporte_por_dia() is
  'Limite diário de novos chamados de suporte abertos pelo app por conta (D13). Ajustável por migração.';
