-- 715_rls_posicao.sql
--
-- Cobertura de Row Level Security (RLS) para public.posicao (politica posicao_leitura):
--   Predicado:
--     using (profissional_id = (select privado.meu_profissional_id())
--            or privado.eh_membro(privado.estabelecimento_da_vaga(vaga_id)))
--
-- Casos cobertos:
--   1. Catalogo & RLS:
--      - RLS ativo em public.posicao;
--      - Papel anon recebe 42501 em SELECT direto e nao possui grant.
--   2. Membro do estabelecimento (privado.eh_membro):
--      - Contratante le todas as posicoes da vaga da sua casa (abertas e confirmadas);
--      - Contratante le especificamente a posicao aberta e a posicao confirmada.
--   3. Profissional confirmado (profissional_id = meu_profissional_id()):
--      - Profissional confirmada le a posicao que ocupa;
--      - Profissional confirmada le apenas a sua propria posicao na vaga.
--   4. Lacuna Top 3 - Candidato com candidatura ativa:
--      - Profissional que se candidatou a vaga aberta recebe 0 linhas em public.posicao
--        (a posicao aberta e confidencial da casa ate confirmacao; candidatura nao da acesso a posicao);
--      - Candidato le 0 posicoes da vaga.
--   5. Isolamento e Terceiros:
--      - Profissional terceiro le 0 linhas na posicao confirmada de outro profissional;
--      - Profissional sem qualquer vinculo le 0 posicoes;
--      - Contratante de outro estabelecimento le 0 posicoes da vaga alheia;
--      - Isolamento bidirecional entre estabelecimentos.
--   6. Provas de mutacao do predicado USING:
--      - Mutante sem politica: contratante e profissional deixam de ler;
--      - Mutante sem clausula membro: contratante nao le posicoes da casa;
--      - Mutante sem clausula profissional: profissional confirmada nao le sua posicao;
--      - Mutante com vazamento para candidatos: prova que candidato leria se houvesse vazamento;
--      - Restauracao da politica canonica e revalidacao completa.

begin;
select plan(25);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-25 12:00:00+00';
set local frila.agendador_secret = 'teste-segredo-715';

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
  '71500000-0000-4000-8000-000000000001'::uuid as c_ze,                -- contratante Bar do Ze
  '71500000-0000-4000-8000-000000000002'::uuid as c_rita,              -- contratante Buffet da Rita
  '71500000-0000-4000-8000-000000000003'::uuid as p_ana,               -- profissional confirmada
  '71500000-0000-4000-8000-000000000004'::uuid as p_beto,              -- profissional candidato nao-confirmado
  '71500000-0000-4000-8000-000000000005'::uuid as p_clara,             -- profissional terceira sem vinculo
  '71500000-0000-4000-8000-000000000013'::uuid as prof_ana,            -- perfil Ana
  '71500000-0000-4000-8000-000000000014'::uuid as prof_beto,           -- perfil Beto
  '71500000-0000-4000-8000-000000000015'::uuid as prof_clara,          -- perfil Clara
  '71500000-0000-4000-8000-000000000010'::uuid as estab_ze,            -- Bar do Ze
  '71500000-0000-4000-8000-000000000011'::uuid as estab_rita,          -- Buffet Rita
  '71500000-0000-4000-8000-000000000020'::uuid as fn_garcom,           -- funcao garcom
  '71500000-0000-4000-8000-000000000031'::uuid as vaga_ze,             -- vaga Ze
  '71500000-0000-4000-8000-000000000032'::uuid as vaga_rita,           -- vaga Rita
  '71500000-0000-4000-8000-000000000041'::uuid as pos_aberta,          -- posicao aberta (sem profissional)
  '71500000-0000-4000-8000-000000000042'::uuid as pos_confirmada_ana,   -- posicao confirmada para Ana
  '71500000-0000-4000-8000-000000000043'::uuid as pos_rita,            -- posicao da Rita
  '71500000-0000-4000-8000-000000000051'::uuid as cand_beto;           -- candidatura de Beto na pos_aberta

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', id_val, 'authenticated', 'authenticated',
       email_val, '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false
from (values
  ((select c_ze from ids),    'ze.715@test.com'),
  ((select c_rita from ids),  'rita.715@test.com'),
  ((select p_ana from ids),   'ana.715@test.com'),
  ((select p_beto from ids),  'beto.715@test.com'),
  ((select p_clara from ids), 'clara.715@test.com')
) as u(id_val, email_val);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ((select c_ze from ids),    'contratante',  'Ze Bar 715',         '+5561997150001', 'ze.715@test.com',    '1980-01-01', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_rita from ids),  'contratante',  'Rita Buffet 715',    '+5561997150002', 'rita.715@test.com',  '1982-02-02', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_ana from ids),   'profissional', 'Ana Garconete 715',  '+5561997150003', 'ana.715@test.com',   '1995-03-03', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_beto from ids),  'profissional', 'Beto Garcom 715',    '+5561997150004', 'beto.715@test.com',  '1996-04-04', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_clara from ids), 'profissional', 'Clara Terceira 715', '+5561997150005', 'clara.715@test.com', '1997-05-05', '2026-09-22', '2026-10-25 12:00:00+00');

insert into public.profissional (id, usuario_id, ponto_base)
values
  ((select prof_ana from ids),   (select p_ana from ids),   'POINT(-47.8820 -15.7940)'::extensions.geography),
  ((select prof_beto from ids),  (select p_beto from ids),  'POINT(-47.8830 -15.7950)'::extensions.geography),
  ((select prof_clara from ids), (select p_clara from ids), 'POINT(-47.8840 -15.7960)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values
  ((select estab_ze from ids),   'Bar do Ze 715',   '94827105000199', 'food_service', 'CLN 102', 'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto'),
  ((select estab_rita from ids), 'Buffet Rita 715', '94827105000188', 'evento',       'SIA 3',   'POINT(-47.89 -15.80)'::extensions.geography, 'SIA');

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
) values
  ((select vaga_ze from ids), (select estab_ze from ids), (select fn_garcom from ids),
   '2026-10-27 18:00:00+00', '2026-10-27 23:00:00+00', 'Salao do Ze',
   'POINT(-47.88 -15.79)'::extensions.geography, 15000, 2, true, false, false,
   'Seu Ze', 'urgencia', 'publicada',
   gen_random_uuid(), (select c_ze from ids), '2026-10-25 12:00:00+00'),
  ((select vaga_rita from ids), (select estab_rita from ids), (select fn_garcom from ids),
   '2026-10-28 18:00:00+00', '2026-10-28 23:00:00+00', 'Buffet Rita',
   'POINT(-47.89 -15.80)'::extensions.geography, 16000, 1, true, false, false,
   'Dona Rita', 'urgencia', 'publicada',
   gen_random_uuid(), (select c_rita from ids), '2026-10-25 12:00:00+00');

-- Posicoes da vaga do Ze: 1 aberta e 1 confirmada para Ana
insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
values
  ((select pos_aberta from ids), (select vaga_ze from ids), '2026-10-27 18:00:00+00', '2026-10-27 23:00:00+00', 'aberta', null, null),
  ((select pos_confirmada_ana from ids), (select vaga_ze from ids), '2026-10-27 18:00:00+00', '2026-10-27 23:00:00+00', 'confirmada', (select prof_ana from ids), '2026-10-25 12:00:00+00');

-- Posicao da vaga da Rita: 1 aberta
insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
values
  ((select pos_rita from ids), (select vaga_rita from ids), '2026-10-28 18:00:00+00', '2026-10-28 23:00:00+00', 'aberta', null, null);

-- Beto se candidata a posicao aberta da vaga do Ze (mas NAO e confirmado nela)
insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado)
values
  ((select cand_beto from ids), (select pos_aberta from ids), (select prof_beto from ids), '2026-10-25 12:00:00+00', 'pendente');

grant select on ids to authenticated;

-- ── 3. Catalogo e anon ─────────────────────────────────────────────────────────

select has_table('public', 'posicao', 'tabela public.posicao existe');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.posicao'::regclass),
  'RLS ativo em public.posicao'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.posicao') $$,
  '42501',
  null,
  'papel anon recebe 42501 em SELECT direto em public.posicao'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public' and table_name = 'posicao'),
  0,
  'anon nao possui grant em public.posicao'
);

-- ── 4. Membro do Estabelecimento (privado.eh_membro) ──────────────────────────

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.posicao where vaga_id = %L', (select vaga_ze from ids))
  ),
  2,
  'membro do estabelecimento le todas as posicoes da vaga da casa (abertas e confirmadas)'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_aberta from ids))
  ),
  1,
  'membro le a posicao em estado aberta'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_confirmada_ana from ids))
  ),
  1,
  'membro le a posicao confirmada da casa'
);

-- ── 5. Profissional Confirmado (profissional_id = meu_profissional_id) ─────────

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_confirmada_ana from ids))
  ),
  1,
  'profissional confirmada le a posicao que ocupa'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.posicao where vaga_id = %L', (select vaga_ze from ids))
  ),
  1,
  'profissional confirmada le apenas a sua propria posicao na vaga'
);

-- ── 6. Lacuna Top 3: Candidato com candidatura ativa NAO le posicao aberta ─────

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_aberta from ids))
  ),
  0,
  'candidato com candidatura ativa recebe 0 linhas na posicao em estado aberta (lacuna Top 3)'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.posicao where vaga_id = %L', (select vaga_ze from ids))
  ),
  0,
  'candidato com candidatura ativa le 0 posicoes da vaga'
);

-- ── 7. Isolamento de Terceiros e Outros Estabelecimentos ────────────────────────

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_confirmada_ana from ids))
  ),
  0,
  'profissional terceiro le 0 linhas na posicao confirmada de outro profissional'
);

select is(
  pg_temp.contar_como(
    (select p_clara from ids),
    'select count(*)::int from public.posicao'
  ),
  0,
  'profissional sem vinculo le 0 posicoes no sistema'
);

select is(
  pg_temp.contar_como(
    (select c_rita from ids),
    format('select count(*)::int from public.posicao where vaga_id = %L', (select vaga_ze from ids))
  ),
  0,
  'contratante de outro estabelecimento le 0 posicoes da vaga alheia'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.posicao where vaga_id = %L', (select vaga_rita from ids))
  ),
  0,
  'contratante do bar le 0 posicoes da vaga do buffet da Rita'
);

-- ── 8. Provas de Mutacao Real do Predicado USING ──────────────────────────────

-- Mutacao 1: Remocao total da politica fecha o acesso legitimo
drop policy posicao_leitura on public.posicao;

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.posicao where vaga_id = %L', (select vaga_ze from ids))
  ),
  0,
  'mutante sem politica: contratante da casa deixa de ler posicoes'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_confirmada_ana from ids))
  ),
  0,
  'mutante sem politica: profissional confirmada deixa de ler sua posicao'
);

-- Mutacao 2: Remocao da clausula de membro (apenas profissional_id = meu_profissional_id)
create policy posicao_leitura on public.posicao for select to authenticated
  using (profissional_id = (select privado.meu_profissional_id()));

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.posicao where vaga_id = %L', (select vaga_ze from ids))
  ),
  0,
  'mutante sem clausula membro: contratante nao consegue ler posicoes da casa'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_confirmada_ana from ids))
  ),
  1,
  'mutante sem clausula membro: profissional confirmada ainda le sua posicao'
);

-- Mutacao 3: Remocao da clausula de profissional (apenas eh_membro)
drop policy posicao_leitura on public.posicao;
create policy posicao_leitura on public.posicao for select to authenticated
  using (privado.eh_membro(privado.estabelecimento_da_vaga(vaga_id)));

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_confirmada_ana from ids))
  ),
  0,
  'mutante sem clausula profissional: profissional confirmada nao le sua posicao'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.posicao where vaga_id = %L', (select vaga_ze from ids))
  ),
  2,
  'mutante sem clausula profissional: contratante ainda le posicoes'
);

-- Mutacao 4: Simulacao de vazamento para candidatos (o que a regra proibe e protege)
drop policy posicao_leitura on public.posicao;
create policy posicao_leitura on public.posicao for select to authenticated
  using (
    profissional_id = (select privado.meu_profissional_id())
    or privado.eh_membro(privado.estabelecimento_da_vaga(vaga_id))
    or exists (
      select 1 from public.candidatura c
       where c.posicao_id = posicao.id
         and c.profissional_id = (select privado.meu_profissional_id())
    )
  );

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_aberta from ids))
  ),
  1,
  'mutante com vazamento para candidato: comprova que candidato leria se houvesse vazamento'
);

-- Restauracao da politica canonica e verificacao final
drop policy posicao_leitura on public.posicao;
create policy posicao_leitura on public.posicao for select to authenticated
  using (profissional_id = (select privado.meu_profissional_id())
         or privado.eh_membro(privado.estabelecimento_da_vaga(vaga_id)));

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.posicao where vaga_id = %L', (select vaga_ze from ids))
  ),
  2,
  'politica restaurada: contratante le novamente suas 2 posicoes'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_confirmada_ana from ids))
  ),
  1,
  'politica restaurada: profissional le novamente sua posicao'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.posicao where id = %L', (select pos_aberta from ids))
  ),
  0,
  'politica restaurada: candidato volta a ler 0 posicoes abertas'
);

select * from finish();
rollback;
