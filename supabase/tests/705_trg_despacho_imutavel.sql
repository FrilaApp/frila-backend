-- 705_trg_despacho_imutavel.sql
--
-- Cobertura pgTAP do trigger despacho_imutavel e da função privado.despacho_imutavel().
-- Regras de Negócio: RNF13 (trilha de auditoria / imutabilidade), RN23 (teto e agrupamento de push) e RF25 (retenção/limpeza).
-- Migrações: 20260925220000_trilha_de_auditoria.sql:138 e 20260928210000_teto_e_agrupamento_rn23.sql:95.
--
-- 1. Metadados e privilégios:
--    - Trigger despacho_imutavel registrado em public.despacho (BEFORE UPDATE OR DELETE).
--    - privado.despacho_imutavel() é SECURITY DEFINER com search_path="" fixado.
--    - Menor privilégio: service_role executa; authenticated, anon e public NÃO executam.
-- 2. Imutabilidade e Integridade de Auditoria (RNF13, RN23):
--    - DELETE direto é bloqueado com restrict_violation (23001) e mensagem 'registro de despacho nao pode ser apagado'.
--    - UPDATE em colunas imutáveis (vaga_id, profissional_id, criado_em) é bloqueado com restrict_violation (23001).
--    - UPDATE reescrevendo ou anulando notificacao_id preenchido é bloqueado com mensagem 'despacho ja tem notificacao'.
--    - UPDATE preenchendo notificacao_id nulo pela primeira vez é permitido (esperou o teto e recebe notificação, RN23).
--    - Segunda tentativa de alterar notificacao_id é bloqueada ("uma vez só").
--    - UPDATE idempotente mantendo todas as colunas é permitido.
-- 3. Retenção e Anonimização (RF25):
--    - Sob sessão com privado.retencao = 'on', DELETE é autorizado e remove a linha.

begin;

-- Pré-requisito: habilitar ambiente de teste e congelar relógio antes de inserir dados
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-16 12:00:00-03';

select plan(19);

-- ── 1. Metadados e privilégios ──────────────────────────────────────────────────

select has_trigger(
  'public',
  'despacho',
  'despacho_imutavel',
  'tabela public.despacho possui o trigger despacho_imutavel'
);

select is(
  (select prosecdef from pg_proc where proname = 'despacho_imutavel' and pronamespace = 'privado'::regnamespace),
  true,
  'privado.despacho_imutavel() é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'despacho_imutavel' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'privado.despacho_imutavel() possui search_path="" fixado'
);

select ok(
  has_function_privilege('service_role', 'privado.despacho_imutavel()', 'execute'),
  'service_role executa privado.despacho_imutavel()'
);

select ok(
  not has_function_privilege('authenticated', 'privado.despacho_imutavel()', 'execute'),
  'authenticated não executa privado.despacho_imutavel()'
);

select ok(
  not has_function_privilege('anon', 'privado.despacho_imutavel()', 'execute'),
  'anon não executa privado.despacho_imutavel()'
);

select ok(
  not has_function_privilege('public', 'privado.despacho_imutavel()', 'execute'),
  'public não executa privado.despacho_imutavel()'
);

-- ── 2. Cenário de teste (prefixo 705) ──────────────────────────────────────────

insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado
) values
  ('70500000-0000-4000-8000-000000000001', 'contratante',  'Contratante 705',  '+5561970500001', 'c705@test.com', '1988-03-03', '2026-09-22', '2026-10-16 12:00:00-03', 'ativa'),
  ('70500000-0000-4000-8000-000000000002', 'profissional', 'Profissional 705', '+5561970500002', 'p705@test.com', '1993-07-07', '2026-09-22', '2026-10-16 12:00:00-03', 'ativa');

insert into public.estabelecimento (
  id, nome, documento, tipo, endereco, ponto, regiao_administrativa
) values (
  '70500000-0000-4000-8000-000000000010',
  'Bar e Restaurante 705',
  '12345678000195',
  'food_service',
  'CLS 302 Bloco B',
  'POINT(-47.8900 -15.8000)'::extensions.geography,
  'Plano Piloto'
);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('70500000-0000-4000-8000-000000000010', '70500000-0000-4000-8000-000000000001', 'administrador');

insert into public.profissional (id, usuario_id, ponto_base)
values (
  '70500000-0000-4000-8000-000000000020',
  '70500000-0000-4000-8000-000000000002',
  'POINT(-47.8900 -15.8000)'::extensions.geography
);

insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por,
  publicado_em
) values
  ('70500000-0000-4000-8000-000000000030', '70500000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8900 -15.8000)'::extensions.geography,
   'Salão Principal', 15000, 1, true, false, false, 'Gerente 705',
   '2026-10-17 18:00:00-03', '2026-10-18 02:00:00-03', 'selecao', 'publicada',
   'Plano Piloto', '70500000-0000-4000-8000-0000000000c1', '70500000-0000-4000-8000-000000000001',
   '2026-10-16 12:00:00-03'),
  ('70500000-0000-4000-8000-000000000031', '70500000-0000-4000-8000-000000000010',
   (select id from public.funcao limit 1), 'POINT(-47.8900 -15.8000)'::extensions.geography,
   'Salão Lateral', 15000, 1, true, false, false, 'Gerente 705',
   '2026-10-17 18:00:00-03', '2026-10-18 02:00:00-03', 'selecao', 'publicada',
   'Plano Piloto', '70500000-0000-4000-8000-0000000000c2', '70500000-0000-4000-8000-000000000001',
   '2026-10-16 12:00:00-03');

insert into public.notificacao (
  id, usuario_id, profissional_id, tipo, referencia_id, urgente, estado_entrega, enviada_em
) values
  ('70500000-0000-4000-8000-000000000041', '70500000-0000-4000-8000-000000000002',
   '70500000-0000-4000-8000-000000000020', 'vaga', '70500000-0000-4000-8000-000000000030', false, 'pendente', '2026-10-16 11:00:00-03'),
  ('70500000-0000-4000-8000-000000000042', '70500000-0000-4000-8000-000000000002',
   '70500000-0000-4000-8000-000000000020', 'vagas_agrupadas', '70500000-0000-4000-8000-000000000031', false, 'pendente', '2026-10-16 11:00:00-03');

-- Despacho 1: notificacao_id NULL (esperando teto)
-- Despacho 2: notificacao_id preenchido (já notificado)
insert into public.despacho (id, vaga_id, profissional_id, notificacao_id, criado_em)
values
  ('70500000-0000-4000-8000-000000000051', '70500000-0000-4000-8000-000000000030',
   '70500000-0000-4000-8000-000000000020', null, '2026-10-16 11:30:00-03'),
  ('70500000-0000-4000-8000-000000000052', '70500000-0000-4000-8000-000000000031',
   '70500000-0000-4000-8000-000000000020', '70500000-0000-4000-8000-000000000041', '2026-10-16 11:00:00-03');

-- ── 3. Testes de Imutabilidade (RNF13, RN23) ────────────────────────────────────

-- 1. Tentativa de DELETE direto em despacho deve falhar (23001)
select throws_ok(
  $$delete from public.despacho where id = '70500000-0000-4000-8000-000000000051'$$,
  '23001',
  'registro de despacho nao pode ser apagado',
  'DELETE em public.despacho é bloqueado com restrict_violation (RNF13)'
);

-- 2. Tentativa de alterar vaga_id deve falhar
select throws_ok(
  $$update public.despacho set vaga_id = '70500000-0000-4000-8000-000000000031' where id = '70500000-0000-4000-8000-000000000051'$$,
  '23001',
  'registro de despacho so muda em notificacao_id, uma vez',
  'UPDATE alterando vaga_id é bloqueado com restrict_violation'
);

-- 3. Tentativa de alterar profissional_id deve falhar
select throws_ok(
  $$update public.despacho set profissional_id = '70500000-0000-4000-8000-000000000021' where id = '70500000-0000-4000-8000-000000000051'$$,
  '23001',
  'registro de despacho so muda em notificacao_id, uma vez',
  'UPDATE alterando profissional_id é bloqueado com restrict_violation'
);

-- 4. Tentativa de alterar criado_em deve falhar
select throws_ok(
  $$update public.despacho set criado_em = '2026-10-16 10:00:00-03' where id = '70500000-0000-4000-8000-000000000051'$$,
  '23001',
  'registro de despacho so muda em notificacao_id, uma vez',
  'UPDATE alterando criado_em é bloqueado com restrict_violation'
);

-- 4. Tentativa de repontar notificacao_id já preenchido para outra notificação deve falhar
select throws_ok(
  $$update public.despacho set notificacao_id = '70500000-0000-4000-8000-000000000042' where id = '70500000-0000-4000-8000-000000000052'$$,
  '23001',
  'despacho ja tem notificacao',
  'UPDATE repontando notificacao_id já preenchido para outra notificação é bloqueado'
);

-- 5. Tentativa de anular notificacao_id já preenchido deve falhar
select throws_ok(
  $$update public.despacho set notificacao_id = null where id = '70500000-0000-4000-8000-000000000052'$$,
  '23001',
  'despacho ja tem notificacao',
  'UPDATE anulando notificacao_id existente é bloqueado'
);

-- 6. UPDATE idempotente mantendo todos os campos é permitido
select lives_ok(
  $$update public.despacho set id = id where id = '70500000-0000-4000-8000-000000000051'$$,
  'UPDATE idempotente mantendo todas as colunas é permitido'
);

-- 7. UPDATE preenchendo notificacao_id nulo pela primeira vez é permitido (RN23)
select lives_ok(
  $$update public.despacho set notificacao_id = '70500000-0000-4000-8000-000000000041' where id = '70500000-0000-4000-8000-000000000051'$$,
  'UPDATE preenchendo notificacao_id nulo pela primeira vez é permitido (RN23)'
);

select is(
  (select notificacao_id from public.despacho where id = '70500000-0000-4000-8000-000000000051'),
  '70500000-0000-4000-8000-000000000041'::uuid,
  'despacho agora possui notificacao_id gravado'
);

-- 8. Segunda tentativa de alterar notificacao_id agora que foi preenchido deve falhar ("uma vez só")
select throws_ok(
  $$update public.despacho set notificacao_id = '70500000-0000-4000-8000-000000000042' where id = '70500000-0000-4000-8000-000000000051'$$,
  '23001',
  'despacho ja tem notificacao',
  'segundo UPDATE em notificacao_id é bloqueado ("uma vez só", RN23)'
);

-- ── 4. Bypass de Retenção e Limpeza (RF25) ──────────────────────────────────────

-- 9. DELETE autorizado quando privado.retencao = 'on'
set local "privado.retencao" = 'on';

select lives_ok(
  $$delete from public.despacho where id = '70500000-0000-4000-8000-000000000052'$$,
  'DELETE é permitido quando sessão ativa privado.retencao = on (RF25)'
);

select is(
  (select count(*)::int from public.despacho where id = '70500000-0000-4000-8000-000000000052'),
  0,
  'registro de despacho foi efetivamente removido pelo expurgo de retenção'
);

select * from finish();

rollback;
