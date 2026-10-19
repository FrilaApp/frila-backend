-- 650_fechamento_vaga_expirada_sem_processo.sql
--
-- Cartão D654gdGQ: Vagas publicadas após fim_em não são fechadas.
-- Problema: fechar_turnos_e_vagas só encerrava vagas quando não havia posições
-- abertas ou confirmadas. Vagas publicadas cujo fim_em já passou sem nenhuma
-- confirmação permaneciam com posições 'aberta' e estado 'publicada' para sempre,
-- poluindo o índice GiST e a busca de vagas.
--
-- Cobertura:
-- 1. Vaga publicada de 1 posição sem confirmação/processo cujo fim_em passou:
--    vira 'encerrada', e sua posição aberta vira 'cancelada'.
-- 2. Vaga publicada de 2 posições (1 confirmada e cumprida, 1 não preenchida):
--    vira 'encerrada', a confirmada vira 'cumprida' e a aberta vira 'cancelada'.
-- 3. Vaga futura cujo fim_em ainda não chegou:
--    continua 'publicada' e suas posições continuam 'aberta'.
-- 4. Idempotência:
--    reexecutar fechar_turnos_e_vagas mantém os estados sem efeitos colaterais.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(12);

insert into privado.ambiente (eh_teste) values (true);
select set_config('frila.agora', '2026-10-02 12:00:00-03', true);

create temp table ids as
select
  'c6000000-0000-4000-8000-000000000001'::uuid as prof_user,
  'c6000000-0000-4000-8000-000000000002'::uuid as contratante_user,
  'c6000000-0000-4000-8000-000000000011'::uuid as profissional,
  'c6000000-0000-4000-8000-000000000021'::uuid as estabelecimento,
  -- Cenário 1: Vaga sem processo (1 posição aberta que expirou)
  'c6000000-0000-4000-8000-000000000031'::uuid as vaga_sem_processo,
  'c6000000-0000-4000-8000-000000000041'::uuid as pos_sem_processo,
  -- Cenário 2: Vaga mista (1 posição confirmada/cumprida + 1 aberta que expirou)
  'c6000000-0000-4000-8000-000000000032'::uuid as vaga_mista,
  'c6000000-0000-4000-8000-000000000042'::uuid as pos_mista_cumprida,
  'c6000000-0000-4000-8000-000000000043'::uuid as pos_mista_sobra,
  'c6000000-0000-4000-8000-000000000052'::uuid as turno_misto,
  -- Cenário 3: Vaga futura (não deve ser fechada)
  'c6000000-0000-4000-8000-000000000033'::uuid as vaga_futura,
  'c6000000-0000-4000-8000-000000000044'::uuid as pos_futura;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select prof_user, 'profissional'::public.perfil_conta, 'Profissional Teste Exp',
       '+5561999990011', 'prof-exp@test.invalid', '1992-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids
union all
select contratante_user, 'contratante'::public.perfil_conta, 'Casa Teste Exp',
       '+5561999990012', 'casa-exp@test.invalid', '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select profissional, prof_user, 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.profissional_funcao (profissional_id, funcao_id)
select profissional, (select id from public.funcao limit 1)
  from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select estabelecimento, 'Casa Vagas Expiradas', '80000000000292', 'food_service',
       'Endereco de teste', 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select contratante_user, estabelecimento, 'administrador'
  from ids;

-- ── 1. Cenário 1: Vaga sem processo (1 posição aberta que expirou) ─────────────
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_sem_processo, estabelecimento, (select id from public.funcao limit 1),
       '2026-10-02 18:00:00-03', '2026-10-02 23:00:00-03',
       'Local DF', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada',
       '2026-10-01 12:00:00-03', gen_random_uuid(), contratante_user
  from ids;

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
select pos_sem_processo, vaga_sem_processo, 'aberta',
       '2026-10-02 18:00:00-03', '2026-10-02 23:00:00-03'
  from ids;

-- ── 2. Cenário 2: Vaga mista (1 cumprida + 1 aberta que expirou) ───────────────
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_mista, estabelecimento, (select id from public.funcao limit 1),
       '2026-10-02 18:00:00-03', '2026-10-02 23:00:00-03',
       'Local DF 2', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 2, false, false, false, 'Gerente', 'urgencia', 'publicada',
       '2026-10-01 12:00:00-03', gen_random_uuid(), contratante_user
  from ids;

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select pos_mista_cumprida, vaga_mista, 'confirmada', profissional,
       '2026-10-01 15:00:00-03', '2026-10-02 18:00:00-03', '2026-10-02 23:00:00-03'
  from ids;

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
select turno_misto, pos_mista_cumprida, '2026-10-02 18:02:00-03', 'geolocalizado', 40, 'verificado', 15000
  from ids;

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
select pos_mista_sobra, vaga_mista, 'aberta',
       '2026-10-02 18:00:00-03', '2026-10-02 23:00:00-03'
  from ids;

-- ── 3. Cenário 3: Vaga futura (não expirada) ──────────────────────────────────
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_futura, estabelecimento, (select id from public.funcao limit 1),
       '2026-10-04 18:00:00-03', '2026-10-04 23:00:00-03',
       'Local DF 3', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada',
       '2026-10-01 12:00:00-03', gen_random_uuid(), contratante_user
  from ids;

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
select pos_futura, vaga_futura, 'aberta',
       '2026-10-04 18:00:00-03', '2026-10-04 23:00:00-03'
  from ids;

-- ── Avança o relógio para depois do fim das vagas 1 e 2 ────────────────────────
select set_config('frila.agora', '2026-10-03 01:00:00-03', true);

-- Executa o job de fechamento
select lives_ok(
  $$ select privado.fechar_turnos_e_vagas() $$,
  'fechar_turnos_e_vagas roda sem erro com vagas expiradas sem processo');

-- ── Verificações do Cenário 1 (vaga sem processo expirada) ─────────────────────
select is(
  (select estado::text from public.vaga where id = (select vaga_sem_processo from ids)),
  'encerrada',
  'vaga sem processo com fim_em no passado deve ser encerrada');

select is(
  (select estado::text from public.posicao where id = (select pos_sem_processo from ids)),
  'cancelada',
  'posição aberta sem processo com fim_em no passado deve ser cancelada');

-- ── Verificações do Cenário 2 (vaga mista) ─────────────────────────────────────
select is(
  (select estado::text from public.vaga where id = (select vaga_mista from ids)),
  'encerrada',
  'vaga com 1 cumprida e 1 sobra aberta deve ser encerrada após o fim');

select is(
  (select estado::text from public.posicao where id = (select pos_mista_cumprida from ids)),
  'cumprida',
  'posição cumprida com presença verificada permanece cumprida');

select is(
  (select estado::text from public.posicao where id = (select pos_mista_sobra from ids)),
  'cancelada',
  'posição que sobrou aberta na vaga mista deve ser cancelada');

-- ── Verificações do Cenário 3 (vaga futura intocada) ───────────────────────────
select is(
  (select estado::text from public.vaga where id = (select vaga_futura from ids)),
  'publicada',
  'vaga futura continua publicada');

select is(
  (select estado::text from public.posicao where id = (select pos_futura from ids)),
  'aberta',
  'posição de vaga futura continua aberta');

-- ── Idempotência ───────────────────────────────────────────────────────────────
select lives_ok(
  $$ select privado.fechar_turnos_e_vagas() $$,
  'segunda execução de fechar_turnos_e_vagas roda limpa');

select is(
  (select estado::text from public.vaga where id = (select vaga_sem_processo from ids)),
  'encerrada',
  'idempotente: vaga sem processo permanece encerrada');

select is(
  (select estado::text from public.posicao where id = (select pos_sem_processo from ids)),
  'cancelada',
  'idempotente: posição sem processo permanece cancelada');

select is(
  (select count(*)::int from public.notificacao n, ids
    where n.referencia_id = ids.vaga_sem_processo),
  0,
  'nenhuma notificação espúria gerada para vaga sem processo');

select * from finish();
rollback;
