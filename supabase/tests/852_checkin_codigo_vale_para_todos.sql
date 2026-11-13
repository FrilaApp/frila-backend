-- 852_checkin_codigo_vale_para_todos.sql
--
-- O check-in por código vale para TODOS os estabelecimentos (migração 20261112210000; decisão do Cauê,
-- 12/11/2026). A chave global manda; a lista por casa (privado.recurso_estabelecimento) não é mais lida.
-- Este teste NÃO liga a chave nem insere casa na lista: o estado de partida é o que a migração deixou.
-- Cobre:
--   1. A migração: chave ligada, nenhuma casa na lista, versão mínima do iOS em 1.2.0 e nada no Android;
--   2. recurso_ligado_para é true para qualquer casa (na lista ou não, e até para uma casa que não existe);
--   3. fazer_checkin do app 1.1 (150 m, sem sinais) numa casa FORA da lista: manual, pendente, código exigido;
--   4. gerar_codigo_checkin e validar_codigo_checkin funcionam numa casa FORA da lista (sem 403 recurso_desligado);
--   5. configuracao_do_app: ios 1.2.0 → true; ios 1.1 → false; android → false;
--   6. A volta: com a chave desligada, tudo recua (403 recurso_desligado; 150 m → geolocalizado e verificado);
--   7. A tabela da lista continua lá, comentada como "não é mais lida" (nada destrutivo).
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);
select plan(29);

create temp table ids as
select 'c8520000-0000-4000-8000-000000000001'::uuid as dono_a,
       'c8520000-0000-4000-8000-000000000002'::uuid as dono_b,
       'c8520000-0000-4000-8000-000000000021'::uuid as casa_a,
       'c8520000-0000-4000-8000-000000000022'::uuid as casa_b;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select u, 'contratante'::public.perfil_conta, 'Casa 852 ' || n, '+556199999852' || n, 'casa852-' || n || '@test.invalid',
       '1988-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids, lateral (values (dono_a, 1), (dono_b, 2)) v (u, n);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select c, 'Bar 852 ' || n, '8000000000085' || n, 'food_service'::public.tipo_estabelecimento, 'Endereço 852',
       'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids, lateral (values (casa_a, 1), (casa_b, 2)) v (c, n);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select u, c, 'administrador' from ids, lateral (values (dono_a, casa_a), (dono_b, casa_b)) v (u, c);

-- Turnos de teste
create temp table turnos (nome text primary key, turno uuid, usuario uuid, prof uuid);
create function pg_temp.novo_turno(nome text, casa uuid, inicio timestamptz default '2027-01-11 21:00:00+00') returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid(); v_prof uuid := gen_random_uuid();
  v_vaga uuid := gen_random_uuid(); v_pos  uuid := gen_random_uuid(); v_t uuid := gen_random_uuid();
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_user, 'profissional', 'Prof 852 ' || nome, '+5561999998520', nome || '@t852.invalid',
          '1992-01-01', '1.0', '2026-09-20 12:00:00-03');
  insert into public.profissional (id, usuario_id, ponto_base) values (v_prof, v_user, 'POINT(-47.8800 -15.7700)');
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
  values (v_vaga, casa, (select id from public.funcao limit 1),
          inicio, inicio + interval '5 hours', 'Local 852', 'POINT(-47.8800 -15.7700)',
          15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', inicio - interval '33 hours',
          gen_random_uuid(), 'c8520000-0000-4000-8000-000000000001');
  insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
  values (v_pos, v_vaga, 'confirmada', v_prof, inicio - interval '32 hours', inicio, inicio + interval '5 hours');
  insert into public.turno (id, posicao_id, valor_acordado_centavos) values (v_t, v_pos, 15000);
  insert into turnos values (nome, v_t, v_user, v_prof);
  return v_t;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  perform set_config('request.jwt.claims', jsonb_build_object('sub', conta, 'role', 'authenticated')::text, true);
  execute sql into r;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return r;
end $$;

create function pg_temp.t(nome text) returns uuid language sql as $$ select turno from turnos where turnos.nome = t.nome $$;
create function pg_temp.u(nome text) returns uuid language sql as $$ select usuario from turnos where turnos.nome = u.nome $$;

create function pg_temp.checkin(nome text, distancia integer, em timestamptz default privado.agora(), sinais jsonb default null) returns jsonb language sql as $$
  select pg_temp.como(pg_temp.u(nome),
                      format('select public.fazer_checkin(%L::uuid, %s, %L::timestamptz, %L::jsonb)',
                             pg_temp.t(nome), coalesce(distancia::text, 'null'), em, sinais))
$$;

create function pg_temp.gerar(dono uuid, turno uuid) returns jsonb language sql as $$
  select pg_temp.como(dono, format('select public.gerar_codigo_checkin(%L::uuid)', turno))
$$;

create function pg_temp.recusa_gerar(dono uuid, turno uuid) returns text language plpgsql as $$
begin
  perform pg_temp.gerar(dono, turno);
  return 'ok';
exception when sqlstate 'PGRST' then
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return (sqlerrm::jsonb->>'code');
end $$;

create function pg_temp.recusa_gerar_det(dono uuid, turno uuid) returns text language plpgsql as $$
begin
  perform pg_temp.gerar(dono, turno);
  return 'ok';
exception when sqlstate 'PGRST' then
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return (sqlerrm::jsonb->>'code') || ':' || coalesce(sqlerrm::jsonb->>'details', '');
end $$;

create function pg_temp.validar(nome text, codigo text, distancia integer) returns jsonb language sql as $$
  select pg_temp.como(pg_temp.u(nome),
                      format('select public.validar_codigo_checkin(%L::uuid, %L, %s)',
                             pg_temp.t(nome), codigo, coalesce(distancia::text, 'null')))
$$;

create function pg_temp.confirmar_manual(dono uuid, turno uuid) returns jsonb language sql as $$
  select pg_temp.como(dono, format('select public.confirmar_checkin_manual(%L::uuid)', turno))
$$;


create function pg_temp.config(plataforma text, versao text) returns jsonb language sql as $$
  select public.configuracao_do_app(plataforma, versao)->'recursos'->'checkin_por_codigo'
$$;

-- Nenhuma casa nesta massa está na lista: o teste não toca em privado.recurso_estabelecimento.

-- ── 1. O que a migração deixou ────────────────────────────────────────────────

select ok(privado.recurso_ligado('checkin_por_codigo'), '1.1 migração: a chave global checkin_por_codigo está ligada');
select is((select count(*)::int from privado.recurso_estabelecimento
            where estabelecimento_id in (select casa_a from ids union select casa_b from ids)), 0,
          '1.2 migração: nenhuma das casas do teste está na lista por casa');
select is((select versao_minima from privado.recurso_versao_minima
            where recurso = 'checkin_por_codigo' and plataforma = 'ios'), '1.2.0',
          '1.3 migração: versão mínima do iOS é 1.2.0');
select is((select count(*)::int from privado.recurso_versao_minima
            where recurso = 'checkin_por_codigo' and plataforma = 'android'), 0,
          '1.4 migração: nenhuma linha de versão mínima no Android (fora até ordem nova)');

-- ── 2. recurso_ligado_para olha só a chave global ─────────────────────────────

select ok(privado.recurso_ligado_para('checkin_por_codigo', (select casa_a from ids)),
          '2.1 recurso_ligado_para: true para a casa A, fora da lista');
select ok(privado.recurso_ligado_para('checkin_por_codigo', (select casa_b from ids)),
          '2.2 recurso_ligado_para: true para a casa B, fora da lista');
select ok(privado.recurso_ligado_para('checkin_por_codigo', gen_random_uuid()),
          '2.3 recurso_ligado_para: true até para um id que não é de casa nenhuma (o parâmetro não é lido)');
select ok(not privado.recurso_ligado_para('chave_que_nao_existe', (select casa_a from ids)),
          '2.4 recurso_ligado_para: chave inexistente segue desligada (fechado por padrão)');
select lives_ok($$select privado.exigir_recurso_para('checkin_por_codigo', (select casa_a from ids))$$,
          '2.5 exigir_recurso_para: não recusa a casa A, fora da lista');

-- ── 3. App 1.1 (150 m, sem sinais) numa casa fora da lista ────────────────────

select pg_temp.novo_turno('app11_150m', (select casa_a from ids));
select is((pg_temp.checkin('app11_150m', 150, privado.agora(), null))->>'tipo', 'manual',
          '3.1 app 1.1 a 150 m, sem sinais: tipo manual');
select is((pg_temp.checkin('app11_150m', 150, privado.agora(), null))->>'verificacao', 'pendente',
          '3.2 app 1.1 a 150 m, sem sinais: verificacao pendente');
select is((pg_temp.checkin('app11_150m', 150, privado.agora(), null))->>'codigo_exigido', 'true',
          '3.3 app 1.1 a 150 m, sem sinais: codigo_exigido true');

-- ── 4. Gerar e validar o código numa casa fora da lista ───────────────────────

select pg_temp.novo_turno('codigo_casa_b', (select casa_b from ids));
select is((pg_temp.checkin('codigo_casa_b', 20))->>'codigo_disponivel', 'true',
          '4.1 casa B: toque a 20 m deixa o código disponível');
select is(pg_temp.recusa_gerar((select dono_b from ids), pg_temp.t('codigo_casa_b')), 'ok',
          '4.2 gerar_codigo_checkin: casa B, fora da lista, não toma 403 recurso_desligado');
create temp table codigo_b as
select (pg_temp.gerar((select dono_b from ids), pg_temp.t('codigo_casa_b')))->>'codigo' as cod;
select matches((select cod from codigo_b), '^[0-9]{6}$', '4.3 gerar_codigo_checkin: o código tem 6 dígitos');
select is((pg_temp.validar('codigo_casa_b', (select cod from codigo_b), 20))->>'verificacao', 'verificado',
          '4.4 validar_codigo_checkin: casa B, fora da lista, confirma a presença');
select is((select checkin_tipo from public.turno where id = pg_temp.t('codigo_casa_b')), 'codigo',
          '4.5 validar_codigo_checkin: checkin_tipo vira codigo');

-- ── 5. configuracao_do_app: o mínimo por versão e plataforma ──────────────────

select is(pg_temp.config('ios', '1.2.0'), 'true'::jsonb, '5.1 configuracao_do_app: ios 1.2.0 → checkin_por_codigo true');
select is(pg_temp.config('ios', '1.3'),   'true'::jsonb, '5.2 configuracao_do_app: ios 1.3 → true');
select is(pg_temp.config('ios', '1.1'),   'false'::jsonb, '5.3 configuracao_do_app: ios 1.1 → false');
select is(pg_temp.config('ios', null),    'false'::jsonb, '5.4 configuracao_do_app: ios sem versão → false');
select is(pg_temp.config('android', '9.9.9'), 'false'::jsonb, '5.5 configuracao_do_app: android, qualquer versão → false');

-- ── 6. A volta: chave desligada, tudo recua ───────────────────────────────────

-- Turno da casa B com a chegada já registrada a 20 m, ainda com a chave ligada.
select pg_temp.novo_turno('volta_gerar', (select casa_b from ids));
select pg_temp.checkin('volta_gerar', 20);

update privado.recurso set ligado = false where chave = 'checkin_por_codigo';

select ok(not privado.recurso_ligado_para('checkin_por_codigo', (select casa_a from ids)),
          '6.1 volta: recurso_ligado_para vira false para a casa A');
select is(pg_temp.recusa_gerar_det((select dono_b from ids), pg_temp.t('volta_gerar')), 'sem_permissao:recurso_desligado',
          '6.2 volta: gerar_codigo_checkin recusa com 403 sem_permissao (recurso_desligado)');
select is(pg_temp.config('ios', '1.2.0'), 'false'::jsonb, '6.3 volta: configuracao_do_app ios 1.2.0 → false');

select pg_temp.novo_turno('volta_150m', (select casa_a from ids));
select is((pg_temp.checkin('volta_150m', 150))->>'tipo', 'geolocalizado',
          '6.4 volta: toque a 150 m volta a ser geolocalizado');
select is((pg_temp.checkin('volta_150m', 150))->>'verificacao', 'verificado',
          '6.5 volta: e verificado na hora');

-- ── 7. Nada destrutivo ────────────────────────────────────────────────────────

select has_table('privado', 'recurso_estabelecimento', '7.1 a tabela da lista por casa continua lá (nada destrutivo)');
select matches(obj_description('privado.recurso_estabelecimento'::regclass, 'pg_class'),
               'Não é mais lida desde 20261112210000', '7.2 a tabela diz que não é mais lida');

select * from finish();
rollback;
