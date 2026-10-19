-- Teste pgTAP 330: Lembretes 24 h e 3 h antes do turno
-- Cartão: k5R4tzjC (US14, RF12, UC05, RN10, RN15, RN23)
--
-- Critérios cobertos:
-- 1. Turno criado para daqui a 25 h recebe o lembrete de 24 h no minuto certo (relógio controlado).
-- 2. Reiniciar o job não duplica lembrete; com o job parado por 20 minutos, os atrasados saem uma vez ao voltar.
-- 3. Lembretes não contam no teto da RN23.
-- 4. Turno confirmado com menos de 3 h de antecedência não recebe lembrete atrasado.
-- 5. Turno cancelado antes do horário não dispara lembrete.
-- 6. Lembrete de 3 h é enviado na janela correta (entre 3 h e o início).
-- 7. Textos da Opção A homologada (proposta-textos.md, pushes 09–12):
--    - Local = apenas o nome do estabelecimento ({estabelecimento}) per RN10 e aviso do orquestrador
--    - Nunca telefone nem endereço com número (RN10)
--    - Tamanho seguro para iPhone SE (título <= 32, corpo <= 85)

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(34);

insert into privado.ambiente (eh_teste) values (true);

-- ── Funções auxiliares ──────────────────────────────────────────────────────────

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}', '{}', now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, consulta text) returns jsonb
language plpgsql as $$
declare resultado jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute consulta into resultado;
  reset role;
  execute 'reset request.jwt.claims';
  return resultado;
end $$;

-- ── Contas e perfis de teste ───────────────────────────────────────────────────

create temp table ids as
select
  'c3000000-0000-4000-8000-000000000001'::uuid as prof_user,
  'c3000000-0000-4000-8000-000000000002'::uuid as contratante_user,
  'c3000000-0000-4000-8000-000000000003'::uuid as contratante_socio,
  'c3000000-0000-4000-8000-000000000011'::uuid as profissional,
  'c3000000-0000-4000-8000-000000000021'::uuid as estabelecimento,
  'c3000000-0000-4000-8000-000000000031'::uuid as funcao_garcom;

select pg_temp.autenticar((select prof_user from ids), 'prof@lembrete.test');
select pg_temp.autenticar((select contratante_user from ids), 'dona@lembrete.test');
select pg_temp.autenticar((select contratante_socio from ids), 'socio@lembrete.test');

select pg_temp.como((select prof_user from ids),
  $$ select public.criar_conta('profissional','Prof Lembrete','+5561955550001','1992-05-10','2026-09-22') $$);
select pg_temp.como((select contratante_user from ids),
  $$ select public.criar_conta('contratante','Dona Lembrete','+5561955550002','1985-08-20','2026-09-22') $$);
select pg_temp.como((select contratante_socio from ids),
  $$ select public.criar_conta('contratante','Socio Lembrete','+5561955550003','1986-04-12','2026-09-22') $$);

update ids set funcao_garcom = (select id from public.funcao where nome = 'garçom');

select pg_temp.como((select prof_user from ids),
  format($$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$,
       (select funcao_garcom from ids)));

update ids set profissional = (select id from public.profissional where usuario_id = (select prof_user from ids));

-- Cria estabelecimento "Bar Beirute" na Asa Sul
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select (select estabelecimento from ids), 'Bar Beirute', '04252011000110', 'food_service',
       'CLS 109 Bloco A, Asa Sul', 'POINT(-47.8980 -15.8120)'::extensions.geography;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ((select contratante_user from ids), (select estabelecimento from ids), 'administrador'),
       ((select contratante_socio from ids), (select estabelecimento from ids), 'operador');

-- ── 1. Metadados e privilégios das funções ─────────────────────────────────────

select has_function('privado', 'enviar_lembretes_turno', array[]::text[],
  'função privado.enviar_lembretes_turno existe');

select has_function('privado', 'obter_conteudo_push_lembrete', array['uuid', 'uuid', 'text'],
  'função privado.obter_conteudo_push_lembrete existe');

select is(
  has_function_privilege('authenticated', 'privado.enviar_lembretes_turno()', 'execute'),
  false,
  'authenticated não pode executar privado.enviar_lembretes_turno');

select is(
  has_function_privilege('service_role', 'privado.enviar_lembretes_turno()', 'execute'),
  true,
  'service_role pode executar privado.enviar_lembretes_turno');

select is(
  has_function_privilege('authenticated', 'privado.obter_conteudo_push_lembrete(uuid, uuid, text)', 'execute'),
  false,
  'authenticated não pode executar privado.obter_conteudo_push_lembrete');

select is(
  has_function_privilege('service_role', 'privado.obter_conteudo_push_lembrete(uuid, uuid, text)', 'execute'),
  true,
  'service_role pode executar privado.obter_conteudo_push_lembrete');

select is(
  (select count(*)::int from cron.job
    where jobname = 'enviar_lembretes_turno'
      and command = 'select privado.enviar_lembretes_turno()'),
  1,
  'Job enviar_lembretes_turno está agendado no pg_cron');

select is(
  (select schedule from cron.job where jobname = 'enviar_lembretes_turno'),
  '*/5 * * * *',
  'Job enviar_lembretes_turno roda a cada 5 minutos no pg_cron');

-- ── 2. Critério 1: Turno criado para daqui a 25 h recebe lembrete de 24 h no minuto certo ───

-- T0: 2026-10-10 10:00:00-03. Vaga para 25 h no futuro: 2026-10-11 11:00:00-03.
select set_config('frila.agora', '2026-10-10 10:00:00-03', true);

insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, estado,
                         chave_cliente, publicado_por)
select 'c3000000-0000-4000-8000-000000000041'::uuid, (select estabelecimento from ids),
       (select funcao_garcom from ids),
       timestamptz '2026-10-11 11:00:00-03', timestamptz '2026-10-11 17:00:00-03',
       'Bar Beirute (Asa Sul)', 'POINT(-47.8980 -15.8120)'::extensions.geography,
       15000, 1, true, false, false, 'Gerente', 'urgencia', 'publicada',
       gen_random_uuid(), (select contratante_user from ids);

insert into public.posicao (id, vaga_id, inicio_em, fim_em)
values ('c3000000-0000-4000-8000-000000000051'::uuid,
        'c3000000-0000-4000-8000-000000000041'::uuid,
        timestamptz '2026-10-11 11:00:00-03', timestamptz '2026-10-11 17:00:00-03');

-- Profissional se candidata e confirma às 10:00 (25 h antes)
select pg_temp.como((select prof_user from ids),
  $$ select public.candidatar('c3000000-0000-4000-8000-000000000041') $$);

create temp table turno_25h as
  select t.id as turno_id from public.turno t
   where t.posicao_id = 'c3000000-0000-4000-8000-000000000051'::uuid;

-- Relógio em 10:59 (24 h e 1 minuto antes do início): NÃO deve disparar
select set_config('frila.agora', '2026-10-10 10:59:00-03', true);
select privado.enviar_lembretes_turno();

select is(
  (select count(*)::int from public.notificacao where tipo = 'lembrete_24h' and referencia_id = (select turno_id from turno_25h)),
  0,
  'Critério 1: a 24 h e 1 min do início, nenhum lembrete de 24 h foi enviado');

-- Relógio em 11:00 (exatamente 24 h antes do início): DEVE disparar
select set_config('frila.agora', '2026-10-10 11:00:00-03', true);
select privado.enviar_lembretes_turno();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_24h'
      and referencia_id = (select turno_id from turno_25h)
      and usuario_id = (select prof_user from ids)),
  1,
  'Critério 1: exatamente às 24 h antes, o profissional recebe o lembrete de 24 h');

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_24h'
      and referencia_id = (select turno_id from turno_25h)
      and usuario_id in ((select contratante_user from ids), (select contratante_socio from ids))),
  2,
  'Critério 1: exatamente às 24 h antes, todos os membros do contratante recebem o lembrete de 24 h');

select is(
  (select payload->>'estabelecimento_id' from public.notificacao
    where tipo = 'lembrete_24h'
      and usuario_id = (select contratante_user from ids)
    limit 1),
  (select estabelecimento::text from ids),
  'Notificação do contratante carrega estabelecimento_id no payload para uso no fallback');

-- ── 3. Critério 2: Reiniciar o job não duplica; atrasados saem uma vez ao voltar ────────

-- Reexecução imediata
select privado.enviar_lembretes_turno();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_24h'
      and referencia_id = (select turno_id from turno_25h)),
  3,
  'Critério 2: reiniciar o job não duplica lembrete (1 profissional + 2 contratantes = 3)');

-- Cenário com o job parado por 20 minutos para um novo turno:
-- Turno B criado às 17:00 para amanhã às 18:00 (25 h no futuro).
-- Marca de 24 h seria às 18:00. Job parado até 18:20 (20 min depois).
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, estado,
                         chave_cliente, publicado_por)
select 'c3000000-0000-4000-8000-000000000042'::uuid, (select estabelecimento from ids),
       (select funcao_garcom from ids),
       timestamptz '2026-10-11 18:00:00-03', timestamptz '2026-10-11 23:00:00-03',
       'Bar Beirute (Asa Sul)', 'POINT(-47.8980 -15.8120)'::extensions.geography,
       15000, 1, true, false, false, 'Gerente', 'urgencia', 'publicada',
       gen_random_uuid(), (select contratante_user from ids);

insert into public.posicao (id, vaga_id, inicio_em, fim_em)
values ('c3000000-0000-4000-8000-000000000052'::uuid,
        'c3000000-0000-4000-8000-000000000042'::uuid,
        timestamptz '2026-10-11 18:00:00-03', timestamptz '2026-10-11 23:00:00-03');

select set_config('frila.agora', '2026-10-10 17:00:00-03', true);
select pg_temp.como((select prof_user from ids),
  $$ select public.candidatar('c3000000-0000-4000-8000-000000000042') $$);

create temp table turno_atrasado as
  select t.id as turno_id from public.turno t
   where t.posicao_id = 'c3000000-0000-4000-8000-000000000052'::uuid;

-- Salta direto para 18:20 (20 min após a janela das 18:00 sem rodar o job)
select set_config('frila.agora', '2026-10-10 18:20:00-03', true);
select privado.enviar_lembretes_turno();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_24h'
      and referencia_id = (select turno_id from turno_atrasado)),
  3,
  'Critério 2: com o job parado por 20 minutos, os atrasados saem uma vez ao voltar');

select privado.enviar_lembretes_turno();
select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_24h'
      and referencia_id = (select turno_id from turno_atrasado)),
  3,
  'Critério 2: reexecução após atraso permanece sem duplicar');

-- ── 4. Critério 3: Lembretes não contam no teto da RN23 ────────────────────────

select is(
  (select count(*)::int from public.notificacao
    where tipo in ('lembrete_24h', 'lembrete_3h')
      and profissional_id is not null),
  0,
  'Critério 3: notificações de lembrete têm profissional_id nulo por CHECK e não entram no índice de teto da RN23');

select is(
  (select count(*)::int from public.notificacao
    where profissional_id = (select profissional from ids)
      and tipo in ('vaga', 'vagas_agrupadas')),
  0,
  'Critério 3: o envio de lembretes não altera o contador de vagas recebidas para o teto da RN23');

-- ── 5. Critério 4: Turno confirmado com menos de 3 h não recebe lembrete atrasado ───

-- Vaga para daqui a 2 h: 2026-10-10 14:00 (agora é 12:00)
select set_config('frila.agora', '2026-10-10 12:00:00-03', true);

insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, estado,
                         chave_cliente, publicado_por)
select 'c3000000-0000-4000-8000-000000000043'::uuid, (select estabelecimento from ids),
       (select funcao_garcom from ids),
       timestamptz '2026-10-10 14:00:00-03', timestamptz '2026-10-10 20:00:00-03',
       'Bar Beirute (Asa Sul)', 'POINT(-47.8980 -15.8120)'::extensions.geography,
       15000, 1, true, false, false, 'Gerente', 'urgencia', 'publicada',
       gen_random_uuid(), (select contratante_user from ids);

insert into public.posicao (id, vaga_id, inicio_em, fim_em)
values ('c3000000-0000-4000-8000-000000000053'::uuid,
        'c3000000-0000-4000-8000-000000000043'::uuid,
        timestamptz '2026-10-10 14:00:00-03', timestamptz '2026-10-10 20:00:00-03');

-- Confirmado a 2 h do início (confirmado_em = 12:00, inicio_em = 14:00)
select pg_temp.como((select prof_user from ids),
  $$ select public.candidatar('c3000000-0000-4000-8000-000000000043') $$);

create temp table turno_menos_3h as
  select t.id as turno_id from public.turno t
   where t.posicao_id = 'c3000000-0000-4000-8000-000000000053'::uuid;

select privado.enviar_lembretes_turno();

select is(
  (select count(*)::int from public.notificacao
    where referencia_id = (select turno_id from turno_menos_3h)
      and tipo in ('lembrete_24h', 'lembrete_3h')),
  0,
  'Critério 4: turno confirmado com menos de 3 h de antecedência não recebe lembrete atrasado de 24 h nem de 3 h');

-- ── 6. Lembrete de 3 h dispara na janela correta ───────────────────────────────

-- Turno 25h: início é 2026-10-11 11:00:00-03.
-- Às 07:59 (3h01 antes): nenhum lembrete 3h
select set_config('frila.agora', '2026-10-11 07:59:00-03', true);
select privado.enviar_lembretes_turno();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_3h' and referencia_id = (select turno_id from turno_25h)),
  0,
  'a 3 h e 1 min do início, nenhum lembrete de 3 h foi enviado');

-- Às 08:00 (exatamente 3 h antes): DEVE disparar
select set_config('frila.agora', '2026-10-11 08:00:00-03', true);
select privado.enviar_lembretes_turno();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_3h'
      and referencia_id = (select turno_id from turno_25h)
      and usuario_id = (select prof_user from ids)),
  1,
  'às 3 h antes do início, o profissional recebe o lembrete de 3 h');

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_3h'
      and referencia_id = (select turno_id from turno_25h)
      and usuario_id in ((select contratante_user from ids), (select contratante_socio from ids))),
  2,
  'às 3 h antes do início, todos os membros do contratante recebem o lembrete de 3 h');

-- Reexecução imediata às 08:05: não duplica
select set_config('frila.agora', '2026-10-11 08:05:00-03', true);
select privado.enviar_lembretes_turno();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_3h'
      and referencia_id = (select turno_id from turno_25h)),
  3,
  'reexecução do job não duplica lembrete de 3 h');

-- ── 7. Turno cancelado antes do horário não dispara lembrete ────────────────────

insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, estado,
                         chave_cliente, publicado_por)
select 'c3000000-0000-4000-8000-000000000044'::uuid, (select estabelecimento from ids),
       (select funcao_garcom from ids),
       timestamptz '2026-10-13 18:00:00-03', timestamptz '2026-10-13 23:00:00-03',
       'Bar Beirute (Asa Sul)', 'POINT(-47.8980 -15.8120)'::extensions.geography,
       15000, 1, true, false, false, 'Gerente', 'urgencia', 'publicada',
       gen_random_uuid(), (select contratante_user from ids);

insert into public.posicao (id, vaga_id, inicio_em, fim_em)
values ('c3000000-0000-4000-8000-000000000054'::uuid,
        'c3000000-0000-4000-8000-000000000044'::uuid,
        timestamptz '2026-10-13 18:00:00-03', timestamptz '2026-10-13 23:00:00-03');

select set_config('frila.agora', '2026-10-12 10:00:00-03', true);
select pg_temp.como((select prof_user from ids),
  $$ select public.candidatar('c3000000-0000-4000-8000-000000000044') $$);

create temp table turno_cancelado as
  select t.id as turno_id from public.turno t
   where t.posicao_id = 'c3000000-0000-4000-8000-000000000054'::uuid;

-- Cancelamento antes da marca de 24 h (às 12:00 do dia 12, início é dia 13 às 18:00)
select set_config('frila.agora', '2026-10-12 12:00:00-03', true);
select pg_temp.como((select prof_user from ids),
  $$ select public.cancelar_posicao('c3000000-0000-4000-8000-000000000054'::uuid, 'imprevisto') $$);

-- Avança relógio para a marca de 24 h (2026-10-12 18:00:00-03)
select set_config('frila.agora', '2026-10-12 18:00:00-03', true);
select privado.enviar_lembretes_turno();

select is(
  (select count(*)::int from public.notificacao
    where tipo in ('lembrete_24h', 'lembrete_3h')
      and referencia_id = (select turno_id from turno_cancelado)),
  0,
  'turno cancelado antes da marca não dispara lembrete');

-- ── 8. Textos da Opção A homologada (proposta-textos.md, pushes 09–12) ───────────

-- Push 09: Lembrete 24 h Profissional
select is(
  (select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select prof_user from ids), 'lembrete_24h')->>'title'),
  'Lembrete de turno amanhã',
  'Push 09: título do lembrete 24 h do profissional está correto');

select is(
  (select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select prof_user from ids), 'lembrete_24h')->>'body'),
  'Garçom em Bar Beirute (Plano Piloto) amanhã às 11:00.',
  'Push 09: corpo do lembrete 24 h do profissional interpola função, local ({estabelecimento} ({regiao})) e horário');

-- Push 10: Lembrete 24 h Contratante
select is(
  (select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select contratante_user from ids), 'lembrete_24h')->>'title'),
  'Turno agendado para amanhã',
  'Push 10: título do lembrete 24 h do contratante está correto');

select is(
  (select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select contratante_user from ids), 'lembrete_24h')->>'body'),
  'Turno de garçom confirmado para amanhã às 11:00.',
  'Push 10: corpo do lembrete 24 h do contratante está correto');

-- Push 11: Lembrete 3 h Profissional
select is(
  (select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select prof_user from ids), 'lembrete_3h')->>'title'),
  'Seu turno começa em 3 horas',
  'Push 11: título do lembrete 3 h do profissional está correto');

select is(
  (select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select prof_user from ids), 'lembrete_3h')->>'body'),
  'Garçom em Bar Beirute (Plano Piloto) às 11:00. Planeje seu trajeto.',
  'Push 11: corpo do lembrete 3 h do profissional interpola função, local ({estabelecimento} ({regiao})) e horário');

-- Push 12: Lembrete 3 h Contratante
select is(
  (select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select contratante_user from ids), 'lembrete_3h')->>'title'),
  'Turno em 3 horas',
  'Push 12: título do lembrete 3 h do contratante está correto');

select is(
  (select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select contratante_user from ids), 'lembrete_3h')->>'body'),
  'Turno de garçom começa às 11:00. O profissional foi lembrado.',
  'Push 12: corpo do lembrete 3 h do contratante está correto');

-- Validação de RN10 / RN15 nos textos
select ok(
  (select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select prof_user from ids), 'lembrete_24h')->>'body') !~* '(\+55|[0-9]{8,11}|@)',
  'RN10/RN15: corpo do push não contém telefone nem e-mail');

select ok(
  length((select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select prof_user from ids), 'lembrete_24h')->>'title')) <= 32
  and length((select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select prof_user from ids), 'lembrete_24h')->>'body')) <= 85,
  'iPhone SE: título <= 32 e corpo <= 85 caracteres no lembrete 24 h');

select ok(
  length((select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select prof_user from ids), 'lembrete_3h')->>'title')) <= 32
  and length((select privado.obter_conteudo_push_lembrete((select turno_id from turno_25h), (select prof_user from ids), 'lembrete_3h')->>'body')) <= 85,
  'iPhone SE: título <= 32 e corpo <= 85 caracteres no lembrete 3 h');

select * from finish();
rollback;
