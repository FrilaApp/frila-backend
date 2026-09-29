-- 490_funil_piloto.sql
-- Prova de acesso e números do funil do piloto (Cartão 1MK1CGyF, T-0017, T-0020).
--
-- Critérios cobertos:
-- 1. Schema `metrica` e views sem acesso de `anon` e `authenticated` (só `service_role`).
-- 2. Tabela `privado.conta_equipe` sem acesso de `anon` e `authenticated` (só `service_role`).
-- 3. Números do funil sobre o seed (cenários):
--    - Vagas publicadas, notificações, candidaturas, confirmações, check-ins e avaliações.
--    - Tempo mediano entre publicação e confirmação.
--    - Consistência por dia e por estabelecimento.
-- 4. Exclusão de contas de demonstração (usuario.demonstracao = true) de todos os cálculos.
-- 5. Exclusão de contas da equipe (privado.conta_equipe) de todos os cálculos.
-- 6. Contabilização correta de notificações enviadas.

begin;
select plan(43);

create function pg_temp.como(papel text, sql text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
end $$;

-- ── 1. Permissões de Acesso ao Schema metrica ────────────────────────────────
-- anon e authenticated não podem acessar o schema metrica nem as views.

select throws_ok(
  $$ select pg_temp.como('anon', 'select * from metrica.funil_por_dia') $$,
  '42501',
  null,
  'anon não pode consultar metrica.funil_por_dia'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select * from metrica.funil_por_estabelecimento') $$,
  '42501',
  null,
  'anon não pode consultar metrica.funil_por_estabelecimento'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select * from metrica.funil_geral') $$,
  '42501',
  null,
  'anon não pode consultar metrica.funil_geral'
);

select throws_ok(
  $$ select pg_temp.como('authenticated', 'select * from metrica.funil_por_dia') $$,
  '42501',
  null,
  'authenticated não pode consultar metrica.funil_por_dia'
);

select throws_ok(
  $$ select pg_temp.como('authenticated', 'select * from metrica.funil_por_estabelecimento') $$,
  '42501',
  null,
  'authenticated não pode consultar metrica.funil_por_estabelecimento'
);

select throws_ok(
  $$ select pg_temp.como('authenticated', 'select * from metrica.funil_geral') $$,
  '42501',
  null,
  'authenticated não pode consultar metrica.funil_geral'
);

select lives_ok(
  $$ select pg_temp.como('service_role', 'select count(*) from metrica.funil_por_dia') $$,
  'service_role pode consultar metrica.funil_por_dia'
);

select lives_ok(
  $$ select pg_temp.como('service_role', 'select count(*) from metrica.funil_por_estabelecimento') $$,
  'service_role pode consultar metrica.funil_por_estabelecimento'
);

select lives_ok(
  $$ select pg_temp.como('service_role', 'select count(*) from metrica.funil_geral') $$,
  'service_role pode consultar metrica.funil_geral'
);

-- ── 2. Permissões de Acesso à Tabela privado.conta_equipe ────────────────────
select throws_ok(
  $$ select pg_temp.como('anon', 'select * from privado.conta_equipe') $$,
  '42501',
  null,
  'anon não pode consultar privado.conta_equipe'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'insert into privado.conta_equipe (usuario_id) values (gen_random_uuid())') $$,
  '42501',
  null,
  'anon não pode inserir em privado.conta_equipe'
);

select throws_ok(
  $$ select pg_temp.como('authenticated', 'select * from privado.conta_equipe') $$,
  '42501',
  null,
  'authenticated não pode consultar privado.conta_equipe'
);

select throws_ok(
  $$ select pg_temp.como('authenticated', 'insert into privado.conta_equipe (usuario_id) values (gen_random_uuid())') $$,
  '42501',
  null,
  'authenticated não pode inserir em privado.conta_equipe'
);

select lives_ok(
  $$ select pg_temp.como('service_role', 'select count(*) from privado.conta_equipe') $$,
  'service_role pode consultar privado.conta_equipe'
);

-- ── 3. Números sobre o Seed (cenarios.sql) ──────────────────────────────────
-- Resumo Geral sobre os estabelecimentos semeados
select cmp_ok(
  (select vagas_publicadas from metrica.funil_geral),
  '>=',
  8::bigint,
  'funil geral: pelo menos 8 vagas publicadas semeadas'
);

select cmp_ok(
  (select candidaturas from metrica.funil_geral),
  '>=',
  5::bigint,
  'funil geral: pelo menos 5 candidaturas semeadas'
);

select cmp_ok(
  (select confirmacoes from metrica.funil_geral),
  '>=',
  9::bigint,
  'funil geral: pelo menos 9 posições confirmadas'
);

select cmp_ok(
  (select checkins from metrica.funil_geral),
  '>=',
  5::bigint,
  'funil geral: pelo menos 5 check-ins registrados'
);

select cmp_ok(
  (select avaliacoes from metrica.funil_geral),
  '>=',
  6::bigint,
  'funil geral: pelo menos 6 avaliações registradas'
);

select ok(
  (select tempo_mediano_confirmacao is not null from metrica.funil_geral),
  'funil geral: tempo mediano de confirmação foi calculado'
);

-- Soma das 3 casas semeadas tem exatamente 8 vagas
select is(
  (select sum(vagas_publicadas)::bigint from metrica.funil_por_estabelecimento
    where estabelecimento_id in (
      'c0000000-0000-4000-8000-000000000001'::uuid,
      'c0000000-0000-4000-8000-000000000002'::uuid,
      'c0000000-0000-4000-8000-000000000003'::uuid
    )),
  8::bigint,
  'soma dos 3 estabelecimentos de cenário totaliza 8 vagas'
);

-- ── 4. Funil por Estabelecimento sobre o Seed ────────────────────────────────
-- Bar do Cerrado
select is(
  (select vagas_publicadas from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'::uuid),
  3::bigint,
  'Bar do Cerrado: 3 vagas publicadas (d01, d02, d07)'
);

select is(
  (select candidaturas from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'::uuid),
  3::bigint,
  'Bar do Cerrado: 3 candidaturas'
);

select is(
  (select confirmacoes from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'::uuid),
  2::bigint,
  'Bar do Cerrado: 2 confirmações'
);

select is(
  (select checkins from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'::uuid),
  1::bigint,
  'Bar do Cerrado: 1 check-in realizado'
);

select is(
  (select avaliacoes from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'::uuid),
  2::bigint,
  'Bar do Cerrado: 2 avaliações (mútuas)'
);

-- Buffet Águas Claras
select is(
  (select vagas_publicadas from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000002'::uuid),
  3::bigint,
  'Buffet Águas Claras: 3 vagas publicadas (d03, d06, d08)'
);

select is(
  (select confirmacoes from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000002'::uuid),
  7::bigint,
  'Buffet Águas Claras: 7 confirmações'
);

select is(
  (select checkins from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000002'::uuid),
  4::bigint,
  'Buffet Águas Claras: 4 check-ins'
);

select is(
  (select avaliacoes from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000002'::uuid),
  4::bigint,
  'Buffet Águas Claras: 4 avaliações'
);

-- Empório Lago Sul
select is(
  (select vagas_publicadas from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000003'::uuid),
  2::bigint,
  'Empório Lago Sul: 2 vagas publicadas (d04, d05)'
);

select is(
  (select candidaturas from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000003'::uuid),
  2::bigint,
  'Empório Lago Sul: 2 candidaturas (d05)'
);

-- ── 5. Funil por Dia: Consistência ───────────────────────────────────────────
select is(
  (select sum(vagas_publicadas)::bigint from metrica.funil_por_dia),
  (select vagas_publicadas from metrica.funil_geral),
  'funil por dia: soma das vagas publicadas bate com total geral'
);

select is(
  (select sum(candidaturas)::bigint from metrica.funil_por_dia),
  (select candidaturas from metrica.funil_geral),
  'funil por dia: soma das candidaturas bate com total geral'
);

-- ── 6. Exclusão de Contas de Demonstração ─────────────────────────────────────
-- Cria uma conta de demonstração, publica uma vaga e verifica que os números do funil
-- permanecem inalterados.
do $$
declare
  v_vagas_antes bigint := (select vagas_publicadas from metrica.funil_geral);
  v_demo_user uuid := gen_random_uuid();
  v_demo_estab uuid := gen_random_uuid();
  v_demo_vaga uuid := gen_random_uuid();
  v_funcao uuid;
begin
  select id into v_funcao from public.funcao limit 1;

  -- Cria usuário de demonstração
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
  values (v_demo_user, 'contratante', 'Demo Contratante', '+5561999990099', 'demo_contratante@frila.test', '1990-01-01', '2026-09-22', now(), true);

  -- Cria estabelecimento do usuário de demonstração
  insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
  values (v_demo_estab, 'Restaurante Demo', '09123456000999', 'food_service', 'Endereço Demo', 'POINT(-47.8869 -15.7620)'::extensions.geography);

  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values (v_demo_user, v_demo_estab, 'administrador');

  -- Publica vaga de demonstração
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em,
    chave_cliente, publicado_por
  ) values (
    v_demo_vaga, v_demo_estab, v_funcao, now() + interval '2 days', now() + interval '2 days 8 hours',
    'Local Demo', 'POINT(-47.8869 -15.7620)'::extensions.geography,
    15000, 1, false, false, false, 'Gerente Demo', 'urgencia', 'publicada',
    now(), gen_random_uuid(), v_demo_user
  );

  perform set_config('frila.teste_vagas_antes', v_vagas_antes::text, true);
end $$;

select is(
  (select vagas_publicadas from metrica.funil_geral),
  current_setting('frila.teste_vagas_antes')::bigint,
  'vaga de demonstração é excluída do funil geral'
);

select ok(
  not exists (
    select 1 from metrica.funil_por_estabelecimento where estabelecimento_nome = 'Restaurante Demo'
  ),
  'estabelecimento de demonstração é excluído do funil por estabelecimento'
);

-- ── 7. Exclusão de Contas da Equipe (privado.conta_equipe) ───────────────────
do $$
declare
  v_vagas_antes bigint := (select vagas_publicadas from metrica.funil_geral);
  v_equipe_user uuid := gen_random_uuid();
  v_equipe_estab uuid := gen_random_uuid();
  v_equipe_vaga uuid := gen_random_uuid();
  v_equipe_prof_usr uuid := gen_random_uuid();
  v_equipe_prof uuid := gen_random_uuid();
  v_funcao uuid;
begin
  select id into v_funcao from public.funcao limit 1;

  -- 1. Cria usuário contratante e marca como conta_equipe
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_equipe_user, 'contratante', 'Membro Equipe', '+5561999990077', 'equipe_admin@frila.test', '1990-01-01', '2026-09-22', now());

  insert into privado.conta_equipe (usuario_id) values (v_equipe_user);

  insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
  values (v_equipe_estab, 'Bar da Equipe Frila', '09123456000777', 'food_service', 'Endereço Equipe', 'POINT(-47.8869 -15.7620)'::extensions.geography);

  insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
  values (v_equipe_user, v_equipe_estab, 'administrador');

  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em,
    chave_cliente, publicado_por
  ) values (
    v_equipe_vaga, v_equipe_estab, v_funcao, now() + interval '3 days', now() + interval '3 days 8 hours',
    'Local Equipe', 'POINT(-47.8869 -15.7620)'::extensions.geography,
    15000, 1, false, false, false, 'Gerente Equipe', 'urgencia', 'publicada',
    now(), gen_random_uuid(), v_equipe_user
  );

  -- 2. Cria profissional da equipe e candidata na vaga d01 do Bar do Cerrado
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_equipe_prof_usr, 'profissional', 'Profissional Equipe', '+5561999990066', 'equipe_prof@frila.test', '1992-01-01', '2026-09-22', now());

  insert into privado.conta_equipe (usuario_id) values (v_equipe_prof_usr);

  insert into public.profissional (id, usuario_id, ponto_base)
  values (v_equipe_prof, v_equipe_prof_usr, 'POINT(-47.8869 -15.7620)'::extensions.geography);

  insert into public.candidatura (posicao_id, profissional_id, estado, criada_em)
  values ('f1000000-0000-4000-8000-000000000101'::uuid, v_equipe_prof, 'pendente', now());

  perform set_config('frila.teste_equipe_vagas_antes', v_vagas_antes::text, true);
end $$;

select is(
  (select vagas_publicadas from metrica.funil_geral),
  current_setting('frila.teste_equipe_vagas_antes')::bigint,
  'vaga da equipe Frila é excluída do funil geral'
);

select ok(
  not exists (
    select 1 from metrica.funil_por_estabelecimento where estabelecimento_nome = 'Bar da Equipe Frila'
  ),
  'estabelecimento da equipe Frila é excluído do funil por estabelecimento'
);

select is(
  (select candidaturas from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'::uuid),
  3::bigint,
  'candidatura de membro da equipe é ignorada no funil do Bar do Cerrado'
);

-- ── 8. Incremento de Notificações e Isolamento de Candidatura Demo ────────────
do $$
declare
  v_vaga_id uuid := 'd0000000-0000-4000-8000-000000000001'::uuid; -- Bar do Cerrado
  v_pos_id  uuid := 'f1000000-0000-4000-8000-000000000101'::uuid;
  v_ana_usr uuid := 'a0000000-0000-4000-8000-000000000001'::uuid;
  v_ana_prof uuid := 'e0000000-0000-4000-8000-000000000001'::uuid;
  v_notif_id uuid := gen_random_uuid();
  v_demo_prof_usr uuid := gen_random_uuid();
  v_demo_prof uuid := gen_random_uuid();
  v_notif_antes bigint := (select notificacoes_enviadas from metrica.funil_geral);
  v_notif_bar_antes bigint := (select notificacoes_enviadas from metrica.funil_por_estabelecimento
                                where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'::uuid);
  v_cand_bar_antes bigint := (select candidaturas from metrica.funil_por_estabelecimento
                               where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'::uuid);
begin
  -- 1. Insere notificação real para a Ana sobre a vaga d01
  insert into public.notificacao (id, usuario_id, profissional_id, tipo, referencia_id, enviada_em, rodada)
  values (v_notif_id, v_ana_usr, v_ana_prof, 'vaga', v_vaga_id, now(), 1);

  insert into public.despacho (vaga_id, profissional_id, notificacao_id, criado_em, rodada)
  values (v_vaga_id, v_ana_prof, v_notif_id, now(), 1);

  -- 2. Cria profissional de demonstração e candidatura de demonstração na d01
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
  values (v_demo_prof_usr, 'profissional', 'Profissional Demo', '+5561999990088', 'demo_prof@frila.test', '1995-01-01', '2026-09-22', now(), true);

  insert into public.profissional (id, usuario_id, ponto_base)
  values (v_demo_prof, v_demo_prof_usr, 'POINT(-47.8869 -15.7620)'::extensions.geography);

  insert into public.candidatura (posicao_id, profissional_id, estado, criada_em)
  values (v_pos_id, v_demo_prof, 'pendente', now());

  perform set_config('frila.teste_notif_antes', v_notif_antes::text, true);
  perform set_config('frila.teste_notif_bar_antes', v_notif_bar_antes::text, true);
  perform set_config('frila.teste_cand_bar_antes', v_cand_bar_antes::text, true);
end $$;

select is(
  (select notificacoes_enviadas from metrica.funil_geral),
  current_setting('frila.teste_notif_antes')::bigint + 1::bigint,
  'notificação real incrementa o funil geral'
);

select is(
  (select notificacoes_enviadas from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'::uuid),
  current_setting('frila.teste_notif_bar_antes')::bigint + 1::bigint,
  'notificação real incrementa o funil do Bar do Cerrado'
);

select is(
  (select candidaturas from metrica.funil_por_estabelecimento
    where estabelecimento_id = 'c0000000-0000-4000-8000-000000000001'::uuid),
  current_setting('frila.teste_cand_bar_antes')::bigint,
  'candidatura de profissional demo é ignorada no funil do Bar do Cerrado'
);

select is(
  (select candidaturas from metrica.funil_por_dia
    where dia = (select dia from metrica.funil_por_vaga where vaga_id = 'd0000000-0000-4000-8000-000000000001'::uuid)),
  current_setting('frila.teste_cand_bar_antes')::bigint,
  'candidatura de profissional demo é ignorada no funil por dia'
);

rollback;
