-- 823_lgpd_limpeza_trilha_e_sessoes_auth.sql · LGPD-J6 T2b (migração 20261108120000).
-- privado.limpar_trilha_e_sessoes_auth apaga a trilha do Auth com mais de 6 meses, a trilha de conta excluída
-- (actor_id ou traits.user_id de conta que não existe mais, como a linha user_deleted medida no local) e SÓ as
-- sessões sem atividade há mais de 6 meses, com refresh_tokens em cascata. Piso de 6 meses, lote e teto, e erro de
-- privilégio no esquema auth registrado sem derrubar as outras etapas.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-08 12:00:00+00', true);
select plan(31);

-- Base limpa dentro da transação (desfeita no fim): só as linhas deste teste contam.
delete from auth.audit_log_entries;
delete from auth.sessions;

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'c8230000-0000-4000-8000-000000000001', 'authenticated',
        'authenticated', 'u1@t823.test', privado.agora(), privado.agora(), false, false);
-- c8230000-…-000000000002 é a conta excluída: não existe em auth.users.

create function pg_temp.trilha(id uuid, idade interval, payload json) returns void language sql as $$
  insert into auth.audit_log_entries (instance_id, id, payload, created_at, ip_address)
  values ('00000000-0000-0000-0000-000000000000', id, payload, privado.agora() - idade, '')
$$;
create function pg_temp.existe(id uuid) returns boolean language sql as $$
  select exists (select 1 from auth.audit_log_entries a where a.id = existe.id)
$$;
create function pg_temp.sessao(id uuid, criada interval, renovada interval, atualizada interval) returns void language sql as $$
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, ip)
  values (id, 'c8230000-0000-4000-8000-000000000001', privado.agora() - criada, privado.agora() - atualizada,
          (privado.agora() - renovada) at time zone 'UTC', '203.0.113.80')
$$;
create function pg_temp.tem_sessao(id uuid) returns boolean language sql as $$
  select exists (select 1 from auth.sessions s where s.id = tem_sessao.id)
$$;

-- Trilha
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000a1', interval '7 months',
  '{"action":"login","actor_id":"c8230000-0000-4000-8000-000000000001","actor_username":"u1@t823.test"}');
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000a2', interval '1 month',
  '{"action":"login","actor_id":"c8230000-0000-4000-8000-000000000001","actor_username":"u1@t823.test"}');
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000a3', interval '1 day',
  '{"action":"login","actor_id":"c8230000-0000-4000-8000-000000000002","actor_username":"u2@t823.test"}');
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000a4', interval '1 day',
  '{"action":"user_deleted","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role",
    "traits":{"user_id":"c8230000-0000-4000-8000-000000000002","user_email":"u2@t823.test"}}');
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000a5', interval '1 day',
  '{"action":"user_invited","actor_id":"00000000-0000-0000-0000-000000000000","actor_username":"service_role",
    "traits":{"user_id":"c8230000-0000-4000-8000-000000000001","user_email":"u1@t823.test"}}');
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000a6', interval '1 day',
  '{"action":"token_refreshed","actor_id":"service_role"}');
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000a7', interval '1 day', '{"action":"login"}');
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000a8', interval '6 months' - interval '1 day',
  '{"action":"login","actor_id":"c8230000-0000-4000-8000-000000000001"}');
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000a9', interval '6 months' + interval '1 day',
  '{"action":"login","actor_id":"c8230000-0000-4000-8000-000000000001"}');
-- Casos cruzados do OU: basta um dos dois lados ser conta excluída.
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000aa', interval '1 day',
  '{"action":"user_modified","actor_id":"c8230000-0000-4000-8000-000000000002",
    "traits":{"user_id":"c8230000-0000-4000-8000-000000000001"}}');
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000ab', interval '1 day',
  '{"action":"user_modified","actor_id":"c8230000-0000-4000-8000-000000000001",
    "traits":{"user_id":"c8230000-0000-4000-8000-000000000002"}}');

-- Sessões (criada, renovada, atualizada)
select pg_temp.sessao('c8230000-0000-4000-8000-0000000000b1', '1 year', '7 months', '7 months');
select pg_temp.sessao('c8230000-0000-4000-8000-0000000000b2', '1 year', '1 month', '1 month');
insert into auth.sessions (id, user_id, created_at, updated_at, ip)
values ('c8230000-0000-4000-8000-0000000000b3', 'c8230000-0000-4000-8000-000000000001',
        privado.agora() - interval '7 months', privado.agora() - interval '7 months', '203.0.113.81'),
       ('c8230000-0000-4000-8000-0000000000b4', 'c8230000-0000-4000-8000-000000000001',
        privado.agora() - interval '1 month', privado.agora() - interval '1 month', '203.0.113.82'),
       ('c8230000-0000-4000-8000-0000000000b6', 'c8230000-0000-4000-8000-000000000001', null, null, '203.0.113.84');
select pg_temp.sessao('c8230000-0000-4000-8000-0000000000b5', '1 year', '7 months', '1 day');
insert into auth.refresh_tokens (instance_id, token, user_id, revoked, created_at, updated_at, session_id)
values ('00000000-0000-0000-0000-000000000000', 'zz823-b1', 'c8230000-0000-4000-8000-000000000001', false,
        privado.agora() - interval '7 months', privado.agora() - interval '7 months', 'c8230000-0000-4000-8000-0000000000b1'),
       ('00000000-0000-0000-0000-000000000000', 'zz823-b2', 'c8230000-0000-4000-8000-000000000001', false,
        privado.agora() - interval '1 month', privado.agora() - interval '1 month', 'c8230000-0000-4000-8000-0000000000b2');

-- ── A rodada, com p_meses = 1: o piso de 6 meses vale ────────────────────────
create temp table r as select privado.limpar_trilha_e_sessoes_auth(1, 1000) as j;
select results_eq($$ select (j->>'trilha_antiga')::int, (j->>'trilha_conta_excluida')::int,
                            (j->>'sessoes_paradas')::int, j->'falhas' from r $$,
  $$ values (2, 4, 2, '[]'::jsonb) $$, 'devolve as três contagens, sem falha');
select ok(not pg_temp.existe('c8230000-0000-4000-8000-0000000000a1'), '(a) trilha de 7 meses sai');
select ok(not pg_temp.existe('c8230000-0000-4000-8000-0000000000a9'), '(a) trilha de 6 meses e 1 dia sai');
select ok(pg_temp.existe('c8230000-0000-4000-8000-0000000000a8'), '(a) trilha de 6 meses menos 1 dia fica');
select ok(pg_temp.existe('c8230000-0000-4000-8000-0000000000a2'), 'piso: p_meses = 1 não apaga a trilha de 1 mês');
select ok(not pg_temp.existe('c8230000-0000-4000-8000-0000000000a3'), '(b) trilha recente de conta excluída (actor_id) sai');
select ok(not pg_temp.existe('c8230000-0000-4000-8000-0000000000a4'),
  '(b) user_deleted com o e-mail da conta excluída em traits sai');
select ok(pg_temp.existe('c8230000-0000-4000-8000-0000000000a5'), 'ação de admin sobre conta que existe fica');
select ok(not pg_temp.existe('c8230000-0000-4000-8000-0000000000aa'), '(b) ator excluído com traits de conta viva sai');
select ok(not pg_temp.existe('c8230000-0000-4000-8000-0000000000ab'), '(b) ator vivo com traits de conta excluída sai');
select ok(pg_temp.existe('c8230000-0000-4000-8000-0000000000a6') and pg_temp.existe('c8230000-0000-4000-8000-0000000000a7'),
  'actor_id que não é uuid, ou ausente, fica até os 6 meses');
select ok(not pg_temp.tem_sessao('c8230000-0000-4000-8000-0000000000b1'), '(c) sessão renovada há 7 meses sai');
select ok(not pg_temp.tem_sessao('c8230000-0000-4000-8000-0000000000b3'), '(c) sessão nunca renovada, criada há 7 meses, sai');
select ok(pg_temp.tem_sessao('c8230000-0000-4000-8000-0000000000b2'),
  '(c) sessão criada há 1 ano e renovada há 1 mês fica');
select ok(pg_temp.tem_sessao('c8230000-0000-4000-8000-0000000000b4'), '(c) sessão criada há 1 mês fica');
select ok(pg_temp.tem_sessao('c8230000-0000-4000-8000-0000000000b5'),
  '(c) sessão renovada há 7 meses mas atualizada ontem fica');
select ok(pg_temp.tem_sessao('c8230000-0000-4000-8000-0000000000b6'), '(c) sessão sem nenhuma data fica');
select results_eq($$ select token from auth.refresh_tokens where token like 'zz823-%' order by token $$,
  $$ values ('zz823-b2'::varchar) $$, 'refresh_token da sessão apagada cai em cascata; o da que ficou, fica');

-- ── Lote e teto ──────────────────────────────────────────────────────────────
select pg_temp.trilha(gen_random_uuid(), interval '7 months' + (n || ' seconds')::interval,
  '{"action":"login","actor_id":"c8230000-0000-4000-8000-000000000001"}') from generate_series(1, 150) n;
select is((privado.limpar_trilha_e_sessoes_auth(6, 1) ->> 'trilha_antiga')::int, 100, 'teto de 100 lotes por etapa');
select is((privado.limpar_trilha_e_sessoes_auth(6, 1) ->> 'trilha_antiga')::int, 50, 'o resto sai na execução seguinte');

-- ── Erro de privilégio no esquema auth: registra e segue ─────────────────────
create function privado.zz_823_nega() returns trigger language plpgsql as $$
begin raise exception 'permission denied for table audit_log_entries' using errcode = '42501'; end $$;
create trigger zz_823_nega before delete on auth.audit_log_entries for each row execute function privado.zz_823_nega();
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000c1', interval '7 months',
  '{"action":"login","actor_id":"c8230000-0000-4000-8000-000000000002","actor_username":"u2@t823.test"}');
select pg_temp.sessao('c8230000-0000-4000-8000-0000000000b7', '1 year', '8 months', '8 months');
delete from privado.falha_execucao where origem = 'limpar_trilha_e_sessoes_auth';
select lives_ok($$ create temp table r2 as select privado.limpar_trilha_e_sessoes_auth() as j $$,
  'trilha sem permissão de apagar: a rotina não cai');
select results_eq($$ select f->>'etapa', f->>'sqlstate' from r2, jsonb_array_elements(j->'falhas') f order by 1 $$,
  $$ values ('trilha_antiga', '42501'), ('trilha_conta_excluida', '42501') $$, 'as duas etapas da trilha registram 42501');
select is((select (j->>'sessoes_paradas')::int from r2), 1, 'e a etapa das sessões segue e apaga');
select ok(pg_temp.existe('c8230000-0000-4000-8000-0000000000c1'), 'a etapa que falhou não apagou nada');
select results_eq($$ select codigo, detalhes::text !~ '@' from privado.falha_execucao where origem = 'limpar_trilha_e_sessoes_auth' $$,
  $$ values ('limpeza_auth_falhou', true) $$, 'a falha vai para falha_execucao, sem e-mail');
drop trigger zz_823_nega on auth.audit_log_entries;

-- ── Dono sem BYPASSRLS: a etapa não roda e registra, em vez de não apagar nada calada ──
-- As tabelas do Auth têm RLS ligado e nenhuma política. Um dono sem BYPASSRLS não enxerga linha nenhuma.
create role zz_823_sem_bypass nologin;
grant zz_823_sem_bypass to postgres;
-- CREATE no esquema: exigido para o papel virar dono de função em privado.
grant usage, create on schema privado to zz_823_sem_bypass;
grant execute on function privado.agora() to zz_823_sem_bypass;
grant execute on function privado.registrar_falha_execucao(text, text, jsonb) to zz_823_sem_bypass;
alter function privado.limpar_trilha_e_sessoes_auth(integer, integer) owner to zz_823_sem_bypass;
select pg_temp.trilha('c8230000-0000-4000-8000-0000000000c2', interval '7 months',
  '{"action":"login","actor_id":"c8230000-0000-4000-8000-000000000001"}');
delete from privado.falha_execucao where origem = 'limpar_trilha_e_sessoes_auth';
create temp table r3 as select privado.limpar_trilha_e_sessoes_auth() as j;
select results_eq($$ select f->>'etapa', f->>'codigo' from r3, jsonb_array_elements(j->'falhas') f order by 1 $$,
  $$ values ('sessoes_paradas', 'rls_sem_bypass'), ('trilha_antiga', 'rls_sem_bypass'),
            ('trilha_conta_excluida', 'rls_sem_bypass') $$,
  'dono sem BYPASSRLS: as três etapas registram rls_sem_bypass e não rodam');
select ok(pg_temp.existe('c8230000-0000-4000-8000-0000000000c2'), 'e nada é apagado');
select is((select count(*)::int from privado.falha_execucao
            where origem = 'limpar_trilha_e_sessoes_auth' and codigo = 'limpeza_auth_falhou'), 1,
  'a falha vai para falha_execucao, que o verificar_saude transforma em alerta');
alter function privado.limpar_trilha_e_sessoes_auth(integer, integer) owner to postgres;

-- ── Agendamento e permissão ──────────────────────────────────────────────────
-- FOR UPDATE pede UPDATE na tabela: só a etapa das sessões trava linha, e a trilha pede só SELECT e DELETE
-- (Lince no #442, R-1). A prova com um papel que tem só esses privilégios é feita fora daqui, como superusuário.
select is((select (length(c.codigo) - length(replace(c.codigo, 'for update skip locked', ''))) / length('for update skip locked')
             from pg_proc p, lateral (select lower(regexp_replace(p.prosrc, '--[^\n]*', '', 'g')) as codigo) c where p.oid = 'privado.limpar_trilha_e_sessoes_auth(integer, integer)'::regprocedure),
  1, 'só a etapa das sessões usa FOR UPDATE SKIP LOCKED');
select results_eq($$ select schedule, command from cron.job where jobname = 'limpar_trilha_e_sessoes_auth' $$,
  $$ values ('23 4 * * *'::text, 'select privado.limpar_trilha_e_sessoes_auth()'::text) $$,
  'agendamento próprio às 04:23 UTC');
select ok(not has_function_privilege('authenticated', 'privado.limpar_trilha_e_sessoes_auth(integer, integer)', 'execute')
      and not has_function_privilege('anon', 'privado.limpar_trilha_e_sessoes_auth(integer, integer)', 'execute'),
  'só o service_role e o agendador chamam a limpeza');

select * from finish();
rollback;
