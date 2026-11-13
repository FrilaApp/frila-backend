-- 854_checkin_tolerancia_zero_depois_do_fim.sql
--
-- Tolerância zero para check-in que chega ao servidor após o fim previsto do turno (fim_em).
-- Decisão do JP (13/11/2026, contrato 0.2.80, migração 20261114020000).
--
-- Cobertura mínima obrigatória:
--   1. Toque recebido antes do fim, com registrado_em dentro da janela → aceito.
--   2. Toque recebido 1 s depois do fim, com registrado_em dentro da janela → 422 fora_da_janela.
--   3. Toque recebido no dia seguinte com registrado_em de ontem → 422 fora_da_janela.
--   4. Repetição depois do fim num turno já com check-in → 422 fora_da_janela e check-in antigo intacto.
--   5. Conta de demonstração depois do fim → aceita.

begin;

insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
set local frila.agendador_secret = 'segredo-de-teste-854';

select plan(11);

-- ── 1. Estrutura da função public.fazer_checkin ──────────────────────────────

select function_lang_is(
  'public', 'fazer_checkin',
  array['uuid', 'integer', 'timestamp with time zone', 'jsonb'],
  'plpgsql',
  'public.fazer_checkin é em plpgsql'
);

-- ── Massa de dados de teste ──────────────────────────────────────────────────

create temp table ids as
select 'd8540000-0000-4000-8000-000000000001'::uuid as dono,
       'd8540000-0000-4000-8000-000000000010'::uuid as casa;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select dono, 'contratante'::public.perfil_conta, 'Dono 854', '+5561999998540', 'dono854@test.invalid',
       '1985-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select casa, 'Bar 854', '85400000000185', 'food_service'::public.tipo_estabelecimento, 'Endereço 854',
       'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select dono, casa, 'administrador' from ids;

create temp table turnos (nome text primary key, turno uuid, usuario uuid, prof uuid);

create function pg_temp.novo_turno(
  p_nome text,
  p_inicio timestamptz default '2027-01-15 10:00:00+00',
  p_fim timestamptz default '2027-01-15 14:00:00+00',
  p_demonstracao boolean default false
) returns uuid language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_prof uuid := gen_random_uuid();
  v_vaga uuid := gen_random_uuid();
  v_pos  uuid := gen_random_uuid();
  v_t    uuid := gen_random_uuid();
  v_casa uuid := (select casa from ids);
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
  values (v_user, 'profissional', 'Prof 854 ' || p_nome, '+556199999854' || (select count(*)+1 from turnos),
          p_nome || '@t854.invalid', '1992-01-01', '1.0', '2026-09-20 12:00:00-03', p_demonstracao);

  insert into public.profissional (id, usuario_id, ponto_base)
  values (v_prof, v_user, 'POINT(-47.8800 -15.7700)');

  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
  )
  values (
    v_vaga, v_casa, (select id from public.funcao limit 1),
    p_inicio, p_fim, 'Local 854', 'POINT(-47.8800 -15.7700)',
    15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', p_inicio - interval '24 hours',
    gen_random_uuid(), (select dono from ids)
  );

  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_pos, v_vaga, 'confirmada', v_prof, p_inicio - interval '20 hours', p_inicio, p_fim);

  insert into public.turno (id, posicao_id, valor_acordado_centavos)
  values (v_t, v_pos, 15000);

  insert into turnos values (p_nome, v_t, v_user, v_prof);
  return v_t;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute sql into r;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return r;
end $$;

create function pg_temp.t(nome text) returns uuid language sql as $$
  select turno from turnos where turnos.nome = t.nome
$$;

create function pg_temp.u(nome text) returns uuid language sql as $$
  select usuario from turnos where turnos.nome = u.nome
$$;

create function pg_temp.fazer_checkin(
  p_nome text,
  p_distancia integer default null,
  p_registrado_em timestamptz default privado.agora()
) returns jsonb language sql as $$
  select pg_temp.como(
    pg_temp.u(p_nome),
    format('select public.fazer_checkin(%L::uuid, %s, %L::timestamptz)',
           pg_temp.t(p_nome), coalesce(p_distancia::text, 'null'), p_registrado_em)
  )
$$;

-- ── 2. Cenário 1: Toque recebido antes do fim com registrado_em na janela ───
-- Turno: 10:00 às 14:00. Relógio do servidor: 13:59:59. Registrado em: 13:59:50.
select pg_temp.novo_turno('antes_do_fim');
select set_config('frila.agora', '2027-01-15 13:59:59+00', true);

select lives_ok(
  $$ select pg_temp.fazer_checkin('antes_do_fim', 10, '2027-01-15 13:59:50+00'::timestamptz) $$,
  'Cenário 1: Toque recebido antes do fim (13:59:59 <= 14:00:00) com registrado_em na janela é aceito'
);

select is(
  (select checkin_em from public.turno where id = pg_temp.t('antes_do_fim')),
  '2027-01-15 13:59:50+00'::timestamptz,
  'Cenário 1: checkin_em gravado com o instante do toque informado'
);

-- ── 3. Cenário 2: Toque recebido 1 s depois do fim (tolerância zero) ─────────
-- Turno: 10:00 às 14:00. Relógio do servidor: 14:00:01. Registrado em: 13:59:50 (na janela).
select pg_temp.novo_turno('um_segundo_apos_fim');
select set_config('frila.agora', '2027-01-15 14:00:01+00', true);

select throws_ok(
  $$ select pg_temp.fazer_checkin('um_segundo_apos_fim', 10, '2027-01-15 13:59:50+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'Cenário 2: Toque recebido 1 s depois do fim (14:00:01 > 14:00:00) é recusado com 422 fora_da_janela'
);

select is(
  (select checkin_em from public.turno where id = pg_temp.t('um_segundo_apos_fim')),
  null,
  'Cenário 2: Turno permanece sem check-in após recusa'
);

-- ── 4. Cenário 3: Toque recebido no dia seguinte com registrado_em de ontem ───
-- Turno: 10:00 às 14:00 do dia 15. Relógio do servidor: dia 16 às 09:00.
select pg_temp.novo_turno('dia_seguinte');
select set_config('frila.agora', '2027-01-16 09:00:00+00', true);

select throws_ok(
  $$ select pg_temp.fazer_checkin('dia_seguinte', 10, '2027-01-15 11:00:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'Cenário 3: Toque guardado offline e recebido no dia seguinte é recusado com 422 fora_da_janela'
);

select is(
  (select checkin_em from public.turno where id = pg_temp.t('dia_seguinte')),
  null,
  'Cenário 3: Turno permanece sem check-in'
);

-- ── 5. Cenário 4: Repetição depois do fim em turno já com check-in ────────────
-- Check-in realizado com sucesso durante o turno (às 10:30:00).
select pg_temp.novo_turno('repeticao_pos_fim');
select set_config('frila.agora', '2027-01-15 10:30:00+00', true);
select pg_temp.fazer_checkin('repeticao_pos_fim', 20, '2027-01-15 10:30:00+00'::timestamptz);

-- Servidor avança para depois do fim previsto do turno (14:15:00)
select set_config('frila.agora', '2027-01-15 14:15:00+00', true);

select throws_ok(
  $$ select pg_temp.fazer_checkin('repeticao_pos_fim', 10, '2027-01-15 10:35:00+00'::timestamptz) $$,
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'Cenário 4: Repetição de toque após o fim do turno é recusada com 422 fora_da_janela'
);

select is(
  (select checkin_em from public.turno where id = pg_temp.t('repeticao_pos_fim')),
  '2027-01-15 10:30:00+00'::timestamptz,
  'Cenário 4: Check-in original permanece intacto (instante preservado)'
);

-- ── 6. Cenário 5: Conta de demonstração depois do fim ─────────────────────────
-- Conta com usuario.demonstracao = true atravessa a janela pós-fim (recebe 200).
select pg_temp.novo_turno('demo_pos_fim', '2027-01-15 10:00:00+00', '2027-01-15 14:00:00+00', true);
select set_config('frila.agora', '2027-01-15 14:30:00+00', true);

select lives_ok(
  $$ select pg_temp.fazer_checkin('demo_pos_fim', 15, '2027-01-15 14:30:00+00'::timestamptz) $$,
  'Cenário 5: Conta de demonstração após o fim é aceita (atravessa a janela)'
);

select is(
  (select checkin_em from public.turno where id = pg_temp.t('demo_pos_fim')),
  '2027-01-15 14:30:00+00'::timestamptz,
  'Cenário 5: Check-in da conta de demonstração registrado com sucesso'
);

rollback;
