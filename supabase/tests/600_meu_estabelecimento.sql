-- `meu_estabelecimento`: o cadastro da casa, para quem é membro dela (contrato 0.2.29).
--
-- RF02, RF21, RN02. `publicar_vaga` exige `local`, `regiao_administrativa` e `ponto`, que
-- vêm preenchidos com os da casa, e só `cadastrar_estabelecimento` devolvia esses dados.
-- Sem esta leitura, quem volta ao app noutro dia não consegue publicar a segunda vaga.
--
-- O que este arquivo cobra, além do caminho feliz:
--
--   RF21  só membro lê, e o `papel` é o de quem chama: administradora numa casa,
--         operadora na outra. Os dois papéis leem, porque os dois publicam vaga.
--   —     quem não é membro recebe 403 sem_permissao, e o id que não existe também:
--         a resposta não distingue "não é sua" de "não existe".
--   RN10  nenhum dado além do `Estabelecimento` do contrato: sem telefone, sem e-mail
--         e sem os outros membros.
--
-- Prefixo `e6`, que não existe em `cenarios.sql` nem nos outros arquivos de teste.

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

create function pg_temp.meu(conta uuid, casa uuid) returns jsonb
language sql as $$
  select pg_temp.como(conta, format('select public.meu_estabelecimento(%L::uuid)', casa))
$$;

-- ── O cenário ──────────────────────────────────────────────────────────────────
--
--   Lia   administradora do Bar da Lia e operadora do Buffet da Lia
--   Noé   contratante sem casa nenhuma: não é membro de nada
--   Rui   profissional: nunca é membro
--
--   A Casa de Outro existe e não é de ninguém daqui.

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('e6000000-0000-4000-8000-000000000001','contratante', 'Lia','+5561960000001','lia@e60.test','1983-01-01','2026-09-22', now()),
  ('e6000000-0000-4000-8000-000000000002','contratante', 'Noé','+5561960000002','noe@e60.test','1984-01-01','2026-09-22', now()),
  ('e6000000-0000-4000-8000-000000000003','profissional','Rui','+5561960000003','rui@e60.test','1995-01-01','2026-09-22', now());

insert into public.profissional (usuario_id, ponto_base)
values ('e6000000-0000-4000-8000-000000000003','POINT(-47.88 -15.79)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, regiao_administrativa, ponto) values
  ('e6000000-0000-4000-8000-000000000010','Bar da Lia','60600600000101','food_service','CLN 410, Bloco B',
   'Plano Piloto','POINT(-47.8840 -15.7960)'::extensions.geography),
  ('e6000000-0000-4000-8000-000000000011','Buffet da Lia','60600600000102','evento','QS 3, Lote 5',
   'Águas Claras','POINT(-48.0260 -15.8390)'::extensions.geography),
  ('e6000000-0000-4000-8000-000000000012','Casa de Outro','60600600000103','varejo','Taguatinga Centro',
   'Taguatinga','POINT(-48.0500 -15.8300)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('e6000000-0000-4000-8000-000000000001','e6000000-0000-4000-8000-000000000010','administrador'),
  ('e6000000-0000-4000-8000-000000000001','e6000000-0000-4000-8000-000000000011','operador');

-- ── As recusas ────────────────────────────────────────────────────────────────

select throws_ok(
  $$ select public.meu_estabelecimento('e6000000-0000-4000-8000-000000000010'::uuid) $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não se lê o cadastro de casa nenhuma');

select throws_ok(
  $$ select pg_temp.meu('e6000000-0000-4000-8000-000000000001', 'e6000000-0000-4000-8000-000000000012') $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'RF21: contratante que não é membro da casa recebe sem_permissao');

select throws_ok(
  $$ select pg_temp.meu('e6000000-0000-4000-8000-000000000002', 'e6000000-0000-4000-8000-000000000010') $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'contratante sem casa nenhuma não lê a casa dos outros');

select throws_ok(
  $$ select pg_temp.meu('e6000000-0000-4000-8000-000000000003', 'e6000000-0000-4000-8000-000000000010') $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'profissional nunca é membro: sem_permissao');

-- A resposta para o id que não existe é a mesma de "não é sua": quem pergunta não
-- descobre, pela diferença, quais casas existem.
select throws_ok(
  $$ select pg_temp.meu('e6000000-0000-4000-8000-000000000001', 'e6000000-0000-4000-8000-0000000000ff') $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'o id que não existe responde sem_permissao, igual à casa alheia');

-- ── O caminho feliz ───────────────────────────────────────────────────────────

select is(
  pg_temp.meu('e6000000-0000-4000-8000-000000000001', 'e6000000-0000-4000-8000-000000000010'),
  '{"id": "e6000000-0000-4000-8000-000000000010", "nome": "Bar da Lia", "documento": "60600600000101",
    "tipo": "food_service", "endereco": "CLN 410, Bloco B", "regiao_administrativa": "Plano Piloto",
    "ponto": {"latitude": -15.796, "longitude": -47.884}, "papel": "administrador"}'::jsonb,
  'RN02: a administradora recebe o endereço, a região e o ponto da casa, para preencher a vaga');

select is(
  pg_temp.meu('e6000000-0000-4000-8000-000000000001', 'e6000000-0000-4000-8000-000000000011')->>'papel',
  'operador',
  'RF21: a operadora também lê, e o papel é o dela nesta casa');

select is(
  pg_temp.meu('e6000000-0000-4000-8000-000000000001', 'e6000000-0000-4000-8000-000000000011')->>'regiao_administrativa',
  'Águas Claras',
  'e a casa devolvida é a pedida, e não a primeira da conta');

-- ── O schema do contrato ──────────────────────────────────────────────────────

select is(
  (select array_agg(k order by k)
     from jsonb_object_keys(pg_temp.meu('e6000000-0000-4000-8000-000000000001', 'e6000000-0000-4000-8000-000000000010')) k),
  array['documento','endereco','id','nome','papel','ponto','regiao_administrativa','tipo'],
  'Estabelecimento: os oito campos do contrato, e nada além deles');

-- RN10: nada de contato de quem é membro. Uma coluna a mais copiada para dentro da
-- resposta amanhã cai aqui.
select is(
  pg_temp.meu('e6000000-0000-4000-8000-000000000001', 'e6000000-0000-4000-8000-000000000010')::text
    ~* '(\+55|e60\.test|telefone|email|membros|usuario_id)',
  false,
  'RN10: a resposta não traz telefone, e-mail nem os outros membros da casa');

-- ── Quem executa ──────────────────────────────────────────────────────────────

select is(
  (select array[has_function_privilege('anon', p.oid, 'execute'),
                has_function_privilege('authenticated', p.oid, 'execute')]
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'meu_estabelecimento'),
  array[false, true],
  'anon não executa meu_estabelecimento; authenticated executa');

select * from finish();
rollback;
