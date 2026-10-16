-- 717_rls_bloqueio.sql
--
-- Cobertura de Row Level Security (RLS) para public.bloqueio (politica bloqueio_leitura):
--   Predicado:
--     using (autor_id = (select auth.uid()))
--
-- Casos cobertos:
--   1. Catalogo & RLS:
--      - RLS ativo em public.bloqueio;
--      - Papel anon recebe 42501 em SELECT direto e nao possui grant.
--   2. Autor le seu proprio bloqueio:
--      - Contratante autor (Ze) le o bloqueio cadastrado por ele;
--      - Profissional autora (Ana) le o bloqueio cadastrado por ela.
--   3. Bloqueado NAO descobre quem o bloqueou (Protecao RF26 contra risco e retaliacao):
--      - Profissional bloqueada (Ana) recebe 0 linhas no bloqueio criado contra si por Ze;
--      - Profissional bloqueado (Beto) recebe 0 linhas no bloqueio criado por Ana;
--      - Usuario que apenas sofreu bloqueios le 0 bloqueios no sistema.
--   4. Lacuna Top 5 - Colega de estabelecimento NAO le bloqueio do outro membro:
--      - Operadora Nina (mesmo estabelecimento de Ze) recebe 0 linhas no bloqueio pessoal de Ze
--        (bloqueio e estritamente pessoal, evitando constrangimento ou interferencia interna);
--      - Nina le 0 bloqueios no sistema.
--   5. Isolamento de terceiros:
--      - Profissional sem vinculo le 0 bloqueios;
--      - Contratante de outro estabelecimento le 0 bloqueios alheios;
--      - Sessao sem claims (auth.uid() nulo) le 0 bloqueios.
--   6. Provas de mutacao real do predicado USING:
--      - Mutante sem politica: autores deixam de ler;
--      - Mutante com vazamento para o bloqueado: detecta se bloqueada passasse a ler;
--      - Mutante com vazamento para colegas de estabelecimento: detecta se Nina passasse a ler;
--      - Mutante com inversao autor/bloqueado: autor perde e bloqueado ganha;
--      - Restauracao da politica canonica e revalidacao completa.

begin;
select plan(25);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-25 12:00:00+00';
set local frila.agendador_secret = 'teste-segredo-717';

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
  '71700000-0000-4000-8000-000000000001'::uuid as c_ze,                -- contratante Bar do Ze (admin)
  '71700000-0000-4000-8000-000000000002'::uuid as c_nina,              -- contratante Bar do Ze (operadora)
  '71700000-0000-4000-8000-000000000003'::uuid as c_rita,              -- contratante Buffet da Rita (admin)
  '71700000-0000-4000-8000-000000000004'::uuid as p_ana,               -- profissional Ana
  '71700000-0000-4000-8000-000000000005'::uuid as p_beto,              -- profissional Beto
  '71700000-0000-4000-8000-000000000006'::uuid as p_clara,             -- profissional Clara
  '71700000-0000-4000-8000-000000000014'::uuid as prof_ana,            -- perfil Ana
  '71700000-0000-4000-8000-000000000015'::uuid as prof_beto,           -- perfil Beto
  '71700000-0000-4000-8000-000000000016'::uuid as prof_clara,          -- perfil Clara
  '71700000-0000-4000-8000-000000000010'::uuid as estab_ze,            -- Bar do Ze
  '71700000-0000-4000-8000-000000000011'::uuid as estab_rita,          -- Buffet Rita
  '71700000-0000-4000-8000-000000000071'::uuid as bloq_ze_ana,         -- bloqueio Ze -> Ana
  '71700000-0000-4000-8000-000000000072'::uuid as bloq_ana_beto,        -- bloqueio Ana -> Beto
  '71700000-0000-4000-8000-000000000073'::uuid as bloq_rita_beto;       -- bloqueio Rita -> Beto

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', id_val, 'authenticated', 'authenticated',
       email_val, '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false
from (values
  ((select c_ze from ids),    'ze.717@test.com'),
  ((select c_nina from ids),  'nina.717@test.com'),
  ((select c_rita from ids),  'rita.717@test.com'),
  ((select p_ana from ids),   'ana.717@test.com'),
  ((select p_beto from ids),  'beto.717@test.com'),
  ((select p_clara from ids), 'clara.717@test.com')
) as u(id_val, email_val);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ((select c_ze from ids),    'contratante',  'Ze Bar 717',         '+5561997170001', 'ze.717@test.com',    '1980-01-01', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_nina from ids),  'contratante',  'Nina Operadora 717', '+5561997170002', 'nina.717@test.com',  '1985-02-02', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_rita from ids),  'contratante',  'Rita Buffet 717',    '+5561997170003', 'rita.717@test.com',  '1982-03-03', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_ana from ids),   'profissional', 'Ana Garconete 717',  '+5561997170004', 'ana.717@test.com',   '1995-04-04', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_beto from ids),  'profissional', 'Beto Garcom 717',    '+5561997170005', 'beto.717@test.com',  '1996-05-05', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_clara from ids), 'profissional', 'Clara Terceira 717', '+5561997170006', 'clara.717@test.com', '1997-06-06', '2026-09-22', '2026-10-25 12:00:00+00');

insert into public.profissional (id, usuario_id, ponto_base)
values
  ((select prof_ana from ids),   (select p_ana from ids),   'POINT(-47.8820 -15.7940)'::extensions.geography),
  ((select prof_beto from ids),  (select p_beto from ids),  'POINT(-47.8830 -15.7950)'::extensions.geography),
  ((select prof_clara from ids), (select p_clara from ids), 'POINT(-47.8840 -15.7960)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values
  ((select estab_ze from ids),   'Bar do Ze 717',   '94827107000199', 'food_service', 'CLN 102', 'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto'),
  ((select estab_rita from ids), 'Buffet Rita 717', '94827107000188', 'evento',       'SIA 3',   'POINT(-47.89 -15.80)'::extensions.geography, 'SIA');

-- Bar do Ze tem dois membros: Ze (administrador) e Nina (operadora)
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values
  ((select c_ze from ids),   (select estab_ze from ids),   'administrador'),
  ((select c_nina from ids), (select estab_ze from ids),   'operador'),
  ((select c_rita from ids), (select estab_rita from ids), 'administrador');

-- Bloqueios hermeticos
insert into public.bloqueio (id, autor_id, bloqueado_id, criado_em)
values
  ((select bloq_ze_ana from ids),   (select c_ze from ids),   (select p_ana from ids),  '2026-10-25 10:00:00+00'),
  ((select bloq_ana_beto from ids),  (select p_ana from ids),  (select p_beto from ids), '2026-10-25 10:30:00+00'),
  ((select bloq_rita_beto from ids), (select c_rita from ids), (select p_beto from ids), '2026-10-25 11:00:00+00');

grant select on ids to authenticated;

-- ── 3. Catalogo e anon ─────────────────────────────────────────────────────────

select has_table('public', 'bloqueio', 'tabela public.bloqueio existe');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.bloqueio'::regclass),
  'RLS ativo em public.bloqueio'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.bloqueio') $$,
  '42501',
  null,
  'papel anon recebe 42501 em SELECT direto em public.bloqueio'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public' and table_name = 'bloqueio'),
  0,
  'anon nao possui grant em public.bloqueio'
);

-- ── 4. Autor le seu proprio bloqueio ───────────────────────────────────────────

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  1,
  'autor contratante (Ze) le o bloqueio que cadastrou'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    'select count(*)::int from public.bloqueio'
  ),
  1,
  'Ze le apenas o seu proprio bloqueio cadastrado'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ana_beto from ids))
  ),
  1,
  'autora profissional (Ana) le o bloqueio que cadastrou'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    'select count(*)::int from public.bloqueio'
  ),
  1,
  'Ana le apenas o seu proprio bloqueio cadastrado'
);

-- ── 5. Bloqueado NAO descobre quem o bloqueou (RF26) ───────────────────────────

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  0,
  'bloqueada (Ana) recebe 0 linhas no bloqueio cadastrado contra si por Ze'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ana_beto from ids))
  ),
  0,
  'bloqueado (Beto) recebe 0 linhas no bloqueio cadastrado contra si por Ana'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    'select count(*)::int from public.bloqueio'
  ),
  0,
  'usuario que apenas sofreu bloqueios le 0 bloqueios no sistema'
);

-- ── 6. Lacuna Top 5: Colega de estabelecimento NAO le bloqueio de outro membro ─

select is(
  pg_temp.contar_como(
    (select c_nina from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  0,
  'colega de estabelecimento (Nina) recebe 0 linhas no bloqueio pessoal de Ze (lacuna Top 5)'
);

select is(
  pg_temp.contar_como(
    (select c_nina from ids),
    'select count(*)::int from public.bloqueio'
  ),
  0,
  'membro sem bloqueios proprios le 0 bloqueios mesmo tendo colega que bloqueou'
);

-- ── 7. Isolamento de Terceiros e Outros Estabelecimentos ────────────────────────

select is(
  pg_temp.contar_como(
    (select p_clara from ids),
    'select count(*)::int from public.bloqueio'
  ),
  0,
  'profissional terceira sem vinculo le 0 bloqueios'
);

select is(
  pg_temp.contar_como(
    (select c_rita from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  0,
  'contratante de outro estabelecimento le 0 bloqueios da outra casa'
);

select is(
  pg_temp.contar_como(
    null,
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  0,
  'sessao sem claims (auth.uid() nulo) le 0 bloqueios'
);

-- ── 8. Provas de Mutacao Real do Predicado USING ──────────────────────────────

-- Mutacao 1: Remocao total da politica fecha o acesso
drop policy bloqueio_leitura on public.bloqueio;

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  0,
  'mutante sem politica: autor Ze deixa de ler bloqueio'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ana_beto from ids))
  ),
  0,
  'mutante sem politica: autora Ana deixa de ler bloqueio'
);

-- Mutacao 2: Vazamento para o bloqueado (simulando quebra grave de privacidade/seguranca)
create policy bloqueio_leitura on public.bloqueio for select to authenticated
  using (
    autor_id = (select auth.uid())
    or bloqueado_id = (select auth.uid())
  );

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  1,
  'mutante com vazamento para bloqueado: comprova que bloqueada leria se houvesse vazamento'
);

-- Mutacao 3: Vazamento para colegas de estabelecimento
drop policy bloqueio_leitura on public.bloqueio;
create policy bloqueio_leitura on public.bloqueio for select to authenticated
  using (
    autor_id = (select auth.uid())
    or exists (
      select 1 from public.membro_estabelecimento m1
        join public.membro_estabelecimento m2 on m2.estabelecimento_id = m1.estabelecimento_id
       where m1.usuario_id = bloqueio.autor_id
         and m2.usuario_id = (select auth.uid())
    )
  );

select is(
  pg_temp.contar_como(
    (select c_nina from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  1,
  'mutante com vazamento para colega do estab: comprova que Nina leria bloqueio de Ze'
);

-- Mutacao 4: Inversao indevida (bloqueado le em vez do autor)
drop policy bloqueio_leitura on public.bloqueio;
create policy bloqueio_leitura on public.bloqueio for select to authenticated
  using (bloqueado_id = (select auth.uid()));

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  0,
  'mutante com inversao autor/bloqueado: autor deixa de ler'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  1,
  'mutante com inversao autor/bloqueado: bloqueada passa a ler indevidamente'
);

-- Restauracao da politica canonica e verificacao final
drop policy bloqueio_leitura on public.bloqueio;
create policy bloqueio_leitura on public.bloqueio for select to authenticated
  using (autor_id = (select auth.uid()));

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  1,
  'politica restaurada: Ze le novamente seu bloqueio'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  0,
  'politica restaurada: Ana volta a receber 0 no bloqueio contra si'
);

select is(
  pg_temp.contar_como(
    (select c_nina from ids),
    format('select count(*)::int from public.bloqueio where id = %L', (select bloq_ze_ana from ids))
  ),
  0,
  'politica restaurada: Nina volta a receber 0 no bloqueio do colega'
);

select * from finish();
rollback;
