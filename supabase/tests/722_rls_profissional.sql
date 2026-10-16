-- 722_rls_profissional.sql
--
-- Cobertura de Row Level Security (RLS) para public.profissional (politica profissional_leitura):
--   Predicado:
--     using (usuario_id = (select auth.uid()))
--
-- Casos cobertos:
--   1. Catalogo & RLS:
--      - RLS ativo em public.profissional;
--      - Papel anon recebe 42501 em SELECT direto e nao possui grant;
--      - Papel authenticated recebe 42501 em INSERT, UPDATE e DELETE direto (prova do REVOKE de escrita).
--   2. Profissional le o seu proprio perfil:
--      - Profissional Ana le o seu proprio registro de profissional;
--      - Ana le apenas o seu proprio perfil (1 linha).
--   3. Lacuna Top 9 - Profissional concorrente NAO le perfil alheio:
--      - Profissional Beto recebe 0 linhas no perfil de Ana
--        (protege a coluna sensivel ponto_base, que indica a localizacao geografica habitual do profissional);
--      - Beto le apenas o seu proprio perfil.
--   4. Contratante NAO le public.profissional via SELECT direto:
--      - Contratante Ze recebe 0 linhas no perfil de Ana via SELECT direto
--        (a modelagem proibe contratantes de minerar o ponto_base; visualizacao de candidatos se da por RPCs);
--      - Contratante Ze le 0 perfis no sistema.
--   5. Isolamento de terceiros:
--      - Contratante Rita le 0 perfis de profissionais;
--      - Sessao sem claims (auth.uid() nulo) le 0 profissionais.
--   6. Provas de mutacao real do predicado USING:
--      - Mutante sem politica: profissional deixa de ler o proprio perfil;
--      - Mutante com vazamento aberto (using true): detecta se concorrente ou contratante lessem ponto_base de outrem;
--      - Mutante invertido por perfil (apenas contratante le): profissional perde e contratante vaza;
--      - Restauracao da politica canonica e revalidacao completa.

begin;
select plan(24);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-25 12:00:00+00';
set local frila.agendador_secret = 'teste-segredo-722';

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
  '72200000-0000-4000-8000-000000000001'::uuid as c_ze,                -- contratante Bar do Ze
  '72200000-0000-4000-8000-000000000002'::uuid as c_rita,              -- contratante Buffet da Rita
  '72200000-0000-4000-8000-000000000003'::uuid as p_ana,               -- profissional Ana
  '72200000-0000-4000-8000-000000000004'::uuid as p_beto,              -- profissional Beto
  '72200000-0000-4000-8000-000000000013'::uuid as prof_ana,            -- perfil Ana
  '72200000-0000-4000-8000-000000000014'::uuid as prof_beto;           -- perfil Beto

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', id_val, 'authenticated', 'authenticated',
       email_val, '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false
from (values
  ((select c_ze from ids),   'ze.722@test.com'),
  ((select c_rita from ids), 'rita.722@test.com'),
  ((select p_ana from ids),  'ana.722@test.com'),
  ((select p_beto from ids), 'beto.722@test.com')
) as u(id_val, email_val);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ((select c_ze from ids),   'contratante',  'Ze Bar 722',        '+5561997220001', 'ze.722@test.com',   '1980-01-01', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_rita from ids), 'contratante',  'Rita Buffet 722',   '+5561997220002', 'rita.722@test.com', '1982-02-02', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_ana from ids),  'profissional', 'Ana Garconete 722', '+5561997220003', 'ana.722@test.com',  '1995-03-03', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_beto from ids), 'profissional', 'Beto Garcom 722',   '+5561997220004', 'beto.722@test.com', '1996-04-04', '2026-09-22', '2026-10-25 12:00:00+00');

insert into public.profissional (id, usuario_id, ponto_base)
values
  ((select prof_ana from ids),  (select p_ana from ids),  'POINT(-47.8820 -15.7940)'::extensions.geography),
  ((select prof_beto from ids), (select p_beto from ids), 'POINT(-47.8830 -15.7950)'::extensions.geography);

grant select on ids to authenticated;

-- ── 3. Catalogo, anon e Prova do REVOKE de escrita para authenticated ─────────

select has_table('public', 'profissional', 'tabela public.profissional existe');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.profissional'::regclass),
  'RLS ativo em public.profissional'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.profissional') $$,
  '42501',
  null,
  'papel anon recebe 42501 em SELECT direto em public.profissional'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public' and table_name = 'profissional'),
  0,
  'anon nao possui grant em public.profissional'
);

-- Prova do REVOKE de escrita para authenticated (Frase 1 da Modelagem)
select throws_ok(
  $$ select pg_temp.como('authenticated', 'insert into public.profissional (usuario_id, ponto_base) values (gen_random_uuid(), ''POINT(-47.88 -15.79)''::extensions.geography)') $$,
  '42501',
  null,
  'prova do REVOKE: authenticated recebe 42501 em INSERT direto em public.profissional'
);

select throws_ok(
  $$ select pg_temp.como('authenticated', 'update public.profissional set turnos_realizados = 10') $$,
  '42501',
  null,
  'prova do REVOKE: authenticated recebe 42501 em UPDATE direto em public.profissional'
);

select throws_ok(
  $$ select pg_temp.como('authenticated', 'delete from public.profissional') $$,
  '42501',
  null,
  'prova do REVOKE: authenticated recebe 42501 em DELETE direto em public.profissional'
);

-- ── 4. Profissional le o seu proprio perfil ────────────────────────────────────

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  1,
  'profissional Ana le o seu proprio perfil de profissional'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    'select count(*)::int from public.profissional'
  ),
  1,
  'Ana le apenas o seu proprio perfil (1 linha)'
);

-- ── 5. Lacuna Top 9: Profissional concorrente NAO le perfil alheio ─────────────

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  0,
  'profissional concorrente (Beto) recebe 0 linhas no perfil de Ana (lacuna Top 9)'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_beto from ids))
  ),
  1,
  'Beto le o seu proprio perfil'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    'select count(*)::int from public.profissional'
  ),
  1,
  'Beto le apenas o seu proprio perfil no sistema'
);

-- ── 6. Contratante NAO le public.profissional via SELECT direto ────────────────

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  0,
  'contratante Ze recebe 0 linhas no perfil de Ana via SELECT direto (protege ponto_base)'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    'select count(*)::int from public.profissional'
  ),
  0,
  'contratante Ze le 0 perfis de profissionais no sistema'
);

-- ── 7. Isolamento de Terceiros e Anon ──────────────────────────────────────────

select is(
  pg_temp.contar_como(
    (select c_rita from ids),
    'select count(*)::int from public.profissional'
  ),
  0,
  'contratante Rita le 0 perfis de profissionais'
);

select is(
  pg_temp.contar_como(
    null,
    'select count(*)::int from public.profissional'
  ),
  0,
  'sessao sem claims (auth.uid() nulo) le 0 profissionais'
);

-- ── 8. Provas de Mutacao Real do Predicado USING ──────────────────────────────

-- Mutacao 1: Remocao total da politica fecha o acesso legitimo dos profissionais
drop policy profissional_leitura on public.profissional;

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  0,
  'mutante sem politica: Ana deixa de ler seu perfil'
);

-- Mutacao 2: Vazamento irrestrito (using true)
create policy profissional_leitura on public.profissional for select to authenticated
  using (true);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  1,
  'mutante com vazamento aberto: concorrente passaria a ler perfil e ponto_base de Ana'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  1,
  'mutante com vazamento aberto: contratante passaria a ler perfil e ponto_base de Ana'
);

-- Mutacao 3: Inversao por perfil (apenas contratante le)
drop policy profissional_leitura on public.profissional;
create policy profissional_leitura on public.profissional for select to authenticated
  using (
    (select perfil from public.usuario where id = (select auth.uid())) = 'contratante'
  );

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  0,
  'mutante invertido por perfil: profissional deixa de ler'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  1,
  'mutante invertido por perfil: contratante passa a ler indevidamente'
);

-- Restauracao da politica canonica e revalidacao final
drop policy profissional_leitura on public.profissional;
create policy profissional_leitura on public.profissional for select to authenticated
  using (usuario_id = (select auth.uid()));

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  1,
  'politica restaurada: Ana volta a ler seu perfil'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  0,
  'politica restaurada: Beto volta a receber 0 no perfil de Ana'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.profissional where id = %L', (select prof_ana from ids))
  ),
  0,
  'politica restaurada: Ze volta a receber 0 no perfil de Ana'
);

select * from finish();
rollback;
