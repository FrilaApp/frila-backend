-- 890_cancelar_vaga_ordem_de_travas.sql
--
-- B-072 (#572): public.cancelar_vaga trava a vaga depois das confirmadas e antes das posições abertas
-- (migração 20261117200000). Antes, na vaga de publicação, pegava as abertas antes da vaga e fechava ciclo
-- com quem pega a vaga primeiro: o fechamento e a exclusão da conta da casa. O ciclo só aparece com
-- várias conexões (scripts/corrida-chamada.sh, cenários 28 a 30). Numa sessão só ficam:
--   1-2. o catálogo: a trava da vaga, em no key update e relida (select into), vem depois do laço das
--        confirmadas e antes do update das abertas (falha com o corpo da 20261117050000); SECURITY
--        DEFINER, search_path vazio, só para authenticated;
--   3-16. o desfecho sem disputa, que não muda (passa igual com o corpo anterior): vaga de publicação
--        futura com uma confirmada e uma aberta, o reenvio idempotente, a vaga terminada, a vaga já
--        encerrada pelo fechamento (409 vaga_encerrada), a vaga direta e os erros de antes da trava;
--   17-19. o curto-circuito depois da trava: a vaga encerrada por outro entre a 1ª leitura e a trava
--        (simulado por um gatilho de teste na ocorrência que o laço das confirmadas grava) dá 409
--        vaga_encerrada, o desfecho serial, e o erro desfaz a confirmada cancelada no laço (sem estado
--        misto). Com o corpo anterior, a vaga encerrada virava cancelada e a resposta era 200.
begin;
set local search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
select plan(19);

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
  perform pg_temp.como(conta, sql);
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text;
  reset role; execute 'reset request.jwt.claims';
  return case when m ~ '^\s*\{' then (m::jsonb->>'code') || coalesce(':' || (m::jsonb->>'details'), '') else m end;
end $$;
-- Uma vaga gravada direto, publicada, com k posições abertas.
create function pg_temp.vaga(id uuid, casa uuid, autor uuid, inicio timestamptz, origem text, k int) returns uuid
language sql as $$
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, regiao_administrativa,
                           ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
                           responsavel_local, modo, chave_cliente, publicado_em, estado, origem)
  values (id, casa, (select f.id from public.funcao f where f.nome = 'garçom'), autor, inicio, inicio + interval '5 hours',
          'CLN 201', 'Plano Piloto', 'POINT(-47.8822 -15.7942)'::extensions.geography, 15000, k, true, false, false,
          'Maitre', 'urgencia', gen_random_uuid(), now() - interval '2 days', 'publicada', origem);
  insert into public.posicao (vaga_id, inicio_em, fim_em)
  select g.id, g.inicio_em, g.fim_em from public.vaga g, generate_series(1, k) where g.id = vaga.id;
  select id;
$$;

-- Contas: 1 contratante (casa e1, membro único), 2 profissional, 3 contratante de outra casa (e2).
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c8900000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '@t890.test', now(), now(), false, false
  from generate_series(1, 3) n;
select pg_temp.como(('c8900000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195555890%s', '1990-01-01', '2026-09-22') $$,
  case when n = 2 then 'profissional' else 'contratante' end, n, n)) from generate_series(1, 3) n;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('c8900000-0000-4000-8000-0000000000e1', 'Casa 890 um', '89012345000101', 'food_service', 'CLN 201',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('c8900000-0000-4000-8000-0000000000e2', 'Casa 890 dois', '89012345000202', 'food_service', 'CLN 202',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c8900000-0000-4000-8000-000000000001', 'c8900000-0000-4000-8000-0000000000e1', 'administrador'),
  ('c8900000-0000-4000-8000-000000000003', 'c8900000-0000-4000-8000-0000000000e2', 'administrador');
insert into public.profissional (usuario_id, ponto_base)
values ('c8900000-0000-4000-8000-000000000002', 'POINT(-47.8822 -15.7800)'::extensions.geography);

-- V1: publicação daqui a 3 dias, duas posições: a menor confirmada (com turno), a outra aberta.
-- V2: publicação terminada há 1 h, uma aberta. V3: a mesma, encerrada pelo fechamento. V4: direta futura.
select pg_temp.vaga('c8900000-0000-4000-8000-0000000000a1', 'c8900000-0000-4000-8000-0000000000e1',
  'c8900000-0000-4000-8000-000000000001', date_trunc('hour', now()) + interval '3 days', 'publicacao', 2);
select pg_temp.vaga('c8900000-0000-4000-8000-0000000000a2', 'c8900000-0000-4000-8000-0000000000e1',
  'c8900000-0000-4000-8000-000000000001', date_trunc('minute', now()) - interval '6 hours', 'publicacao', 1);
select pg_temp.vaga('c8900000-0000-4000-8000-0000000000a3', 'c8900000-0000-4000-8000-0000000000e1',
  'c8900000-0000-4000-8000-000000000001', date_trunc('minute', now()) - interval '6 hours', 'publicacao', 1);
select pg_temp.vaga('c8900000-0000-4000-8000-0000000000a4', 'c8900000-0000-4000-8000-0000000000e1',
  'c8900000-0000-4000-8000-000000000001', date_trunc('hour', now()) + interval '4 days', 'chamada_direta', 1);
create temp table conf as
with p as (
  update public.posicao set estado = 'confirmada', confirmado_em = now() - interval '1 hour',
         profissional_id = (select id from public.profissional where usuario_id = 'c8900000-0000-4000-8000-000000000002')
   where id = (select id from public.posicao where vaga_id = 'c8900000-0000-4000-8000-0000000000a1' order by id limit 1)
  returning id)
select id from p;
insert into public.turno (posicao_id, valor_acordado_centavos) select id, 15000 from conf;

-- 1-2. Catálogo.
create temp table fonte as
select regexp_replace(p.prosrc, '\s+', ' ', 'g') as src
  from pg_proc p where p.oid = 'public.cancelar_vaga(uuid, text)'::regprocedure;
select ok((select strpos(src, 'select * into v from public.vaga g where g.id = cancelar_vaga.vaga_id for no key update;') > 0
                  and strpos(src, 'perform privado.cancelar_uma_posicao(v_pos, v_uid, v_motivo, false);')
                    < strpos(src, 'select * into v from public.vaga g where g.id = cancelar_vaga.vaga_id for no key update;')
                  and strpos(src, 'select * into v from public.vaga g where g.id = cancelar_vaga.vaga_id for no key update;')
                    < strpos(src, 'update public.posicao p set estado = ''cancelada'' where p.vaga_id = cancelar_vaga.vaga_id and p.estado = ''aberta'';')
             from fonte),
  'cancelar_vaga trava e relê a vaga (no key update) depois das confirmadas e antes das posições abertas');
select ok((select p.prosecdef and p.proconfig @> array['search_path=""']
                  and has_function_privilege('authenticated', p.oid, 'execute')
                  and not has_function_privilege('anon', p.oid, 'execute')
             from pg_proc p where p.oid = 'public.cancelar_vaga(uuid, text)'::regprocedure),
  'cancelar_vaga segue SECURITY DEFINER, search_path vazio, só para authenticated');

-- 3-6. Vaga de publicação futura com uma confirmada e uma aberta.
select is(pg_temp.como('c8900000-0000-4000-8000-000000000001',
  $$ select public.cancelar_vaga('c8900000-0000-4000-8000-0000000000a1', 'Evento desmarcado') $$),
  jsonb_build_object('vaga_id', 'c8900000-0000-4000-8000-0000000000a1', 'estado', 'cancelada', 'posicoes_canceladas', 2),
  'publicação futura: a resposta de sempre, com as duas posições canceladas');
select is((select estado::text from public.vaga where id = 'c8900000-0000-4000-8000-0000000000a1'), 'cancelada',
  'publicação futura: a vaga cancelada');
select is((select string_agg(estado::text, ',' order by id) from public.posicao where vaga_id = 'c8900000-0000-4000-8000-0000000000a1'),
  'cancelada,cancelada', 'publicação futura: a confirmada e a aberta canceladas');
select is((select count(*)::int from public.ocorrencia o join conf on conf.id = o.posicao_id where o.tipo = 'cancelamento'), 1,
  'publicação futura: a confirmada cancelada pelo caminho de sempre (uma ocorrência de cancelamento)');

-- 7. O reenvio pelo mesmo autor é idempotente.
select is(pg_temp.como('c8900000-0000-4000-8000-000000000001',
  $$ select public.cancelar_vaga('c8900000-0000-4000-8000-0000000000a1', 'Evento desmarcado') $$),
  jsonb_build_object('vaga_id', 'c8900000-0000-4000-8000-0000000000a1', 'estado', 'cancelada', 'posicoes_canceladas', 2),
  'reenvio: 200 com a mesma resposta');

-- 8-9. Vaga de publicação terminada, ainda não fechada.
select is(pg_temp.como('c8900000-0000-4000-8000-000000000001',
  $$ select public.cancelar_vaga('c8900000-0000-4000-8000-0000000000a2', 'Evento desmarcado') $$),
  jsonb_build_object('vaga_id', 'c8900000-0000-4000-8000-0000000000a2', 'estado', 'cancelada', 'posicoes_canceladas', 1),
  'publicação terminada: cancelada, com a posição aberta');
select is((select estado::text from public.posicao where vaga_id = 'c8900000-0000-4000-8000-0000000000a2'), 'cancelada',
  'publicação terminada: a posição cancelada');

-- 10-11. Vaga de publicação terminada e já encerrada pelo fechamento.
select privado.fechar_turnos_e_vagas();
select is((select estado::text from public.vaga where id = 'c8900000-0000-4000-8000-0000000000a3'), 'encerrada',
  'montagem: o fechamento encerrou a vaga terminada');
select is(pg_temp.r('c8900000-0000-4000-8000-000000000001',
  $$ select public.cancelar_vaga('c8900000-0000-4000-8000-0000000000a3', 'Evento desmarcado') $$),
  'vaga_encerrada', 'vaga já encerrada: 409 vaga_encerrada, como antes');

-- 12-13. Vaga direta.
select is(pg_temp.como('c8900000-0000-4000-8000-000000000001',
  $$ select public.cancelar_vaga('c8900000-0000-4000-8000-0000000000a4', 'Evento desmarcado') $$),
  jsonb_build_object('vaga_id', 'c8900000-0000-4000-8000-0000000000a4', 'estado', 'cancelada', 'posicoes_canceladas', 1),
  'vaga direta: a resposta de sempre');
select is((select estado::text from public.vaga where id = 'c8900000-0000-4000-8000-0000000000a4'), 'cancelada',
  'vaga direta: cancelada');

-- 14-16. Os erros de antes da trava.
select is(pg_temp.r('c8900000-0000-4000-8000-000000000003',
  $$ select public.cancelar_vaga('c8900000-0000-4000-8000-0000000000a3', 'Evento desmarcado') $$),
  'nao_encontrado', 'casa de outro contratante: 404');
select is(pg_temp.r('c8900000-0000-4000-8000-000000000001',
  $$ select public.cancelar_vaga(gen_random_uuid(), 'Evento desmarcado') $$),
  'nao_encontrado', 'vaga inexistente: 404');
select is(pg_temp.r('c8900000-0000-4000-8000-000000000001',
  $$ select public.cancelar_vaga('c8900000-0000-4000-8000-0000000000a3', 'ok') $$),
  'campo_obrigatorio:motivo', 'motivo curto: 422 campo_obrigatorio');

-- 17-19. O curto-circuito depois da trava. V5: publicação terminada há 1 h, uma confirmada sem chegada
-- (a menor) e uma aberta. O gatilho de teste faz o papel de quem fecha a vaga enquanto o cancelamento
-- espera a trava: quando o laço das confirmadas grava a ocorrência, a vaga vai a encerrada.
select pg_temp.vaga('c8900000-0000-4000-8000-0000000000a5', 'c8900000-0000-4000-8000-0000000000e1',
  'c8900000-0000-4000-8000-000000000001', date_trunc('minute', now()) - interval '6 hours', 'publicacao', 2);
update public.posicao set estado = 'confirmada', confirmado_em = now() - interval '1 day',
       profissional_id = (select id from public.profissional where usuario_id = 'c8900000-0000-4000-8000-000000000002')
 where id = (select id from public.posicao where vaga_id = 'c8900000-0000-4000-8000-0000000000a5' order by id limit 1);
create function public.t890_encerra_no_meio() returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.vaga g set estado = 'encerrada'
   where g.id = 'c8900000-0000-4000-8000-0000000000a5'
     and exists (select 1 from public.posicao p where p.id = new.posicao_id and p.vaga_id = g.id);
  return null;
end $$;
-- ver o comentário do 420 (lock antes do create trigger)
lock table public.ocorrencia in access exclusive mode;
create trigger t890_encerra_no_meio after insert on public.ocorrencia
  for each row execute function public.t890_encerra_no_meio();
select is(pg_temp.r('c8900000-0000-4000-8000-000000000001',
  $$ select public.cancelar_vaga('c8900000-0000-4000-8000-0000000000a5', 'Evento desmarcado') $$),
  'vaga_encerrada', 'vaga encerrada por outro antes da trava: 409 vaga_encerrada, o desfecho serial');
select is((select estado::text from public.vaga where id = 'c8900000-0000-4000-8000-0000000000a5'), 'publicada',
  'sem estado misto: o 409 desfaz o que o cancelamento fez, e a vaga não vira cancelada');
select is((select string_agg(estado::text, ',' order by id) from public.posicao where vaga_id = 'c8900000-0000-4000-8000-0000000000a5'),
  'confirmada,aberta', 'sem estado misto: a confirmada cancelada no laço volta, e a aberta fica');
drop trigger t890_encerra_no_meio on public.ocorrencia;

select * from finish();
rollback;
