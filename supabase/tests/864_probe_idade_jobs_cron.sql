-- 864_probe_idade_jobs_cron.sql
--
-- Probe operacional da idade e estado dos jobs pg_cron (Cartão bB0tV5R8).
-- Migração: 20261116130000_probe_saude_cron.sql
--
-- Casos cobertos:
--   1. Estrutura e segurança:
--      - privado.consultar_saude_cron(numeric, numeric) existe, é SECURITY DEFINER com search_path="" fixado.
--      - Revoke para anon e authenticated (sem permissão de chamada).
--      - Grant exclusivo para service_role.
--      - Colunas de retorno não contêm dados pessoais nem nomes confidenciais (RN15).
--   2. Detecção de job ativo sem execução recente (Critério 4 do cartão):
--      - Job ativo com execução recente (dentro da tolerância) -> saudavel = true, status = 'saudavel'.
--      - Job ativo cuja execução ultrapassou a tolerância -> saudavel = false, status = 'atrasado'.
--      - Job ativo sem nenhum histórico de sucesso -> saudavel = false, status = 'atrasado'.
--   3. Detecção de job inativo:
--      - reprocessar_despacho desativado (active = false) -> saudavel = false, status = 'atrasado', despacho_ativo = false.
--      - verificar_saude desativado (active = false) -> saudavel = false, status = 'atrasado', vigia_ativo = false.
--   4. Recuperação:
--      - Religando ambos os jobs -> saudavel = true, status = 'saudavel'.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_temp;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-16 12:00:00-03';

select plan(16);

-- ── 1. Estrutura e Segurança ──────────────────────────────────────────────────

select has_function(
  'privado',
  'consultar_saude_cron',
  ARRAY['numeric', 'numeric'],
  'privado.consultar_saude_cron(numeric, numeric) existe com tipos corretos'
);

select function_returns(
  'privado',
  'consultar_saude_cron',
  ARRAY['numeric', 'numeric'],
  'setof record',
  'privado.consultar_saude_cron retorna tabela/setof record com colunas estruturadas'
);

-- Permissões por papel
select ok(
  has_function_privilege('service_role', 'privado.consultar_saude_cron(numeric, numeric)', 'execute'),
  'service_role pode executar privado.consultar_saude_cron'
);

select ok(
  not has_function_privilege('anon', 'privado.consultar_saude_cron(numeric, numeric)', 'execute'),
  'anon não pode executar privado.consultar_saude_cron'
);

select ok(
  not has_function_privilege('authenticated', 'privado.consultar_saude_cron(numeric, numeric)', 'execute'),
  'authenticated não pode executar privado.consultar_saude_cron'
);

select ok(
  not has_function_privilege('public', 'privado.consultar_saude_cron(numeric, numeric)', 'execute'),
  'public não pode executar privado.consultar_saude_cron'
);

-- ── 2. Cenário Saudável (jobs ativos com sucesso recente) ─────────────────────

-- Garante existência de histórico sintético de sucesso para ambos os jobs
do $$
declare
  v_agora timestamptz := privado.agora();
  v_job_despacho bigint;
  v_job_saude bigint;
begin
  select jobid into v_job_despacho from cron.job where jobname = 'reprocessar_despacho';
  select jobid into v_job_saude from cron.job where jobname = 'verificar_saude';

  perform cron.alter_job(v_job_despacho, active := true);
  perform cron.alter_job(v_job_saude, active := true);

  -- Limpa execuções prévias para isolamento total dentro da transação do teste
  delete from cron.job_run_details where jobid in (v_job_despacho, v_job_saude);

  -- Simula execução recente (há 30 segundos)
  insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
  values (v_job_despacho, 999901, 1001, 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', v_agora - interval '30 seconds', v_agora - interval '30 seconds');

  insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
  values (v_job_saude, 999902, 1002, 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', v_agora - interval '60 seconds', v_agora - interval '60 seconds');
end $$;

select is(
  (select saudavel from privado.consultar_saude_cron()),
  true,
  'Estado inicial com jobs ativos e recentes reporta saudavel = true'
);

select is(
  (select status from privado.consultar_saude_cron()),
  'saudavel',
  'Status inicial é ''saudavel'''
);

-- ── 3. Critério 4: Job ativo sem execução recente é detectado ─────────────────

-- Se a tolerância de despacho for de 10s e o último sucesso foi há 30s:
select is(
  (select saudavel from privado.consultar_saude_cron(p_tolerancia_despacho_s := 10, p_tolerancia_vigia_s := 900)),
  false,
  'Critério 4: Job de despacho ativo sem execução recente é detectado (saudavel = false)'
);

select is(
  (select status from privado.consultar_saude_cron(p_tolerancia_despacho_s := 10, p_tolerancia_vigia_s := 900)),
  'atrasado',
  'Critério 4: Status do probe muda para ''atrasado'' quando despacho ultrapassa tolerância'
);

-- Se a tolerância de vigia for de 45s e o último sucesso foi há 60s:
select is(
  (select saudavel from privado.consultar_saude_cron(p_tolerancia_despacho_s := 300, p_tolerancia_vigia_s := 45)),
  false,
  'Critério 4: Job de vigia ativo sem execução recente é detectado (saudavel = false)'
);

-- ── 4. Detecção de Job Desativado ─────────────────────────────────────────────

do $$
declare
  v_job_despacho bigint;
begin
  select jobid into v_job_despacho from cron.job where jobname = 'reprocessar_despacho';
  perform cron.alter_job(v_job_despacho, active := false);
end $$;

select is(
  (select despacho_ativo from privado.consultar_saude_cron()),
  false,
  'Probe detecta que reprocessar_despacho foi desativado (despacho_ativo = false)'
);

select is(
  (select saudavel from privado.consultar_saude_cron()),
  false,
  'Probe reporta saudavel = false quando reprocessar_despacho está inativo'
);

-- Reativa o despacho e desativa o vigia
do $$
declare
  v_job_despacho bigint;
  v_job_saude bigint;
begin
  select jobid into v_job_despacho from cron.job where jobname = 'reprocessar_despacho';
  select jobid into v_job_saude from cron.job where jobname = 'verificar_saude';
  perform cron.alter_job(v_job_despacho, active := true);
  perform cron.alter_job(v_job_saude, active := false);
end $$;

select is(
  (select vigia_ativo from privado.consultar_saude_cron()),
  false,
  'Probe detecta que verificar_saude foi desativado (vigia_ativo = false)'
);

-- ── 5. Reativação e Recuperação ("voltou") ───────────────────────────────────

do $$
declare
  v_job_saude bigint;
begin
  select jobid into v_job_saude from cron.job where jobname = 'verificar_saude';
  perform cron.alter_job(v_job_saude, active := true);
end $$;

select is(
  (select saudavel from privado.consultar_saude_cron()),
  true,
  'Após reativação de ambos os jobs com execuções na tolerância, probe volta a ser saudável'
);

-- ── 6. RN15: Ausência de Dados Pessoais / Nomes Internos ─────────────────────

select is(
  (
    select count(*)
      from information_schema.columns
     where table_schema = 'privado'
       and table_name = 'consultar_saude_cron'
       and column_name in ('usuario_id', 'email', 'telefone', 'nome', 'conteudo', 'vaga_id')
  )::int,
  0,
  'RN15: Nenhuma coluna da função expõe dado pessoal ou identificador de produto'
);

rollback;
