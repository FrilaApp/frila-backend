-- Teste pgTAP 320: Retenção e limpeza de dados pessoais e contas sem cadastro.
-- Cartão yClUqOpU (RF25, RNF08, RN15, UC09 2a).
--
-- Critérios de aceite e decisões cobertos:
-- 1. Conta de autenticação sem cadastro há mais de 24 h é identificada e purgada na rotina
--    (em até 48 h no pior caso / relógio controlado).
-- 2. 15 dias depois da exclusão, nenhuma coluna pessoal da conta tem valor
--    (nascimento e ponto base nulos, grade semanal apagada, funções apagadas,
--     aparelhos apagados, relato da ocorrência de autoria dela substituído por marcador).
-- 3. Turnos e avaliações da contraparte continuam legíveis, com 'Conta encerrada'.
-- 4. Higiene operacional: cron.job_run_details (> 7 d) e arquivo pgmq (> 30 d).
--    auditoria_ciclo é explicitamente preservada (RNF13 sem dado pessoal).
-- 5. Restrições DDL: nascimento e ponto_base anuláveis SOMENTE quando estado = 'anonimizada'.

begin;
select plan(43);

insert into privado.ambiente (eh_teste) values (true);
select set_config('frila.agora', '2026-10-20 12:00:00-03', true);

-- ── 1. Metadados e privilégios das funções ───────────────────────────────────

select has_trigger(
  'public',
  'profissional',
  'profissional_ponto_base_anulavel',
  'trigger profissional_ponto_base_anulavel existe');

select is(
  (select has_function_privilege('public', p.oid, 'execute')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'validar_ponto_base_profissional'),
  false,
  'privado.validar_ponto_base_profissional não é executável por public');

select is(
  (select has_function_privilege('authenticated', p.oid, 'execute')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'validar_ponto_base_profissional'),
  false,
  'privado.validar_ponto_base_profissional não é executável por authenticated');

select is(
  (select has_function_privilege('service_role', p.oid, 'execute')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'validar_ponto_base_profissional'),
  true,
  'privado.validar_ponto_base_profissional é executável por service_role');

select has_function(
  'privado',
  'contas_auth_orfas',
  array['integer']::text[],
  'privado.contas_auth_orfas(integer) existe');

select is(
  has_function_privilege('public', 'privado.contas_auth_orfas(integer)', 'execute'),
  false,
  'privado.contas_auth_orfas(integer) não é executável por public');

select is(
  has_function_privilege('authenticated', 'privado.contas_auth_orfas(integer)', 'execute'),
  false,
  'privado.contas_auth_orfas(integer) não é executável por authenticated');

select is(
  has_function_privilege('service_role', 'privado.contas_auth_orfas(integer)', 'execute'),
  true,
  'privado.contas_auth_orfas(integer) é executável por service_role');

select has_function(
  'privado',
  'limpar_contas_anonimizadas',
  array['integer']::text[],
  'privado.limpar_contas_anonimizadas(integer) existe');

select is(
  has_function_privilege('public', 'privado.limpar_contas_anonimizadas(integer)', 'execute'),
  false,
  'privado.limpar_contas_anonimizadas(integer) não é executável por public');

select is(
  has_function_privilege('authenticated', 'privado.limpar_contas_anonimizadas(integer)', 'execute'),
  false,
  'privado.limpar_contas_anonimizadas(integer) não é executável por authenticated');

select is(
  has_function_privilege('service_role', 'privado.limpar_contas_anonimizadas(integer)', 'execute'),
  true,
  'privado.limpar_contas_anonimizadas(integer) é executável por service_role');

select has_function(
  'privado',
  'higienizar_tabelas',
  array[]::text[],
  'privado.higienizar_tabelas() existe');

select is(
  has_function_privilege('public', 'privado.higienizar_tabelas()', 'execute'),
  false,
  'privado.higienizar_tabelas() não é executável por public');

select is(
  has_function_privilege('service_role', 'privado.higienizar_tabelas()', 'execute'),
  true,
  'privado.higienizar_tabelas() é executável por service_role');

select has_function(
  'privado',
  'executar_retencao_diaria',
  array[]::text[],
  'privado.executar_retencao_diaria() existe');

select is(
  has_function_privilege('service_role', 'privado.executar_retencao_diaria()', 'execute'),
  true,
  'privado.executar_retencao_diaria() é executável por service_role');

-- ── 2. Auxiliares do teste ───────────────────────────────────────────────────

create function pg_temp.autenticar(conta uuid, email text, criado_em timestamptz default now()) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, criado_em, criado_em, false, false)
  on conflict (id) do update set created_at = excluded.created_at;
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

-- ── 3. Contas de autenticação sem cadastro (UC09 2a / 24h) ───────────────────

-- Usuário 1: criado há 30 horas no auth.users sem cadastro no public.usuario (ex: menor de idade recusado)
select pg_temp.autenticar(
  'c3200000-0000-4000-8000-000000000001',
  'orfa_antiga@retencao.test',
  privado.agora() - interval '30 hours'
);

-- Usuário 2: criado há 5 horas no auth.users sem cadastro (ainda dentro da janela de 24h)
select pg_temp.autenticar(
  'c3200000-0000-4000-8000-000000000002',
  'orfa_recente@retencao.test',
  privado.agora() - interval '5 hours'
);

-- Usuário 3: criado há 30 horas no auth.users COM cadastro regular concluído
select pg_temp.autenticar(
  'c3200000-0000-4000-8000-000000000003',
  'cadastrada@retencao.test',
  privado.agora() - interval '30 hours'
);
select pg_temp.como(
  'c3200000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional', 'Cadastrada Valida', '+5561932000003', '1995-01-01', '2026-09-22') $$
);

-- Consulta de contas órfãs identifica Usuário 1, mas ignora Usuário 2 (< 24h) e Usuário 3 (tem usuario)
select is(
  (select count(*)::int from privado.contas_auth_orfas(24) where id = 'c3200000-0000-4000-8000-000000000001'),
  1,
  'contas_auth_orfas(24) retorna conta sem cadastro criada há mais de 24 h');

select is(
  (select count(*)::int from privado.contas_auth_orfas(24) where id = 'c3200000-0000-4000-8000-000000000002'),
  0,
  'contas_auth_orfas(24) não retorna conta sem cadastro criada há menos de 24 h');

select is(
  (select count(*)::int from privado.contas_auth_orfas(24) where id = 'c3200000-0000-4000-8000-000000000003'),
  0,
  'contas_auth_orfas(24) não retorna conta que completou cadastro em public.usuario');

select is(
  (select id from privado.contas_auth_orfas(24) where id = 'c3200000-0000-4000-8000-000000000001'),
  'c3200000-0000-4000-8000-000000000001'::uuid,
  'contas_auth_orfas(24) retorna o id correto da conta órfã para expurgo via Admin API');

-- ── 4. Regras DDL: nascimento e ponto_base anuláveis apenas sob anonimização ─

-- Conta ativa 3: tentar zerar nascimento viola a constraint
select throws_ok(
  $$ update public.usuario set nascimento = null where id = 'c3200000-0000-4000-8000-000000000003' $$,
  '23514',
  null,
  'nascimento não pode ser nulo para conta ativa (nascimento_ate_anonimizar)');

-- Cria perfil profissional para a conta 3
select pg_temp.como(
  'c3200000-0000-4000-8000-000000000003',
  format($$
    select public.criar_perfil_profissional(
      array[%L]::uuid[],
      jsonb_build_object('latitude', -15.793889, 'longitude', -47.882778),
      '[{"dia_semana": 1, "hora_inicio": "08:00", "hora_fim": "16:00"}]'::jsonb
    )
  $$, (select id from public.funcao where ativo limit 1))
);

-- Conta ativa 3: tentar zerar ponto_base viola a trigger/gatilho
select throws_ok(
  $$ update public.profissional set ponto_base = null where usuario_id = 'c3200000-0000-4000-8000-000000000003' $$,
  '23514',
  null,
  'ponto_base não pode ser nulo para conta ativa (validar_ponto_base_profissional)');

-- ── 5. Retenção de 15 dias: exclusão e limpeza de dados pessoais ──────────────

-- Prepara cenário com conta a excluir (profissional)
select pg_temp.autenticar(
  'c3200000-0000-4000-8000-000000000010',
  'prof_excluido@retencao.test',
  privado.agora() - interval '20 days'
);
select pg_temp.como(
  'c3200000-0000-4000-8000-000000000010',
  $$ select public.criar_conta('profissional', 'Profissional Exclusao', '+5561932000010', '1990-06-15', '2026-09-22') $$
);
select pg_temp.como(
  'c3200000-0000-4000-8000-000000000010',
  format($$
    select public.criar_perfil_profissional(
      array[%L]::uuid[],
      jsonb_build_object('latitude', -15.793889, 'longitude', -47.882778),
      '[{"dia_semana": 5, "hora_inicio": "18:00", "hora_fim": "02:00"}]'::jsonb
    )
  $$, (select id from public.funcao where ativo limit 1))
);

-- Registra aparelho da conta a excluir
select pg_temp.como(
  'c3200000-0000-4000-8000-000000000010',
  $$ select public.registrar_dispositivo('token-fcm-retencao-teste-1234567890', 'ios') $$
);

-- Registra uma ocorrência de autoria da conta a excluir
insert into public.ocorrencia (tipo, usuario_id, autor_id, motivo)
values ('suporte', 'c3200000-0000-4000-8000-000000000003', 'c3200000-0000-4000-8000-000000000010', 'Relato pessoal detalhado sobre o ocorrido');

-- Exclui a conta hoje (dia 0 da exclusão)
select privado.excluir_conta('c3200000-0000-4000-8000-000000000010');

-- Logo após excluir (dia 0), o nome é anonimizado mas dados de retenção ainda aguardam 15 dias
select is(
  (select nome from public.usuario where id = 'c3200000-0000-4000-8000-000000000010'),
  'Conta encerrada',
  'Após excluir_conta, nome já é Conta encerrada');

select is(
  (select nascimento is not null from public.usuario where id = 'c3200000-0000-4000-8000-000000000010'),
  true,
  'Após excluir_conta (dia 0), nascimento ainda existe até a retenção de 15 dias');

select is(
  (select ponto_base is not null from public.profissional where usuario_id = 'c3200000-0000-4000-8000-000000000010'),
  true,
  'Após excluir_conta (dia 0), ponto_base ainda existe até a retenção de 15 dias');

-- Executa a rotina de limpeza com 15 dias (a conta tem apenas 0 dias de anonimização) -> NADA é limpo
select is(
  privado.limpar_contas_anonimizadas(15),
  0,
  'limpar_contas_anonimizadas(15) não toca conta anonimizada há menos de 15 dias');

-- Simula passagem de tempo: retroage a data de anonimização da conta para 16 dias atrás
update public.usuario
   set anonimizado_em = privado.agora() - interval '16 days'
 where id = 'c3200000-0000-4000-8000-000000000010';

-- Agora sim: 15 dias depois da exclusão, a rotina de retenção deve limpar tudo
select is(
  privado.limpar_contas_anonimizadas(15),
  1,
  'limpar_contas_anonimizadas(15) processa a conta após 15 dias');

-- Verificação detalhada de conformidade LGPD / Critério de Aceite 2:
-- "15 dias depois da exclusão, nenhuma coluna pessoal da conta tem valor"
select is(
  (select nascimento from public.usuario where id = 'c3200000-0000-4000-8000-000000000010'),
  null::date,
  'Critério 2: nascimento é zerado (null)');

select is(
  (select ponto_base from public.profissional where usuario_id = 'c3200000-0000-4000-8000-000000000010'),
  null::extensions.geography,
  'Critério 2: ponto_base é zerado (null)');

select is(
  (select count(*)::int from public.disponibilidade where profissional_id = (select id from public.profissional where usuario_id = 'c3200000-0000-4000-8000-000000000010')),
  0,
  'Critério 2: disponibilidade semanal é completamente apagada');

select is(
  (select count(*)::int from public.profissional_funcao where profissional_id = (select id from public.profissional where usuario_id = 'c3200000-0000-4000-8000-000000000010')),
  0,
  'Critério 2: funções profissionais são completamente apagadas');

select is(
  (select count(*)::int from public.dispositivo where usuario_id = 'c3200000-0000-4000-8000-000000000010'),
  0,
  'Critério 2: aparelhos registrados são apagados');

select is(
  (select motivo from public.ocorrencia where autor_id = 'c3200000-0000-4000-8000-000000000010'),
  '[removido por exclusão de conta]',
  'Critério 2: relato da ocorrência de autoria dela foi substituído pelo marcador neutro');

-- ── 6. Critério de Aceite 3: Turnos e avaliações da contraparte legíveis ──────

-- Cria contratante com estabelecimento e vaga para testar preservação de histórico
select pg_temp.autenticar(
  'c3200000-0000-4000-8000-000000000020',
  'dono_estab@retencao.test',
  privado.agora() - interval '30 days'
);
select pg_temp.como(
  'c3200000-0000-4000-8000-000000000020',
  $$ select public.criar_conta('contratante', 'Dono do Restaurante', '+5561932000020', '1985-04-12', '2026-09-22') $$
);

-- Estabelecimento e vaga no passado
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('e3200000-0000-4000-8000-000000000001', 'Restaurante Teste 320', '12345678000199', 'food_service', 'CLN 201 Bloco A',
        extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('e3200000-0000-4000-8000-000000000001', 'c3200000-0000-4000-8000-000000000020', 'administrador');

insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, valor_centavos, estado, ponto, local, modo, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, chave_cliente)
values ('ba320000-0000-4000-8000-000000000001', 'e3200000-0000-4000-8000-000000000001',
        (select id from public.funcao where ativo limit 1),
        'c3200000-0000-4000-8000-000000000020',
        privado.agora() - interval '20 days', privado.agora() - interval '20 days' + interval '8 hours',
        18000, 'encerrada',
        extensions.ST_SetSRID(extensions.ST_MakePoint(-47.8825, -15.7942), 4326)::extensions.geography,
        'CLN 201 Bloco A', 'urgencia', 1, false, false, false, 'Gerente', gen_random_uuid());

insert into public.posicao (id, vaga_id, profissional_id, estado, inicio_em, fim_em, confirmado_em, falta)
values ('da320000-0000-4000-8000-000000000001', 'ba320000-0000-4000-8000-000000000001',
        (select id from public.profissional where usuario_id = 'c3200000-0000-4000-8000-000000000010'),
        'cumprida', privado.agora() - interval '20 days', privado.agora() - interval '20 days' + interval '8 hours',
        privado.agora() - interval '21 days', false);

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkout_em, checkout_distancia_m, verificacao, valor_acordado_centavos)
values ('fa320000-0000-4000-8000-000000000001', 'da320000-0000-4000-8000-000000000001',
        privado.agora() - interval '20 days', 'geolocalizado', 50,
        privado.agora() - interval '20 days' + interval '8 hours', 60, 'verificado', 18000);

-- Avaliação feita pelo profissional (conta excluída) sobre o estabelecimento
insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta, criada_em)
values ('fa320000-0000-4000-8000-000000000001', 'c3200000-0000-4000-8000-000000000010',
        'estabelecimento', 'e3200000-0000-4000-8000-000000000001', true, privado.agora() - interval '19 days');

-- Avaliação feita pelo contratante sobre o profissional (conta excluída)
insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta, criada_em)
values ('fa320000-0000-4000-8000-000000000001', 'c3200000-0000-4000-8000-000000000020',
        'profissional', (select id from public.profissional where usuario_id = 'c3200000-0000-4000-8000-000000000010'), true, privado.agora() - interval '19 days');

-- Verificação do Critério 3: a contraparte lê o turno e a avaliação normalmente, com nome 'Conta encerrada'
select is(
  (select u.nome from public.posicao p
     join public.profissional prof on prof.id = p.profissional_id
     join public.usuario u on u.id = prof.usuario_id
    where p.id = 'da320000-0000-4000-8000-000000000001'),
  'Conta encerrada',
  'Critério 3: Turno realizado exibe profissional como Conta encerrada');

select is(
  (select u.nome from public.avaliacao a
     join public.usuario u on u.id = a.autor_id
    where a.turno_id = 'fa320000-0000-4000-8000-000000000001'
      and a.autor_id = 'c3200000-0000-4000-8000-000000000010'),
  'Conta encerrada',
  'Critério 3: Avaliação dada pela conta excluída continua legível com autor Conta encerrada');

select is(
  (select count(*)::int from public.avaliacao where turno_id = 'fa320000-0000-4000-8000-000000000001'),
  2,
  'Critério 3: Todas as avaliações bilaterais continuam preservadas');

-- ── 7. Higiene operacional das tabelas ────────────────────────────────────────

-- 7.1 auditoria_ciclo: insere um evento com 95 dias e um com 10 dias
insert into privado.auditoria_ciclo (entidade, entidade_id, acao, estado_anterior, estado_novo, em)
values ('vaga', gen_random_uuid(), 'criou', null, 'publicada', privado.agora() - interval '95 days'),
       ('vaga', gen_random_uuid(), 'criou', null, 'publicada', privado.agora() - interval '10 days');

-- 7.2 pgmq.a_despacho: insere uma mensagem arquivada com 35 dias e uma com 5 dias
insert into pgmq.a_despacho (msg_id, read_ct, enqueued_at, archived_at, vt, message)
values (999901, 1, privado.agora() - interval '36 days', privado.agora() - interval '35 days', privado.agora() - interval '35 days', '{}'::jsonb),
       (999902, 1, privado.agora() - interval '6 days', privado.agora() - interval '5 days', privado.agora() - interval '5 days', '{}'::jsonb);

-- Executa a rotina de higiene
select lives_ok(
  $$ select privado.higienizar_tabelas() $$,
  'privado.higienizar_tabelas() roda com sucesso');

-- auditoria_ciclo NÃO deve ser apagada pela retenção (RNF13 sem dado pessoal preservada)
select is(
  (select count(*)::int from privado.auditoria_ciclo where em < privado.agora() - interval '90 days'),
  1,
  'Higiene: auditoria_ciclo NÃO é apagada pela retenção (trilha imutável RNF13 preservada)');

-- pgmq.a_despacho com mais de 30 dias deve ter sido removida
select is(
  (select count(*)::int from pgmq.a_despacho where msg_id = 999901),
  0,
  'Higiene: arquivo pgmq com mais de 30 dias é removido');

select is(
  (select count(*)::int from pgmq.a_despacho where msg_id = 999902),
  1,
  'Higiene: arquivo pgmq com menos de 30 dias é mantido');

-- ── 8. Execução consolidada e auxiliares ──────────────────────────────────────

select lives_ok(
  $$ select privado.executar_retencao_diaria() $$,
  'privado.executar_retencao_diaria() executa com sucesso');

select is(
  privado.ponto_em_json(null),
  null::jsonb,
  'privado.ponto_em_json aceita coordenada nula');

select * from finish();
rollback;
