-- Teste pgTAP 290: Exclusão de conta (cartão OrS9gEfU).
--
-- Critérios de aceite cobertos:
-- 1. Depois de excluir, a conta não entra, não recebe despacho e não aparece em busca.
-- 2. Turnos passados da outra parte mostram 'Conta encerrada' e a reputação dela não muda.
-- 3. Token emitido antes da exclusão é recusado em qualquer RPC de escrita (privado.exigir_conta_ativa).
-- 5. Turno futuro fica cancelado com motivo 'exclusão de conta' e a outra parte recebe notificação.
-- Extra: Regra de negócio 409 administrador_unico e exclusão de único membro da casa.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(34);

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
      and tablename in ('usuario', 'dispositivo', 'ocorrencia', 'posicao', 'vaga')
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
  'c1000000-0000-4000-8000-000000000031'::uuid as vaga_futura,
  'c1000000-0000-4000-8000-000000000041'::uuid as pos_futura,
  'c1000000-0000-4000-8000-000000000051'::uuid as turno_futuro,
  'c1000000-0000-4000-8000-000000000032'::uuid as vaga_passada,
  'c1000000-0000-4000-8000-000000000042'::uuid as pos_passada,
  'c1000000-0000-4000-8000-000000000052'::uuid as turno_passado,
  'c1000000-0000-4000-8000-000000000033'::uuid as vaga_solo,
  'c1000000-0000-4000-8000-000000000043'::uuid as pos_solo;

select pg_temp.autenticar(prof_u, 'prof-exclusao@test.invalid') from ids;
select pg_temp.autenticar(admin_u, 'admin-exclusao@test.invalid') from ids;
select pg_temp.autenticar(operador_u, 'operador-exclusao@test.invalid') from ids;
select pg_temp.autenticar(admin_solo_u, 'admin-solo@test.invalid') from ids;

-- Contas
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select prof_u, 'profissional', 'Carlos Garçom', '+5561999990101', 'prof-exclusao@test.invalid', '1995-05-10', '2026-09-22', now(), 'ativa' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select admin_u, 'contratante', 'Maria Administradora', '+5561999990102', 'admin-exclusao@test.invalid', '1985-04-12', '2026-09-22', now(), 'ativa' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select operador_u, 'contratante', 'João Operador', '+5561999990103', 'operador-exclusao@test.invalid', '1992-08-20', '2026-09-22', now(), 'ativa' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
select admin_solo_u, 'contratante', 'Paula Solo', '+5561999990104', 'admin-solo@test.invalid', '1988-11-15', '2026-09-22', now(), 'ativa' from ids;

-- Perfil profissional com ponto_base em Brasília
insert into public.profissional (id, usuario_id, ponto_base, taxa_comparecimento, turnos_realizados, aval_positivas, aval_total)
select prof_p, prof_u, extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       1.000, 1, 1, 1 from ids;

insert into public.profissional_funcao (profissional_id, funcao_id)
select prof_p, (select id from public.funcao where nome = 'garçom') from ids;

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

-- Aparelho do profissional
insert into public.dispositivo (usuario_id, token_fcm, plataforma)
select prof_u, 'token-fcm-prof-1', 'ios' from ids;

-- 1. Turno passado (já realizado e avaliado)
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

-- 2. Turno futuro confirmado
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto, local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
select vaga_futura, estab_com_membros, (select id from public.funcao where nome = 'garçom'), admin_u,
       privado.agora() + interval '3 days', privado.agora() + interval '3 days' + interval '6 hours',
       18000, 'preenchida', extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       'SCLS 402', 'urgencia', 1, false, false, false, 'Maria', gen_random_uuid() from ids;

insert into public.posicao (id, vaga_id, profissional_id, estado, inicio_em, fim_em, confirmado_em, falta)
select pos_futura, vaga_futura, prof_p, 'confirmada',
       privado.agora() + interval '3 days', privado.agora() + interval '3 days' + interval '6 hours',
       privado.agora() - interval '1 hour', false from ids;

insert into public.turno (id, posicao_id, valor_acordado_centavos, verificacao)
select turno_futuro, pos_futura, 18000, 'pendente' from ids;

-- 3. Vaga aberta do estabelecimento solo
insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto, local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
select vaga_solo, estab_solo, (select id from public.funcao where nome = 'garçom'), admin_solo_u,
       privado.agora() + interval '4 days', privado.agora() + interval '4 days' + interval '6 hours',
       20000, 'publicada', extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
       'SCLN 102', 'urgencia', 1, false, false, false, 'Paula', gen_random_uuid() from ids;

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
select pos_solo, vaga_solo, 'aberta',
       privado.agora() + interval '4 days', privado.agora() + interval '4 days' + interval '6 hours' from ids;

-- ── 3. Conflito 409 administrador_unico ──────────────────────────────────────

select throws_ok(
  format($$ select privado.excluir_conta(%L) $$, (select admin_u from ids)),
  'PGRST',
  '{"code" : "administrador_unico", "message" : "administrador_unico", "details" : null, "hint" : null}',
  'Único administrador de estabelecimento com outros membros recebe 409 administrador_unico');

-- ── 4. Exclusão de profissional com turno futuro (Critério 5) ────────────────

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
  'Cancelamento por exclusão de conta não marca falta');

select is(
  (select verificacao from public.turno where id = (select turno_futuro from ids)),
  'nao_verificado'::public.verificacao_turno,
  'Turno cancelado fica com verificacao = nao_verificado');

select is(
  (select motivo from public.ocorrencia where posicao_id = (select pos_futura from ids)),
  'exclusão de conta',
  'Ocorrência de cancelamento registra motivo exclusão de conta');

-- Contraparte notificada (Critério 5)
select is(
  (select count(*) from public.notificacao
    where tipo = 'cancelamento'
      and referencia_id = (select pos_futura from ids)
      and usuario_id = (select admin_u from ids)),
  1::bigint,
  'Contraparte recebe notificação de cancelamento do turno futuro');

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

-- ── 5. Critério 1: Não recebe despacho e aparece anonimizado ─────────────────

select is(
  (select count(*) from privado.elegiveis((select vaga_solo from ids))
    where profissional_id = (select prof_p from ids)),
  0::bigint,
  'Conta excluída não recebe despacho (privado.elegiveis não a inclui)');

select is(
  (privado.perfil_publico_profissional((select prof_p from ids))->>'nome'),
  'Conta encerrada',
  'Perfil público do profissional mostra Conta encerrada');

-- ── 6. Critério 2: Histórico e reputação da contraparte mantidos ──────────────

select is(
  (select aval_positivas from public.estabelecimento where id = (select estab_com_membros from ids)),
  1,
  'Reputação da outra parte (positivas) não muda com a exclusão');

select is(
  (select aval_total from public.estabelecimento where id = (select estab_com_membros from ids)),
  1,
  'Reputação da outra parte (total) não muda com a exclusão');

-- ── 7. Critério 3: Token pré-emissão recusado em RPCs de escrita ─────────────

select throws_ok(
  format($$ select pg_temp.como(%L, format('select public.candidatar(%%L)', %L)) $$,
         (select prof_u from ids), (select vaga_solo from ids)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : "conta_encerrada", "hint" : null}',
  'Token emitido antes da exclusão é recusado em candidatar');

select throws_ok(
  format($$ select pg_temp.como(%L, format('select public.fazer_checkin(%%L::uuid, 10)', %L)) $$,
         (select prof_u from ids), (select turno_passado from ids)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : "conta_encerrada", "hint" : null}',
  'Token emitido antes da exclusão é recusado em fazer_checkin');

-- ── 8. Exclusão de contratante solo cancela vagas abertas ─────────────────────

select lives_ok(
  format($$ select privado.excluir_conta(%L) $$, (select admin_solo_u from ids)),
  'Único membro do estabelecimento pode excluir a conta');

select is(
  (select estado from public.vaga where id = (select vaga_solo from ids)),
  'cancelada'::public.estado_vaga,
  'Vaga aberta do estabelecimento sem membros é cancelada');

select is(
  (select estado from public.posicao where id = (select pos_solo from ids)),
  'cancelada'::public.estado_posicao,
  'Posição aberta da vaga sem membros é cancelada');

select * from finish();
rollback;
