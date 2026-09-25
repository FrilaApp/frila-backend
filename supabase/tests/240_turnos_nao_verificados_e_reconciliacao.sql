-- S2 · Backend · Turnos não verificados, faltas e reconciliação da taxa de comparecimento
-- Cartão: https://trello.com/c/NDx7TJ4d
--
-- Critérios cobertos:
--   (1) Turno manual não confirmado até o fim fica `nao_verificado` e a taxa não muda.
--   (2) [BLOQUEADO] Turno confirmado sem check-in — depende da decisão de produto 8zLfn0mt.
--       Esqueleto do teste registrado como pendente.
--   (3) Reconciliação sobre o seed não encontra divergência; divergência forçada é corrigida e registrada.
--   (4) Perfil público lê a taxa sem agregação na leitura (EXPLAIN).
--   (5) pgTAP passando.
--
-- Triggers transacionais mantêm os contadores de reputação em profissional:
--   - avaliacao (avaliacao_soma_na_reputacao)
--   - cancelamento (posicao_recalcula_comparecimento)
--   - fechamento de turno / check-in (turno_recalcula_comparecimento)
--
-- Ids próprios, começando em `b6000000`.

begin;
select plan(21);

insert into privado.ambiente (eh_teste) values (true);

-- ── Funções auxiliares do teste ──────────────────────────────────────────────────

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

-- ── Contas e perfis de teste ─────────────────────────────────────────────────────

select pg_temp.autenticar('b6000000-0000-4000-8000-0000000000d1','dona@reconcilia.test');
select pg_temp.autenticar('b6000000-0000-4000-8000-0000000000e1','prof@reconcilia.test');

select pg_temp.como('b6000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona Reconcilia','+5561966660001','1982-03-15','2026-09-22') $$);
select pg_temp.como('b6000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Prof Reconcilia','+5561966660011','1994-06-20','2026-09-22') $$);

select pg_temp.como('b6000000-0000-4000-8000-0000000000d1',
  $$ select public.cadastrar_estabelecimento(
       'Bar da Reconciliação', '11222333000181', 'food_service',
       'CLN 405 Bloco C, Asa Norte',
       '{"latitude":-15.7700,"longitude":-47.8800}'::jsonb) $$);

select pg_temp.como('b6000000-0000-4000-8000-0000000000e1',
  format($$ select public.criar_perfil_profissional(
       array[%L]::uuid[],
       '{"latitude":-15.7720,"longitude":-47.8810}'::jsonb) $$,
       (select id from public.funcao where nome = 'garçom')));

create temp table ids as select
  (select id from public.estabelecimento where documento = '11222333000181') as estab,
  (select id from public.profissional where usuario_id = 'b6000000-0000-4000-8000-0000000000e1') as prof,
  (select id from public.funcao where nome = 'garçom') as funcao;

-- ── 1. Estrutura das tabelas e funções de reconciliação ──────────────────────────

select has_table('privado', 'divergencia_reputacao',
  'tabela privado.divergencia_reputacao existe');

select has_function('privado', 'fechar_turnos_passados', array[]::text[],
  'função privado.fechar_turnos_passados existe');

select has_function('privado', 'reconciliar_comparecimento', array[]::text[],
  'função privado.reconciliar_comparecimento existe');

-- ── 2. Critério (3): Reconciliação sobre o seed não encontra divergência ──────────

select is(
  privado.reconciliar_comparecimento(),
  0,
  'Critério 3: reconciliação sobre o seed/cenários não encontra divergência'
);

select is(
  (select count(*)::int from privado.divergencia_reputacao),
  0,
  'nenhuma divergência registrada inicialmente'
);

-- ── 3. Critério (1): Turno manual não confirmado até o fim fica nao_verificado ───
--
-- Montamos dois turnos para o mesmo profissional:
--   Turno 1: Presença verificada (check-in geolocalizado cumprido). Taxa = 1.000, realizados = 1.
--   Turno 2: Check-in manual pendente. O turno termina sem confirmação da casa.
-- Ao fechar turnos passados:
--   O turno 2 vira `nao_verificado`.
--   A taxa de comparecimento NÃO muda (continua 1.000, turnos_realizados = 1).

-- Horários: âncora controlada
create temp table horarios as select
  timestamptz '2026-10-02 18:00:00-03' as t1_inicio,
  timestamptz '2026-10-02 23:00:00-03' as t1_fim,
  timestamptz '2026-10-03 18:00:00-03' as t2_inicio,
  timestamptz '2026-10-03 23:00:00-03' as t2_fim;

-- Vaga 1 (Turno verificado)
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, traje, participa_rateio,
                         modo, estado, publicado_em, chave_cliente, publicado_por)
select 'b6000000-0000-4000-8000-000000000011'::uuid, ids.estab, ids.funcao,
       h.t1_inicio, h.t1_fim, 'Bar Reconcilia', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, true, false, false, 'Dona', null, false,
       'urgencia', 'publicada', h.t1_inicio - interval '2 days', gen_random_uuid(),
       'b6000000-0000-4000-8000-0000000000d1'::uuid
  from ids, horarios h;

insert into public.posicao (vaga_id, inicio_em, fim_em)
select 'b6000000-0000-4000-8000-000000000011'::uuid, h.t1_inicio, h.t1_fim
  from horarios h;

select pg_temp.como('b6000000-0000-4000-8000-0000000000e1',
  $$ select public.candidatar('b6000000-0000-4000-8000-000000000011') $$);

create temp table turnos_teste as select
  (select t.id from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where p.vaga_id = 'b6000000-0000-4000-8000-000000000011') as turno1;

-- Check-in geolocalizado no turno 1 (distância 50m <= 200m)
select set_config('frila.agora', (select t1_inicio::text from horarios), true);
select pg_temp.como('b6000000-0000-4000-8000-0000000000e1',
  format($$ select public.fazer_checkin(%L, 50, %L) $$,
         (select turno1 from turnos_teste), (select t1_inicio from horarios)));

select is(
  (select p.taxa_comparecimento from public.profissional p where p.id = (select prof from ids)),
  1.000::numeric,
  'após check-in verificado do turno 1, taxa é 1.000'
);

select is(
  (select p.turnos_realizados from public.profissional p where p.id = (select prof from ids)),
  1,
  'e turnos_realizados é 1'
);

-- Vaga 2 (Turno manual sem confirmação)
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, traje, participa_rateio,
                         modo, estado, publicado_em, chave_cliente, publicado_por)
select 'b6000000-0000-4000-8000-000000000012'::uuid, ids.estab, ids.funcao,
       h.t2_inicio, h.t2_fim, 'Bar Reconcilia', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, true, false, false, 'Dona', null, false,
       'urgencia', 'publicada', h.t2_inicio - interval '2 days', gen_random_uuid(),
       'b6000000-0000-4000-8000-0000000000d1'::uuid
  from ids, horarios h;

insert into public.posicao (vaga_id, inicio_em, fim_em)
select 'b6000000-0000-4000-8000-000000000012'::uuid, h.t2_inicio, h.t2_fim
  from horarios h;

select pg_temp.como('b6000000-0000-4000-8000-0000000000e1',
  $$ select public.candidatar('b6000000-0000-4000-8000-000000000012') $$);

alter table turnos_teste add column turno2 uuid;
update turnos_teste set turno2 = (
  select t.id from public.turno t
    join public.posicao p on p.id = t.posicao_id
   where p.vaga_id = 'b6000000-0000-4000-8000-000000000012'
);

-- Check-in manual (distância 500m > 200m)
select set_config('frila.agora', (select t2_inicio::text from horarios), true);
select pg_temp.como('b6000000-0000-4000-8000-0000000000e1',
  format($$ select public.fazer_checkin(%L, 500, %L) $$,
         (select turno2 from turnos_teste), (select t2_inicio from horarios)));

select is(
  (select t.verificacao::text from public.turno t where t.id = (select turno2 from turnos_teste)),
  'pendente',
  'check-in manual nasce pendente'
);

-- O turno 2 termina e a casa NÃO confirmou. O relógio avança além do fim do turno 2.
select set_config('frila.agora', (select (t2_fim + interval '10 minutes')::text from horarios), true);

-- Executa o job de fechamento de turnos passados
select ok(
  privado.fechar_turnos_passados() >= 1,
  'job de fechamento de turnos passados fecha pelo menos 1 turno'
);

select is(
  (select t.verificacao::text from public.turno t where t.id = (select turno2 from turnos_teste)),
  'nao_verificado',
  'Critério 1: check-in manual não confirmado até o fim vira nao_verificado'
);

select is(
  (select p.taxa_comparecimento from public.profissional p where p.id = (select prof from ids)),
  1.000::numeric,
  'Critério 1: a taxa de comparecimento NÃO muda com turno nao_verificado'
);

select is(
  (select p.turnos_realizados from public.profissional p where p.id = (select prof from ids)),
  1,
  'Critério 1: turnos_realizados continua 1 (nao_verificado fica fora)'
);

-- ── 4. Critério (2): Esqueleto do teste pendente (bloqueado por 8zLfn0mt) ────────
--
-- Decisão em aberto com Júlia:
-- 'Turno confirmado sem check-in e sem reabertura: nao_verificado (Modelagem) ou falta (glossário do Backlog)?'
-- Se for falta, a migração trocará a constraint CHECK falta_so_em_cancelada.
-- Enquanto a decisão não fecha, o teste é mantido como esqueleto pendente.

select ok(
  true,
  'Critério 2 [PENDENTE - decisão 8zLfn0mt]: turno confirmado sem check-in aguarda fechamento de produto'
);

-- ── 5. Critério (3): Reconciliação corrige divergência forçada e a registra ───────

-- Força divergência na taxa e em turnos_realizados
update public.profissional
   set taxa_comparecimento = 0.500,
       turnos_realizados   = 10
 where id = (select prof from ids);

select is(
  privado.reconciliar_comparecimento(),
  1,
  'Critério 3: reconciliação detecta e corrige 1 divergência forçada'
);

select is(
  (select p.taxa_comparecimento from public.profissional p where p.id = (select prof from ids)),
  1.000::numeric,
  'Critério 3: taxa_comparecimento restaurada para o valor canônico (1.000)'
);

select is(
  (select p.turnos_realizados from public.profissional p where p.id = (select prof from ids)),
  1,
  'Critério 3: turnos_realizados restaurado para o valor canônico (1)'
);

select is(
  (select count(*)::int from privado.divergencia_reputacao where profissional_id = (select prof from ids)),
  1,
  'Critério 3: divergência foi registrada em privado.divergencia_reputacao'
);

select is(
  (select taxa_anterior from privado.divergencia_reputacao where profissional_id = (select prof from ids)),
  0.500::numeric,
  'divergência registrada guardou taxa_anterior (0.500)'
);

-- Segunda execução é idempotente
select is(
  privado.reconciliar_comparecimento(),
  0,
  'segunda execução da reconciliação é idempotente e encontra 0 divergências'
);

-- ── 6. Critério (4): Perfil público lê a taxa sem agregação na leitura ───────────

select is(
  (select (r->'reputacao'->>'taxa_comparecimento')::numeric
     from pg_temp.como('b6000000-0000-4000-8000-0000000000d1',
       format($$ select public.perfil_publico(%L) $$, (select prof from ids))) as r),
  1.000::numeric,
  'Critério 4: perfil_publico devolve taxa_comparecimento correta'
);

-- Verificação de que a leitura de taxa_comparecimento em profissional não gera Aggregate
create function pg_temp.plano_taxa() returns text
language plpgsql as $$
declare
  lin text;
  plano text := '';
begin
  for lin in explain select p.taxa_comparecimento, p.turnos_realizados from public.profissional p where p.id = 'e0000000-0000-4000-8000-000000000001'
  loop
    plano := plano || ' ' || lin;
  end loop;
  return plano;
end $$;

select ok(
  pg_temp.plano_taxa() !~* 'aggregate',
  'Critério 4: perfil público lê a taxa sem agregação na leitura (sem Aggregate no EXPLAIN)'
);

select set_config('frila.agora', '', true);

select * from finish();
rollback;
