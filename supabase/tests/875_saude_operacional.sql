-- 875_saude_operacional.sql
--
-- Sonda operacional da Edge Function saude, fase 2 (Cartão bB0tV5R8).
-- Migração: 20261117100000_saude_operacional.sql
--
-- Casos cobertos:
--   1. Estrutura e segurança: definer, search_path vazio, stable, grants só do service_role.
--   2. Todos os sinais frescos -> saudavel.
--   3. Job de entrega de e-mail: atrasado e inativo são detectados; religado, volta.
--   4. Job do registro de acessos: ignorado com a coleta desligada; detectado com ela ligada.
--   5. Filas de e-mail e de despacho: mensagem velha derruba, mensagem nova não.
--   6. pg_net: falha de transporte na janela derruba; fora da janela ou recusa 4xx não;
--      tabela ilegível ou erro de leitura devolve transporte_legivel = false e NÃO adoece.
--   7. SMTP: falha gravada por enviar-email na janela derruba; outra origem ou fora da janela, não.
--   8. RN15: o retorno não tem coluna com nome de job, fila ou tabela.

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_temp;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-16 12:00:00-03';

-- O gatilho de pgmq.q_despacho chama privado.disparar_despacho, que aborta sem segredo.
-- O valor é definido na transação para não depender do segredo global do ambiente.
set local frila.agendador_secret = 'segredo-de-teste-875';

select plan(51);

-- ── 1. Estrutura e segurança ──────────────────────────────────────────────────

select has_function(
  'privado',
  'consultar_saude_operacional',
  array['numeric', 'numeric', 'numeric', 'numeric', 'integer', 'integer', 'integer', 'integer'],
  'privado.consultar_saude_operacional existe com os tipos esperados'
);

select ok(
  (select p.prosecdef
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'consultar_saude_operacional'),
  'é SECURITY DEFINER'
);

select ok(
  (select p.proconfig @> array['search_path=""']
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'consultar_saude_operacional'),
  'opera com search_path vazio'
);

select is(
  (select p.provolatile::text
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'consultar_saude_operacional'),
  's',
  'é STABLE: a sonda só lê'
);

select ok(
  has_function_privilege('service_role', 'privado.consultar_saude_operacional(numeric, numeric, numeric, numeric, integer, integer, integer, integer)', 'execute'),
  'service_role pode executar'
);

select ok(
  not has_function_privilege('anon', 'privado.consultar_saude_operacional(numeric, numeric, numeric, numeric, integer, integer, integer, integer)', 'execute'),
  'anon não pode executar'
);

select ok(
  not has_function_privilege('authenticated', 'privado.consultar_saude_operacional(numeric, numeric, numeric, numeric, integer, integer, integer, integer)', 'execute'),
  'authenticated não pode executar'
);

select ok(
  not has_function_privilege('public', 'privado.consultar_saude_operacional(numeric, numeric, numeric, numeric, integer, integer, integer, integer)', 'execute'),
  'public não pode executar'
);

-- ── 2. Estado inicial saudável ────────────────────────────────────────────────

do $$
declare
  v_agora timestamptz := privado.agora();
  v_entrega bigint;
  v_registro bigint;
begin
  select jobid into v_entrega from cron.job where jobname = 'processar_fila_email';
  select jobid into v_registro from cron.job where jobname = 'consumir_registro_acesso';

  perform cron.alter_job(v_entrega, active := true);
  perform cron.alter_job(v_registro, active := true);

  -- Isolamento dentro da transação do teste.
  delete from cron.job_run_details where jobid in (v_entrega, v_registro);
  delete from pgmq.q_email;
  delete from pgmq.q_despacho;
  delete from net._http_response;
  delete from privado.falha_execucao where origem = 'enviar_email';
  update privado.registro_acesso_coleta set ligada = false;

  insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
  values
    (v_entrega,  999911, 1001, 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', v_agora - interval '30 seconds', v_agora - interval '30 seconds'),
    (v_registro, 999912, 1002, 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', v_agora - interval '20 minutes', v_agora - interval '20 minutes');
end $$;

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'todos os sinais frescos: saudavel = true'
);

select is(
  (select status from privado.consultar_saude_operacional()),
  'saudavel',
  'status inicial é saudavel'
);

select is(
  (select entrega_idade_segundos from privado.consultar_saude_operacional()),
  30.00::numeric,
  'a idade do job de entrega é a do último sucesso (30 s)'
);

select is(
  (select fila_idade_segundos from privado.consultar_saude_operacional()),
  null::numeric,
  'sem mensagem em nenhuma fila, a idade da fila é nula'
);

-- ── 3. Job de entrega de e-mail ───────────────────────────────────────────────

update cron.job_run_details
   set start_time = privado.agora() - interval '11 minutes',
       end_time   = privado.agora() - interval '11 minutes'
 where runid = 999911;

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  false,
  'entrega: último sucesso há 11 min (> 600 s) derruba a sonda'
);

select is(
  (select status from privado.consultar_saude_operacional()),
  'atrasado',
  'entrega atrasada: status atrasado'
);

update cron.job_run_details
   set start_time = privado.agora() - interval '9 minutes',
       end_time   = privado.agora() - interval '9 minutes'
 where runid = 999911;

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'entrega: último sucesso há 9 min (dentro de 600 s) não derruba'
);

select is(
  (select saudavel from privado.consultar_saude_operacional(p_tol_entrega_s := 5)),
  false,
  'entrega: tolerância apertada (5 s) derruba um job com sucesso há 9 min'
);

update cron.job_run_details
   set start_time = privado.agora() - interval '30 seconds',
       end_time   = privado.agora() - interval '30 seconds'
 where runid = 999911;

do $$
begin
  perform cron.alter_job((select jobid from cron.job where jobname = 'processar_fila_email'), active := false);
end $$;

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  false,
  'entrega: job inativo com sucesso recente derruba a sonda'
);

select is(
  (select entrega_ativo from privado.consultar_saude_operacional()),
  false,
  'entrega_ativo = false quando o job foi desativado'
);

do $$
begin
  perform cron.alter_job((select jobid from cron.job where jobname = 'processar_fila_email'), active := true);
end $$;

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'entrega: religado, a sonda volta a saudavel (o "voltou")'
);

delete from cron.job_run_details
 where jobid = (select jobid from cron.job where jobname = 'processar_fila_email');

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  false,
  'entrega: job ativo sem nenhum sucesso no histórico derruba'
);

insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
values (
  (select jobid from cron.job where jobname = 'processar_fila_email'),
  999913, 1003, 'postgres', 'postgres', 'select 1', 'failed', 'erro', privado.agora() - interval '10 seconds', privado.agora() - interval '10 seconds'
);

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  false,
  'entrega: execução recente que FALHOU não conta como sucesso'
);

delete from cron.job_run_details where runid = 999913;
insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
values (
  (select jobid from cron.job where jobname = 'processar_fila_email'),
  999911, 1001, 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', privado.agora() - interval '30 seconds', privado.agora() - interval '30 seconds'
);

-- ── 4. Job do registro de acessos ─────────────────────────────────────────────

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'registro: coleta desligada e job com último sucesso há 20 min é ignorado'
);

select is(
  (select registro_idade_segundos from privado.consultar_saude_operacional()),
  null::numeric,
  'registro: com a coleta desligada a idade não é medida'
);

update privado.registro_acesso_coleta set ligada = true;

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  false,
  'registro: coleta ligada e job com último sucesso há 20 min derruba a sonda'
);

select is(
  (select status from privado.consultar_saude_operacional()),
  'atrasado',
  'registro parado: status atrasado'
);

update cron.job_run_details
   set start_time = privado.agora() - interval '1 minute',
       end_time   = privado.agora() - interval '1 minute'
 where runid = 999912;

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'registro: coleta ligada e job com sucesso há 1 min é saudavel'
);

do $$
begin
  perform cron.alter_job((select jobid from cron.job where jobname = 'consumir_registro_acesso'), active := false);
end $$;

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  false,
  'registro: coleta ligada e job inativo derruba a sonda'
);

do $$
begin
  perform cron.alter_job((select jobid from cron.job where jobname = 'consumir_registro_acesso'), active := true);
end $$;
update privado.registro_acesso_coleta set ligada = false;

-- ── 5. Filas ──────────────────────────────────────────────────────────────────

select pgmq.send('email', '{"tipo":"teste_875"}'::jsonb);
update pgmq.q_email set enqueued_at = privado.agora() - interval '16 minutes';

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  false,
  'fila de e-mail: mensagem há 16 min (> 900 s) derruba a sonda'
);

select is(
  (select status from privado.consultar_saude_operacional()),
  'degradado',
  'fila parada: status degradado'
);

select is(
  (select fila_idade_segundos from privado.consultar_saude_operacional()),
  960.00::numeric,
  'fila_idade_segundos é a idade da mensagem mais velha'
);

update pgmq.q_email set enqueued_at = privado.agora() - interval '14 minutes';

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'fila de e-mail: mensagem há 14 min (dentro de 900 s) não derruba'
);

delete from pgmq.q_email;
select pgmq.send('despacho', '{"tipo":"teste_875"}'::jsonb);
update pgmq.q_despacho set enqueued_at = privado.agora() - interval '16 minutes';

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  false,
  'fila de despacho: mensagem há 16 min derruba a sonda'
);

delete from pgmq.q_despacho;

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'filas esvaziadas: a sonda volta a saudavel'
);

-- ── 6. pg_net ─────────────────────────────────────────────────────────────────

insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values
  (8751, null, null, null, null, true,  null,      privado.agora() - interval '5 minutes'),
  (8752, null, null, null, null, false, 'timeout', privado.agora() - interval '4 minutes');

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'pg_net: 2 falhas de transporte (< 3) na janela não derrubam'
);

insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values (8753, 503, 'text/html', '{}'::jsonb, 'indisponivel', false, null, privado.agora() - interval '3 minutes');

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  false,
  'pg_net: 3 falhas de transporte (timeout, erro e 5xx) na janela derrubam a sonda'
);

select is(
  (select status from privado.consultar_saude_operacional()),
  'degradado',
  'pg_net: status degradado'
);

select is(
  (select transporte_falhas from privado.consultar_saude_operacional()),
  3,
  'transporte_falhas conta as 3 falhas'
);

select is(
  (select transporte_legivel from privado.consultar_saude_operacional()),
  true,
  'transporte_legivel = true quando net._http_response é lida'
);

delete from net._http_response;
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values
  (8754, 502, 'text/html', '{}'::jsonb, 'x', false, null, privado.agora() - interval '16 minutes'),
  (8755, 502, 'text/html', '{}'::jsonb, 'x', false, null, privado.agora() - interval '20 minutes'),
  (8756, 502, 'text/html', '{}'::jsonb, 'x', false, null, privado.agora() - interval '30 minutes');

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'pg_net: falhas mais velhas que a janela de 15 min não contam'
);

delete from net._http_response;
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values
  (8757, 404, 'application/json', '{}'::jsonb, '{}', false, null, privado.agora() - interval '2 minutes'),
  (8758, 401, 'application/json', '{}'::jsonb, '{}', false, null, privado.agora() - interval '2 minutes'),
  (8759, 403, 'application/json', '{}'::jsonb, '{}', false, null, privado.agora() - interval '2 minutes');

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'pg_net: recusa 401, 403 e 404 não é falha de transporte (o verificar_saude tem alerta próprio)'
);

delete from net._http_response;
insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg, created)
values
  (8760, 500, 'text/html', '{}'::jsonb, 'x', false, null, privado.agora() - interval '2 minutes'),
  (8761, 500, 'text/html', '{}'::jsonb, 'x', false, null, privado.agora() - interval '2 minutes'),
  (8762, 500, 'text/html', '{}'::jsonb, 'x', false, null, privado.agora() - interval '2 minutes');

savepoint s_sem_pgnet;
set local frila.simular_sem_pgnet = 'on';

select is(
  (select transporte_legivel from privado.consultar_saude_operacional()),
  false,
  'pg_net ilegível: transporte_legivel = false'
);

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'pg_net ilegível NÃO adoece a sonda, mesmo com falhas gravadas na tabela'
);
rollback to savepoint s_sem_pgnet;

savepoint s_excecao_pgnet;
set local frila.simular_excecao_pgnet = 'on';

select is(
  (select transporte_legivel from privado.consultar_saude_operacional()),
  false,
  'erro ao ler o pg_net: transporte_legivel = false, sem derrubar a função'
);

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'erro ao ler o pg_net NÃO adoece a sonda'
);
rollback to savepoint s_excecao_pgnet;

delete from net._http_response;

-- ── 7. SMTP ───────────────────────────────────────────────────────────────────

select privado.registrar_falha_execucao('saude', 'operacao_degradada', null);

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'SMTP: falha de outra origem não conta'
);

select privado.registrar_falha_execucao('enviar_email', 'falha_de_autenticacao', null);

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  false,
  'SMTP: uma falha de enviar_email na janela derruba a sonda'
);

select is(
  (select entrega_falhas from privado.consultar_saude_operacional()),
  1,
  'entrega_falhas conta a falha'
);

select is(
  (select saudavel from privado.consultar_saude_operacional(p_teto_smtp := 2)),
  true,
  'SMTP: com teto 2, uma falha só não derruba'
);

update privado.falha_execucao
   set criada_em = privado.agora() - interval '40 minutes'
 where origem = 'enviar_email';

select is(
  (select saudavel from privado.consultar_saude_operacional()),
  true,
  'SMTP: falha mais velha que a janela (30 min) não conta; a sonda volta a saudavel'
);

-- ── 8. RN15 ───────────────────────────────────────────────────────────────────

select is(
  (
    select count(*)::int
      from (
        select c.nome, c.modo
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace,
          unnest(p.proargnames, p.proargmodes) as c(nome, modo)
         where n.nspname = 'privado' and p.proname = 'consultar_saude_operacional'
      ) colunas
     where colunas.modo::text = 't'
       and colunas.nome ~* '(pgmq|q_email|q_despacho|cron|pg_net|http_response|smtp|falha_execucao|processar_fila|consumir_registro|reprocessar|verificar_saude|usuario|email|telefone|nome|vaga)'
  ),
  0,
  'RN15: nenhuma coluna do retorno tem nome de job, fila, tabela ou dado pessoal'
);

select is(
  (
    select count(*)::int
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace,
      unnest(p.proargnames, p.proargmodes) as c(nome, modo)
     where n.nspname = 'privado' and p.proname = 'consultar_saude_operacional'
       and c.modo::text = 't'
  ),
  10,
  'o retorno tem as 10 colunas genéricas desenhadas'
);

rollback;
