-- 620_abrir_suporte.sql
--
-- Suporte por e-mail a partir do turno (v1.1, RF23, UC14, D1=C, D7, D10, D12 a D16, contrato 0.2.40).
-- Critérios de aceite 5 a 14 e Seção 6 de requisitos/ingestao-email-suporte-v1.1.md.
--
-- Ids próprios começando em `c6200000`.

begin;
select plan(26);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- Relógio congelado logo no início (imune a bomba-relógio)
select set_config('frila.agora', '2026-10-15 14:00:00-03', true);

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

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- Ids do cenário isolado
create temp table ids as select
  'c6200000-0000-4000-8000-000000000001'::uuid as prof_user,
  'c6200000-0000-4000-8000-000000000002'::uuid as dono_user,
  'c6200000-0000-4000-8000-000000000003'::uuid as terceiro_user,
  'c6200000-0000-4000-8000-000000000004'::uuid as suspenso_user,
  'c6200000-0000-4000-8000-000000000005'::uuid as anonimizado_user,
  'c6200000-0000-4000-8000-000000000010'::uuid as estab_id,
  'c6200000-0000-4000-8000-000000000020'::uuid as prof_id,
  'c6200000-0000-4000-8000-000000000030'::uuid as vaga_id,
  'c6200000-0000-4000-8000-000000000040'::uuid as posicao_id,
  'c6200000-0000-4000-8000-000000000050'::uuid as turno_id;

-- Autentica contas em auth.users
select pg_temp.autenticar(prof_user, 'prof620@test.local') from ids;
select pg_temp.autenticar(dono_user, 'dono620@test.local') from ids;
select pg_temp.autenticar(terceiro_user, 'terceiro620@test.local') from ids;
select pg_temp.autenticar(suspenso_user, 'suspenso620@test.local') from ids;
select pg_temp.autenticar(anonimizado_user, 'anonimizado620@test.local') from ids;

-- Cria contas em public.usuario
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado, anonimizado_em)
values
  ((select prof_user from ids), 'profissional', 'Profissional 620', '+5561911116201', 'prof620@test.local', '1995-01-01', '1.0', now(), 'ativa', null),
  ((select dono_user from ids), 'contratante', 'Dono 620', '+5561911116202', 'dono620@test.local', '1985-01-01', '1.0', now(), 'ativa', null),
  ((select terceiro_user from ids), 'profissional', 'Terceiro 620', '+5561911116203', 'terceiro620@test.local', '1992-01-01', '1.0', now(), 'ativa', null),
  ((select suspenso_user from ids), 'profissional', 'Suspenso 620', '+5561911116204', 'suspenso620@test.local', '1990-01-01', '1.0', now(), 'suspensa', null),
  ((select anonimizado_user from ids), 'profissional', 'Anonimizado 620', '+5561911116205', 'anonimizado620@test.local', '1990-01-01', '1.0', now(), 'anonimizada', now());

-- Cria perfil profissional
insert into public.profissional (id, usuario_id, ponto_base)
values ((select prof_id from ids), (select prof_user from ids), 'POINT(-47.8850 -15.7900)'::geography);

-- Cria estabelecimento e membro
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ((select estab_id from ids), 'Bar 620', '39979036000140', 'food_service', 'CLN 108', 'POINT(-47.8855 -15.7905)'::geography);

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ((select estab_id from ids), (select dono_user from ids), 'administrador');

-- Cria vaga, posicao e turno
create temp table f as select id from public.funcao where nome = 'garçom';

insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_por)
values ((select vaga_id from ids), (select estab_id from ids), (select id from f), '2026-10-18 18:00:00-03', '2026-10-18 23:00:00-03', 'CLN 108', 'POINT(-47.8855 -15.7905)'::geography, 15000, 1, false, false, false, 'Gerente 620', 'urgencia', gen_random_uuid(), (select dono_user from ids));

insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, inicio_em, fim_em)
values ((select posicao_id from ids), (select vaga_id from ids), (select prof_id from ids), 'confirmada', now(), '2026-10-18 18:00:00-03', '2026-10-18 23:00:00-03');

insert into public.turno (id, posicao_id, valor_acordado_centavos)
values ((select turno_id from ids), (select posicao_id from ids), 15000);

-- ── 1. Permissões de Execução (P1/P2) ──────────────────────────────────────────
select has_function('public', 'abrir_suporte', array['uuid', 'text', 'uuid'],
  'public.abrir_suporte(uuid, text, uuid) existe');

select ok(
  has_function_privilege('authenticated', 'public.abrir_suporte(uuid, text, uuid)', 'execute')
  and not has_function_privilege('anon', 'public.abrir_suporte(uuid, text, uuid)', 'execute')
  and not has_function_privilege('public', 'public.abrir_suporte(uuid, text, uuid)', 'execute'),
  'authenticated pode executar abrir_suporte; anon e public não podem');

-- ── 2. Ordem das Conferências ──────────────────────────────────────────────────

-- Conferência 1: Sem sessão (401 nao_autenticado)
select throws_ok(
  $$ select public.abrir_suporte('c6200000-0000-4000-8000-000000000050'::uuid, 'endereco', gen_random_uuid()) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '1. abrir_suporte sem sessão recusa 401 nao_autenticado'
);

-- Conferência 2a: Conta anonimizada (401 nao_autenticado via exigir_conta_ativa)
select throws_ok(
  pg_temp.por((select anonimizado_user from ids),
    format($$ select public.abrir_suporte(%L::uuid, 'endereco', gen_random_uuid()) $$, (select turno_id from ids))),
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '2a. abrir_suporte com conta anonimizada recusa 401 nao_autenticado'
);

-- Conferência 2b: Conta suspensa (403 sem_permissao com details: conta_suspensa)
select throws_ok(
  pg_temp.por((select suspenso_user from ids),
    format($$ select public.abrir_suporte(%L::uuid, 'endereco', gen_random_uuid()) $$, (select turno_id from ids))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '2b. abrir_suporte com conta suspensa recusa 403 sem_permissao (conta_suspensa)'
);

-- Conferência 3: Chave de idempotência nula (422 campo_obrigatorio, details: chave)
select throws_ok(
  pg_temp.por((select prof_user from ids),
    format($$ select public.abrir_suporte(%L::uuid, 'endereco', null::uuid) $$, (select turno_id from ids))),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'chave'),
  '3. abrir_suporte com chave nula recusa 422 campo_obrigatorio (chave)'
);

-- Conferência 5a: turno_id nulo (422 campo_obrigatorio, details: turno_id)
select throws_ok(
  pg_temp.por((select prof_user from ids),
    $$ select public.abrir_suporte(null::uuid, 'endereco', gen_random_uuid()) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'turno_id'),
  '5a. abrir_suporte com turno_id nulo recusa 422 campo_obrigatorio (turno_id)'
);

-- Conferência 5b: categoria nula ou vazia (422 campo_obrigatorio, details: categoria)
select throws_ok(
  pg_temp.por((select prof_user from ids),
    format($$ select public.abrir_suporte(%L::uuid, null::text, gen_random_uuid()) $$, (select turno_id from ids))),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'categoria'),
  '5b. abrir_suporte com categoria nula recusa 422 campo_obrigatorio (categoria)'
);

select throws_ok(
  pg_temp.por((select prof_user from ids),
    format($$ select public.abrir_suporte(%L::uuid, '   '::text, gen_random_uuid()) $$, (select turno_id from ids))),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'categoria'),
  '5c. abrir_suporte com categoria em branco recusa 422 campo_obrigatorio (categoria)'
);

-- Conferência 6: categoria fora do enum (422 campo_invalido, details: categoria)
select throws_ok(
  pg_temp.por((select prof_user from ids),
    format($$ select public.abrir_suporte(%L::uuid, 'categoria_inexistente', gen_random_uuid()) $$, (select turno_id from ids))),
  'PGRST',
  pg_temp.erro('campo_invalido', 'categoria'),
  '6. abrir_suporte com categoria fora do enum recusa 422 campo_invalido (categoria)'
);

-- Conferência 7a: Turno inexistente (404 nao_encontrado)
select throws_ok(
  pg_temp.por((select prof_user from ids),
    $$ select public.abrir_suporte('c6200000-0000-4000-8000-000000000099'::uuid, 'endereco', gen_random_uuid()) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '7a. abrir_suporte com turno inexistente recusa 404 nao_encontrado'
);

-- Conferência 7b: Turno de outra pessoa / alheio (404 nao_encontrado idêntico)
select throws_ok(
  pg_temp.por((select terceiro_user from ids),
    format($$ select public.abrir_suporte(%L::uuid, 'endereco', gen_random_uuid()) $$, (select turno_id from ids))),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '7b. abrir_suporte por terceiro alheio recusa 404 nao_encontrado identico ao inexistente'
);

-- ── 3. Caminho Feliz e Critérios 5, 6 e 12 ─────────────────────────────────────

-- Critério 5: Profissional do turno abre chamado -> 200 OK
create temp table c_prof as
select pg_temp.como((select prof_user from ids), format(
  $$ select public.abrir_suporte(%L::uuid, 'endereco', 'c6200000-0000-4000-8000-000000000101'::uuid) $$,
  (select turno_id from ids))) as resp;

select is(
  (select resp->>'tipo' from c_prof),
  'suporte',
  '5. profissional do turno recebe 200 com Protocolo.tipo = suporte'
);

select is(
  (select resp->>'prazo_resposta_ate' from c_prof),
  privado.prazo_de_resposta('2026-10-15 14:00:00-03'::timestamptz)::text,
  '5b. prazo_resposta_ate casa com privado.prazo_de_resposta(criada_em)'
);

-- Critério 12: Ocorrência gravada com tipo suporte, origem app, relato null, motivo categoria
select is(
  (select o.origem from public.ocorrencia o where o.id = ((select resp->>'ocorrencia_id' from c_prof))::uuid),
  'app',
  '12a. ocorrencia gravada com origem = app'
);

select is(
  (select o.relato from public.ocorrencia o where o.id = ((select resp->>'ocorrencia_id' from c_prof))::uuid),
  null,
  '12b. ocorrencia gravada com relato NULL'
);

select is(
  (select o.motivo from public.ocorrencia o where o.id = ((select resp->>'ocorrencia_id' from c_prof))::uuid),
  'endereco',
  '12c. ocorrencia gravada com motivo = categoria'
);

-- Critério 12d: Nenhuma mensagem enfileirada na fila email
select is(
  (select count(*)::int from pgmq.q_email),
  0,
  '12d. nenhuma mensagem enfileirada na fila email'
);

-- Critério 4 / Conferência 4: Reenvio idempotente com mesma chave devolve o mesmo Protocolo
create temp table c_reenvio as
select pg_temp.como((select prof_user from ids), format(
  $$ select public.abrir_suporte(%L::uuid, 'endereco', 'c6200000-0000-4000-8000-000000000101'::uuid) $$,
  (select turno_id from ids))) as resp;

select is(
  (select resp->>'ocorrencia_id' from c_reenvio),
  (select resp->>'ocorrencia_id' from c_prof),
  '4. reenvio com a mesma chave devolve exatamente a mesma ocorrencia_id'
);

-- Critério 6: Membro do estabelecimento da vaga também pode abrir chamado
create temp table c_dono as
select pg_temp.como((select dono_user from ids), format(
  $$ select public.abrir_suporte(%L::uuid, 'conduta', 'c6200000-0000-4000-8000-000000000102'::uuid) $$,
  (select turno_id from ids))) as resp;

select is(
  (select resp->>'tipo' from c_dono),
  'suporte',
  '6. membro do estabelecimento abre chamado com sucesso (200 OK)'
);

-- ── 4. Teto Diário (5/dia) e Virada do Dia (Critérios 10 e 11) ─────────────────

-- O prof_user já consumiu 1 chamado ('c6200000-...-0101'). Vamos abrir mais 4 chamados novos (total 5).
select pg_temp.como((select prof_user from ids), format(
  $$ select public.abrir_suporte(%L::uuid, 'atraso', 'c6200000-0000-4000-8000-000000000103'::uuid) $$,
  (select turno_id from ids)));

select pg_temp.como((select prof_user from ids), format(
  $$ select public.abrir_suporte(%L::uuid, 'seguranca', 'c6200000-0000-4000-8000-000000000104'::uuid) $$,
  (select turno_id from ids)));

select pg_temp.como((select prof_user from ids), format(
  $$ select public.abrir_suporte(%L::uuid, 'outro', 'c6200000-0000-4000-8000-000000000105'::uuid) $$,
  (select turno_id from ids)));

select pg_temp.como((select prof_user from ids), format(
  $$ select public.abrir_suporte(%L::uuid, 'conduta', 'c6200000-0000-4000-8000-000000000106'::uuid) $$,
  (select turno_id from ids)));

-- Agora prof_user tem exatamente 5 chamados abertos hoje.
-- 6º chamado novo no mesmo dia deve falhar com 429 limite_excedido (Critério 10)
select throws_ok(
  pg_temp.por((select prof_user from ids), format(
    $$ select public.abrir_suporte(%L::uuid, 'endereco', 'c6200000-0000-4000-8000-000000000107'::uuid) $$,
    (select turno_id from ids))),
  'PGRST',
  pg_temp.erro('limite_excedido'),
  '10a. 6º chamado novo no mesmo dia recusa 429 limite_excedido'
);

-- Mas o reenvio de um chamado já existente (ex: o 5º, chave ...0106) NÃO é barrado pelo teto (Critério 10)
select lives_ok(
  pg_temp.por((select prof_user from ids), format(
    $$ select public.abrir_suporte(%L::uuid, 'conduta', 'c6200000-0000-4000-8000-000000000106'::uuid) $$,
    (select turno_id from ids))),
  '10b. reenvio com mesma chave passa mesmo após atingir o limite diário'
);

-- Virada do dia no fuso de Brasília (Critério 11):
-- Avançamos frila.agora para o dia seguinte 00:01 no fuso de Brasília. O teto zera!
select set_config('frila.agora', '2026-10-16 00:01:00-03', true);

select lives_ok(
  pg_temp.por((select prof_user from ids), format(
    $$ select public.abrir_suporte(%L::uuid, 'endereco', 'c6200000-0000-4000-8000-000000000108'::uuid) $$,
    (select turno_id from ids))),
  '11. virada do dia em Brasília zera o teto de chamados'
);

-- ── 5. Imutabilidade e restrições da coluna origem ──────────────────────────
-- Linhas criadas têm origem = 'app'. O trigger ocorrencia_imutavel impede update na origem.
select throws_ok(
  $$ update public.ocorrencia set origem = 'operacao' where tipo = 'suporte' $$,
  '23001',
  null,
  '5a. update de origem em ocorrencia é bloqueado por ocorrencia_imutavel'
);

-- O check constraint origem in ('app', 'operacao') rejeita outros valores na inserção
select throws_ok(
  format($$ insert into public.ocorrencia (tipo, origem, turno_id, autor_id, motivo, criada_em)
             values ('suporte', 'invalida', %L::uuid, %L::uuid, 'endereco', now()) $$,
         (select turno_id from ids), (select prof_user from ids)),
  '23514',
  null,
  '5b. inserção de origem fora do check (app, operacao) viola restrição check 23514'
);

-- ── 6. Comportamento com UUID malformado (Análise técnica) ─────────────────────
-- A assinatura é abrir_suporte(turno_id uuid, categoria text, chave uuid).
-- Quando chamada via SQL com texto inválido para uuid, o parser do Postgres levanta erro 22P02.
-- Quando chamada via PostgREST por HTTP, o PostgREST valida a sintaxe do tipo uuid antes
-- da execução da função e devolve HTTP 400 Bad Request com erro 22P02 (invalid input syntax for type uuid),
-- idêntico ao que acontece com denunciar(alvo_id, chave).
select throws_ok(
  pg_temp.por((select prof_user from ids), format(
    $$ select public.abrir_suporte('nao-e-um-uuid'::uuid, 'endereco', gen_random_uuid()) $$,
    (select turno_id from ids))),
  '22P02',
  null,
  'UUID malformado em turno_id levanta 22P02 (HTTP 400 no PostgREST, identico a denunciar)'
);

select * from finish();
rollback;
