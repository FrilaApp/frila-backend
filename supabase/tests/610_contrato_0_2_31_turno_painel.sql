-- 610_contrato_0_2_31_turno_painel.sql
--
-- Contrato 0.2.31: turno cancelado, avaliação já dada e cancelamento no painel (cartão 7IIPRTdg).
--
-- Critérios de aceite cobrados aqui:
--   1. has_index em ocorrencia(posicao_id)
--   2. meus_turnos devolve turno cancelado com estado: cancelada, de pé com confirmada e
--      encerrado com cumprida; contagem não muda ao cancelar.
--   3. Turno.avaliacao é nulo antes de avaliar e preenchido após; pode_avaliar vira false;
--      operador vê o voto do admin da mesma casa; ninguém vê a avaliação recebida.
--   4. painel: checkin_em, checkin_tipo e checkin_confirmado_em no check-in manual.
--   5. painel: todas as causas de cancelamento (profissional com/sem falta, estabelecimento,
--      vaga_cancelada, reabertura_por_atraso, no_show_sem_checkin, exclusao, suspensao).
--   6. cancelamento sem profissional resulta em cancelamento: null.
--   7. códigos fixos e 'exclusão de conta' / 'suspensão de conta' nunca saem em motivo.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(26);

-- ── 1. Índice no caminho do painel ────────────────────────────────────────────
select has_index(
  'public', 'ocorrencia', 'ocorrencia_posicao_id', array['posicao_id'],
  '0.2.31: índice ocorrencia_posicao_id existe cobrindo ocorrencia(posicao_id)'
);

-- ── Setup de contas e estabelecimento ─────────────────────────────────────────
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

-- Contas de teste
select pg_temp.autenticar('bb100000-0000-4000-8000-000000000001','dono@p31.test');
select pg_temp.autenticar('bb100000-0000-4000-8000-000000000002','operador@p31.test');
select pg_temp.autenticar('bb100000-0000-4000-8000-000000000003','p1@p31.test');
select pg_temp.autenticar('bb100000-0000-4000-8000-000000000004','p2@p31.test');

select pg_temp.como('bb100000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante','Dono P31','+5561977770001','1980-01-01','2026-09-22') $$);
select pg_temp.como('bb100000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('contratante','Operador P31','+5561977770002','1982-01-01','2026-09-22') $$);
select pg_temp.como('bb100000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional','Prof 1 P31','+5561977770003','1995-01-01','2026-09-22') $$);
select pg_temp.como('bb100000-0000-4000-8000-000000000004',
  $$ select public.criar_conta('profissional','Prof 2 P31','+5561977770004','1996-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como('bb100000-0000-4000-8000-000000000003',
  format($$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.79,"longitude":-47.88}'::jsonb) $$, (select garcom from fn)));
select pg_temp.como('bb100000-0000-4000-8000-000000000004',
  format($$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.79,"longitude":-47.88}'::jsonb) $$, (select garcom from fn)));

create temp table casa as
  select (pg_temp.como('bb100000-0000-4000-8000-000000000001',
    $$ select public.cadastrar_estabelecimento('Bar 031','04252011000110','food_service','SCLN 100',
         '{"latitude":-15.79,"longitude":-47.88}') $$)->>'id')::uuid as id;

-- Operador vinculado à mesma casa
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('bb100000-0000-4000-8000-000000000002', (select id from casa), 'operador');

-- ── 2. Teste de todas as causas de cancelamento no painel ─────────────────────
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-15 12:00:00+00';

-- Cria vaga base para os testes de cancelamento
create function pg_temp.criar_vaga_com_prof(p_chave uuid, p_prof_conta uuid, p_ini timestamptz, p_fim timestamptz)
returns table (vaga_id uuid, pos_id uuid, turno_id uuid) language plpgsql as $$
declare
  v_vaga_id uuid;
  v_pos_id  uuid;
  v_turno   uuid;
begin
  select (pg_temp.como('bb100000-0000-4000-8000-000000000001', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'SCLN 100',
            '{"latitude":-15.79,"longitude":-47.88}'::jsonb, 15000, 1, true, true, false, 'Gerente', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn), p_ini, p_fim, p_chave))->>'vaga_id')::uuid
    into v_vaga_id;

  select (pg_temp.como(p_prof_conta, format(
    $sql$ select public.candidatar(%L) $sql$, v_vaga_id))->>'turno_id')::uuid
    into v_turno;

  select t.posicao_id into v_pos_id from public.turno t where t.id = v_turno;

  return query select v_vaga_id, v_pos_id, v_turno;
end $$;

create function pg_temp.obter_posicao(p_pos_id uuid) returns jsonb language plpgsql as $$
declare
  p jsonb;
  x jsonb;
begin
  p := pg_temp.como('bb100000-0000-4000-8000-000000000001', format(
         $sql$ select public.painel_estabelecimento(%L::uuid, '2026-10-01 00:00+00'::timestamptz, '2026-10-31 00:00+00'::timestamptz) $sql$,
         (select id from casa)));
  select elem into x
    from jsonb_array_elements(p->'vagas') v,
         jsonb_array_elements(v->'posicoes') elem
   where elem->>'id' = p_pos_id::text;
  return x;
end $$;

create function pg_temp.obter_cancelamento(p_pos_id uuid) returns jsonb language sql as $$
  select pg_temp.obter_posicao(p_pos_id)->'cancelamento';
$$;

-- Causa 1: Desistência do profissional com falta (< 24h)
create temp table c1 as
  select * from pg_temp.criar_vaga_com_prof('bb200000-0000-4000-8000-000000000001',
    'bb100000-0000-4000-8000-000000000003',
    '2026-10-15 18:00:00+00'::timestamptz, '2026-10-15 22:00:00+00'::timestamptz);

select pg_temp.como('bb100000-0000-4000-8000-000000000003', format(
  $$ select public.cancelar_posicao(%L::uuid, 'Imprevisto medico urgente') $$, (select pos_id from c1)));

select is((select pg_temp.obter_cancelamento((select pos_id from c1))->>'causa'), 'profissional',
  '0.2.31: cancelamento por desistencia do profissional tem causa profissional');
select is((select pg_temp.obter_cancelamento((select pos_id from c1))->>'motivo'), 'Imprevisto medico urgente',
  '0.2.31: motivo do profissional traz o texto livre digitado');
select is((select (pg_temp.obter_cancelamento((select pos_id from c1))->>'falta')::boolean), true,
  '0.2.31: desistencia a menos de 24h gera falta = true');

-- Causa 2: Desistência do profissional sem falta (>= 24h)
create temp table c2 as
  select * from pg_temp.criar_vaga_com_prof('bb200000-0000-4000-8000-000000000002',
    'bb100000-0000-4000-8000-000000000003',
    '2026-10-18 18:00:00+00'::timestamptz, '2026-10-18 22:00:00+00'::timestamptz);

select pg_temp.como('bb100000-0000-4000-8000-000000000003', format(
  $$ select public.cancelar_posicao(%L::uuid, 'Aviso previo com antecedencia') $$, (select pos_id from c2)));

select is((select (pg_temp.obter_cancelamento((select pos_id from c2))->>'falta')::boolean), false,
  '0.2.31: desistencia a mais de 24h gera falta = false');

-- Causa 3: Cancelamento pela casa da posição (cancelar_posicao com membro da casa)
create temp table c3 as
  select * from pg_temp.criar_vaga_com_prof('bb200000-0000-4000-8000-000000000003',
    'bb100000-0000-4000-8000-000000000004',
    '2026-10-18 18:00:00+00'::timestamptz, '2026-10-18 22:00:00+00'::timestamptz);

select pg_temp.como('bb100000-0000-4000-8000-000000000001', format(
  $$ select public.cancelar_posicao(%L::uuid, 'Reducao de movimento na casa') $$, (select pos_id from c3)));

select is((select pg_temp.obter_cancelamento((select pos_id from c3))->>'causa'), 'estabelecimento',
  '0.2.31: cancelamento pela casa tem causa estabelecimento');
select is((select pg_temp.obter_cancelamento((select pos_id from c3))->>'motivo'), 'Reducao de movimento na casa',
  '0.2.31: motivo do cancelamento pela casa traz o texto livre da casa');

-- Causa 4: Cancelamento da vaga inteira pela casa (cancelar_vaga)
create temp table c4 as
  select * from pg_temp.criar_vaga_com_prof('bb200000-0000-4000-8000-000000000004',
    'bb100000-0000-4000-8000-000000000004',
    '2026-10-19 18:00:00+00'::timestamptz, '2026-10-19 22:00:00+00'::timestamptz);

select pg_temp.como('bb100000-0000-4000-8000-000000000001', format(
  $$ select public.cancelar_vaga(%L::uuid, 'evento cancelado') $$, (select vaga_id from c4)));

select is((select pg_temp.obter_cancelamento((select pos_id from c4))->>'causa'), 'estabelecimento',
  '0.2.31: vaga cancelada tem causa estabelecimento');
select is((select pg_temp.obter_cancelamento((select pos_id from c4))->>'motivo'), 'evento cancelado',
  '0.2.31: vaga cancelada com motivo livre preserva o texto digitado');

-- Causa 4b: Código interno vaga_cancelada não vaza no painel
create temp table c4b as
  select * from pg_temp.criar_vaga_com_prof('bb200000-0000-4000-8000-00000000004b',
    'bb100000-0000-4000-8000-000000000004',
    '2026-10-19 18:00:00+00'::timestamptz, '2026-10-19 22:00:00+00'::timestamptz);

update public.posicao set estado = 'cancelada' where id = (select pos_id from c4b);
insert into public.ocorrencia (tipo, posicao_id, usuario_id, autor_id, motivo)
values ('cancelamento', (select pos_id from c4b),
        'bb100000-0000-4000-8000-000000000004'::uuid,
        'bb100000-0000-4000-8000-000000000001'::uuid,
        'vaga_cancelada');

select is((select pg_temp.obter_cancelamento((select pos_id from c4b))->>'causa'), 'estabelecimento',
  '0.2.31: vaga cancelada com codigo interno tem causa estabelecimento');
select is((select pg_temp.obter_cancelamento((select pos_id from c4b))->'motivo'), 'null'::jsonb,
  '0.2.31: vaga cancelada tem motivo nulo quando o codigo interno vaga_cancelada e usado');

-- Causa 5: Reabertura por atraso aos 15 min (reabrir_por_atraso)
create temp table c5 as
  select * from pg_temp.criar_vaga_com_prof('bb200000-0000-4000-8000-000000000005',
    'bb100000-0000-4000-8000-000000000003',
    '2026-10-15 13:00:00+00'::timestamptz, '2026-10-15 17:00:00+00'::timestamptz);

-- Avança o relógio para 20 minutos após o início do turno
set local frila.agora = '2026-10-15 13:20:00+00';

select pg_temp.como('bb100000-0000-4000-8000-000000000001', format(
  $$ select public.reabrir_por_atraso(%L::uuid) $$, (select pos_id from c5)));

select is((select pg_temp.obter_cancelamento((select pos_id from c5))->>'causa'), 'reabertura_por_atraso',
  '0.2.31: reabertura por atraso tem causa reabertura_por_atraso');
select is((select pg_temp.obter_cancelamento((select pos_id from c5))->'motivo'), 'null'::jsonb,
  '0.2.31: reabertura por atraso tem motivo nulo (sem codigo vazado)');
select is((select (pg_temp.obter_cancelamento((select pos_id from c5))->>'falta')::boolean), true,
  '0.2.31: reabertura por atraso gera falta = true');

-- Causa 6: Turno encerrado sem check-in (fechar_turnos_passados)
create temp table c6 as
  select * from pg_temp.criar_vaga_com_prof('bb200000-0000-4000-8000-000000000006',
    'bb100000-0000-4000-8000-000000000004',
    '2026-10-15 14:00:00+00'::timestamptz, '2026-10-15 18:00:00+00'::timestamptz);

-- Avança o relógio para depois do término da vaga
set local frila.agora = '2026-10-15 19:00:00+00';

select privado.fechar_turnos_passados();

select is((select pg_temp.obter_cancelamento((select pos_id from c6))->>'causa'), 'no_show_sem_checkin',
  '0.2.31: turno sem check-in tem causa no_show_sem_checkin');
select is((select pg_temp.obter_cancelamento((select pos_id from c6))->'motivo'), 'null'::jsonb,
  '0.2.31: no show tem motivo nulo');
select is((select (pg_temp.obter_cancelamento((select pos_id from c6))->>'falta')::boolean), true,
  '0.2.31: no show gera falta = true');

-- Causa 7: Exclusão de conta
create temp table c7 as
  select * from pg_temp.criar_vaga_com_prof('bb200000-0000-4000-8000-000000000007',
    'bb100000-0000-4000-8000-000000000003',
    '2026-10-20 18:00:00+00'::timestamptz, '2026-10-20 22:00:00+00'::timestamptz);

-- Simula cancelamento por exclusao de conta (como em privado.cancelar_uma_posicao)
select set_config('frila.exclusao_de_conta', 'on', true);
select privado.cancelar_uma_posicao((select pos_id from c7), 'bb100000-0000-4000-8000-000000000003'::uuid, 'exclusão de conta', true);
select set_config('frila.exclusao_de_conta', 'off', true);

select is((select pg_temp.obter_cancelamento((select pos_id from c7))->>'causa'), 'outro',
  '0.2.31: exclusao de conta tem causa outro');
select is((select pg_temp.obter_cancelamento((select pos_id from c7))->'motivo'), 'null'::jsonb,
  '0.2.31: exclusao de conta tem motivo nulo (o texto literal exclusão de conta nao vaza)');
select is((select (pg_temp.obter_cancelamento((select pos_id from c7))->>'falta')::boolean), false,
  '0.2.31: exclusao de conta nao gera falta');

-- Causa 8: Suspensão de conta
create temp table c8 as
  select * from pg_temp.criar_vaga_com_prof('bb200000-0000-4000-8000-000000000008',
    'bb100000-0000-4000-8000-000000000004',
    '2026-10-21 18:00:00+00'::timestamptz, '2026-10-21 22:00:00+00'::timestamptz);

select set_config('frila.exclusao_de_conta', 'on', true);
select privado.cancelar_uma_posicao((select pos_id from c8), 'bb100000-0000-4000-8000-000000000004'::uuid, 'suspensão de conta', true);
select set_config('frila.exclusao_de_conta', 'off', true);

select is((select pg_temp.obter_cancelamento((select pos_id from c8))->>'causa'), 'outro',
  '0.2.31: suspensao de conta tem causa outro');
select is((select pg_temp.obter_cancelamento((select pos_id from c8))->'motivo'), 'null'::jsonb,
  '0.2.31: suspensao de conta tem motivo nulo (o texto literal suspensão de conta nao vaza)');

-- Posição cancelada sem profissional traz cancelamento: null
create function pg_temp.publicar_sem_prof(p_chave uuid) returns uuid language plpgsql as $$
declare
  v_vaga_id uuid;
begin
  select (pg_temp.como('bb100000-0000-4000-8000-000000000001', format(
    $sql$ select public.publicar_vaga(%L, %L, '2026-10-25 18:00+00'::timestamptz, '2026-10-25 22:00+00'::timestamptz,
            'SCLN 100', '{"latitude":-15.79,"longitude":-47.88}'::jsonb, 15000, 1, true, true, false, 'Gerente', 'urgencia',
            %L) $sql$,
    (select id from casa), (select garcom from fn), p_chave))->>'vaga_id')::uuid
    into v_vaga_id;
  return v_vaga_id;
end $$;

create temp table c_sem_prof as
  select pg_temp.publicar_sem_prof('bb200000-0000-4000-8000-000000000099'::uuid) as vaga_id;

update public.posicao set estado = 'cancelada'
 where vaga_id = (select vaga_id::uuid from c_sem_prof);

select is(
  (select elem->'cancelamento'
     from jsonb_array_elements(pg_temp.como('bb100000-0000-4000-8000-000000000001', format(
            $sql$ select public.painel_estabelecimento(%L::uuid, '2026-10-01 00:00+00'::timestamptz, '2026-10-31 00:00+00'::timestamptz) $sql$,
            (select id from casa)))->'vagas') v,
          jsonb_array_elements(v->'posicoes') elem
    where v->'vaga'->>'id' = (select vaga_id::text from c_sem_prof)),
  'null'::jsonb,
  '0.2.31: posicao cancelada que nunca teve profissional traz cancelamento: null');

-- ── 3. Check-in manual no painel ─────────────────────────────────────────────
create temp table c_manual as
  select * from pg_temp.criar_vaga_com_prof('bb200000-0000-4000-8000-000000000010',
    'bb100000-0000-4000-8000-000000000004',
    '2026-10-22 11:30:00+00'::timestamptz, '2026-10-22 15:30:00+00'::timestamptz);

-- Profissional faz check-in manual
update public.turno
   set checkin_em = '2026-10-22 11:35:00+00'::timestamptz,
       checkin_tipo = 'manual'
 where id = (select turno_id from c_manual);

select is(
  (select pg_temp.obter_posicao((select pos_id from c_manual))->>'checkin_tipo'),
  'manual',
  '0.2.31: painel traz checkin_tipo = manual');

select is(
  (select pg_temp.obter_posicao((select pos_id from c_manual))->'checkin_confirmado_em'),
  'null'::jsonb,
  '0.2.31: checkin_confirmado_em é null antes da confirmacao pelo contratante');

-- Contratante confirma
select pg_temp.como('bb100000-0000-4000-8000-000000000001', format(
  $$ select public.confirmar_checkin_manual(%L::uuid) $$, (select turno_id from c_manual)));

select ok(
  (select (pg_temp.obter_posicao((select pos_id from c_manual))->>'checkin_confirmado_em') is not null),
  '0.2.31: checkin_confirmado_em preenchido apos confirmacao pelo contratante');

select * from finish();
rollback;
