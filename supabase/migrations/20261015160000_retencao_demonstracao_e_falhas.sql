-- Higiene operacional periódica: purga de tentativas de entrada na demonstração
-- (> 30 dias, Achado 5) e falhas de execução operacionais (> 60 dias, Achado 6).
--
-- Prazos propostos sujeitos a validação do dono da plataforma:
-- - public.entrada_demonstracao: 30 dias (mesmo prazo dos arquivos pgmq.a_despacho e pgmq.a_email).
-- - privado.falha_execucao: 60 dias (histórico para depuração de erros transitórios).

create or replace function privado.higienizar_tabelas()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cron_removidos   integer := 0;
  v_pgmq_removidos   integer := 0;
  v_email_removidos  integer := 0;
  v_demo_removidos   integer := 0;
  v_falhas_removidas integer := 0;
begin
  -- 1. cron.job_run_details com mais de 7 dias
  if exists (
    select 1 from pg_catalog.pg_tables
     where schemaname = 'cron' and tablename = 'job_run_details'
  ) then
    delete from cron.job_run_details
     where start_time < privado.agora() - interval '7 days';
    get diagnostics v_cron_removidos = row_count;
  end if;

  -- 2. Arquivo do pgmq com mais de 30 dias (pgmq.a_despacho)
  if exists (
    select 1 from pg_catalog.pg_tables
     where schemaname = 'pgmq' and tablename = 'a_despacho'
  ) then
    delete from pgmq.a_despacho
     where archived_at < privado.agora() - interval '30 days';
    get diagnostics v_pgmq_removidos = row_count;
  end if;

  -- 3. Arquivo dos pedidos de e-mail com mais de 30 dias (pgmq.a_email)
  if exists (
    select 1 from pg_catalog.pg_tables
     where schemaname = 'pgmq' and tablename = 'a_email'
  ) then
    delete from pgmq.a_email
     where archived_at < privado.agora() - interval '30 days';
    get diagnostics v_email_removidos = row_count;
  end if;

  -- 4. public.entrada_demonstracao com mais de 30 dias (Achado 5 da caçada)
  if exists (
    select 1 from pg_catalog.pg_tables
     where schemaname = 'public' and tablename = 'entrada_demonstracao'
  ) then
    delete from public.entrada_demonstracao
     where em < privado.agora() - interval '30 days';
    get diagnostics v_demo_removidos = row_count;
  end if;

  -- 5. privado.falha_execucao com mais de 60 dias (Achado 6 da caçada)
  if exists (
    select 1 from pg_catalog.pg_tables
     where schemaname = 'privado' and tablename = 'falha_execucao'
  ) then
    delete from privado.falha_execucao
     where criada_em < privado.agora() - interval '60 days';
    get diagnostics v_falhas_removidas = row_count;
  end if;

  return jsonb_build_object(
    'cron_job_run_details', v_cron_removidos,
    'pgmq_arquivo',         v_pgmq_removidos,
    'pgmq_arquivo_email',   v_email_removidos,
    'entrada_demonstracao', v_demo_removidos,
    'falha_execucao',       v_falhas_removidas
  );
end $$;

comment on function privado.higienizar_tabelas() is
  'Higiene operacional periódica: cron.job_run_details (> 7d), arquivos pgmq (> 30d), entrada_demonstracao (> 30d) e falha_execucao (> 60d).';

revoke execute on function privado.higienizar_tabelas() from public, anon, authenticated;
grant  execute on function privado.higienizar_tabelas() to service_role;
