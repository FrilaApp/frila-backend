-- `meus_estabelecimentos`: por qual casa o contratante está falando.
--
-- RF02, RF21, UC07, cartão `AvockvHx`. `publicar_vaga`, `painel_estabelecimento` e
-- `republicar_vaga` recebem `estabelecimento_id`, e sem esta leitura o app só descobre
-- esse id cadastrando um novo estabelecimento — o caminho errado para quem já tem.
--
-- O que este arquivo cobra, além do caminho feliz:
--
--   RF21  o papel vem junto. `operador` não publica vaga em nome da casa, e a tela
--         precisa esconder o que o servidor vai recusar com 403.
--   RN10  nenhum dado de contato na resposta — nem telefone, nem e-mail, nem o
--         documento da casa. É leitura de tela, não de cadastro.
--   —     lista vazia é resposta legítima, e não erro: contratante recém-criado.

begin;
select plan(11);

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

create function pg_temp.meus(conta uuid) returns jsonb
language sql as $$
  select pg_temp.como(conta, 'select public.meus_estabelecimentos()')
$$;

-- ── O cenário ──────────────────────────────────────────────────────────────────
--
--   Bia   administradora do Bar da Bia E operadora do Buffet da Bia — é ela que prova
--         que a mesma conta opera mais de uma casa, com papéis diferentes
--   Caio  contratante recém-criado, sem nenhuma casa: o array vazio
--   Duda  profissional: o perfil errado
--
-- Prefixo `b7`, que não existe em `cenarios.sql` nem nos outros arquivos de teste.

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('b7000000-0000-4000-8000-000000000001','contratante', 'Bia', '+5561955550001','bia@casa.test', '1983-01-01','2026-09-22', now()),
  ('b7000000-0000-4000-8000-000000000002','contratante', 'Caio','+5561955550002','caio@casa.test','1984-01-01','2026-09-22', now()),
  ('b7000000-0000-4000-8000-000000000003','profissional','Duda','+5561955550003','duda@casa.test','1995-01-01','2026-09-22', now());

insert into public.profissional (usuario_id, ponto_base)
values ('b7000000-0000-4000-8000-000000000003','POINT(-47.88 -15.79)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, aval_positivas, aval_total) values
  ('b7000000-0000-4000-8000-000000000010','Bar da Bia','13347016000117','food_service','CLN 410',
   'POINT(-47.8840 -15.7960)'::extensions.geography, 3, 4),
  ('b7000000-0000-4000-8000-000000000011','Buffet da Bia','09346601000125','evento','SIA Trecho 3',
   'POINT(-47.9010 -15.8010)'::extensions.geography, 0, 0),
  ('b7000000-0000-4000-8000-000000000012','Casa de Ninguém','17155730000164','varejo','Taguatinga',
   'POINT(-48.0500 -15.8300)'::extensions.geography, 0, 0);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('b7000000-0000-4000-8000-000000000001','b7000000-0000-4000-8000-000000000010','administrador'),
  ('b7000000-0000-4000-8000-000000000001','b7000000-0000-4000-8000-000000000011','operador');

-- ── As recusas ────────────────────────────────────────────────────────────────

select throws_ok(
  $$ select public.meus_estabelecimentos() $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não se lista casa nenhuma');

select throws_ok(
  $$ select pg_temp.meus('b7000000-0000-4000-8000-000000000003') $$,
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'RN25: esta tela é do contratante — o profissional recebe perfil_incompativel');

-- ── A lista vazia, que é resposta e não erro ──────────────────────────────────
--
-- O contratante recém-criado cai aqui, e é o caso mais comum do primeiro minuto de uso.
-- Se isto virasse 404 ou lista nula, a tela de "cadastre sua primeira casa" nunca
-- apareceria.
select is(
  pg_temp.meus('b7000000-0000-4000-8000-000000000002'),
  '[]'::jsonb,
  'contratante sem nenhuma casa recebe array vazio, e não erro');

-- ── O caminho feliz ───────────────────────────────────────────────────────────

select is(
  jsonb_array_length(pg_temp.meus('b7000000-0000-4000-8000-000000000001')),
  2,
  'RF02: a mesma conta opera mais de uma casa, e recebe as duas');

select is(
  (select jsonb_agg(e->>'nome' order by e->>'nome')
     from jsonb_array_elements(pg_temp.meus('b7000000-0000-4000-8000-000000000001')) e),
  '["Bar da Bia","Buffet da Bia"]'::jsonb,
  'e são as casas dela, em ordem de nome');

-- A casa de que ela não é membro não aparece. Negativa, porque uma leitura que devolve
-- demais só se descobre perguntando pelo que ela não deveria trazer.
select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.meus('b7000000-0000-4000-8000-000000000001')) e
    where (e->>'id')::uuid = 'b7000000-0000-4000-8000-000000000012'),
  0,
  'e a casa de que ela não é membro não entra na lista');

select is(
  (select e->>'papel' from jsonb_array_elements(pg_temp.meus('b7000000-0000-4000-8000-000000000001')) e
    where (e->>'id')::uuid = 'b7000000-0000-4000-8000-000000000010'),
  'administrador',
  'RF21: o papel vem junto — administradora no bar');

select is(
  (select e->>'papel' from jsonb_array_elements(pg_temp.meus('b7000000-0000-4000-8000-000000000001')) e
    where (e->>'id')::uuid = 'b7000000-0000-4000-8000-000000000011'),
  'operador',
  'e operadora no buffet: o papel é por casa, não por conta');

-- ── O schema do contrato ──────────────────────────────────────────────────────

select is(
  (select array_agg(distinct k order by k)
     from jsonb_array_elements(pg_temp.meus('b7000000-0000-4000-8000-000000000001')) e,
          jsonb_object_keys(e) k),
  array['id','nome','papel','reputacao','tipo'],
  'EstabelecimentoDaConta: id, nome, papel, tipo e reputacao, e nada além disso');

select is(
  (select e->'reputacao' from jsonb_array_elements(pg_temp.meus('b7000000-0000-4000-8000-000000000001')) e
    where (e->>'id')::uuid = 'b7000000-0000-4000-8000-000000000010'),
  '{"total": 4, "positivas": 3, "turnos_realizados": 0, "turnos_considerados": 0, "taxa_comparecimento": null}'::jsonb,
  'RN08: a reputação da casa sai pronta, com taxa nula e os turnos em zero — a taxa é do profissional');

-- ── RN10: nenhum contato nesta tela ───────────────────────────────────────────
--
-- A regex casa o telefone, o domínio dos e-mails, os três CNPJ, os endereços e as
-- palavras que nomeariam qualquer um deles. Uma coluna a mais copiada para dentro da
-- resposta amanhã cai aqui.
select is(
  (select count(*)::int
     from jsonb_array_elements(pg_temp.meus('b7000000-0000-4000-8000-000000000001')) e
    where e::text ~* '(\+55|casa\.test|13347016000117|09346601000125|17155730000164|CLN 410|SIA Trecho|telefone|email|documento|endereco|ponto|latitude|longitude)'),
  0,
  'RN10: a lista não traz telefone, e-mail, documento, endereço nem coordenada da casa');

select * from finish();
rollback;
