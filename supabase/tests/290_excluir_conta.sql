-- Teste pgTAP 290: Exclusão de conta (cartão OrS9gEfU).
--
-- Critérios de aceite e decisões cobertos:
-- 1. Depois de excluir, a conta não entra, não recebe despacho e não aparece em busca.
-- 2. Turnos passados da outra parte mostram 'Conta encerrada' e a reputação dela não muda
--    (visto em painel_estabelecimento pelo contratante e em meus_turnos pelo profissional).
-- 3. Token emitido antes da exclusão é recusado com 401 (nao_autenticado) em qualquer RPC de escrita
--    (candidatar, fazer_checkin, registrar_dispositivo, avaliar, confirmar_checkin_manual,
--     cancelar_posicao, cancelar_vaga) e não consegue puxar token de push de outra conta.
-- 4. Idempotência: conta inexistente no usuario ou já anonimizada não falha (turnos_cancelados = 0).
-- 5. Turno futuro do profissional reabre (vaga volta a 'publicada', nova posição 'aberta',
--    sem falta, outra parte avisada com reaberta: true).
-- 6. Contratante único membro: turnos futuros cancelados (sem falta, prof avisado com reaberta: false),
--    vagas abertas canceladas, candidaturas pendentes retiradas e candidatos avisados.
-- 7. Regra de negócio: 409 administrador_unico quando houver outros membros no estabelecimento.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(60);

insert into privado.ambiente (eh_teste) values (true);

-- ── 1. Metadados e privilégios das funções ───────────────────────────────────

select has_function(
  'privado',
  'exigir_conta_ativa',
  array[]::text[],
  'privado.exigir_conta_ativa() existe');

select is(
  has_function_privilege('public', 'privado.exigir_conta_ativa()', 'execute'),
  false,
  'privado.exigir_conta_ativa() não é executável por public');

select is(
  has_function_privilege('anon', 'privado.exigir_conta_ativa()', 'execute'),
  false,
  'privado.exigir_conta_ativa() não é executável por anon');

select is(
  has_function_privilege('authenticated', 'privado.exigir_conta_ativa()', 'execute'),
  false,
  'privado.exigir_conta_ativa() não é executável por authenticated');

select is(
  has_function_privilege('service_role', 'privado.exigir_conta_ativa()', 'execute'),
  true,
  'privado.exigir_conta_ativa() é executável por service_role');

select has_function(
  'privado',
  'excluir_conta',
  array['uuid']::text[],
  'privado.excluir_conta(uuid) existe');

select is(
  has_function_privilege('public', 'privado.excluir_conta(uuid)', 'execute'),
  false,
  'privado.excluir_conta(uuid) não é executável por public');

select is(
  has_function_privilege('anon', 'privado.excluir_conta(uuid)', 'execute'),
  false,
  'privado.excluir_conta(uuid) não é executável por anon');

select is(
  has_function_privilege('authenticated', 'privado.excluir_conta(uuid)', 'execute'),
  false,
  'privado.excluir_conta(uuid) não é executável por authenticated');

select is(
  has_function_privilege('service_role', 'privado.excluir_conta(uuid)', 'execute'),
  true,
  'privado.excluir_conta(uuid) é executável por service_role');

select is(
  (select p.prosecdef
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'excluir_conta'),
  true,
  'privado.excluir_conta é security definer');

select is(
  (select coalesce(p.proconfig, '{}') @> array['search_path=""']
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'excluir_conta'),
  true,
  'privado.excluir_conta fixa search_path vazio');

select is(
  (select count(*)
     from pg_policies
    where schemaname = 'public'
      and tablename in ('usuario', 'dispositivo', 'ocorrencia', 'posicao', 'vaga', 'candidatura')
      and cmd <> 'SELECT'),
  0::bigint,
  'A exclusão não abre política de escrita em tabelas');

-- ── 2. Cenário de teste isolado ───────────────────────────────────────────────

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
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

create temp table ids as
select
  'c1000000-0000-4000-8000-000000000001'::uuid as prof_u,
  'c1000000-0000-4000-8000-000000000011'::uuid as prof_p,
  'c1000000-0000-4000-8000-000000000002'::uuid as admin_u,
  'c1000000-0000-4000-8000-000000000003'::uuid as operador_u,
  'c1000000-0000-4000-8000-000000000021'::uuid as estab_com_membros,
  'c1000000-0000-4000-8000-000000000004'::uuid as admin_solo_u,
  'c1000000-0000-4000-8000-000000000022'::uuid as estab_solo,
  'c1000000-0000-4000-8000-000000000005'::uuid as prof2_u,
  'c1000000-0000-4000-8000-000000000015'::uuid as prof2_p,
  'c1000000-0000-4000-8000-000000000006'::uuid as outro_u,
  'c1000000-0000-4000-8000-000000000016'::uuid as outro_p,
  -- Vagas e posições do estab_com_membros
  'c1000000-0000-4000-8000-000000000031'::uuid as vaga_futura,
  'c1000000-0000-4000-8000-000000000041'::uuid as pos_futura,
  'c1000000-0000-4000-8000-000000000051'::uuid as turno_futuro,
  'c1000000-0000-4000-8000-000000000037'::uuid as vaga_urgente,
  'c1000000-0000-4000-8000-000000000047'::uuid as pos_urgente,
  'c1000000-0000-4000-8000-000000000057'::uuid as turno_urgente,
  'c1000000-0000-4000-8000-000000000032'::uuid as vaga_passada,
  'c1000000-0000-4000-8000-000000000042'::uuid as pos_passada,
  'c1000000-0000-4000-8000-000000000052'::uuid as turno_passado,
  'c1000000-0000-4000-8000-000000000033'::uuid as vaga_aberta_outra,
  'c1000000-0000-4000-8000-000000000043'::uuid as pos_aberta_outra,
  'c1000000-0000-4000-8000-000000000061'::uuid as cand_prof_u,
  -- Vagas e posições do estab_solo
  'c1000000-0000-4000-8000-000000000034'::uuid as vaga_passada_solo,
  'c1000000-0000-4000-8000-000000000044'::uuid as pos_passada_solo,
  'c1000000-0000-4000-8000-000000000054'::uuid as turno_passado_solo,
  'c1000000-0000-4000-8000-000000000035'::uuid as vaga_futura_solo,
  'c1000000-0000-4000-8000-000000000045'::uuid as pos_futura_solo,
  'c1000000-0000-4000-8000-000000000055'::uuid as turno_futuro_solo,
  'c1000000-0000-4000-8000-000000000036'::uuid as vaga_aberta_solo,
  'c1000000-0000-4000-8000-000000000046'::uuid as pos_aberta_solo,
  'c1000000-0000-4000-8000-000000000062'::uuid as cand_prof2_solo;

select pg_temp.autenticar(prof_u, 'prof-exclusao@test.invalid') from ids;
select pg_temp.autenticar(admin_u, 'admin-exclusao@test.invalid') from ids;
select pg_temp.autenticar(operador_u, 'operador-exclusao@test.invalid') from ids;
select pg_temp.autenticar(admin_solo_u, 'admin-solo@test.invalid') from ids;
select pg_temp.autenticar(prof2_u, 'prof2-exclusao@test.invalid') from ids;
select pg_temp.autenticar(outro_u, 'outro-user@test.invalid') from ids;

-- Contas
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select prof_u, 'profissional', 'Carlos Garçom', '+5561999990101', 'prof-exclusao@test.invalid', '1995-05-10', '2026-09-22', now(), 'ativa' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select admin_u, 'contratante', 'Maria Administradora', '+5561999990102', 'admin-exclusao@test.invalid', '1985-04-12', '2026-09-22', now(), 'ativa' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select operador_u, 'contratante', 'João Operador', '+5561999990103', 'operador-exclusao@test.invalid', '1992-08-20', '2026-09-22', now(), 'ativa' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select admin_solo_u, 'contratante', 'Paula Solo', '+5561999990104', 'admin-solo@test.invalid', '1988-11-15', '2026-09-22', now(), 'ativa' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select prof2_u, 'profissional', 'Roberto Barman', '+5561999990105', 'prof2-exclusao@test.invalid', '1990-07-22', '2026-09-22', now(), 'ativa' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select outro_u, 'profissional', 'Outro Ativo', '+5561999990106', 'outro-user@test.invalid', '1994-01-30', '2026-09-22', now(), 'ativa' from ids;

-- Perfis profissionais
insert into public.profissional (id, usuario_id, ponto_base, taxa_comparecimento, turnos_realizados, aval_positivas, aval_total)
select prof_p, prof_u, extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       1.000, 1, 1, 1 from ids;

insert into public.profissional_funcao (profissional_id, funcao_id)
select prof_p, (select id from public.funcao where nome = 'garçom') from ids;

insert into public.profissional (id, usuario_id, ponto_base, taxa_comparecimento, turnos_realizados, aval_positivas, aval_total)
select prof2_p, prof2_u, extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       1.000, 1, 0, 0 from ids;

insert into public.profissional_funcao (profissional_id, funcao_id)
select prof2_p, (select id from public.funcao where nome = 'bartender') from ids;

insert into public.profissional (id, usuario_id, ponto_base, taxa_comparecimento, turnos_realizados, aval_positivas, aval_total)
select outro_p, outro_u, extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       1.000, 0, 0, 0 from ids;

insert into public.profissional_funcao (profissional_id, funcao_id)
select outro_p, (select id from public.funcao where nome = 'garçom') from ids;

-- Estabelecimentos
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, aval_positivas, aval_total)
select estab_com_membros, 'Bar das Nações', '12345678000195', 'food_service', 'SCLS 402',
       extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography, 0, 0 from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select admin_u, estab_com_membros, 'administrador' from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select operador_u, estab_com_membros, 'operador' from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, aval_positivas, aval_total)
select estab_solo, 'Café Solo', '98765432000100', 'food_service', 'SCLN 102',
       extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography, 0, 0 from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select admin_solo_u, estab_solo, 'administrador' from ids;

-- Aparelhos registrados
insert into public.dispositivo (usuario_id, token_fcm, plataforma)
select prof_u, 'token-fcm-prof-1', 'ios' from ids;

insert into public.dispositivo (usuario_id, token_fcm, plataforma)
select outro_u, 'token-fcm-outro', 'android' from ids;

-- ── Estabelecimento com membros: Vagas, Posições e Turnos ─────────────────────

-- 1. Turno passado (já realizado e avaliado bilateralmente com estab_com_membros)
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto, local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
select vaga_passada, estab_com_membros, (select id from public.funcao where nome = 'garçom'), admin_u,
       privado.agora() - interval '2 days', privado.agora() - interval '2 days' + interval '6 hours',
       15000, 'preenchida', extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       'SCLS 402', 'urgencia', 1, false, false, false, 'Maria', gen_random_uuid() from ids;

insert into public.posicao (id, vaga_id, profissional_id, estado, inicio_em, fim_em, confirmado_em, falta)
select pos_passada, vaga_passada, prof_p, 'cumprida',
       privado.agora() - interval '2 days', privado.agora() - interval '2 days' + interval '6 hours',
       privado.agora() - interval '3 days', false from ids;

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
select turno_passado, pos_passada, privado.agora() - interval '2 days', 'geolocalizado', 15, 'verificado', 15000 from ids;

insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
select turno_passado, admin_u, 'profissional', prof_p, true from ids;

insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
select turno_passado, prof_u, 'estabelecimento', estab_com_membros, true from ids;

-- 2. Turno futuro confirmado do profissional prof_u (a menos de 24h para provar isenção por excluir_conta)
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto, local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
select vaga_futura, estab_com_membros, (select id from public.funcao where nome = 'garçom'), admin_u,
       privado.agora() + interval '3 hours', privado.agora() + interval '9 hours',
       18000, 'preenchida', extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       'SCLS 402', 'urgencia', 1, false, false, false, 'Maria', gen_random_uuid() from ids;

insert into public.posicao (id, vaga_id, profissional_id, estado, inicio_em, fim_em, confirmado_em, falta)
select pos_futura, vaga_futura, prof_p, 'confirmada',
       privado.agora() + interval '3 hours', privado.agora() + interval '9 hours',
       privado.agora() - interval '1 hour', false from ids;

insert into public.turno (id, posicao_id, valor_acordado_centavos, verificacao)
select turno_futuro, pos_futura, 18000, 'pendente' from ids;

-- 2.1 Turno urgente de outro profissional (para provar falta em cancelar_posicao a menos de 24h)
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto, local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
select vaga_urgente, estab_com_membros, (select id from public.funcao where nome = 'garçom'), admin_u,
       privado.agora() + interval '2 hours', privado.agora() + interval '8 hours',
       15000, 'preenchida', extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       'SCLS 402', 'urgencia', 1, false, false, false, 'Maria', gen_random_uuid() from ids;

insert into public.posicao (id, vaga_id, profissional_id, estado, inicio_em, fim_em, confirmado_em, falta)
select pos_urgente, vaga_urgente, outro_p, 'confirmada',
       privado.agora() + interval '2 hours', privado.agora() + interval '8 hours',
       privado.agora() - interval '1 hour', false from ids;

insert into public.turno (id, posicao_id, valor_acordado_centavos, verificacao)
select turno_urgente, pos_urgente, 15000, 'pendente' from ids;

-- 3. Outra vaga aberta com candidatura pendente de prof_u
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto, local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
select vaga_aberta_outra, estab_com_membros, (select id from public.funcao where nome = 'garçom'), admin_u,
       privado.agora() + interval '5 days', privado.agora() + interval '5 days' + interval '6 hours',
       17000, 'publicada', extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       'SCLS 402', 'urgencia', 1, false, false, false, 'Maria', gen_random_uuid() from ids;

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
select pos_aberta_outra, vaga_aberta_outra, 'aberta',
       privado.agora() + interval '5 days', privado.agora() + interval '5 days' + interval '6 hours' from ids;

insert into public.candidatura (id, posicao_id, profissional_id, estado)
select cand_prof_u, pos_aberta_outra, prof_p, 'pendente' from ids;

-- ── Estabelecimento solo: Vagas, Posições e Turnos ────────────────────────────

-- 4. Turno passado do estabelecimento solo com prof2_p (já realizado e avaliado)
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto, local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
select vaga_passada_solo, estab_solo, (select id from public.funcao where nome = 'bartender'), admin_solo_u,
       privado.agora() - interval '1 day', privado.agora() - interval '1 day' + interval '6 hours',
       16000, 'preenchida', extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       'SCLN 102', 'urgencia', 1, false, false, false, 'Paula', gen_random_uuid() from ids;

insert into public.posicao (id, vaga_id, profissional_id, estado, inicio_em, fim_em, confirmado_em, falta)
select pos_passada_solo, vaga_passada_solo, prof2_p, 'cumprida',
       privado.agora() - interval '1 day', privado.agora() - interval '1 day' + interval '6 hours',
       privado.agora() - interval '2 days', false from ids;

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
select turno_passado_solo, pos_passada_solo, privado.agora() - interval '1 day', 'geolocalizado', 10, 'verificado', 16000 from ids;

insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
select turno_passado_solo, admin_solo_u, 'profissional', prof2_p, true from ids;

insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
select turno_passado_solo, prof2_u, 'estabelecimento', estab_solo, true from ids;

-- 5. Turno futuro confirmado no estabelecimento solo com prof2_p
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto, local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
select vaga_futura_solo, estab_solo, (select id from public.funcao where nome = 'bartender'), admin_solo_u,
       privado.agora() + interval '2 days', privado.agora() + interval '2 days' + interval '6 hours',
       19000, 'preenchida', extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       'SCLN 102', 'urgencia', 1, false, false, false, 'Paula', gen_random_uuid() from ids;

insert into public.posicao (id, vaga_id, profissional_id, estado, inicio_em, fim_em, confirmado_em, falta)
select pos_futura_solo, vaga_futura_solo, prof2_p, 'confirmada',
       privado.agora() + interval '2 days', privado.agora() + interval '2 days' + interval '6 hours',
       privado.agora() - interval '2 hours', false from ids;

insert into public.turno (id, posicao_id, valor_acordado_centavos, verificacao)
select turno_futuro_solo, pos_futura_solo, 19000, 'pendente' from ids;

-- 6. Vaga aberta no estabelecimento solo com candidatura pendente de prof2_p
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto, local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
select vaga_aberta_solo, estab_solo, (select id from public.funcao where nome = 'bartender'), admin_solo_u,
       privado.agora() + interval '4 days', privado.agora() + interval '4 days' + interval '6 hours',
       20000, 'publicada', extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       'SCLN 102', 'urgencia', 1, false, false, false, 'Paula', gen_random_uuid() from ids;

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
select pos_aberta_solo, vaga_aberta_solo, 'aberta',
       privado.agora() + interval '4 days', privado.agora() + interval '4 days' + interval '6 hours' from ids;

insert into public.candidatura (id, posicao_id, profissional_id, estado)
select cand_prof2_solo, pos_aberta_solo, prof2_p, 'pendente' from ids;

-- ── 3. Conflito 409 administrador_unico e Idempotência ───────────────────────

select throws_ok(
  format($$ select privado.excluir_conta(%L) $$, (select admin_u from ids)),
  'PGRST',
  '{"code" : "administrador_unico", "message" : "administrador_unico", "details" : null, "hint" : null}',
  'Único administrador de estabelecimento com outros membros recebe 409 administrador_unico');

select is(
  (select (privado.excluir_conta('c1000000-0000-4000-8000-000000000999'::uuid))->>'turnos_cancelados'),
  '0',
  'Conta inexistente no usuario retorna 0 turnos cancelados sem erro');

-- ── 3.1 Falta em cancelar_posicao com motivo 'exclusão de conta' a menos de 24h ──
--
-- A isenção de falta em cima da hora (RN12) é exclusiva de exclusão de conta real
-- (sinalizada internamente via frila.exclusao_de_conta). Se um usuário chamar
-- cancelar_posicao diretamente informando o texto 'exclusão de conta' a menos de 24h,
-- a falta AINDA deve ser marcada e a taxa de comparecimento recalculada.

select lives_ok(
  format($$ select pg_temp.como(%L, format('select public.cancelar_posicao(%%L::uuid, %%L)', %L, 'exclusão de conta')) $$,
         (select outro_u from ids), (select pos_urgente from ids)),
  'Profissional ativo pode cancelar posição com motivo exclusão de conta');

select is(
  (select estado from public.posicao where id = (select pos_urgente from ids)),
  'cancelada'::public.estado_posicao,
  'Posição cancelada pelo profissional via cancelar_posicao');

select is(
  (select falta from public.posicao where id = (select pos_urgente from ids)),
  true,
  'cancelar_posicao a menos de 24h com motivo "exclusão de conta" ainda marca falta');

select is(
  (select taxa_comparecimento from public.profissional where id = (select outro_p from ids)),
  0.000,
  'Taxa de comparecimento do profissional é recalculada refletindo a falta');

-- ── 4. Exclusão de profissional com turno futuro (Decisão JP: Reabertura) ────

select lives_ok(
  format($$ select privado.excluir_conta(%L) $$, (select prof_u from ids)),
  'Exclusão de conta de profissional executa com sucesso');

-- Verifica cancelamento do turno futuro
select is(
  (select estado from public.posicao where id = (select pos_futura from ids)),
  'cancelada'::public.estado_posicao,
  'Turno futuro fica cancelado com a exclusão');

select is(
  (select falta from public.posicao where id = (select pos_futura from ids)),
  false,
  'Cancelamento por exclusão de conta a menos de 24h não marca falta');

select is(
  (select verificacao from public.turno where id = (select turno_futuro from ids)),
  'nao_verificado'::public.verificacao_turno,
  'Turno cancelado fica com verificacao = nao_verificado');

select is(
  (select motivo from public.ocorrencia where posicao_id = (select pos_futura from ids)),
  'exclusão de conta',
  'Ocorrência de cancelamento registra motivo exclusão de conta');

-- Contraparte notificada com reaberta: true (Decisão do João Paulo)
select is(
  (select count(*) from public.notificacao
    where tipo = 'cancelamento'
      and referencia_id = (select pos_futura from ids)
      and usuario_id = (select admin_u from ids)),
  1::bigint,
  'Contraparte recebe notificação de cancelamento do turno futuro');

select is(
  (select (payload->>'reaberta')::boolean from public.notificacao
    where tipo = 'cancelamento'
      and referencia_id = (select pos_futura from ids)
      and usuario_id = (select admin_u from ids)),
  true,
  'Notificação de cancelamento indica reaberta = true');

-- Vaga reabre: volta a publicada e ganha nova posição aberta
select is(
  (select estado from public.vaga where id = (select vaga_futura from ids)),
  'publicada'::public.estado_vaga,
  'Vaga futura volta para estado publicada (reaberta)');

select is(
  (select count(*) from public.posicao
    where vaga_id = (select vaga_futura from ids)
      and estado = 'aberta'),
  1::bigint,
  'Vaga futura ganha nova posição com estado aberta');

-- Candidatura pendente do profissional retirada
select is(
  (select estado from public.candidatura where id = (select cand_prof_u from ids)),
  'retirada'::public.estado_candidatura,
  'Candidatura pendente do profissional é marcada como retirada');

-- Aparelhos removidos
select is(
  (select count(*) from public.dispositivo where usuario_id = (select prof_u from ids)),
  0::bigint,
  'Aparelhos da conta excluída são removidos');

-- Usuário anonimizado (RF25)
select is(
  (select nome from public.usuario where id = (select prof_u from ids)),
  'Conta encerrada',
  'Nome do usuário excluído passa a ser Conta encerrada');

select is(
  (select telefone from public.usuario where id = (select prof_u from ids)),
  null,
  'Telefone do usuário excluído é nulo');

select is(
  (select email from public.usuario where id = (select prof_u from ids)),
  null,
  'E-mail do usuário excluído é nulo');

select is(
  (select estado from public.usuario where id = (select prof_u from ids)),
  'anonimizada'::public.estado_conta,
  'Estado da conta excluída é anonimizada');

-- Idempotência: segunda chamada na mesma conta já anonimizada
select is(
  (select (privado.excluir_conta((select prof_u from ids)))->>'turnos_cancelados'),
  '0',
  'Segunda chamada a excluir_conta em conta já anonimizada retorna 0 turnos cancelados');

-- ── 5. Critério 1: Não recebe despacho e aparece anonimizado ─────────────────

select is(
  (select count(*) from privado.elegiveis((select vaga_aberta_solo from ids))
    where profissional_id = (select prof_p from ids)),
  0::bigint,
  'Conta excluída não recebe despacho (privado.elegiveis não a inclui)');

select is(
  (privado.perfil_publico_profissional((select prof_p from ids))->>'nome'),
  'Conta encerrada',
  'Perfil público do profissional mostra Conta encerrada');

-- ── 6. Critério 2: Histórico e reputação vistos pela contraparte contratante ─

select is(
  (select p->'profissional'->>'nome'
     from jsonb_array_elements(
       (pg_temp.como(
         (select admin_u from ids),
         format('select public.painel_estabelecimento(%L, %L, %L)',
                (select estab_com_membros from ids),
                privado.agora() - interval '5 days',
                privado.agora() + interval '5 days')
       ))->'vagas'
     ) as v,
     jsonb_array_elements(v->'posicoes') as p
    where (p->>'id')::uuid = (select pos_passada from ids)),
  'Conta encerrada',
  'Turno passado no painel_estabelecimento mostra Conta encerrada');

select is(
  (select aval_positivas from public.estabelecimento where id = (select estab_com_membros from ids)),
  1,
  'Reputação da outra parte (positivas) não muda com a exclusão');

select is(
  (select aval_total from public.estabelecimento where id = (select estab_com_membros from ids)),
  1,
  'Reputação da outra parte (total) não muda com a exclusão');

-- ── 7. Critério 3 (Bloqueio 2): Token pré-emissão recusado em RPCs de escrita ──

select throws_ok(
  format($$ select pg_temp.como(%L, format('select public.candidatar(%%L)', %L)) $$,
         (select prof_u from ids), (select vaga_aberta_outra from ids)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'Token emitido antes da exclusão é recusado em candidatar');

select throws_ok(
  format($$ select pg_temp.como(%L, format('select public.fazer_checkin(%%L::uuid, 10)', %L)) $$,
         (select prof_u from ids), (select turno_passado from ids)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'Token emitido antes da exclusão é recusado em fazer_checkin');

select throws_ok(
  format($$ select pg_temp.como(%L, format('select public.registrar_dispositivo(%%L, %%L)', 'token-fcm-novo-1234567890', 'android')) $$,
         (select prof_u from ids)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'Token emitido antes da exclusão é recusado em registrar_dispositivo');

select throws_ok(
  format($$ select pg_temp.como(%L, format('select public.avaliar(%%L::uuid, true)', %L)) $$,
         (select prof_u from ids), (select turno_passado from ids)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'Token emitido antes da exclusão é recusado em avaliar');

select throws_ok(
  format($$ select pg_temp.como(%L, format('select public.confirmar_checkin_manual(%%L::uuid)', %L)) $$,
         (select prof_u from ids), (select turno_passado from ids)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'Token emitido antes da exclusão é recusado em confirmar_checkin_manual');

select throws_ok(
  format($$ select pg_temp.como(%L, format('select public.cancelar_posicao(%%L::uuid, %%L)', %L, 'motivo valido cancelamento')) $$,
         (select prof_u from ids), (select pos_passada from ids)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'Token emitido antes da exclusão é recusado em cancelar_posicao');

select throws_ok(
  format($$ select pg_temp.como(%L, format('select public.cancelar_vaga(%%L::uuid, %%L)', %L, 'motivo valido cancelamento')) $$,
         (select prof_u from ids), (select vaga_aberta_outra from ids)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'Token emitido antes da exclusão é recusado em cancelar_vaga');

-- Conta encerrada não puxa token de push de outra conta
select throws_ok(
  format($$ select pg_temp.como(%L, format('select public.registrar_dispositivo(%%L, %%L)', 'token-fcm-outro', 'android')) $$,
         (select prof_u from ids)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'Conta encerrada não consegue puxar token de push de outra conta');

select is(
  (select usuario_id from public.dispositivo where token_fcm = 'token-fcm-outro'),
  (select outro_u from ids),
  'Token push de outra conta permanece inalterado com seu verdadeiro dono');

-- ── 8. Exclusão de contratante único membro (Estabelecimento solo) ───────────

select lives_ok(
  format($$ select privado.excluir_conta(%L) $$, (select admin_solo_u from ids)),
  'Único membro do estabelecimento pode excluir a conta');

-- Turno futuro confirmado com prof2: posição cancelada sem falta e prof2 avisado (reaberta: false)
select is(
  (select estado from public.posicao where id = (select pos_futura_solo from ids)),
  'cancelada'::public.estado_posicao,
  'Turno futuro do contratante solo fica cancelado sem falta');

select is(
  (select (payload->>'reaberta')::boolean from public.notificacao
    where tipo = 'cancelamento'
      and referencia_id = (select pos_futura_solo from ids)
      and usuario_id = (select prof2_u from ids)),
  false,
  'Profissional 2 é notificado do cancelamento com reaberta = false');

-- Vagas do estabelecimento solo canceladas
select is(
  (select estado from public.vaga where id = (select vaga_futura_solo from ids)),
  'cancelada'::public.estado_vaga,
  'Vaga do turno futuro do estabelecimento solo é cancelada');

select is(
  (select estado from public.vaga where id = (select vaga_aberta_solo from ids)),
  'cancelada'::public.estado_vaga,
  'Vaga aberta do estabelecimento sem membros é cancelada');

select is(
  (select estado from public.posicao where id = (select pos_aberta_solo from ids)),
  'cancelada'::public.estado_posicao,
  'Posição aberta da vaga sem membros é cancelada');

-- Candidatura pendente de prof2 na vaga solo retirada e prof2 avisado
select is(
  (select estado from public.candidatura where id = (select cand_prof2_solo from ids)),
  'retirada'::public.estado_candidatura,
  'Candidatura pendente na vaga do contratante solo passa para retirada');

select is(
  (select count(*) from public.notificacao
    where tipo = 'cancelamento'
      and referencia_id = (select vaga_aberta_solo from ids)
      and usuario_id = (select prof2_u from ids)),
  1::bigint,
  'Candidato da vaga do contratante solo é notificado do cancelamento da vaga');

select is(
  (select count(*) from public.membro_estabelecimento where usuario_id = (select admin_solo_u from ids)),
  0::bigint,
  'Contratante solo é removido de membro_estabelecimento');

-- Critério 2 visto pelo profissional prof2_u em meus_turnos
select is(
  (select count(*)
     from jsonb_array_elements(
       pg_temp.como((select prof2_u from ids), 'select public.meus_turnos()')
     ) as t
    where (t->>'id')::uuid = (select turno_passado_solo from ids)),
  1::bigint,
  'Profissional 2 vê turno passado com estabelecimento solo em meus_turnos');

select is(
  (select jsonb_build_object(
            'taxa', taxa_comparecimento,
            'realizados', turnos_realizados,
            'positivas', aval_positivas,
            'total', aval_total)
     from public.profissional
    where id = (select prof2_p from ids)),
  jsonb_build_object('taxa', 1.000, 'realizados', 1, 'positivas', 1, 'total', 1),
  'Reputação do profissional 2 mantida intacta após exclusão do contratante');

select * from finish();
rollback;
