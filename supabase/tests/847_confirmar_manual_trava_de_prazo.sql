-- 847_confirmar_manual_trava_de_prazo.sql
--
-- A trava de prazo de public.confirmar_checkin_manual com tolerância tardia de 24 horas
-- (migração 20261112100000_confirmacao_tardia_24h.sql, decisão JP 12/11/2026).
--
-- Regras cobertas:
--   1. Estrutura, search_path e permissões de public.confirmar_checkin_manual(uuid) e
--      privado.prazo_da_confirmacao_tardia().
--   2. Confirmar antes do fim aceita (privado.agora() <= fim_em), e a re-execução já confirmada
--      segue aceita de forma idempotente depois do fim.
--   3. Bordas da tolerância tardia (24 horas após fim_em):
--      - exatamente em fim_em (22:00:00) aceita;
--      - fim_em + 1 min (22:01:00) aceita (tolerância tardia);
--      - fim_em + 24 h (dia seguinte 22:00:00) aceita;
--      - fim_em + 24 h + 1 min (dia seguinte 22:01:00) recusa 422 fora_da_janela;
--      - fim_em + 24 h + 1 hora (dia seguinte 23:00:00) recusa 422 fora_da_janela;
--      - turno recusado por prazo não altera verificação (permanece pendente).
--   4. Turno com verificacao = 'nao_verificado' recusa 422 fora_da_janela, mesmo dentro da janela.
--   5. Integração com privado.fechar_turnos_passados():
--      - no fim do turno (fim + 30 min): check-in manual pendente NÃO fecha, segue pendente,
--        sem aviso turno_nao_verificado, e confirmação manual pela casa é aceita;
--      - após fim + 24 h (fim + 24h30min): o job fecha como nao_verificado e emite o aviso
--        turno_nao_verificado a ambos os lados;
--      - confirmação após fechamento pelo job recusa 422 fora_da_janela.
--   6. Posição cancelada vem antes da trava de prazo: recusa é 409 vaga_encerrada (posicao_cancelada),
--      dentro do horário e após fim + 24 h.
--   7. public.painel_estabelecimento: checkins_pendentes lista turno pendente de ontem (dentro de 24h),
--      mas omite turno fechado como nao_verificado.
--   8. Confirmação tardia libera avaliação (privado.pode_avaliar) para ambos os lados e recalcula
--      o comparecimento do profissional.

begin;

-- Configuração determinística do relógio de teste
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
set local frila.agora = '2030-07-01 12:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste-847';

select plan(42);

-- ── 1. Estrutura, permissões e search_path ───────────────────────────────────

select has_function(
  'public', 'confirmar_checkin_manual',
  array['uuid'],
  'public.confirmar_checkin_manual(uuid) existe'
);

select function_lang_is(
  'public', 'confirmar_checkin_manual',
  array['uuid'],
  'plpgsql',
  'public.confirmar_checkin_manual é em plpgsql'
);

select is(
  (select proconfig from pg_proc where proname = 'confirmar_checkin_manual' and pronamespace = 'public'::regnamespace),
  array['search_path=""'],
  'public.confirmar_checkin_manual possui search_path="" vazio'
);

select is(
  (select prosecdef from pg_proc where proname = 'confirmar_checkin_manual' and pronamespace = 'public'::regnamespace),
  true,
  'public.confirmar_checkin_manual é security definer'
);

select is(
  has_function_privilege('anon', 'public.confirmar_checkin_manual(uuid)', 'execute'),
  false,
  'anon não pode executar confirmar_checkin_manual'
);

select is(
  has_function_privilege('authenticated', 'public.confirmar_checkin_manual(uuid)', 'execute'),
  true,
  'authenticated pode executar confirmar_checkin_manual'
);

select has_function(
  'privado', 'prazo_da_confirmacao_tardia',
  array[]::text[],
  'privado.prazo_da_confirmacao_tardia() existe'
);

select is(
  privado.prazo_da_confirmacao_tardia(),
  interval '24 hours',
  'privado.prazo_da_confirmacao_tardia() retorna interval 24 hours'
);

select is(
  has_function_privilege('anon', 'privado.prazo_da_confirmacao_tardia()', 'execute'),
  false,
  'anon não pode executar prazo_da_confirmacao_tardia'
);

select is(
  has_function_privilege('authenticated', 'privado.prazo_da_confirmacao_tardia()', 'execute'),
  false,
  'authenticated não pode executar prazo_da_confirmacao_tardia'
);

select is(
  has_function_privilege('service_role', 'privado.prazo_da_confirmacao_tardia()', 'execute'),
  true,
  'service_role pode executar prazo_da_confirmacao_tardia'
);

-- ── 2. Massa de dados isolada para testes ─────────────────────────────────────

create temp table ids on commit drop as
select
  'c8470000-0000-4000-8000-000000000001'::uuid as contratante_user,
  'c8470000-0000-4000-8000-000000000002'::uuid as prof_user,
  'c8470000-0000-4000-8000-000000000010'::uuid as estab_id,
  'c8470000-0000-4000-8000-000000000020'::uuid as prof_id;

-- Inserção de contratante e profissional
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select contratante_user, 'contratante', 'Contratante 847', '+5561999998471', 'contratante847@test.invalid', '1980-01-01', '1.0', '2026-09-20' from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
select estab_id, 'Bar 847', '84700000000100', 'food_service', 'CLN 847', 'POINT(-47.8800 -15.7700)', 'Plano Piloto' from ids;

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
select estab_id, contratante_user, 'administrador' from ids;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select prof_user, 'profissional', 'Profissional 847', '+5561999998472', 'prof847@test.invalid', '1995-01-01', '1.0', '2026-09-20' from ids;

insert into public.profissional (id, usuario_id, ponto_base)
select prof_id, prof_user, 'POINT(-47.8800 -15.7700)' from ids;

-- Função auxiliar para criar vaga, posição e turno com check-in manual
create function pg_temp.criar_turno_manual(
  p_dia int,
  p_verificacao public.verificacao_turno default 'pendente'
) returns uuid language plpgsql as $$
declare
  v_inicio timestamptz := ('2030-07-' || lpad(p_dia::text, 2, '0') || ' 18:00:00+00')::timestamptz;
  v_fim    timestamptz := ('2030-07-' || lpad(p_dia::text, 2, '0') || ' 22:00:00+00')::timestamptz;
  v_vaga   uuid := gen_random_uuid();
  v_pos    uuid := gen_random_uuid();
  v_t      uuid := gen_random_uuid();
begin
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por
  ) values (
    v_vaga, (select estab_id from ids), (select id from public.funcao limit 1),
    v_inicio, v_fim, 'Salão 847', 'POINT(-47.8800 -15.7700)',
    15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', '2030-07-01 12:00:00+00', gen_random_uuid(), (select contratante_user from ids)
  );

  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, inicio_em, fim_em)
  values (v_pos, v_vaga, (select prof_id from ids), 'confirmada',
          '2030-07-01 12:00:00+00', v_inicio, v_fim);

  insert into public.turno (id, posicao_id, checkin_em, checkin_distancia_m, checkin_tipo, verificacao, valor_acordado_centavos)
  values (v_t, v_pos, v_inicio + interval '5 minutes', null, 'manual', p_verificacao, 15000);

  return v_t;
end;
$$;

-- Autentica como o contratante do estabelecimento
select set_config(
  'request.jwt.claims',
  json_build_object('sub', 'c8470000-0000-4000-8000-000000000001', 'role', 'authenticated')::text,
  true
);

-- ── 3. Cenário 1: Confirmar antes do fim aceita ───────────────────────────────
-- Turno no dia 1: das 18:00 às 22:00. Relógio em 19:30 (dentro do turno).
set local frila.agora = '2030-07-01 19:30:00+00';
create temp table turno_cenario1 on commit drop as
select pg_temp.criar_turno_manual(1, 'pendente') as id;

select is(
  (select (public.confirmar_checkin_manual((select id from turno_cenario1)))->>'verificacao'),
  'verificado',
  'confirmar antes do fim_em aceita e torna o turno verificado'
);

select is(
  (select checkin_confirmado_em from public.turno where id = (select id from turno_cenario1)),
  '2030-07-01 19:30:00+00'::timestamptz,
  'checkin_confirmado_em recebe exatamente privado.agora()'
);

-- Idempotência: re-execução em turno já confirmado continua aceita mesmo após fim_em (22:30)
set local frila.agora = '2030-07-01 22:30:00+00';
select is(
  (select (public.confirmar_checkin_manual((select id from turno_cenario1)))->>'verificacao'),
  'verificado',
  're-execução de turno já confirmado permanece idempotente mesmo após o fim_em'
);

select is(
  (select checkin_confirmado_em from public.turno where id = (select id from turno_cenario1)),
  '2030-07-01 19:30:00+00'::timestamptz,
  'checkin_confirmado_em original é preservado na re-execução idempotente'
);

-- ── 4. Cenário 2: Bordas da confirmação tardia de 24 horas ───────────────────
-- Turno no dia 2: das 18:00 às 22:00.
-- Borda exata fim_em: às 22:00:00 aceita.
set local frila.agora = '2030-07-02 22:00:00+00';
create temp table turno_borda on commit drop as
select pg_temp.criar_turno_manual(2, 'pendente') as id;

select is(
  (select (public.confirmar_checkin_manual((select id from turno_borda)))->>'verificacao'),
  'verificado',
  'confirmação exatamente no instante fim_em (22:00:00) é aceita'
);

-- Turno no dia 3: das 18:00 às 22:00.
-- fim_em + 1 min (22:01:00): aceita pela confirmação tardia.
set local frila.agora = '2030-07-03 22:01:00+00';
create temp table turno_fim_mais_1min on commit drop as
select pg_temp.criar_turno_manual(3, 'pendente') as id;

select is(
  (select (public.confirmar_checkin_manual((select id from turno_fim_mais_1min)))->>'verificacao'),
  'verificado',
  'confirmação 1 minuto após fim_em (22:01:00) é aceita (tolerância tardia)'
);

-- Turno no dia 4: das 18:00 às 22:00 (fim_em: 2030-07-04 22:00:00).
-- Limite exato de 24 horas: 2030-07-05 22:00:00. Aceita.
set local frila.agora = '2030-07-05 22:00:00+00';
create temp table turno_limite_24h on commit drop as
select pg_temp.criar_turno_manual(4, 'pendente') as id;

select is(
  (select (public.confirmar_checkin_manual((select id from turno_limite_24h)))->>'verificacao'),
  'verificado',
  'confirmação exatamente no limite de 24h pós-fim (dia seguinte 22:00:00) é aceita'
);

-- Turno no dia 5: das 18:00 às 22:00 (fim_em: 2030-07-05 22:00:00).
-- Relógio em 2030-07-06 22:01:00 (fim_em + 24h + 1min). Recusa 422 fora_da_janela.
set local frila.agora = '2030-07-06 22:01:00+00';
create temp table turno_expirado_24h on commit drop as
select pg_temp.criar_turno_manual(5, 'pendente') as id;

select throws_ok(
  format($$ select public.confirmar_checkin_manual(%L::uuid) $$, (select id from turno_expirado_24h)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'confirmar 1 minuto após fim_em + 24h (22:01:00) recusa 422 fora_da_janela'
);

-- Relógio em 2030-07-06 23:00:00 (fim_em + 25h). Recusa 422 fora_da_janela.
set local frila.agora = '2030-07-06 23:00:00+00';
select throws_ok(
  format($$ select public.confirmar_checkin_manual(%L::uuid) $$, (select id from turno_expirado_24h)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'confirmar 1 hora após fim_em + 24h (23:00:00) recusa 422 fora_da_janela'
);

select is(
  (select verificacao from public.turno where id = (select id from turno_expirado_24h)),
  'pendente',
  'turno recusado após fim+24h não teve verificação alterada (permanece pendente)'
);

-- ── 5. Cenário 3: Confirmar turno com verificacao = 'nao_verificado' recusa ────
-- Turno no dia 6: com verificacao prévia 'nao_verificado', mesmo dentro das 24h.
set local frila.agora = '2030-07-06 20:00:00+00';
create temp table turno_nao_verificado on commit drop as
select pg_temp.criar_turno_manual(6, 'nao_verificado') as id;

select throws_ok(
  format($$ select public.confirmar_checkin_manual(%L::uuid) $$, (select id from turno_nao_verificado)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'confirmar turno já marcado como nao_verificado recusa 422 fora_da_janela'
);

select is(
  (select verificacao from public.turno where id = (select id from turno_nao_verificado)),
  'nao_verificado',
  'verificação permanece nao_verificado após a recusa'
);

-- ── 6. Cenário 4: Integração com privado.fechar_turnos_passados() ──────────────
-- Turno no dia 7: das 18:00 às 22:00, inicialmente pendente.
-- Relógio avança para 22:30 (fim + 30 min): DENTRO da tolerância de 24h.
set local frila.agora = '2030-07-07 22:30:00+00';
create temp table turno_job_dentro_prazo on commit drop as
select pg_temp.criar_turno_manual(7, 'pendente') as id;

-- O job fechar_turnos_passados roda no fim do turno (fim + 30m).
-- O turno manual pendente NÃO deve ser fechado como nao_verificado.
select privado.fechar_turnos_passados();

select is(
  (select verificacao from public.turno where id = (select id from turno_job_dentro_prazo)),
  'pendente',
  'no fim do turno (fim + 30 min), check-in manual pendente NÃO vira nao_verificado (tolerância tardia 24h)'
);

select is(
  (select count(*) from public.notificacao
    where tipo = 'turno_nao_verificado'
      and referencia_id = (select id from turno_job_dentro_prazo)),
  0::bigint,
  'nenhuma notificação turno_nao_verificado emitida enquanto o turno está na tolerância de 24h'
);

-- A casa confirma o turno pendente às 22:30 (fim + 30 min): DEVE ACEITAR com sucesso!
select is(
  (select (public.confirmar_checkin_manual((select id from turno_job_dentro_prazo)))->>'verificacao'),
  'verificado',
  'casa confirma com sucesso turno pendente em fim + 30 min (vira verificado)'
);

-- Turno no dia 8: das 18:00 às 22:00 (fim: 2030-07-08 22:00:00).
-- Relógio avança para 2030-07-09 22:30:00 (fim + 24h30min): FORA da tolerância de 24h.
create temp table turno_job_expirado on commit drop as
select pg_temp.criar_turno_manual(8, 'pendente') as id;

set local frila.agora = '2030-07-09 22:30:00+00';

-- O job de fechamento roda e fecha o turno expirado após 24h
select privado.fechar_turnos_passados();

select is(
  (select verificacao from public.turno where id = (select id from turno_job_expirado)),
  'nao_verificado',
  'job fechar_turnos_passados marcou o turno como nao_verificado após fim + 24h'
);

select is(
  (select count(*) from public.notificacao
    where tipo = 'turno_nao_verificado'
      and referencia_id = (select id from turno_job_expirado)
      and usuario_id = (select prof_user from ids)),
  1::bigint,
  'notificação turno_nao_verificado emitida para o profissional após fim + 24h'
);

select is(
  (select count(*) from public.notificacao
    where tipo = 'turno_nao_verificado'
      and referencia_id = (select id from turno_job_expirado)
      and usuario_id = (select contratante_user from ids)),
  1::bigint,
  'notificação turno_nao_verificado emitida para o contratante após fim + 24h'
);

-- A casa tenta confirmar o turno que o job acabou de fechar: DEVE RECUSAR com 422 fora_da_janela
select throws_ok(
  format($$ select public.confirmar_checkin_manual(%L::uuid) $$, (select id from turno_job_expirado)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'após fechamento pelo job, confirmar_checkin_manual é barrado com 422 fora_da_janela'
);

-- ── 7. Cenário 5: Posição cancelada vem antes da trava de prazo ────────────────
-- Turno no dia 9: das 18:00 às 22:00, check-in manual às 18:05. O profissional desiste às 19:00.
set local frila.agora = '2030-07-09 19:00:00+00';
create temp table turno_cancelado on commit drop as
select pg_temp.criar_turno_manual(9, 'pendente') as id;

select set_config('request.jwt.claims',
  json_build_object('sub', 'c8470000-0000-4000-8000-000000000002', 'role', 'authenticated')::text, true);
select public.cancelar_posicao(
  (select posicao_id from public.turno where id = (select id from turno_cancelado)), 'imprevisto de família');
select set_config('request.jwt.claims',
  json_build_object('sub', 'c8470000-0000-4000-8000-000000000001', 'role', 'authenticated')::text, true);

select is(
  (select p.estado::text || '/' || tu.verificacao::text
     from public.turno tu join public.posicao p on p.id = tu.posicao_id
    where tu.id = (select id from turno_cancelado)),
  'cancelada/nao_verificado',
  'pré-condição: a posição foi cancelada depois do check-in manual, e o turno saiu nao_verificado');

select throws_ok(
  format($$ select public.confirmar_checkin_manual(%L::uuid) $$, (select id from turno_cancelado)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : "posicao_cancelada", "hint" : null}',
  'posição cancelada, dentro do horário: 409 vaga_encerrada (posicao_cancelada), e não 422 fora_da_janela');

-- Depois de fim + 24h, a posição cancelada continua respondendo 409: ela vem antes da trava de prazo.
set local frila.agora = '2030-07-11 00:00:00+00';
select throws_ok(
  format($$ select public.confirmar_checkin_manual(%L::uuid) $$, (select id from turno_cancelado)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : "posicao_cancelada", "hint" : null}',
  'posição cancelada, depois de fim + 24h: segue 409 vaga_encerrada, antes da trava de prazo');

-- ── 8. Cenário 6: public.painel_estabelecimento e checkins_pendentes ───────────
-- Turno no dia 10: das 18:00 às 22:00 (fim: 2030-07-10 22:00:00).
-- Relógio no dia 11 às 10:00 (2030-07-11 10:00:00, 12h após fim_em: dentro de 24h).
set local frila.agora = '2030-07-11 10:00:00+00';
create temp table turno_painel_pendente on commit drop as
select pg_temp.criar_turno_manual(10, 'pendente') as id;

select ok(
  (select (public.painel_estabelecimento(
            (select estab_id from ids),
            '2030-07-10 00:00:00+00'::timestamptz,
            '2030-07-12 00:00:00+00'::timestamptz
          )->'checkins_pendentes') ? ((select id from turno_painel_pendente)::text)),
  'painel: turno pendente de ontem (dentro de 24h) aparece em checkins_pendentes'
);

-- O turno expirado após 24h fechado como nao_verificado (turno_job_expirado) NÃO deve aparecer no painel.
select ok(
  not (select (public.painel_estabelecimento(
                (select estab_id from ids),
                '2030-07-07 00:00:00+00'::timestamptz,
                '2030-07-10 00:00:00+00'::timestamptz
              )->'checkins_pendentes') ? ((select id from turno_job_expirado)::text)),
  'painel: turno fechado como nao_verificado (após 24h) NÃO aparece em checkins_pendentes'
);

-- ── 9. Cenário 7: Confirmação tardia libera avaliação e recalcula comparecimento
-- Turno no dia 12: das 18:00 às 22:00 (fim: 2030-07-12 22:00:00).
-- Relógio no dia 13 às 14:00 (16h após o fim, dentro das 24h).
create temp table turno_tardia_aval on commit drop as
select pg_temp.criar_turno_manual(12, 'pendente') as id;

set local frila.agora = '2030-07-13 14:00:00+00';

-- Antes da confirmação: mesmo com fim_em já passado, o turno está pendente, logo pode_avaliar é false.
select is(
  privado.pode_avaliar((select id from turno_tardia_aval), (select contratante_user from ids)),
  false,
  'antes da confirmação tardia, contratante não pode avaliar turno pendente (pode_avaliar = false)'
);

select is(
  privado.pode_avaliar((select id from turno_tardia_aval), (select prof_user from ids)),
  false,
  'antes da confirmação tardia, profissional não pode avaliar turno pendente (pode_avaliar = false)'
);

select is(
  (select turnos_realizados from public.profissional where id = (select prof_id from ids)),
  5,
  'antes da confirmação tardia, profissional possui 5 turnos_realizados'
);

-- Casa realiza confirmação tardia às 14:00 do dia seguinte.
select is(
  (select (public.confirmar_checkin_manual((select id from turno_tardia_aval)))->>'verificacao'),
  'verificado',
  'confirmação tardia no dia seguinte às 14:00 é aceita com sucesso (verificado)'
);

-- Após a confirmação tardia: pode_avaliar é liberado para contratante e profissional!
select is(
  privado.pode_avaliar((select id from turno_tardia_aval), (select contratante_user from ids)),
  true,
  'após confirmação tardia, contratante pode avaliar (pode_avaliar = true)'
);

select is(
  privado.pode_avaliar((select id from turno_tardia_aval), (select prof_user from ids)),
  true,
  'após confirmação tardia, profissional pode avaliar (pode_avaliar = true)'
);

select is(
  (select turnos_realizados from public.profissional where id = (select prof_id from ids)),
  6,
  'após confirmação tardia, comparecimento é recalculado e turnos_realizados sobe para 6'
);

select * from finish();

rollback;
