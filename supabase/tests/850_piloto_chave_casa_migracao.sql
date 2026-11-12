-- 850_piloto_chave_casa_migracao.sql
--
-- Prova do ciclo de vida da chave checkin_por_codigo por migração:
--   1. Global ligado sem casa na lista: prova a afirmação de Cauê de que NADA muda
--      para ninguém (legado segue 100% ativo, geração/validação respondem 403 recurso_desligado);
--   2. Migração de ligar casa: casa PJ ou de teste entra em privado.recurso_estabelecimento,
--      ativando o fluxo novo (manual/pendente, código exigido, geração e validação ativas);
--   3. Migração de desligar casa: remoção de privado.recurso_estabelecimento volta imediatamente
--      ao fluxo legado, sem quebrar confirmações manuais em contingência.
--
-- Massa sintética; o arquivo desfaz tudo no rollback.

begin;
insert into privado.ambiente (eh_teste) values (true) on conflict do nothing;
select set_config('frila.agora', '2027-01-11 21:30:00+00', true);
select plan(24);

-- Massa: Casa PJ 850 e Casa Legado 850
create temp table ids as
select 'c8500000-0000-4000-8000-000000000001'::uuid as dono_pj,
       'c8500000-0000-4000-8000-000000000002'::uuid as dono_legado,
       'c8500000-0000-4000-8000-000000000021'::uuid as casa_pj,
       'c8500000-0000-4000-8000-000000000022'::uuid as casa_legado;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
select u, 'contratante'::public.perfil_conta, 'Casa 850 ' || n, '+556199999850' || n, 'casa850-' || n || '@test.invalid',
       '1985-01-01'::date, '1.0', '2026-09-20 12:00:00-03'::timestamptz
  from ids, lateral (values (dono_pj, 1), (dono_legado, 2)) v (u, n);

-- Casa PJ sintética de teste: food_service, CNPJ sintético de 14 dígitos
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select casa_pj, 'Restaurante Ficticio PJ LTDA', '12345678000199', 'food_service'::public.tipo_estabelecimento,
       'Endereço Fictício de Teste', 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
select casa_legado, 'Bar Legado', '80000000000850', 'food_service'::public.tipo_estabelecimento,
       'Endereço Legado', 'POINT(-47.8800 -15.7700)'::extensions.geography
  from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select u, c, 'administrador' from ids, lateral (values (dono_pj, casa_pj), (dono_legado, casa_legado)) v (u, c);

-- Turnos de teste
create temp table turnos (nome text primary key, turno uuid, usuario uuid, prof uuid);
create function pg_temp.novo_turno(nome text, casa uuid, inicio timestamptz default '2027-01-11 21:00:00+00') returns uuid
language plpgsql as $$
declare
  v_user uuid := gen_random_uuid(); v_prof uuid := gen_random_uuid();
  v_vaga uuid := gen_random_uuid(); v_pos  uuid := gen_random_uuid(); v_t uuid := gen_random_uuid();
begin
  insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
  values (v_user, 'profissional', 'Prof 850 ' || nome, '+5561999998500', nome || '@t850.invalid',
          '1992-01-01', '1.0', '2026-09-20 12:00:00-03');
  insert into public.profissional (id, usuario_id, ponto_base) values (v_prof, v_user, 'POINT(-47.8800 -15.7700)');
  insert into public.vaga (
    id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
    valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
    exige_material_proprio, responsavel_local, modo, estado, publicado_em, chave_cliente, publicado_por)
  values (v_vaga, casa, (select id from public.funcao limit 1),
          inicio, inicio + interval '5 hours', 'Local 850', 'POINT(-47.8800 -15.7700)',
          15000, 1, false, false, false, 'Gerente', 'urgencia', 'publicada', inicio - interval '33 hours',
          gen_random_uuid(), 'c8500000-0000-4000-8000-000000000001');
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

create function pg_temp.recusa_gerar(dono uuid, turno uuid) returns text language plpgsql as $$
begin
  perform pg_temp.como(dono, format('select public.gerar_codigo_checkin(%L::uuid)', turno));
  return 'ok';
exception when sqlstate 'PGRST' then
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return (sqlerrm::jsonb->>'details');
end $$;

create function pg_temp.recusa_validar(nome text, codigo text, distancia integer) returns text language plpgsql as $$
begin
  perform pg_temp.como(pg_temp.u(nome),
                       format('select public.validar_codigo_checkin(%L::uuid, %L, %s)',
                              pg_temp.t(nome), codigo, coalesce(distancia::text, 'null')));
  return 'ok';
exception when sqlstate 'PGRST' then
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return (sqlerrm::jsonb->>'details');
end $$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- CENÁRIO 1: Global ligado no pacote de Prod, mas NENHUMA casa na lista
-- (Afirmação de Cauê: nada muda para ninguém)
-- ═══════════════════════════════════════════════════════════════════════════════

update privado.recurso set ligado = true where chave = 'checkin_por_codigo';
delete from privado.recurso_estabelecimento where chave = 'checkin_por_codigo';

select is((select ligado from privado.recurso where chave = 'checkin_por_codigo'), true,
  '1.1 chave global está ligada em privado.recurso');
select is((select count(*)::int from privado.recurso_estabelecimento where chave = 'checkin_por_codigo'), 0,
  '1.2 nenhuma casa está cadastrada em privado.recurso_estabelecimento');

-- Para ambas as casas, recurso_ligado_para responde false:
select is(privado.recurso_ligado_para('checkin_por_codigo', (select casa_pj from ids)), false,
  '1.3 recurso_ligado_para responde false para casa PJ quando lista está vazia');
select is(privado.recurso_ligado_para('checkin_por_codigo', (select casa_legado from ids)), false,
  '1.4 recurso_ligado_para responde false para casa legado quando lista está vazia');

-- Turno na casa PJ sem a casa na lista segue fluxo legado:
select pg_temp.novo_turno('sem_casa_pj', (select casa_pj from ids));
select is((pg_temp.checkin('sem_casa_pj', 40))->>'tipo', 'geolocalizado',
  '1.5 toque a 40 m em casa fora da lista segue fluxo legado: tipo geolocalizado');
select is((pg_temp.checkin('sem_casa_pj', 40))->>'verificacao', 'verificado',
  '1.6 toque a 40 m em casa fora da lista auto-verifica na hora pelo GPS');
select is((pg_temp.checkin('sem_casa_pj', 40))->>'codigo_exigido', null,
  '1.7 resposta não traz campos de código quando a casa não está na lista');

-- Tentativas de gerar ou validar código na casa respondem 403 recurso_desligado:
select is(pg_temp.recusa_gerar((select dono_pj from ids), pg_temp.t('sem_casa_pj')), 'recurso_desligado',
  '1.8 gerar_codigo_checkin responde 403 recurso_desligado quando casa não está na lista');
select is(pg_temp.recusa_validar('sem_casa_pj', '123456', 30), 'recurso_desligado',
  '1.9 validar_codigo_checkin responde 403 recurso_desligado quando casa não está na lista');

-- Sem linha em privado.recurso_versao_minima, configuracao_do_app segue false mesmo com global ligado:
delete from privado.recurso_versao_minima where recurso = 'checkin_por_codigo';
select is((select public.configuracao_do_app('ios', '1.2.0')->'recursos'->>'checkin_por_codigo'), 'false',
  '1.10 configuracao_do_app segue false sem versão mínima, mesmo com global ligado (0.2.65)');

-- ═══════════════════════════════════════════════════════════════════════════════
-- CENÁRIO 2: Migração de LIGAR a casa piloto (PJ ou teste)
-- ═══════════════════════════════════════════════════════════════════════════════

-- Simula a execução da migração linear que inclui a casa piloto PJ:
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
values ('checkin_por_codigo', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

insert into privado.recurso_estabelecimento (chave, estabelecimento_id)
select 'checkin_por_codigo', (select casa_pj from ids)
on conflict do nothing;

select is(privado.recurso_ligado_para('checkin_por_codigo', (select casa_pj from ids)), true,
  '2.1 após migração de ligar, recurso_ligado_para responde true para a casa piloto');
select is(privado.recurso_ligado_para('checkin_por_codigo', (select casa_legado from ids)), false,
  '2.2 casa legado segue false (isolamento estrito do piloto)');

select is((select public.configuracao_do_app('ios', '1.2.0')->'recursos'->>'checkin_por_codigo'), 'true',
  '2.3 com versão mínima cadastrada, configuracao_do_app libera checkin_por_codigo para iOS 1.2.0');
select is((select public.configuracao_do_app('ios', '1.1.0')->'recursos'->>'checkin_por_codigo'), 'false',
  '2.4 configuracao_do_app segue false para iOS 1.1.0 anterior ao piloto');

-- Turno na casa piloto agora adota a Etapa 1:
select pg_temp.novo_turno('com_casa_piloto', (select casa_pj from ids));
select is((pg_temp.checkin('com_casa_piloto', 30))->>'tipo', 'manual',
  '2.5 no piloto: chegada a 30 m não auto-verifica pelo GPS, vira tipo manual');
select is((pg_temp.checkin('com_casa_piloto', 30))->>'verificacao', 'pendente',
  '2.6 no piloto: presença permanece pendente');
select is((pg_temp.checkin('com_casa_piloto', 30))->>'codigo_exigido', 'true',
  '2.7 no piloto: codigo_exigido é true');
select is((pg_temp.checkin('com_casa_piloto', 30))->>'codigo_disponivel', 'true',
  '2.8 no piloto: codigo_disponivel é true para chegada <= 50 m');

-- Geração de código permitida:
select is(pg_temp.recusa_gerar((select dono_pj from ids), pg_temp.t('com_casa_piloto')), 'ok',
  '2.9 casa piloto gera código com sucesso via gerar_codigo_checkin');

-- Validação de código confirmada:
create temp table cod_migracao as
select (pg_temp.como((select dono_pj from ids),
                     format('select public.gerar_codigo_checkin(%L::uuid)', pg_temp.t('com_casa_piloto'))))->>'codigo' as c;

select is((pg_temp.como(pg_temp.u('com_casa_piloto'),
                        format('select public.validar_codigo_checkin(%L::uuid, %L, 25)',
                               pg_temp.t('com_casa_piloto'), (select c from cod_migracao))))->>'verificacao',
          'verificado',
          '2.10 validação a 25 m confirma presença (verificado) no fluxo novo');

-- ═══════════════════════════════════════════════════════════════════════════════
-- CENÁRIO 3: Migração de DESLIGAR a casa piloto (Rollback forward-only)
-- ═══════════════════════════════════════════════════════════════════════════════

-- Simula a execução da migração compensatória que remove a casa do piloto:
delete from privado.recurso_estabelecimento
 where chave = 'checkin_por_codigo'
   and estabelecimento_id = (select casa_pj from ids);

select is(privado.recurso_ligado_para('checkin_por_codigo', (select casa_pj from ids)), false,
  '3.1 após migração de desligar, recurso_ligado_para volta imediatamente a false');

-- Novo turno na casa desativada volta na hora ao fluxo legado:
select pg_temp.novo_turno('pos_desligar', (select casa_pj from ids));
select is((pg_temp.checkin('pos_desligar', 35))->>'tipo', 'geolocalizado',
  '3.2 novo toque volta a ser geolocalizado na hora (fluxo legado restabelecido)');
select is((pg_temp.checkin('pos_desligar', 35))->>'verificacao', 'verificado',
  '3.3 presença auto-verifica na hora pelo GPS a <= 200 m após desligar');
select is(pg_temp.recusa_gerar((select dono_pj from ids), pg_temp.t('pos_desligar')), 'recurso_desligado',
  '3.4 gerar_codigo_checkin volta a responder 403 recurso_desligado');

select * from finish();
rollback;
