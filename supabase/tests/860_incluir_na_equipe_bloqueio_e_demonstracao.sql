-- 860_incluir_na_equipe_bloqueio_e_demonstracao.sql
--
-- Cobertura de integridade para public.incluir_na_equipe:
-- D-14 / RF26: bloqueio mútuo e separação estrita de contas de demonstração.
--
-- Cenários obrigatórios cobertos:
--   1. Caminho feliz nominal: profissional real cumpriu turno verificado na casa e não possui bloqueio mútuo -> 200 MembroDaEquipe.
--   2. Idempotência do caminho feliz: re-execução devolve o mesmo payload sem duplicar nem falhar -> 200 MembroDaEquipe.
--   3. Bloqueio sentido A -> B: contratante (administrador da casa) bloqueou o profissional -> recusa fechada com 404 nao_encontrado (RF26).
--   4. Bloqueio sentido B -> A: profissional bloqueou o contratante da casa -> recusa fechada com 404 nao_encontrado (RF26).
--   5. Bloqueio por outro membro: outro membro da casa bloqueou o profissional -> recusa fechada com 404 nao_encontrado (RF26).
--   6. Isolamento de demonstração (chamador real x profissional demo): contratante real tentando incluir profissional demo -> 404 nao_encontrado.
--   7. Isolamento de demonstração (chamador demo x profissional real): contratante demo tentando incluir profissional real -> 404 nao_encontrado.
--   8. Caminho feliz no domínio de demonstração: contratante demo incluindo profissional demo sem bloqueio -> 200 MembroDaEquipe.
--   9. Preservação de guardas anteriores:
--      - Não autenticado -> 401 nao_autenticado
--      - Perfil não-contratante -> 422 perfil_incompativel
--      - Operador do estabelecimento -> 403 sem_permissao
--      - Administrador de outro estabelecimento -> 403 sem_permissao
--      - Profissional sem turno verificado -> 403 sem_turno_cumprido
--      - Profissional inexistente -> 404 nao_encontrado

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-14 12:00:00-03';

select plan(21);

-- ── 1. Estrutura e Privilégios da Função ───────────────────────────────────────

select function_lang_is(
  'public', 'incluir_na_equipe', array['uuid', 'uuid'],
  'plpgsql', 'public.incluir_na_equipe é escrita em plpgsql'
);

select ok(
  has_function_privilege('authenticated', 'public.incluir_na_equipe(uuid, uuid)', 'execute'),
  'authenticated possui privilégio de execução em public.incluir_na_equipe'
);

select ok(
  not has_function_privilege('anon', 'public.incluir_na_equipe(uuid, uuid)', 'execute'),
  'anon NÃO possui privilégio de execução em public.incluir_na_equipe'
);

select is(
  (select prosecdef from pg_proc where proname = 'incluir_na_equipe' and pronamespace = 'public'::regnamespace),
  true, 'public.incluir_na_equipe é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'incluir_na_equipe' and pronamespace = 'public'::regnamespace) @> array['search_path=""'],
  true, 'public.incluir_na_equipe possui search_path="" fixado'
);

-- ── 2. Funções auxiliares temporárias de JWT e teste ──────────────────────────

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local "request.jwt.claims" = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute format('set local "request.jwt.claim.sub" = %L', conta::text);
  execute sql into r;
  reset role;
  execute 'reset "request.jwt.claims"';
  execute 'reset "request.jwt.claim.sub"';
  return r;
end $$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

-- ── 3. Massa de dados ─────────────────────────────────────────────────────────

create temp table ids as
select
  -- Contratante Real e Estabelecimento
  '86000000-0000-4000-8000-000000000001'::uuid as user_dono,
  '86000000-0000-4000-8000-000000000002'::uuid as user_gerente,
  '86000000-0000-4000-8000-000000000003'::uuid as user_operador,
  '86000000-0000-4000-8000-000000000010'::uuid as estab_real,
  '86000000-0000-4000-8000-000000000020'::uuid as estab_outro,
  '86000000-0000-4000-8000-000000000021'::uuid as user_dono_outro,

  -- Contratante Demo e Estabelecimento Demo
  '86000000-0000-4000-8000-000000000050'::uuid as user_dono_demo,
  '86000000-0000-4000-8000-000000000051'::uuid as estab_demo,

  -- Profissionais
  '86000000-0000-4000-8000-000000000101'::uuid as user_prof_feliz,
  '86000000-0000-4000-8000-000000000102'::uuid as prof_feliz,

  '86000000-0000-4000-8000-000000000201'::uuid as user_prof_bloq_casa,
  '86000000-0000-4000-8000-000000000202'::uuid as prof_bloq_casa,

  '86000000-0000-4000-8000-000000000301'::uuid as user_prof_bloqueou_dono,
  '86000000-0000-4000-8000-000000000302'::uuid as prof_bloqueou_dono,

  '86000000-0000-4000-8000-000000000401'::uuid as user_prof_bloq_gerente,
  '86000000-0000-4000-8000-000000000402'::uuid as prof_bloq_gerente,

  '86000000-0000-4000-8000-000000000501'::uuid as user_prof_demo,
  '86000000-0000-4000-8000-000000000502'::uuid as prof_demo,

  '86000000-0000-4000-8000-000000000601'::uuid as user_prof_sem_turno,
  '86000000-0000-4000-8000-000000000602'::uuid as prof_sem_turno;

-- Cadastra usuários contratantes
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values
  ((select user_dono from ids), 'contratante', 'Dono Real 860', '+5561999998601', 'dono860@test.invalid', '1985-01-01', '1.0', now(), false),
  ((select user_gerente from ids), 'contratante', 'Gerente 860', '+5561999998602', 'gerente860@test.invalid', '1988-02-02', '1.0', now(), false),
  ((select user_operador from ids), 'contratante', 'Operador 860', '+5561999998603', 'operador860@test.invalid', '1990-03-03', '1.0', now(), false),
  ((select user_dono_outro from ids), 'contratante', 'Outro Dono 860', '+5561999998620', 'outro860@test.invalid', '1982-04-04', '1.0', now(), false),
  ((select user_dono_demo from ids), 'contratante', 'Dono Demo 860', '+5561999998650', 'demo860@test.invalid', '1986-05-05', '1.0', now(), true);

-- Cadastra estabelecimentos e membros
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values
  ((select estab_real from ids), 'Restaurante Real 860', '86000000000101', 'food_service', 'Quadra 860', 'POINT(-47.88 -15.78)'::extensions.geography),
  ((select estab_outro from ids), 'Bar Alheio 860', '86000000000102', 'food_service', 'Quadra 861', 'POINT(-47.89 -15.79)'::extensions.geography),
  ((select estab_demo from ids), 'Casa Demo 860', '86000000000103', 'food_service', 'Quadra Demo', 'POINT(-47.90 -15.80)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values
  ((select user_dono from ids), (select estab_real from ids), 'administrador'),
  ((select user_gerente from ids), (select estab_real from ids), 'administrador'),
  ((select user_operador from ids), (select estab_real from ids), 'operador'),
  ((select user_dono_outro from ids), (select estab_outro from ids), 'administrador'),
  ((select user_dono_demo from ids), (select estab_demo from ids), 'administrador');

-- Cadastra profissionais
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values
  ((select user_prof_feliz from ids), 'profissional', 'Prof Feliz 860', '+5561988888601', 'feliz860@test.invalid', '1992-06-06', '1.0', now(), false),
  ((select user_prof_bloq_casa from ids), 'profissional', 'Prof Bloq Casa 860', '+5561988888602', 'bloqcasa860@test.invalid', '1993-07-07', '1.0', now(), false),
  ((select user_prof_bloqueou_dono from ids), 'profissional', 'Prof Bloq Dono 860', '+5561988888603', 'bloqdono860@test.invalid', '1994-08-08', '1.0', now(), false),
  ((select user_prof_bloq_gerente from ids), 'profissional', 'Prof Bloq Gerente 860', '+5561988888604', 'bloqger860@test.invalid', '1995-09-09', '1.0', now(), false),
  ((select user_prof_demo from ids), 'profissional', 'Prof Demo 860', '+5561988888605', 'demo_prof860@test.invalid', '1996-10-10', '1.0', now(), true),
  ((select user_prof_sem_turno from ids), 'profissional', 'Prof Sem Turno 860', '+5561988888606', 'semturno860@test.invalid', '1997-11-11', '1.0', now(), false);

insert into public.profissional (id, usuario_id, ponto_base)
values
  ((select prof_feliz from ids), (select user_prof_feliz from ids), 'POINT(-47.88 -15.78)'::extensions.geography),
  ((select prof_bloq_casa from ids), (select user_prof_bloq_casa from ids), 'POINT(-47.88 -15.78)'::extensions.geography),
  ((select prof_bloqueou_dono from ids), (select user_prof_bloqueou_dono from ids), 'POINT(-47.88 -15.78)'::extensions.geography),
  ((select prof_bloq_gerente from ids), (select user_prof_bloq_gerente from ids), 'POINT(-47.88 -15.78)'::extensions.geography),
  ((select prof_demo from ids), (select user_prof_demo from ids), 'POINT(-47.88 -15.78)'::extensions.geography),
  ((select prof_sem_turno from ids), (select user_prof_sem_turno from ids), 'POINT(-47.88 -15.78)'::extensions.geography);

-- Registra os usuários no auth
select pg_temp.autenticar((select user_dono from ids), 'dono860@test.invalid');
select pg_temp.autenticar((select user_gerente from ids), 'gerente860@test.invalid');
select pg_temp.autenticar((select user_operador from ids), 'operador860@test.invalid');
select pg_temp.autenticar((select user_dono_outro from ids), 'outro860@test.invalid');
select pg_temp.autenticar((select user_dono_demo from ids), 'demo860@test.invalid');
select pg_temp.autenticar((select user_prof_feliz from ids), 'feliz860@test.invalid');

-- Cria função helper para criar turno com presença verificada
create function pg_temp.criar_turno_verificado(
  p_estab uuid,
  p_prof  uuid,
  p_inicio timestamptz default '2026-11-10 10:00:00-03',
  p_fim    timestamptz default '2026-11-10 16:00:00-03'
) returns void language plpgsql as $$
declare
  v_vaga uuid := gen_random_uuid();
  v_pos  uuid := gen_random_uuid();
  v_func uuid;
begin
  select id into v_func from public.funcao where nome = 'garçom';

  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em,
                           local, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em, estado)
  values (v_vaga, p_estab, v_func, (select usuario_id from public.membro_estabelecimento where estabelecimento_id = p_estab limit 1),
          p_inicio, p_fim, 'Local 860', 'POINT(-47.88 -15.78)'::extensions.geography, 15000, 1, true, false, false,
          'Responsável 860', 'urgencia', gen_random_uuid(), p_inicio - interval '2 days', 'encerrada');

  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos, v_vaga, p_prof, 'cumprida', p_inicio - interval '1 day', false, p_inicio, p_fim);

  insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
  values (gen_random_uuid(), v_pos, p_inicio, p_fim, 'geolocalizado', 50, 'verificado', 15000);
end $$;

-- Cria turnos verificados na casa real para prof_feliz, prof_bloq_casa, prof_bloqueou_dono, prof_bloq_gerente e prof_demo
select pg_temp.criar_turno_verificado((select estab_real from ids), (select prof_feliz from ids), '2026-11-01 10:00-03', '2026-11-01 16:00-03');
select pg_temp.criar_turno_verificado((select estab_real from ids), (select prof_bloq_casa from ids), '2026-11-02 10:00-03', '2026-11-02 16:00-03');
select pg_temp.criar_turno_verificado((select estab_real from ids), (select prof_bloqueou_dono from ids), '2026-11-03 10:00-03', '2026-11-03 16:00-03');
select pg_temp.criar_turno_verificado((select estab_real from ids), (select prof_bloq_gerente from ids), '2026-11-04 10:00-03', '2026-11-04 16:00-03');
select pg_temp.criar_turno_verificado((select estab_real from ids), (select prof_demo from ids), '2026-11-05 10:00-03', '2026-11-05 16:00-03');

-- Cria turno verificado na casa demo para prof_demo e prof_feliz em dias distintos
select pg_temp.criar_turno_verificado((select estab_demo from ids), (select prof_demo from ids), '2026-11-06 10:00-03', '2026-11-06 16:00-03');
select pg_temp.criar_turno_verificado((select estab_demo from ids), (select prof_feliz from ids), '2026-11-07 10:00-03', '2026-11-07 16:00-03');

-- ── 4. Configuração dos Bloqueios (RF26) ───────────────────────────────────────

-- Bloqueio Sentido 1: Dono da casa real bloqueou prof_bloq_casa
insert into public.bloqueio (autor_id, bloqueado_id, criado_em)
values ((select user_dono from ids), (select user_prof_bloq_casa from ids), '2026-11-12 10:00:00-03');

-- Bloqueio Sentido 2: prof_bloqueou_dono bloqueou o Dono da casa real
insert into public.bloqueio (autor_id, bloqueado_id, criado_em)
values ((select user_prof_bloqueou_dono from ids), (select user_dono from ids), '2026-11-12 10:30:00-03');

-- Bloqueio por outro membro da casa: Gerente da casa bloqueou prof_bloq_gerente
insert into public.bloqueio (autor_id, bloqueado_id, criado_em)
values ((select user_gerente from ids), (select user_prof_bloq_gerente from ids), '2026-11-12 11:00:00-03');

-- ── 5. Execução dos Testes pgTAP ──────────────────────────────────────────────

-- Teste 6: Caminho feliz nominal: profissional real, sem bloqueio, turno verificado -> 200 MembroDaEquipe
select is(
  pg_temp.como((select user_dono from ids),
               format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), (select prof_feliz from ids))),
  jsonb_build_object('estabelecimento_id', (select estab_real from ids), 'profissional_id', (select prof_feliz from ids)),
  'Caminho feliz: profissional com turno verificado e sem bloqueio é incluído com sucesso na equipe'
);

-- Teste 7: Idempotência: re-execução do caminho feliz devolve o mesmo payload sem erro nem duplicação
select is(
  pg_temp.como((select user_dono from ids),
               format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), (select prof_feliz from ids))),
  jsonb_build_object('estabelecimento_id', (select estab_real from ids), 'profissional_id', (select prof_feliz from ids)),
  'Idempotência: re-execução de incluir_na_equipe é idempotente e devolve o mesmo payload'
);

-- Teste 8: Bloqueio Sentido 1 (Dono -> Profissional): recusa com 404 nao_encontrado (RF26 / D-14)
select throws_matching(
  pg_temp.por((select user_dono from ids),
              format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), (select prof_bloq_casa from ids))),
  pg_temp.erro('nao_encontrado'),
  'Bloqueio sentido 1 (Dono -> Profissional): incluir_na_equipe recusa 404 nao_encontrado (D-14)'
);

-- Teste 9: Bloqueio Sentido 2 (Profissional -> Dono): recusa com 404 nao_encontrado (RF26 / D-14)
select throws_matching(
  pg_temp.por((select user_dono from ids),
              format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), (select prof_bloqueou_dono from ids))),
  pg_temp.erro('nao_encontrado'),
  'Bloqueio sentido 2 (Profissional -> Dono): incluir_na_equipe recusa 404 nao_encontrado (D-14)'
);

-- Teste 10: Bloqueio por outro membro do estabelecimento: recusa com 404 nao_encontrado (RF26)
select throws_matching(
  pg_temp.por((select user_dono from ids),
              format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), (select prof_bloq_gerente from ids))),
  pg_temp.erro('nao_encontrado'),
  'Bloqueio por outro membro do estabelecimento recusa 404 nao_encontrado (RF26)'
);

-- Teste 11: Isolamento de demonstração (Chamador real x Profissional demo): recusa 404 nao_encontrado
select throws_matching(
  pg_temp.por((select user_dono from ids),
              format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), (select prof_demo from ids))),
  pg_temp.erro('nao_encontrado'),
  'Isolamento de demonstração: contratante real não pode incluir profissional de demonstração (404 nao_encontrado)'
);

-- Teste 12: Isolamento de demonstração (Chamador demo x Profissional real): recusa 404 nao_encontrado
select throws_matching(
  pg_temp.por((select user_dono_demo from ids),
              format('select public.incluir_na_equipe(%L, %L)', (select estab_demo from ids), (select prof_feliz from ids))),
  pg_temp.erro('nao_encontrado'),
  'Isolamento de demonstração: contratante demo não pode incluir profissional real (404 nao_encontrado)'
);

-- Teste 13: Caminho feliz no domínio de demonstração: Dono demo incluindo Profissional demo
select is(
  pg_temp.como((select user_dono_demo from ids),
               format('select public.incluir_na_equipe(%L, %L)', (select estab_demo from ids), (select prof_demo from ids))),
  jsonb_build_object('estabelecimento_id', (select estab_demo from ids), 'profissional_id', (select prof_demo from ids)),
  'Caminho feliz de demonstração: contratante demo inclui profissional demo sem bloqueio'
);

-- Teste 14: Preservação: chamador não autenticado recusa 401 nao_autenticado
select throws_matching(
  $$ select public.incluir_na_equipe('86000000-0000-4000-8000-000000000010'::uuid, '86000000-0000-4000-8000-000000000102'::uuid) $$,
  pg_temp.erro('nao_autenticado'),
  'Preservação: chamada sem autenticação recusa 401 nao_autenticado'
);

-- Teste 15: Preservação: chamador com perfil profissional recusa 422 perfil_incompativel
select throws_matching(
  pg_temp.por((select user_prof_feliz from ids),
              format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), (select prof_feliz from ids))),
  pg_temp.erro('perfil_incompativel'),
  'Preservação: profissional chamando incluir_na_equipe recusa 422 perfil_incompativel'
);

-- Teste 16: Preservação: operador da casa (não administrador) recusa 403 sem_permissao
select throws_matching(
  pg_temp.por((select user_operador from ids),
              format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), (select prof_feliz from ids))),
  pg_temp.erro('sem_permissao'),
  'Preservação: operador do estabelecimento recusa 403 sem_permissao (RF21)'
);

-- Teste 17: Preservação: administrador de outro estabelecimento recusa 403 sem_permissao
select throws_matching(
  pg_temp.por((select user_dono_outro from ids),
              format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), (select prof_feliz from ids))),
  pg_temp.erro('sem_permissao'),
  'Preservação: administrador de outro estabelecimento recusa 403 sem_permissao'
);

-- Teste 18: Preservação: profissional que não cumpriu turno na casa recusa 403 sem_turno_cumprido
select throws_matching(
  pg_temp.por((select user_dono from ids),
              format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), (select prof_sem_turno from ids))),
  pg_temp.erro('sem_permissao', 'sem_turno_cumprido'),
  'Preservação: profissional sem turno verificado recusa 403 sem_permissao (sem_turno_cumprido)'
);

-- Teste 19: Preservação: profissional inexistente recusa 404 nao_encontrado
select throws_matching(
  pg_temp.por((select user_dono from ids),
              format('select public.incluir_na_equipe(%L, %L)', (select estab_real from ids), '86000000-0000-4000-8000-000000000999'::uuid)),
  pg_temp.erro('nao_encontrado'),
  'Preservação: profissional inexistente recusa 404 nao_encontrado'
);

-- Teste 20: Tabela equipe_confianca não foi poluída com os profissionais bloqueados
select is(
  (select count(*)::int from public.equipe_confianca where profissional_id in (
    (select prof_bloq_casa from ids),
    (select prof_bloqueou_dono from ids),
    (select prof_bloq_gerente from ids)
  )),
  0,
  'Integridade: nenhum profissional bloqueado consta em public.equipe_confianca'
);

-- Teste 21: Tabela equipe_confianca possui exatamente o profissional feliz cadastrado
select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id = (select estab_real from ids)
      and profissional_id = (select prof_feliz from ids)),
  1,
  'Integridade: profissional feliz cadastrado com sucesso e sem duplicação'
);

rollback;
