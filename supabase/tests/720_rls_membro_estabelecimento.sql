-- 720_rls_membro_estabelecimento.sql
--
-- Cobertura de Row Level Security (RLS) para public.membro_estabelecimento (politica membro_estabelecimento_leitura):
--   Predicado:
--     using (privado.eh_membro(estabelecimento_id))
--
-- Casos cobertos:
--   1. Catalogo & RLS:
--      - RLS ativo em public.membro_estabelecimento;
--      - Papel anon recebe 42501 em SELECT direto e nao possui grant;
--      - Papel authenticated recebe 42501 em INSERT, UPDATE e DELETE direto (prova do REVOKE de escrita).
--   2. Visao de equipe entre membros da mesma casa:
--      - Contratante administrador (Ze) le todos os membros do seu estabelecimento (Ze e Nina);
--      - Contratante operadora (Nina) le todos os membros do seu estabelecimento (Ze e Nina).
--   3. Lacuna Top 8 - Profissional NAO enumera membros de estabelecimentos:
--      - Profissional Ana recebe 0 linhas ao consultar membros do Bar do Ze
--        (protege a relacao societaria e equipe operacional do contratante contra enumeracao por autônomos);
--      - Profissional Beto le 0 membros no sistema.
--   4. Isolamento entre estabelecimentos:
--      - Contratante Rita (Buffet da Rita) recebe 0 linhas para membros do Bar do Ze;
--      - Contratante Ze recebe 0 linhas para membros do Buffet da Rita;
--      - Sessao sem claims (auth.uid() nulo) le 0 membros.
--   5. Provas de mutacao real do predicado USING:
--      - Mutante sem politica: membros deixam de ler a propria equipe;
--      - Mutante com vazamento aberto (using true): detecta se profissional lesse equipe alheia;
--      - Mutante sem visao de equipe (usuario_id = auth.uid()): membros perderiam a visao de equipe (leriam 1 em vez de 2);
--      - Restauracao da politica canonica e revalidacao completa.

begin;
select plan(24);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-25 12:00:00+00';
set local frila.agendador_secret = 'teste-segredo-720';

-- ── 1. Auxiliares ──────────────────────────────────────────────────────────────

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

-- ── 2. Cenario Hermetico ───────────────────────────────────────────────────────

create temp table ids as select
  '72000000-0000-4000-8000-000000000001'::uuid as c_ze,                -- contratante Bar do Ze (admin)
  '72000000-0000-4000-8000-000000000002'::uuid as c_nina,              -- contratante Bar do Ze (operadora)
  '72000000-0000-4000-8000-000000000003'::uuid as c_rita,              -- contratante Buffet da Rita (admin)
  '72000000-0000-4000-8000-000000000004'::uuid as p_ana,               -- profissional Ana
  '72000000-0000-4000-8000-000000000005'::uuid as p_beto,              -- profissional Beto
  '72000000-0000-4000-8000-000000000010'::uuid as estab_ze,            -- Bar do Ze
  '72000000-0000-4000-8000-000000000011'::uuid as estab_rita;          -- Buffet Rita

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', id_val, 'authenticated', 'authenticated',
       email_val, '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false
from (values
  ((select c_ze from ids),   'ze.720@test.com'),
  ((select c_nina from ids), 'nina.720@test.com'),
  ((select c_rita from ids), 'rita.720@test.com'),
  ((select p_ana from ids),  'ana.720@test.com'),
  ((select p_beto from ids), 'beto.720@test.com')
) as u(id_val, email_val);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ((select c_ze from ids),   'contratante',  'Ze Bar 720',         '+5561997200001', 'ze.720@test.com',   '1980-01-01', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_nina from ids), 'contratante',  'Nina Operadora 720', '+5561997200002', 'nina.720@test.com', '1985-02-02', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_rita from ids), 'contratante',  'Rita Buffet 720',    '+5561997200003', 'rita.720@test.com', '1982-03-03', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_ana from ids),  'profissional', 'Ana Garconete 720',  '+5561997200004', 'ana.720@test.com',  '1995-04-04', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_beto from ids), 'profissional', 'Beto Garcom 720',    '+5561997200005', 'beto.720@test.com', '1996-05-05', '2026-09-22', '2026-10-25 12:00:00+00');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values
  ((select estab_ze from ids),   'Bar do Ze 720',   '94827109000199', 'food_service', 'CLN 102', 'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto'),
  ((select estab_rita from ids), 'Buffet Rita 720', '94827109000188', 'evento',       'SIA 3',   'POINT(-47.89 -15.80)'::extensions.geography, 'SIA');

-- Membros do Bar do Ze: Ze (administrador) e Nina (operador)
-- Membro do Buffet da Rita: Rita (administrador)
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values
  ((select c_ze from ids),   (select estab_ze from ids),   'administrador'),
  ((select c_nina from ids), (select estab_ze from ids),   'operador'),
  ((select c_rita from ids), (select estab_rita from ids), 'administrador');

grant select on ids to authenticated;

-- ── 3. Catalogo, anon e Prova do REVOKE de escrita para authenticated ─────────

select has_table('public', 'membro_estabelecimento', 'tabela public.membro_estabelecimento existe');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.membro_estabelecimento'::regclass),
  'RLS ativo em public.membro_estabelecimento'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.membro_estabelecimento') $$,
  '42501',
  null,
  'papel anon recebe 42501 em SELECT direto em public.membro_estabelecimento'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public' and table_name = 'membro_estabelecimento'),
  0,
  'anon nao possui grant em public.membro_estabelecimento'
);

-- Prova do REVOKE de escrita para authenticated (Frase 1 da Modelagem)
select throws_ok(
  $$ select pg_temp.como('authenticated', 'insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values (gen_random_uuid(), gen_random_uuid(), ''operador'')') $$,
  '42501',
  null,
  'prova do REVOKE: authenticated recebe 42501 em INSERT direto em public.membro_estabelecimento'
);

select throws_ok(
  $$ select pg_temp.como('authenticated', 'update public.membro_estabelecimento set papel = ''administrador''') $$,
  '42501',
  null,
  'prova do REVOKE: authenticated recebe 42501 em UPDATE direto em public.membro_estabelecimento'
);

select throws_ok(
  $$ select pg_temp.como('authenticated', 'delete from public.membro_estabelecimento') $$,
  '42501',
  null,
  'prova do REVOKE: authenticated recebe 42501 em DELETE direto em public.membro_estabelecimento'
);

-- ── 4. Visao de equipe entre membros da mesma casa ────────────────────────────

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  2,
  'administrador Ze le todos os 2 membros do Bar do Ze (Ze e Nina)'
);

select is(
  pg_temp.contar_como(
    (select c_nina from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  2,
  'operadora Nina le todos os 2 membros do Bar do Ze (Ze e Nina)'
);

-- ── 5. Lacuna Top 8: Profissional NAO enumera membros de estabelecimentos ──────

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  0,
  'profissional Ana recebe 0 linhas ao consultar membros do Bar do Ze (lacuna Top 8)'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    'select count(*)::int from public.membro_estabelecimento'
  ),
  0,
  'profissional Ana le 0 membros no sistema'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    'select count(*)::int from public.membro_estabelecimento'
  ),
  0,
  'profissional Beto le 0 membros no sistema'
);

-- ── 6. Isolamento entre estabelecimentos ───────────────────────────────────────

select is(
  pg_temp.contar_como(
    (select c_rita from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  0,
  'contratante Rita recebe 0 linhas para membros do estabelecimento alheio'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_rita from ids))
  ),
  0,
  'contratante Ze recebe 0 linhas para membros do Buffet da Rita'
);

select is(
  pg_temp.contar_como(
    null,
    'select count(*)::int from public.membro_estabelecimento'
  ),
  0,
  'sessao sem claims (auth.uid() nulo) le 0 membros'
);

-- ── 7. Provas de Mutacao Real do Predicado USING ──────────────────────────────

-- Mutacao 1: Remocao total da politica fecha o acesso legitimo dos membros
drop policy membro_estabelecimento_leitura on public.membro_estabelecimento;

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  0,
  'mutante sem politica: Ze deixa de ler membros da casa'
);

select is(
  pg_temp.contar_como(
    (select c_nina from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  0,
  'mutante sem politica: Nina deixa de ler membros da casa'
);

-- Mutacao 2: Vazamento irrestrito (using true)
create policy membro_estabelecimento_leitura on public.membro_estabelecimento
  for select to authenticated using (true);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  2,
  'mutante com vazamento aberto: comprova que profissional leria membros do bar'
);

-- Mutacao 3: Sem visao de equipe (apenas usuario_id = auth.uid())
drop policy membro_estabelecimento_leitura on public.membro_estabelecimento;
create policy membro_estabelecimento_leitura on public.membro_estabelecimento
  for select to authenticated using (usuario_id = (select auth.uid()));

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  1,
  'mutante sem visao de equipe: Ze le apenas a si proprio (1 em vez de 2)'
);

select is(
  pg_temp.contar_como(
    (select c_nina from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  1,
  'mutante sem visao de equipe: Nina le apenas a si propria (1 em vez de 2)'
);

-- Restauracao da politica canonica e revalidacao final
drop policy membro_estabelecimento_leitura on public.membro_estabelecimento;
create policy membro_estabelecimento_leitura on public.membro_estabelecimento
  for select to authenticated using (privado.eh_membro(estabelecimento_id));

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  2,
  'politica restaurada: Ze volta a ler os 2 membros da casa'
);

select is(
  pg_temp.contar_como(
    (select c_nina from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  2,
  'politica restaurada: Nina volta a ler os 2 membros da casa'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  0,
  'politica restaurada: Ana volta a receber 0 membros'
);

select is(
  pg_temp.contar_como(
    (select c_rita from ids),
    format('select count(*)::int from public.membro_estabelecimento where estabelecimento_id = %L', (select estab_ze from ids))
  ),
  0,
  'politica restaurada: Rita volta a receber 0 membros alheios'
);

select * from finish();
rollback;
