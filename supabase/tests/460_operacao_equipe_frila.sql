-- 460_operacao_equipe_frila.sql
--
-- Testes das ferramentas e procedimentos operacionais da Equipe Frila (Cartão Oxh0AWE7):
--   - privado.operacao_suspender_conta(uuid, text)
--   - privado.operacao_reativar_conta(uuid, text)
--   - privado.operacao_moderar_conteudo(uuid, text, text)
--   - Controle de acesso: restrito à service_role (fora da API pública)
--   - Gravação de ocorrências e cancelamento de turnos futuros (RN13)
--   - Moderação da diretriz 1.2 da App Store (ocultar / reexibir em 24h)

begin;

select plan(41);

set local frila.agendador_secret = 'segredo-de-teste';

-- ── 1. Cenário de teste ─────────────────────────────────────────────────────────

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values
  ('00000000-0000-0000-0000-000000000000', 'd7000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', 'operacao-prof@frila.test', now(), now(), false, false),
  ('00000000-0000-0000-0000-000000000000', 'd7000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', 'operacao-casa@frila.test', now(), now(), false, false);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values
  ('d7000000-0000-4000-8000-000000000001', 'profissional', 'Carlos Operacao', '+5561955550001', 'operacao-prof@frila.test', '1990-01-01', 'ativa', '2026-09-22', now()),
  ('d7000000-0000-4000-8000-000000000002', 'contratante',  'Restaurante Operacao', '+5561955550002', 'operacao-casa@frila.test', '1985-01-01', 'ativa', '2026-09-22', now());

insert into public.profissional (id, usuario_id, ponto_base)
values ('d7000000-0000-4000-8000-000000000011', 'd7000000-0000-4000-8000-000000000001', 'POINT(-47.8800 -15.7900)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, regiao_administrativa, endereco, ponto)
values ('d7000000-0000-4000-8000-000000000022', 'Bar da Operacao', '29979036000140', 'food_service', 'Plano Piloto', 'SCLRN 705', 'POINT(-47.8850 -15.7950)'::extensions.geography);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('d7000000-0000-4000-8000-000000000022', 'd7000000-0000-4000-8000-000000000002', 'administrador');

-- Cria uma vaga futura para testes de cancelamento/moderação
insert into public.vaga (id, estabelecimento_id, publicado_por, funcao_id, inicio_em, fim_em, local, regiao_administrativa, responsavel_local, valor_centavos, posicoes, modo, estado, ponto, inclui_refeicao, inclui_transporte, exige_material_proprio, chave_cliente)
select 'd7000000-0000-4000-8000-000000000033'::uuid,
       'd7000000-0000-4000-8000-000000000022'::uuid,
       'd7000000-0000-4000-8000-000000000002'::uuid,
       f.id,
       now() + interval '2 days',
       now() + interval '2 days 6 hours',
       'Bar da Operacao',
       'Plano Piloto',
       'Gerente',
       15000,
       1,
       'urgencia',
       'publicada',
       'POINT(-47.8850 -15.7950)'::extensions.geography,
       false,
       false,
       false,
       gen_random_uuid()
  from public.funcao f
 where f.nome = 'garçom';

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em, profissional_id, confirmado_em)
values ('d7000000-0000-4000-8000-000000000044',
        'd7000000-0000-4000-8000-000000000033',
        'confirmada',
        now() + interval '2 days',
        now() + interval '2 days 6 hours',
        'd7000000-0000-4000-8000-000000000011',
        now());

insert into public.turno (id, posicao_id, valor_acordado_centavos)
values ('d7000000-0000-4000-8000-000000000055', 'd7000000-0000-4000-8000-000000000044', 15000);

-- Membro da Equipe Frila que age nos scripts (bloqueio 4 da revisão do #74): é ele o
-- autor das ocorrências operacionais, nunca o alvo.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
values
  ('00000000-0000-0000-0000-000000000000', 'd7000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', 'operacao-equipe@frila.test', now(), now(), false, false),
  ('00000000-0000-0000-0000-000000000000', 'd7000000-0000-4000-8000-000000000004', 'authenticated', 'authenticated', 'operacao-prof2@frila.test', now(), now(), false, false),
  ('00000000-0000-0000-0000-000000000000', 'd7000000-0000-4000-8000-000000000005', 'authenticated', 'authenticated', 'operacao-prof3@frila.test', now(), now(), false, false),
  ('00000000-0000-0000-0000-000000000000', 'd7000000-0000-4000-8000-000000000006', 'authenticated', 'authenticated', 'operacao-casa2@frila.test', now(), now(), false, false);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values
  ('d7000000-0000-4000-8000-000000000003', 'contratante',  'Equipe Frila Operador', '+5561955550003', 'operacao-equipe@frila.test', '1990-01-01', 'ativa', '2026-09-22', now()),
  ('d7000000-0000-4000-8000-000000000004', 'profissional', 'Beatriz Confirmada',    '+5561955550004', 'operacao-prof2@frila.test',  '1992-01-01', 'ativa', '2026-09-22', now()),
  ('d7000000-0000-4000-8000-000000000005', 'profissional', 'Davi Candidato',        '+5561955550005', 'operacao-prof3@frila.test',  '1993-01-01', 'ativa', '2026-09-22', now()),
  ('d7000000-0000-4000-8000-000000000006', 'contratante',  'Casa Suspensa',         '+5561955550006', 'operacao-casa2@frila.test',  '1980-01-01', 'ativa', '2026-09-22', now());

insert into public.profissional (id, usuario_id, ponto_base)
values ('d7000000-0000-4000-8000-000000000014', 'd7000000-0000-4000-8000-000000000004', 'POINT(-47.8800 -15.7900)'::extensions.geography),
       ('d7000000-0000-4000-8000-000000000015', 'd7000000-0000-4000-8000-000000000005', 'POINT(-47.8800 -15.7900)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, regiao_administrativa, endereco, ponto)
values ('d7000000-0000-4000-8000-000000000023', 'Casa da Suspensao', '11222333000181', 'food_service', 'Plano Piloto', 'SCLRN 706', 'POINT(-47.8850 -15.7950)'::extensions.geography);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('d7000000-0000-4000-8000-000000000023', 'd7000000-0000-4000-8000-000000000006', 'administrador');

-- Vaga publicada de 3 posições com 1 confirmada, 2 abertas e 1 candidatura pendente,
-- e vaga preenchida de 1 posição confirmada. É o cenário do bloqueio 2.
insert into public.vaga (id, estabelecimento_id, publicado_por, funcao_id, inicio_em, fim_em, local, regiao_administrativa, responsavel_local, valor_centavos, posicoes, modo, estado, ponto, inclui_refeicao, inclui_transporte, exige_material_proprio, chave_cliente)
select v.id, 'd7000000-0000-4000-8000-000000000023'::uuid, 'd7000000-0000-4000-8000-000000000006'::uuid,
       f.id, v.inicio, v.inicio + interval '6 hours', 'Casa da Suspensao', 'Plano Piloto', 'Gerente',
       15000, v.posicoes, 'urgencia', v.estado::public.estado_vaga,
       'POINT(-47.8850 -15.7950)'::extensions.geography, false, false, false, gen_random_uuid()
  from public.funcao f,
       (values ('d7000000-0000-4000-8000-000000000034'::uuid, now() + interval '4 days', 3, 'publicada'),
               ('d7000000-0000-4000-8000-000000000035'::uuid, now() + interval '5 days', 1, 'preenchida'))
         as v(id, inicio, posicoes, estado)
 where f.nome = 'garçom';

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em, profissional_id, confirmado_em)
values ('d7000000-0000-4000-8000-000000000045', 'd7000000-0000-4000-8000-000000000034', 'confirmada',
        now() + interval '4 days', now() + interval '4 days 6 hours', 'd7000000-0000-4000-8000-000000000014', now()),
       ('d7000000-0000-4000-8000-000000000046', 'd7000000-0000-4000-8000-000000000034', 'aberta',
        now() + interval '4 days', now() + interval '4 days 6 hours', null, null),
       ('d7000000-0000-4000-8000-000000000047', 'd7000000-0000-4000-8000-000000000034', 'aberta',
        now() + interval '4 days', now() + interval '4 days 6 hours', null, null),
       ('d7000000-0000-4000-8000-000000000048', 'd7000000-0000-4000-8000-000000000035', 'confirmada',
        now() + interval '5 days', now() + interval '5 days 6 hours', 'd7000000-0000-4000-8000-000000000014', now());

insert into public.turno (id, posicao_id, valor_acordado_centavos)
values ('d7000000-0000-4000-8000-000000000056', 'd7000000-0000-4000-8000-000000000045', 15000),
       ('d7000000-0000-4000-8000-000000000057', 'd7000000-0000-4000-8000-000000000048', 15000);

insert into public.candidatura (id, posicao_id, profissional_id, estado)
values ('d7000000-0000-4000-8000-000000000081', 'd7000000-0000-4000-8000-000000000046',
        'd7000000-0000-4000-8000-000000000015', 'pendente');

-- ── 2. Segurança e permissões de acesso ─────────────────────────────────────────

select ok(
  not has_function_privilege('anon', 'privado.operacao_suspender_conta(uuid, text, uuid)', 'execute'),
  'anon não executa privado.operacao_suspender_conta');

select ok(
  not has_function_privilege('anon', 'privado.operacao_reativar_conta(uuid, text, uuid)', 'execute'),
  'anon não executa privado.operacao_reativar_conta');

select ok(
  not has_function_privilege('anon', 'privado.operacao_moderar_conteudo(uuid, text, text, uuid)', 'execute'),
  'anon não executa privado.operacao_moderar_conteudo');

select ok(
  not has_function_privilege('authenticated', 'privado.operacao_suspender_conta(uuid, text, uuid)', 'execute'),
  'authenticated não executa privado.operacao_suspender_conta');

select ok(
  not has_function_privilege('authenticated', 'privado.operacao_reativar_conta(uuid, text, uuid)', 'execute'),
  'authenticated não executa privado.operacao_reativar_conta');

select ok(
  not has_function_privilege('authenticated', 'privado.operacao_moderar_conteudo(uuid, text, text, uuid)', 'execute'),
  'authenticated não executa privado.operacao_moderar_conteudo');

-- ── 3. Validações e Recusas (service_role) ──────────────────────────────────────

-- Motivo obrigatório
select throws_ok(
  $$ select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', null, 'd7000000-0000-4000-8000-000000000003') $$,
  'PGRST', null,
  'suspender com motivo nulo é recusado com erro');

select throws_ok(
  $$ select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', '   ', 'd7000000-0000-4000-8000-000000000003') $$,
  'PGRST', null,
  'suspender com motivo em branco é recusado com erro');

-- Usuário inexistente
select throws_ok(
  $$ select privado.operacao_suspender_conta('00000000-0000-0000-0000-000000000000', 'motivo', 'd7000000-0000-4000-8000-000000000003') $$,
  'PGRST', null,
  'suspender usuário inexistente devolve 404');

select throws_ok(
  $$ select privado.operacao_reativar_conta('00000000-0000-0000-0000-000000000000', 'justificativa', 'd7000000-0000-4000-8000-000000000003') $$,
  'PGRST', null,
  'reativar usuário inexistente devolve 404');

-- Operador obrigatório, ativo e diferente do alvo (bloqueio 4)
select throws_ok(
  $$ select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', 'motivo', null) $$,
  'PGRST', null,
  'suspender sem operador é recusado');

select throws_ok(
  $$ select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', 'motivo', 'd7000000-0000-4000-8000-000000000001') $$,
  'PGRST', null,
  'o alvo não assina a própria suspensão');

select throws_ok(
  $$ select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', 'motivo', '00000000-0000-0000-0000-000000000000') $$,
  'PGRST', null,
  'operador sem conta é recusado');

select throws_ok(
  $$ select privado.operacao_reativar_conta('d7000000-0000-4000-8000-000000000001', 'justificativa', null) $$,
  'PGRST', null,
  'reativar sem operador é recusado');

select throws_ok(
  $$ select privado.operacao_moderar_conteudo('d7000000-0000-4000-8000-000000000033', 'ocultar', 'motivo', 'd7000000-0000-4000-8000-000000000002') $$,
  'PGRST', null,
  'quem publicou a vaga não assina a moderação dela');

-- ── 4. Suspender conta e efeitos colaterais ─────────────────────────────────────

create temp table res_suspensao as
  select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', 'Denúncia grave de assédio confirmada', 'd7000000-0000-4000-8000-000000000003') as r;

select is(
  (select u.estado from public.usuario u where u.id = 'd7000000-0000-4000-8000-000000000001'),
  'suspensa'::public.estado_conta,
  'estado do usuário muda para suspensa');

select is(
  (select count(*)::int from public.ocorrencia o
    where o.tipo = 'suspensao'
      and o.usuario_id = 'd7000000-0000-4000-8000-000000000001'
      and o.motivo = 'Denúncia grave de assédio confirmada'),
  1,
  'ocorrência de suspensão foi registrada com motivo');

select is(
  (select p.estado from public.posicao p where p.id = 'd7000000-0000-4000-8000-000000000044'),
  'cancelada'::public.estado_posicao,
  'turno futuro do profissional suspenso foi cancelado (RN13)');

select is(
  ((select r from res_suspensao)->>'turnos_cancelados')::int,
  1,
  'relatório indica 1 turno cancelado');

select is(
  (select o.autor_id from public.ocorrencia o
    where o.tipo = 'suspensao'
      and o.usuario_id = 'd7000000-0000-4000-8000-000000000001'),
  'd7000000-0000-4000-8000-000000000003'::uuid,
  'autor da ocorrência de suspensão é o membro da Equipe Frila, não o suspenso');

-- Idempotência de suspensão
create temp table res_suspensao_2 as
  select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', 'Outra tentativa de suspender', 'd7000000-0000-4000-8000-000000000003') as r;

select is(
  ((select r from res_suspensao_2)->>'ja_estava_suspensa')::boolean,
  true,
  'suspender conta já suspensa é idempotente e devolve ja_estava_suspensa');

-- ── 5. Reativar conta ──────────────────────────────────────────────────────────

create temp table res_reativacao as
  select privado.operacao_reativar_conta('d7000000-0000-4000-8000-000000000001', 'Contestação acolhida por documento comprobatório', 'd7000000-0000-4000-8000-000000000003') as r;

select is(
  (select u.estado from public.usuario u where u.id = 'd7000000-0000-4000-8000-000000000001'),
  'ativa'::public.estado_conta,
  'estado do usuário retorna para ativa');

select is(
  (select count(*)::int from public.ocorrencia o
    where o.tipo = 'suporte'
      and o.usuario_id = 'd7000000-0000-4000-8000-000000000001'
      and o.resultado like '%reativada%'),
  1,
  'ocorrência de suporte foi registrada para a reativação');

select is(
  (select o.autor_id from public.ocorrencia o
    where o.tipo = 'suporte'
      and o.usuario_id = 'd7000000-0000-4000-8000-000000000001'
      and o.resultado like '%reativada%'),
  'd7000000-0000-4000-8000-000000000003'::uuid,
  'autor da ocorrência de reativação é o membro da Equipe Frila');

-- Idempotência de reativação
create temp table res_reativacao_2 as
  select privado.operacao_reativar_conta('d7000000-0000-4000-8000-000000000001', 'Tentativa extra de reativar', 'd7000000-0000-4000-8000-000000000003') as r;

select is(
  ((select r from res_reativacao_2)->>'ja_estava_ativa')::boolean,
  true,
  'reativar conta já ativa é idempotente');

-- ── 6. Moderação de Conteúdo (Diretriz 1.2 da App Store) ─────────────────────────

-- Cria vaga nova para moderação
insert into public.vaga (id, estabelecimento_id, publicado_por, funcao_id, inicio_em, fim_em, local, regiao_administrativa, responsavel_local, valor_centavos, posicoes, modo, estado, ponto, inclui_refeicao, inclui_transporte, exige_material_proprio, chave_cliente)
select 'd7000000-0000-4000-8000-000000000066'::uuid,
       'd7000000-0000-4000-8000-000000000022'::uuid,
       'd7000000-0000-4000-8000-000000000002'::uuid,
       f.id,
       now() + interval '3 days',
       now() + interval '3 days 6 hours',
       'Local com Conteúdo Impróprio',
       'Plano Piloto',
       'Gerente',
       14000,
       1,
       'urgencia',
       'publicada',
       'POINT(-47.8850 -15.7950)'::extensions.geography,
       false,
       false,
       false,
       gen_random_uuid()
  from public.funcao f
 where f.nome = 'garçom';

create temp table res_mod_ocultar as
  select privado.operacao_moderar_conteudo('d7000000-0000-4000-8000-000000000066', 'ocultar', 'Linguagem ofensiva reportada em denúncia', 'd7000000-0000-4000-8000-000000000003') as r;

select is(
  (select g.estado from public.vaga g where g.id = 'd7000000-0000-4000-8000-000000000066'),
  'cancelada'::public.estado_vaga,
  'moderação oculta (cancela) vaga denunciada');

select is(
  (select count(*)::int from public.ocorrencia o
    where o.motivo like '%Linguagem ofensiva reportada%'),
  1,
  'ocorrência de moderação de conteúdo gravada');

select is(
  (select o.autor_id from public.ocorrencia o
    where o.motivo like '%Linguagem ofensiva reportada%'),
  'd7000000-0000-4000-8000-000000000003'::uuid,
  'autor da ocorrência de moderação é o membro da Equipe Frila, não quem publicou');

select isnt(
  (select o.tipo from public.ocorrencia o
    where o.motivo like '%Linguagem ofensiva reportada%'),
  'denuncia'::public.tipo_ocorrencia,
  'moderação não se registra como denúncia escrita pelo moderado');

-- Reexibir vaga
create temp table res_mod_reexibir as
  select privado.operacao_moderar_conteudo('d7000000-0000-4000-8000-000000000066', 'reexibir', 'Denúncia improcedente após verificação', 'd7000000-0000-4000-8000-000000000003') as r;

select is(
  (select g.estado from public.vaga g where g.id = 'd7000000-0000-4000-8000-000000000066'),
  'publicada'::public.estado_vaga,
  'moderação pode reexibir vaga antes do início');

-- ── 7. Suspender contratante com vaga parcialmente preenchida (bloqueio 2) ────────

create temp table res_suspensao_casa as
  select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000006', 'Fraude confirmada na publicação', 'd7000000-0000-4000-8000-000000000003') as r;

select is(
  (select g.estado from public.vaga g where g.id = 'd7000000-0000-4000-8000-000000000034'),
  'cancelada'::public.estado_vaga,
  'vaga publicada da casa suspensa é cancelada');

select is(
  (select p.estado from public.posicao p where p.id = 'd7000000-0000-4000-8000-000000000045'),
  'cancelada'::public.estado_posicao,
  'posição confirmada da vaga publicada é cancelada junto');

select is(
  (select p.falta from public.posicao p where p.id = 'd7000000-0000-4000-8000-000000000045'),
  false,
  'a profissional da casa suspensa não leva falta (RN12)');

select is(
  (select count(*)::int from public.posicao p
     join public.vaga g on g.id = p.vaga_id
    where g.estabelecimento_id = 'd7000000-0000-4000-8000-000000000023'
      and g.estado = 'cancelada'
      and p.estado = 'confirmada'),
  0,
  'nenhuma posição confirmada sobra em vaga cancelada da casa suspensa');

select is(
  (select g.estado from public.vaga g where g.id = 'd7000000-0000-4000-8000-000000000035'),
  'cancelada'::public.estado_vaga,
  'vaga preenchida da casa suspensa também é cancelada');

select is(
  (select p.estado from public.posicao p where p.id = 'd7000000-0000-4000-8000-000000000048'),
  'cancelada'::public.estado_posicao,
  'posição confirmada da vaga preenchida é cancelada');

select is(
  (select c.estado from public.candidatura c where c.id = 'd7000000-0000-4000-8000-000000000081'),
  'retirada'::public.estado_candidatura,
  'candidatura pendente na vaga cancelada é retirada');

select ok(
  exists (select 1 from public.notificacao n
           where n.usuario_id = 'd7000000-0000-4000-8000-000000000004'
             and n.tipo = 'cancelamento'
             and n.referencia_id = 'd7000000-0000-4000-8000-000000000045'),
  'a profissional confirmada é avisada do cancelamento');

select ok(
  exists (select 1 from public.notificacao n
           where n.usuario_id = 'd7000000-0000-4000-8000-000000000005'
             and n.tipo = 'cancelamento'
             and n.referencia_id = 'd7000000-0000-4000-8000-000000000034'),
  'o candidato pendente é avisado do cancelamento da vaga');

select is(
  (select o.autor_id from public.ocorrencia o
    where o.tipo = 'cancelamento'
      and o.posicao_id = 'd7000000-0000-4000-8000-000000000045'),
  'd7000000-0000-4000-8000-000000000003'::uuid,
  'o cancelamento da posição confirmada tem o membro da Equipe Frila como autor');

-- ── 8. Retenção não apaga o motivo da suspensão (bloqueio 4) ─────────────────────

-- A conta suspensa é anonimizada e passa o prazo; a limpeza apaga o relato das
-- ocorrências de autoria dela. A suspensão não é de autoria dela.
update public.usuario
   set estado = 'anonimizada', anonimizado_em = now() - interval '20 days',
       nome = 'Conta encerrada', telefone = null, email = null
 where id = 'd7000000-0000-4000-8000-000000000001';

select privado.limpar_contas_anonimizadas(15);

select is(
  (select o.motivo from public.ocorrencia o
    where o.tipo = 'suspensao'
      and o.usuario_id = 'd7000000-0000-4000-8000-000000000001'),
  'Denúncia grave de assédio confirmada',
  'o motivo da suspensão sobrevive à limpeza da conta suspensa');

rollback;
