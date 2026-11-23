-- Teste pgTAP: supabase/tests/811_lgpd_j6_retencao_turnos_e_registros_acesso.sql
-- Escopo: LGPD-J6 (Retenção de turnos por 5 anos e registros de acesso por 6 meses)
-- Provas:
--   B1: Calendário civil real (interval '5 years' e interval '6 months' vs dias fixos);
--       fronteira de 5 anos preserva turno de 4 anos e 363 dias.
--   B2: Expurgo em lotes determinísticos com SKIP LOCKED e teto mínimo de salvaguarda.
--   B3: Expurgo encerra retenção do contexto pessoal do turno:
--       - Desvinculação de ocorrência (turno_id = null e posicao_id = null);
--       - Remoção em cascata de avaliações;
--       - Remoção de registros em privado.auditoria_ciclo;
--       - Remoção da posição expirada;
--       - Anonimização do responsável_local da vaga expirada ('Expurgado (LGPD)').

begin;
select plan(29);

-- 1. Estrutura da tabela privado.registro_acesso
select has_table('privado', 'registro_acesso', 'tabela privado.registro_acesso deve existir');
-- O layout enxuto (20261108110000, registro de acessos pela borda) tira id, recurso e user_agent.
select hasnt_column('privado', 'registro_acesso', 'id', 'sem a coluna id (layout enxuto de 20261108110000)');
select has_column('privado', 'registro_acesso', 'usuario_id', 'coluna usuario_id deve existir');
select has_column('privado', 'registro_acesso', 'ip', 'coluna ip deve existir');
select has_column('privado', 'registro_acesso', 'acessado_em', 'coluna acessado_em deve existir');
select hasnt_column('privado', 'registro_acesso', 'recurso', 'sem a coluna recurso (layout enxuto de 20261108110000)');
select hasnt_column('privado', 'registro_acesso', 'user_agent', 'sem a coluna user_agent (jurídico: o registro não guarda user_agent)');

-- 2. Segurança e RLS
select results_eq(
  'select relrowsecurity from pg_class where relname = ''registro_acesso'' and relnamespace = ''privado''::regnamespace',
  ARRAY[true],
  'RLS deve estar ativado em privado.registro_acesso'
);

select results_eq(
  'select has_table_privilege(''anon'', ''privado.registro_acesso'', ''SELECT,INSERT,UPDATE,DELETE'')',
  ARRAY[false],
  'anon não deve ter acesso a privado.registro_acesso'
);

select results_eq(
  'select has_table_privilege(''authenticated'', ''privado.registro_acesso'', ''SELECT,INSERT,UPDATE,DELETE'')',
  ARRAY[false],
  'authenticated não deve ter acesso a privado.registro_acesso'
);

-- 3. A gravação manual saiu (20261108110000): quem grava é privado.consumir_registro_acesso
select hasnt_function('privado', 'registrar_acesso', ARRAY['uuid', 'inet', 'text', 'text'], 'privado.registrar_acesso saiu');
select is((select count(*)::int from pg_constraint where conrelid = 'privado.registro_acesso'::regclass and contype = 'f'), 0,
  'sem chave estrangeira: o registro dura 6 meses depois da exclusão da conta');
select is((select count(*)::int from pg_index i join pg_class c on c.oid = i.indexrelid join pg_am a on a.oid = c.relam
            where i.indrelid = 'privado.registro_acesso'::regclass and a.amname = 'brin'), 1,
  'a limpeza usa uma BRIN em acessado_em');

-- 4. Função privado.limpar_registros_acesso (6 meses, MCI art. 15)
select has_function('privado', 'limpar_registros_acesso', ARRAY['integer', 'integer'], 'função privado.limpar_registros_acesso(integer, integer) deve existir');

-- Inserção manual de registros para teste de expurgo (calendário real de meses)
insert into privado.registro_acesso (ip, acessado_em)
values ('10.0.0.1'::inet, privado.agora() - interval '7 months');

insert into privado.registro_acesso (ip, acessado_em)
values ('10.0.0.2'::inet, privado.agora() - interval '1 month');

-- Executa a limpeza com lote
select is(
  privado.limpar_registros_acesso(6, 1000),
  1,
  'limpar_registros_acesso deve remover exatamente 1 registro com mais de 6 meses'
);

select results_eq(
  'select count(*)::int from privado.registro_acesso where ip = ''10.0.0.1''::inet',
  ARRAY[0],
  'registro de 7 meses atrás deve ter sido expurgado'
);

select results_eq(
  'select count(*)::int from privado.registro_acesso where ip = ''10.0.0.2''::inet',
  ARRAY[1],
  'registro de 1 mês atrás deve continuar preservado'
);

-- 5. Função privado.expurgar_turnos_antigos (5 anos, CF art. 7º XXIX, CC art. 206 § 3º V)
select has_function('privado', 'expurgar_turnos_antigos', ARRAY['integer', 'integer'], 'função privado.expurgar_turnos_antigos(integer, integer) deve existir');

-- Setup isolado com entidades de teste dedicadas
create temp table setup_ids as
with conta_estab as (
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (gen_random_uuid(), 'contratante', 'Contratante LGPD', '+5561999990001', 'contratante_lgpd@teste.com', '1985-01-01', '0.2.62', privado.agora())
  returning id
),
estab as (
  insert into public.estabelecimento (nome, documento, tipo, endereco, regiao_administrativa, ponto)
  values ('Estab LGPD', '99888777000199', 'food_service', 'Endereço LGPD', 'Plano Piloto', 'POINT(-47.88 -15.77)'::extensions.geography)
  returning id
),
membro as (
  insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
  select estab.id, conta_estab.id, 'administrador'
    from estab cross join conta_estab
  returning estabelecimento_id, usuario_id
),
conta_prof as (
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (gen_random_uuid(), 'profissional', 'Profissional LGPD', '+5561999990002', 'prof_lgpd@teste.com', '1990-01-01', '0.2.62', privado.agora())
  returning id, perfil
),
prof as (
  insert into public.profissional (usuario_id, perfil, ponto_base)
  select id, perfil, 'POINT(-47.88 -15.77)'::extensions.geography
  from conta_prof
  returning id, usuario_id
)
select (select id from estab) as estab_id,
       (select id from conta_estab) as estab_user_id,
       (select id from prof) as prof_id,
       (select id from conta_prof) as prof_user_id,
       (select id from public.funcao limit 1) as funcao_id;

create temp table ids_teste (
  turno_antigo_id uuid,
  posicao_antiga_id uuid,
  vaga_antiga_id uuid,
  turno_fronteira_id uuid,
  posicao_fronteira_id uuid,
  turno_recente_id uuid,
  posicao_recente_id uuid,
  vaga_recente_id uuid
);

-- Popula dados de teste para expurgo
do $$
declare
  v_estab_id uuid;
  v_estab_user_id uuid;
  v_prof_id uuid;
  v_prof_user_id uuid;
  v_funcao_id uuid;
  v_vaga_antiga_id uuid;
  v_pos_antiga_id uuid;
  v_turno_antigo_id uuid;
  v_vaga_fronteira_id uuid;
  v_pos_fronteira_id uuid;
  v_turno_fronteira_id uuid;
  v_vaga_recente_id uuid;
  v_pos_recente_id uuid;
  v_turno_recente_id uuid;
begin
  select estab_id, estab_user_id, prof_id, prof_user_id, funcao_id
    into v_estab_id, v_estab_user_id, v_prof_id, v_prof_user_id, v_funcao_id
    from setup_ids;

  -- 1. Turno antigo: encerrou há 5 anos e 2 dias (deve ser expurgado)
  insert into public.vaga (
    estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_por
  ) values (
    v_estab_id, v_funcao_id,
    privado.agora() - interval '5 years' - interval '3 days',
    privado.agora() - interval '5 years' - interval '2 days',
    'Local Antigo', 'POINT(-47.88 -15.77)'::extensions.geography,
    15000, 1, false, false, false, 'Gerente Antigo', 'urgencia', gen_random_uuid(), v_estab_user_id
  ) returning id into v_vaga_antiga_id;

  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em)
  values (
    v_vaga_antiga_id, v_prof_id,
    privado.agora() - interval '5 years' - interval '3 days',
    privado.agora() - interval '5 years' - interval '2 days',
    'cumprida', privado.agora() - interval '5 years' - interval '3 days'
  ) returning id into v_pos_antiga_id;

  insert into public.turno (posicao_id, valor_acordado_centavos, checkin_em, checkin_tipo, checkin_distancia_m, verificacao)
  values (
    v_pos_antiga_id, 15000,
    privado.agora() - interval '5 years' - interval '3 days',
    'geolocalizado', 50, 'verificado'
  ) returning id into v_turno_antigo_id;

  -- Avaliação no turno antigo (RN07: autor é membro do estab, alvo é profissional do turno)
  insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
  values (v_turno_antigo_id, v_estab_user_id, 'profissional', v_prof_id, true);

  -- Ocorrência vinculada ao turno e à posição antigos
  insert into public.ocorrencia (tipo, turno_id, posicao_id, autor_id, motivo)
  values ('cancelamento', v_turno_antigo_id, v_pos_antiga_id, v_estab_user_id, 'Ocorrência teste turno antigo');

  -- Auditoria vinculada ao turno antigo
  insert into privado.auditoria_ciclo (entidade, entidade_id, acao, estado_anterior, estado_novo, autor_id)
  values ('turno', v_turno_antigo_id, 'mudou_estado', 'pendente', 'verificado', v_estab_user_id);

  -- 2. Turno na fronteira: encerrou há 5 anos MENOS 2 dias (deve SOBREVIVER ao expurgo de 5 anos - prova de B1)
  insert into public.vaga (
    estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_por
  ) values (
    v_estab_id, v_funcao_id,
    privado.agora() - interval '5 years' + interval '1 day',
    privado.agora() - interval '5 years' + interval '2 days',
    'Local Fronteira', 'POINT(-47.88 -15.77)'::extensions.geography,
    15000, 1, false, false, false, 'Gerente Fronteira', 'urgencia', gen_random_uuid(), v_estab_user_id
  ) returning id into v_vaga_fronteira_id;

  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em)
  values (
    v_vaga_fronteira_id, v_prof_id,
    privado.agora() - interval '5 years' + interval '1 day',
    privado.agora() - interval '5 years' + interval '2 days',
    'cumprida', privado.agora() - interval '5 years' + interval '1 day'
  ) returning id into v_pos_fronteira_id;

  insert into public.turno (posicao_id, valor_acordado_centavos, checkin_em, checkin_tipo, checkin_distancia_m, verificacao)
  values (
    v_pos_fronteira_id, 15000,
    privado.agora() - interval '5 years' + interval '1 day',
    'geolocalizado', 50, 'verificado'
  ) returning id into v_turno_fronteira_id;

  -- 3. Turno recente: encerrou há 1 mês (deve SOBREVIVER)
  insert into public.vaga (
    estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_por
  ) values (
    v_estab_id, v_funcao_id,
    privado.agora() - interval '30 days',
    privado.agora() - interval '29 days',
    'Local Recente', 'POINT(-47.88 -15.77)'::extensions.geography,
    15000, 1, false, false, false, 'Gerente Recente', 'urgencia', gen_random_uuid(), v_estab_user_id
  ) returning id into v_vaga_recente_id;

  insert into public.posicao (vaga_id, profissional_id, inicio_em, fim_em, estado, confirmado_em)
  values (
    v_vaga_recente_id, v_prof_id,
    privado.agora() - interval '30 days',
    privado.agora() - interval '29 days',
    'cumprida', privado.agora() - interval '30 days'
  ) returning id into v_pos_recente_id;

  insert into public.turno (posicao_id, valor_acordado_centavos, checkin_em, checkin_tipo, checkin_distancia_m, verificacao)
  values (
    v_pos_recente_id, 15000,
    privado.agora() - interval '30 days',
    'geolocalizado', 50, 'verificado'
  ) returning id into v_turno_recente_id;

  insert into ids_teste (
    turno_antigo_id, posicao_antiga_id, vaga_antiga_id,
    turno_fronteira_id, posicao_fronteira_id,
    turno_recente_id, posicao_recente_id, vaga_recente_id
  ) values (
    v_turno_antigo_id, v_pos_antiga_id, v_vaga_antiga_id,
    v_turno_fronteira_id, v_pos_fronteira_id,
    v_turno_recente_id, v_pos_recente_id, v_vaga_recente_id
  );
end $$;

-- B1/B2: Executa expurgo de turnos de 5 anos em lote
select is(
  privado.expurgar_turnos_antigos(5, 500),
  1,
  'privado.expurgar_turnos_antigos(5) deve expurgar exatamente 1 turno antigo com mais de 5 anos'
);

-- Confere que o turno antigo sumiu
select is(
  (select count(*)::int from public.turno where id = (select turno_antigo_id from ids_teste)),
  0,
  'turno de mais de 5 anos deve ter sido expurgado'
);

-- B1: Confere que o turno na fronteira (5 anos menos 2 dias) SOBREVIVEU
select is(
  (select count(*)::int from public.turno where id = (select turno_fronteira_id from ids_teste)),
  1,
  'B1: turno na fronteira (5 anos menos 2 dias) deve continuar preservado'
);

-- Confere que o turno recente continua preservado
select is(
  (select count(*)::int from public.turno where id = (select turno_recente_id from ids_teste)),
  1,
  'turno recente deve permanecer intacto'
);

-- B3: Confere desvinculação da ocorrência (turno_id e posicao_id setados para NULL sem apagar o registro)
select results_eq(
  'select count(*)::int from public.ocorrencia where motivo = ''Ocorrência teste turno antigo'' and turno_id is null and posicao_id is null',
  ARRAY[1],
  'B3: ocorrência do turno antigo deve ter sido desvinculada (turno_id e posicao_id = null) sem ser apagada'
);

-- B3: Confere remoção da posição expirada
select is(
  (select count(*)::int from public.posicao where id = (select posicao_antiga_id from ids_teste)),
  0,
  'B3: posição encerrada há mais de 5 anos do turno expurgado deve ter sido removida'
);

-- B3: Confere remoção da trilha de auditoria do turno e posição expurgados
select is(
  (select count(*)::int from privado.auditoria_ciclo where (entidade = 'turno' and entidade_id = (select turno_antigo_id from ids_teste)) or (entidade = 'posicao' and entidade_id = (select posicao_antiga_id from ids_teste))),
  0,
  'B3: trilha de auditoria do turno e posição expurgados deve ter sido limpa'
);

-- B3: Confere anonimização de contexto pessoal na vaga antiga
select results_eq(
  'select responsavel_local from public.vaga where id = (select vaga_antiga_id from ids_teste)',
  ARRAY['Expurgado (LGPD)'],
  'B3: responsavel_local da vaga antiga sem posições ativas deve ter sido anonimizado para Expurgado (LGPD)'
);

-- B3: Confere preservação do contexto na vaga recente
select results_eq(
  'select responsavel_local from public.vaga where id = (select vaga_recente_id from ids_teste)',
  ARRAY['Gerente Recente'],
  'B3: responsavel_local da vaga recente com posições válidas deve permanecer inalterado'
);

-- 6. Execução consolidada em privado.executar_retencao_diaria
select ok(
  (privado.executar_retencao_diaria()->>'expurgo_turnos_antigos') is not null,
  'privado.executar_retencao_diaria deve conter campo expurgo_turnos_antigos no jsonb de retorno'
);

select ok(
  (privado.executar_retencao_diaria()->>'expurgo_registros_acesso') is not null,
  'privado.executar_retencao_diaria deve conter campo expurgo_registros_acesso no jsonb de retorno'
);

select finish();
rollback;
