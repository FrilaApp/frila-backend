-- 716_rls_turno.sql
--
-- Cobertura de Row Level Security (RLS) para public.turno (politica turno_leitura):
--   Predicado:
--     using (privado.lado_da_posicao(posicao_id))
--
-- Casos cobertos:
--   1. Catalogo & RLS:
--      - RLS ativo em public.turno;
--      - Papel anon recebe 42501 em SELECT direto e nao possui grant.
--   2. Dois lados da posicao:
--      - Contratante (membro do estabelecimento da posicao) le o turno realizado;
--      - Profissional confirmada le o seu proprio turno.
--   3. Preservacao historica pos-bloqueio (Requisito Critico RN26 / RF26):
--      - O bloqueio mutuo posterior entre contratante e profissional NAO apaga nem esconde
--        o registro historico do turno ja cumprido;
--      - Ambos os lados continuam conseguindo ler o turno via SELECT direto.
--   4. Lacuna Top 4 - Candidato rejeitado/nao confirmado da mesma vaga:
--      - Candidato com candidatura ativa em outra posicao da mesma vaga recebe 0 linhas
--        para o turno cumprido pela profissional vencedora (protecao RN22 de dados de presenca);
--      - Candidato le 0 turnos no sistema.
--   5. Isolamento de terceiros:
--      - Profissional terceira sem vinculo le 0 turnos;
--      - Contratante de outro estabelecimento le 0 turnos da casa alheia;
--      - Sessao sem claims (auth.uid() nulo) le 0 turnos.
--   6. Provas de mutacao real do predicado USING:
--      - Mutante sem politica: contratante e profissional deixam de ler;
--      - Mutante com bloqueio indevido: profissional bloqueada perde historico (prova de preservacao);
--      - Mutante sem lado do profissional: profissional confirmada deixa de ler;
--      - Mutante sem lado do estabelecimento: contratante deixa de ler;
--      - Mutante com vazamento para candidatos: detecta vazamento para candidatos da mesma vaga;
--      - Restauracao da politica canonica e revalidacao completa.

begin;
select plan(24);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-25 12:00:00+00';
set local frila.agendador_secret = 'teste-segredo-716';

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
  '71600000-0000-4000-8000-000000000001'::uuid as c_ze,                -- contratante Bar do Ze
  '71600000-0000-4000-8000-000000000002'::uuid as c_rita,              -- contratante Buffet da Rita
  '71600000-0000-4000-8000-000000000003'::uuid as p_ana,               -- profissional confirmada no turno
  '71600000-0000-4000-8000-000000000004'::uuid as p_beto,              -- profissional candidato da vaga
  '71600000-0000-4000-8000-000000000005'::uuid as p_clara,             -- profissional terceira sem vinculo
  '71600000-0000-4000-8000-000000000013'::uuid as prof_ana,            -- perfil Ana
  '71600000-0000-4000-8000-000000000014'::uuid as prof_beto,           -- perfil Beto
  '71600000-0000-4000-8000-000000000015'::uuid as prof_clara,          -- perfil Clara
  '71600000-0000-4000-8000-000000000010'::uuid as estab_ze,            -- Bar do Ze
  '71600000-0000-4000-8000-000000000011'::uuid as estab_rita,          -- Buffet Rita
  '71600000-0000-4000-8000-000000000020'::uuid as fn_garcom,           -- funcao garcom
  '71600000-0000-4000-8000-000000000031'::uuid as vaga_ze,             -- vaga Ze
  '71600000-0000-4000-8000-000000000041'::uuid as pos_ana,             -- posicao confirmada Ana
  '71600000-0000-4000-8000-000000000042'::uuid as pos_aberta,          -- posicao aberta da mesma vaga
  '71600000-0000-4000-8000-000000000051'::uuid as cand_beto,           -- candidatura de Beto
  '71600000-0000-4000-8000-000000000061'::uuid as turno_ana,           -- turno de Ana
  '71600000-0000-4000-8000-000000000071'::uuid as bloq_ze_ana;         -- bloqueio Ze -> Ana

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', id_val, 'authenticated', 'authenticated',
       email_val, '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false
from (values
  ((select c_ze from ids),    'ze.716@test.com'),
  ((select c_rita from ids),  'rita.716@test.com'),
  ((select p_ana from ids),   'ana.716@test.com'),
  ((select p_beto from ids),  'beto.716@test.com'),
  ((select p_clara from ids), 'clara.716@test.com')
) as u(id_val, email_val);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ((select c_ze from ids),    'contratante',  'Ze Bar 716',         '+5561997160001', 'ze.716@test.com',    '1980-01-01', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_rita from ids),  'contratante',  'Rita Buffet 716',    '+5561997160002', 'rita.716@test.com',  '1982-02-02', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_ana from ids),   'profissional', 'Ana Garconete 716',  '+5561997160003', 'ana.716@test.com',   '1995-03-03', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_beto from ids),  'profissional', 'Beto Garcom 716',    '+5561997160004', 'beto.716@test.com',  '1996-04-04', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_clara from ids), 'profissional', 'Clara Terceira 716', '+5561997160005', 'clara.716@test.com', '1997-05-05', '2026-09-22', '2026-10-25 12:00:00+00');

insert into public.profissional (id, usuario_id, ponto_base)
values
  ((select prof_ana from ids),   (select p_ana from ids),   'POINT(-47.8820 -15.7940)'::extensions.geography),
  ((select prof_beto from ids),  (select p_beto from ids),  'POINT(-47.8830 -15.7950)'::extensions.geography),
  ((select prof_clara from ids), (select p_clara from ids), 'POINT(-47.8840 -15.7960)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values
  ((select estab_ze from ids),   'Bar do Ze 716',   '94827106000199', 'food_service', 'CLN 102', 'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto'),
  ((select estab_rita from ids), 'Buffet Rita 716', '94827106000188', 'evento',       'SIA 3',   'POINT(-47.89 -15.80)'::extensions.geography, 'SIA');

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
  '2026-10-24 18:00:00+00', '2026-10-24 23:00:00+00', 'Salao do Ze',
  'POINT(-47.88 -15.79)'::extensions.geography, 15000, 2, true, false, false,
  'Seu Ze', 'urgencia', 'publicada',
  gen_random_uuid(), (select c_ze from ids), '2026-10-24 12:00:00+00'
);

-- Posicao cumprida/confirmada da Ana
insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
values
  ((select pos_ana from ids), (select vaga_ze from ids),
   '2026-10-24 18:00:00+00', '2026-10-24 23:00:00+00', 'confirmada',
   (select prof_ana from ids), '2026-10-24 12:30:00+00');

-- Posicao aberta da mesma vaga
insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
values
  ((select pos_aberta from ids), (select vaga_ze from ids),
   '2026-10-24 18:00:00+00', '2026-10-24 23:00:00+00', 'aberta', null, null);

-- Candidatura de Beto na posicao que foi preenchida por Ana (candidato concorrente/rejeitado)
insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado)
values
  ((select cand_beto from ids), (select pos_ana from ids),
   (select prof_beto from ids), '2026-10-24 13:00:00+00', 'pendente');

-- Turno cumprido associado a posicao de Ana
insert into public.turno (
  id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m,
  checkout_em, checkout_distancia_m, verificacao, valor_acordado_centavos
) values (
  (select turno_ana from ids), (select pos_ana from ids),
  '2026-10-24 17:55:00+00', 'geolocalizado', 45,
  '2026-10-24 23:05:00+00', 50, 'verificado', 15000
);

-- Bloqueio mutuo registrado posteriormente (RF26)
insert into public.bloqueio (id, autor_id, bloqueado_id, criado_em)
values
  ((select bloq_ze_ana from ids), (select c_ze from ids), (select p_ana from ids), '2026-10-25 10:00:00+00');

grant select on ids to authenticated;

-- ── 3. Catalogo e anon ─────────────────────────────────────────────────────────

select has_table('public', 'turno', 'tabela public.turno existe');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.turno'::regclass),
  'RLS ativo em public.turno'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.turno') $$,
  '42501',
  null,
  'papel anon recebe 42501 em SELECT direto em public.turno'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public' and table_name = 'turno'),
  0,
  'anon nao possui grant em public.turno'
);

-- ── 4. Os dois lados leem o turno ──────────────────────────────────────────────

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  1,
  'membro do estabelecimento le o turno da casa'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  1,
  'profissional confirmada le o seu proprio turno'
);

-- ── 5. Preservacao Historica Pos-Bloqueio (RN26 / RF26) ────────────────────────

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  1,
  'pos-bloqueio: contratante continua lendo o historico do turno cumprido'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  1,
  'pos-bloqueio: profissional continua lendo o historico do seu turno cumprido'
);

-- ── 6. Lacuna Top 4: Candidato rejeitado da mesma vaga NAO le o turno ──────────

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  0,
  'candidato da mesma vaga recebe 0 linhas no turno de outra profissional (lacuna Top 4)'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    'select count(*)::int from public.turno'
  ),
  0,
  'candidato nao-confirmado le 0 turnos no sistema'
);

-- ── 7. Isolamento de Terceiros e Outros Estabelecimentos ────────────────────────

select is(
  pg_temp.contar_como(
    (select p_clara from ids),
    'select count(*)::int from public.turno'
  ),
  0,
  'profissional terceira sem vinculo le 0 turnos no sistema'
);

select is(
  pg_temp.contar_como(
    (select c_rita from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  0,
  'contratante de outro estabelecimento le 0 turnos da casa alheia'
);

select is(
  pg_temp.contar_como(
    null,
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  0,
  'sessao sem claims (auth.uid() nulo) le 0 turnos'
);

-- ── 8. Provas de Mutacao Real do Predicado USING ──────────────────────────────

-- Mutacao 1: Remocao total da politica fecha o acesso aos dois lados
drop policy turno_leitura on public.turno;

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  0,
  'mutante sem politica: contratante deixa de ler turnos da casa'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  0,
  'mutante sem politica: profissional deixa de ler seu proprio turno'
);

-- Mutacao 2: Bloqueio indevido na politica de turnos (quebraria a preservacao historica)
create policy turno_leitura on public.turno for select to authenticated
  using (
    privado.lado_da_posicao(posicao_id)
    and not privado.bloqueado_com_estabelecimento(
      (select auth.uid()),
      privado.estabelecimento_da_posicao(posicao_id)
    )
  );

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  0,
  'mutante com bloqueio indevido: profissional bloqueada perde indevidamente o historico'
);

-- Mutacao 3: Remocao do lado do profissional (apenas eh_membro)
drop policy turno_leitura on public.turno;
create policy turno_leitura on public.turno for select to authenticated
  using (privado.eh_membro(privado.estabelecimento_da_posicao(posicao_id)));

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  0,
  'mutante sem profissional: profissional confirmada nao le seu turno'
);

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  1,
  'mutante sem profissional: contratante ainda le o turno da casa'
);

-- Mutacao 4: Remocao do lado do estabelecimento (apenas profissional da posicao)
drop policy turno_leitura on public.turno;
create policy turno_leitura on public.turno for select to authenticated
  using (
    exists (
      select 1 from public.posicao p
       where p.id = posicao_id
         and p.profissional_id = (select privado.meu_profissional_id())
    )
  );

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  0,
  'mutante sem estabelecimento: contratante deixa de ler turnos da casa'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  1,
  'mutante sem estabelecimento: profissional ainda le seu turno'
);

-- Mutacao 5: Vazamento para outros candidatos da posicao que virou turno
drop policy turno_leitura on public.turno;
create policy turno_leitura on public.turno for select to authenticated
  using (
    privado.lado_da_posicao(posicao_id)
    or exists (
      select 1 from public.candidatura c
       where c.posicao_id = turno.posicao_id
         and c.profissional_id = (select privado.meu_profissional_id())
    )
  );

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  1,
  'mutante com vazamento para candidatos: comprova que candidato leria turno alheio'
);

-- Restauracao da politica canonica e verificacao final
drop policy turno_leitura on public.turno;
create policy turno_leitura on public.turno for select to authenticated
  using (privado.lado_da_posicao(posicao_id));

select is(
  pg_temp.contar_como(
    (select c_ze from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  1,
  'politica restaurada: contratante le novamente seu turno'
);

select is(
  pg_temp.contar_como(
    (select p_ana from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  1,
  'politica restaurada: profissional le novamente seu turno'
);

select is(
  pg_temp.contar_como(
    (select p_beto from ids),
    format('select count(*)::int from public.turno where id = %L', (select turno_ana from ids))
  ),
  0,
  'politica restaurada: candidato volta a ler 0 turnos'
);

select * from finish();
rollback;
