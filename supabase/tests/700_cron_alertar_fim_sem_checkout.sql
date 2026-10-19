-- 700_cron_alertar_fim_sem_checkout.sql
-- Cobertura pgTAP do job pg_cron 'alertar_fim_sem_checkout' e função privado.alertar_fim_sem_checkout()
-- Lacuna #6 do MAPA-COBERTURA-EDGE-FUNCTIONS-E-CRON.md (RF11, US15, RN11, UC05, RNF13)
--
-- Afere:
--   1. Existência da função, retorno integer, search_path restrito e privilégios mínimos;
--   2. Agendamento ativo no pg_cron a cada 5 minutos ('*/5 * * * *');
--   3. Comportamento antes do fim previsto (sem alertas antecipados);
--   4. Disparo inicial de alerta para ambos os lados (profissional e contratante);
--   5. Idempotência estrita sob múltiplas rodadas periódicas do cron (+5m, +10m, +15m) sem duplicação de notificações;
--   6. Cessação imediata de novos alertas após registro de check-out;
--   7. Descarte de turno fora da janela de 6 horas (fim_sem_checkout_janela);
--   8. Supressão de alertas para posições canceladas.

begin;

set local timezone = 'UTC';
set local frila.agendador_secret = 'segredo-de-teste-cron-700';

select plan(30);

-- ── 1. Helpers de Sessão e Autenticação ────────────────────────────────────────

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

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

create function pg_temp.avisos(p_conta uuid, p_turno uuid) returns int
language sql as $$
  select count(*)::int from public.notificacao n
   where n.tipo::text = 'fim_sem_checkout'
     and n.usuario_id = p_conta
     and n.referencia_id = p_turno;
$$;

-- ── 2. Asserções Estruturais e Privilégios ──────────────────────────────────────

select has_function(
  'privado',
  'alertar_fim_sem_checkout',
  array[]::text[],
  'privado.alertar_fim_sem_checkout() existe no schema privado'
);

select function_returns(
  'privado',
  'alertar_fim_sem_checkout',
  array[]::text[],
  'integer',
  'privado.alertar_fim_sem_checkout() retorna integer'
);

select ok(
  (select proconfig from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'alertar_fim_sem_checkout')
  @> array['search_path=""'],
  'privado.alertar_fim_sem_checkout() roda com search_path vazio'
);

select is(
  has_function_privilege('authenticated', 'privado.alertar_fim_sem_checkout()', 'execute'),
  false,
  'authenticated NÃO tem execute em privado.alertar_fim_sem_checkout()'
);

select is(
  has_function_privilege('anon', 'privado.alertar_fim_sem_checkout()', 'execute'),
  false,
  'anon NÃO tem execute em privado.alertar_fim_sem_checkout()'
);

select is(
  has_function_privilege('public', 'privado.alertar_fim_sem_checkout()', 'execute'),
  false,
  'public NÃO tem execute em privado.alertar_fim_sem_checkout()'
);

select is(
  has_function_privilege('service_role', 'privado.alertar_fim_sem_checkout()', 'execute'),
  true,
  'service_role pode executar privado.alertar_fim_sem_checkout()'
);

-- ── 3. Asserções de Agendamento no pg_cron ─────────────────────────────────────

select is(
  (select count(*)::int from cron.job where jobname = 'alertar_fim_sem_checkout'),
  1,
  'Job alertar_fim_sem_checkout existe agendado no pg_cron'
);

select is(
  (select schedule from cron.job where jobname = 'alertar_fim_sem_checkout'),
  '*/5 * * * *',
  'Job alertar_fim_sem_checkout está agendado a cada 5 minutos'
);

select is(
  (select command from cron.job where jobname = 'alertar_fim_sem_checkout'),
  'select privado.alertar_fim_sem_checkout()',
  'Job invoca exatamente select privado.alertar_fim_sem_checkout()'
);

select ok(
  (select active from cron.job where jobname = 'alertar_fim_sem_checkout'),
  'Job alertar_fim_sem_checkout está com active = true'
);

-- ── 4. Cenário de Teste de Efeito e Idempotência Periódica ──────────────────────

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- Fixa o relógio no setup antes de qualquer publicação ou candidatura
select set_config('frila.agora', '2026-10-15 20:00:00+00', true);

-- Isola o teste fechando temporariamente turnos pré-existentes de cenários de desenvolvimento
update public.turno set checkout_em = coalesce(checkin_em, now())
 where checkin_em is not null and checkout_em is null;

-- Criação de contas
select pg_temp.autenticar('70000000-0000-4000-8000-000000000001', 'contratante700@frila.test');
select pg_temp.autenticar('70000000-0000-4000-8000-000000000002', 'profissional700@frila.test');
select pg_temp.autenticar('70000000-0000-4000-8000-000000000003', 'antigo700@frila.test');
select pg_temp.autenticar('70000000-0000-4000-8000-000000000004', 'cancelado700@frila.test');

select pg_temp.como('70000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante','Restaurante Cron 700','+5561955570001','1982-05-10','2026-10-16') $$);
select pg_temp.como('70000000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('profissional','Garcom Cron 700','+5561955570002','1994-08-20','2026-10-16') $$);
select pg_temp.como('70000000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional','Garcom Antigo 700','+5561955570003','1993-03-15','2026-10-16') $$);
select pg_temp.como('70000000-0000-4000-8000-000000000004',
  $$ select public.criar_conta('profissional','Garcom Cancelado 700','+5561955570004','1995-11-25','2026-10-16') $$);

create temp table fn700 as select (select id from public.funcao where nome = 'garçom') as id;

create function pg_temp.perfil700(conta uuid) returns void language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
         '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select id from fn700)));
end $corpo$;

select pg_temp.perfil700('70000000-0000-4000-8000-000000000002');
select pg_temp.perfil700('70000000-0000-4000-8000-000000000003');
select pg_temp.perfil700('70000000-0000-4000-8000-000000000004');

create temp table estab700 as
  select (pg_temp.como('70000000-0000-4000-8000-000000000001',
    $$ select public.cadastrar_estabelecimento('Restaurante Cron 700','04252011000110','food_service',
         'SCLN 100','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create function pg_temp.publicar700(chave uuid, inicio_t timestamptz, fim_t timestamptz) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('70000000-0000-4000-8000-000000000001', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 100',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         20000, 1, true, true, false, 'Gerente 700', 'urgencia', %L) $sql$,
    (select id from estab700), (select id from fn700), inicio_t, fim_t, chave))->>'vaga_id')::uuid;
end $corpo$;

-- 3 Vagas: 
-- V1 (alvo principal do teste): inicio 12:00, fim 18:00
-- V2 (antigo, fora da janela de 6h): inicio 00:00, fim 06:00
-- V3 (cancelada): inicio 12:00, fim 18:00
create temp table vagas700 as
  select pg_temp.publicar700('70000000-0000-4000-8000-000000000011', '2026-10-16 12:00:00+00', '2026-10-16 18:00:00+00') as v_principal,
         pg_temp.publicar700('70000000-0000-4000-8000-000000000012', '2026-10-16 00:00:00+00', '2026-10-16 06:00:00+00') as v_antiga,
         pg_temp.publicar700('70000000-0000-4000-8000-000000000013', '2026-10-16 12:00:00+00', '2026-10-16 18:00:00+00') as v_cancelada;

-- Candidaturas
create temp table c700 as
  select pg_temp.como('70000000-0000-4000-8000-000000000002',
           format($$ select public.candidatar(%L) $$, (select v_principal from vagas700))) as c_principal,
         pg_temp.como('70000000-0000-4000-8000-000000000003',
           format($$ select public.candidatar(%L) $$, (select v_antiga from vagas700))) as c_antiga,
         pg_temp.como('70000000-0000-4000-8000-000000000004',
           format($$ select public.candidatar(%L) $$, (select v_cancelada from vagas700))) as c_cancelada;

create temp table turnos700 as
  select (c_principal->>'posicao_id')::uuid as pos_principal, (c_principal->>'turno_id')::uuid as turno_principal,
         (c_antiga->>'posicao_id')::uuid    as pos_antiga,    (c_antiga->>'turno_id')::uuid    as turno_antigo,
         (c_cancelada->>'posicao_id')::uuid as pos_cancelada, (c_cancelada->>'turno_id')::uuid as turno_cancelado
    from c700;

-- Registra check-in em cada turno no respectivo horário de início (janela válida)
select set_config('frila.agora', '2026-10-16 00:05:00+00', true);
select pg_temp.como('70000000-0000-4000-8000-000000000003',
  format($$ select public.fazer_checkin(%L, 30, '2026-10-16 00:05:00+00') $$, (select turno_antigo from turnos700)));

select set_config('frila.agora', '2026-10-16 12:05:00+00', true);
select pg_temp.como('70000000-0000-4000-8000-000000000002',
  format($$ select public.fazer_checkin(%L, 30, '2026-10-16 12:05:00+00') $$, (select turno_principal from turnos700)));
select pg_temp.como('70000000-0000-4000-8000-000000000004',
  format($$ select public.fazer_checkin(%L, 30, '2026-10-16 12:05:00+00') $$, (select turno_cancelado from turnos700)));

-- Cancela a 3ª posição
update public.posicao set estado = 'cancelada' where id = (select pos_cancelada from turnos700);

-- ── 5. Verificação Antes do Fim (17:59 UTC, fim - 1 min) ──────────────────────

select set_config('frila.agora', '2026-10-16 17:59:00+00', true);

select is(
  privado.alertar_fim_sem_checkout(),
  0,
  'Antes do horário de término previsto (17:59), alertar_fim_sem_checkout retorna 0'
);

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000002', (select turno_principal from turnos700)),
  0,
  'Profissional não recebe notificação antes do término'
);

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000001', (select turno_principal from turnos700)),
  0,
  'Contratante não recebe notificação antes do término'
);

-- ── 6. Disparo na 1ª Rodada do Cron Pós-Fim (18:01 UTC, fim + 1 min) ───────────

select set_config('frila.agora', '2026-10-16 18:01:00+00', true);

select is(
  privado.alertar_fim_sem_checkout(),
  1,
  '1ª rodada do cron (18:01): detecta e processa exatamente 1 turno em atraso de check-out'
);

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000002', (select turno_principal from turnos700)),
  1,
  'Profissional recebe 1 notificação fim_sem_checkout'
);

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000001', (select turno_principal from turnos700)),
  1,
  'Contratante também recebe 1 notificação fim_sem_checkout (RN11: ambos os lados)'
);

select is(
  (select payload from public.notificacao
    where usuario_id = '70000000-0000-4000-8000-000000000002'
      and tipo::text = 'fim_sem_checkout'
      and referencia_id = (select turno_principal from turnos700)),
  jsonb_build_object('tipo', 'fim_sem_checkout', 'turno_id', (select turno_principal from turnos700)),
  'Payload da notificação contém tipo e turno_id, sem campos de hora extra'
);

-- ── 7. Idempotência Periódica do Cron (Lacuna #6: 18:06, 18:11, 18:16) ──────────

-- Rodada 2 do cron (18:06 UTC, fim + 6 min):
select set_config('frila.agora', '2026-10-16 18:06:00+00', true);

select is(
  privado.alertar_fim_sem_checkout(),
  1,
  'Rodada 2 do cron (+5m): localiza o turno pendente'
);

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000002', (select turno_principal from turnos700)),
  1,
  'Idempotência na rodada 2: profissional continua com exatamente 1 aviso (sem duplicação)'
);

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000001', (select turno_principal from turnos700)),
  1,
  'Idempotência na rodada 2: contratante continua com exatamente 1 aviso'
);

-- Rodada 3 do cron (18:11 UTC, fim + 11 min):
select set_config('frila.agora', '2026-10-16 18:11:00+00', true);
select privado.alertar_fim_sem_checkout();

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000002', (select turno_principal from turnos700)),
  1,
  'Idempotência na rodada 3 (+10m): total de avisos ao profissional permanece 1'
);

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000001', (select turno_principal from turnos700)),
  1,
  'Idempotência na rodada 3 (+10m): total de avisos ao contratante permanece 1'
);

-- Rodada 4 do cron (18:16 UTC, fim + 16 min):
select set_config('frila.agora', '2026-10-16 18:16:00+00', true);
select privado.alertar_fim_sem_checkout();

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000002', (select turno_principal from turnos700)),
  1,
  'Idempotência na rodada 4 (+15m): total de avisos ao profissional permanece 1'
);

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000001', (select turno_principal from turnos700)),
  1,
  'Idempotência na rodada 4 (+15m): total de avisos ao contratante permanece 1'
);

-- ── 8. Cessação de Alertas Após Check-out Registrado ─────────────────────────────

-- Profissional registra check-out às 18:20 (com carimbo do término previsto 18:00)
select set_config('frila.agora', '2026-10-16 18:20:00+00', true);
select pg_temp.como('70000000-0000-4000-8000-000000000002',
  format($$ select public.fazer_checkout(%L, 30, '2026-10-16 18:00:00+00') $$, (select turno_principal from turnos700)));

select isnt(
  (select checkout_em from public.turno where id = (select turno_principal from turnos700)),
  null,
  'Check-out registrado com sucesso no turno'
);

-- Rodada 5 do cron (18:21 UTC, pós-checkout):
select set_config('frila.agora', '2026-10-16 18:21:00+00', true);

select is(
  privado.alertar_fim_sem_checkout(),
  0,
  'Pós-checkout: alertar_fim_sem_checkout retorna 0 (turno não é mais elegível)'
);

select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000002', (select turno_principal from turnos700)),
  1,
  'Total de avisos ao profissional não se altera após checkout'
);

-- ── 9. Turno Fora da Janela (Janela de 6 Horas) e Posição Cancelada ──────────

-- V2 terminou às 06:00; às 18:21 já se passaram 12h21m (> 6 horas da janela)
select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000003', (select turno_antigo from turnos700)),
  0,
  'Turno fora da janela de 6h não gera alerta de fim sem checkout'
);

-- V3 teve a posição cancelada
select is(
  pg_temp.avisos('70000000-0000-4000-8000-000000000004', (select turno_cancelado from turnos700)),
  0,
  'Posição cancelada com check-in não gera alerta de fim sem checkout'
);

select * from finish();
rollback;
