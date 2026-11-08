-- Teste pgTAP: supabase/tests/811_lgpd_j6_retencao_turnos_e_registros_acesso.sql
-- Escopo: LGPD-J6 (Retenção de turnos por 5 anos e registros de acesso por 6 meses)

begin;
select plan(24);

-- 1. Estrutura da tabela privado.registro_acesso
select has_table('privado', 'registro_acesso', 'tabela privado.registro_acesso deve existir');
select has_column('privado', 'registro_acesso', 'id', 'coluna id deve existir');
select has_column('privado', 'registro_acesso', 'usuario_id', 'coluna usuario_id deve existir');
select has_column('privado', 'registro_acesso', 'ip', 'coluna ip deve existir');
select has_column('privado', 'registro_acesso', 'acessado_em', 'coluna acessado_em deve existir');
select has_column('privado', 'registro_acesso', 'recurso', 'coluna recurso deve existir');
select has_column('privado', 'registro_acesso', 'user_agent', 'coluna user_agent deve existir');

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

-- 3. Função privado.registrar_acesso
select has_function('privado', 'registrar_acesso', ARRAY['uuid', 'inet', 'text', 'text'], 'função privado.registrar_acesso deve existir');

-- Teste de inserção via registrar_acesso
select ok(
  privado.registrar_acesso(
    null,
    '192.168.1.1'::inet,
    'api/v1/auth',
    'FrilaApp/1.0 (iOS)'
  ) > 0,
  'privado.registrar_acesso deve inserir com sucesso e retornar ID positivo'
);

select is(
  privado.registrar_acesso(null, null, 'api', 'agent'),
  null::bigint,
  'privado.registrar_acesso com IP nulo deve retornar null sem inserir'
);

-- 4. Função privado.limpar_registros_acesso (180 dias / 6 meses)
select has_function('privado', 'limpar_registros_acesso', ARRAY['integer'], 'função privado.limpar_registros_acesso deve existir');

-- Inserção manual de registros para teste de expurgo
insert into privado.registro_acesso (ip, acessado_em, recurso)
values ('10.0.0.1'::inet, privado.agora() - interval '200 days', 'antigo');

insert into privado.registro_acesso (ip, acessado_em, recurso)
values ('10.0.0.2'::inet, privado.agora() - interval '10 days', 'recente');

-- Executa a limpeza
select is(
  privado.limpar_registros_acesso(180),
  1,
  'limpar_registros_acesso deve remover exatamente 1 registro com mais de 180 dias'
);

select results_eq(
  'select count(*)::int from privado.registro_acesso where ip = ''10.0.0.1''::inet',
  ARRAY[0],
  'registro de 200 dias atrás deve ter sido expurgado'
);

select results_eq(
  'select count(*)::int from privado.registro_acesso where ip = ''10.0.0.2''::inet',
  ARRAY[1],
  'registro de 10 dias atrás deve continuar preservado'
);

-- 5. Função privado.expurgar_turnos_antigos (1825 dias / 5 anos)
select has_function('privado', 'expurgar_turnos_antigos', ARRAY['integer'], 'função privado.expurgar_turnos_antigos deve existir');

-- Setup de teste para turnos antigos
do $$
declare
  v_estab_id uuid;
  v_vaga_antiga_id uuid;
  v_vaga_recente_id uuid;
  v_pos_antiga_id uuid;
  v_pos_recente_id uuid;
  v_turno_antigo_id uuid;
  v_turno_recente_id uuid;
  v_user_id uuid;
begin
  select id into v_user_id from public.usuario limit 1;
  select id into v_estab_id from public.estabelecimento limit 1;

  -- Vaga e posição antigas (fim há 1900 dias)
  insert into public.vaga (estabelecimento_id, funcao, data, valor_centavos)
  values (v_estab_id, 'garcom', (privado.agora() - interval '1900 days')::date, 15000)
  returning id into v_vaga_antiga_id;

  insert into public.posicao (vaga_id, numero, inicio_em, fim_em, valor_centavos)
  values (v_vaga_antiga_id, 1, privado.agora() - interval '1900 days', privado.agora() - interval '1899 days', 15000)
  returning id into v_pos_antiga_id;

  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos_antiga_id, 15000)
  returning id into v_turno_antigo_id;

  -- Avaliação no turno antigo
  insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
  values (v_turno_antigo_id, v_user_id, 'profissional', v_user_id, true);

  -- Ocorrência vinculada ao turno antigo
  insert into public.ocorrencia (tipo, turno_id, autor_id, motivo)
  values ('desistencia_profissional', v_turno_antigo_id, v_user_id, 'Ocorrência teste turno antigo');

  -- Vaga e posição recentes (fim há 10 dias)
  insert into public.vaga (estabelecimento_id, funcao, data, valor_centavos)
  values (v_estab_id, 'garcom', (privado.agora() - interval '10 days')::date, 15000)
  returning id into v_vaga_recente_id;

  insert into public.posicao (vaga_id, numero, inicio_em, fim_em, valor_centavos)
  values (v_vaga_recente_id, 1, privado.agora() - interval '10 days', privado.agora() - interval '9 days', 15000)
  returning id into v_pos_recente_id;

  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos_recente_id, 15000)
  returning id into v_turno_recente_id;

  -- Avaliação no turno recente
  insert into public.avaliacao (turno_id, autor_id, alvo_tipo, alvo_id, resposta)
  values (v_turno_recente_id, v_user_id, 'profissional', v_user_id, true);
end $$;

-- Executa expurgo de turnos com mais de 1825 dias
select is(
  privado.expurgar_turnos_antigos(1825),
  1,
  'privado.expurgar_turnos_antigos deve expurgar exatamente 1 turno antigo de mais de 5 anos'
);

-- Confere cascateamento da avaliação do turno antigo
select is(
  (select count(*)::int from public.avaliacao a join public.turno t on t.id = a.turno_id join public.posicao p on p.id = t.posicao_id where p.fim_em < privado.agora() - interval '1825 days'),
  0,
  'avaliações de turnos de mais de 5 anos devem ser removidas por cascade'
);

-- Confere desvinculação da ocorrência (turno_id setado para NULL)
select results_eq(
  'select count(*)::int from public.ocorrencia where motivo = ''Ocorrência teste turno antigo'' and turno_id is null',
  ARRAY[1],
  'ocorrência do turno antigo deve ter sido desvinculada (turno_id = null) sem ser apagada'
);

-- Confere que o turno recente continua preservado
select is(
  (select count(*)::int from public.turno t join public.posicao p on p.id = t.posicao_id where p.fim_em > privado.agora() - interval '30 days'),
  1,
  'turno recente com menos de 5 anos deve permanecer intacto'
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
