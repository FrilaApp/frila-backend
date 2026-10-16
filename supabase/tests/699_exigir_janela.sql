-- Janela regulamentar para check-in e check-out (RF09, RF10, RN14).
--
-- Cobertura da função `privado.exigir_janela(registrado_em timestamptz, inicio timestamptz, fim timestamptz)`
-- (migrações 20260925000000_checkin_e_checkout.sql e 20260925230000_janela_da_demonstracao.sql).
--
-- A função garante que o registro de presença ocorra entre 60 minutos antes do início
-- previsto e até o término previsto da posição, com tolerância máxima de 2 minutos
-- à frente do relógio do banco (`privado.agora() + 2 minutes`) para desvios do aparelho,
-- barrando registros no futuro e registros fora da janela.
--
-- Este teste valida:
--   1. Existência, linguagem e search_path vazio.
--   2. Controle de acesso estrito: sem EXECUTE para anon e authenticated; concedido a service_role.
--   3. Recusa com campo_obrigatorio quando registrado_em é nulo.
--   4. Recusa com registro_no_futuro quando registrado_em > agora + 2 minutos.
--   5. Recusa com fora_da_janela quando registrado_em < inicio - 60 minutos.
--   6. Recusa com fora_da_janela quando registrado_em > fim previsto.
--   7. Aceite nos marcos exatos da janela: início - 60 min e término previsto (fim).
--   8. Aceite dentro do intervalo regulamentar.

begin;

select plan(13);

-- ── 1. Estrutura e controle de acesso ────────────────────────────────────────

select has_function('privado', 'exigir_janela', array['timestamptz', 'timestamptz', 'timestamptz'],
  'privado.exigir_janela(timestamptz, timestamptz, timestamptz) existe');

select function_lang_is('privado', 'exigir_janela', array['timestamptz', 'timestamptz', 'timestamptz'], 'plpgsql',
  'privado.exigir_janela é em linguagem plpgsql');

select is(
  (select proconfig from pg_proc where proname = 'exigir_janela' and pronamespace = 'privado'::regnamespace),
  array['search_path=""'],
  'privado.exigir_janela tem search_path vazio'
);

select is(has_function_privilege('anon', 'privado.exigir_janela(timestamptz, timestamptz, timestamptz)', 'execute'), false,
  'anon não pode executar privado.exigir_janela');

select is(has_function_privilege('authenticated', 'privado.exigir_janela(timestamptz, timestamptz, timestamptz)', 'execute'), false,
  'authenticated não pode executar privado.exigir_janela');

select is(has_function_privilege('service_role', 'privado.exigir_janela(timestamptz, timestamptz, timestamptz)', 'execute'), true,
  'service_role pode executar privado.exigir_janela');

-- ── 2. Validações de presença e recusas ──────────────────────────────────────

select throws_matching(
  $$ select privado.exigir_janela(null, now(), now() + interval '4 hours') $$,
  'campo_obrigatorio',
  'registrado_em nulo levanta campo_obrigatorio'
);

select throws_matching(
  $$ select privado.exigir_janela(privado.agora() + interval '5 minutes', privado.agora(), privado.agora() + interval '4 hours') $$,
  'registro_no_futuro',
  'carimbo superior a agora + 2 minutos levanta registro_no_futuro'
);

select throws_matching(
  $$ select privado.exigir_janela(privado.agora() - interval '70 minutes', privado.agora(), privado.agora() + interval '4 hours') $$,
  'fora_da_janela',
  'registro anterior a inicio - 60 minutos levanta fora_da_janela'
);

select throws_matching(
  $$ select privado.exigir_janela(privado.agora(), privado.agora() - interval '5 hours', privado.agora() - interval '1 hour') $$,
  'fora_da_janela',
  'registro posterior ao fim do turno levanta fora_da_janela'
);

-- ── 3. Casos legítimos e bordas exatas ────────────────────────────────────────

select lives_ok(
  $$ select privado.exigir_janela(privado.agora(), privado.agora(), privado.agora() + interval '4 hours') $$,
  'registro no marco inicial do turno é aceito'
);

select lives_ok(
  $$ select privado.exigir_janela(privado.agora(), privado.agora() + interval '60 minutes', privado.agora() + interval '5 hours') $$,
  'borda exata inicial (inicio - 60 minutos) é aceita'
);

select lives_ok(
  $$ select privado.exigir_janela(privado.agora(), privado.agora() - interval '4 hours', privado.agora()) $$,
  'borda exata final (em = fim) é aceita'
);

select * from finish();

rollback;
