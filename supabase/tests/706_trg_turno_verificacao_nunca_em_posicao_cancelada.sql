-- 706_trg_turno_verificacao_nunca_em_posicao_cancelada.sql
--
-- Cobertura pgTAP do trigger turno_verificacao_nunca_em_posicao_cancelada e da função privado.verificacao_nunca_em_posicao_cancelada().
-- Regras de Negócio: RN22/RN07 (presença verificada nunca em posição cancelada / integridade de reputação).
-- Migração: 20260930141533_presenca_nunca_em_posicao_cancelada.sql.
--
-- 1. Metadados e privilégios:
--    - Trigger turno_verificacao_nunca_em_posicao_cancelada registrado em public.turno (BEFORE UPDATE OF verificacao).
--    - privado.verificacao_nunca_em_posicao_cancelada() é SECURITY DEFINER com search_path="" fixado.
--    - Menor privilégio: service_role executa; authenticated, anon e public NÃO executam.
-- 2. Integridade e Imutabilidade (RN22/RN07):
--    - Bloqueia UPDATE de verificacao para 'verificado' em turno cuja posição associada está 'cancelada' (409 vaga_encerrada / posicao_cancelada).
--    - Permite UPDATE de verificacao para 'verificado' em turno de posição válida ('confirmada').
--    - Permite UPDATE mantendo o estado 'nao_verificado' ou atualização idempotente.
--    - Permite UPDATE em outras colunas (a_caminho_em) sem alterar verificacao.

begin;

-- Pré-requisito: habilitar ambiente de teste e congelar relógio antes de inserir dados
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-16 12:00:00-03';

select plan(13);

-- ── 1. Metadados e privilégios ──────────────────────────────────────────────────

select has_trigger(
  'public',
  'turno',
  'turno_verificacao_nunca_em_posicao_cancelada',
  'tabela public.turno possui o trigger turno_verificacao_nunca_em_posicao_cancelada'
);

select is(
  (select prosecdef from pg_proc where proname = 'verificacao_nunca_em_posicao_cancelada' and pronamespace = 'privado'::regnamespace),
  true,
  'privado.verificacao_nunca_em_posicao_cancelada() é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'verificacao_nunca_em_posicao_cancelada' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'privado.verificacao_nunca_em_posicao_cancelada() possui search_path="" fixado'
);

select ok(
  has_function_privilege('service_role', 'privado.verificacao_nunca_em_posicao_cancelada()', 'execute'),
  'service_role executa privado.verificacao_nunca_em_posicao_cancelada()'
);

select ok(
  not has_function_privilege('authenticated', 'privado.verificacao_nunca_em_posicao_cancelada()', 'execute'),
  'authenticated não executa privado.verificacao_nunca_em_posicao_cancelada()'
);

select ok(
  not has_function_privilege('anon', 'privado.verificacao_nunca_em_posicao_cancelada()', 'execute'),
  'anon não executa privado.verificacao_nunca_em_posicao_cancelada()'
);

select ok(
  not has_function_privilege('public', 'privado.verificacao_nunca_em_posicao_cancelada()', 'execute'),
  'public não executa privado.verificacao_nunca_em_posicao_cancelada()'
);

-- ── 2. Cenário de teste (prefixo 706) ──────────────────────────────────────────

insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado
) values
  ('70600000-0000-4000-8000-000000000001', 'contratante',  'Contratante 706',  '+5561970600001', 'c706@test.com', '1987-04-04', '2026-09-22', now(), 'ativa'),
  ('70600000-0000-4000-8000-000000000002', 'profissional', 'Profissional 706', '+5561970600002', 'p706@test.com', '1994-08-08', '2026-09-22', now(), 'ativa');

insert into public.estabelecimento (
  id, nome, documento, tipo, endereco, ponto, regiao_administrativa
) values (
  '70600000-0000-4000-8000-000000000010',
  'Pizzaria 706',
  '98765432000188',
  'food_service',
  'CLN 108 Bloco C',
  'POINT(-47.8850 -15.7750)'::extensions.geography,
  'Plano Piloto'
);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('70600000-0000-4000-8000-000000000010', '70600000-0000-4000-8000-000000000001', 'administrador');

insert into public.profissional (id, usuario_id, ponto_base)
values (
  '70600000-0000-4000-8000-000000000020',
  '70600000-0000-4000-8000-000000000002',
  'POINT(-47.8850 -15.7750)'::extensions.geography
);

insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por
) values
  ('70600000-0000-4000-8000-000000000030', '70600000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8850 -15.7750)'::extensions.geography,
   'Cozinha', 16000, 2, true, false, false, 'Chefe 706',
   '2026-10-18 18:00:00-03', '2026-10-19 02:00:00-03', 'selecao', 'publicada',
   'Plano Piloto', '70600000-0000-4000-8000-0000000000c1', '70600000-0000-4000-8000-000000000001');

-- Posição 1: cancelada (com falta registrada)
-- Posição 2: confirmada (profissional alocado)
insert into public.posicao (
  id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em
) values
  ('70600000-0000-4000-8000-0000000000a1', '70600000-0000-4000-8000-000000000030',
   'cancelada', null, null, true, '2026-10-18 18:00:00-03', '2026-10-19 02:00:00-03'),
  ('70600000-0000-4000-8000-0000000000a2', '70600000-0000-4000-8000-000000000030',
   'confirmada', '70600000-0000-4000-8000-000000000020', now(), false, '2026-10-18 18:00:00-03', '2026-10-19 02:00:00-03');

-- Turno 1 na posição cancelada: simula o cenário canônico medido em 30/09:
-- check-in manual pendente já existia antes da desistência/cancelamento da posição.
-- Turno 2 na posição confirmada (verificacao inicial 'pendente')
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, verificacao, valor_acordado_centavos)
values
  ('70600000-0000-4000-8000-0000000000b1', '70600000-0000-4000-8000-0000000000a1',
   '2026-10-18 18:05:00-03', 'manual', 'pendente', 16000),
  ('70600000-0000-4000-8000-0000000000b2', '70600000-0000-4000-8000-0000000000a2',
   null, null, 'pendente', 16000);

-- ── 3. Testes de Bloqueio em Posição Cancelada (RN22/RN07) ──────────────────────

-- 1. Tentativa de confirmar check-in manual (verificacao = 'verificado', checkin_confirmado_em = now())
-- em posição cancelada deve ser bloqueada estritamente pelo trigger de verificação com 409 vaga_encerrada.
-- (checkin_em já estava preenchido, logo turno_checkin_nunca_em_posicao_cancelada NÃO interfere).
select throws_ok(
  $$update public.turno set verificacao = 'verificado', checkin_confirmado_em = now() where id = '70600000-0000-4000-8000-0000000000b1'$$,
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : "posicao_cancelada", "hint" : null}',
  'UPDATE alterando verificacao para verificado em turno de posicao cancelada levanta 409 vaga_encerrada (RN22/RN07)'
);

-- 2. UPDATE alterando verificacao para 'nao_verificado' em posição cancelada é permitido
select lives_ok(
  $$update public.turno set verificacao = 'nao_verificado' where id = '70600000-0000-4000-8000-0000000000b1'$$,
  'UPDATE alterando verificacao para nao_verificado em posicao cancelada não dispara o trigger'
);

-- 3. UPDATE em posição confirmada (ativa) alterando para 'verificado' é permitido
select lives_ok(
  $$update public.turno set verificacao = 'verificado', checkin_tipo = 'geolocalizado', checkin_distancia_m = 50, checkin_em = now() where id = '70600000-0000-4000-8000-0000000000b2'$$,
  'UPDATE alterando verificacao para verificado em turno de posicao confirmada é permitido'
);

select is(
  (select verificacao from public.turno where id = '70600000-0000-4000-8000-0000000000b2'),
  'verificado'::public.verificacao_turno,
  'turno da posicao confirmada foi atualizado para verificado com sucesso'
);

-- 4. UPDATE idempotente de verificacao = 'verificado' no turno já verificado é permitido
select lives_ok(
  $$update public.turno set verificacao = 'verificado' where id = '70600000-0000-4000-8000-0000000000b2'$$,
  'UPDATE idempotente de verificacao = verificado não levanta erro (old.verificacao já é verificado)'
);

-- 5. UPDATE em outras colunas (a_caminho_em) no turno da posição cancelada é permitido
select lives_ok(
  $$update public.turno set a_caminho_em = now() where id = '70600000-0000-4000-8000-0000000000b1'$$,
  'UPDATE em outras colunas (a_caminho_em) em turno de posicao cancelada é permitido'
);

select * from finish();

rollback;
