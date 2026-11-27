-- 923_chamar_profissional_chave_por_casa.sql
--
-- K9VcaypQ: a chave de idempotência de `public.chamar_profissional` é POR CASA (`c.estabelecimento_id = v_estab and c.chave = ...`, nas duas buscas
-- da função; a unique é `(estabelecimento_id, chave)`). Sem o filtro da casa, a casa B que gerasse o mesmo uuid receberia a chamada da casa A
-- (outro profissional, outra diária) em vez da sua. Nenhum teste reusava a mesma chave em duas casas.
--   A  a casa 1 chama o profissional A com a chave K; a casa 2 reusa K para o profissional B com outra diária: a casa 2 recebe uma chamada NOVA, dela
--   B  a chamada da casa 1 não mudou; há uma chamada com a chave K por casa
--   C  o reenvio da chave dentro de cada casa continua devolvendo a chamada daquela casa (idempotência intacta)
-- Fixtures de usuário e casas copiados do 808 (as duas casas têm a mesma equipe). Ids próprios (`c9230000`). Só dados sintéticos.

begin;
update privado.recurso set ligado = false where chave in ('chamada_direta', 'perfil_rico');
update privado.configuracao_app set foto_de_perfil = false;
delete from privado.recurso_versao_minima where recurso in ('foto_de_perfil', 'chamada_direta', 'perfil_rico');

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-923';

select plan(16);

-- ── Helpers de execução e classificação de retorno ───────────────────────────
create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

create function pg_temp.r(conta uuid, sql text) returns text language plpgsql as $$
declare m text;
begin
  if conta is null then execute sql; else perform pg_temp.como(conta, sql); end if;
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text;
  reset role; execute 'reset request.jwt.claims';
  return case when m ~ '^\s*\{' then (m::jsonb->>'code') || coalesce(':' || (m::jsonb->>'details'), '') else m end;
end $$;

-- ── Fixtures de usuários, estabelecimentos e funções ─────────────────────────
-- u1: contratante dono Casa 1
-- u2: outro contratante (não membro)
-- u3: profissional A (equipe confiança)
-- u4: profissional B (equipe confiança)
-- u5: profissional C (equipe confiança)
-- u6: contratante Casa 2
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c9230000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '@t923.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 6) n;

select pg_temp.como(('c9230000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195555923%s', '1990-01-01', '2026-09-22') $$,
  case when n in (1, 2, 6) then 'contratante' else 'profissional' end, n, n)) from generate_series(1, 6) n;

-- Estabelecimento 1 (Casa 1 - CNPJ)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c9230000-0000-4000-8000-0000000000e1', 'Restaurante 923', '92312345000101', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c9230000-0000-4000-8000-000000000001', 'c9230000-0000-4000-8000-0000000000e1', 'administrador');

-- Estabelecimento 2 (Casa 2 - CNPJ)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c9230000-0000-4000-8000-0000000000e2', 'Bar 923', '92312345000102', 'food_service', 'CLN 202',
        'POINT(-47.8825 -15.7945)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c9230000-0000-4000-8000-000000000006', 'c9230000-0000-4000-8000-0000000000e2', 'administrador');

-- Profissionais
insert into public.profissional (usuario_id, ponto_base)
select ('c9230000-0000-4000-8000-00000000000' || n)::uuid, 'POINT(-47.8822 -15.7800)'::extensions.geography
  from generate_series(3, 5) n;

create temp table prof_ids as select
  (select id from public.profissional where usuario_id = 'c9230000-0000-4000-8000-000000000003') as a,
  (select id from public.profissional where usuario_id = 'c9230000-0000-4000-8000-000000000004') as b,
  (select id from public.profissional where usuario_id = 'c9230000-0000-4000-8000-000000000005') as c;

insert into public.profissional_funcao select p, (select id from public.funcao where nome = 'garçom')
  from prof_ids, unnest(array[a, b, c]) p;

insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c9230000-0000-4000-8000-0000000000e1', p from prof_ids, unnest(array[a, b, c]) p;

insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c9230000-0000-4000-8000-0000000000e2', p from prof_ids, unnest(array[a, b, c]) p;

-- Histórico prévio de turno cumprido e verificado para Casa 1 (CD-C14 / B5d)
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, traje, estado, modo, publicado_em, chave_cliente, publicado_por)
values ('c9230000-0000-4000-8000-000000000010', 'c9230000-0000-4000-8000-0000000000e1', (select id from public.funcao where nome = 'garçom'),
        '2026-10-01 18:00+00', '2026-10-01 23:00+00', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 15000, 1, true, false, false, 'Carlos', 'social', 'encerrada', 'urgencia', '2026-09-30 10:00+00', gen_random_uuid(), 'c9230000-0000-4000-8000-000000000001');

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values ('c9230000-0000-4000-8000-000000000020', 'c9230000-0000-4000-8000-000000000010', 'cumprida', (select a from prof_ids), '2026-10-01 17:00+00', '2026-10-01 18:00+00', '2026-10-01 23:00+00');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkout_em, verificacao, valor_acordado_centavos)
values ('c9230000-0000-4000-8000-000000000030', 'c9230000-0000-4000-8000-000000000020', '2026-10-01 18:00+00', 'geolocalizado', 50, '2026-10-01 23:00+00', 'verificado', 15000);

-- Liga o interruptor para os demais testes
update privado.recurso set ligado = true where chave = 'chamada_direta';
-- 0.2.66 (20261108160000): só se chama quem tem aparelho na versão mínima de chamada_direta.
-- Este arquivo mede a chamada com o portão satisfeito; o portão em si é o 830.
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do nothing;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select p.usuario_id, 'tok-teste-' || p.usuario_id, 'ios', '1.2.0'
  from public.profissional p where p.usuario_id::text like 'c9230000-%'
on conflict (token_fcm) do nothing;


create function pg_temp.chamar(conta text, estab text, prof uuid, valor int, chave uuid, dia text) returns jsonb language sql as $$
  select pg_temp.como(conta::uuid, format(
    $x$ select public.chamar_profissional(chave => %L, profissional_id => %L, estabelecimento_id => %L,
       funcao_id => (select id from public.funcao where nome = 'garçom'),
       inicio_em => %L, fim_em => %L, local => 'CLN 201 Bloco A',
       regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => %s,
       inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Carlos',
       recado => 'Chegar 10 min antes') $x$, chave, prof, estab, dia || ' 18:00+00', dia || ' 23:00+00', valor))
$$;

create temp table k as select '92300000-0000-4000-8000-0000000000aa'::uuid as chave;

-- A casa 1 chama o profissional A, diária de 160, dia 8.
create temp table c1 as select pg_temp.chamar('c9230000-0000-4000-8000-000000000001', 'c9230000-0000-4000-8000-0000000000e1',
  (select a from prof_ids), 16000, (select chave from k), '2026-11-08') as j;
select ok((select j ? 'id' from c1), '0 a casa 1 chama com a chave K');

-- A casa 2 reusa a MESMA chave K, para o profissional B, diária de 210, dia 9.
create temp table c2 as select pg_temp.chamar('c9230000-0000-4000-8000-000000000006', 'c9230000-0000-4000-8000-0000000000e2',
  (select b from prof_ids), 21000, (select chave from k), '2026-11-09') as j;

-- ── A. A casa 2 recebe uma chamada nova, dela ─────────────────────────────────

select ok((select j ? 'id' from c2), 'A1 a casa 2 recebe uma chamada (não um erro)');
select isnt((select j->>'id' from c2), (select j->>'id' from c1), 'A2 e é uma chamada DIFERENTE da da casa 1');
select is((select j->>'estabelecimento_id' from c2), 'c9230000-0000-4000-8000-0000000000e2', 'A3 da casa 2');
select is((select j->>'profissional_id' from c2), (select b::text from prof_ids), 'A4 para o profissional que a casa 2 escolheu (B), não o da casa 1');
select is((select valor_centavos from public.vaga where id = (select (j->>'vaga_id')::uuid from c2)), 21000::bigint, 'A5 com a diária da casa 2 (210), não a da casa 1');
select is((select estabelecimento_id from public.vaga where id = (select (j->>'vaga_id')::uuid from c2)), 'c9230000-0000-4000-8000-0000000000e2'::uuid, 'A6 e a vaga direta dela é da casa 2');
select is((select inicio_em from public.vaga where id = (select (j->>'vaga_id')::uuid from c2)), '2026-11-09 18:00+00'::timestamptz, 'A7 no dia que a casa 2 pediu');

-- ── B. A casa 1 não mudou, e há uma chamada com a chave K por casa ───────────

select is((select profissional_id from public.chamada where id = (select (j->>'id')::uuid from c1)), (select a from prof_ids), 'B1 a chamada da casa 1 segue com o profissional A');
select is((select valor_centavos from public.vaga where id = (select (j->>'vaga_id')::uuid from c1)), 16000::bigint, 'B2 e com a diária da casa 1');
select is((select count(*)::int from public.chamada where chave = (select chave from k)), 2, 'B3 existem duas chamadas com a chave K, uma por casa');
select is((select count(distinct estabelecimento_id)::int from public.chamada where chave = (select chave from k)), 2, 'B4 de casas diferentes');

-- ── C. Dentro de cada casa a chave continua idempotente ───────────────────────

select is((pg_temp.chamar('c9230000-0000-4000-8000-000000000006', 'c9230000-0000-4000-8000-0000000000e2',
  (select b from prof_ids), 21000, (select chave from k), '2026-11-09'))->>'id', (select j->>'id' from c2), 'C1 o reenvio da casa 2 devolve a chamada da casa 2');
select is((pg_temp.chamar('c9230000-0000-4000-8000-000000000001', 'c9230000-0000-4000-8000-0000000000e1',
  (select a from prof_ids), 16000, (select chave from k), '2026-11-08'))->>'id', (select j->>'id' from c1), 'C2 o reenvio da casa 1 devolve a chamada da casa 1');
-- Reenvio com o corpo diferente: a chave manda, como no contrato (devolve o gravado).
select is((pg_temp.chamar('c9230000-0000-4000-8000-000000000006', 'c9230000-0000-4000-8000-0000000000e2',
  (select c from prof_ids), 99000, (select chave from k), '2026-11-10'))->>'profissional_id', (select b::text from prof_ids), 'C3 reenvio da casa 2 com outro corpo devolve o que ela gravou (profissional B)');
select is((select count(*)::int from public.chamada where chave = (select chave from k)), 2, 'C4 e nenhuma terceira chamada nasceu');

select * from finish();
rollback;
