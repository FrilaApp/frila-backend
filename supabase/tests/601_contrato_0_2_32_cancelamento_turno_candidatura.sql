-- 601_contrato_0_2_32_cancelamento_turno_candidatura.sql
--
-- Contrato 0.2.32 (frila-docs #68, cartão Uc69VI57):
-- 1. Turno.cancelamento (CancelamentoDoTurno ou null) em meus_turnos e MeusDados.turnos:
--    causa, falta, cancelada_em. SEM motivo (nem para profissional nem para contratante).
-- 2. Candidatura.turno_id (Uuid ou null) em minhas_candidaturas e retirar_candidatura:
--    preenchido estritamente no estado 'aceita'.
-- 3. Todas as causas de cancelamento medidas e confirmadas.
-- 4. 422 campo_obrigatorio em retirar_candidatura e candidatos_da_vaga.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(43);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

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

-- ── Contas e perfis ───────────────────────────────────────────────────────────
select pg_temp.autenticar('c3200000-0000-4000-8000-0000000000d1', 'dona32@teste.test');
select pg_temp.autenticar('c3200000-0000-4000-8000-000000000011', 'p1@teste.test');
select pg_temp.autenticar('c3200000-0000-4000-8000-000000000012', 'p2@teste.test');
select pg_temp.autenticar('c3200000-0000-4000-8000-000000000013', 'p3@teste.test');
select pg_temp.autenticar('c3200000-0000-4000-8000-000000000014', 'p4@teste.test');
select pg_temp.autenticar('c3200000-0000-4000-8000-000000000015', 'p5@teste.test');
select pg_temp.autenticar('c3200000-0000-4000-8000-000000000016', 'p6@teste.test');
select pg_temp.autenticar('c3200000-0000-4000-8000-000000000017', 'p7@teste.test');
select pg_temp.autenticar('c3200000-0000-4000-8000-000000000018', 'p8@teste.test');

select pg_temp.como('c3200000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona 32','+5561932320001','1980-01-01','2026-09-22') $$);
select pg_temp.como('c3200000-0000-4000-8000-000000000011',
  $$ select public.criar_conta('profissional','Prof Um','+5561932320011','1995-01-01','2026-09-22') $$);
select pg_temp.como('c3200000-0000-4000-8000-000000000012',
  $$ select public.criar_conta('profissional','Prof Dois','+5561932320012','1995-01-01','2026-09-22') $$);
select pg_temp.como('c3200000-0000-4000-8000-000000000013',
  $$ select public.criar_conta('profissional','Prof Tres','+5561932320013','1995-01-01','2026-09-22') $$);
select pg_temp.como('c3200000-0000-4000-8000-000000000014',
  $$ select public.criar_conta('profissional','Prof Quatro','+5561932320014','1995-01-01','2026-09-22') $$);
select pg_temp.como('c3200000-0000-4000-8000-000000000015',
  $$ select public.criar_conta('profissional','Prof Cinco','+5561932320015','1995-01-01','2026-09-22') $$);
select pg_temp.como('c3200000-0000-4000-8000-000000000016',
  $$ select public.criar_conta('profissional','Prof Seis','+5561932320016','1995-01-01','2026-09-22') $$);
select pg_temp.como('c3200000-0000-4000-8000-000000000017',
  $$ select public.criar_conta('profissional','Prof Sete','+5561932320017','1995-01-01','2026-09-22') $$);
select pg_temp.como('c3200000-0000-4000-8000-000000000018',
  $$ select public.criar_conta('profissional','Prof Oito','+5561932320018','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));
end $corpo$;

select pg_temp.perfil('c3200000-0000-4000-8000-000000000011');
select pg_temp.perfil('c3200000-0000-4000-8000-000000000012');
select pg_temp.perfil('c3200000-0000-4000-8000-000000000013');
select pg_temp.perfil('c3200000-0000-4000-8000-000000000014');
select pg_temp.perfil('c3200000-0000-4000-8000-000000000015');
select pg_temp.perfil('c3200000-0000-4000-8000-000000000016');
select pg_temp.perfil('c3200000-0000-4000-8000-000000000017');
select pg_temp.perfil('c3200000-0000-4000-8000-000000000018');

create temp table casa as
  select (pg_temp.como('c3200000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Restaurante 32','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create function pg_temp.pub(dias int, modo text default 'urgencia', posicoes int default 1) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('c3200000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, %s, true, true, false, 'Dona 32', %L, gen_random_uuid()) $sql$,
    (select id from casa), (select garcom from fn),
    privado.agora() + (dias || ' days')::interval,
    privado.agora() + (dias || ' days 6 hours')::interval,
    posicoes, modo))->>'vaga_id')::uuid;
end $corpo$;

-- ── 1. 422 campo_obrigatorio em retirar_candidatura e candidatos_da_vaga ─────
select throws_ok(
  $$ select pg_temp.como('c3200000-0000-4000-8000-000000000011',
       $x$ select public.retirar_candidatura(null::uuid) $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "candidatura_id", "hint" : null}',
  'retirar_candidatura(null) é 422 campo_obrigatorio com details candidatura_id');

select throws_ok(
  $$ select pg_temp.como('c3200000-0000-4000-8000-0000000000d1',
       $x$ select public.candidatos_da_vaga(null::uuid) $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "vaga_id", "hint" : null}',
  'candidatos_da_vaga(null) é 422 campo_obrigatorio com details vaga_id');

-- ── 2. Candidatura.turno_id em modo urgência e modo seleção ──────────────────
create temp table vaga_urg as select pg_temp.pub(3, 'urgencia') as id;
create temp table cand_urg as
  select pg_temp.como('c3200000-0000-4000-8000-000000000011',
    format($$ select public.candidatar(%L) $$, (select id from vaga_urg))) as r;

select isnt((select r->>'turno_id' from cand_urg), null,
  'candidatar urgência devolve turno_id');

select is(
  (select c->>'turno_id' from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000011', $$ select public.minhas_candidaturas() $$)) c
    where c->>'id' = (select r->>'candidatura_id' from cand_urg)),
  (select r->>'turno_id' from cand_urg),
  'minhas_candidaturas traz turno_id na candidatura aceita do modo urgência');

-- Modo seleção com 2 posições: p2 e p3 se candidatam
create temp table vaga_sel as select pg_temp.pub(4, 'selecao', 2) as id;
create temp table cand_sel_p2 as
  select pg_temp.como('c3200000-0000-4000-8000-000000000012',
    format($$ select public.candidatar(%L) $$, (select id from vaga_sel))) as r;
create temp table cand_sel_p3 as
  select pg_temp.como('c3200000-0000-4000-8000-000000000013',
    format($$ select public.candidatar(%L) $$, (select id from vaga_sel))) as r;

-- Candidatura pendente traz turno_id: null
select is(
  (select c->>'turno_id' from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000012', $$ select public.minhas_candidaturas() $$)) c
    where c->>'id' = (select r->>'candidatura_id' from cand_sel_p2)),
  null,
  'candidatura pendente traz turno_id nulo');

-- Escolhe p2
create temp table esc_p2 as
  select pg_temp.como('c3200000-0000-4000-8000-0000000000d1',
    format($$ select public.escolher_candidato(%L) $$, (select r->>'candidatura_id' from cand_sel_p2))) as r;

select is(
  (select c->>'turno_id' from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000012', $$ select public.minhas_candidaturas() $$)) c
    where c->>'id' = (select r->>'candidatura_id' from cand_sel_p2)),
  (select r->>'turno_id' from esc_p2),
  'minhas_candidaturas traz turno_id retornado por escolher_candidato na candidatura aceita');

-- p3 continua pendente e continua com turno_id: null (mesmo com vaga de 2 posições tendo 1 confirmada)
select is(
  (select c->>'turno_id' from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000013', $$ select public.minhas_candidaturas() $$)) c
    where c->>'id' = (select r->>'candidatura_id' from cand_sel_p3)),
  null,
  'candidatura de p3 continua pendente com turno_id nulo mesmo após p2 ser confirmado na mesma vaga');

-- p3 retira candidatura: retirar_candidatura e minhas_candidaturas trazem turno_id: null
create temp table ret_p3 as
  select pg_temp.como('c3200000-0000-4000-8000-000000000013',
    format($$ select public.retirar_candidatura(%L) $$, (select r->>'candidatura_id' from cand_sel_p3))) as r;

select is((select r->>'turno_id' from ret_p3), null,
  'retirar_candidatura devolve turno_id nulo');

select is(
  (select c->>'turno_id' from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000013', $$ select public.minhas_candidaturas() $$)) c
    where c->>'id' = (select r->>'candidatura_id' from cand_sel_p3)),
  null,
  'minhas_candidaturas traz turno_id nulo na candidatura retirada');

-- ── 3. Turno cancelado continua com candidatura aceita e com o mesmo turno_id ──
create temp table vaga_canc as select pg_temp.pub(5, 'urgencia') as id;
create temp table cand_canc as
  select pg_temp.como('c3200000-0000-4000-8000-000000000014',
    format($$ select public.candidatar(%L) $$, (select id from vaga_canc))) as r;

-- Cancela o turno (desistência com mais de 24h)
select pg_temp.como('c3200000-0000-4000-8000-000000000014',
  format($$ select public.cancelar_posicao(%L, 'imprevisto familiar') $$, (select r->>'posicao_id' from cand_canc)));

select is(
  (select c->>'estado' from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000014', $$ select public.minhas_candidaturas() $$)) c
    where c->>'id' = (select r->>'candidatura_id' from cand_canc)),
  'aceita',
  'após cancelamento do turno a candidatura continua com estado aceita');

select is(
  (select c->>'turno_id' from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000014', $$ select public.minhas_candidaturas() $$)) c
    where c->>'id' = (select r->>'candidatura_id' from cand_canc)),
  (select r->>'turno_id' from cand_canc),
  'após cancelamento do turno a candidatura continua com o mesmo turno_id');

-- ── 4. Turno.cancelamento: causas, falta, sem motivo ──────────────────────────

-- Causa 1: profissional sem falta (antecedência >= 24h)
create temp table t_p4 as
  select t from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000014', $$ select public.meus_turnos() $$)) t
   where t->>'id' = (select r->>'turno_id' from cand_canc);

select is((select t->'cancelamento'->>'causa' from t_p4), 'profissional',
  'desistência profissional antecipada tem causa profissional');
select is((select (t->'cancelamento'->>'falta')::boolean from t_p4), false,
  'desistência profissional com mais de 24h tem falta false');
select isnt((select t->'cancelamento'->>'cancelada_em' from t_p4), null,
  'cancelada_em vem preenchido');
select is((select (t->'cancelamento') ? 'motivo' from t_p4), false,
  'Turno.cancelamento NÃO contém a chave motivo para o profissional');
select is((select t_p4.t->>'estado' from t_p4), 'cancelada',
  'Turno cancelado preserva o campo estado (0.2.31)');
select ok((select (t_p4.t ? 'avaliacao') from t_p4),
  'Turno cancelado preserva o campo avaliacao (0.2.31)');
select is(
  (select array_agg(k order by k) from jsonb_object_keys((select t from t_p4)) k),
  array['a_caminho_em','avaliacao','cancelamento','checkin_confirmado_em','checkin_distancia_m','checkin_em','checkin_tipo',
        'checkout_distancia_m','checkout_em','contato_visivel_ate','contraparte','estado','id',
        'pode_avaliar','posicao_id','vaga','valor_acordado_centavos','verificacao'],
  'Turno em meus_turnos contém todos os 18 campos do schema do contrato (sem regressão de estado e avaliacao da 0.2.31)');

-- Causa 2: profissional com falta (antecedência < 24h)
create temp table vaga_falta as select pg_temp.pub(6, 'urgencia') as id;
create temp table cand_falta as
  select pg_temp.como('c3200000-0000-4000-8000-000000000015',
    format($$ select public.candidatar(%L) $$, (select id from vaga_falta))) as r;

-- Avança o relógio para 10h antes do turno
select set_config('frila.agora',
  (select (p.inicio_em - interval '10 hours')::text
     from public.posicao p where p.id = (select (r->>'posicao_id')::uuid from cand_falta)), true);

select pg_temp.como('c3200000-0000-4000-8000-000000000015',
  format($$ select public.cancelar_posicao(%L, 'não vou conseguir chegar a tempo') $$,
         (select r->>'posicao_id' from cand_falta)));

create temp table t_p5 as
  select t from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000015', $$ select public.meus_turnos() $$)) t
   where t->>'id' = (select r->>'turno_id' from cand_falta);

select is((select t->'cancelamento'->>'causa' from t_p5), 'profissional',
  'desistência tardia tem causa profissional');
select is((select (t->'cancelamento'->>'falta')::boolean from t_p5), true,
  'desistência com menos de 24h tem falta true');
select is((select (t->'cancelamento') ? 'motivo' from t_p5), false,
  'Turno.cancelamento com falta NÃO contém a chave motivo');

-- Volta o relógio
select set_config('frila.agora', '', true);

-- Causa 3: estabelecimento cancela posição
create temp table vaga_canc_casa as select pg_temp.pub(7, 'urgencia') as id;
create temp table cand_canc_casa as
  select pg_temp.como('c3200000-0000-4000-8000-000000000016',
    format($$ select public.candidatar(%L) $$, (select id from vaga_canc_casa))) as r;

select pg_temp.como('c3200000-0000-4000-8000-0000000000d1',
  format($$ select public.cancelar_posicao(%L, 'evento cancelado pelo cliente') $$,
         (select r->>'posicao_id' from cand_canc_casa)));

create temp table t_p6 as
  select t from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000016', $$ select public.meus_turnos() $$)) t
   where t->>'id' = (select r->>'turno_id' from cand_canc_casa);

select is((select t->'cancelamento'->>'causa' from t_p6), 'estabelecimento',
  'cancelamento pela casa tem causa estabelecimento');
select is((select (t->'cancelamento'->>'falta')::boolean from t_p6), false,
  'cancelamento pela casa tem falta false');
select is((select (t->'cancelamento') ? 'motivo' from t_p6), false,
  'Turno.cancelamento da casa NÃO contém motivo para o profissional');

-- Causa 4: estabelecimento cancela vaga
create temp table vaga_canc_tot as select pg_temp.pub(8, 'urgencia') as id;
create temp table cand_canc_tot as
  select pg_temp.como('c3200000-0000-4000-8000-000000000017',
    format($$ select public.candidatar(%L) $$, (select id from vaga_canc_tot))) as r;

select pg_temp.como('c3200000-0000-4000-8000-0000000000d1',
  format($$ select public.cancelar_vaga(%L, 'reforma no salão') $$,
         (select id from vaga_canc_tot)));

create temp table t_p7 as
  select t from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000017', $$ select public.meus_turnos() $$)) t
   where t->>'id' = (select r->>'turno_id' from cand_canc_tot);

select is((select t->'cancelamento'->>'causa' from t_p7), 'estabelecimento',
  'vaga cancelada tem causa estabelecimento');
select is((select (t->'cancelamento'->>'falta')::boolean from t_p7), false,
  'vaga cancelada tem falta false');

-- Causa 5: reabertura por atraso
create temp table vaga_atraso as select pg_temp.pub(9, 'urgencia') as id;
create temp table cand_atraso as
  select pg_temp.como('c3200000-0000-4000-8000-000000000018',
    format($$ select public.candidatar(%L) $$, (select id from vaga_atraso))) as r;

-- Avança o relógio para 20 minutos após o início da vaga
select set_config('frila.agora',
  (select (p.inicio_em + interval '20 minutes')::text
     from public.posicao p where p.id = (select (r->>'posicao_id')::uuid from cand_atraso)), true);

select pg_temp.como('c3200000-0000-4000-8000-0000000000d1',
  format($$ select public.reabrir_por_atraso(%L) $$, (select r->>'posicao_id' from cand_atraso)));

create temp table t_p8 as
  select t from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000018', $$ select public.meus_turnos() $$)) t
   where t->>'id' = (select r->>'turno_id' from cand_atraso);

select is((select t->'cancelamento'->>'causa' from t_p8), 'reabertura_por_atraso',
  'reabertura por atraso tem causa reabertura_por_atraso');
select is((select (t->'cancelamento'->>'falta')::boolean from t_p8), true,
  'reabertura por atraso tem falta true');

-- Volta o relógio
select set_config('frila.agora', '', true);

-- Causa 6: turno sem check-in (no_show_sem_checkin)
select pg_temp.autenticar('c3200000-0000-4000-8000-000000000019', 'p9@teste.test');
select pg_temp.como('c3200000-0000-4000-8000-000000000019',
  $$ select public.criar_conta('profissional','Prof Nove','+5561932320019','1995-01-01','2026-09-22') $$);
select pg_temp.perfil('c3200000-0000-4000-8000-000000000019');

create temp table vaga_noshow as select pg_temp.pub(10, 'urgencia') as id;
create temp table cand_noshow as
  select pg_temp.como('c3200000-0000-4000-8000-000000000019',
    format($$ select public.candidatar(%L) $$, (select id from vaga_noshow))) as r;

-- Avança o relógio para 1h após o fim da vaga e roda fechar_turnos_noshow
select set_config('frila.agora',
  (select (p.fim_em + interval '1 hour')::text
     from public.posicao p where p.id = (select (r->>'posicao_id')::uuid from cand_noshow)), true);

select privado.fechar_turnos_passados();

create temp table t_p9 as
  select t from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-000000000019', $$ select public.meus_turnos() $$)) t
   where t->>'id' = (select r->>'turno_id' from cand_noshow);

select is((select t->'cancelamento'->>'causa' from t_p9), 'no_show_sem_checkin',
  'turno sem checkin tem causa no_show_sem_checkin');
select is((select (t->'cancelamento'->>'falta')::boolean from t_p9), true,
  'turno sem checkin tem falta true');

select set_config('frila.agora', '', true);

-- Causa 7: exclusão de conta (outro)
select pg_temp.autenticar('c3200000-0000-4000-8000-00000000001a', 'pa@teste.test');
select pg_temp.como('c3200000-0000-4000-8000-00000000001a',
  $$ select public.criar_conta('profissional','Prof Dez','+5561932320020','1995-01-01','2026-09-22') $$);
select pg_temp.perfil('c3200000-0000-4000-8000-00000000001a');

create temp table vaga_exc as select pg_temp.pub(11, 'urgencia') as id;
create temp table cand_exc as
  select pg_temp.como('c3200000-0000-4000-8000-00000000001a',
    format($$ select public.candidatar(%L) $$, (select id from vaga_exc))) as r;

-- Exclui a conta
select privado.excluir_conta('c3200000-0000-4000-8000-00000000001a');

-- O cancelamento da posição cancelada por exclusão de conta tem causa outro
create temp table canc_exc as
  select privado.cancelamento_da_posicao((select (r->>'posicao_id')::uuid from cand_exc)) as j;

select is((select j->>'causa' from canc_exc), 'outro',
  'cancelamento por exclusão de conta tem causa outro');
select is((select (j->>'falta')::boolean from canc_exc), false,
  'cancelamento por exclusão de conta tem falta false');
select is((select j->>'motivo' from canc_exc), null,
  'cancelamento por exclusão de conta tem motivo nulo');

-- Causa 8: suspensão de conta (outro)
select pg_temp.autenticar('c3200000-0000-4000-8000-00000000001b', 'pb@teste.test');
select pg_temp.como('c3200000-0000-4000-8000-00000000001b',
  $$ select public.criar_conta('profissional','Prof Onze','+5561932320021','1995-01-01','2026-09-22') $$);
select pg_temp.perfil('c3200000-0000-4000-8000-00000000001b');

create temp table vaga_susp as select pg_temp.pub(12, 'urgencia') as id;
create temp table cand_susp as
  select pg_temp.como('c3200000-0000-4000-8000-00000000001b',
    format($$ select public.candidatar(%L) $$, (select id from vaga_susp))) as r;

-- Suspende a conta via serviço
select privado.operacao_suspender_conta(
  'c3200000-0000-4000-8000-00000000001b',
  'atividade suspeita',
  'c3200000-0000-4000-8000-0000000000d1'
);

create temp table canc_susp as
  select privado.cancelamento_da_posicao((select (r->>'posicao_id')::uuid from cand_susp)) as j;

select is((select j->>'causa' from canc_susp), 'outro',
  'cancelamento por suspensão de conta tem causa outro');
select is((select (j->>'falta')::boolean from canc_susp), false,
  'cancelamento por suspensão de conta tem falta false');
select is((select j->>'motivo' from canc_susp), null,
  'cancelamento por suspensão de conta tem motivo nulo');

-- ── 5. A casa lendo meus_turnos com estabelecimento_id TAMBÉM NÃO vê motivo ──
create temp table t_casa_canc as
  select t from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-0000000000d1',
      format($$ select public.meus_turnos(estabelecimento_id => %L) $$, (select id from casa)))) t
   where t->>'id' = (select r->>'turno_id' from cand_canc_casa);

select is((select (t->'cancelamento') ? 'motivo' from t_casa_canc), false,
  'a casa em meus_turnos(estabelecimento_id) também NÃO vê a chave motivo');

-- ── 6. Igualdade entre Turno.cancelamento e privado.cancelamento_da_posicao ──
create temp table comp_pos as
  select (r->>'posicao_id')::uuid as id, (r->>'turno_id')::uuid as turno_id from cand_canc_casa;

select is(
  (select t->'cancelamento'->>'causa' from t_casa_canc),
  (select privado.cancelamento_da_posicao((select id from comp_pos))->>'causa'),
  'causa no turno é igual à causa na dedução da posição');
select is(
  (select (t->'cancelamento'->>'falta')::boolean from t_casa_canc),
  (select (privado.cancelamento_da_posicao((select id from comp_pos))->>'falta')::boolean),
  'falta no turno é igual à falta na dedução da posição');
select is(
  (select t->'cancelamento'->>'cancelada_em' from t_casa_canc),
  (select privado.cancelamento_da_posicao((select id from comp_pos))->>'cancelada_em'),
  'cancelada_em no turno é igual a cancelada_em na dedução da posição');

-- ── 7. Turno confirmado e cumprido trazem cancelamento: null ─────────────────
create temp table vaga_cumprida as select pg_temp.pub(13, 'urgencia') as id;
select pg_temp.autenticar('c3200000-0000-4000-8000-00000000001c', 'pc@teste.test');
select pg_temp.como('c3200000-0000-4000-8000-00000000001c',
  $$ select public.criar_conta('profissional','Prof Doze','+5561932320022','1995-01-01','2026-09-22') $$);
select pg_temp.perfil('c3200000-0000-4000-8000-00000000001c');

create temp table cand_cumprida as
  select pg_temp.como('c3200000-0000-4000-8000-00000000001c',
    format($$ select public.candidatar(%L) $$, (select id from vaga_cumprida))) as r;

-- Turno confirmado traz cancelamento nulo
select is(
  (select t->'cancelamento' from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-00000000001c', $$ select public.meus_turnos() $$)) t
    where t->>'id' = (select r->>'turno_id' from cand_cumprida)),
  'null'::jsonb,
  'turno confirmado traz cancelamento nulo');

-- Passa para cumprida
update public.posicao set estado = 'cumprida'
 where id = (select (r->>'posicao_id')::uuid from cand_cumprida);

select is(
  (select t->'cancelamento' from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-00000000001c', $$ select public.meus_turnos() $$)) t
    where t->>'id' = (select r->>'turno_id' from cand_cumprida)),
  'null'::jsonb,
  'turno cumprido traz cancelamento nulo');

-- Quantidade de turnos não muda
select is(
  (select count(*)::int from jsonb_array_elements(
    pg_temp.como('c3200000-0000-4000-8000-00000000001c', $$ select public.meus_turnos() $$))),
  1,
  'quantidade de turnos devolvidos não muda');

select * from finish();
rollback;
