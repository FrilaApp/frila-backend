-- 850_lembrete_casa_fim_turno.sql
--
-- Lembretes à casa sobre chegada não confirmada (30 min antes do fim e no fim)
-- (migração 20261112220000_lembrete_casa_fim_turno.sql, contrato 0.2.77, decisão JP 12/11/2026).
--
-- Regras cobertas:
--   1. Existência dos tipos no enum public.tipo_notificacao.
--   2. Janela de 30 minutos antes do fim ([fim_em - 30 min, fim_em)):
--      - antes da janela (fim - 31 min): não sai;
--      - no limite esquerdo (fim - 30 min): sai para administrador e operador;
--      - re-execução (deduplicação): não reenvia;
--      - dentro da janela (fim - 1 seg): sai.
--   3. Janela curta de término ([fim_em, fim_em + 1 hour)):
--      - exatamente no fim_em: sai para administrador e operador;
--      - re-execução (deduplicação): não reenvia;
--      - dentro da janela curta (fim + 55 min): sai;
--      - após a janela curta / caso do deploy (fim + 2 horas): NÃO sai.
--   4. Referência e agrupamento:
--      - referencia_id é o vaga_id;
--      - payload estruturado sem dados pessoais: {vaga_id: ...};
--      - vaga com múltiplas posições/profissionais pendentes emite apenas UM aviso por membro.
--   5. Condições negativas estritas:
--      - sem check-in registrado (checkin_em is null): não sai;
--      - presença já confirmada (verificacao = 'verificado'): não sai;
--      - turno já nao_verificado: não sai;
--      - posição cancelada: não sai;
--      - vaga cancelada: não sai.

begin;

-- Configuração determinística do relógio de teste
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
set local frila.agora = '2030-07-01 12:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste-850';

select plan(35);

-- ── 1. Enum public.tipo_notificacao ──────────────────────────────────────────

select ok(
  'lembrete_30min_fim_turno' = any (enum_range(null::public.tipo_notificacao)::text[]),
  'tipo_notificacao inclui lembrete_30min_fim_turno (0.2.77)'
);

select ok(
  'lembrete_fim_turno' = any (enum_range(null::public.tipo_notificacao)::text[]),
  'tipo_notificacao inclui lembrete_fim_turno (0.2.77)'
);

-- ── 2. Massa de dados isolada para testes ─────────────────────────────────────

create temp table ids on commit drop as
select
  'c8500000-0000-4000-8000-000000000001'::uuid as admin_user,
  'c8500000-0000-4000-8000-000000000002'::uuid as operador_user,
  'c8500000-0000-4000-8000-000000000003'::uuid as prof1_user,
  'c8500000-0000-4000-8000-000000000004'::uuid as prof2_user,
  'c8500000-0000-4000-8000-000000000010'::uuid as estab_id,
  'c8500000-0000-4000-8000-000000000021'::uuid as prof1_id,
  'c8500000-0000-4000-8000-000000000022'::uuid as prof2_id;

-- Usuários: 1 administrador, 1 operador e 2 profissionais
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select admin_user, 'contratante', 'Admin 850', '+5561999998501', 'admin850@test.invalid', '1980-01-01', '1.0', '2026-09-20' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select operador_user, 'contratante', 'Operador 850', '+5561999998502', 'operador850@test.invalid', '1985-01-01', '1.0', '2026-09-20' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select prof1_user, 'profissional', 'Profissional 1 850', '+5561999998503', 'prof1850@test.invalid', '1995-01-01', '1.0', '2026-09-20' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select prof2_user, 'profissional', 'Profissional 2 850', '+5561999998504', 'prof2850@test.invalid', '1996-01-01', '1.0', '2026-09-20' from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
select estab_id, 'Restaurante 850', '85000000000100', 'food_service', 'CLN 850', 'POINT(-47.8800 -15.7700)', 'Plano Piloto' from ids;

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
select estab_id, admin_user, 'administrador' from ids;

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
select estab_id, operador_user, 'operador' from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select prof1_id, prof1_user, 'POINT(-47.8800 -15.7700)' from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select prof2_id, prof2_user, 'POINT(-47.8800 -15.7700)' from ids;

-- Função auxiliar para criar vagas de teste com horários específicos
create function pg_temp.criar_vaga_teste(
  p_inicio timestamptz,
  p_fim timestamptz,
  p_posicoes int default 1,
  p_estado_vaga public.estado_vaga default 'publicada'
) returns uuid language plpgsql as $$
declare
  v_vaga uuid := gen_random_uuid();
begin
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
  ) values (
    v_vaga, (select estab_id from ids), (select id from public.funcao limit 1),
    p_inicio, p_fim, 'Salão 850', 'POINT(-47.8800 -15.7700)',
    15000, p_posicoes, false, false, false, 'Gerente', 'urgencia', p_estado_vaga,
    '2030-07-01 12:00:00+00', gen_random_uuid(), (select admin_user from ids)
  );
  return v_vaga;
end;
$$;

-- Função auxiliar para associar posição e turno a uma vaga
create function pg_temp.adicionar_posicao_turno(
  p_vaga_id uuid,
  p_prof_id uuid,
  p_inicio timestamptz,
  p_fim timestamptz,
  p_estado_posicao public.estado_posicao default 'confirmada',
  p_com_checkin boolean default true,
  p_verificacao public.verificacao_turno default 'pendente'
) returns uuid language plpgsql as $$
declare
  v_pos uuid := gen_random_uuid();
  v_t   uuid := gen_random_uuid();
begin
  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, inicio_em, fim_em)
  values (v_pos, p_vaga_id, p_prof_id, p_estado_posicao,
          case when p_estado_posicao in ('confirmada', 'cumprida') then '2030-07-01 12:00:00+00'::timestamptz else null end,
          p_inicio, p_fim);

  if p_estado_posicao <> 'cancelada' or p_com_checkin then
    insert into public.turno (id, posicao_id, checkin_em, checkin_confirmado_em, checkin_distancia_m, checkin_tipo, verificacao, valor_acordado_centavos)
    values (
      v_t, v_pos,
      case when p_com_checkin then p_inicio + interval '5 minutes' else null end,
      case when p_verificacao = 'verificado' then p_inicio + interval '10 minutes' else null end,
      null,
      case when p_com_checkin then 'manual'::public.tipo_registro else null end,
      p_verificacao,
      15000
    );
  end if;

  return v_t;
end;
$$;

-- ── 3. Cenário 1: Janela 30 minutos antes do fim ([fim_em - 30 min, fim_em)) ───
-- Turno: 2030-07-01 18:00 às 22:00. Janela do lembrete_30min_fim_turno: [21:30, 22:00).

create temp table cenario1 on commit drop as
select
  '2030-07-01 18:00:00+00'::timestamptz as inicio,
  '2030-07-01 22:00:00+00'::timestamptz as fim,
  pg_temp.criar_vaga_teste('2030-07-01 18:00:00+00'::timestamptz, '2030-07-01 22:00:00+00'::timestamptz, 1) as vaga_id;

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from cenario1),
  (select prof1_id from ids),
  (select inicio from cenario1),
  (select fim from cenario1),
  'confirmada',
  true,
  'pendente'
);

-- Teste 1a: antes da janela (21:29:00 = fim - 31 min) -> NÃO sai
set local frila.agora = '2030-07-01 21:29:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_30min_fim_turno' and referencia_id = (select vaga_id from cenario1)),
  0,
  'antes de [fim - 30 min, fim) (21:29) lembrete_30min_fim_turno NÃO é gerado'
);

-- Teste 1b: exatamente no limite esquerdo da janela (21:30:00 = fim - 30 min) -> SAI
set local frila.agora = '2030-07-01 21:30:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_30min_fim_turno' and referencia_id = (select vaga_id from cenario1)),
  2,
  'em fim - 30 min (21:30) lembrete_30min_fim_turno é gerado para ambos os membros'
);

-- Verifica destinatários: administrador e operador recebem cada um sua notificação
select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_30min_fim_turno'
      and referencia_id = (select vaga_id from cenario1)
      and usuario_id = (select admin_user from ids)),
  1,
  'administrador do estabelecimento recebe o lembrete_30min_fim_turno'
);

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_30min_fim_turno'
      and referencia_id = (select vaga_id from cenario1)
      and usuario_id = (select operador_user from ids)),
  1,
  'operador do estabelecimento recebe o lembrete_30min_fim_turno'
);

-- Verifica payload estrito (RN15)
select is(
  (select payload from public.notificacao
    where tipo = 'lembrete_30min_fim_turno'
      and referencia_id = (select vaga_id from cenario1)
      and usuario_id = (select admin_user from ids)),
  jsonb_build_object('tipo', 'lembrete_30min_fim_turno', 'vaga_id', (select vaga_id from cenario1)::text),
  'payload de lembrete_30min_fim_turno contém tipo e vaga_id sem dado pessoal'
);

-- Teste 1c: Deduplicação e idempotência ao reexecutar na janela (21:35:00)
set local frila.agora = '2030-07-01 21:35:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_30min_fim_turno' and referencia_id = (select vaga_id from cenario1)),
  2,
  'reexecução na janela não duplica lembrete_30min_fim_turno (continua 2)'
);

select is(
  (select count(*)::int from privado.marca_notificacao
    where tipo = 'lembrete_30min_fim_turno' and referencia_id = (select vaga_id from cenario1)),
  2,
  'marca durável gravada em privado.marca_notificacao para lembrete_30min_fim_turno'
);

-- ── 4. Cenário 2: Janela de término ([fim_em, fim_em + 1 hour)) ───────────────
-- Mesmo turno do Dia 1: fim em 22:00. Janela do lembrete_fim_turno: [22:00, 23:00).

-- Teste 2a: exatamente no fim_em (22:00:00) -> SAI lembrete_fim_turno
set local frila.agora = '2030-07-01 22:00:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_fim_turno' and referencia_id = (select vaga_id from cenario1)),
  2,
  'em fim_em (22:00) lembrete_fim_turno é gerado para ambos os membros'
);

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_fim_turno'
      and referencia_id = (select vaga_id from cenario1)
      and usuario_id = (select admin_user from ids)),
  1,
  'administrador recebe o lembrete_fim_turno'
);

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_fim_turno'
      and referencia_id = (select vaga_id from cenario1)
      and usuario_id = (select operador_user from ids)),
  1,
  'operador recebe o lembrete_fim_turno'
);

select is(
  (select payload from public.notificacao
    where tipo = 'lembrete_fim_turno'
      and referencia_id = (select vaga_id from cenario1)
      and usuario_id = (select admin_user from ids)),
  jsonb_build_object('tipo', 'lembrete_fim_turno', 'vaga_id', (select vaga_id from cenario1)::text),
  'payload de lembrete_fim_turno contém tipo e vaga_id sem dado pessoal'
);

-- Teste 2b: Deduplicação do lembrete_fim_turno (22:15:00)
set local frila.agora = '2030-07-01 22:15:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_fim_turno' and referencia_id = (select vaga_id from cenario1)),
  2,
  'reexecução após o término não duplica lembrete_fim_turno'
);

select is(
  (select count(*)::int from privado.marca_notificacao
    where tipo = 'lembrete_fim_turno' and referencia_id = (select vaga_id from cenario1)),
  2,
  'marca durável gravada em privado.marca_notificacao para lembrete_fim_turno'
);

-- ── 5. Cenário 3: Janela curta e proteção de deploy (passou de fim + 1h) ───────
-- Dia 2: Vaga com turno que terminou há 2 horas (fim em 20:00, relógio em 22:00).
-- Não pode receber lembrete_fim_turno na primeira execução pós-deploy.

create temp table cenario_deploy on commit drop as
select
  '2030-07-02 16:00:00+00'::timestamptz as inicio,
  '2030-07-02 20:00:00+00'::timestamptz as fim,
  pg_temp.criar_vaga_teste('2030-07-02 16:00:00+00'::timestamptz, '2030-07-02 20:00:00+00'::timestamptz, 1) as vaga_id;

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from cenario_deploy),
  (select prof2_id from ids),
  (select inicio from cenario_deploy),
  (select fim from cenario_deploy),
  'confirmada',
  true,
  'pendente'
);

-- Relógio em 22:00 (fim + 2h).
set local frila.agora = '2030-07-02 22:00:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_fim_turno' and referencia_id = (select vaga_id from cenario_deploy)),
  0,
  'caso deploy: turno terminado há 2h (fora de [fim, fim + 1h)) NÃO recebe lembrete_fim_turno'
);

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_30min_fim_turno' and referencia_id = (select vaga_id from cenario_deploy)),
  0,
  'caso deploy: turno terminado há 2h NÃO recebe lembrete_30min_fim_turno'
);

-- ── 6. Cenário 4: Borda superior da janela curta (fim + 55 min vs fim + 1h 1s) ─
-- Dia 3: Vaga 4A com fim às 21:05. Relógio às 22:00 (fim + 55 min, dentro da janela [fim, fim + 1h)).
create temp table cenario_borda_dentro on commit drop as
select
  '2030-07-03 17:05:00+00'::timestamptz as inicio,
  '2030-07-03 21:05:00+00'::timestamptz as fim,
  pg_temp.criar_vaga_teste('2030-07-03 17:05:00+00'::timestamptz, '2030-07-03 21:05:00+00'::timestamptz, 1) as vaga_id;

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from cenario_borda_dentro),
  (select prof1_id from ids),
  (select inicio from cenario_borda_dentro),
  (select fim from cenario_borda_dentro),
  'confirmada',
  true,
  'pendente'
);

set local frila.agora = '2030-07-03 22:00:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_fim_turno' and referencia_id = (select vaga_id from cenario_borda_dentro)),
  2,
  'dentro de [fim, fim + 1h) (fim + 55 min) lembrete_fim_turno é gerado'
);

-- Dia 4: Vaga 4B com fim às 20:59:59. Relógio às 22:00:00 (fim + 1h 1s, fora da janela).
create temp table cenario_borda_fora on commit drop as
select
  '2030-07-04 16:59:59+00'::timestamptz as inicio,
  '2030-07-04 20:59:59+00'::timestamptz as fim,
  pg_temp.criar_vaga_teste('2030-07-04 16:59:59+00'::timestamptz, '2030-07-04 20:59:59+00'::timestamptz, 1) as vaga_id;

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from cenario_borda_fora),
  (select prof2_id from ids),
  (select inicio from cenario_borda_fora),
  (select fim from cenario_borda_fora),
  'confirmada',
  true,
  'pendente'
);

set local frila.agora = '2030-07-04 22:00:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_fim_turno' and referencia_id = (select vaga_id from cenario_borda_fora)),
  0,
  'fora de [fim, fim + 1h) (fim + 1h 1s) lembrete_fim_turno NÃO é gerado'
);

-- ── 7. Cenário 5: Vaga com múltiplas posições ──────────────────────────────────
-- Dia 5: Vaga com 2 posições, ambas com check-in pendente de confirmação.
-- Deve emitir exatamente UM lembrete por membro para a vaga (não duplica por profissional).

create temp table cenario_multiplas on commit drop as
select
  '2030-07-05 18:00:00+00'::timestamptz as inicio,
  '2030-07-05 22:00:00+00'::timestamptz as fim,
  pg_temp.criar_vaga_teste('2030-07-05 18:00:00+00'::timestamptz, '2030-07-05 22:00:00+00'::timestamptz, 2) as vaga_id;

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from cenario_multiplas),
  (select prof1_id from ids),
  (select inicio from cenario_multiplas),
  (select fim from cenario_multiplas),
  'confirmada',
  true,
  'pendente'
);

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from cenario_multiplas),
  (select prof2_id from ids),
  (select inicio from cenario_multiplas),
  (select fim from cenario_multiplas),
  'confirmada',
  true,
  'pendente'
);

-- Em 21:30 (30 min antes):
set local frila.agora = '2030-07-05 21:30:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_30min_fim_turno' and referencia_id = (select vaga_id from cenario_multiplas)),
  2,
  'vaga com 2 posições pendentes emite exatamente 1 aviso lembrete_30min_fim_turno por membro (total 2)'
);

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_30min_fim_turno'
      and referencia_id = (select vaga_id from cenario_multiplas)
      and usuario_id = (select admin_user from ids)),
  1,
  'admin recebe apenas 1 aviso para a vaga com 2 posições'
);

-- Em 22:00 (término):
set local frila.agora = '2030-07-05 22:00:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_fim_turno' and referencia_id = (select vaga_id from cenario_multiplas)),
  2,
  'vaga com 2 posições pendentes emite exatamente 1 aviso lembrete_fim_turno por membro no encerramento'
);

-- ── 8. Cenário 6: Condições negativas estritas ─────────────────────────────────

-- 6a. Sem check-in registrado (checkin_em is null)
create temp table neg_sem_checkin on commit drop as
select
  '2030-07-06 18:00:00+00'::timestamptz as inicio,
  '2030-07-06 22:00:00+00'::timestamptz as fim,
  pg_temp.criar_vaga_teste('2030-07-06 18:00:00+00'::timestamptz, '2030-07-06 22:00:00+00'::timestamptz, 1) as vaga_id;

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from neg_sem_checkin),
  (select prof1_id from ids),
  (select inicio from neg_sem_checkin),
  (select fim from neg_sem_checkin),
  'confirmada',
  false, -- SEM check-in
  'pendente'
);

set local frila.agora = '2030-07-06 21:30:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where referencia_id = (select vaga_id from neg_sem_checkin)),
  0,
  'condição negativa: vaga sem check-in registrado NÃO gera lembrete aos 30 min'
);

set local frila.agora = '2030-07-06 22:00:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo in ('lembrete_30min_fim_turno', 'lembrete_fim_turno')
      and referencia_id = (select vaga_id from neg_sem_checkin)),
  0,
  'condição negativa: vaga sem check-in registrado NÃO gera lembrete no término'
);

-- 6b. Presença já confirmada (verificacao = 'verificado')
create temp table neg_verificado on commit drop as
select
  '2030-07-07 18:00:00+00'::timestamptz as inicio,
  '2030-07-07 22:00:00+00'::timestamptz as fim,
  pg_temp.criar_vaga_teste('2030-07-07 18:00:00+00'::timestamptz, '2030-07-07 22:00:00+00'::timestamptz, 1) as vaga_id;

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from neg_verificado),
  (select prof1_id from ids),
  (select inicio from neg_verificado),
  (select fim from neg_verificado),
  'confirmada',
  true,
  'verificado' -- JÁ VERIFICADO
);

set local frila.agora = '2030-07-07 21:30:00+00';
select privado.fechar_turnos_passados();
set local frila.agora = '2030-07-07 22:00:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo in ('lembrete_30min_fim_turno', 'lembrete_fim_turno')
      and referencia_id = (select vaga_id from neg_verificado)),
  0,
  'condição negativa: turno já verificado NÃO gera nenhum dos dois lembretes'
);

-- 6c. Turno já encerrado como nao_verificado
create temp table neg_nao_verificado on commit drop as
select
  '2030-07-08 18:00:00+00'::timestamptz as inicio,
  '2030-07-08 22:00:00+00'::timestamptz as fim,
  pg_temp.criar_vaga_teste('2030-07-08 18:00:00+00'::timestamptz, '2030-07-08 22:00:00+00'::timestamptz, 1) as vaga_id;

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from neg_nao_verificado),
  (select prof1_id from ids),
  (select inicio from neg_nao_verificado),
  (select fim from neg_nao_verificado),
  'confirmada',
  true,
  'nao_verificado' -- NÃO VERIFICADO
);

set local frila.agora = '2030-07-08 21:30:00+00';
select privado.fechar_turnos_passados();
set local frila.agora = '2030-07-08 22:00:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo in ('lembrete_30min_fim_turno', 'lembrete_fim_turno')
      and referencia_id = (select vaga_id from neg_nao_verificado)),
  0,
  'condição negativa: turno já nao_verificado NÃO gera lembretes'
);

-- 6d. Posição cancelada
create temp table neg_pos_cancelada on commit drop as
select
  '2030-07-09 18:00:00+00'::timestamptz as inicio,
  '2030-07-09 22:00:00+00'::timestamptz as fim,
  pg_temp.criar_vaga_teste('2030-07-09 18:00:00+00'::timestamptz, '2030-07-09 22:00:00+00'::timestamptz, 1) as vaga_id;

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from neg_pos_cancelada),
  (select prof1_id from ids),
  (select inicio from neg_pos_cancelada),
  (select fim from neg_pos_cancelada),
  'cancelada', -- POSIÇÃO CANCELADA
  true,
  'pendente'
);

set local frila.agora = '2030-07-09 21:30:00+00';
select privado.fechar_turnos_passados();
set local frila.agora = '2030-07-09 22:00:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo in ('lembrete_30min_fim_turno', 'lembrete_fim_turno')
      and referencia_id = (select vaga_id from neg_pos_cancelada)),
  0,
  'condição negativa: posição cancelada NÃO gera lembretes'
);

-- 6e. Vaga cancelada
create temp table neg_vaga_cancelada on commit drop as
select
  '2030-07-10 18:00:00+00'::timestamptz as inicio,
  '2030-07-10 22:00:00+00'::timestamptz as fim,
  pg_temp.criar_vaga_teste('2030-07-10 18:00:00+00'::timestamptz, '2030-07-10 22:00:00+00'::timestamptz, 1, 'cancelada') as vaga_id;

select pg_temp.adicionar_posicao_turno(
  (select vaga_id from neg_vaga_cancelada),
  (select prof1_id from ids),
  (select inicio from neg_vaga_cancelada),
  (select fim from neg_vaga_cancelada),
  'confirmada',
  true,
  'pendente'
);

set local frila.agora = '2030-07-10 21:30:00+00';
select privado.fechar_turnos_passados();
set local frila.agora = '2030-07-10 22:00:00+00';
select privado.fechar_turnos_passados();

select is(
  (select count(*)::int from public.notificacao
    where tipo in ('lembrete_30min_fim_turno', 'lembrete_fim_turno')
      and referencia_id = (select vaga_id from neg_vaga_cancelada)),
  0,
  'condição negativa: vaga cancelada NÃO gera lembretes'
);

-- ── 9. Estrutura e privilégios de privado.fechar_turnos_passados() ─────────────

select has_function(
  'privado', 'fechar_turnos_passados',
  array[]::text[],
  'privado.fechar_turnos_passados() existe'
);

select function_lang_is(
  'privado', 'fechar_turnos_passados',
  array[]::text[],
  'plpgsql',
  'privado.fechar_turnos_passados é em plpgsql'
);

select is(
  (select proconfig from pg_proc where proname = 'fechar_turnos_passados' and pronamespace = 'privado'::regnamespace),
  array['search_path=""'],
  'privado.fechar_turnos_passados possui search_path="" vazio'
);

select is(
  (select prosecdef from pg_proc where proname = 'fechar_turnos_passados' and pronamespace = 'privado'::regnamespace),
  true,
  'privado.fechar_turnos_passados é security definer'
);

select is(
  has_function_privilege('anon', 'privado.fechar_turnos_passados()', 'execute'),
  false,
  'anon não pode executar privado.fechar_turnos_passados'
);

select is(
  has_function_privilege('authenticated', 'privado.fechar_turnos_passados()', 'execute'),
  false,
  'authenticated não pode executar privado.fechar_turnos_passados'
);

select is(
  has_function_privilege('service_role', 'privado.fechar_turnos_passados()', 'execute'),
  true,
  'service_role pode executar privado.fechar_turnos_passados'
);

rollback;
