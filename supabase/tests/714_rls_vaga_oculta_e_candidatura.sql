-- 714_rls_vaga_oculta_e_candidatura.sql
--
-- Cobertura de Row Level Security (RLS) para public.vaga (politica vaga_leitura):
--   1. Vaga Ocultada (privado.vaga_oculta(id)):
--      - Vaga publicada mas presente em privado.vaga_ocultada (Diretriz 1.2 / moderação)
--        some do SELECT direto para profissionais sem vínculo;
--      - O estabelecimento criador da vaga continua conseguindo ler a vaga ocultada;
--      - Profissional que já possui candidatura na vaga continua conseguindo lê-la
--        (privado.candidatou_na_vaga(id)).
--   2. Vaga Encerrada:
--      - Profissional que candidatou-se lê a vaga encerrada;
--      - Profissional sem candidatura não lê a vaga encerrada (0 linhas).
--   3. Papel anon:
--      - SELECT direto em public.vaga levanta 42501 (permissão negada).
--   4. Prova de mutação:
--      - Remoção da política fecha o acesso legítimo do contratante da casa.

begin;
select plan(16);

insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-25 12:00:00+00';
set local frila.agendador_secret = 'teste-segredo-714';

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

-- ── 2. Cenário Hermético ───────────────────────────────────────────────────────

create temp table ids as select
  '71400000-0000-4000-8000-000000000001'::uuid as c_ze,       -- contratante dono da casa
  '71400000-0000-4000-8000-000000000002'::uuid as c_rita,     -- contratante outro estab
  '71400000-0000-4000-8000-000000000003'::uuid as p_ana,      -- profissional candidata
  '71400000-0000-4000-8000-000000000004'::uuid as p_beto,     -- profissional terceiro
  '71400000-0000-4000-8000-000000000013'::uuid as prof_ana,   -- perfil Ana
  '71400000-0000-4000-8000-000000000014'::uuid as prof_beto,  -- perfil Beto
  '71400000-0000-4000-8000-000000000010'::uuid as estab_ze,   -- bar do Zé
  '71400000-0000-4000-8000-000000000011'::uuid as estab_rita, -- buffet da Rita
  '71400000-0000-4000-8000-000000000020'::uuid as fn_garcom,  -- função
  '71400000-0000-4000-8000-000000000031'::uuid as vaga_1,     -- vaga teste
  '71400000-0000-4000-8000-000000000041'::uuid as pos_1,      -- posicao teste
  '71400000-0000-4000-8000-000000000051'::uuid as cand_1;     -- candidatura teste

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', id_val, 'authenticated', 'authenticated',
       email_val, '2026-10-25 12:00:00+00', '{"provider":"email"}', '{}',
       '2026-10-25 12:00:00+00', '2026-10-25 12:00:00+00', false, false
from (values
  ((select c_ze from ids),   'ze.714@test.com'),
  ((select c_rita from ids), 'rita.714@test.com'),
  ((select p_ana from ids),  'ana.714@test.com'),
  ((select p_beto from ids), 'beto.714@test.com')
) as u(id_val, email_val);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values
  ((select c_ze from ids),   'contratante',  'Zé Bar',         '+5561997140001', 'ze.714@test.com',   '1980-01-01', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select c_rita from ids), 'contratante',  'Rita Buffet',    '+5561997140002', 'rita.714@test.com', '1982-02-02', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_ana from ids),  'profissional', 'Ana Garçonete',  '+5561997140003', 'ana.714@test.com',  '1995-03-03', '2026-09-22', '2026-10-25 12:00:00+00'),
  ((select p_beto from ids), 'profissional', 'Beto Garçom',    '+5561997140004', 'beto.714@test.com', '1996-04-04', '2026-09-22', '2026-10-25 12:00:00+00');

insert into public.profissional (id, usuario_id, ponto_base)
values
  ((select prof_ana from ids),  (select p_ana from ids),  'POINT(-47.8820 -15.7940)'::extensions.geography),
  ((select prof_beto from ids), (select p_beto from ids), 'POINT(-47.8830 -15.7950)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values
  ((select estab_ze from ids),   'Bar do Zé 714',   '94827104000199', 'food_service', 'CLN 102', 'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto'),
  ((select estab_rita from ids), 'Buffet Rita 714', '94827104000188', 'evento',       'SIA 3',   'POINT(-47.89 -15.80)'::extensions.geography, 'SIA');

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
  (select vaga_1 from ids), (select estab_ze from ids), (select fn_garcom from ids),
  '2026-10-27 18:00:00+00', '2026-10-27 23:00:00+00', 'Salão do Zé',
  'POINT(-47.88 -15.79)'::extensions.geography, 15000, 1, true, false, false,
  'Seu Zé', 'urgencia', 'publicada',
  gen_random_uuid(), (select c_ze from ids), '2026-10-25 12:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado)
values ((select pos_1 from ids), (select vaga_1 from ids), '2026-10-27 18:00:00+00', '2026-10-27 23:00:00+00', 'aberta');

-- ── 3. Estrutura e anon ────────────────────────────────────────────────────────

select has_table('public', 'vaga', 'tabela public.vaga existe');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.vaga'::regclass),
  'RLS ativo em public.vaga'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.vaga') $$,
  '42501',
  null,
  'papel anon recebe 42501 em SELECT direto em public.vaga'
);

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public' and table_name = 'vaga'),
  0,
  'papel anon possui zero privilégios concedidos em public.vaga'
);

-- ── 4. Vaga Publicada Normal ───────────────────────────────────────────────────

select is(
  pg_temp.contar_como((select p_beto from ids),
    format('select count(*)::int from public.vaga where id = %L', (select vaga_1 from ids))),
  1,
  'positivo: profissional lê vaga publicada e visível'
);

select is(
  pg_temp.contar_como((select c_ze from ids),
    format('select count(*)::int from public.vaga where id = %L', (select vaga_1 from ids))),
  1,
  'positivo: contratante dono da casa lê vaga publicada'
);

-- ── 5. Vaga Ocultada por Moderação (privado.vaga_ocultada) ─────────────────────

insert into public.ocorrencia (id, tipo, autor_id, motivo, criada_em)
values ('71400000-0000-4000-8000-000000000099', 'suporte', (select c_ze from ids),
        'Ocultacao preventiva por moderacao', '2026-10-25 12:05:00+00');

insert into privado.vaga_ocultada (vaga_id, ocorrencia_id, oculta_em)
values ((select vaga_1 from ids), '71400000-0000-4000-8000-000000000099', '2026-10-25 12:10:00+00');

select is(
  privado.vaga_oculta((select vaga_1 from ids)),
  true,
  'função privado.vaga_oculta retorna true para a vaga'
);

select is(
  pg_temp.contar_como((select p_beto from ids),
    format('select count(*)::int from public.vaga where id = %L', (select vaga_1 from ids))),
  0,
  'negativo: profissional comum recebe 0 linhas para vaga com status oculta'
);

select is(
  pg_temp.contar_como((select c_ze from ids),
    format('select count(*)::int from public.vaga where id = %L', (select vaga_1 from ids))),
  1,
  'positivo: contratante da casa continua lendo a vaga mesmo estando ocultada'
);

-- ── 6. Vaga Ocultada com Candidatura (privado.candidatou_na_vaga) ──────────────

insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado)
values ((select cand_1 from ids), (select pos_1 from ids), (select prof_ana from ids), '2026-10-25 12:05:00+00', 'pendente');

select is(
  privado.candidatou_na_vaga((select vaga_1 from ids)),
  false,
  'privado.candidatou_na_vaga executada como superuser retorna false (sem session auth)'
);

select is(
  pg_temp.contar_como((select p_ana from ids),
    format('select count(*)::int from public.vaga where id = %L', (select vaga_1 from ids))),
  1,
  'positivo: profissional que se candidatou LÊ a vaga mesmo estando ocultada'
);

-- ── 7. Vaga Encerrada: Candidato vs Não-Candidato ──────────────────────────────

delete from privado.vaga_ocultada where vaga_id = (select vaga_1 from ids);
update public.vaga set estado = 'encerrada' where id = (select vaga_1 from ids);

select is(
  pg_temp.contar_como((select p_ana from ids),
    format('select count(*)::int from public.vaga where id = %L', (select vaga_1 from ids))),
  1,
  'positivo: profissional candidata lê a vaga que transitou para encerrada'
);

select is(
  pg_temp.contar_como((select p_beto from ids),
    format('select count(*)::int from public.vaga where id = %L', (select vaga_1 from ids))),
  0,
  'negativo: profissional não-candidato recebe 0 linhas para a vaga encerrada'
);

select is(
  pg_temp.contar_como((select c_rita from ids),
    format('select count(*)::int from public.vaga where id = %L', (select vaga_1 from ids))),
  0,
  'negativo: contratante de outro estabelecimento não lê vaga da outra casa'
);

select is(
  pg_temp.contar_como(null,
    format('select count(*)::int from public.vaga where id = %L', (select vaga_1 from ids))),
  0,
  'negativo: sessão sem claims (auth.uid() nulo) recebe 0 linhas'
);

-- ── 8. Prova de Mutação: Remoção de Política Fecha Acesso ──────────────────────

drop policy vaga_leitura on public.vaga;

select is(
  pg_temp.contar_como((select c_ze from ids),
    format('select count(*)::int from public.vaga where id = %L', (select vaga_1 from ids))),
  0,
  'prova de mutação: sem a política vaga_leitura, o acesso legítimo do contratante fecha (0 linhas)'
);

create policy vaga_leitura on public.vaga for select to authenticated
  using (
    privado.mesma_populacao(publicado_por)
    and (
          privado.eh_membro(estabelecimento_id)
       or ((select privado.perfil_da_conta()) = 'profissional'
           and (   privado.ocupa_posicao_na_vaga(id)
                or (not privado.bloqueado_com_estabelecimento(
                          (select auth.uid()), estabelecimento_id)
                    and ((estado = 'publicada' and not privado.vaga_oculta(id))
                         or privado.candidatou_na_vaga(id)))))));

select * from finish();
rollback;
