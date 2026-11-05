-- 797_listar_bloqueios_e_desbloquear.sql
--
-- Listar e desfazer bloqueios (RF26, RN10, UC17). Cartão Y18NMyPo · decisão A8 da PO ·
-- contrato 0.2.51. Ids próprios, começando em `c7970000`.
--
-- O que este arquivo prova, e por que cada grupo existe:
--   1. A lista traz o par `alvo_tipo` + `alvo_id` do `PerfilPublico` e o nome público, e
--      NÃO traz `usuario_id` (RN10). Sem bloqueio, lista vazia e não erro.
--   2. Só aparece o que o chamador bloqueou: bloqueio que a outra parte criou contra ele
--      não entra, senão a tela revelaria quem o bloqueou.
--   3. O desbloqueio **restaura visibilidade de verdade**: a vaga volta a `vagas_abertas` e
--      ao `detalhe_vaga`, e o profissional volta a `privado.elegiveis`. Medir só a tabela
--      `bloqueio` provaria que a linha saiu, não que o produto voltou a funcionar.
--   4. Membro desbloqueando profissional desfaz para a CASA INTEIRA, inclusive o bloqueio
--      que um colega criou. É a assimetria de `bloquear`, e errá-la produz o pior defeito
--      possível: a tela diz que desfez e o despacho continua cortando.
--   5. Idempotência e as recusas: 401, 403 de conta suspensa, 404 e os dois 422.
--
-- Cenário: uma casa com dois membros (dono e colega), dois profissionais e uma vaga.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-05 12:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-797';

select plan(33);

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, privado.agora(), '{"provider":"email"}'::jsonb, '{}'::jsonb,
          privado.agora(), privado.agora(), false, false)
  on conflict (id) do nothing;
end $$;

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

-- ── O cenário ─────────────────────────────────────────────────────────────────

select pg_temp.autenticar('c7970000-0000-4000-8000-000000000001', 'dono797@t.test');
select pg_temp.autenticar('c7970000-0000-4000-8000-000000000002', 'colega797@t.test');
select pg_temp.autenticar('c7970000-0000-4000-8000-000000000003', 'prof797a@t.test');
select pg_temp.autenticar('c7970000-0000-4000-8000-000000000004', 'prof797b@t.test');

select pg_temp.como('c7970000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('contratante','Dona da Casa','+5561955557971','1980-01-01','2026-09-22') $$);
select pg_temp.como('c7970000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('contratante','Colega da Casa','+5561955557972','1980-01-01','2026-09-22') $$);
select pg_temp.como('c7970000-0000-4000-8000-000000000003',
  $$ select public.criar_conta('profissional','Profissional A','+5561955557973','1995-01-01','2026-09-22') $$);
select pg_temp.como('c7970000-0000-4000-8000-000000000004',
  $$ select public.criar_conta('profissional','Profissional B','+5561955557974','1995-01-01','2026-09-22') $$);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c7970000-0000-4000-8000-0000000000e1', 'Bar do Teste 797', '11222333000197', 'food_service',
        'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c7970000-0000-4000-8000-000000000001', 'c7970000-0000-4000-8000-0000000000e1', 'administrador'),
  ('c7970000-0000-4000-8000-000000000002', 'c7970000-0000-4000-8000-0000000000e1', 'operador');

insert into public.profissional (usuario_id, ponto_base) values
  ('c7970000-0000-4000-8000-000000000003', 'POINT(-47.8822 -15.7800)'::extensions.geography),
  ('c7970000-0000-4000-8000-000000000004', 'POINT(-47.8822 -15.7801)'::extensions.geography);

create temp table ids as
select (select p.id from public.profissional p where p.usuario_id = 'c7970000-0000-4000-8000-000000000003') as prof_a,
       (select p.id from public.profissional p where p.usuario_id = 'c7970000-0000-4000-8000-000000000004') as prof_b,
       'c7970000-0000-4000-8000-0000000000e1'::uuid as casa,
       (select id from public.funcao where nome = 'garçom') as funcao;

insert into public.profissional_funcao (profissional_id, funcao_id)
select prof_a, funcao from ids union all select prof_b, funcao from ids;

insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select prof_a, d::smallint, '00:00'::time, '23:59:59'::time from ids, generate_series(0, 6) d
union all
select prof_b, d::smallint, '00:00'::time, '23:59:59'::time from ids, generate_series(0, 6) d;

create temp table vaga as
select (pg_temp.como('c7970000-0000-4000-8000-000000000001', format(
  $$ select public.publicar_vaga(%L::uuid, %L::uuid,
       '2026-11-07 18:00:00+00'::timestamptz, '2026-11-07 23:00:00+00'::timestamptz,
       'CLN 201','{"latitude":-15.7942,"longitude":-47.8822}'::jsonb,
       12000::bigint, 2, true, false, false, 'Maitre',
       'urgencia'::public.modo_preenchimento, %L::uuid) $$,
  (select casa from ids), (select funcao from ids), gen_random_uuid()))->>'vaga_id')::uuid as id;

-- ── 1. Lista vazia ────────────────────────────────────────────────────────────

select is(
  pg_temp.como('c7970000-0000-4000-8000-000000000003', $$ select public.listar_bloqueios() $$),
  '[]'::jsonb,
  'sem bloqueio nenhum, a lista é vazia e não erro');

select is(
  pg_temp.como('c7970000-0000-4000-8000-000000000001', $$ select public.listar_bloqueios() $$),
  '[]'::jsonb,
  'o mesmo do lado do contratante');

-- ── 2. O profissional bloqueia a casa ─────────────────────────────────────────

select lives_ok(
  $$ select pg_temp.como('c7970000-0000-4000-8000-000000000003', format(
       $x$ select public.bloquear('estabelecimento', %L::uuid) $x$, (select casa from ids))) $$,
  'o profissional bloqueia o estabelecimento');

create temp table lista_prof as
select pg_temp.como('c7970000-0000-4000-8000-000000000003', $$ select public.listar_bloqueios() $$) as j;

select is(
  (select jsonb_array_length(j) from lista_prof),
  1,
  'as duas linhas (uma por membro) viram UM item de casa na lista');

select is(
  (select j->0->>'alvo_tipo' from lista_prof),
  'estabelecimento',
  'o alvo_tipo é estabelecimento');

select is(
  (select (j->0->>'alvo_id')::uuid from lista_prof),
  (select casa from ids),
  'o alvo_id é o id do estabelecimento, o mesmo que bloquear recebe');

select is(
  (select j->0->>'nome' from lista_prof),
  'Bar do Teste 797',
  'o nome é o nome público da casa');

select ok(
  (select j->0 ? 'criado_em' from lista_prof),
  'o item traz criado_em');

select is(
  (select count(*)::int from jsonb_object_keys((select j->0 from lista_prof))),
  4,
  'exatamente as quatro chaves do ItemBloqueio, e nenhuma a mais');

select ok(
  (select j::text not like '%usuario_id%'
          and j::text not like '%c7970000-0000-4000-8000-000000000001%'
          and j::text not like '%c7970000-0000-4000-8000-000000000002%'
     from lista_prof),
  'RN10: a lista não traz usuario_id nem id de conta de membro nenhum');

-- ── 3. Um bloqueio só aparece para quem o criou ───────────────────────────────

select is(
  pg_temp.como('c7970000-0000-4000-8000-000000000001', $$ select public.listar_bloqueios() $$),
  '[]'::jsonb,
  'a casa bloqueada não vê o bloqueio na própria lista: a tela não revela quem bloqueou');

-- ── 4. O bloqueio tira a vaga de vista, e o desbloqueio devolve ───────────────

-- A medida de visibilidade aqui é `privado.elegiveis`, e não a contagem de
-- `vagas_abertas`: é por `elegiveis` que o despacho decide quem recebe notificação, que é
-- o efeito que a RF26 corta. Contar itens de `vagas_abertas` mediria também o formato da
-- resposta, e o formato não é o assunto deste arquivo.
select is(
  (select count(*)::int from privado.elegiveis((select id from vaga))
    where profissional_id = (select prof_a from ids)),
  0,
  'bloqueado, o profissional A sai dos elegíveis da vaga da casa');

select lives_ok(
  $$ select pg_temp.como('c7970000-0000-4000-8000-000000000003', format(
       $x$ select public.desbloquear('estabelecimento', %L::uuid) $x$, (select casa from ids))) $$,
  'o profissional desbloqueia o estabelecimento');

-- A prova que importa: não é a linha ter saído da tabela, é a vaga ter voltado.
select is(
  (select count(*)::int from privado.elegiveis((select id from vaga))
    where profissional_id = (select prof_a from ids)),
  1,
  'depois do desbloqueio ele volta aos elegíveis: a notificação de vaga volta a alcançá-lo');

select lives_ok(
  format($$ select pg_temp.como('c7970000-0000-4000-8000-000000000003', format(
    $x$ select public.detalhe_vaga(%%L::uuid) $x$, %L::uuid)) $$, (select id from vaga)),
  'e o detalhe da vaga volta a abrir para ele');

select is(
  pg_temp.como('c7970000-0000-4000-8000-000000000003', $$ select public.listar_bloqueios() $$),
  '[]'::jsonb,
  'a lista dele fica vazia de novo');

select is(
  (select count(*)::int from public.bloqueio b
    where b.autor_id = 'c7970000-0000-4000-8000-000000000003'),
  0,
  'as duas linhas (uma por membro) saíram juntas, e não só a do dono');

-- ── 5. Idempotência ───────────────────────────────────────────────────────────

create temp table repetido as
select pg_temp.como('c7970000-0000-4000-8000-000000000003', format(
  $$ select public.desbloquear('estabelecimento', %L::uuid) $$, (select casa from ids))) as j;

select is(
  (select (j->>'alvo_id')::uuid from repetido),
  (select casa from ids),
  'desbloquear quem já não está bloqueado devolve 200 com o mesmo par');

select is(
  (select (j->>'criado_em')::timestamptz from repetido),
  '2026-11-05 12:00:00+00'::timestamptz,
  'e o criado_em passa a ser o instante da chamada, como o contrato declara');

-- ── 6. O lado da casa desfaz para a casa inteira ──────────────────────────────

-- O COLEGA bloqueia, e quem desbloqueia é a DONA. É o caso que separa "apagou a minha
-- linha" de "desfez para a casa": `privado.bloqueado_com_estabelecimento` olha qualquer
-- membro, então a linha do colega bastaria para manter a vaga invisível.
select lives_ok(
  $$ select pg_temp.como('c7970000-0000-4000-8000-000000000002', format(
       $x$ select public.bloquear('profissional', %L::uuid) $x$, (select prof_b from ids))) $$,
  'o colega bloqueia o Profissional B');

select is(
  (select count(*)::int from privado.elegiveis((select id from vaga))
    where profissional_id = (select prof_b from ids)),
  0,
  'bloqueado pelo colega, o Profissional B sai dos elegíveis da vaga da casa');

create temp table lista_casa as
select pg_temp.como('c7970000-0000-4000-8000-000000000002', $$ select public.listar_bloqueios() $$) as j;

select is(
  (select j->0->>'nome' from lista_casa),
  'Profissional B',
  'a lista do colega mostra o nome público do profissional');

select is(
  (select (j->0->>'alvo_id')::uuid from lista_casa),
  (select prof_b from ids),
  'e o alvo_id é o id do perfil do profissional, não a conta dele');

select lives_ok(
  $$ select pg_temp.como('c7970000-0000-4000-8000-000000000001', format(
       $x$ select public.desbloquear('profissional', %L::uuid) $x$, (select prof_b from ids))) $$,
  'a dona desbloqueia o profissional que o COLEGA havia bloqueado');

select is(
  (select count(*)::int from privado.elegiveis((select id from vaga))
    where profissional_id = (select prof_b from ids)),
  1,
  'o profissional volta aos elegíveis: o desbloqueio valeu para a casa inteira');

select is(
  pg_temp.como('c7970000-0000-4000-8000-000000000002', $$ select public.listar_bloqueios() $$),
  '[]'::jsonb,
  'e a lista do colega esvazia, mesmo sem ele ter pedido nada');

-- ── 7. Recusas ────────────────────────────────────────────────────────────────

select throws_ok(
  $$ select public.listar_bloqueios() $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token, listar_bloqueios é 401');

select throws_ok(
  format($$ select pg_temp.como('c7970000-0000-4000-8000-000000000003',
    $x$ select public.desbloquear('profissional', %L::uuid) $x$) $$, (select prof_b from ids)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "alvo_tipo", "hint" : null}',
  'profissional desbloqueando profissional é 422 campo_invalido: o perfil decide o alvo');

select throws_ok(
  $$ select pg_temp.como('c7970000-0000-4000-8000-000000000003',
       $x$ select public.desbloquear(null, '00000000-0000-4000-8000-000000000000'::uuid) $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "alvo_tipo", "hint" : null}',
  'alvo_tipo nulo é 422 campo_obrigatorio nomeando o campo');

select throws_ok(
  $$ select pg_temp.como('c7970000-0000-4000-8000-000000000003',
       $x$ select public.desbloquear('estabelecimento', null) $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "alvo_id", "hint" : null}',
  'alvo_id nulo é 422 campo_obrigatorio nomeando o campo');

select throws_ok(
  $$ select pg_temp.como('c7970000-0000-4000-8000-000000000003',
       $x$ select public.desbloquear('estabelecimento', '00000000-0000-4000-8000-0000000000ff'::uuid) $x$) $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'estabelecimento inexistente é 404, e não 200 por idempotência: o alvo não existe');

-- Conta suspensa não desbloqueia: a RN13 exige conta ativa para a ação, e o 403 vem com o
-- motivo no details.
update public.usuario set estado = 'suspensa'
 where id = 'c7970000-0000-4000-8000-000000000003';

select throws_ok(
  format($$ select pg_temp.como('c7970000-0000-4000-8000-000000000003',
    $x$ select public.desbloquear('estabelecimento', %L::uuid) $x$) $$, (select casa from ids)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : "conta_suspensa", "hint" : null}',
  'conta suspensa recebe 403 sem_permissao com details conta_suspensa');

select throws_ok(
  $$ select pg_temp.como('c7970000-0000-4000-8000-000000000003', $$ || quote_literal('select public.listar_bloqueios()') || $$) $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : "conta_suspensa", "hint" : null}',
  'e a listagem também, porque a tela de bloqueados é da conta ativa');

select * from finish();

rollback;
