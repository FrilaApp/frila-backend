-- 440_equipe_de_confianca.sql
--
-- US09 (RF18, UC11, RN05, RN16, RN23, cartão jl6nbekI)
-- Equipe de confiança:
--   1. Permissões de chamada (apenas authenticated; public e anon sem execute).
--   2. Recusas: não autenticado (401), perfil não contratante ou não membro (403),
--      conta suspensa (403), profissional inexistente/anonimizado (404),
--      e sem turno verificado cumprido no estabelecimento (403 sem_turno_cumprido).
--   3. incluir_na_equipe: grava na equipe_confianca e é idempotente (200 MembroDaEquipe).
--   4. equipe_de_confianca: lista PerfilPublico[] dos membros da equipe (200).
--   5. Despacho/elegibilidade (RF18, RN05, UC02): profissional da equipe a 30 km é elegível;
--      profissional fora da equipe a 30 km não é elegível.
--   6. remover_da_equipe: remove da equipe, é idempotente, e corta a elegibilidade
--      além dos 15 km a partir da próxima vaga.

begin;
select plan(29);

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

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- ── 1. Estrutura e privilégios ──────────────────────────────────────────────────

select ok(has_function_privilege('authenticated', 'public.equipe_de_confianca(uuid)', 'execute'),
  'authenticated executa public.equipe_de_confianca');
select ok(not has_function_privilege('anon', 'public.equipe_de_confianca(uuid)', 'execute'),
  'anon não executa public.equipe_de_confianca');

select ok(has_function_privilege('authenticated', 'public.incluir_na_equipe(uuid, uuid)', 'execute'),
  'authenticated executa public.incluir_na_equipe');
select ok(not has_function_privilege('anon', 'public.incluir_na_equipe(uuid, uuid)', 'execute'),
  'anon não executa public.incluir_na_equipe');

select ok(has_function_privilege('authenticated', 'public.remover_da_equipe(uuid, uuid)', 'execute'),
  'authenticated executa public.remover_da_equipe');
select ok(not has_function_privilege('anon', 'public.remover_da_equipe(uuid, uuid)', 'execute'),
  'anon não executa public.remover_da_equipe');

-- ── O Cenário ───────────────────────────────────────────────────────────────────
--
-- Prefixo `e9`
-- Usuários:
--   e90001: Zé (contratante, admin do Bar do Zé e90010)
--   e90002: Rita (contratante, admin do Buffet da Rita e90020)
--   e90003: Hugo (contratante com conta suspensa)
--   e90004: Ana (profissional garçom, ponto base a ~30 km do Bar do Zé)
--   e90005: Beto (profissional garçom, ponto base a ~30 km do Bar do Zé, sem turno cumprido)
--   e90006: Caio (profissional anonimizado)

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado, anonimizado_em) values
  ('e9000000-0000-4000-8000-000000000001', 'contratante', 'Zé', '+5561999990001', 'ze@e9.test', '1980-01-01', '2026-09-22', now(), 'ativa', null),
  ('e9000000-0000-4000-8000-000000000002', 'contratante', 'Rita', '+5561999990002', 'rita@e9.test', '1982-01-01', '2026-09-22', now(), 'ativa', null),
  ('e9000000-0000-4000-8000-000000000003', 'contratante', 'Hugo', '+5561999990003', 'hugo@e9.test', '1985-01-01', '2026-09-22', now(), 'suspensa', null),
  ('e9000000-0000-4000-8000-000000000004', 'profissional', 'Ana', '+5561999990004', 'ana@e9.test', '1995-01-01', '2026-09-22', now(), 'ativa', null),
  ('e9000000-0000-4000-8000-000000000005', 'profissional', 'Beto', '+5561999990005', 'beto@e9.test', '1996-01-01', '2026-09-22', now(), 'ativa', null),
  ('e9000000-0000-4000-8000-000000000006', 'profissional', 'Conta encerrada', null, null, '1997-01-01', '2026-09-22', now(), 'anonimizada', now());

-- Bar do Zé: Plano Piloto (-47.8822, -15.7942)
-- Ponto a ~30 km: (-48.1500, -15.8500)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('e9000000-0000-4000-8000-000000000010', 'Bar do Zé', '43141444000180', 'food_service', 'CLN 201',
   'POINT(-47.8822 -15.7942)'::extensions.geography),
  ('e9000000-0000-4000-8000-000000000020', 'Buffet da Rita', '86422896000130', 'evento', 'SIA Trecho 2',
   'POINT(-47.9500 -15.8200)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('e9000000-0000-4000-8000-000000000001', 'e9000000-0000-4000-8000-000000000010', 'administrador'),
  ('e9000000-0000-4000-8000-000000000002', 'e9000000-0000-4000-8000-000000000020', 'administrador'),
  ('e9000000-0000-4000-8000-000000000003', 'e9000000-0000-4000-8000-000000000010', 'operador');

-- Profissionais: ponto base a 30 km
insert into public.profissional (id, usuario_id, ponto_base) values
  ('e9000000-0000-4000-8000-000000000014', 'e9000000-0000-4000-8000-000000000004', 'POINT(-48.1500 -15.8500)'::extensions.geography),
  ('e9000000-0000-4000-8000-000000000015', 'e9000000-0000-4000-8000-000000000005', 'POINT(-48.1500 -15.8500)'::extensions.geography),
  ('e9000000-0000-4000-8000-000000000016', 'e9000000-0000-4000-8000-000000000006', 'POINT(-48.1500 -15.8500)'::extensions.geography);

-- Função: garçom
insert into public.profissional_funcao (profissional_id, funcao_id)
select p.id, f.id
  from (values ('e9000000-0000-4000-8000-000000000014'::uuid),
               ('e9000000-0000-4000-8000-000000000015'::uuid)) as p(id)
  cross join (select id from public.funcao where nome = 'garçom') as f;

-- Disponibilidade ampla para ambos: dia_semana 1 a 6, o dia todo
insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select p.id, d, '00:00'::time, '23:59'::time
  from (values ('e9000000-0000-4000-8000-000000000014'::uuid),
               ('e9000000-0000-4000-8000-000000000015'::uuid)) as p(id)
  cross join generate_series(0, 6) as d;

-- Ana já cumpriu um turno com presença verificada no Bar do Zé:
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em,
                         publicado_por)
values ('e9000000-0000-4000-8000-000000000100', 'e9000000-0000-4000-8000-000000000010',
        (select id from public.funcao where nome = 'garçom'),
        '2026-10-01 18:00+00', '2026-10-01 23:00+00', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
        15000, 1, true, false, false, 'Zé', 'urgencia', gen_random_uuid(), '2026-09-30 12:00+00',
        'e9000000-0000-4000-8000-000000000001');

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em)
values ('e9000000-0000-4000-8000-000000000200', 'e9000000-0000-4000-8000-000000000100', 'confirmada',
        'e9000000-0000-4000-8000-000000000014', '2026-09-30 13:00+00', false, '2026-10-01 18:00+00', '2026-10-01 23:00+00');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('e9000000-0000-4000-8000-000000000300', 'e9000000-0000-4000-8000-000000000200',
        '2026-10-01 18:02+00', 'geolocalizado', 35, 'verificado', 15000);

select privado.recalcular_comparecimento('e9000000-0000-4000-8000-000000000014');

-- ── 2. Recusas (401, 403, 404) ──────────────────────────────────────────────────

-- Sem token: 401
select throws_ok(
  $$ select public.equipe_de_confianca('e9000000-0000-4000-8000-000000000010') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'equipe_de_confianca sem token é 401');

select throws_ok(
  $$ select public.incluir_na_equipe('e9000000-0000-4000-8000-000000000010', 'e9000000-0000-4000-8000-000000000014') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'incluir_na_equipe sem token é 401');

select throws_ok(
  $$ select public.remover_da_equipe('e9000000-0000-4000-8000-000000000010', 'e9000000-0000-4000-8000-000000000014') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'remover_da_equipe sem token é 401');

-- Não membro ou perfil errado: 403
select throws_ok(
  $$ select pg_temp.como('e9000000-0000-4000-8000-000000000002',
     'select public.equipe_de_confianca(''e9000000-0000-4000-8000-000000000010'')') $$,
  'PGRST', pg_temp.erro('sem_permissao'),
  'membro de outra casa não vê equipe do Bar do Zé (403)');

select throws_ok(
  $$ select pg_temp.como('e9000000-0000-4000-8000-000000000002',
     'select public.incluir_na_equipe(''e9000000-0000-4000-8000-000000000010'', ''e9000000-0000-4000-8000-000000000014'')') $$,
  'PGRST', pg_temp.erro('sem_permissao'),
  'membro de outra casa não altera equipe do Bar do Zé (403)');

-- Conta suspensa: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('e9000000-0000-4000-8000-000000000003',
     'select public.incluir_na_equipe(''e9000000-0000-4000-8000-000000000010'', ''e9000000-0000-4000-8000-000000000014'')') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'conta suspensa não inclui na equipe (403 conta_suspensa)');

-- Profissional inexistente ou anonimizado: 404
select throws_ok(
  $$ select pg_temp.como('e9000000-0000-4000-8000-000000000001',
     'select public.incluir_na_equipe(''e9000000-0000-4000-8000-000000000010'', gen_random_uuid())') $$,
  'PGRST', pg_temp.erro('nao_encontrado'),
  'profissional inexistente é 404');

select throws_ok(
  $$ select pg_temp.como('e9000000-0000-4000-8000-000000000001',
     'select public.incluir_na_equipe(''e9000000-0000-4000-8000-000000000010'', ''e9000000-0000-4000-8000-000000000016'')') $$,
  'PGRST', pg_temp.erro('nao_encontrado'),
  'profissional com conta encerrada/anonimizada é 404');

-- Só quem já cumpriu turno no estabelecimento: Beto nunca trabalhou no Bar do Zé -> 403 sem_turno_cumprido
select throws_ok(
  $$ select pg_temp.como('e9000000-0000-4000-8000-000000000001',
     'select public.incluir_na_equipe(''e9000000-0000-4000-8000-000000000010'', ''e9000000-0000-4000-8000-000000000015'')') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'sem_turno_cumprido'),
  'profissional sem turno cumprido na casa é recusado com 403 sem_turno_cumprido');

-- Ana cumpriu turno no Bar do Zé, mas NUNCA no Buffet da Rita -> Rita não pode incluir Ana
select throws_ok(
  $$ select pg_temp.como('e9000000-0000-4000-8000-000000000002',
     'select public.incluir_na_equipe(''e9000000-0000-4000-8000-000000000020'', ''e9000000-0000-4000-8000-000000000014'')') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'sem_turno_cumprido'),
  'turno cumprido em outro estabelecimento não autoriza inclusão');

-- ── 3. Caminho feliz de inclusão e idempotência ──────────────────────────────────

select is(
  pg_temp.como('e9000000-0000-4000-8000-000000000001',
    'select public.incluir_na_equipe(''e9000000-0000-4000-8000-000000000010'', ''e9000000-0000-4000-8000-000000000014'')'),
  jsonb_build_object(
    'estabelecimento_id', 'e9000000-0000-4000-8000-000000000010'::uuid,
    'profissional_id',    'e9000000-0000-4000-8000-000000000014'::uuid
  ),
  'incluir_na_equipe devolve MembroDaEquipe com sucesso');

-- Idempotência: incluir novamente devolve o mesmo resultado e não duplica registro
select is(
  pg_temp.como('e9000000-0000-4000-8000-000000000001',
    'select public.incluir_na_equipe(''e9000000-0000-4000-8000-000000000010'', ''e9000000-0000-4000-8000-000000000014'')'),
  jsonb_build_object(
    'estabelecimento_id', 'e9000000-0000-4000-8000-000000000010'::uuid,
    'profissional_id',    'e9000000-0000-4000-8000-000000000014'::uuid
  ),
  'incluir_na_equipe é idempotente');

select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id = 'e9000000-0000-4000-8000-000000000010'
      and profissional_id = 'e9000000-0000-4000-8000-000000000014'),
  1,
  'exatamente uma linha gravada em public.equipe_confianca');

-- ── 4. Listar equipe_de_confianca ───────────────────────────────────────────────

select is(
  (pg_temp.como('e9000000-0000-4000-8000-000000000001',
     'select public.equipe_de_confianca(''e9000000-0000-4000-8000-000000000010'')')->0->>'nome'),
  'Ana',
  'equipe_de_confianca lista o PerfilPublico da Ana');

select is(
  pg_temp.como('e9000000-0000-4000-8000-000000000002',
    'select public.equipe_de_confianca(''e9000000-0000-4000-8000-000000000020'')'),
  '[]'::jsonb,
  'casa sem equipe devolve array vazio');

-- ── 5. Despacho/elegibilidade: 30 km dentro da equipe vs fora da equipe ─────────
--
-- Nova vaga do Bar do Zé.
-- Ana e Beto estão ambos a ~30 km (> 15 km), ambos garçons, ambos disponíveis.
-- Ana está na equipe_confianca; Beto NÃO está.

insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em,
                         publicado_por, estado)
values ('e9000000-0000-4000-8000-000000000999', 'e9000000-0000-4000-8000-000000000010',
        (select id from public.funcao where nome = 'garçom'),
        '2026-10-05 18:00+00', '2026-10-05 23:00+00', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
        16000, 1, true, false, false, 'Zé', 'urgencia', gen_random_uuid(), '2026-10-05 10:00+00',
        'e9000000-0000-4000-8000-000000000001', 'publicada');

-- Distância real conferida: > 25 km
select ok(
  extensions.ST_Distance(
    'POINT(-47.8822 -15.7942)'::extensions.geography,
    'POINT(-48.1500 -15.8500)'::extensions.geography
  ) > 25000,
  'distância de teste é comprovadamente maior que 25 km (> 15 km da RN05)');

-- Elegíveis para a vaga:
select ok(
  exists (
    select 1 from privado.elegiveis('e9000000-0000-4000-8000-000000000999')
     where profissional_id = 'e9000000-0000-4000-8000-000000000014'
  ),
  'Ana (na equipe de confiança) é elegível mesmo a 30 km (RF18)');

select ok(
  not exists (
    select 1 from privado.elegiveis('e9000000-0000-4000-8000-000000000999')
     where profissional_id = 'e9000000-0000-4000-8000-000000000015'
  ),
  'Beto (fora da equipe) NÃO é elegível além de 15 km');

-- ── 6. remover_da_equipe e corte na próxima vaga ────────────────────────────────

select is(
  pg_temp.como('e9000000-0000-4000-8000-000000000001',
    'select public.remover_da_equipe(''e9000000-0000-4000-8000-000000000010'', ''e9000000-0000-4000-8000-000000000014'')'),
  jsonb_build_object(
    'estabelecimento_id', 'e9000000-0000-4000-8000-000000000010'::uuid,
    'profissional_id',    'e9000000-0000-4000-8000-000000000014'::uuid
  ),
  'remover_da_equipe devolve MembroDaEquipe com sucesso');

-- Idempotência da remoção
select is(
  pg_temp.como('e9000000-0000-4000-8000-000000000001',
    'select public.remover_da_equipe(''e9000000-0000-4000-8000-000000000010'', ''e9000000-0000-4000-8000-000000000014'')'),
  jsonb_build_object(
    'estabelecimento_id', 'e9000000-0000-4000-8000-000000000010'::uuid,
    'profissional_id',    'e9000000-0000-4000-8000-000000000014'::uuid
  ),
  'remover_da_equipe é idempotente');

select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id = 'e9000000-0000-4000-8000-000000000010'),
  0,
  'equipe do Bar do Zé ficou vazia');

-- Nova vaga publicada após a remoção:
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em,
                         publicado_por, estado)
values ('e9000000-0000-4000-8000-000000000888', 'e9000000-0000-4000-8000-000000000010',
        (select id from public.funcao where nome = 'garçom'),
        '2026-10-06 18:00+00', '2026-10-06 23:00+00', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
        16000, 1, true, false, false, 'Zé', 'urgencia', gen_random_uuid(), '2026-10-06 10:00+00',
        'e9000000-0000-4000-8000-000000000001', 'publicada');

select ok(
  not exists (
    select 1 from privado.elegiveis('e9000000-0000-4000-8000-000000000888')
     where profissional_id = 'e9000000-0000-4000-8000-000000000014'
  ),
  'remover da equipe corta a elegibilidade da Ana a 30 km para a próxima vaga');

select is(
  pg_temp.como('e9000000-0000-4000-8000-000000000001',
    'select public.equipe_de_confianca(''e9000000-0000-4000-8000-000000000010'')'),
  '[]'::jsonb,
  'equipe_de_confianca agora devolve lista vazia');

select * from finish();
rollback;
