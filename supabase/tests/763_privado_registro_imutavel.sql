-- 763_privado_registro_imutavel.sql
-- Cobertura direta do gatilho privado.registro_imutavel() (BEFORE UPDATE OR DELETE): torna a linha
-- um registro — só as colunas listadas em TG_ARGV mudam, nada se apaga, e a rotina de retenção
-- (`privado.retencao = 'on'`) é a única exceção.
--
-- A função é compartilhada (hoje só `ocorrencia_imutavel` a usa, e a ocorrência exige um
-- cenário inteiro). O teste a exercita numa tabela temporária com o mesmo desenho de gatilho,
-- para medir a função e não o cenário.
--
-- Mutantes que estes testes matam (ver PR):
--   M1  remover o desvio da retenção                      -> testes 5 e 6 ficam vermelhos
--   M2  deixar o DELETE passar                            -> testes 4, 7 e 10 ficam vermelhos
--   M3  não descontar as colunas permitidas na comparação -> testes 1 e 2 ficam vermelhos
--   M4  nunca recusar o UPDATE de coluna proibida         -> testes 3, 8 e 9 ficam vermelhos

begin;
select plan(11);

-- Mesma forma do gatilho real: `execute function privado.registro_imutavel('col', ...)`.
create temp table reg (id int primary key, fixo text not null, livre text, outra text);
create trigger reg_imutavel before update or delete on reg
  for each row execute function privado.registro_imutavel('livre', 'outra');

-- Sem colunas permitidas: o registro é totalmente congelado.
create temp table reg_fechado (id int primary key, texto text);
create trigger reg_fechado_imutavel before update or delete on reg_fechado
  for each row execute function privado.registro_imutavel();

insert into reg values (1, 'original', 'a', 'b'), (2, 'original', 'a', 'b');
insert into reg_fechado values (1, 'congelado');

-- 1-2. Caminho feliz: as colunas listadas mudam, sozinhas ou juntas.
select lives_ok($$ update reg set livre = 'alterada' where id = 1 $$,
  'coluna permitida (livre) pode mudar');
select lives_ok($$ update reg set livre = 'x', outra = 'y' where id = 1 $$,
  'as duas colunas permitidas mudam na mesma instrução');

-- 3. Coluna fora da lista: recusa com restrict_violation e mensagem que nomeia a tabela e a lista.
select throws_ok($$ update reg set fixo = 'adulterado' where id = 1 $$,
  '23001', 'registro de reg so muda em livre, outra',
  'coluna fora da lista é restrict_violation e a mensagem diz o que pode mudar');

-- 4. Apagar é proibido.
select throws_ok($$ delete from reg where id = 1 $$,
  '23001', 'registro de reg nao pode ser apagado',
  'DELETE é restrict_violation');

-- 5-6. Retenção ligada: a rotina de retenção apaga e reescreve o que o resto do mundo não pode.
select set_config('privado.retencao', 'on', true);
select lives_ok($$ update reg set fixo = 'reescrita pela retenção' where id = 2 $$,
  'com privado.retencao = on, o UPDATE de coluna fixa passa');
select lives_ok($$ delete from reg where id = 2 $$,
  'com privado.retencao = on, o DELETE passa');

-- 7. Retenção desligada de novo: qualquer valor diferente de "on" não abre a porta.
select set_config('privado.retencao', 'off', true);
select throws_ok($$ delete from reg where id = 1 $$,
  '23001', 'registro de reg nao pode ser apagado',
  'privado.retencao = off não libera o DELETE');

-- 8. Vazio (valor padrão de uma sessão que nunca ligou a retenção) também não libera.
select set_config('privado.retencao', '', true);
select throws_ok($$ update reg set fixo = 'x' where id = 1 $$,
  '23001', 'registro de reg so muda em livre, outra',
  'privado.retencao vazio não libera o UPDATE');

-- 9-10. Tabela sem colunas permitidas: nada muda, e a mensagem não inventa uma lista.
select throws_ok($$ update reg_fechado set texto = 'x' where id = 1 $$,
  '23001', 'registro de reg_fechado so muda em ',
  'sem colunas permitidas, qualquer UPDATE é recusado');
select throws_ok($$ delete from reg_fechado where id = 1 $$,
  '23001', 'registro de reg_fechado nao pode ser apagado',
  'sem colunas permitidas, o DELETE também é recusado');

-- 11. UPDATE que não muda nada passa (a comparação é de conteúdo, não de "tocou na coluna").
select lives_ok($$ update reg_fechado set texto = texto where id = 1 $$,
  'UPDATE sem alteração de conteúdo é aceito');

select * from finish();
rollback;
