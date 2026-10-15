-- 660_ciclo_de_vida_achados.sql
--
-- Cobertura e reprodução dos Achados 1, 2 e 3 da caçada de ciclo de vida:
-- 1. Candidaturas quando vaga de seleção expira (demonstrar se ficam órfãs ou se expiram).
-- 2. Laço de avaliacao_disponivel em fechar_turnos_e_vagas para turnos já notificados.
-- 3. Despacho com notificacao_id null cuja vaga foi cancelada não deve disparar alerta de saúde.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(5);

insert into privado.ambiente (eh_teste) values (true);
select set_config('frila.agora', '2026-10-10 12:00:00-03', true);

create temp table ids as
select
  'c6600000-0000-4000-8000-000000000001'::uuid as prof_user,
  'c6600000-0000-4000-8000-000000000002'::uuid as contratante_user,
  'c6600000-0000-4000-8000-000000000011'::uuid as profissional,
  'c6600000-0000-4000-8000-000000000021'::uuid as estabelecimento,
  -- Achado 1
  'c6600000-0000-4000-8000-000000000031'::uuid as vaga_selecao,
  'c6600000-0000-4000-8000-000000000041'::uuid as pos_selecao,
  'c6600000-0000-4000-8000-000000000051'::uuid as cand_selecao,
  -- Achado 2
  'c6600000-0000-4000-8000-000000000032'::uuid as vaga_passada,
  'c6600000-0000-4000-8000-000000000042'::uuid as pos_passada,
  'c6600000-0000-4000-8000-000000000052'::uuid as turno_passado,
  -- Achado 3
  'c6600000-0000-4000-8000-000000000033'::uuid as vaga_cancelada,
  'c6600000-0000-4000-8000-000000000063'::uuid as despacho_teto;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select prof_user, 'profissional'::public.perfil_conta, 'Profissional Ciclo',
       '+5561999990061', 'prof-ciclo@test.invalid', '1992-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids
union all
select contratante_user, 'contratante'::public.perfil_conta, 'Casa Ciclo',
       '+5561999990062', 'casa-ciclo@test.invalid', '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select profissional, prof_user, 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.profissional_funcao (profissional_id, funcao_id)
select profissional, (select id from public.funcao limit 1)
  from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select estabelecimento, 'Casa Ciclo Vida', '80000000000660', 'food_service',
       'Endereco de teste', 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select contratante_user, estabelecimento, 'administrador'
  from ids;

-- ── 1. Achado 1: Vaga em seleção com fim_em passado ───────────────────────────
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_selecao, estabelecimento, (select id from public.funcao limit 1),
       '2026-10-09 18:00:00-03', '2026-10-09 23:00:00-03',
       'Local DF', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, false, false, false, 'Gerente', 'selecao', 'publicada',
       '2026-10-08 12:00:00-03', gen_random_uuid(), contratante_user
  from ids;

insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em)
select pos_selecao, vaga_selecao, 'aberta',
       '2026-10-09 18:00:00-03', '2026-10-09 23:00:00-03'
  from ids;

insert into public.candidatura (id, posicao_id, profissional_id, estado, criada_em)
select cand_selecao, pos_selecao, profissional, 'pendente', '2026-10-08 13:00:00-03'
  from ids;

-- Executa o fechamento de turnos e vagas expiradas
select privado.fechar_turnos_e_vagas();

select is(
  (select estado from public.vaga where id = (select vaga_selecao from ids)),
  'encerrada'::public.estado_vaga,
  'Achado 1: Vaga expirada recebe estado = encerrada (nao concluida, que sequer existe no enum)'
);

select is(
  (select estado from public.candidatura where id = (select cand_selecao from ids)),
  'expirada'::public.estado_candidatura,
  'Achado 1: Candidatura pendente transiciona para expirada quando a vaga é encerrada'
);

-- ── 2. Achado 2: Laço de avaliação não renotifica turnos já processados ────────
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_passada, estabelecimento, (select id from public.funcao limit 1),
       '2026-10-08 18:00:00-03', '2026-10-08 23:00:00-03',
       'Local DF 2', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, false, false, false, 'Gerente', 'urgencia', 'encerrada',
       '2026-10-07 12:00:00-03', gen_random_uuid(), contratante_user
  from ids;

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select pos_passada, vaga_passada, 'cumprida', profissional, '2026-10-07 14:00:00-03',
       '2026-10-08 18:00:00-03', '2026-10-08 23:00:00-03'
  from ids;

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkout_em, verificacao, valor_acordado_centavos)
select turno_passado, pos_passada,
       '2026-10-08 18:05:00-03', 'geolocalizado'::public.tipo_registro, 50,
       '2026-10-08 23:00:00-03', 'verificado'::public.verificacao_turno, 15000
  from ids;

-- Simula que as notificações de avaliação já foram emitidas anteriormente
insert into public.notificacao (usuario_id, tipo, referencia_id, payload, enviada_em)
select prof_user, 'avaliacao_disponivel'::public.tipo_notificacao, turno_passado,
       jsonb_build_object('turno_id', turno_passado), '2026-10-08 23:05:00-03'::timestamptz
  from ids
union all
select contratante_user, 'avaliacao_disponivel'::public.tipo_notificacao, turno_passado,
       jsonb_build_object('turno_id', turno_passado), '2026-10-08 23:05:00-03'::timestamptz
  from ids;

-- Monitora tentativas de renotificação através de trigger temporário
create temp table tentativas_notif (referencia_id uuid);

create or replace function pg_temp.vigiar_tentativas_notif()
returns trigger
language plpgsql as $$
begin
  if new.tipo = 'avaliacao_disponivel' then
    insert into tentativas_notif values (new.referencia_id);
  end if;
  return new;
end $$;

create trigger trg_vigiar_notif
  before insert on public.notificacao
  for each row
  execute function pg_temp.vigiar_tentativas_notif();

-- Reexecuta o job
select privado.fechar_turnos_e_vagas();

select is(
  (select count(*)::int from tentativas_notif where referencia_id = (select turno_passado from ids)),
  0,
  'Achado 2: Turno verificado já notificado não deve entrar no laço de renotificação de avaliacao_disponivel'
);

-- ── 3. Achado 3: Despacho com teto órfão em vaga cancelada ────────────────────
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
)
select vaga_cancelada, estabelecimento, (select id from public.funcao limit 1),
       '2026-10-10 18:00:00-03', '2026-10-10 23:00:00-03',
       'Local DF 3', 'POINT(-47.8800 -15.7700)'::extensions.geography,
       15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada',
       '2026-10-10 10:00:00-03', gen_random_uuid(), contratante_user
  from ids;

-- Insere despacho esperando teto (notificacao_id null) criado há 50 minutos (além do teto + 15 min)
insert into public.despacho (id, vaga_id, profissional_id, notificacao_id, criado_em, rodada)
select despacho_teto, vaga_cancelada, profissional, null,
       '2026-10-10 11:10:00-03', 1
  from ids;

-- A vaga é cancelada
update public.vaga
   set estado = 'cancelada'
 where id = (select vaga_cancelada from ids);

-- Limpa filas de alerta para teste isolado de verificar_saude
truncate table pgmq.q_email;
truncate table privado.alerta_emitido;

-- Executa verificar_saude
select privado.verificar_saude();

select is(
  (select count(*)::int from pgmq.q_email where message->>'codigo' = 'despacho_esperando_alem_do_teto'),
  0,
  'Achado 3: Despacho retido sob teto de vaga cancelada/inativa não deve emitir alerta despacho_esperando_alem_do_teto'
);

-- Agora testa o caminho positivo do Achado 3: se a vaga AINDA FOR publicada e no futuro, o alerta DEVE ser emitido
update public.vaga
   set estado = 'publicada'
 where id = (select vaga_cancelada from ids);

truncate table pgmq.q_email;
truncate table privado.alerta_emitido;

select privado.verificar_saude();

select is(
  (select count(*)::int from pgmq.q_email where message->>'codigo' = 'despacho_esperando_alem_do_teto'),
  1,
  'Achado 3 (positivo): Despacho retido sob teto de vaga que CONTINUA publicada no futuro emite alerta com sucesso'
);

select * from finish();
rollback;
