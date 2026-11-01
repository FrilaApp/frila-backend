-- 764_privado_estabelecimento_publico.sql
-- Cobertura direta de privado.estabelecimento_publico(uuid): o cartão público de reputação de um
-- estabelecimento (RF16/RN07) — só nome e contagem binária de avaliações. Nada de documento,
-- endereço ou ponto: o que sai daqui chega ao profissional que ainda não foi confirmado (RN10).
--
-- Mutantes que estes testes matam (ver PR):
--   M1  trocar aval_positivas por aval_total em `positivas` -> teste 3 fica vermelho
--   M2  incluir `documento` no objeto                       -> testes 1 e 5 ficam vermelhos
--   M3  remover o `where e.id = estab` (devolve qualquer)   -> testes 1, 2, 3 e 6 ficam vermelhos

begin;
select plan(7);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, aval_positivas, aval_total) values
  ('76400000-0000-4000-8000-0000000000e1', 'Casa do Teste 764', '76400000000001', 'food_service', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 7, 9),
  ('76400000-0000-4000-8000-0000000000e2', 'Outra Casa 764', '76400000000002', 'food_service', 'CLS 305',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 0, 0);

-- 1. Caminho feliz: o cartão traz id, tipo e nome.
select is(
  (privado.estabelecimento_publico('76400000-0000-4000-8000-0000000000e1')) - 'reputacao',
  '{"id":"76400000-0000-4000-8000-0000000000e1","tipo":"estabelecimento","nome":"Casa do Teste 764"}'::jsonb,
  'o cartão traz id, tipo "estabelecimento" e nome');

-- 2-3. Reputação binária: positivas e total vêm das colunas, sem média nem nota.
select is(
  privado.estabelecimento_publico('76400000-0000-4000-8000-0000000000e1') #>> '{reputacao,total}',
  '9', 'reputacao.total vem de aval_total');
select is(
  privado.estabelecimento_publico('76400000-0000-4000-8000-0000000000e1') #>> '{reputacao,positivas}',
  '7', 'reputacao.positivas vem de aval_positivas (e não de aval_total)');

-- 4. Estabelecimento não tem taxa de comparecimento: a chave existe e é nula, não zero.
select is(
  (privado.estabelecimento_publico('76400000-0000-4000-8000-0000000000e1') #> '{reputacao}')
    - array['positivas', 'total'],
  '{"taxa_comparecimento":null,"turnos_considerados":0,"turnos_realizados":0}'::jsonb,
  'a parte de comparecimento é o mesmo formato do profissional, com taxa nula e zeros');

-- 5. Nada de dado cadastral no cartão público (RN10/LGPD).
select is(
  (select array_agg(k order by k) from jsonb_object_keys(
     privado.estabelecimento_publico('76400000-0000-4000-8000-0000000000e1')) k),
  array['id', 'nome', 'reputacao', 'tipo'],
  'o cartão público não expõe documento, endereço nem ponto');

-- 6. Borda: id que não existe devolve NULL (a RPC chamadora decide o 404).
select is(
  privado.estabelecimento_publico('76400000-0000-4000-8000-0000000000ff'),
  null::jsonb,
  'estabelecimento inexistente devolve NULL');

-- 7. Execução fechada para os papéis da API: só RPC pública a chama.
select is(
  has_function_privilege('anon', 'privado.estabelecimento_publico(uuid)', 'execute')
  or has_function_privilege('authenticated', 'privado.estabelecimento_publico(uuid)', 'execute'),
  false,
  'anon e authenticated não executam privado.estabelecimento_publico direto');

select * from finish();
rollback;
