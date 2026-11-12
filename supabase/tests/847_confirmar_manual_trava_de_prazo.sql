-- 847_confirmar_manual_trava_de_prazo.sql
--
-- A trava de prazo de public.confirmar_checkin_manual, como a 20261111202000 (PR7 do B-CHECKIN-BACK) a
-- redefine: o corpo é o da confirmar_manual_so_ate_o_fim.sql do frila-backend #477 (do JP, head
-- 9074326), mais o `for update` do turno.
-- Os casos são os do 846 do #477, com dados próprios (c847...), para que a trava continue provada
-- qualquer que seja a ordem das mesclas, e mesmo que só um dos dois PRs entre.
--
--   1. Estrutura, search_path e permissões de public.confirmar_checkin_manual(uuid).
--   2. Confirmar antes do fim aceita (privado.agora() <= fim_em), e a re-execução já confirmada segue aceita depois do fim.
--   3. Borda: exatamente em fim_em aceita; em fim_em + 1 s e + 1 h recusa 422 fora_da_janela, sem mudar a verificação.
--   4. Turno com verificacao = nao_verificado recusa 422 fora_da_janela, mesmo dentro do horário.
--   5. Com privado.fechar_turnos_passados(): o job marca nao_verificado e a confirmação depois dele recusa 422.
--   6. Posição cancelada depois do check-in manual (o caminho do 480, RN22): a recusa é 409 vaga_encerrada,
--      posicao_cancelada, dentro do horário e depois do fim. Ela vem antes da trava de prazo, que diria 422.

begin;

-- Configuração determinística do relógio de teste
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
set local frila.agora = '2030-07-01 12:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste-847';

select plan(22);

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
  v_inicio timestamptz := ('2030-07-0' || p_dia || ' 18:00:00+00')::timestamptz;
  v_fim    timestamptz := ('2030-07-0' || p_dia || ' 22:00:00+00')::timestamptz;
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

-- ── 4. Cenário 2: Borda e confirmação depois do fim recusa ────────────────────
-- Turno no dia 2: das 18:00 às 22:00.

-- Borda exata: às 22:00:00 (exatamente fim_em) ainda não é > fim_em, então é aceito
set local frila.agora = '2030-07-02 22:00:00+00';
create temp table turno_borda on commit drop as
select pg_temp.criar_turno_manual(2, 'pendente') as id;

select is(
  (select (public.confirmar_checkin_manual((select id from turno_borda)))->>'verificacao'),
  'verificado',
  'confirmação exatamente no instante fim_em (22:00:00) é aceita'
);

-- Turno no dia 3: das 18:00 às 22:00.
-- Relógio em 22:00:01 (1 segundo após fim_em). Recusa 422 fora_da_janela.
set local frila.agora = '2030-07-03 22:00:01+00';
create temp table turno_depois_do_fim on commit drop as
select pg_temp.criar_turno_manual(3, 'pendente') as id;

select throws_ok(
  format($$ select public.confirmar_checkin_manual(%L::uuid) $$, (select id from turno_depois_do_fim)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'confirmar 1 segundo após fim_em (22:00:01) recusa 422 fora_da_janela'
);

-- Relógio em 23:00 (1 hora após fim_em). Recusa 422 fora_da_janela.
set local frila.agora = '2030-07-03 23:00:00+00';
select throws_ok(
  format($$ select public.confirmar_checkin_manual(%L::uuid) $$, (select id from turno_depois_do_fim)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'confirmar 1 hora após fim_em (23:00:00) recusa 422 fora_da_janela'
);

select is(
  (select verificacao from public.turno where id = (select id from turno_depois_do_fim)),
  'pendente',
  'turno recusado após fim_em não teve verificação alterada (permanece pendente)'
);

-- ── 5. Cenário 3: Confirmar turno com verificacao = 'nao_verificado' recusa ────
-- Turno no dia 4: com verificacao prévia 'nao_verificado', mesmo antes do fim (ex.: 20:00 de 22:00)
set local frila.agora = '2030-07-04 20:00:00+00';
create temp table turno_nao_verificado on commit drop as
select pg_temp.criar_turno_manual(4, 'nao_verificado') as id;

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
-- Turno no dia 5: das 18:00 às 22:00, inicialmente pendente.
-- Relógio avança para 22:30 (passou do fim).
set local frila.agora = '2030-07-05 22:30:00+00';
create temp table turno_fechamento on commit drop as
select pg_temp.criar_turno_manual(5, 'pendente') as id;

-- O job de fechamento roda e fecha turnos passados não confirmados
select isnt(
  (select privado.fechar_turnos_passados()),
  0,
  'privado.fechar_turnos_passados() executou e processou turnos'
);

select is(
  (select verificacao from public.turno where id = (select id from turno_fechamento)),
  'nao_verificado',
  'job fechar_turnos_passados marcou o turno como nao_verificado'
);

-- A casa tenta confirmar o turno que o job acabou de fechar: DEVE RECUSAR com 422 fora_da_janela
select throws_ok(
  format($$ select public.confirmar_checkin_manual(%L::uuid) $$, (select id from turno_fechamento)),
  'PGRST',
  '{"code" : "fora_da_janela", "message" : "fora_da_janela", "details" : null, "hint" : null}',
  'após fechamento pelo job, confirmar_checkin_manual é barrado com 422 fora_da_janela'
);

-- ── 7. Cenário 5: Posição cancelada vem antes da trava de prazo ────────────────
-- Turno no dia 6: das 18:00 às 22:00, check-in manual às 18:05. O profissional desiste às 19:00.
set local frila.agora = '2030-07-06 19:00:00+00';
create temp table turno_cancelado on commit drop as
select pg_temp.criar_turno_manual(6, 'pendente') as id;

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

-- Depois do fim, a posição cancelada continua respondendo 409: ela vem antes da trava de prazo.
set local frila.agora = '2030-07-06 23:00:00+00';
select throws_ok(
  format($$ select public.confirmar_checkin_manual(%L::uuid) $$, (select id from turno_cancelado)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : "posicao_cancelada", "hint" : null}',
  'posição cancelada, depois do fim: segue 409 vaga_encerrada, antes da trava de prazo');

select * from finish();

rollback;
