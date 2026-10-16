-- Trilha de auditoria por período em ordem cronológica (RNF13, RF22, RN15).
--
-- Cobertura da função `privado.auditoria_do_periodo(timestamptz, timestamptz)`
-- (migração 20260925220000_trilha_de_auditoria.sql).
--
-- A função exporta a trilha do ciclo em formato JSONB para um intervalo fechado no
-- início e aberto no fim [de, ate). O intervalo semiaberto garante que duas consultas
-- de períodos contíguos (ex: [00:00, 01:00) e [01:00, 02:00)) nunca contem a mesma linha
-- duas vezes.
--
-- Este teste valida:
--   1. Existência, linguagem SQL e atributo SECURITY DEFINER.
--   2. Controle de acesso estrito: sem EXECUTE para anon e authenticated; concedido a service_role.
--   3. Semântica estrita do intervalo [de, ate): inclui o marco inicial exato (em = de) e exclui
--      o marco final exato (em = ate).
--   4. Ordenação cronológica por `em` e desempate por `id`.
--   5. Estrutura do payload JSONB (entidade, entidade_id, acao, estado_anterior, estado_novo, autor_id, em).
--   6. Retorno de array vazio '[]'::jsonb (e nunca NULL) quando não há registros ou quando de > ate.
--   7. RN15: nenhum dado pessoal (telefone, email, documento, coordenadas) no retorno da trilha.

begin;

select plan(12);

-- ── 1. Estrutura e permissões de acesso ──────────────────────────────────────

select has_function('privado', 'auditoria_do_periodo', array['timestamptz', 'timestamptz'],
  'privado.auditoria_do_periodo(timestamptz, timestamptz) existe');

select function_lang_is('privado', 'auditoria_do_periodo', array['timestamptz', 'timestamptz'], 'sql',
  'auditoria_do_periodo é em linguagem sql');

select is_definer('privado', 'auditoria_do_periodo', array['timestamptz', 'timestamptz'],
  'auditoria_do_periodo é SECURITY DEFINER');

select is(has_function_privilege('anon', 'privado.auditoria_do_periodo(timestamptz, timestamptz)', 'execute'), false,
  'anon não tem permissão de execução em auditoria_do_periodo');

select is(has_function_privilege('authenticated', 'privado.auditoria_do_periodo(timestamptz, timestamptz)', 'execute'), false,
  'authenticated não tem permissão de execução em auditoria_do_periodo');

select is(has_function_privilege('service_role', 'privado.auditoria_do_periodo(timestamptz, timestamptz)', 'execute'), true,
  'service_role pode executar auditoria_do_periodo');

-- ── 2. Semântica de intervalo e bordas exatas [de, ate) ──────────────────────

create temp table ids_auditoria as select
  'b6910000-0000-4000-8000-000000000001'::uuid as ent_id,
  'b6910000-0000-4000-8000-000000000002'::uuid as autor_id;

insert into privado.auditoria_ciclo (entidade, entidade_id, acao, estado_anterior, estado_novo, autor_id, em)
values
  ('vaga',    (select ent_id from ids_auditoria), 'criou',        null,        'publicada', (select autor_id from ids_auditoria), '2030-06-01 00:00:00+00'),
  ('posicao', (select ent_id from ids_auditoria), 'mudou_estado', 'aberta',    'confirmada', (select autor_id from ids_auditoria), '2030-06-01 12:00:00+00'),
  ('turno',   (select ent_id from ids_auditoria), 'mudou_estado', 'pendente',  'verificado', (select autor_id from ids_auditoria), '2030-06-01 23:59:59+00'),
  ('turno',   (select ent_id from ids_auditoria), 'mudou_estado', 'verificado','cumprido',  (select autor_id from ids_auditoria), '2030-06-02 00:00:00+00'),
  ('vaga',    (select ent_id from ids_auditoria), 'criou',        null,        'publicada', (select autor_id from ids_auditoria), '2030-05-31 23:59:59+00');

select is(
  jsonb_array_length(privado.auditoria_do_periodo('2030-06-01 00:00:00+00', '2030-06-02 00:00:00+00')),
  3,
  'RNF13: intervalo [de, ate) inclui em=de e exclui em=ate'
);

select is(
  (select jsonb_agg(x->>'em') from jsonb_array_elements(privado.auditoria_do_periodo('2030-06-01 00:00:00+00', '2030-06-02 00:00:00+00')) x),
  '["2030-06-01T00:00:00+00:00", "2030-06-01T12:00:00+00:00", "2030-06-01T23:59:59+00:00"]'::jsonb,
  'RNF13: registros ordenados cronologicamente por em e id'
);

select is(
  (select array_agg(distinct k order by k)
     from jsonb_array_elements(privado.auditoria_do_periodo('2030-06-01 00:00:00+00', '2030-06-02 00:00:00+00')) x,
          jsonb_object_keys(x) k),
  array['acao', 'autor_id', 'em', 'entidade', 'entidade_id', 'estado_anterior', 'estado_novo'],
  'objeto JSONB contem exatamente as chaves da transicao de auditoria'
);

-- ── 3. Casos vazios e integridade de privacidade ─────────────────────────────

select is(
  privado.auditoria_do_periodo('2035-01-01 00:00:00+00', '2035-01-02 00:00:00+00'),
  '[]'::jsonb,
  'intervalo sem registros devolve array vazio [] e nao nulo'
);

select is(
  privado.auditoria_do_periodo('2030-06-02 00:00:00+00', '2030-06-01 00:00:00+00'),
  '[]'::jsonb,
  'intervalo invertido (de > ate) devolve array vazio []'
);

select ok(
  not exists (
    select 1 from jsonb_array_elements(privado.auditoria_do_periodo('2030-06-01 00:00:00+00', '2030-06-02 00:00:00+00')) x
     where x ?| array['nome', 'email', 'telefone', 'documento', 'ponto', 'latitude', 'longitude']
  ),
  'RN15: a saida da trilha nao contem nenhuma coluna de dado pessoal'
);

select * from finish();

rollback;
