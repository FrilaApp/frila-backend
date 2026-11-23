-- Teste pgTAP: supabase/tests/840_reputacao_base_historica_expurgo_r9.sql
-- Escopo: Reputação guarda a base histórica do que o expurgo de 5 anos apaga (R9, Modelagem A11, cartão 8KFuT8UP).
--
-- Provas:
--   1. Schema estrito: tabela privado.profissional_reputacao_expurgada contém exclusivamente
--      profissional_id e contadores agregados (sem id de turno, vaga, casa/estabelecimento nem datas).
--   2. Permissões estritas: anônimo e autenticado não acessam a tabela de base histórica.
--   3. Cenário completo: profissional com 10 turnos, 2 faltas e 8 avaliações, onde 3 turnos
--      e 1 falta têm mais de 5 anos:
--      - Antes do expurgo: contadores aferidos em profissional e perfil público.
--      - Após expurgo (executar_retencao_diaria): dados antigos são removidos das tabelas vivas
--        e acumulados na tabela privado.profissional_reputacao_expurgada.
--      - Após reconciliação diária (privado.reconciliar_comparecimento): turnos_realizados,
--        taxa_comparecimento, aval_positivas, aval_total e turnos_considerados no perfil público
--        permanecem exatamente os mesmos de antes do expurgo (zero divergências).
--   4. Recálculo pontual (privado.recalcular_comparecimento) também preserva os contadores expurgados.
--   5. Integridade referencial: exclusão do profissional cascateia para a base histórica expurgada.
--   6. Integridade de dados: 6 restrições CHECK da tabela protegidas contra mutação.

begin;

insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2026-11-09 12:00:00+00', true);
set local timezone = 'UTC';

select plan(34);

-- ── 1. Schema e permissões da base histórica expurgada ─────────────────────────

select has_table('privado', 'profissional_reputacao_expurgada',
  'tabela privado.profissional_reputacao_expurgada existe');

-- Validação estrita do schema: NÃO EXISTE id de turno, vaga, casa nem data do turno
select columns_are('privado', 'profissional_reputacao_expurgada',
  array['profissional_id', 'turnos_realizados', 'presencas', 'faltas', 'aval_positivas', 'aval_total'],
  'schema estrito: colunas da base histórica contêm exclusivamente o id do profissional e contadores agregados'
);

select col_type_is('privado', 'profissional_reputacao_expurgada', 'profissional_id', 'uuid',
  'profissional_id é uuid');
select col_type_is('privado', 'profissional_reputacao_expurgada', 'turnos_realizados', 'integer',
  'turnos_realizados é integer');
select col_type_is('privado', 'profissional_reputacao_expurgada', 'presencas', 'integer',
  'presencas é integer');
select col_type_is('privado', 'profissional_reputacao_expurgada', 'faltas', 'integer',
  'faltas é integer');
select col_type_is('privado', 'profissional_reputacao_expurgada', 'aval_positivas', 'integer',
  'aval_positivas é integer');
select col_type_is('privado', 'profissional_reputacao_expurgada', 'aval_total', 'integer',
  'aval_total é integer');

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'privado'
      and table_name = 'profissional_reputacao_expurgada'
      and column_name in ('turno_id', 'vaga_id', 'estabelecimento_id', 'casa_id', 'data',
                          'data_turno', 'criado_em', 'atualizado_em', 'inicio_em', 'fim_em')),
  0,
  'schema estrito: garantido que não existe coluna de turno, vaga, casa/estabelecimento nem datas'
);

select is(
  (select count(*)::int from information_schema.table_privileges
    where table_schema = 'privado'
      and table_name = 'profissional_reputacao_expurgada'
      and grantee in ('anon', 'authenticated')),
  0,
  'permissões: anon e authenticated não possuem nenhum privilégio na tabela de base histórica'
);

select ok(
  (select count(*)::int from information_schema.table_privileges
    where table_schema = 'privado'
      and table_name = 'profissional_reputacao_expurgada'
      and grantee = 'service_role') > 0,
  'permissões: service_role possui acesso à tabela'
);

-- ── 2. Cenário: 10 turnos, 2 faltas e 8 avaliações (3 turnos > 5 anos) ────────

create temp table ids (chave text primary key, id uuid not null);
grant select on ids to authenticated;

do $$
declare
  a         timestamptz := privado.agora();
  v_c_user  uuid := gen_random_uuid();
  v_p_user  uuid := gen_random_uuid();
  v_p_id    uuid;
  v_e_id    uuid;
  v_funcao  uuid := (select id from public.funcao order by id limit 1);
  v_vaga_antiga uuid;
  v_vaga_recente uuid;
  v_pos_id  uuid;
  v_turno_id uuid;
  i         int;
  v_fim_antigo timestamptz := a - interval '5 years' - interval '10 days';
  v_fim_recente timestamptz := a - interval '10 days';
begin
  -- Contratante e profissional
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_c_user, 'contratante', 'Contratante 840', '+5561999984001', 'c_840@teste.com', '1985-01-01', '0.2.68', a),
         (v_p_user, 'profissional', 'Profissional 840', '+5561999984002', 'p_840@teste.com', '1990-01-01', '0.2.68', a);

  insert into public.profissional (usuario_id, perfil, ponto_base)
  values (v_p_user, 'profissional', 'POINT(-47.88 -15.77)'::extensions.geography)
  returning id into v_p_id;

  insert into public.estabelecimento (nome, documento, tipo, endereco, regiao_administrativa, ponto)
  values ('Casa 840', '84084084000184', 'food_service', 'Endereço 840', 'Plano Piloto',
          'POINT(-47.88 -15.77)'::extensions.geography)
  returning id into v_e_id;

  insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
  values (v_e_id, v_c_user, 'administrador');

  insert into ids values ('c_user', v_c_user), ('p_user', v_p_user), ('prof', v_p_id), ('est', v_e_id);

  -- Vaga antiga (> 5 anos)
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
    responsavel_local, traje, observacoes, modo, estado, chave_cliente, publicado_por)
  values (v_e_id, v_funcao, v_fim_antigo - interval '6 hours', v_fim_antigo, 'Casa Antiga 840',
    'POINT(-47.9100 -15.8300)'::extensions.geography, 15000, 4, false, false, false,
    'Gerente Antigo', 'Preto', 'Observacao Antiga', 'urgencia', 'encerrada', gen_random_uuid(), v_c_user)
  returning id into v_vaga_antiga;
  insert into ids values ('vaga_antiga', v_vaga_antiga);

  -- 3 turnos antigos verificados + 2 avaliações positivas
  for i in 1..3 loop
    insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em)
    values (v_vaga_antiga, v_p_id,
            v_fim_antigo - (i || ' days')::interval - interval '6 hours',
            v_fim_antigo - (i || ' days')::interval,
            'cumprida', v_fim_antigo - (i || ' days')::interval - interval '2 days')
    returning id into v_pos_id;

    insert into public.turno (posicao_id, valor_acordado_centavos, checkin_em, checkin_tipo, checkin_distancia_m, verificacao)
    values (v_pos_id, 15000, v_fim_antigo - (i || ' days')::interval - interval '6 hours', 'geolocalizado', 30, 'verificado')
    returning id into v_turno_id;

    -- Avaliações nos primeiros 2 turnos antigos (ambas positivas)
    if i <= 2 then
      insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
      values (v_turno_id, v_c_user, 'profissional', v_p_id, true);
    end if;
  end loop;

  -- 1 falta antiga (posição com falta e turno sem check-in)
  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em, falta)
  values (v_vaga_antiga, v_p_id,
          v_fim_antigo - interval '4 days' - interval '6 hours',
          v_fim_antigo - interval '4 days',
          'cancelada', v_fim_antigo - interval '5 days', true)
  returning id into v_pos_id;

  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos_id, 15000);

  -- Vaga recente (< 5 anos, ex: 10 dias)
  insert into public.vaga (estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
    responsavel_local, traje, observacoes, modo, estado, chave_cliente, publicado_por)
  values (v_e_id, v_funcao, v_fim_recente - interval '15 days', v_fim_recente, 'Casa Recente 840',
    'POINT(-47.9100 -15.8300)'::extensions.geography, 15000, 8, false, false, false,
    'Gerente Recente', 'Preto', 'Observacao Recente', 'urgencia', 'encerrada', gen_random_uuid(), v_c_user)
  returning id into v_vaga_recente;
  insert into ids values ('vaga_recente', v_vaga_recente);

  -- 7 turnos recentes verificados + 6 avaliações (5 positivas e 1 negativa)
  for i in 1..7 loop
    insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em)
    values (v_vaga_recente, v_p_id,
            v_fim_recente - (i || ' days')::interval - interval '6 hours',
            v_fim_recente - (i || ' days')::interval,
            'cumprida', v_fim_recente - (i || ' days')::interval - interval '2 days')
    returning id into v_pos_id;

    insert into public.turno (posicao_id, valor_acordado_centavos, checkin_em, checkin_tipo, checkin_distancia_m, verificacao)
    values (v_pos_id, 15000, v_fim_recente - (i || ' days')::interval - interval '6 hours', 'geolocalizado', 30, 'verificado')
    returning id into v_turno_id;

    -- Avaliações em 6 dos 7 turnos: turnos 1..5 positivos, turno 6 negativo
    if i <= 5 then
      insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
      values (v_turno_id, v_c_user, 'profissional', v_p_id, true);
    elsif i = 6 then
      insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
      values (v_turno_id, v_c_user, 'profissional', v_p_id, false);
    end if;
  end loop;

  -- 1 falta recente
  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em, falta)
  values (v_vaga_recente, v_p_id,
          v_fim_recente - interval '8 days' - interval '6 hours',
          v_fim_recente - interval '8 days',
          'cancelada', v_fim_recente - interval '9 days', true)
  returning id into v_pos_id;

  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos_id, 15000);
end $$;

-- Reconciliação inicial para alinhar os contadores canônicos no cache antes do expurgo
do $$ begin perform privado.reconciliar_comparecimento(); end $$;

-- Guarda retrato antes do expurgo
create temp table reputacao_antes as
select id, turnos_realizados, taxa_comparecimento, aval_positivas, aval_total
  from public.profissional
 where id = (select id from ids where chave = 'prof');

create temp table perfil_antes as
select privado.perfil_publico_profissional((select id from ids where chave = 'prof')) as perfil;

-- Verificações dos números esperados antes do expurgo:
-- 10 turnos verificados, 2 faltas (taxa 10/12 = 0.833), 7 avaliações positivas, 8 total
select results_eq(
  $$ select turnos_realizados, taxa_comparecimento, aval_positivas, aval_total from reputacao_antes $$,
  $$ values (10, 0.833::numeric(4,3), 7, 8) $$,
  'antes do expurgo: 10 turnos realizados, 2 faltas (taxa 0.833), 7 avaliações positivas e 8 no total'
);

select results_eq(
  $$ select (perfil->'reputacao'->>'turnos_realizados')::int,
            (perfil->'reputacao'->>'turnos_considerados')::int,
            (perfil->'reputacao'->>'taxa_comparecimento')::numeric(4,3),
            (perfil->'reputacao'->>'positivas')::int,
            (perfil->'reputacao'->>'total')::int
       from perfil_antes $$,
  $$ values (10, 12, 0.833::numeric(4,3), 7, 8) $$,
  'antes do expurgo: perfil público reflete turnos_considerados = 12 (10 turnos + 2 faltas)'
);

-- ── 3. Execução do expurgo de 5 anos ───────────────────────────────────────────

create temp table r_exec as
select privado.executar_retencao_diaria() as res;

-- Prova que os turnos e posições antigos foram removidos do histórico vivo
select is(
  (select count(*)::int from public.turno t
     join public.posicao p on p.id = t.posicao_id
    where p.vaga_id = (select id from ids where chave = 'vaga_antiga')),
  0,
  'após expurgo: os 4 turnos antigos (3 cumpridos + 1 falta) foram apagados das tabelas vivas'
);

select is(
  (select count(*)::int from public.posicao p
    where p.vaga_id = (select id from ids where chave = 'vaga_antiga')),
  0,
  'após expurgo: as 4 posições antigas foram apagadas'
);

-- Prova que os turnos recentes continuam vivos
select is(
  (select count(*)::int from public.turno t
     join public.posicao p on p.id = t.posicao_id
    where p.vaga_id = (select id from ids where chave = 'vaga_recente')
      and t.verificacao = 'verificado'),
  7,
  'após expurgo: os 7 turnos verificados recentes continuam vivos'
);

-- Prova de acumulação na tabela privado.profissional_reputacao_expurgada
select results_eq(
  $$ select turnos_realizados, presencas, faltas, aval_positivas, aval_total
       from privado.profissional_reputacao_expurgada
      where profissional_id = (select id from ids where chave = 'prof') $$,
  $$ values (3, 3, 1, 2, 2) $$,
  'após expurgo: base histórica acumulou exatamente 3 turnos, 3 presenças, 1 falta e 2 avaliações positivas'
);

-- R9: imediatamente após o expurgo, o cache em profissional não mudou
select results_eq(
  $$ select turnos_realizados, taxa_comparecimento, aval_positivas, aval_total
       from public.profissional
      where id = (select id from ids where chave = 'prof') $$,
  $$ select turnos_realizados, taxa_comparecimento, aval_positivas, aval_total from reputacao_antes $$,
  'R9: após expurgo, contadores em public.profissional permanecem idênticos'
);

-- ── 4. Reconciliação diária preserva os contadores canônicos ──────────────────

-- Executa a reconciliação diária que antes zerava/baixava os contadores
select is(
  privado.reconciliar_comparecimento(),
  0,
  'reconciliação diária: zero divergências encontradas (histórico vivo + base expurgada somam a mesma reputação)'
);

select is(
  (select count(*)::int from privado.divergencia_reputacao
    where profissional_id = (select id from ids where chave = 'prof')),
  0,
  'nenhuma divergência registrada para o profissional após reconciliação'
);

-- Prova central: contadores em profissional iguais antes e depois
select results_eq(
  $$ select turnos_realizados, taxa_comparecimento, aval_positivas, aval_total
       from public.profissional
      where id = (select id from ids where chave = 'prof') $$,
  $$ select turnos_realizados, taxa_comparecimento, aval_positivas, aval_total from reputacao_antes $$,
  'prova central: turnos_realizados, taxa_comparecimento, aval_positivas e aval_total são os mesmos após reconciliação'
);

-- Prova do perfil público (privado.perfil_publico_profissional e public.perfil_publico)
select results_eq(
  $$ select (perfil->'reputacao'->>'turnos_realizados')::int,
            (perfil->'reputacao'->>'turnos_considerados')::int,
            (perfil->'reputacao'->>'taxa_comparecimento')::numeric(4,3),
            (perfil->'reputacao'->>'positivas')::int,
            (perfil->'reputacao'->>'total')::int
       from (select privado.perfil_publico_profissional((select id from ids where chave = 'prof')) as perfil) _ $$,
  $$ values (10, 12, 0.833::numeric(4,3), 7, 8) $$,
  'perfil público após expurgo e reconciliação: turnos_considerados = 12 (10 turnos + 1 falta viva + 1 falta expurgada)'
);

-- Prova via RPC autenticada public.perfil_publico
select set_config('role', 'authenticated', true);
select set_config('request.jwt.claims', json_build_object('sub', (select id::text from ids where chave = 'c_user'))::text, true);

select results_eq(
  $$ select (perfil->'reputacao'->>'turnos_realizados')::int,
            (perfil->'reputacao'->>'turnos_considerados')::int,
            (perfil->'reputacao'->>'taxa_comparecimento')::numeric(4,3),
            (perfil->'reputacao'->>'positivas')::int,
            (perfil->'reputacao'->>'total')::int
       from (select public.perfil_publico((select id from ids where chave = 'prof')) as perfil) _ $$,
  $$ values (10, 12, 0.833::numeric(4,3), 7, 8) $$,
  'RPC public.perfil_publico entrega exatamente a mesma reputação completa'
);

-- Restaura role para continuar testes administrativos
select set_config('role', 'postgres', true);

-- ── 5. Recálculo pontual (privado.recalcular_comparecimento) ───────────────────

-- Zera temporariamente o cache para forçar recalcular_comparecimento a reconstruir
update public.profissional
   set turnos_realizados = 0, taxa_comparecimento = null
 where id = (select id from ids where chave = 'prof');

select privado.recalcular_comparecimento((select id from ids where chave = 'prof'));

select results_eq(
  $$ select turnos_realizados, taxa_comparecimento
       from public.profissional
      where id = (select id from ids where chave = 'prof') $$,
  $$ select turnos_realizados, taxa_comparecimento from reputacao_antes $$,
  'recalcular_comparecimento reconstrói turnos_realizados (10) e taxa_comparecimento (0.833) somando vivo + expurgado'
);

-- ── 6. Idempotência do expurgo (segunda rodada não duplica contadores) ─────────

select is(
  privado.expurgar_turnos_antigos(),
  0,
  'segunda execução de expurgar_turnos_antigos: 0 turnos expurgados'
);

select results_eq(
  $$ select turnos_realizados, presencas, faltas, aval_positivas, aval_total
       from privado.profissional_reputacao_expurgada
      where profissional_id = (select id from ids where chave = 'prof') $$,
  $$ values (3, 3, 1, 2, 2) $$,
  'idempotência: base histórica expurgada não sofre incremento espúrio na segunda rodada'
);

-- ── 7. Integridade referencial: exclusão do profissional cascateia ────────────

do $$
declare
  v_u uuid := gen_random_uuid();
  v_p uuid;
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_u, 'profissional', 'Dummy 840', '+5561999984099', 'dummy@teste.com', '1990-01-01', '0.2.68', privado.agora());
  insert into public.profissional (usuario_id, perfil, ponto_base)
  values (v_u, 'profissional', 'POINT(-47.88 -15.77)'::extensions.geography)
  returning id into v_p;
  insert into ids values ('dummy_prof', v_p);
  insert into privado.profissional_reputacao_expurgada (profissional_id, turnos_realizados, presencas, faltas, aval_positivas, aval_total)
  values (v_p, 5, 5, 1, 4, 4);
end $$;

delete from public.profissional
 where id = (select id from ids where chave = 'dummy_prof');

select is(
  (select count(*)::int from privado.profissional_reputacao_expurgada
    where profissional_id = (select id from ids where chave = 'dummy_prof')),
  0,
  'deleção de profissional cascateia para privado.profissional_reputacao_expurgada (ON DELETE CASCADE)'
);

-- ── 8. Restrições CHECK da tabela privado.profissional_reputacao_expurgada (mutação) ──

do $$
declare
  v_u uuid := gen_random_uuid();
  v_p uuid;
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_u, 'profissional', 'Check 840', '+5561999984095', 'check840@teste.com', '1990-01-01', '0.2.68', privado.agora());
  insert into public.profissional (usuario_id, perfil, ponto_base)
  values (v_u, 'profissional', 'POINT(-47.88 -15.77)'::extensions.geography)
  returning id into v_p;
  insert into ids values ('prof_check', v_p);
end $$;

select throws_ok(
  $$ insert into privado.profissional_reputacao_expurgada (profissional_id, turnos_realizados, presencas, faltas, aval_positivas, aval_total)
     values ((select id from ids where chave = 'prof_check'), -1, 0, 0, 0, 0) $$,
  '23514',
  null,
  'turnos_realizados_nao_negativo: valor negativo recusado'
);

select throws_ok(
  $$ insert into privado.profissional_reputacao_expurgada (profissional_id, turnos_realizados, presencas, faltas, aval_positivas, aval_total)
     values ((select id from ids where chave = 'prof_check'), 0, -1, 0, 0, 0) $$,
  '23514',
  null,
  'presencas_nao_negativo: valor negativo recusado'
);

select throws_ok(
  $$ insert into privado.profissional_reputacao_expurgada (profissional_id, turnos_realizados, presencas, faltas, aval_positivas, aval_total)
     values ((select id from ids where chave = 'prof_check'), 0, 0, -1, 0, 0) $$,
  '23514',
  null,
  'faltas_nao_negativo: valor negativo recusado'
);

select throws_ok(
  $$ insert into privado.profissional_reputacao_expurgada (profissional_id, turnos_realizados, presencas, faltas, aval_positivas, aval_total)
     values ((select id from ids where chave = 'prof_check'), 0, 0, 0, -1, 0) $$,
  '23514',
  null,
  'aval_positivas_nao_negativo: valor negativo recusado'
);

select throws_ok(
  $$ insert into privado.profissional_reputacao_expurgada (profissional_id, turnos_realizados, presencas, faltas, aval_positivas, aval_total)
     values ((select id from ids where chave = 'prof_check'), 0, 0, 0, 0, -1) $$,
  '23514',
  null,
  'aval_total_nao_negativo: valor negativo recusado'
);

-- Como aval_coerente (aval_positivas <= aval_total) subsume aval_total >= 0 quando aval_positivas >= 0,
-- a asserção de catálogo garante detecção direta da restrição na mutação.
select is(
  (select count(*)::int from pg_constraint c
    where c.conrelid = 'privado.profissional_reputacao_expurgada'::regclass
      and c.conname = 'aval_total_nao_negativo'),
  1,
  'aval_total_nao_negativo: restrição check existe no catálogo'
);

select throws_ok(
  $$ insert into privado.profissional_reputacao_expurgada (profissional_id, turnos_realizados, presencas, faltas, aval_positivas, aval_total)
     values ((select id from ids where chave = 'prof_check'), 0, 0, 0, 5, 2) $$,
  '23514',
  null,
  'aval_coerente: avaliacoes_positivas > total recusado'
);

select * from finish();
rollback;
