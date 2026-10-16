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
-- Exceção da demonstração (App Review): contas marcadas com `demonstracao = true`
-- atravessam qualquer janela de turno (para permitir testes com turnos envelhecidos do seed),
-- mas a trava de segurança contra carimbos no futuro permanece estritamente ativa.
--
-- Este teste valida:
--   1. Existência, linguagem e search_path vazio.
--   2. Controle de acesso estrito: sem EXECUTE para anon e authenticated; concedido a service_role.
--   3. Recusa com campo_obrigatorio (PGRST) quando registrado_em é nulo.
--   4. Tolerância máxima no futuro: agora + 2 minutos aceito; agora + 2 min 1s rejeitado (registro_no_futuro).
--   5. Intervalo regulamentar normal aceito.
--   6. Borda exata inicial: inicio - 60 minutos aceito; 1 segundo antes rejeitado (fora_da_janela).
--   7. Borda exata final: fim previsto aceito; 1 segundo depois rejeitado (fora_da_janela).
--   8. Isenção da conta de demonstração: atravessa turnos expirados, mas é barrada no futuro.

begin;

-- Configuração determinística do relógio de teste
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict do nothing;
set local frila.agora = '2030-06-01 12:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste';

select plan(17);

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

-- ── 2. Validações para conta padrão (fora de demonstração) ───────────────────

-- Limites temporais do turno base: 12:00 às 16:00
select throws_ok(
  $$ select privado.exigir_janela(null, '2030-06-01 12:00:00+00'::timestamptz, '2030-06-01 16:00:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "registrado_em", "hint" : null}',
  'registrado_em nulo levanta PGRST campo_obrigatorio'
);

select lives_ok(
  $$ select privado.exigir_janela('2030-06-01 12:02:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz, '2030-06-01 16:00:00+00'::timestamptz) $$,
  'carimbo na tolerância exata de 2 minutos à frente de agora é aceito'
);

select throws_ok(
  $$ select privado.exigir_janela('2030-06-01 12:02:01+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz, '2030-06-01 16:00:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "registro_no_futuro", "message" : "registro_no_futuro", "details" : null, "hint" : null}',
  'carimbo a 2 minutos e 1 segundo à frente de agora levanta registro_no_futuro'
);

select lives_ok(
  $$ select privado.exigir_janela('2030-06-01 12:00:00+00'::timestamptz, '2030-06-01 11:00:00+00'::timestamptz, '2030-06-01 15:00:00+00'::timestamptz) $$,
  'registro dentro do intervalo regulamentar é aceito'
);

select lives_ok(
  $$ select privado.exigir_janela('2030-06-01 11:00:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz, '2030-06-01 16:00:00+00'::timestamptz) $$,
  'borda exata de abertura (inicio - 60 minutos) é aceita'
);

select throws_ok(
  $$ select privado.exigir_janela('2030-06-01 10:59:59+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz, '2030-06-01 16:00:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'registro a 60 minutos e 1 segundo antes do início levanta fora_da_janela'
);

select lives_ok(
  $$ select privado.exigir_janela('2030-06-01 12:00:00+00'::timestamptz, '2030-06-01 08:00:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz) $$,
  'borda exata de fechamento (registrado_em = fim) é aceita'
);

select throws_ok(
  $$ select privado.exigir_janela('2030-06-01 12:00:00+00'::timestamptz, '2030-06-01 08:00:00+00'::timestamptz, '2030-06-01 11:59:59+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'registro posterior ao término previsto (fim) levanta fora_da_janela'
);

-- ── 3. Conta de demonstração (isenção de janela e retenção de trava de futuro) ──

-- Cadastra usuário marcado para demonstração
insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao
) values (
  'f9000000-0000-4000-8000-000000000099',
  'profissional',
  'Avaliador App Store',
  '+5561999990099',
  'revisao-appstore@frila.app',
  '1992-05-15',
  '0.1.0',
  '2030-06-01 12:00:00+00',
  true
);

-- Simula sessão autenticada com os claims do usuário de demonstração
select set_config(
  'request.jwt.claims',
  json_build_object('sub', 'f9000000-0000-4000-8000-000000000099', 'role', 'authenticated')::text,
  true
);

select is(
  privado.conta_de_demonstracao(),
  true,
  'sessão autenticada do usuário de teste é reconhecida como conta de demonstração'
);

-- Turno ocorrido há 30 dias (fora da janela regulamentar)
select lives_ok(
  $$ select privado.exigir_janela('2030-06-01 12:00:00+00'::timestamptz, '2030-05-01 10:00:00+00'::timestamptz, '2030-05-01 14:00:00+00'::timestamptz) $$,
  'conta de demonstração atravessa a janela de turno expirado (isenção RN14)'
);

-- Mesmo em conta de demonstração, carimbo além de agora + 2 minutos é terminantemente barrado
select throws_ok(
  $$ select privado.exigir_janela('2030-06-01 12:02:01+00'::timestamptz, '2030-05-01 10:00:00+00'::timestamptz, '2030-05-01 14:00:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "registro_no_futuro", "message" : "registro_no_futuro", "details" : null, "hint" : null}',
  'conta de demonstração continua proibida de registrar ponto no futuro (sem isenção)'
);

select * from finish();

rollback;
