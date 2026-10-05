-- 603_cancelamento_idempotente_reenvio.sql
--
-- Teste pgTAP do reenvio idempotente de cancelamento de posição e vaga (cartão pVvubZJy, contrato 0.2.35).
-- Decisão de produto de 05/10/2026: Opção A (Sucesso Idempotente).
--
-- Cobre:
--   1. Reenvio idempotente de `cancelar_posicao` pelo mesmo autor devolve 200 com o mesmo objeto cancelado.
--   2. Reenvio idempotente de `cancelar_vaga` pelo mesmo contratante autor devolve 200.
--   3. Efeitos colaterais NÃO duplicados (nenhuma notificação duplicada, nenhuma ocorrência duplicada,
--      nenhuma penalidade adicional de falta, nenhuma posição reaberta duplicada).
--   4. Cancelar o que foi cancelado pela outra parte ou outro autor continua respondendo 409.
--   5. Cancelar posição aberta sem confirmação continua 409.
--   6. Cancelar vaga por outro membro da casa continua 409 vaga_encerrada.
--   7. Cancelar o que não é seu continua 404 nao_encontrado.
--   8. Profissional chamando cancelar_vaga continua 422 perfil_incompativel.
--   9. Executado com data futura congelada via privado.agora() (+90 dias).

begin;
select plan(31);

set local frila.agendador_secret = 'segredo-de-teste';

-- Ativa ambiente de teste e fixa o relógio em data futura (+90 dias)
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2027-01-15 12:00:00-03', true);

-- Helper como(conta, sql)
create or replace function pg_temp.como(conta uuid, sql text) returns jsonb
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

-- Criação de contas auth.users para os testes
create or replace function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

select pg_temp.autenticar('b0000000-0000-4000-8000-0000000000d1', 'dona@reenvio.test');
select pg_temp.autenticar('b0000000-0000-4000-8000-0000000000d2', 'gerente@reenvio.test');
select pg_temp.autenticar('b0000000-0000-4000-8000-0000000000d9', 'outro_dono@reenvio.test');
select pg_temp.autenticar('b0000000-0000-4000-8000-0000000000e1', 'prof1@reenvio.test');
select pg_temp.autenticar('b0000000-0000-4000-8000-0000000000e2', 'prof2@reenvio.test');
select pg_temp.autenticar('b0000000-0000-4000-8000-0000000000e3', 'estranho@reenvio.test');

select pg_temp.como('b0000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona Reenvio','+5561944440001','1980-01-01','2026-09-22') $$);
select pg_temp.como('b0000000-0000-4000-8000-0000000000d2',
  $$ select public.criar_conta('contratante','Gerente Reenvio','+5561944440002','1985-01-01','2026-09-22') $$);
select pg_temp.como('b0000000-0000-4000-8000-0000000000d9',
  $$ select public.criar_conta('contratante','Outro Dono','+5561944440009','1982-01-01','2026-09-22') $$);
select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Profissional Um','+5561944440011','1995-01-01','2026-09-22') $$);
select pg_temp.como('b0000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Profissional Dois','+5561944440012','1996-01-01','2026-09-22') $$);
select pg_temp.como('b0000000-0000-4000-8000-0000000000e3',
  $$ select public.criar_conta('profissional','Estranho','+5561944440013','1997-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
  format($$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como('b0000000-0000-4000-8000-0000000000e2',
  format($$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como('b0000000-0000-4000-8000-0000000000e3',
  format($$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$, (select garcom from fn)));

create temp table casa as
  select (pg_temp.como('b0000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa do Reenvio','11222333000181','food_service',
         'CLN 102','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create temp table outra_casa as
  select (pg_temp.como('b0000000-0000-4000-8000-0000000000d9',
    $$ select public.cadastrar_estabelecimento('Outra Casa','45223011000179','food_service',
         'CLN 103','{"latitude":-15.7920,"longitude":-47.8870}') $$)->>'id')::uuid as id;

-- Inclui gerente na Casa do Reenvio
insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ((select id from casa), 'b0000000-0000-4000-8000-0000000000d2', 'administrador');

-- Função auxiliar para publicar vagas
create or replace function pg_temp.publicar(dono uuid, est uuid, chave uuid, dias interval, posicoes int default 1) returns uuid
language plpgsql as $$
begin
  return (pg_temp.como(dono, format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 102',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         20000, %s, true, true, false, 'Dona', 'urgencia', %L) $sql$,
    est, (select garcom from fn),
    privado.agora() + dias,
    privado.agora() + dias + interval '6 hours', posicoes, chave))->>'vaga_id')::uuid;
end $$;

-- Vaga 1: com 5 dias de antecedência (cancelamento sem falta)
create temp table v1 as
  select pg_temp.publicar('b0000000-0000-4000-8000-0000000000d1', (select id from casa),
                          'b1111111-0000-4000-8000-000000000001', interval '5 days', 1) as id;

-- Vaga 2: com 10 horas de antecedência (cancelamento com falta, menos de 24h)
create temp table v2 as
  select pg_temp.publicar('b0000000-0000-4000-8000-0000000000d1', (select id from casa),
                          'b2222222-0000-4000-8000-000000000002', interval '10 hours', 1) as id;

-- Vaga 3: 3 posições (1 confirmada para prof1, 2 abertas) para teste de cancelar_vaga
create temp table v3 as
  select pg_temp.publicar('b0000000-0000-4000-8000-0000000000d1', (select id from casa),
                          'b3333333-0000-4000-8000-000000000003', interval '7 days', 3) as id;

-- Candidaturas
create temp table p1 as
  select (pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
            format($$ select public.candidatar(%L) $$, (select id from v1)))->>'posicao_id')::uuid as id;

create temp table p2 as
  select (pg_temp.como('b0000000-0000-4000-8000-0000000000e2',
            format($$ select public.candidatar(%L) $$, (select id from v2)))->>'posicao_id')::uuid as id;

create temp table p3 as
  select (pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
            format($$ select public.candidatar(%L) $$, (select id from v3)))->>'posicao_id')::uuid as id;

-- ══════════════════════════════════════════════════════════════════════════════
-- 1. Testes de cancelar_posicao (>24h, sem falta)
-- ══════════════════════════════════════════════════════════════════════════════

-- Contagens antes de cancelar P1
create temp table cont_antes_p1 as
select
  (select count(*)::int from public.notificacao where tipo = 'cancelamento') as notifs,
  (select count(*)::int from public.ocorrencia where tipo = 'cancelamento') as ocorrs,
  (select count(*)::int from public.posicao where vaga_id = (select id from v1)) as posicoes;

-- 1ª chamada de cancelar_posicao por Profissional 1
create temp table res_p1_call1 as
select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
  format($$ select public.cancelar_posicao(%L, 'imprevisto de transporte') $$, (select id from p1))) as j;

select is((select (j->>'posicao_id')::uuid from res_p1_call1), (select id from p1),
  '1ª chamada cancelar_posicao: devolve posicao_id correta');
select is((select (j->>'falta')::boolean from res_p1_call1), false,
  '1ª chamada cancelar_posicao: falta = false (>24h)');
select is((select (j->>'reaberta')::boolean from res_p1_call1), true,
  '1ª chamada cancelar_posicao: reaberta = true');
select isnt((select (j->>'nova_posicao_id') from res_p1_call1), null,
  '1ª chamada cancelar_posicao: nova_posicao_id gerada');

-- 2ª chamada (REENVIO IDEMPOTENTE) pelo MESMO autor (Profissional 1)
create temp table res_p1_call2 as
select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
  format($$ select public.cancelar_posicao(%L, 'imprevisto de transporte') $$, (select id from p1))) as j;

select is((select (j->>'posicao_id')::uuid from res_p1_call2), (select id from p1),
  'reenvio cancelar_posicao (mesmo autor): devolve 200 com a mesma posicao_id');
select is((select (j->>'falta')::boolean from res_p1_call2), false,
  'reenvio cancelar_posicao (mesmo autor): devolve a mesma falta = false');
select is((select (j->>'reaberta')::boolean from res_p1_call2), true,
  'reenvio cancelar_posicao (mesmo autor): devolve a mesma reaberta = true');
select is((select (j->>'nova_posicao_id') from res_p1_call2), (select (j->>'nova_posicao_id') from res_p1_call1),
  'reenvio cancelar_posicao (mesmo autor): devolve o mesmo nova_posicao_id');

-- Verificação de efeitos colaterais NÃO duplicados para P1
select is(
  (select count(*)::int from public.notificacao where tipo = 'cancelamento') - (select notifs from cont_antes_p1),
  2,
  'reenvio cancelar_posicao não duplicou notificações (manteve as 2 enviadas aos membros na 1ª chamada)');

select is(
  (select count(*)::int from public.ocorrencia where tipo = 'cancelamento') - (select ocorrs from cont_antes_p1),
  1,
  'reenvio cancelar_posicao não duplicou ocorrências');

select is(
  (select count(*)::int from public.posicao where vaga_id = (select id from v1)) - (select posicoes from cont_antes_p1),
  1,
  'reenvio cancelar_posicao não criou uma segunda posição reaberta');

-- Tentativa de cancelar P1 pela contraparte (Dona da casa): continua 409 posicao_nao_cancelavel!
select throws_ok(
  format($$ select pg_temp.como('b0000000-0000-4000-8000-0000000000d1',
       $x$ select public.cancelar_posicao(%L, 'casa cancela') $x$) $$, (select id from p1)),
  'PGRST',
  '{"code" : "posicao_nao_cancelavel", "message" : "posicao_nao_cancelavel", "details" : null, "hint" : null}',
  'cancelar_posicao pela contraparte após cancelamento do profissional responde 409');

-- Tentativa de cancelar P1 por terceiro não membro e não profissional da vaga: responde 404!
select throws_ok(
  format($$ select pg_temp.como('b0000000-0000-4000-8000-0000000000e3',
       $x$ select public.cancelar_posicao(%L, 'terceiro cancela') $x$) $$, (select id from p1)),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'cancelar_posicao por quem não é parte responde 404');

-- Tentativa de cancelar posição aberta (a recém-reaberta da Vaga 1): responde 409!
select throws_ok(
  format($$ select pg_temp.como('b0000000-0000-4000-8000-0000000000d1',
       $x$ select public.cancelar_posicao(%L, 'tentando cancelar vaga aberta') $x$) $$,
       (select (j->>'nova_posicao_id')::uuid from res_p1_call1)),
  'PGRST',
  '{"code" : "posicao_nao_cancelavel", "message" : "posicao_nao_cancelavel", "details" : null, "hint" : null}',
  'cancelar_posicao em posição aberta (sem confirmação) responde 409');

-- ══════════════════════════════════════════════════════════════════════════════
-- 2. Testes de cancelar_posicao (<24h, com falta / penalidade na taxa)
-- ══════════════════════════════════════════════════════════════════════════════

-- 1ª chamada de cancelar_posicao por Profissional 2 (<24h)
create temp table res_p2_call1 as
select pg_temp.como('b0000000-0000-4000-8000-0000000000e2',
  format($$ select public.cancelar_posicao(%L, 'motivo em cima da hora') $$, (select id from p2))) as j;

select is((select (j->>'falta')::boolean from res_p2_call1), true,
  '1ª chamada cancelar_posicao (<24h): falta = true');

select is(
  (select taxa_comparecimento from public.profissional where usuario_id = 'b0000000-0000-4000-8000-0000000000e2'),
  0.000::numeric,
  'taxa de comparecimento do profissional 2 vira 0.000 (uma falta)');

create temp table cont_antes_p2_retry as
select
  (select count(*)::int from public.notificacao where tipo = 'cancelamento') as notifs,
  (select count(*)::int from public.ocorrencia where tipo = 'cancelamento') as ocorrs;

-- 2ª chamada (REENVIO IDEMPOTENTE) pelo MESMO Profissional 2
create temp table res_p2_call2 as
select pg_temp.como('b0000000-0000-4000-8000-0000000000e2',
  format($$ select public.cancelar_posicao(%L, 'motivo em cima da hora') $$, (select id from p2))) as j;

select is((select (j->>'falta')::boolean from res_p2_call2), true,
  'reenvio cancelar_posicao (<24h): devolve 200 com falta = true');

select is(
  (select taxa_comparecimento from public.profissional where usuario_id = 'b0000000-0000-4000-8000-0000000000e2'),
  0.000::numeric,
  'reenvio cancelar_posicao: penalidade não foi recalculada/duplicada na taxa');

select is(
  (select count(*)::int from public.notificacao where tipo = 'cancelamento'),
  (select notifs from cont_antes_p2_retry),
  'reenvio cancelar_posicao (<24h): notificações não duplicadas');

select is(
  (select count(*)::int from public.ocorrencia where tipo = 'cancelamento'),
  (select ocorrs from cont_antes_p2_retry),
  'reenvio cancelar_posicao (<24h): ocorrências não duplicadas');

-- ══════════════════════════════════════════════════════════════════════════════
-- 3. Testes de cancelar_vaga (contratante)
-- ══════════════════════════════════════════════════════════════════════════════

-- Contagens antes de cancelar V3
create temp table cont_antes_v3 as
select
  (select count(*)::int from public.notificacao where tipo = 'cancelamento') as notifs,
  (select count(*)::int from public.ocorrencia where tipo = 'cancelamento') as ocorrs;

-- 1ª chamada de cancelar_vaga pela Dona da casa
create temp table res_v3_call1 as
select pg_temp.como('b0000000-0000-4000-8000-0000000000d1',
  format($$ select public.cancelar_vaga(%L, 'evento suspenso por chuva') $$, (select id from v3))) as j;

select is((select (j->>'vaga_id')::uuid from res_v3_call1), (select id from v3),
  '1ª chamada cancelar_vaga: devolve vaga_id correta');
select is((select j->>'estado' from res_v3_call1), 'cancelada',
  '1ª chamada cancelar_vaga: estado = cancelada');
select is((select (j->>'posicoes_canceladas')::int from res_v3_call1), 3,
  '1ª chamada cancelar_vaga: posicoes_canceladas = 3');

-- 2ª chamada (REENVIO IDEMPOTENTE) pela MESMA Dona da casa
create temp table res_v3_call2 as
select pg_temp.como('b0000000-0000-4000-8000-0000000000d1',
  format($$ select public.cancelar_vaga(%L, 'evento suspenso por chuva') $$, (select id from v3))) as j;

select is((select (j->>'vaga_id')::uuid from res_v3_call2), (select id from v3),
  'reenvio cancelar_vaga (mesmo autor): devolve 200 com a mesma vaga_id');
select is((select j->>'estado' from res_v3_call2), 'cancelada',
  'reenvio cancelar_vaga (mesmo autor): devolve o mesmo estado = cancelada');
select is((select (j->>'posicoes_canceladas')::int from res_v3_call2), 3,
  'reenvio cancelar_vaga (mesmo autor): devolve as mesmas posicoes_canceladas = 3');

-- Verificação de efeitos colaterais NÃO duplicados para V3
select is(
  (select count(*)::int from public.notificacao where tipo = 'cancelamento') - (select notifs from cont_antes_v3),
  1,
  'reenvio cancelar_vaga não duplicou notificações para o profissional confirmado');

select is(
  (select count(*)::int from public.ocorrencia where tipo = 'cancelamento') - (select ocorrs from cont_antes_v3),
  1,
  'reenvio cancelar_vaga não duplicou ocorrências da posição confirmada');

-- ══════════════════════════════════════════════════════════════════════════════
-- 4. Casos que continuam recusando com 409 / 404 / 422 em cancelar_vaga
-- ══════════════════════════════════════════════════════════════════════════════

-- Tentativa de cancelar V3 por OUTRO membro da casa (Gerente d2): continua 409 vaga_encerrada!
select throws_ok(
  format($$ select pg_temp.como('b0000000-0000-4000-8000-0000000000d2',
       $x$ select public.cancelar_vaga(%L, 'cancelando novamente') $x$) $$, (select id from v3)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : null, "hint" : null}',
  'cancelar_vaga já cancelada chamada por outro membro da casa responde 409 vaga_encerrada');

-- Tentativa de cancelar V3 por contratante de OUTRA casa (d9): continua 404 nao_encontrado!
select throws_ok(
  format($$ select pg_temp.como('b0000000-0000-4000-8000-0000000000d9',
       $x$ select public.cancelar_vaga(%L, 'tentando cancelar casa alheia') $x$) $$, (select id from v3)),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'cancelar_vaga de outra casa responde 404 nao_encontrado');

-- Tentativa de profissional chamar cancelar_vaga: continua 422 perfil_incompativel!
select throws_ok(
  format($$ select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
       $x$ select public.cancelar_vaga(%L, 'profissional tentando') $x$) $$, (select id from v3)),
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'profissional chamando cancelar_vaga responde 422 perfil_incompativel');

rollback;
