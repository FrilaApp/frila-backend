-- 835_lgpd_guarda_legal_nas_sessoes_auth.sql · LGPD-J6, brief B-GUARDA (migração 20261108230000).
-- As três etapas de privado.limpar_trilha_e_sessoes_auth (#442) pulam o que é da conta em guarda legal vigente
-- (privado.registro_acesso_guarda, Marco Civil art. 15, § 2º), pelo mesmo predicado de privado.limpar_registros_acesso
-- (#449): a guarda vale de desde, inclusive, até ate, exclusive.
--   (a) a trilha do Auth com mais de 6 meses e (b) a de conta excluída: pelo actor_id ou pelo traits.user_id;
--   (c) a sessão parada há mais de 6 meses, com o refresh_token.
-- Sem guarda, com a guarda vencida ou ainda por começar, tudo sai, como no #442. Com a guarda invisível ao dono da
-- função, ou ausente, nenhuma etapa roda e a falha é registrada, nomeando a guarda (autoconferência de RLS).
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-08 12:00:00+00', true);
select plan(36);

-- Base limpa dentro da transação (desfeita no fim): só as linhas deste teste contam.
delete from auth.audit_log_entries;
delete from auth.sessions;
delete from privado.registro_acesso_guarda;

-- Contas sintéticas pela etiqueta: 01 a 07 existem em auth.users; d1 a d6 são contas excluídas (a guarda não tem FK).
--   01 e d1: guarda vigente · 02 e d2: sem guarda · 03 e d3: guarda vencida · 04 e d4: guarda por começar
--   05 e d5: guarda que começa agora · 06 e d6: guarda que termina agora · 07: uma guarda vencida e outra vigente.
create function pg_temp.conta(etiqueta text) returns uuid language sql immutable as $$
  select ('c8350000-0000-4000-8000-0000000000' || etiqueta)::uuid
$$;
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.conta('0' || n), 'authenticated',
       'authenticated', 'u' || n || '@t835.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 7) n;

insert into privado.registro_acesso_guarda (usuario_id, desde, ate, referencia)
select pg_temp.conta(c.p || g.n), g.desde, g.ate, 'T835-' || c.p || g.n
  from (values ('0'), ('d')) c (p), lateral (values
         (1, privado.agora() - interval '1 month', privado.agora() + interval '1 year'),
         (3, privado.agora() - interval '1 year',  privado.agora() - interval '1 day'),
         (4, privado.agora() + interval '1 day',   privado.agora() + interval '1 year'),
         (5, privado.agora(),                      privado.agora() + interval '1 year'),
         (6, privado.agora() - interval '1 year',  privado.agora())) g (n, desde, ate);
insert into privado.registro_acesso_guarda (usuario_id, desde, ate, referencia) values
  (pg_temp.conta('07'), privado.agora() - interval '2 years', privado.agora() - interval '1 year', 'T835-07-velha'),
  (pg_temp.conta('07'), privado.agora() - interval '1 day', privado.agora() + interval '1 month', 'T835-07-nova');

-- Sessões: uma parada há 7 meses por conta que existe (criada há 1 ano), cada uma com um refresh_token; a conta 01
-- tem ainda uma sessão recente, que fica de todo jeito.
create function pg_temp.sessao(etiqueta text, id uuid, parada interval) returns void language sql as $$
  insert into auth.sessions (id, user_id, created_at, updated_at, refreshed_at, ip)
  values (id, pg_temp.conta(etiqueta), privado.agora() - interval '1 year',
          privado.agora() - parada, (privado.agora() - parada) at time zone 'UTC', '203.0.113.32');
  insert into auth.refresh_tokens (instance_id, token, user_id, revoked, created_at, updated_at, session_id)
  values ('00000000-0000-0000-0000-000000000000', 'zz835-' || id::text, pg_temp.conta(etiqueta)::text, false,
          privado.agora() - parada, privado.agora() - parada, id);
$$;
create function pg_temp.tem_sessao(id uuid) returns boolean language sql as $$
  select exists (select 1 from auth.sessions s where s.id = tem_sessao.id)
$$;
create function pg_temp.tem_token(id uuid) returns boolean language sql as $$
  select exists (select 1 from auth.refresh_tokens t where t.session_id = tem_token.id)
$$;
-- Trilha: a conta no actor_id e, numa ação de admin (user_deleted, actor_id nulo), no traits.user_id.
create function pg_temp.trilha(etiqueta text, idade interval, ator uuid, alvo uuid default null) returns void
language sql as $$
  insert into auth.audit_log_entries (instance_id, id, payload, created_at, ip_address)
  values ('00000000-0000-0000-0000-000000000000', ('c8350000-0000-4000-8000-00000000' || etiqueta)::uuid,
          json_build_object('action', case when alvo is null then 'login' else 'user_deleted' end,
                            'actor_id', ator::text,
                            'traits', case when alvo is not null then json_build_object('user_id', alvo::text) end),
          privado.agora() - idade, '203.0.113.33')
$$;
create function pg_temp.tem_trilha(etiqueta text) returns boolean language sql as $$
  select exists (select 1 from auth.audit_log_entries a
                  where a.id = ('c8350000-0000-4000-8000-00000000' || etiqueta)::uuid)
$$;

select pg_temp.sessao('0' || n, ('c8350000-0000-4000-8000-0000000000b' || n)::uuid, interval '7 months')
  from generate_series(1, 7) n;
select pg_temp.sessao('01', 'c8350000-0000-4000-8000-0000000000c1', interval '1 day');

-- (a) trilha de 7 meses de conta que existe: aa0n no actor_id da conta 0n; aa07 é ação de admin sobre a conta 01.
select pg_temp.trilha('aa0' || n, interval '7 months', pg_temp.conta('0' || n)) from generate_series(1, 6) n;
select pg_temp.trilha('aa07', interval '7 months', '00000000-0000-0000-0000-000000000000', pg_temp.conta('01'));
-- (b) trilha de ontem de conta excluída: ab0n no actor_id da conta dn; ab07 é o user_deleted da d1.
select pg_temp.trilha('ab0' || n, interval '1 day', pg_temp.conta('d' || n)) from generate_series(1, 6) n;
select pg_temp.trilha('ab07', interval '1 day', '00000000-0000-0000-0000-000000000000', pg_temp.conta('d1'));

-- ── A rodada ─────────────────────────────────────────────────────────────────
create temp table r as select privado.limpar_trilha_e_sessoes_auth() as j;
select results_eq($$ select (j->>'trilha_antiga')::int, (j->>'trilha_conta_excluida')::int,
                            (j->>'sessoes_paradas')::int, j->'falhas' from r $$,
  $$ values (4, 4, 4, '[]'::jsonb) $$, 'cada etapa apaga só as 4 linhas sem guarda vigente, sem falha');

-- (c) Positivas: a guarda vigente segura a sessão e o refresh_token.
select ok(pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b1'),
  '(c) conta em guarda vigente: a sessão parada há 7 meses fica');
select ok(pg_temp.tem_token('c8350000-0000-4000-8000-0000000000b1'),
  '(c) conta em guarda vigente: o refresh_token da sessão fica');
select ok(pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000c1'),
  '(c) conta em guarda vigente: a sessão recente fica');
select ok(pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b5'),
  '(c) borda: a guarda que começa agora (desde = agora) já vale, e a sessão fica');
select ok(pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b7'),
  '(c) conta com uma guarda vencida e outra vigente: vale a vigente, e a sessão fica');
-- (c) Negativas: sem guarda vigente, a sessão parada sai, com o refresh_token em cascata.
select ok(not pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b2'),
  '(c) conta sem guarda: a sessão parada há 7 meses sai');
select ok(not pg_temp.tem_token('c8350000-0000-4000-8000-0000000000b2'),
  '(c) conta sem guarda: o refresh_token cai em cascata');
select ok(not pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b3'),
  '(c) conta com a guarda vencida: a sessão parada sai');
select ok(not pg_temp.tem_token('c8350000-0000-4000-8000-0000000000b3'),
  '(c) conta com a guarda vencida: o refresh_token cai em cascata');
select ok(not pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b4'),
  '(c) conta com a guarda por começar (desde amanhã): a sessão parada sai');
select ok(not pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b6'),
  '(c) borda: a guarda que termina agora (ate = agora) já não vale, e a sessão sai');

-- (a) Trilha de 7 meses de conta que existe.
select ok(pg_temp.tem_trilha('aa01'), '(a) conta em guarda vigente (actor_id): a trilha de 7 meses fica');
select ok(pg_temp.tem_trilha('aa07'), '(a) conta em guarda vigente (traits.user_id): a trilha de 7 meses fica');
select ok(pg_temp.tem_trilha('aa05'), '(a) borda: a guarda que começa agora já vale, e a trilha fica');
select ok(not pg_temp.tem_trilha('aa02'), '(a) conta sem guarda: a trilha de 7 meses sai');
select ok(not pg_temp.tem_trilha('aa03'), '(a) conta com a guarda vencida: a trilha sai');
select ok(not pg_temp.tem_trilha('aa04'), '(a) conta com a guarda por começar: a trilha sai');
select ok(not pg_temp.tem_trilha('aa06'), '(a) borda: a guarda que termina agora já não vale, e a trilha sai');

-- (b) Trilha recente de conta excluída.
select ok(pg_temp.tem_trilha('ab01'), '(b) conta excluída em guarda vigente (actor_id): a trilha fica');
select ok(pg_temp.tem_trilha('ab07'), '(b) user_deleted da conta excluída em guarda (traits.user_id): a trilha fica');
select ok(pg_temp.tem_trilha('ab05'), '(b) borda: a guarda que começa agora já vale, e a trilha fica');
select ok(not pg_temp.tem_trilha('ab02'), '(b) conta excluída sem guarda: a trilha sai');
select ok(not pg_temp.tem_trilha('ab03'), '(b) conta excluída com a guarda vencida: a trilha sai');
select ok(not pg_temp.tem_trilha('ab04'), '(b) conta excluída com a guarda por começar: a trilha sai');
select ok(not pg_temp.tem_trilha('ab06'), '(b) borda: a guarda que termina agora já não vale, e a trilha sai');

-- ── Vencida a guarda, tudo sai na rodada seguinte ────────────────────────────
update privado.registro_acesso_guarda set ate = privado.agora() - interval '1 second'
 where usuario_id in (pg_temp.conta('01'), pg_temp.conta('d1'));
create temp table r_vencida as select privado.limpar_trilha_e_sessoes_auth() as j;
select results_eq($$ select (j->>'trilha_antiga')::int, (j->>'trilha_conta_excluida')::int,
                            (j->>'sessoes_paradas')::int from r_vencida $$,
  $$ values (2, 2, 1) $$, 'vencidas as guardas de 01 e d1, a trilha e a sessão parada delas saem na rodada seguinte');
select ok(not (pg_temp.tem_trilha('aa01') or pg_temp.tem_trilha('aa07') or pg_temp.tem_trilha('ab01')
               or pg_temp.tem_trilha('ab07') or pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b1')),
  'as linhas que a guarda vencida segurava são as que saíram');

-- ── Sem a tabela de guarda: as três etapas param, e nenhuma tenta rodar ──────
-- Com o postgres como dono, o Auth fica visível (BYPASSRLS) e só a guarda some (renomeada dentro da transação). As
-- três etapas registram rls_sem_bypass nomeando SÓ a guarda. Uma etapa que nomeasse a guarda sem parar rodaria o
-- not exists sobre a tabela ausente e registraria um 42P01 a mais (Lince AG no #460). Desfeito no fim do bloco.
select pg_temp.sessao('02', 'c8350000-0000-4000-8000-0000000000b9', interval '7 months');
select pg_temp.trilha('aa09', interval '7 months', pg_temp.conta('02'));
select pg_temp.trilha('ab09', interval '1 day', pg_temp.conta('d2'));
alter table privado.registro_acesso_guarda rename to registro_acesso_guarda_zz835;
create temp table r_sem_tabela as select privado.limpar_trilha_e_sessoes_auth() as j;
alter table privado.registro_acesso_guarda_zz835 rename to registro_acesso_guarda;
select is((select j->'falhas' from r_sem_tabela),
  '[{"etapa": "trilha_antiga", "codigo": "rls_sem_bypass", "tabelas": ["privado.registro_acesso_guarda"]},
    {"etapa": "trilha_conta_excluida", "codigo": "rls_sem_bypass", "tabelas": ["privado.registro_acesso_guarda"]},
    {"etapa": "sessoes_paradas", "codigo": "rls_sem_bypass", "tabelas": ["privado.registro_acesso_guarda"]}]'::jsonb,
  'sem a tabela de guarda: as três etapas param e nomeiam só a guarda, e nenhuma tenta rodar (nenhum 42P01)');
select results_eq($$ select (j->>'trilha_antiga')::int, (j->>'trilha_conta_excluida')::int, (j->>'sessoes_paradas')::int,
                            pg_temp.tem_trilha('aa09') and pg_temp.tem_trilha('ab09')
                              and pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b9')
                       from r_sem_tabela $$,
  $$ values (0, 0, 0, true) $$, 'sem a tabela de guarda: nada sai');

-- ── A guarda invisível ao dono: nenhuma etapa roda, e cada uma registra a falha nomeando a guarda ──
-- Premissa medida: no banco da suíte, as tabelas do Auth têm RLS e o postgres não alcança papel que as enxergue sem
-- BYPASSRLS (não é membro do dono delas). Um dono sem BYPASSRLS deixa invisíveis o Auth E a guarda; o campo tabelas
-- é o que separa a guarda. A prova com SÓ a guarda invisível (dono das tabelas do Auth sem BYPASSRLS) exige
-- supabase_admin e está no PR. Se esta premissa cair, dá para isolar aqui: refaça o bloco.
select ok((select bool_and(c.relrowsecurity) from pg_class c
            where c.oid in ('auth.audit_log_entries'::regclass, 'auth.users'::regclass, 'auth.sessions'::regclass))
          and not pg_has_role('postgres', (select pg_get_userbyid(relowner) from pg_class
                                            where oid = 'auth.sessions'::regclass), 'member'),
  'premissa: as tabelas do Auth têm RLS, e o postgres não é membro do dono delas');
create role zz_835_sem_bypass nologin;
grant zz_835_sem_bypass to postgres;
-- CREATE no esquema: exigido para o papel virar dono de função em privado.
grant usage, create on schema privado to zz_835_sem_bypass;
grant execute on function privado.agora() to zz_835_sem_bypass;
grant execute on function privado.registrar_falha_execucao(text, text, jsonb) to zz_835_sem_bypass;
grant select on table privado.registro_acesso_guarda to zz_835_sem_bypass;
alter function privado.limpar_trilha_e_sessoes_auth(integer, integer) owner to zz_835_sem_bypass;
-- O que já não tinha guarda e sairia se a etapa rodasse: uma sessão parada da 02 e uma trilha de cada tipo.
select pg_temp.sessao('02', 'c8350000-0000-4000-8000-0000000000b8', interval '7 months');
select pg_temp.trilha('aa08', interval '7 months', pg_temp.conta('02'));
select pg_temp.trilha('ab08', interval '1 day', pg_temp.conta('d2'));
delete from privado.falha_execucao where origem = 'limpar_trilha_e_sessoes_auth';
create temp table r_cega as select privado.limpar_trilha_e_sessoes_auth() as j;
select ok((select j->'falhas' @> '[{"etapa":"trilha_antiga","codigo":"rls_sem_bypass","tabelas":["privado.registro_acesso_guarda"]}]' from r_cega),
  'guarda invisível ao dono: a etapa (a) registra rls_sem_bypass e nomeia a guarda');
select ok((select j->'falhas' @> '[{"etapa":"trilha_conta_excluida","codigo":"rls_sem_bypass","tabelas":["privado.registro_acesso_guarda"]}]' from r_cega),
  'guarda invisível ao dono: a etapa (b) registra rls_sem_bypass e nomeia a guarda');
select ok((select j->'falhas' @> '[{"etapa":"sessoes_paradas","codigo":"rls_sem_bypass","tabelas":["privado.registro_acesso_guarda"]}]' from r_cega),
  'guarda invisível ao dono: a etapa (c) registra rls_sem_bypass e nomeia a guarda');
select results_eq($$ select (j->>'trilha_antiga')::int, (j->>'trilha_conta_excluida')::int, (j->>'sessoes_paradas')::int,
                            pg_temp.tem_trilha('aa05') and pg_temp.tem_trilha('ab05')
                              and pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b7')
                              and pg_temp.tem_trilha('aa08') and pg_temp.tem_trilha('ab08')
                              and pg_temp.tem_sessao('c8350000-0000-4000-8000-0000000000b8')
                       from r_cega $$,
  $$ values (0, 0, 0, true) $$, 'guarda invisível ao dono: nada sai, nem o que está em guarda, nem o que não está');
select is((select count(*)::int from privado.falha_execucao
            where origem = 'limpar_trilha_e_sessoes_auth' and codigo = 'limpeza_auth_falhou'), 1,
  'a falha vai para falha_execucao, que o verificar_saude transforma em alerta');
alter function privado.limpar_trilha_e_sessoes_auth(integer, integer) owner to postgres;

select * from finish();
rollback;
