-- 520_suspensao_da_conta.sql
--
-- Cartão BsXIZHOw (Épico 7 · US23 · RF24, RN13, UC15):
-- Suspensão, situacao_da_conta e contestar_suspensao.
--
-- 1. Permissões de chamada das RPCs e funções operacionais.
-- 2. Recusa de chamadas não autenticadas (401).
-- 3. Suspensão sem motivo recusada com 422 campo_obrigatorio.
-- 4. privado.suspender altera estado para 'suspensa', grava ocorrencia e enfileira push sem motivo.
-- 5. Conta suspensa sai do despacho e não candidata (403 sem_permissao, conta_suspensa).
-- 6. Escritas gerais são bloqueadas para conta suspensa com 403 conta_suspensa.
-- 7. Conta suspensa consegue registrar/remover dispositivo, ler situacao_da_conta, exportar dados e contestar.
-- 8. Contestação valida relato (>= 10 caracteres), devolve Protocolo e envia e-mail para a fila.
-- 9. situacao_da_conta reflete a contestação aberta.
-- 10. Segunda contestação devolve 409 contestacao_ja_aberta.
-- 11. Contestação sem suspensão ativa devolve 422 sem_suspensao_ativa.
-- 12. situacao_da_conta para conta ativa devolve {estado: 'ativa', suspensao: null}.
-- 13. Reativação devolve a conta ao despacho imediatamente e enfileira push sem motivo.
-- 14. Conta suspensa pode excluir a conta.

begin;
select plan(40);

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

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- ── 1. Privilégios e assinaturas ───────────────────────────────────────────────

select ok(
  has_function_privilege('authenticated', 'public.situacao_da_conta()', 'execute'),
  'authenticated executa public.situacao_da_conta'
);

select ok(
  not has_function_privilege('anon', 'public.situacao_da_conta()', 'execute'),
  'anon não executa public.situacao_da_conta'
);

select ok(
  has_function_privilege('authenticated', 'public.contestar_suspensao(text)', 'execute'),
  'authenticated executa public.contestar_suspensao'
);

select ok(
  not has_function_privilege('anon', 'public.contestar_suspensao(text)', 'execute'),
  'anon não executa public.contestar_suspensao'
);

select ok(
  not has_function_privilege('authenticated', 'privado.suspender(uuid, text, uuid)', 'execute'),
  'authenticated não executa privado.suspender'
);

select ok(
  has_function_privilege('service_role', 'privado.suspender(uuid, text, uuid)', 'execute'),
  'service_role executa privado.suspender'
);

select ok(
  not has_function_privilege('authenticated', 'privado.reativar(uuid, text, uuid)', 'execute'),
  'authenticated não executa privado.reativar'
);

select ok(
  has_function_privilege('service_role', 'privado.reativar(uuid, text, uuid)', 'execute'),
  'service_role executa privado.reativar'
);

-- ── 2. Não autenticado (401) ───────────────────────────────────────────────────

select throws_ok(
  $$ select public.situacao_da_conta() $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'situacao_da_conta sem token devolve 401'
);

select throws_ok(
  $$ select public.contestar_suspensao('Contestação com texto válido suficiente') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'contestar_suspensao sem token devolve 401'
);

-- ── 3. Cenário de teste ────────────────────────────────────────────────────────
--
-- Prefixo `f7`
-- Operador Frila: f7000001
-- Profissional:   f7000002 (Eduardo)
-- Contratante:    f7000003 (Cláudio)
-- Estabelecimento: f7000010
-- Vaga:           f7000020
-- Posição:        f7000030

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado) values
  ('f7000000-0000-4000-8000-000000000001', 'contratante', 'Operador Equipe', '+5561999990001', 'operador@frila.test', '1990-01-01', '2026-09-22', now(), 'ativa'),
  ('f7000000-0000-4000-8000-000000000002', 'profissional', 'Eduardo Prof',   '+5561999990002', 'eduardo@f7.test',    '1995-05-10', '2026-09-22', now(), 'ativa'),
  ('f7000000-0000-4000-8000-000000000003', 'contratante',  'Cláudio Dono',   '+5561999990003', 'claudio@f7.test',    '1985-08-20', '2026-09-22', now(), 'ativa');

insert into privado.conta_equipe (usuario_id) values ('f7000000-0000-4000-8000-000000000001');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('f7000000-0000-4000-8000-000000000011', 'f7000000-0000-4000-8000-000000000002',
   'POINT(-47.8825 -15.7942)'::extensions.geography);

insert into public.profissional_funcao (profissional_id, funcao_id)
select 'f7000000-0000-4000-8000-000000000011', id from public.funcao where nome = 'garçom' limit 1;

-- Disponibilidade para todos os dias
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select 'f7000000-0000-4000-8000-000000000011', d, '00:00:00'::time, '23:59:59'::time
  from generate_series(0, 6) d;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('f7000000-0000-4000-8000-000000000010', 'Bar do F7', '52141555000199', 'food_service', 'CLS 405 Bloco C',
   'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('f7000000-0000-4000-8000-000000000010', 'f7000000-0000-4000-8000-000000000003', 'administrador');

-- Vaga para garçom
insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por
) values (
  'f7000000-0000-4000-8000-000000000020',
  'f7000000-0000-4000-8000-000000000010',
  (select id from public.funcao where nome = 'garçom' limit 1),
  'POINT(-47.8825 -15.7942)'::extensions.geography,
  'Bar do F7',
  15000,
  1,
  true, false, false, 'Gerente',
  privado.agora() + interval '3 hours',
  privado.agora() + interval '9 hours',
  'urgencia',
  'publicada',
  'Plano Piloto',
  gen_random_uuid(),
  'f7000000-0000-4000-8000-000000000003'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado) values (
  'f7000000-0000-4000-8000-000000000030',
  'f7000000-0000-4000-8000-000000000020',
  privado.agora() + interval '3 hours',
  privado.agora() + interval '9 hours',
  'aberta'
);

-- Assegura fila email criada
do $$
begin
  if not exists (select 1 from pgmq.meta where queue_name = 'email') then
    perform pgmq.create('email');
  end if;
end $$;

-- ── 4. Profissional ativo: elegibilidade e situacao_da_conta ───────────────────

select is(
  (select count(*)::int from privado.elegiveis('f7000000-0000-4000-8000-000000000020', null) e
    where e.profissional_id = 'f7000000-0000-4000-8000-000000000011'),
  1,
  'profissional ativo é retornado por privado.elegiveis'
);

select is(
  pg_temp.como('f7000000-0000-4000-8000-000000000002', 'select public.situacao_da_conta()'),
  jsonb_build_object('estado', 'ativa', 'suspensao', null),
  'conta ativa tem situacao_da_conta com estado ativa e suspensao nula'
);

select throws_ok(
  $$ select pg_temp.como('f7000000-0000-4000-8000-000000000002',
       'select public.contestar_suspensao(''Contestação de conta ativa sem suspensão'')') $$,
  'PGRST', pg_temp.erro('sem_suspensao_ativa'),
  'contestar_suspensao sem suspensão em vigor devolve 422 sem_suspensao_ativa'
);

-- ── 5. Suspensão: validação de motivo e execução ───────────────────────────────

select throws_ok(
  $$ select privado.suspender('f7000000-0000-4000-8000-000000000002', null, 'f7000000-0000-4000-8000-000000000001') $$,
  'PGRST', pg_temp.erro('campo_obrigatorio', 'motivo'),
  'suspender com motivo nulo é recusado pelo banco (422)'
);

select throws_ok(
  $$ select privado.suspender('f7000000-0000-4000-8000-000000000002', '   ', 'f7000000-0000-4000-8000-000000000001') $$,
  'PGRST', pg_temp.erro('campo_obrigatorio', 'motivo'),
  'suspender com motivo em branco é recusado pelo banco (422)'
);

-- Executa a suspensão da conta
create temp table susp_res as
  select privado.suspender(
    'f7000000-0000-4000-8000-000000000002',
    'Denúncia grave confirmada de fraude',
    'f7000000-0000-4000-8000-000000000001'
  ) as r;

select is(
  (select u.estado from public.usuario u where u.id = 'f7000000-0000-4000-8000-000000000002'),
  'suspensa'::public.estado_conta,
  'usuario.estado é alterado para suspensa'
);

select is(
  (select count(*)::int from public.ocorrencia o
    where o.usuario_id = 'f7000000-0000-4000-8000-000000000002'
      and o.tipo = 'suspensao'
      and o.motivo = 'Denúncia grave confirmada de fraude'
      and o.autor_id = 'f7000000-0000-4000-8000-000000000001'),
  1,
  'ocorrencia de suspensao foi registrada com motivo e assinada pelo operador'
);

-- Push sem o motivo (RN15)
select is(
  (select count(*)::int from public.notificacao n
    where n.usuario_id = 'f7000000-0000-4000-8000-000000000002'
      and n.tipo = 'suspensao'
      and n.payload = '{"tipo": "suspensao"}'::jsonb),
  1,
  'notificacao de suspensao foi enfileirada sem o motivo no payload (RN15)'
);

-- ── 6. Consequências da suspensão: bloqueios ───────────────────────────────────

select is(
  (select count(*)::int from privado.elegiveis('f7000000-0000-4000-8000-000000000020', null) e
    where e.profissional_id = 'f7000000-0000-4000-8000-000000000011'),
  0,
  'conta suspensa não recebe despacho (sai de privado.elegiveis)'
);

select throws_ok(
  $$ select pg_temp.como('f7000000-0000-4000-8000-000000000002',
       'select public.candidatar(''f7000000-0000-4000-8000-000000000020'')') $$,
  'PGRST', pg_temp.erro('inelegivel', 'perfil_suspenso'),
  'conta suspensa não candidata (422 inelegivel, perfil_suspenso)'
);

select throws_ok(
  $$ select pg_temp.como('f7000000-0000-4000-8000-000000000002',
       'select public.bloquear(''estabelecimento'', ''f7000000-0000-4000-8000-000000000010'')') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'escrita geral (bloquear) é recusada com 403 conta_suspensa'
);

-- ── 7. Exceções da conta suspensa: aparelho, exportação e contestação ──────────

select is(
  ((pg_temp.como('f7000000-0000-4000-8000-000000000002',
     'select public.registrar_dispositivo(''token_fcm_conta_suspensa_valido_01'', ''ios'')'))->>'plataforma'),
  'ios',
  'conta suspensa consegue registrar dispositivo'
);

select is(
  ((pg_temp.como('f7000000-0000-4000-8000-000000000002',
     'select public.remover_dispositivo(''token_fcm_conta_suspensa_valido_01'')'))->>'removido')::boolean,
  true,
  'conta suspensa consegue remover dispositivo e sair'
);

select ok(
  (privado.meus_dados('f7000000-0000-4000-8000-000000000002')->'conta'->>'id') = 'f7000000-0000-4000-8000-000000000002',
  'conta suspensa consegue exportar seus dados'
);

-- Leitura de situacao_da_conta antes da contestação
create temp table sit_antes as
  select pg_temp.como('f7000000-0000-4000-8000-000000000002', 'select public.situacao_da_conta()') as s;

select is(
  ((select s from sit_antes)->>'estado'),
  'suspensa',
  'situacao_da_conta devolve estado suspensa'
);

select is(
  ((select s from sit_antes)->'suspensao'->>'motivo'),
  'Denúncia grave confirmada de fraude',
  'situacao_da_conta expõe o motivo registrado ao titular'
);

select is(
  ((select s from sit_antes)->'suspensao'->>'contestacao'),
  null,
  'contestacao é nula antes de ser enviada'
);

-- Validações de contestar_suspensao
select throws_ok(
  $$ select pg_temp.como('f7000000-0000-4000-8000-000000000002',
       'select public.contestar_suspensao(null)') $$,
  'PGRST', pg_temp.erro('campo_obrigatorio', 'relato'),
  'contestar com relato nulo devolve 422 campo_obrigatorio'
);

select throws_ok(
  $$ select pg_temp.como('f7000000-0000-4000-8000-000000000002',
       'select public.contestar_suspensao(''curto'')') $$,
  'PGRST', pg_temp.erro('campo_invalido', 'relato'),
  'contestar com relato menor que 10 caracteres devolve 422 campo_invalido'
);

-- Envio da contestação
create temp table cont_res as
  select pg_temp.como('f7000000-0000-4000-8000-000000000002',
    'select public.contestar_suspensao(''Esta denúncia é infundada e possuo comprovantes de presença.'')') as c;

select is(
  ((select c from cont_res)->>'tipo'),
  'contestacao',
  'contestar_suspensao devolve Protocolo com tipo contestacao'
);

select ok(
  ((select c from cont_res)->>'ocorrencia_id') is not null,
  'contestar_suspensao devolve ocorrencia_id'
);

select is(
  ((select c from cont_res)->>'prazo_resposta_ate'),
  to_char(privado.prazo_de_resposta(now()), 'YYYY-MM-DD'),
  'prazo de resposta da contestacao é calculado em até 5 dias úteis'
);

-- Verifica e-mail enfileirado na fila 'email'
select is(
  (select count(*)::int from pgmq.q_email q
    where (q.message->>'tipo') = 'contestacao'
      and (q.message->>'ocorrencia_id') = ((select c from cont_res)->>'ocorrencia_id')),
  1,
  'e-mail de contestacao enfileirado na fila pgmq email com protocolo (RN15)'
);

-- situacao_da_conta agora traz a contestação aberta
create temp table sit_depois as
  select pg_temp.como('f7000000-0000-4000-8000-000000000002', 'select public.situacao_da_conta()') as s;

select is(
  ((select s from sit_depois)->'suspensao'->'contestacao'->>'tipo'),
  'contestacao',
  'situacao_da_conta agora exibe a contestacao em andamento'
);

-- Segunda contestação devolve 409
select throws_ok(
  $$ select pg_temp.como('f7000000-0000-4000-8000-000000000002',
       'select public.contestar_suspensao(''Segunda contestacao para a mesma suspensao'')') $$,
  'PGRST', pg_temp.erro('contestacao_ja_aberta'),
  'segunda contestacao devolve 409 contestacao_ja_aberta'
);

-- ── 8. Reativação da conta e retorno ao despacho ───────────────────────────────

create temp table reat_res as
  select privado.reativar(
    'f7000000-0000-4000-8000-000000000002',
    'Comprovantes analisados e acolhidos pela Equipe Frila',
    'f7000000-0000-4000-8000-000000000001'
  ) as r;

select is(
  (select u.estado from public.usuario u where u.id = 'f7000000-0000-4000-8000-000000000002'),
  'ativa'::public.estado_conta,
  'usuario.estado é alterado de volta para ativa'
);

-- Push de reativação sem motivo
select is(
  (select count(*)::int from public.notificacao n
    where n.usuario_id = 'f7000000-0000-4000-8000-000000000002'
      and n.tipo = 'reativacao'
      and n.payload = '{"tipo": "reativacao"}'::jsonb),
  1,
  'notificacao de reativacao foi enfileirada sem o motivo no payload (RN15)'
);

select is(
  (select count(*)::int from privado.elegiveis('f7000000-0000-4000-8000-000000000020', null) e
    where e.profissional_id = 'f7000000-0000-4000-8000-000000000011'),
  1,
  'reativar devolve a conta ao despacho na hora'
);

-- ── 9. Exclusão de conta suspensa ──────────────────────────────────────────────
-- Suspende novamente e testa a exclusão
select privado.suspender(
  'f7000000-0000-4000-8000-000000000002',
  'Segunda suspensao para teste de exclusao',
  'f7000000-0000-4000-8000-000000000001'
);

select is(
  (select (privado.excluir_conta('f7000000-0000-4000-8000-000000000002')->>'perfil_removido_em') is not null),
  true,
  'conta suspensa consegue executar exclusao de conta'
);

select is(
  (select u.estado from public.usuario u where u.id = 'f7000000-0000-4000-8000-000000000002'),
  'anonimizada'::public.estado_conta,
  'conta suspensa excluida passa ao estado anonimizada'
);

select * from finish();
rollback;
