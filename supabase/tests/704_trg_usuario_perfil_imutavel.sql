-- 704_trg_usuario_perfil_imutavel.sql
--
-- Cobertura pgTAP do trigger usuario_perfil_imutavel e da função privado.perfil_imutavel().
-- Regra de Negócio: RN25 (cada conta tem UM perfil, escolhido no cadastro e sem troca).
-- Migrações: 20260922150100_identidade.sql:67 e 20260922220000_search_path_e_rls_automatico.sql:25.
--
-- 1. Metadados e privilégios:
--    - Trigger usuario_perfil_imutavel registrado em public.usuario.
--    - privado.perfil_imutavel() com search_path="" fixado.
--    - Privilégios mínimos: service_role executa; authenticated, anon e public NÃO executam.
-- 2. Integridade e Imutabilidade (RN25):
--    - Bloqueia UPDATE alterando perfil de 'profissional' para 'contratante' (erro 23514 / check_violation).
--    - Bloqueia UPDATE alterando perfil de 'contratante' para 'profissional' (erro 23514 / check_violation).
--    - Permite UPDATE mantendo o mesmo perfil (cláusula WHEN: new.perfil is distinct from old.perfil).
--    - Permite UPDATE em outras colunas (nome, telefone) sem alteração de perfil.

begin;

-- Pré-requisito: habilitar ambiente de teste e congelar relógio antes de inserir dados
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-16 12:00:00-03';

select plan(14);

-- ── 1. Metadados e privilégios ──────────────────────────────────────────────────

select has_trigger(
  'public',
  'usuario',
  'usuario_perfil_imutavel',
  'tabela public.usuario possui o trigger usuario_perfil_imutavel'
);

select is(
  (select proconfig from pg_proc where proname = 'perfil_imutavel' and pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'privado.perfil_imutavel() possui search_path="" fixado'
);

select ok(
  has_function_privilege('service_role', 'privado.perfil_imutavel()', 'execute'),
  'service_role executa privado.perfil_imutavel()'
);

select ok(
  not has_function_privilege('authenticated', 'privado.perfil_imutavel()', 'execute'),
  'authenticated não executa privado.perfil_imutavel()'
);

select ok(
  not has_function_privilege('anon', 'privado.perfil_imutavel()', 'execute'),
  'anon não executa privado.perfil_imutavel()'
);

select ok(
  not has_function_privilege('public', 'privado.perfil_imutavel()', 'execute'),
  'public não executa privado.perfil_imutavel()'
);

-- ── 2. Cenário de teste (prefixo 704) ──────────────────────────────────────────

insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado
) values
  ('70400000-0000-4000-8000-000000000001', 'profissional', 'Profissional 704', '+5561970400001', 'p704@test.com', '1995-05-05', '2026-09-22', now(), 'ativa'),
  ('70400000-0000-4000-8000-000000000002', 'contratante',  'Contratante 704',  '+5561970400002', 'c704@test.com', '1990-10-10', '2026-09-22', now(), 'ativa');

-- ── 3. Testes de Imutabilidade (RN25) ───────────────────────────────────────────

-- Tentativa de mudar profissional -> contratante deve levantar check_violation (23514)
select throws_ok(
  $$update public.usuario set perfil = 'contratante' where id = '70400000-0000-4000-8000-000000000001'$$,
  '23514',
  'o perfil da conta não muda (RN25)',
  'UPDATE alterando perfil de profissional para contratante é bloqueado com erro 23514 (RN25)'
);

-- Tentativa de mudar contratante -> profissional deve levantar check_violation (23514)
select throws_ok(
  $$update public.usuario set perfil = 'profissional' where id = '70400000-0000-4000-8000-000000000002'$$,
  '23514',
  'o perfil da conta não muda (RN25)',
  'UPDATE alterando perfil de contratante para profissional é bloqueado com erro 23514 (RN25)'
);

-- UPDATE idempotente no perfil não dispara o trigger (cláusula WHEN: new.perfil is distinct from old.perfil)
select lives_ok(
  $$update public.usuario set perfil = 'profissional' where id = '70400000-0000-4000-8000-000000000001'$$,
  'UPDATE idempotente mantendo o perfil profissional não dispara o trigger'
);

select lives_ok(
  $$update public.usuario set perfil = 'contratante' where id = '70400000-0000-4000-8000-000000000002'$$,
  'UPDATE idempotente mantendo o perfil contratante não dispara o trigger'
);

-- UPDATE em outras colunas sem alterar o perfil é permitido
select lives_ok(
  $$update public.usuario set nome = 'Profissional Atualizado 704', telefone = '+5561970400099' where id = '70400000-0000-4000-8000-000000000001'$$,
  'UPDATE em outras colunas (nome, telefone) sem alterar perfil é executado com sucesso'
);

select is(
  (select nome from public.usuario where id = '70400000-0000-4000-8000-000000000001'),
  'Profissional Atualizado 704',
  'nome do usuário foi atualizado com sucesso'
);

select is(
  (select perfil from public.usuario where id = '70400000-0000-4000-8000-000000000001'),
  'profissional'::public.perfil_conta,
  'perfil do profissional permanece inalterado'
);

select is(
  (select perfil from public.usuario where id = '70400000-0000-4000-8000-000000000002'),
  'contratante'::public.perfil_conta,
  'perfil do contratante permanece inalterado'
);

select * from finish();

rollback;
