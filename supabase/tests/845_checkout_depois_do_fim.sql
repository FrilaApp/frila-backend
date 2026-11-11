-- 845_checkout_depois_do_fim.sql
--
-- Cobertura da correção do bug de check-out pós-fim (migração 20261111180000).
--
-- Requisitos cobertos:
--   1. Estrutura, search_path e permissões de privado.exigir_janela_checkout.
--   2. Borda inferior: check-out antecipado permitido a partir de inicio - 60 min; antes recusa.
--   3. Borda superior estendida: fim + 1 min aceito, fim + 60 min aceito, fim + 60 min 1s recusa fora_da_janela.
--   4. Trava contra o futuro: agora + 2 min aceito, agora + 2 min 1s recusa registro_no_futuro.
--   5. Conta de demonstração da App Store: atravessa a janela de turno antigo, mas respeita a trava de futuro.
--   6. Prova integrada via public.fazer_checkout:
--      - Check-out antecipado aceito (durante o turno).
--      - Check-out em fim + 1 min aceito.
--      - Check-out em fim + 60 min aceito.
--      - Check-out em fim + 61 min recusado com 422 fora_da_janela.
--   7. Prova de não-regressão do check-in:
--      - Check-in depois do fim continua estritamente recusado com 422 fora_da_janela.

begin;

-- Configuração determinística do relógio de teste
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
set local frila.agora = '2030-06-01 12:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste-checkout';

select plan(22);

-- ── 1. Estrutura e permissões de privado.exigir_janela_checkout ───────────────

select has_function(
  'privado', 'exigir_janela_checkout',
  array['timestamptz', 'timestamptz', 'timestamptz'],
  'privado.exigir_janela_checkout(timestamptz, timestamptz, timestamptz) existe'
);

select function_lang_is(
  'privado', 'exigir_janela_checkout',
  array['timestamp with time zone', 'timestamp with time zone', 'timestamp with time zone'],
  'plpgsql',
  'privado.exigir_janela_checkout é em plpgsql'
);

select is(
  (select proconfig from pg_proc where proname = 'exigir_janela_checkout' and pronamespace = 'privado'::regnamespace),
  array['search_path=""'],
  'privado.exigir_janela_checkout tem search_path vazio'
);

select is(
  has_function_privilege('anon', 'privado.exigir_janela_checkout(timestamptz, timestamptz, timestamptz)', 'execute'),
  false,
  'anon não pode executar privado.exigir_janela_checkout'
);

select is(
  has_function_privilege('authenticated', 'privado.exigir_janela_checkout(timestamptz, timestamptz, timestamptz)', 'execute'),
  false,
  'authenticated não pode executar privado.exigir_janela_checkout'
);

select is(
  has_function_privilege('service_role', 'privado.exigir_janela_checkout(timestamptz, timestamptz, timestamptz)', 'execute'),
  true,
  'service_role pode executar privado.exigir_janela_checkout'
);

-- ── 2. Testes unitários da função de janela do check-out ─────────────────────

-- Turno das 08:00 às 12:00 (fim previsto = 12:00; tolerância de check-out até 13:00)

select throws_ok(
  $$ select privado.exigir_janela_checkout(null, '2030-06-01 08:00:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "registrado_em", "hint" : null}',
  'registrado_em nulo levanta PGRST campo_obrigatorio'
);

select lives_ok(
  $$ select privado.exigir_janela_checkout('2030-06-01 12:02:00+00'::timestamptz, '2030-06-01 08:00:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz) $$,
  'check-out com carimbo na tolerância máxima de futuro (+2 min) é aceito'
);

select throws_ok(
  $$ select privado.exigir_janela_checkout('2030-06-01 12:02:01+00'::timestamptz, '2030-06-01 08:00:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "registro_no_futuro", "message" : "registro_no_futuro", "details" : null, "hint" : null}',
  'check-out além de 2 min no futuro levanta registro_no_futuro'
);

select lives_ok(
  $$ select privado.exigir_janela_checkout('2030-06-01 07:00:00+00'::timestamptz, '2030-06-01 08:00:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz) $$,
  'borda inferior: check-out antecipado a 60 min antes do início é aceito'
);

select throws_ok(
  $$ select privado.exigir_janela_checkout('2030-06-01 06:59:59+00'::timestamptz, '2030-06-01 08:00:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'check-out antes de inicio - 60 min levanta fora_da_janela'
);

-- Avança o relógio para 13:30 para testar horários pós-fim
set local frila.agora = '2030-06-01 13:30:00+00';

select lives_ok(
  $$ select privado.exigir_janela_checkout('2030-06-01 12:01:00+00'::timestamptz, '2030-06-01 08:00:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz) $$,
  'borda superior estendida: check-out em fim + 1 min é aceito'
);

select lives_ok(
  $$ select privado.exigir_janela_checkout('2030-06-01 13:00:00+00'::timestamptz, '2030-06-01 08:00:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz) $$,
  'borda superior estendida: check-out em fim + 60 min é aceito'
);

select throws_ok(
  $$ select privado.exigir_janela_checkout('2030-06-01 13:00:01+00'::timestamptz, '2030-06-01 08:00:00+00'::timestamptz, '2030-06-01 12:00:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'check-out além de fim + 60 min levanta fora_da_janela'
);

-- ── 3. Conta de demonstração com privado.exigir_janela_checkout ───────────────

insert into public.usuario (
  id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao
) values (
  'f8450000-0000-4000-8000-000000000099',
  'profissional',
  'Avaliador Checkout',
  '+5561999998459',
  'revisao-checkout@frila.app',
  '1992-05-15',
  '0.1.0',
  '2030-06-01 12:00:00+00',
  true
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', 'f8450000-0000-4000-8000-000000000099', 'role', 'authenticated')::text,
  true
);

select lives_ok(
  $$ select privado.exigir_janela_checkout('2030-06-01 13:30:00+00'::timestamptz, '2030-05-01 10:00:00+00'::timestamptz, '2030-05-01 14:00:00+00'::timestamptz) $$,
  'conta de demonstração atravessa a janela de check-out em turno expirado há dias'
);

select throws_ok(
  $$ select privado.exigir_janela_checkout('2030-06-01 13:32:01+00'::timestamptz, '2030-05-01 10:00:00+00'::timestamptz, '2030-05-01 14:00:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "registro_no_futuro", "message" : "registro_no_futuro", "details" : null, "hint" : null}',
  'conta de demonstração continua barrada contra carimbos no futuro no check-out'
);

-- ── 4. Prova integrada de ponta a ponta (fazer_checkout e fazer_checkin) ───────

create temp table ids as
select 'c8450000-0000-4000-8000-000000000001'::uuid as contratante_user,
       'c8450000-0000-4000-8000-000000000002'::uuid as prof_user,
       'c8450000-0000-4000-8000-000000000010'::uuid as prof_id,
       'c8450000-0000-4000-8000-000000000020'::uuid as estab_id,
       'c8450000-0000-4000-8000-000000000030'::uuid as vaga_id;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select contratante_user, 'contratante', 'Casa 845', '+5561999998451', 'casa845@test.invalid', '1985-01-01', '1.0', '2026-09-20' from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select estab_id, 'Restaurante 845', '84500000000100', 'food_service', 'Rua 845', 'POINT(-47.8800 -15.7700)'::extensions.geography from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select contratante_user, estab_id, 'administrador' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select prof_user, 'profissional', 'Prof 845', '+5561999998452', 'prof845@test.invalid', '1995-01-01', '1.0', '2026-09-20' from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select prof_id, prof_user, 'POINT(-47.8800 -15.7700)' from ids;

-- Helper para criar vaga, posição e turno em dia específico sem conflito de sobreposição
create function pg_temp.criar_turno(
  p_dia int,
  p_com_checkin boolean default true
) returns uuid language plpgsql as $$
declare
  v_inicio timestamptz := ('2030-06-0' || p_dia || ' 18:00:00+00')::timestamptz;
  v_fim    timestamptz := ('2030-06-0' || p_dia || ' 22:00:00+00')::timestamptz;
  v_vaga   uuid := gen_random_uuid();
  v_pos    uuid := gen_random_uuid();
  v_t      uuid := gen_random_uuid();
begin
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
  ) values (
    v_vaga, (select estab_id from ids), (select id from public.funcao limit 1),
    v_inicio, v_fim, 'Salão 845', 'POINT(-47.8800 -15.7700)',
    15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', '2030-06-01 12:00:00+00', gen_random_uuid(), (select contratante_user from ids)
  );

  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, inicio_em, fim_em)
  values (v_pos, v_vaga, (select prof_id from ids), 'confirmada',
          '2030-06-01 12:00:00+00', v_inicio, v_fim);

  if p_com_checkin then
    insert into public.turno (id, posicao_id, checkin_em, checkin_distancia_m, checkin_tipo, verificacao, valor_acordado_centavos)
    values (v_t, v_pos, v_inicio + interval '5 minutes', 30, 'geolocalizado', 'verificado', 15000);
  else
    insert into public.turno (id, posicao_id, valor_acordado_centavos)
    values (v_t, v_pos, 15000);
  end if;

  return v_t;
end;
$$;

-- Autentica como o profissional Prof 845
select set_config(
  'request.jwt.claims',
  json_build_object('sub', 'c8450000-0000-4000-8000-000000000002', 'role', 'authenticated')::text,
  true
);

-- 4.1 Check-out antecipado às 21:00 (durante o turno que termina às 22:00) aceito
set local frila.agora = '2030-06-01 21:00:00+00';
select is(
  (select public.fazer_checkout(pg_temp.criar_turno(1, true), 40, '2030-06-01 21:00:00+00'::timestamptz))->>'distancia_m',
  '40',
  'fazer_checkout: saída antecipada às 21:00 (antes de fim 22:00) continua aceita'
);

-- 4.2 Check-out às 22:01 (fim + 1 min) aceito
set local frila.agora = '2030-06-02 22:01:00+00';
select is(
  (select public.fazer_checkout(pg_temp.criar_turno(2, true), 50, '2030-06-02 22:01:00+00'::timestamptz))->>'distancia_m',
  '50',
  'fazer_checkout: saída em fim + 1 min (22:01) é aceita com sucesso'
);

-- 4.3 Check-out às 23:00 (fim + 60 min exatos) aceito
set local frila.agora = '2030-06-03 23:00:00+00';
select is(
  (select public.fazer_checkout(pg_temp.criar_turno(3, true), 50, '2030-06-03 23:00:00+00'::timestamptz))->>'distancia_m',
  '50',
  'fazer_checkout: saída em fim + 60 min (23:00) na borda da tolerância é aceita'
);

-- 4.4 Check-out às 23:01 (fim + 61 min) recusado com 422 fora_da_janela
set local frila.agora = '2030-06-04 23:05:00+00';
select throws_ok(
  format($$ select public.fazer_checkout(%L::uuid, 50, '2030-06-04 23:01:00+00'::timestamptz) $$, pg_temp.criar_turno(4, true)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'fazer_checkout: saída em fim + 61 min (23:01) é recusada com 422 fora_da_janela'
);

-- ── 5. Prova de não-regressão do check-in ──────────────────────────────────────

-- 5.1 Check-in às 22:01 (1 minuto após fim 22:00) CONTINUA RECUSADO
set local frila.agora = '2030-06-05 22:05:00+00';
select throws_ok(
  format($$ select public.fazer_checkin(%L::uuid, 30, '2030-06-05 22:01:00+00'::timestamptz) $$, pg_temp.criar_turno(5, false)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'fazer_checkin: check-in após o término do turno continua estritamente recusado com fora_da_janela'
);

-- 5.2 Check-in às 23:00 (fim + 60 min) também continua recusado
set local frila.agora = '2030-06-06 23:05:00+00';
select throws_ok(
  format($$ select public.fazer_checkin(%L::uuid, 30, '2030-06-06 23:00:00+00'::timestamptz) $$, pg_temp.criar_turno(6, false)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'fazer_checkin: a tolerância de 60 min pós-fim NÃO se aplica ao check-in'
);

select * from finish();

rollback;
