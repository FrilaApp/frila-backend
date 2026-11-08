-- 822_lgpd_j6_registro_acessos.sql · LGPD-J6 R11 (cartão HAWhzOJ4, migração 20261108110000).
-- O gatilho registrar_acesso em auth.sessions grava IP, data e hora de cada login e de cada renovação em
-- privado.registro_acesso (Marco Civil art. 15), sem user_agent e só com a coleta ligada; nunca bloqueia o Auth
-- (falha engolida e contada); privado.verificar_saude alerta falha em 24 h e renovação sem registro; a limpeza
-- de 6 meses repete lotes até esvaziar, com teto. A conta não tem public.usuario: é o primeiro login, antes de
-- criar_conta, que a FK antiga transformava em HTTP 500 no /verify.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-08 12:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-822';
select plan(41);

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'c8220000-0000-4000-8000-000000000001', 'authenticated',
        'authenticated', 'u1@t822.test', privado.agora(), privado.agora(), false, false);
-- Sessão como o Auth a grava: created_at no login; refreshed_at (sem fuso, em UTC) e ip a cada renovação.
create function pg_temp.entrar(sessao uuid, ip inet) returns void language sql as $$
  insert into auth.sessions (id, user_id, created_at, updated_at, ip, user_agent)
  values (sessao, 'c8220000-0000-4000-8000-000000000001', privado.agora(), privado.agora(), ip, 'Frila/1.1 iOS')
$$;
create function pg_temp.renovar(sessao uuid, ip inet) returns void language sql as $$
  update auth.sessions set refreshed_at = privado.agora() at time zone 'UTC', updated_at = privado.agora(),
         ip = renovar.ip, user_agent = 'Frila/1.1 iOS' where id = sessao
$$;
create function pg_temp.linhas() returns int language sql as $$
  select count(*)::int from privado.registro_acesso where usuario_id = 'c8220000-0000-4000-8000-000000000001'
$$;
create function pg_temp.alertou(codigo text) returns int language sql as $$
  select count(*)::int from privado.alerta_emitido a where a.codigo = alertou.codigo
$$;

-- ── Estrutura ────────────────────────────────────────────────────────────────
select is((select count(*)::int from pg_constraint where conrelid = 'privado.registro_acesso'::regclass and contype = 'f'),
  0, 'registro_acesso.usuario_id sem FK: o primeiro login vem antes de criar_conta');
select has_trigger('auth', 'sessions', 'registrar_acesso', 'gatilho registrar_acesso em auth.sessions');
-- Gatilho com lista de colunas prende o esquema do Auth: "alter column ... type" e "drop column" dele falhariam
-- (Lince Codex e Lince AG 2 no #441, B1).
select is((select count(*)::int from pg_depend d join pg_trigger t on d.classid = 'pg_trigger'::regclass and d.objid = t.oid
            where t.tgname = 'registrar_acesso' and t.tgrelid = 'auth.sessions'::regclass
              and d.refobjid = 'auth.sessions'::regclass and d.refobjsubid > 0),
  0, 'o gatilho não depende de coluna de auth.sessions (pg_depend refobjsubid > 0)');
select ok((select cardinality(t.tgattr::int2[]) = 0 from pg_trigger t
            where t.tgname = 'registrar_acesso' and t.tgrelid = 'auth.sessions'::regclass),
  'o gatilho não tem lista de colunas (tgattr vazio)');
select ok((select p.proconfig from pg_proc p where p.oid = 'privado.registrar_acesso_da_sessao()'::regprocedure)
            @> array['lock_timeout=200ms'],
  'a função do gatilho fixa lock_timeout de 200 ms: não segura o login atrás de trava');
select ok((select obj_description('privado.registro_acesso'::regclass, 'pg_class')) ~ 'art\. 15'
      and (select obj_description('privado.registro_acesso'::regclass, 'pg_class')) ~ 'art\. 7º II'
      and (select obj_description('privado.registro_acesso'::regclass, 'pg_class')) ~ 'art\. 7º IX',
  'base legal no comentário da tabela: Marco Civil art. 15, LGPD art. 7º II e IX');
select throws_ok($$ insert into privado.registro_acesso (ip, recurso, user_agent) values ('198.51.100.9', 'zz_822', 'Frila/1.1 iOS') $$,
  '23514', null, 'user_agent não é guardado: a coluna recusa valor (frila-docs #182)');
-- Grava primeiro e confere a linha gravada: uma linha só, com user_agent nulo (vazio reprova).
create temp table zz_822_manual as
  select privado.registrar_acesso(null, '198.51.100.9', 'zz_822_manual', 'Frila/1.1 iOS') as id;
select results_eq($$ select r.user_agent is null from privado.registro_acesso r join zz_822_manual z on z.id = r.id $$,
  $$ values (true) $$, 'registrar_acesso grava e ignora p_user_agent');
delete from privado.registro_acesso where recurso = 'zz_822_manual';
select is((select ligada from privado.registro_acesso_coleta), false, 'a coleta nasce desligada');
select throws_ok($$ insert into privado.registro_acesso_coleta (unica, ligada) values (false, true) $$,
  '23514', null, 'a chave tem uma linha só: unica = false é recusado');
select throws_ok($$ insert into privado.registro_acesso_coleta (unica, ligada) values (true, true) $$,
  '23505', null, 'a chave tem uma linha só: segunda linha recusada');
select is((select count(*)::int from information_schema.role_table_grants
            where table_schema = 'privado' and table_name in ('registro_acesso_coleta', 'registro_acesso_falha')
              and grantee in ('anon', 'authenticated')), 0,
  'anon e authenticated sem acesso à chave e ao contador');
select ok(not has_function_privilege('authenticated', 'privado.definir_coleta_registro_acesso(boolean)', 'execute')
      and not has_function_privilege('anon', 'privado.definir_coleta_registro_acesso(boolean)', 'execute'),
  'só o service_role liga a coleta');

-- ── Desligada: nada é gravado ────────────────────────────────────────────────
select pg_temp.entrar('c8220000-0000-4000-8000-0000000000a1', '203.0.113.60');
select is(pg_temp.linhas(), 0, 'coleta desligada: login não grava');

-- ── Ligada: login e renovação ────────────────────────────────────────────────
select set_config('frila.agora', '2026-11-08 12:01:00+00', true);
select is((select privado.definir_coleta_registro_acesso(true) ->> 'ligada'), 'true', 'definir_coleta liga a coleta');
select is((select alterada_em from privado.registro_acesso_coleta), '2026-11-08 12:01:00+00'::timestamptz,
  'e carimba alterada_em com o relógio do produto');
select set_config('frila.agora', '2026-11-08 12:02:00+00', true);
select pg_temp.entrar('c8220000-0000-4000-8000-0000000000a2', '203.0.113.61');
select results_eq($$ select ip, acessado_em, recurso, user_agent from privado.registro_acesso
                     where usuario_id = 'c8220000-0000-4000-8000-000000000001' $$,
  $$ values ('203.0.113.61'::inet, '2026-11-08 12:02:00+00'::timestamptz, 'login'::text, null::text) $$,
  'login: IP, data e hora gravados, sem user_agent');
select set_config('frila.agora', '2026-11-08 13:02:00+00', true);
select pg_temp.renovar('c8220000-0000-4000-8000-0000000000a2', '203.0.113.62');
select results_eq($$ select ip, acessado_em, recurso from privado.registro_acesso
                     where usuario_id = 'c8220000-0000-4000-8000-000000000001' order by id desc limit 1 $$,
  $$ values ('203.0.113.62'::inet, '2026-11-08 13:02:00+00'::timestamptz, 'renovacao'::text) $$,
  'renovação: o IP novo, com data e hora, numa linha nova');
select is(pg_temp.linhas(), 2, 'login e renovação: duas linhas');
update auth.sessions set tag = 'outra', aal = 'aal1' where id = 'c8220000-0000-4000-8000-0000000000a2';
select is(pg_temp.linhas(), 2, 'mudar outra coluna da sessão não grava');
update auth.sessions set refreshed_at = refreshed_at, ip = ip where id = 'c8220000-0000-4000-8000-0000000000a2';
select is(pg_temp.linhas(), 2, 'regravar refreshed_at e ip iguais não grava');
select pg_temp.entrar('c8220000-0000-4000-8000-0000000000a3', null);
select is(pg_temp.linhas(), 2, 'sessão sem IP não grava');
select is((select count(*)::int from privado.registro_acesso_falha), 0, 'e não conta como falha');

-- ── Nunca bloqueia o Auth: a falha é engolida e contada ──────────────────────
alter table privado.registro_acesso add constraint zz_822_falha check (false) not valid;
select lives_ok($$ select pg_temp.entrar('c8220000-0000-4000-8000-0000000000a4', '203.0.113.63') $$,
  'insert em registro_acesso falhando: o login segue');
select lives_ok($$ select pg_temp.renovar('c8220000-0000-4000-8000-0000000000a4', '203.0.113.64') $$,
  'e a renovação também');
select results_eq($$ select falhas, ultimo_sqlstate from privado.registro_acesso_falha $$,
  $$ values (2, '23514'::text) $$, 'as duas falhas contadas na hora, só com o SQLSTATE');
select is(pg_temp.linhas(), 2, 'nenhuma linha gravada na falha');
alter table privado.registro_acesso_falha add constraint zz_822_falha_contagem check (false) not valid;
select lives_ok($$ select pg_temp.renovar('c8220000-0000-4000-8000-0000000000a4', '203.0.113.65') $$,
  'até a contagem falhando: a renovação segue');
alter table privado.registro_acesso_falha drop constraint zz_822_falha_contagem;
alter table privado.registro_acesso drop constraint zz_822_falha;
-- Se o Auth remover ip, a migração dele passa (o gatilho não depende de coluna) e a leitura de NEW falha dentro do
-- bloco protegido. A tabela-espelho sem ip faz esse papel: o insert segue e a falha é contada como 42703.
create temp table zz_822_sessao_sem_ip (id uuid, user_id uuid, created_at timestamptz, updated_at timestamptz,
                                        refreshed_at timestamp);
create trigger zz_822_espelho after insert or update on zz_822_sessao_sem_ip
  for each row execute function privado.registrar_acesso_da_sessao();
select lives_ok($$ insert into zz_822_sessao_sem_ip values (gen_random_uuid(), 'c8220000-0000-4000-8000-000000000001',
                                                           privado.agora(), privado.agora(), null) $$,
  'sessão sem a coluna ip: o insert segue');
select results_eq($$ select falhas, ultimo_sqlstate from privado.registro_acesso_falha $$,
  $$ values (3, '42703'::text) $$, 'e a falha é contada como 42703 (coluna ausente)');

-- ── Alertas do verificar_saude ───────────────────────────────────────────────
delete from privado.alerta_emitido;
select privado.verificar_saude();
select is(pg_temp.alertou('registro_acesso_falhou'), 1, 'falha nas últimas 24 h: alerta registro_acesso_falhou');
select is(pg_temp.alertou('registro_acesso_parado'), 0, 'havia linha nova na última hora: sem registro_acesso_parado');
-- Duas horas depois, a sessão renova sem IP: houve renovação e nenhuma linha.
select set_config('frila.agora', '2026-11-08 15:02:00+00', true);
select pg_temp.renovar('c8220000-0000-4000-8000-0000000000a4', null);
delete from privado.alerta_emitido;
select privado.verificar_saude();
select is(pg_temp.alertou('registro_acesso_parado'), 1, 'renovação sem linha nova na última hora: registro_acesso_parado');
select set_config('frila.agora', '2026-11-08 15:03:00+00', true);
select privado.definir_coleta_registro_acesso(false);
delete from privado.alerta_emitido;
select privado.verificar_saude();
select is(pg_temp.alertou('registro_acesso_parado'), 0, 'coleta desligada: sem registro_acesso_parado');
-- Ligar agora não acusa as renovações de antes de ligar.
select set_config('frila.agora', '2026-11-08 15:04:00+00', true);
select privado.definir_coleta_registro_acesso(true);
delete from privado.alerta_emitido;
select privado.verificar_saude();
select is(pg_temp.alertou('registro_acesso_parado'), 0, 'recém-ligada: renovação anterior à chave não alerta');
select set_config('frila.agora', '2026-11-09 16:00:00+00', true);
delete from privado.alerta_emitido;
select privado.verificar_saude();
select is(pg_temp.alertou('registro_acesso_falhou'), 0, 'falha com mais de 24 h não alerta');

-- ── Limpeza de 6 meses em laço, com teto ─────────────────────────────────────
insert into privado.registro_acesso (ip, acessado_em, recurso)
select '198.51.100.1', privado.agora() - interval '7 months' - (n || ' seconds')::interval, 'zz_822_antigo'
  from generate_series(1, 2500) n;
insert into privado.registro_acesso (ip, acessado_em, recurso)
select '198.51.100.2', privado.agora() - interval '1 month', 'zz_822_recente' from generate_series(1, 3);
select is(privado.limpar_registros_acesso(6, 1000), 2500, 'lote de 1000: o laço apaga as 2500 antigas numa execução');
select results_eq($$ select (select count(*)::int from privado.registro_acesso where recurso = 'zz_822_antigo'),
                            (select count(*)::int from privado.registro_acesso where recurso = 'zz_822_recente') $$,
  $$ values (0, 3) $$, 'sobram só as de menos de 6 meses');
insert into privado.registro_acesso (ip, acessado_em, recurso)
select '198.51.100.3', privado.agora() - interval '7 months', 'zz_822_teto' from generate_series(1, 150);
select is(privado.limpar_registros_acesso(6, 1), 100, 'teto de 100 lotes por execução');
select is(privado.limpar_registros_acesso(6, 1), 50, 'o resto sai na execução seguinte');
insert into privado.registro_acesso_falha (hora, falhas, ultimo_sqlstate)
values (privado.agora() - interval '31 days', 1, '23514'), (privado.agora() - interval '1 day', 1, '23514');
select privado.limpar_registros_acesso(6, 1000);
select is((select count(*)::int from privado.registro_acesso_falha where hora < privado.agora() - interval '30 days'), 0,
  'contador de falhas com mais de 30 dias sai na limpeza');

select * from finish();
rollback;
