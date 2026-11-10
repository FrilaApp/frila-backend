-- 842_equipe_confianca_expurgo_e_sair.sql
--
-- Cobertura pgTAP para:
--   1. RPC public.sair_da_equipe(estabelecimento_id uuid)
--   2. privado.expurgar_equipe_confianca_inativa(p_anos, p_limite)
--   3. Integração com a rotina diária privado.executar_retencao_diaria()
--
-- Requisitos: RF18, RN16, UC11, LGPD art. 18. Contrato 0.2.72.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-06-01 12:00:00+00', true);

select plan(26);

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Estrutura, permissões e salvaguardas
-- ─────────────────────────────────────────────────────────────────────────────

select has_function('public', 'sair_da_equipe', array['uuid'],
  'public.sair_da_equipe(uuid) existe');

select is(
  (select prosecdef from pg_proc where proname = 'sair_da_equipe' and pronamespace = 'public'::regnamespace),
  true,
  'public.sair_da_equipe é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'sair_da_equipe' and pronamespace = 'public'::regnamespace) @> array['search_path=""'],
  true,
  'public.sair_da_equipe define search_path=""'
);

select ok(has_function_privilege('authenticated', 'public.sair_da_equipe(uuid)', 'execute'),
  'authenticated pode executar public.sair_da_equipe');

select ok(has_function_privilege('service_role', 'public.sair_da_equipe(uuid)', 'execute'),
  'service_role pode executar public.sair_da_equipe');

select ok(
  not has_function_privilege('anon', 'public.sair_da_equipe(uuid)', 'execute'),
  'anon NÃO pode executar public.sair_da_equipe'
);

select has_function('privado', 'expurgar_equipe_confianca_inativa', array['integer', 'integer'],
  'privado.expurgar_equipe_confianca_inativa(integer, integer) existe');

select is(
  (select prosecdef from pg_proc where proname = 'expurgar_equipe_confianca_inativa' and pronamespace = 'privado'::regnamespace),
  true,
  'privado.expurgar_equipe_confianca_inativa é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'expurgar_equipe_confianca_inativa' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'privado.expurgar_equipe_confianca_inativa define search_path=""'
);

select ok(
  not has_function_privilege('authenticated', 'privado.expurgar_equipe_confianca_inativa(integer, integer)', 'execute'),
  'authenticated NÃO pode executar privado.expurgar_equipe_confianca_inativa'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Massa de teste para sair_da_equipe
-- ─────────────────────────────────────────────────────────────────────────────

create temp table ids as
select
  'c8420000-0000-4000-8000-000000000001'::uuid as u_prof,
  'c8420000-0000-4000-8000-000000000002'::uuid as u_casa,
  'c8420000-0000-4000-8000-000000000003'::uuid as u_suspenso,
  'c8420000-0000-4000-8000-000000000011'::uuid as p_prof,
  'c8420000-0000-4000-8000-000000000013'::uuid as p_suspenso,
  'c8420000-0000-4000-8000-000000000021'::uuid as e_casa,
  'c8420000-0000-4000-8000-000000000022'::uuid as e_outra;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select u_prof, 'profissional'::public.perfil_conta, 'Prof 842', '+5561999998421',
       'prof842@test.invalid', '1992-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz, 'ativa'::public.estado_conta from ids
union all
select u_casa, 'contratante'::public.perfil_conta, 'Casa 842', '+5561999998422',
       'casa842@test.invalid', '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz, 'ativa'::public.estado_conta from ids
union all
select u_suspenso, 'profissional'::public.perfil_conta, 'Prof Suspenso 842', '+5561999998423',
       'suspenso842@test.invalid', '1990-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz, 'suspensa'::public.estado_conta from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select p_prof, u_prof, 'POINT(-47.8800 -15.7700)'::extensions.geography from ids
union all
select p_suspenso, u_suspenso, 'POINT(-47.8800 -15.7700)'::extensions.geography from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select e_casa, 'Bar 842', '80000000000842', 'food_service'::public.tipo_estabelecimento, 'Endereço 842',
       'POINT(-47.8800 -15.7700)'::extensions.geography from ids
union all
select e_outra, 'Restaurante 842', '80000000000843', 'food_service'::public.tipo_estabelecimento, 'Endereço Outro',
       'POINT(-47.8800 -15.7700)'::extensions.geography from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select u_casa, e_casa, 'administrador' from ids;

-- Vincula p_prof na equipe de e_casa
insert into public.equipe_confianca (estabelecimento_id, profissional_id, adicionado_em)
select e_casa, p_prof, '2026-10-01 10:00:00+00'::timestamptz from ids;

-- Helper para chamar como um usuário autenticado
create or replace function pg_temp.como_usuario(p_user_id uuid, p_sql text) returns jsonb
language plpgsql as $$
declare
  r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', p_user_id, 'role', 'authenticated')::text);
  execute p_sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

-- 401 quando chamado sem sessão
select throws_matching(
  $$ select public.sair_da_equipe('c8420000-0000-4000-8000-000000000021'::uuid) $$,
  'nao_autenticado',
  'sair_da_equipe: 401 quando sem sessão'
);

-- 403 quando chamado por contratante (não é profissional)
select throws_matching(
  format($$ select pg_temp.como_usuario(%L, 'select public.sair_da_equipe(''%s''::uuid)') $$,
         (select u_casa from ids), (select e_casa from ids)),
  'sem_permissao',
  'sair_da_equipe: 403 para contratante'
);

-- 403 quando conta suspensa
select throws_matching(
  format($$ select pg_temp.como_usuario(%L, 'select public.sair_da_equipe(''%s''::uuid)') $$,
         (select u_suspenso from ids), (select e_casa from ids)),
  'conta_suspensa',
  'sair_da_equipe: 403 para conta suspensa'
);

-- 422 quando estabelecimento_id é nulo
select throws_matching(
  format($$ select pg_temp.como_usuario(%L, 'select public.sair_da_equipe(null)') $$,
         (select u_prof from ids)),
  'campo_obrigatorio',
  'sair_da_equipe: 422 campo_obrigatorio quando estabelecimento_id é nulo'
);

-- 422 quando o profissional não faz parte da equipe daquele estabelecimento
select throws_matching(
  format($$ select pg_temp.como_usuario(%L, 'select public.sair_da_equipe(''%s''::uuid)') $$,
         (select u_prof from ids), (select e_outra from ids)),
  'campo_invalido',
  'sair_da_equipe: 422 campo_invalido quando não faz parte da equipe'
);

-- Sucesso (200): profissional sai voluntariamente da equipe
select is(
  (select pg_temp.como_usuario((select u_prof from ids),
          format('select public.sair_da_equipe(''%s''::uuid)', (select e_casa from ids)))),
  '{}'::jsonb,
  'sair_da_equipe: devolve objeto vazio no sucesso'
);

-- Confere remoção física da tabela equipe_confianca
select ok(
  not exists (
    select 1 from public.equipe_confianca
     where estabelecimento_id = (select e_casa from ids)
       and profissional_id = (select p_prof from ids)
  ),
  'sair_da_equipe: profissional foi removido de public.equipe_confianca'
);

-- Segunda chamada consecutiva: recusa 422 campo_invalido pois já não está na equipe
select throws_matching(
  format($$ select pg_temp.como_usuario(%L, 'select public.sair_da_equipe(''%s''::uuid)') $$,
         (select u_prof from ids), (select e_casa from ids)),
  'campo_invalido',
  'sair_da_equipe: segunda chamada recusa 422 campo_invalido'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Expurgo de 5 anos de inatividade da equipe de confiança
-- ─────────────────────────────────────────────────────────────────────────────

-- Cria 5 profissionais para o cenário de expurgo
create temp table profs_expurgo as
select
  i,
  gen_random_uuid() as u_id,
  gen_random_uuid() as p_id
from generate_series(1, 5) i;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select u_id, 'profissional'::public.perfil_conta, 'Prof Exp ' || i, '+556199998420' || i,
       'profexp' || i || '@test.invalid', '1992-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from profs_expurgo;

insert into public.profissional (id, usuario_id, ponto_base)
select p_id, u_id, 'POINT(-47.8800 -15.7700)'::extensions.geography
  from profs_expurgo;

-- Cenários de vínculo para e_casa:
-- p1: adicionado há 6 anos, último turno verificado há 6 anos -> EXPURGA
-- p2: adicionado há 6 anos, último turno verificado há 1 ano  -> PRESERVA
-- p3: adicionado há 6 anos, nenhum turno realizado           -> EXPURGA
-- p4: adicionado há 2 anos, nenhum turno realizado           -> PRESERVA (< 5 anos)
-- p5: adicionado há 6 anos, turno recente há 1 ano mas NÃO VERIFICADO -> EXPURGA
insert into public.equipe_confianca (estabelecimento_id, profissional_id, adicionado_em)
select (select e_casa from ids), (select p_id from profs_expurgo where i = 1), '2021-01-01 10:00:00+00'::timestamptz union all
select (select e_casa from ids), (select p_id from profs_expurgo where i = 2), '2021-01-01 10:00:00+00'::timestamptz union all
select (select e_casa from ids), (select p_id from profs_expurgo where i = 3), '2021-01-01 10:00:00+00'::timestamptz union all
select (select e_casa from ids), (select p_id from profs_expurgo where i = 4), '2025-06-01 10:00:00+00'::timestamptz union all
select (select e_casa from ids), (select p_id from profs_expurgo where i = 5), '2021-01-01 10:00:00+00'::timestamptz;

-- Helper para inserir turno
create function pg_temp.criar_turno(
  p_prof uuid,
  p_fim timestamptz,
  p_verificacao public.verificacao_turno
) returns void language plpgsql as $$
declare
  v_vaga uuid := gen_random_uuid();
  v_pos  uuid := gen_random_uuid();
  v_funcao uuid := (select id from public.funcao limit 1);
begin
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
  ) values (
    v_vaga, (select e_casa from ids), v_funcao, p_fim - interval '6 hours', p_fim, 'Local Teste',
    'POINT(-47.8800 -15.7700)'::extensions.geography, 12000, 1, false, false, false,
    'Chefe', 'urgencia'::public.modo_preenchimento, 'encerrada'::public.estado_vaga, p_fim - interval '1 day',
    gen_random_uuid(), (select u_casa from ids)
  );

  insert into public.posicao (
    id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em
  ) values (
    v_pos, v_vaga, 'cumprida'::public.estado_posicao, p_prof, p_fim - interval '7 hours', false,
    p_fim - interval '6 hours', p_fim
  );

  if p_verificacao = 'verificado' then
    insert into public.turno (
      id, posicao_id, verificacao, valor_acordado_centavos, checkin_tipo, checkin_distancia_m, checkin_em, checkout_em
    ) values (
      gen_random_uuid(), v_pos, 'verificado', 12000, 'geolocalizado', 50, p_fim - interval '6 hours', p_fim
    );
  else
    insert into public.turno (
      id, posicao_id, verificacao, valor_acordado_centavos, checkout_em
    ) values (
      gen_random_uuid(), v_pos, p_verificacao, 12000, p_fim
    );
  end if;
end $$;

-- p1 teve turno verificado há 6 anos (2021)
select pg_temp.criar_turno((select p_id from profs_expurgo where i = 1), '2021-02-01 18:00:00+00'::timestamptz, 'verificado');

-- p2 teve turno verificado recente há 1 ano (2026-06-01)
select pg_temp.criar_turno((select p_id from profs_expurgo where i = 2), '2026-06-01 18:00:00+00'::timestamptz, 'verificado');

-- p5 teve turno recente há 1 ano (2026-06-01) mas NAO VERIFICADO
select pg_temp.criar_turno((select p_id from profs_expurgo where i = 5), '2026-06-01 18:00:00+00'::timestamptz, 'nao_verificado');

-- Executa o expurgo com 5 anos (padrão)
select is(
  privado.expurgar_equipe_confianca_inativa(5),
  3,
  'expurgar_equipe_confianca_inativa: removeu exatamente as 3 ligações inativas (p1, p3, p5)'
);

-- Confere que p1 saiu
select ok(
  not exists (select 1 from public.equipe_confianca where profissional_id = (select p_id from profs_expurgo where i = 1)),
  'p1 (turno > 5 anos) foi expurgado da equipe'
);

-- Confere que p2 ficou
select ok(
  exists (select 1 from public.equipe_confianca where profissional_id = (select p_id from profs_expurgo where i = 2)),
  'p2 (turno recente < 5 anos) foi preservado na equipe'
);

-- Confere que p3 saiu
select ok(
  not exists (select 1 from public.equipe_confianca where profissional_id = (select p_id from profs_expurgo where i = 3)),
  'p3 (inclusão > 5 anos sem turnos) foi expurgado da equipe'
);

-- Confere que p4 ficou
select ok(
  exists (select 1 from public.equipe_confianca where profissional_id = (select p_id from profs_expurgo where i = 4)),
  'p4 (inclusão recente < 5 anos) foi preservado na equipe'
);

-- Confere que p5 saiu
select ok(
  not exists (select 1 from public.equipe_confianca where profissional_id = (select p_id from profs_expurgo where i = 5)),
  'p5 (sem turno verificado nos últimos 5 anos) foi expurgado da equipe'
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Integração na rotina consolidada executar_retencao_diaria
-- ─────────────────────────────────────────────────────────────────────────────

create temp table res_retencao as select privado.executar_retencao_diaria() as r;

select is(
  (select r->'falhas' from res_retencao),
  '[]'::jsonb,
  'executar_retencao_diaria roda sem nenhuma falha'
);

select ok(
  (select r ? 'expurgo_equipe_confianca' from res_retencao),
  'executar_retencao_diaria inclui a chave expurgo_equipe_confianca no retorno jsonb'
);

select * from finish();
rollback;
