-- 815_chamada_conta_nova.sql
--
-- RN43 · segurança da chamada: antes do aceite, o profissional vê "Conta nova, sem turnos"
-- quando a casa não tem nenhum turno cumprido e verificado (`detalhe_chamada.conta_nova`,
-- 20261107370000). Achado A6 da varredura final da 1.1: a regra existia no banco e no iOS,
-- sem pgTAP. Cenário do 803 (casa CPF, A na equipe de confiança), sem turno nenhum na casa.
begin;
set local search_path = public, extensions;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-815';
select plan(4);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
-- 'ok' ou code[:details] do envelope de public.erro.
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
create function pg_temp.nova(prof uuid, chave uuid default gen_random_uuid(), inicio text default '2026-11-08 18:00+00', extra text default '')
returns text language sql as $$
  select format($a$ select public.chamar_profissional(chave => %L, profissional_id => %L,
    estabelecimento_id => 'c8030000-0000-4000-8000-0000000000e1', funcao_id => %L, inicio_em => %L,
    fim_em => %L::timestamptz + interval '5 hours', local => 'CLN 201', regiao_administrativa => 'Plano Piloto',
    ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 15000, inclui_refeicao => true,
    inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Maitre'%s) $a$,
    chave, prof, (select id from public.funcao where nome = 'garçom'), inicio, inicio, extra) $$;

insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c8030000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '@t803.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 5) n;
select pg_temp.como(('c8030000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195555803%s', '1990-01-01', '2026-09-22') $$,
  case when n in (1, 5) then 'contratante' else 'profissional' end, n, n)) from generate_series(1, 5) n;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c8030000-0000-4000-8000-0000000000e1', 'Casa 803', '80312345666', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c8030000-0000-4000-8000-000000000001', 'c8030000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (usuario_id, ponto_base)
select ('c8030000-0000-4000-8000-00000000000' || n)::uuid, 'POINT(-47.8822 -15.7800)'::extensions.geography
  from generate_series(2, 4) n;
create temp table ids as select
  (select id from public.profissional where usuario_id = 'c8030000-0000-4000-8000-000000000002') a,
  (select id from public.profissional where usuario_id = 'c8030000-0000-4000-8000-000000000003') b,
  (select id from public.profissional where usuario_id = 'c8030000-0000-4000-8000-000000000004') c;
insert into public.profissional_funcao select p, (select id from public.funcao where nome = 'garçom')
  from ids, unnest(array[a, b, c]) p;
insert into public.equipe_confianca (estabelecimento_id, profissional_id) select 'c8030000-0000-4000-8000-0000000000e1', a from ids;

update privado.recurso set ligado = true where chave = 'chamada_direta';
-- 0.2.66 (20261108160000): só se chama quem tem aparelho na versão mínima de chamada_direta.
-- Este arquivo mede conta_nova com o portão satisfeito; o portão em si é o 830.
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do nothing;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select p.usuario_id, 'tok-teste-' || p.usuario_id, 'ios', '1.2.0'
  from public.profissional p where p.usuario_id::text like 'c8030000-%'
on conflict (token_fcm) do nothing;
create temp table ch as select pg_temp.como('c8030000-0000-4000-8000-000000000001',
  pg_temp.nova((select a from ids), 'c8150000-0000-4000-8000-0000000000c1')) j;
create function pg_temp.conta_nova() returns boolean language sql as $$
  select (pg_temp.como('c8030000-0000-4000-8000-000000000002',
    format('select public.detalhe_chamada(%L)', (select j->>'id' from ch)))->>'conta_nova')::boolean $$;

select is(pg_temp.conta_nova(), true, 'RN43: casa sem turno nenhum é conta nova');

-- Um turno cumprido, mas ainda sem presença verificada, não conta.
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_por, publicado_em)
values ('c8150000-0000-4000-8000-0000000000f1', 'c8030000-0000-4000-8000-0000000000e1',
  (select id from public.funcao where nome = 'garçom'), '2026-11-01 18:00+00', '2026-11-01 23:00+00', 'CLN 201',
  'POINT(-47.8822 -15.7942)'::extensions.geography, 12000, 1, true, false, false, 'Maitre', 'urgencia',
  gen_random_uuid(), 'c8030000-0000-4000-8000-000000000001', '2026-10-31 12:00+00');
insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select 'c8150000-0000-4000-8000-0000000000f2', 'c8150000-0000-4000-8000-0000000000f1', 'cumprida', c,
       '2026-11-01 10:00+00', '2026-11-01 18:00+00', '2026-11-01 23:00+00' from ids;
insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('c8150000-0000-4000-8000-0000000000f2', '2026-11-01 18:00+00', 'manual', null, 'nao_verificado', 12000);
select is(pg_temp.conta_nova(), true, 'RN43: turno cumprido sem presença verificada não tira o selo');

update public.turno set verificacao = 'verificado', checkin_tipo = 'geolocalizado', checkin_distancia_m = 50
 where posicao_id = 'c8150000-0000-4000-8000-0000000000f2';
select is(pg_temp.conta_nova(), false, 'RN43: o primeiro turno cumprido e verificado tira o selo');

-- O campo faz parte da resposta (o app lê `contaNova`).
select ok((pg_temp.como('c8030000-0000-4000-8000-000000000002',
  format('select public.detalhe_chamada(%L)', (select j->>'id' from ch))) ? 'conta_nova'), 'conta_nova presente na resposta do detalhe');

select * from finish();
rollback;
