-- 718_rls_despacho.sql
--
-- Cobertura de Row Level Security (RLS) para public.despacho (politica despacho_leitura):
--   Predicado:
--     using (profissional_id = (select privado.meu_profissional_id()))
--
-- Casos cobertos:
--   1. Catalogo & RLS:
--      - RLS ativo em public.despacho;
--      - Papel anon recebe 42501 em SELECT direto e nao possui grant.
--   2. Profissional despachado le seus proprios despachos:
--      - Profissional Ana le o despacho enderecado a ela;
--      - Ana le apenas o seu proprio despacho.
--   3. Lacuna Top 6 - Profissional concorrente NAO le despachos alheios:
--      - Profissional Beto recebe 0 linhas no despacho emitido para Ana
--        (protege a privacidade do funil de despacho e disponibilidade geografica contra concorrentes);
--      - Beto le 0 despachos no sistema.
--   4. Contratante dono da vaga NAO le despachos:
--      - Contratante Ze (membro do estabelecimento que publicou a vaga) recebe 0 linhas
--        (a modelagem proibe a casa de ver quem foi notificado para nao vazar localizacao/disponibilidade;
--        o contratante ve apenas quem efetivamente se candidatou);
--      - Ze le 0 despachos da sua propria vaga.
--   5. Isolamento de terceiros:
--      - Profissional sem vinculo le 0 despachos;
--      - Contratante de outro estabelecimento le 0 despachos;
--      - Sessao sem claims (auth.uid() nulo) le 0 despachos.
--   6. Provas de mutacao real do predicado USING:
--      - Mutante sem politica: profissional despachada deixa de ler;
--      - Mutante com vazamento aberto: detecta se outros profissionais lessem;
--      - Mutante com vazamento para contratante da vaga: detecta se dono da casa lesse despachos;
--      - Mutante com inversao profissional/estabelecimento: profissional perde e contratante ganha indevidamente;
--      - Restauracao da politica canonica e revalidacao completa.

begin;
select plan(21);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-25 12:00:00+00';
set local frila.agendador_secret = 'teste-segredo-718';

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
  '71800000-0000-4000-8000-000000000001'::uuid as c_ze,                -- contratante Bar do Ze
  '71800000-0000-4000-8000-000000000002'::uuid as c_rita,              -- contratante Buffet da Rita
  '71800000-0000-4000-8000-000000000003'::uuid as p_ana,               -- profissional Ana (despachada)
  '71800000-0000-4000-8000-000000000004'::uuid as p_beto,              -- profissional Beto (concorrente)
  '71800000-0000-4000-8000-000000000005'::uuid as p_clara,             -- profissional Clara (sem vinculo)
  '71800000-0000-4000-8000-000000000013'::uuid as prof_ana,            -- perfil Ana
  '71800000-0000-4000-8000-000000000014'::uuid as prof_beto,           -- perfil Beto
  '71800000-0000-4000-8000-000000000015'::uuid as prof_clara,          -- perfil Clara
  '71800000-0000-4000-8000-000000000010'::uuid as estab_ze,            -- Bar do Ze
  '71800000-0000-4000-8000-000000000011'::uuid as estab_rita,          -- Buffet Rita
  '71800000-0000-4000-8000-000000000020'::uuid as fn_garcom,           -- funcao garcom
  '71800000-0000-4000-8000-000000000031'::uuid as vaga_ze,             -- vaga Ze
  '71800000-0000-4000-8000-000000000081'::uuid as desp_ana;            -- despacho emitido para Ana

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', id_val, 'authenticated', 'authenticated',
       email_val, '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false
from (values
  ((select c_ze from ids),    'ze.718@test.com'),
  ((select c_rita from ids),  'rita.718@test.com'),
  ((select p_ana from ids),   'ana.718@test.com'),
  ((select p_beto from ids),  'beto.718@test.com'),
  ((select p_clara from ids), 'clara.718@test.com')
) as u(id_val, email_val);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ((select c_ze from ids),    'contratante',  'Ze Bar 718',         '+5561997180001', 'ze.718@test.com',    '1980-01-01', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_rita from ids),  'contratante',  'Rita Buffet 718',    '+5561997180002', 'rita.718@test.com',  '1982-02-02', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_ana from ids),   'profissional', 'Ana Garconete 718',  '+5561997180003', 'ana.718@test.com',   '1995-03-03', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_beto from ids),  'profissional', 'Beto Garcom 718',    '+5561997180004', 'beto.718@test.com',  '1996-04-04', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_clara from ids), 'profissional', 'Clara Terceira 718', '+5561997180005', 'clara.718@test.com', '1997-05-05', '2026-09-22', '2026-10-25 12:00:00+00');

insert into public.profissional (id, usuario_id, ponto_base)
values
  ((select prof_ana from ids),   (select p_ana from ids),   'POINT(-47.8820 -15.7940)'::extensions.geography),
  ((select prof_beto from ids),  (select p_beto from ids),  'POINT(-47.8830 -15.7950)'::extensions.geography),
  ((select prof_clara from ids), (select p_clara from ids), 'POINT(-47.8840 -15.7960)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values
  ((select estab_ze from ids),   'Bar do Ze 718',   '94827108000199', 'food_service', 'CLN 102', 'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto'),
  ((select estab_rita from ids), 'Buffet Rita 718', '94827108000188', 'evento',       'SIA 3',   'POINT(-47.89 -15.80)'::extensions.geography, 'SIA');

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values
  ((select c_ze from ids),   (select estab_ze from ids),   'administrador'),
  ((select c_rita from ids), (select estab_rita from ids), 'administrador');

update ids set fn_garcom = (select id from public.funcao where nome = 'garçom' limit 1);

insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  (select vaga_ze from ids), (select estab_ze from ids), (select fn_garcom from ids),
  '2026-10-27 18:00:00+00', '2026-10-27 23:00:00+00', 'Salao do Ze',
  'POINT(-47.88 -15.79)'::extensions.geography, 15000, 1, true, false, false,
  'Seu Ze', 'urgencia', 'publicada',
  gen_random_uuid(), (select c_ze from ids), '2026-10-25 12:00:00+00'
);

-- Despacho emitido para Ana
insert into public.despacho (id, vaga_id, profissional_id, criado_em)
values
  ((select desp_ana from ids), (select vaga_ze from ids), (select prof_ana from ids), '2026-10-25 12:05:00+00');

grant select on ids to authenticated;

-- ── 3. Catalogo e anon ─────────────────────────────────────────────────────────

select has_table('public', 'despacho', 'tabela public.despacho existe');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.despacho'::regclass),
  'RLS ativo em public.despacho'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.despacho') $$,
  '42501',
  'permission denied for table despacho',
  'papel anon recebe 42501 em SELECT direto em public.despacho'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public' and table_name = 'despacho'),
  0,
  'anon nao possui grant em public.despacho'
);

-- ── 4. Profissional despachado le o seu proprio despacho ───────────────────────

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.despacho where id = %L', (select desp_ana from ids))
  ),
  1,
  'profissional despachada le o despacho emitido para ela'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    'select count(*)::int from public.despacho'
  ),
  1,
  'profissional despachada le apenas o seu proprio despacho'
);

-- ── 5. Lacuna Top 6: Outro profissional concorrente NAO le despachos alheios ───

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.despacho where id = %L', (select desp_ana from ids))
  ),
  0,
  'profissional concorrente (Beto) recebe 0 linhas no despacho de Ana (lacuna Top 6)'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    'select count(*)::int from public.despacho'
  ),
  0,
  'profissional concorrente le 0 despachos no sistema'
);

-- ── 6. Contratante dono da vaga NAO le despachos emitidos ──────────────────────

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.despacho where vaga_id = %L', (select vaga_ze from ids))
  ),
  0,
  'contratante criador da vaga recebe 0 linhas nos despachos da casa (sigilo de disponibilidade)'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    'select count(*)::int from public.despacho'
  ),
  0,
  'contratante le 0 despachos no sistema'
);

-- ── 7. Isolamento de Terceiros e Outros Estabelecimentos ────────────────────────

select is(
  pg_temp.contar_como(
    (select p_clara from ids),
    'select count(*)::int from public.despacho'
  ),
  0,
  'profissional terceira sem vinculo le 0 despachos'
);

select is(
  pg_temp.contar_como(
    (select c_rita from ids),
    format('select count(*)::int from public.despacho where id = %L', (select desp_ana from ids))
  ),
  0,
  'contratante de outro estabelecimento le 0 despachos alheios'
);

select is(
  pg_temp.contar_como(
    null,
    format('select count(*)::int from public.despacho where id = %L', (select desp_ana from ids))
  ),
  0,
  'sessao sem claims (auth.uid() nulo) le 0 despachos'
);

-- ── 8. Provas de Mutacao Real do Predicado USING ──────────────────────────────

-- Mutacao 1: Remocao total da politica fecha o acesso legitimo
drop policy despacho_leitura on public.despacho;

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.despacho where id = %L', (select desp_ana from ids))
  ),
  0,
  'mutante sem politica: profissional despachada deixa de ler seu despacho'
);

-- Mutacao 2: Vazamento irrestrito (usando true)
create policy despacho_leitura on public.despacho for select to authenticated
  using (true);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.despacho where id = %L', (select desp_ana from ids))
  ),
  1,
  'mutante com vazamento aberto: comprova que outro profissional leria despacho alheio'
);

-- Mutacao 3: Vazamento para o estabelecimento da vaga
drop policy despacho_leitura on public.despacho;
create policy despacho_leitura on public.despacho for select to authenticated
  using (
    profissional_id = (select privado.meu_profissional_id())
    or privado.eh_membro(privado.estabelecimento_da_vaga(vaga_id))
  );

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.despacho where vaga_id = %L', (select vaga_ze from ids))
  ),
  1,
  'mutante com vazamento para estabelecimento: comprova que contratante leria despachos'
);

-- Mutacao 4: Inversao indevida (apenas estabelecimento le, profissional nao le)
drop policy despacho_leitura on public.despacho;
create policy despacho_leitura on public.despacho for select to authenticated
  using (privado.eh_membro(privado.estabelecimento_da_vaga(vaga_id)));

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.despacho where id = %L', (select desp_ana from ids))
  ),
  0,
  'mutante com inversao: profissional despachada deixa de ler'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.despacho where vaga_id = %L', (select vaga_ze from ids))
  ),
  1,
  'mutante com inversao: contratante passa a ler indevidamente'
);

-- Restauracao da politica canonica e verificacao final
drop policy despacho_leitura on public.despacho;
create policy despacho_leitura on public.despacho for select to authenticated
  using (profissional_id = (select privado.meu_profissional_id()));

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.despacho where id = %L', (select desp_ana from ids))
  ),
  1,
  'politica restaurada: Ana le novamente seu despacho'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.despacho where id = %L', (select desp_ana from ids))
  ),
  0,
  'politica restaurada: Beto volta a receber 0 no despacho de Ana'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.despacho where vaga_id = %L', (select vaga_ze from ids))
  ),
  0,
  'politica restaurada: Ze volta a receber 0 nos despachos da vaga'
);

select * from finish();
rollback;
