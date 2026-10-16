-- 712_rls_notificacao.sql
--
-- Cobertura canônica de Row Level Security (RLS) para public.notificacao
-- Política: notificacao_leitura (for select to authenticated using (usuario_id = (select auth.uid())))
--
-- Garante:
--   1. Estrutura: RLS ativo e política única declarada para authenticated.
--   2. Superfície externa fechada: papel 'anon' não tem concessões e recebe 42501 ao tentar ler.
--   3. Leitura legítima positiva: tanto contratante quanto profissional leem suas próprias notificações.
--   4. Isolamento estrito negativo:
--      - Contratante A não lê Contratante B;
--      - Profissional A não lê Profissional B;
--      - Contratante não lê Profissional e vice-versa;
--      - Contagem irrestrita (sem WHERE) retorna estritamente as notificações da própria conta;
--      - Sessão autenticada sem claim 'sub' (auth.uid() is null) retorna zero linhas.
--   5. Prova de mutação: remoção da política fecha o acesso do contratante legítimo.

begin;
select plan(22);

perform privado.ambiente(eh_teste => true);
set local frila.agora = '2026-10-25 12:00:00+00';

-- ── 1. Auxiliares de Identidade ────────────────────────────────────────────────

create function pg_temp.contar_como(conta uuid, sql text) returns integer
language plpgsql as $$
declare n integer;
begin
  execute 'set local role authenticated';
  if conta is not null then
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', conta, 'role', 'authenticated')::text);
  else
    execute 'set local request.jwt.claims = ''{"role":"authenticated"}''';
  end if;
  execute sql into n;
  reset role;
  execute 'reset request.jwt.claims';
  return n;
end $$;

create function pg_temp.como(papel text, sql text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
end $$;

-- ── 2. Cenário Hermético de Teste ──────────────────────────────────────────────

create temp table ids as select
  '71200000-0000-4000-8000-000000000001'::uuid as c_ze,       -- contratante A
  '71200000-0000-4000-8000-000000000002'::uuid as c_rita,     -- contratante B
  '71200000-0000-4000-8000-000000000003'::uuid as p_ana,      -- profissional A (conta)
  '71200000-0000-4000-8000-000000000004'::uuid as p_beto,     -- profissional B (conta)
  '71200000-0000-4000-8000-000000000013'::uuid as prof_ana,   -- profissional A (perfil)
  '71200000-0000-4000-8000-000000000014'::uuid as prof_beto,  -- profissional B (perfil)
  '71200000-0000-4000-8000-000000000021'::uuid as notif_ze,   -- notificação Zé
  '71200000-0000-4000-8000-000000000022'::uuid as notif_rita, -- notificação Rita
  '71200000-0000-4000-8000-000000000023'::uuid as notif_ana,  -- notificação Ana
  '71200000-0000-4000-8000-000000000024'::uuid as notif_beto; -- notificação Beto

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', id_val, 'authenticated', 'authenticated',
       email_val, '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false
from (values
  ((select c_ze from ids),   'ze.712@test.com'),
  ((select c_rita from ids), 'rita.712@test.com'),
  ((select p_ana from ids),  'ana.712@test.com'),
  ((select p_beto from ids), 'beto.712@test.com')
) as u(id_val, email_val);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ((select c_ze from ids),   'contratante',  'Zé Contratante',   '+5561997120001', 'ze.712@test.com',   '1985-05-10', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_rita from ids), 'contratante',  'Rita Contratante', '+5561997120002', 'rita.712@test.com', '1988-08-15', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_ana from ids),  'profissional', 'Ana Garçonete',    '+5561997120003', 'ana.712@test.com',  '1996-03-20', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_beto from ids), 'profissional', 'Beto Barman',      '+5561997120004', 'beto.712@test.com', '1994-11-25', '2026-09-22', '2026-10-25 12:00:00+00');

insert into public.profissional (id, usuario_id, ponto_base)
values
  ((select prof_ana from ids),  (select p_ana from ids),  'POINT(-47.8820 -15.7940)'::extensions.geography),
  ((select prof_beto from ids), (select p_beto from ids), 'POINT(-47.8830 -15.7950)'::extensions.geography);

-- Notificações de contratante (tipo sem profissional_id, check constraint notificacao_profissional_so_de_vaga)
insert into public.notificacao (id, usuario_id, profissional_id, tipo, referencia_id, payload, enviada_em)
values
  ((select notif_ze from ids),   (select c_ze from ids),   null, 'confirmacao', gen_random_uuid(), '{"turno_id":"71200000-0000-4000-8000-000000000091"}'::jsonb, '2026-10-25 12:05:00+00'),
  ((select notif_rita from ids), (select c_rita from ids), null, 'checkin',     gen_random_uuid(), '{"turno_id":"71200000-0000-4000-8000-000000000092"}'::jsonb, '2026-10-25 12:10:00+00');

-- Notificações de profissional (tipo 'vaga' exige profissional_id não-nulo)
insert into public.notificacao (id, usuario_id, profissional_id, tipo, referencia_id, payload, enviada_em)
values
  ((select notif_ana from ids),  (select p_ana from ids),  (select prof_ana from ids),  'vaga', gen_random_uuid(), '{"vaga_id":"71200000-0000-4000-8000-000000000093"}'::jsonb, '2026-10-25 12:15:00+00'),
  ((select notif_beto from ids), (select p_beto from ids), (select prof_beto from ids), 'vaga', gen_random_uuid(), '{"vaga_id":"71200000-0000-4000-8000-000000000094"}'::jsonb, '2026-10-25 12:20:00+00');

-- ── 3. Estrutura e Estado do RLS ───────────────────────────────────────────────

select has_table('public', 'notificacao', 'tabela public.notificacao existe');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.notificacao'::regclass),
  'RLS está ativado em public.notificacao'
);

select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'notificacao'),
  1,
  'public.notificacao possui exatamente uma política RLS'
);

select is(
  (select policyname from pg_policies where schemaname = 'public' and tablename = 'notificacao'),
  'notificacao_leitura',
  'a política RLS ativa chama-se notificacao_leitura'
);

-- ── 4. Superfície Fechada para anon ────────────────────────────────────────────

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.notificacao') $$,
  '42501',
  null,
  'papel anon não tem permissão de SELECT em public.notificacao (42501)'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public' and table_name = 'notificacao'),
  0,
  'papel anon não possui privilégio algum concedido em public.notificacao'
);

-- ── 5. Casos Positivos: Leitura Legítima por authenticated ─────────────────────

select is(
  pg_temp.contar_como((select c_ze from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_ze from ids))),
  1,
  'positivo: contratante A lê sua própria notificação com sucesso'
);

select is(
  pg_temp.contar_como((select c_rita from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_rita from ids))),
  1,
  'positivo: contratante B lê sua própria notificação com sucesso'
);

select is(
  pg_temp.contar_como((select p_ana from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_ana from ids))),
  1,
  'positivo: profissional A lê sua própria notificação com sucesso'
);

select is(
  pg_temp.contar_como((select p_beto from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_beto from ids))),
  1,
  'positivo: profissional B lê sua própria notificação com sucesso'
);

-- ── 6. Isolamento de Contagem Irrestrita (sem WHERE) ───────────────────────────

select is(
  pg_temp.contar_como((select c_ze from ids),
    format('select count(*)::int from public.notificacao where id in (%L, %L, %L, %L)',
           (select notif_ze from ids), (select notif_rita from ids),
           (select notif_ana from ids), (select notif_beto from ids))),
  1,
  'RLS filtra automaticamente: contratante A vê apenas 1 das 4 notificações do lote'
);

select is(
  pg_temp.contar_como((select c_rita from ids),
    format('select count(*)::int from public.notificacao where id in (%L, %L, %L, %L)',
           (select notif_ze from ids), (select notif_rita from ids),
           (select notif_ana from ids), (select notif_beto from ids))),
  1,
  'RLS filtra automaticamente: contratante B vê apenas 1 das 4 notificações do lote'
);

select is(
  pg_temp.contar_como((select p_ana from ids),
    format('select count(*)::int from public.notificacao where id in (%L, %L, %L, %L)',
           (select notif_ze from ids), (select notif_rita from ids),
           (select notif_ana from ids), (select notif_beto from ids))),
  1,
  'RLS filtra automaticamente: profissional A vê apenas 1 das 4 notificações do lote'
);

select is(
  pg_temp.contar_como((select p_beto from ids),
    format('select count(*)::int from public.notificacao where id in (%L, %L, %L, %L)',
           (select notif_ze from ids), (select notif_rita from ids),
           (select notif_ana from ids), (select notif_beto from ids))),
  1,
  'RLS filtra automaticamente: profissional B vê apenas 1 das 4 notificações do lote'
);

-- ── 7. Casos Negativos Específicos: Isolamento Cruzado e Intraperfil ───────────

select is(
  pg_temp.contar_como((select c_ze from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_rita from ids))),
  0,
  'negativo: contratante A recebe 0 linhas ao consultar notificação de contratante B'
);

select is(
  pg_temp.contar_como((select c_rita from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_ze from ids))),
  0,
  'negativo: contratante B recebe 0 linhas ao consultar notificação de contratante A'
);

select is(
  pg_temp.contar_como((select p_ana from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_beto from ids))),
  0,
  'negativo: profissional A recebe 0 linhas ao consultar notificação de profissional B'
);

select is(
  pg_temp.contar_como((select p_beto from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_ana from ids))),
  0,
  'negativo: profissional B recebe 0 linhas ao consultar notificação de profissional A'
);

select is(
  pg_temp.contar_como((select c_ze from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_ana from ids))),
  0,
  'negativo: contratante recebe 0 linhas ao consultar notificação de profissional'
);

select is(
  pg_temp.contar_como((select p_ana from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_ze from ids))),
  0,
  'negativo: profissional recebe 0 linhas ao consultar notificação de contratante'
);

select is(
  pg_temp.contar_como(null,
    format('select count(*)::int from public.notificacao where id = %L', (select notif_ze from ids))),
  0,
  'negativo: authenticated sem claim sub (auth.uid() nulo) recebe 0 linhas'
);

-- ── 8. Prova de Mutação: Remoção de Política Fecha Acesso ──────────────────────

savepoint mutacao_sem_politica;
drop policy notificacao_leitura on public.notificacao;

select is(
  pg_temp.contar_como((select c_ze from ids),
    format('select count(*)::int from public.notificacao where id = %L', (select notif_ze from ids))),
  0,
  'prova de mutação: sem a política notificacao_leitura, o acesso legítimo do contratante fecha (0 linhas)'
);

rollback to savepoint mutacao_sem_politica;

select * from finish();
rollback;
