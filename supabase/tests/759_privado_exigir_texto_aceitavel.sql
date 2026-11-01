-- 759_privado_exigir_texto_aceitavel.sql
-- Cobertura direta de privado.exigir_texto_aceitavel(jsonb): a trava de moderação de texto livre
-- (RN06/RN15) que as RPCs de escrita chamam antes de gravar título, observação, relato etc.
--
-- Contrato observado: para cada chave do objeto, o valor passa por privado.texto_aceitavel (lista
-- de termos bloqueados) e por privado.contem_contato_ou_link; qualquer reprovação vira
-- `422 campo_invalido` com `details` = nome do campo reprovado.
--
-- Mutantes que estes testes matam (ver PR):
--   M1  remover o `if not privado.texto_aceitavel(v)`        -> teste 3 fica vermelho
--   M2  remover o `if privado.contem_contato_ou_link(v)`     -> testes 4, 5 e 6 ficam vermelhos
--   M3  trocar `k` por texto fixo no `details`               -> testes 3, 4, 5 e 6 ficam vermelhos
--   M4  parar o laço depois da primeira chave (`exit`)       -> só o teste 6 fica vermelho
--
-- Atenção à ordem: jsonb guarda as chaves por tamanho e depois em ordem alfabética, e não na
-- ordem em que foram escritas. "O campo ruim não é o primeiro" só vale se isso for medido
-- (teste 9), e não presumido do literal.

begin;
select plan(9);

-- 1. Caso feliz: todos os campos limpos.
select lives_ok(
  $$ select privado.exigir_texto_aceitavel('{"observacoes":"Traje social preto","traje":"camisa e calça"}'::jsonb) $$,
  'campos limpos passam sem erro');

-- 2. Borda: objeto vazio não tem o que reprovar; valor nulo e vazio são aceitáveis.
select lives_ok(
  $$ select privado.exigir_texto_aceitavel('{}'::jsonb) $$,
  'objeto vazio passa');

-- 3. Termo bloqueado (a lista vem de privado.termo_bloqueado, não de um literal do teste).
select throws_ok(
  format($$ select privado.exigir_texto_aceitavel(jsonb_build_object('observacoes', %L)) $$,
         'turno com ' || (select termo from privado.termo_bloqueado order by termo limit 1)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "observacoes", "hint" : null}',
  'termo bloqueado é 422 campo_invalido com o nome do campo');

-- 4. E-mail no texto é contato e não pode.
select throws_ok(
  $$ select privado.exigir_texto_aceitavel('{"observacoes":"fale comigo em fulano@exemplo.com"}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "observacoes", "hint" : null}',
  'e-mail no texto é campo_invalido');

-- 5. Telefone (8+ dígitos) no texto é contato e não pode.
select throws_ok(
  $$ select privado.exigir_texto_aceitavel('{"traje":"chame no 61 99999-1234"}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "traje", "hint" : null}',
  'telefone no texto é campo_invalido, com o campo certo em details');

-- 6. O campo ruim vem DEPOIS de um campo bom na iteração ("traje" tem 5 letras, "observacoes" 11).
select throws_ok(
  $$ select privado.exigir_texto_aceitavel('{"traje":"camisa preta","observacoes":"entre em https://exemplo.com.br/x"}'::jsonb) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "observacoes", "hint" : null}',
  'link no segundo campo: details nomeia o campo reprovado, não o primeiro');

-- 7. Falsos positivos que a moderação não pode barrar: horário, valor e data são texto de vaga.
select lives_ok(
  $$ select privado.exigir_texto_aceitavel('{"observacoes":"Das 18h30 às 23h, R$ 150,00, dia 15/10/2026"}'::jsonb) $$,
  'horário, valor e data não são confundidos com telefone');

-- 8. Valor JSON nulo: ->> devolve NULL e o texto nulo é aceitável (campo opcional ausente).
select lives_ok(
  $$ select privado.exigir_texto_aceitavel('{"traje":null}'::jsonb) $$,
  'campo nulo (opcional) passa');

-- 9. A premissa do teste 6, medida: o campo reprovado ("observacoes") NÃO é a primeira chave que
--    o laço enxerga.
select is(
  (select array_agg(k) from jsonb_object_keys('{"traje":"camisa preta","observacoes":"x"}'::jsonb) k),
  array['traje', 'observacoes'],
  'a ordem de iteração do jsonb põe "observacoes" depois de "traje" (premissa do teste 6)');

select * from finish();
rollback;
