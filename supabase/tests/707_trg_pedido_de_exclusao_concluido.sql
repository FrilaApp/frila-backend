-- 707_trg_pedido_de_exclusao_concluido.sql
--
-- Cobertura pgTAP do trigger pedido_de_exclusao_concluido e da função privado.pedido_de_exclusao_concluido().
-- Regra de Negócio: RF25 / LGPD (Art. 18 VI).
-- Migração: 20260930090000_rastro_do_pedido_de_exclusao.sql:163-185.
--
-- Contexto e Conexão Arquitetural:
--   O trigger é acionado em AFTER UPDATE OF estado em public.usuario sob a condição
--   WHEN (new.estado = 'anonimizada' and old.estado <> 'anonimizada').
--   Ele delega para privado.concluir_pedido_de_exclusao(new.id, coalesce(new.anonimizado_em, privado.agora())),
--   garantindo que qualquer transição para anonimização comite a conclusão do pedido
--   na mesma transação atômica do banco. No cenário de exclusão que anonimiza mas
--   falha ao apagar a credencial no Auth, se o passo subsequente de remoção falhar,
--   o rastro já está como 'concluido'.
--
-- 1. Metadados e privilégios mínimos:
--    - Trigger registrado em public.usuario com tipo AFTER UPDATE.
--    - privado.pedido_de_exclusao_concluido() com search_path="" vazio fixado.
--    - Privilégios: service_role permitido; authenticated, anon e public negados.
-- 2. Exercício e Borda da Cláusula WHEN:
--    - Transição de ativa -> anonimizada dispara o trigger e conclui o pedido com data.
--    - Update com estado no SET em conta já anonimizada (old.estado = anonimizada) não dispara.
--    - Update em outras colunas (nome, telefone) sem alteração de estado não dispara o trigger.
--    - Update de ativa -> suspensa não dispara o trigger (pedido segue pendente).
-- 3. Atomicidade e Integração com privado.excluir_conta:
--    - Aborto de transação simulado com savepoint reverte tanto a anonimização quanto a conclusão.
--    - Execução de privado.excluir_conta() real comuta gatilho e conclui o pedido atomicamente.
-- 4. Prova de Mutação:
--    - Sem o trigger (DROP TRIGGER), a transição para anonimizada deixa o pedido pendente.

begin;

-- Pré-requisito canônico: habilitar ambiente de teste e congelar relógio antes de inserir dados
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local timezone = 'UTC';
set local frila.agora = '2026-10-20 12:00:00+00';

select plan(20);

-- ── 1. Metadados e Privilégios Mínimos ───────────────────────────────────────

select has_trigger(
  'public',
  'usuario',
  'pedido_de_exclusao_concluido',
  'tabela public.usuario possui o trigger pedido_de_exclusao_concluido'
);

select has_function(
  'privado',
  'pedido_de_exclusao_concluido',
  array[]::text[],
  'privado.pedido_de_exclusao_concluido() existe no schema privado'
);

select function_returns(
  'privado',
  'pedido_de_exclusao_concluido',
  array[]::text[],
  'trigger',
  'privado.pedido_de_exclusao_concluido() retorna trigger'
);

select is_definer(
  'privado',
  'pedido_de_exclusao_concluido',
  array[]::text[],
  'privado.pedido_de_exclusao_concluido() é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'pedido_de_exclusao_concluido' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'privado.pedido_de_exclusao_concluido() possui search_path="" vazio fixado'
);

select ok(
  has_function_privilege('service_role', 'privado.pedido_de_exclusao_concluido()', 'execute'),
  'service_role pode executar privado.pedido_de_exclusao_concluido()'
);

select ok(
  not has_function_privilege('authenticated', 'privado.pedido_de_exclusao_concluido()', 'execute'),
  'authenticated não pode executar privado.pedido_de_exclusao_concluido()'
);

select ok(
  not has_function_privilege('anon', 'privado.pedido_de_exclusao_concluido()', 'execute'),
  'anon não pode executar privado.pedido_de_exclusao_concluido()'
);

select ok(
  not has_function_privilege('public', 'privado.pedido_de_exclusao_concluido()', 'execute'),
  'public não pode executar privado.pedido_de_exclusao_concluido()'
);

-- ── 2. Cenário de Teste (prefixo 707) ──────────────────────────────────────────

-- Inserção de contas com padrão canônico (termos_versao e termos_aceite_em explícitos sem now() conforme 694):
insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado, anonimizado_em
) values
  ('70700000-0000-4000-8000-000000000001', 'profissional', 'Titular 707-1', '+5561970700001', 'u707_1@test.com', '1992-01-01', '2026-09-22', '2026-10-20 12:00:00+00', 'ativa', null),
  ('70700000-0000-4000-8000-000000000002', 'profissional', 'Conta encerrada', null, null, '1992-01-01', '2026-09-22', '2026-10-20 12:00:00+00', 'anonimizada', '2026-10-19 10:00:00+00'),
  ('70700000-0000-4000-8000-000000000003', 'profissional', 'Titular 707-3', '+5561970700003', 'u707_3@test.com', '1992-01-01', '2026-09-22', '2026-10-20 12:00:00+00', 'ativa', null),
  ('70700000-0000-4000-8000-000000000004', 'profissional', 'Titular 707-4', '+5561970700004', 'u707_4@test.com', '1992-01-01', '2026-09-22', '2026-10-20 12:00:00+00', 'ativa', null),
  ('70700000-0000-4000-8000-000000000005', 'profissional', 'Titular 707-5', '+5561970700005', 'u707_5@test.com', '1992-01-01', '2026-09-22', '2026-10-20 12:00:00+00', 'ativa', null),
  ('70700000-0000-4000-8000-000000000006', 'profissional', 'Titular 707-6', '+5561970700006', 'u707_6@test.com', '1992-01-01', '2026-09-22', '2026-10-20 12:00:00+00', 'ativa', null);

-- Pedidos de exclusão pendentes correspondentes:
insert into public.pedido_de_exclusao (usuario_id, pedido_em, estado, tentativas) values
  ('70700000-0000-4000-8000-000000000001', '2026-10-20 10:00:00+00', 'pendente', 1),
  ('70700000-0000-4000-8000-000000000002', '2026-10-19 09:00:00+00', 'pendente', 1),
  ('70700000-0000-4000-8000-000000000003', '2026-10-20 10:00:00+00', 'pendente', 1),
  ('70700000-0000-4000-8000-000000000004', '2026-10-20 10:00:00+00', 'pendente', 1),
  ('70700000-0000-4000-8000-000000000005', '2026-10-20 10:00:00+00', 'pendente', 1),
  ('70700000-0000-4000-8000-000000000006', '2026-10-20 10:00:00+00', 'pendente', 1);

-- ── 3. Disparo Positivo: Transição de ativa para anonimizada ─────────────────

update public.usuario
   set estado = 'anonimizada',
       anonimizado_em = '2026-10-20 12:30:00+00',
       nome = 'Conta encerrada',
       email = null,
       telefone = null
 where id = '70700000-0000-4000-8000-000000000001';

select is(
  (select estado from public.pedido_de_exclusao where usuario_id = '70700000-0000-4000-8000-000000000001'),
  'concluido',
  'trigger dispara em transicao para anonimizada e marca pedido_de_exclusao como concluido'
);

select is(
  (select concluido_em from public.pedido_de_exclusao where usuario_id = '70700000-0000-4000-8000-000000000001'),
  '2026-10-20 12:30:00+00'::timestamptz,
  'trigger preenche concluido_em exatamente com o valor de anonimizado_em do usuario'
);

-- ── 4. Disparo Negativo: Cláusula WHEN do Gatilho ─────────────────────────────

-- Caso 4a: Update com estado no SET em conta já anonimizada (old.estado = 'anonimizada') exercita o WHEN
update public.usuario
   set estado = 'anonimizada'
 where id = '70700000-0000-4000-8000-000000000002';

select is(
  (select estado from public.pedido_de_exclusao where usuario_id = '70700000-0000-4000-8000-000000000002'),
  'pendente',
  'clausula WHEN impede disparo quando old.estado ja era anonimizada'
);

-- Caso 4b: Update em outra coluna (nome, telefone) mantendo estado ativa não dispara
update public.usuario
   set nome = 'Nome Alterado 707-3',
       telefone = '+5561970709999'
 where id = '70700000-0000-4000-8000-000000000003';

select is(
  (select estado from public.pedido_de_exclusao where usuario_id = '70700000-0000-4000-8000-000000000003'),
  'pendente',
  'update em colunas normais sem alterar estado mantem pedido pendente'
);

-- Caso 4c: Update alterando estado para 'suspensa' (new.estado <> 'anonimizada') não dispara
update public.usuario
   set estado = 'suspensa'
 where id = '70700000-0000-4000-8000-000000000004';

select is(
  (select estado from public.pedido_de_exclusao where usuario_id = '70700000-0000-4000-8000-000000000004'),
  'pendente',
  'update de ativa para suspensa nao dispara trigger e pedido segue pendente'
);

-- ── 5. Atomicidade e Integração com privado.excluir_conta ─────────────────────

-- Cenário com falha forçada: se a exclusão aborta na transação, tudo reverte
savepoint antes_da_exclusao_com_falha;

select throws_ok(
  $$select privado.excluir_conta('70700000-0000-4000-8000-000000000006'),
           1 / (select 0)$$,
  '22012',
  NULL,
  'a exclusao aborta no meio (como em 40P01), revertendo a transacao'
);

rollback to savepoint antes_da_exclusao_com_falha;

select is(
  (select estado from public.pedido_de_exclusao where usuario_id = '70700000-0000-4000-8000-000000000006'),
  'pendente',
  'apos falha forcada e rollback da exclusao, pedido de exclusao segue pendente'
);

select is(
  (select estado from public.usuario where id = '70700000-0000-4000-8000-000000000006'),
  'ativa',
  'usuario permanece ativo apos reversao atomica da transacao que falhou'
);

-- Cenário com exclusão real que conclui: privado.excluir_conta() aciona o gatilho
select privado.excluir_conta('70700000-0000-4000-8000-000000000006');

select is(
  (select estado from public.pedido_de_exclusao where usuario_id = '70700000-0000-4000-8000-000000000006'),
  'concluido',
  'privado.excluir_conta() real comuta gatilho e marca pedido como concluido'
);

select is(
  (select concluido_em from public.pedido_de_exclusao where usuario_id = '70700000-0000-4000-8000-000000000006'),
  '2026-10-20 12:00:00+00'::timestamptz,
  'privado.excluir_conta() real preenche concluido_em com a data da exclusao'
);

-- ── 6. Prova de Mutação (Sem o Gatilho Ativo) ─────────────────────────────────

-- Remove temporariamente o trigger da sessão de teste:
drop trigger pedido_de_exclusao_concluido on public.usuario;

-- Executa transição para anonimizada na conta 707-5:
update public.usuario
   set estado = 'anonimizada',
       anonimizado_em = '2026-10-20 12:45:00+00',
       nome = 'Conta encerrada',
       email = null,
       telefone = null
 where id = '70700000-0000-4000-8000-000000000005';

select is(
  (select estado from public.pedido_de_exclusao where usuario_id = '70700000-0000-4000-8000-000000000005'),
  'pendente',
  'prova de mutacao: sem o trigger pedido_de_exclusao_concluido, transicao para anonimizada deixa pedido pendente'
);

select * from finish();
rollback;
