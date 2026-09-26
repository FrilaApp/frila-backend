-- `republicar_vaga`: o bar que chama freela toda sexta não redigita a vaga.
--
-- RF05, US05. Copia todos os campos da vaga de origem e muda só início e fim. O contrato
-- diz "mesmas recusas de `publicar_vaga`" (openapi.yaml:1058), e é isso que este arquivo
-- cobra: não basta a cópia funcionar, as recusas têm de ser as mesmas — senão o app
-- precisa de duas telas de erro para a mesma operação.
--
-- Cada recusa é conferida nos dois eixos, como nos outros arquivos: o `sqlstate` `PGRST`
-- e o envelope inteiro, que fixa `code` e `details`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(16);

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

-- ── O cenário ──────────────────────────────────────────────────────────────────
--
--   Zeca  contratante, administrador do Bar do Zeca
--   Nara  contratante de outra casa — é ela que prova o 403
--   Téo   profissional — prova que o perfil errado é recusado
--
-- Prefixo `a4`, que não existe em `cenarios.sql` nem nos outros arquivos de teste.

insert into privado.ambiente (id, eh_teste) values (true, true);
set local frila.agora = '2026-12-01 09:00:00+00';

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('a4000000-0000-4000-8000-000000000001','contratante', 'Zeca','+5561966660001','zeca@rep.test','1979-01-01','2026-09-22', privado.agora()),
  ('a4000000-0000-4000-8000-000000000002','contratante', 'Nara','+5561966660002','nara@rep.test','1981-01-01','2026-09-22', privado.agora()),
  ('a4000000-0000-4000-8000-000000000003','profissional','Téo', '+5561966660003','teo@rep.test', '1994-01-01','2026-09-22', privado.agora()),
  ('a4000000-0000-4000-8000-000000000004','contratante', 'Ivo', '+5561966660004','ivo@rep.test', '1988-01-01','2026-09-22', privado.agora());

insert into public.profissional (usuario_id, ponto_base)
values ('a4000000-0000-4000-8000-000000000003','POINT(-47.88 -15.79)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('a4000000-0000-4000-8000-000000000010','Bar do Zeca','33014556000196','food_service','CLN 305',
   'POINT(-47.8830 -15.7950)'::extensions.geography),
  ('a4000000-0000-4000-8000-000000000011','Casa da Nara','61695227000193','evento','SIA',
   'POINT(-47.9 -15.8)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('a4000000-0000-4000-8000-000000000001','a4000000-0000-4000-8000-000000000010','administrador'),
  ('a4000000-0000-4000-8000-000000000004','a4000000-0000-4000-8000-000000000010','operador'),
  ('a4000000-0000-4000-8000-000000000002','a4000000-0000-4000-8000-000000000011','administrador');

create temp table funcao_rep as select id from public.funcao where nome = 'garçom';

-- A vaga de origem nasce pela RPC, e não por insert: assim ela tem exatamente o que
-- `publicar_vaga` grava, inclusive os campos opcionais que a cópia precisa carregar.
create temp table origem as
  select (pg_temp.como('a4000000-0000-4000-8000-000000000001', format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2026-12-04 21:00:00+00'::timestamptz, '2026-12-05 03:00:00+00'::timestamptz,
         'CLN 305, Asa Norte', '{"latitude":-15.7950,"longitude":-47.8830}'::jsonb,
         17000::bigint, 2, true, true, false, 'Gerente Zeca',
         'urgencia'::public.modo_preenchimento, %L::uuid,
         'camisa preta', true, 'entrar pela porta dos fundos', 240) $$,
    'a4000000-0000-4000-8000-000000000010', (select id from funcao_rep),
    gen_random_uuid()))->>'vaga_id')::uuid as id;

-- ── As recusas, que o contrato manda ser as mesmas de publicar_vaga ───────────

select throws_ok(
  format($$ select public.republicar_vaga(%L::uuid,
             '2026-12-11 21:00:00+00'::timestamptz, '2026-12-12 03:00:00+00'::timestamptz,
             %L::uuid) $$, (select id from origem), gen_random_uuid()),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não se republica');

select throws_ok(
  format($$ select pg_temp.como('a4000000-0000-4000-8000-000000000003', format(
             'select public.republicar_vaga(%%L::uuid, %%L::timestamptz, %%L::timestamptz, %%L::uuid)',
             %L, '2026-12-11 21:00:00+00', '2026-12-12 03:00:00+00', %L)) $$,
         (select id from origem), gen_random_uuid()),
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'RN25: profissional não republica vaga — a mesma recusa de publicar_vaga');

select throws_ok(
  format($$ select pg_temp.como('a4000000-0000-4000-8000-000000000002', format(
             'select public.republicar_vaga(%%L::uuid, %%L::timestamptz, %%L::timestamptz, %%L::uuid)',
             %L, '2026-12-11 21:00:00+00', '2026-12-12 03:00:00+00', %L)) $$,
         (select id from origem), gen_random_uuid()),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'contratante de outro estabelecimento recebe 403, e não 404: a vaga existe e não é dele');

select throws_ok(
  format($$ select pg_temp.como('a4000000-0000-4000-8000-000000000001', format(
             'select public.republicar_vaga(%%L::uuid, %%L::timestamptz, %%L::timestamptz, %%L::uuid)',
             %L, '2026-12-11 21:00:00+00', '2026-12-12 03:00:00+00', %L)) $$,
         'a4000000-0000-4000-8000-0000000000ff', gen_random_uuid()),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'vaga de origem que não existe é 404 nao_encontrado');

select throws_ok(
  $$ select pg_temp.como('a4000000-0000-4000-8000-000000000001',
       'select public.republicar_vaga(null::uuid, ''2026-12-11 21:00:00+00''::timestamptz, ''2026-12-12 03:00:00+00''::timestamptz, gen_random_uuid())') $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "vaga_id", "hint" : null}',
  'vaga_id ausente é campo faltando, e não vaga alheia');

-- O fim antes do início é recusa de `publicar_vaga`, e tem de chegar igual aqui.
select throws_ok(
  format($$ select pg_temp.como('a4000000-0000-4000-8000-000000000001', format(
             'select public.republicar_vaga(%%L::uuid, %%L::timestamptz, %%L::timestamptz, %%L::uuid)',
             %L, '2026-12-12 03:00:00+00', '2026-12-11 21:00:00+00', %L)) $$,
         (select id from origem), gen_random_uuid()),
  'PGRST',
  '{"code" : "horario_invalido", "message" : "horario_invalido", "details" : null, "hint" : null}',
  'fim antes do início é horario_invalido — a recusa vem de publicar_vaga, não de uma cópia dela');

-- Republicar para o passado também: a data nova passa pela mesma peneira.
select throws_ok(
  format($$ select pg_temp.como('a4000000-0000-4000-8000-000000000001', format(
             'select public.republicar_vaga(%%L::uuid, %%L::timestamptz, %%L::timestamptz, %%L::uuid)',
             %L, '2026-11-01 21:00:00+00', '2026-11-02 03:00:00+00', %L)) $$,
         (select id from origem), gen_random_uuid()),
  'PGRST',
  '{"code" : "horario_invalido", "message" : "horario_invalido", "details" : null, "hint" : null}',
  'e republicar para o passado é recusado pelo relógio do produto');

-- ── A cópia ───────────────────────────────────────────────────────────────────

create temp table chave_nova as select gen_random_uuid() as v;

create temp table nova as
  select (pg_temp.como('a4000000-0000-4000-8000-000000000001', format(
    $$ select public.republicar_vaga(%L::uuid, %L::timestamptz, %L::timestamptz, %L::uuid) $$,
    (select id from origem), '2026-12-11 21:00:00+00', '2026-12-12 03:00:00+00',
    (select v from chave_nova)))->>'vaga_id')::uuid as id;

select isnt((select id from nova), null, 'a republicação devolve o id da vaga nova');

select isnt((select id from nova), (select id from origem),
  'e é uma vaga nova, não a de origem alterada');

-- O coração do cartão: tudo igual menos o que o contrato deixa mudar. Comparar coluna a
-- coluna à mão envelheceria mal — coluna nova em `vaga` passaria despercebida. Comparar
-- a linha inteira menos as exceções declaradas faz o teste reclamar sozinho.
select is(
  (select to_jsonb(v) - 'id' - 'inicio_em' - 'fim_em' - 'estado'
                      - 'publicado_em' - 'chave_cliente' - 'publicado_por'
     from public.vaga v where v.id = (select id from nova)),
  (select to_jsonb(v) - 'id' - 'inicio_em' - 'fim_em' - 'estado'
                      - 'publicado_em' - 'chave_cliente' - 'publicado_por'
     from public.vaga v where v.id = (select id from origem)),
  'RF05: todo o resto da vaga é cópia fiel — inclusive traje, rateio, observações e o alerta');

-- `publicado_por` fica **fora** da comparação acima de propósito: ele não é campo copiado,
-- é quem republicou. RF04 pergunta quem publicou, e a resposta certa é o Ivo, não o Zeca.
-- Se ele entrasse na comparação, o teste passaria por acidente — as duas chamadas acima
-- são do mesmo membro.
create temp table pelo_ivo as
  select (pg_temp.como('a4000000-0000-4000-8000-000000000004', format(
    $$ select public.republicar_vaga(%L::uuid, %L::timestamptz, %L::timestamptz, %L::uuid) $$,
    (select id from origem), '2026-12-18 21:00:00+00', '2026-12-19 03:00:00+00',
    gen_random_uuid()))->>'vaga_id')::uuid as id;

select is(
  (select v.publicado_por from public.vaga v where v.id = (select id from pelo_ivo)),
  'a4000000-0000-4000-8000-000000000004'::uuid,
  'RF04: publicado_por é quem republicou, e não quem publicou a vaga de origem');

select is(
  (select jsonb_build_array(v.inicio_em, v.fim_em) from public.vaga v where v.id = (select id from nova)),
  jsonb_build_array('2026-12-11 21:00:00+00'::timestamptz, '2026-12-12 03:00:00+00'::timestamptz),
  'e só a data e o horário mudaram, para os que foram pedidos');

select is(
  (select count(*)::int from public.posicao p where p.vaga_id = (select id from nova)),
  2,
  'RN03: a vaga nova nasce com uma posição por unidade copiada, todas abertas');

select is(
  (select count(*)::int from pgmq.q_despacho q
    where (q.message->>'vaga_id')::uuid = (select id from nova)),
  1,
  'e a republicação enfileira o despacho, como qualquer publicação');

-- ── A chave, que é o que torna o reenvio seguro ───────────────────────────────

select is(
  (pg_temp.como('a4000000-0000-4000-8000-000000000001', format(
    $$ select public.republicar_vaga(%L::uuid, %L::timestamptz, %L::timestamptz, %L::uuid) $$,
    (select id from origem), '2026-12-11 21:00:00+00', '2026-12-12 03:00:00+00',
    (select v from chave_nova)))->>'vaga_id')::uuid,
  (select id from nova),
  'RF04: a mesma chave devolve a vaga que já existe, e não cria a segunda');

select is(
  (select count(*)::int from public.vaga v
    where v.estabelecimento_id = 'a4000000-0000-4000-8000-000000000010'),
  3,
  'e a casa fica com três vagas: a de origem, a republicada pelo Zeca e a do Ivo');

select * from finish();
rollback;
