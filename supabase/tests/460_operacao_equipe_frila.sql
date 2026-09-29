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

select plan(21);

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

-- ── 2. Segurança e permissões de acesso ─────────────────────────────────────────

select ok(
  not has_function_privilege('anon', 'privado.operacao_suspender_conta(uuid, text)', 'execute'),
  'anon não executa privado.operacao_suspender_conta');

select ok(
  not has_function_privilege('anon', 'privado.operacao_reativar_conta(uuid, text)', 'execute'),
  'anon não executa privado.operacao_reativar_conta');

select ok(
  not has_function_privilege('anon', 'privado.operacao_moderar_conteudo(uuid, text, text)', 'execute'),
  'anon não executa privado.operacao_moderar_conteudo');

select ok(
  not has_function_privilege('authenticated', 'privado.operacao_suspender_conta(uuid, text)', 'execute'),
  'authenticated não executa privado.operacao_suspender_conta');

select ok(
  not has_function_privilege('authenticated', 'privado.operacao_reativar_conta(uuid, text)', 'execute'),
  'authenticated não executa privado.operacao_reativar_conta');

select ok(
  not has_function_privilege('authenticated', 'privado.operacao_moderar_conteudo(uuid, text, text)', 'execute'),
  'authenticated não executa privado.operacao_moderar_conteudo');

-- ── 3. Validações e Recusas (service_role) ──────────────────────────────────────

-- Motivo obrigatório
select throws_ok(
  $$ select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', null) $$,
  'PGRST', null,
  'suspender com motivo nulo é recusado com erro');

select throws_ok(
  $$ select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', '   ') $$,
  'PGRST', null,
  'suspender com motivo em branco é recusado com erro');

-- Usuário inexistente
select throws_ok(
  $$ select privado.operacao_suspender_conta('00000000-0000-0000-0000-000000000000', 'motivo') $$,
  'PGRST', null,
  'suspender usuário inexistente devolve 404');

select throws_ok(
  $$ select privado.operacao_reativar_conta('00000000-0000-0000-0000-000000000000', 'justificativa') $$,
  'PGRST', null,
  'reativar usuário inexistente devolve 404');

-- ── 4. Suspender conta e efeitos colaterais ─────────────────────────────────────

create temp table res_suspensao as
  select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', 'Denúncia grave de assédio confirmada') as r;

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

-- Idempotência de suspensão
create temp table res_suspensao_2 as
  select privado.operacao_suspender_conta('d7000000-0000-4000-8000-000000000001', 'Outra tentativa de suspender') as r;

select is(
  ((select r from res_suspensao_2)->>'ja_estava_suspensa')::boolean,
  true,
  'suspender conta já suspensa é idempotente e devolve ja_estava_suspensa');

-- ── 5. Reativar conta ──────────────────────────────────────────────────────────

create temp table res_reativacao as
  select privado.operacao_reativar_conta('d7000000-0000-4000-8000-000000000001', 'Contestação acolhida por documento comprobatório') as r;

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

-- Idempotência de reativação
create temp table res_reativacao_2 as
  select privado.operacao_reativar_conta('d7000000-0000-4000-8000-000000000001', 'Tentativa extra de reativar') as r;

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
  select privado.operacao_moderar_conteudo('d7000000-0000-4000-8000-000000000066', 'ocultar', 'Linguagem ofensiva reportada em denúncia') as r;

select is(
  (select g.estado from public.vaga g where g.id = 'd7000000-0000-4000-8000-000000000066'),
  'cancelada'::public.estado_vaga,
  'moderação oculta (cancela) vaga denunciada');

select is(
  (select count(*)::int from public.ocorrencia o
    where o.motivo like '%Linguagem ofensiva reportada%'),
  1,
  'ocorrência de moderação de conteúdo gravada');

-- Reexibir vaga
create temp table res_mod_reexibir as
  select privado.operacao_moderar_conteudo('d7000000-0000-4000-8000-000000000066', 'reexibir', 'Denúncia improcedente após verificação') as r;

select is(
  (select g.estado from public.vaga g where g.id = 'd7000000-0000-4000-8000-000000000066'),
  'publicada'::public.estado_vaga,
  'moderação pode reexibir vaga antes do início');

rollback;
