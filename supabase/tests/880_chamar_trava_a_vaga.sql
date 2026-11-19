-- 880_chamar_trava_a_vaga.sql
--
-- B-040 (#543): chamar_profissional com vaga_id trava a vaga direta e confere o estado dela depois
-- da trava (migração 20261117080000). Antes, a função lia a vaga sem trava: uma chamada que corria
-- junto de cancelar_vaga via a vaga "publicada", esperava só na chave estrangeira do insert e
-- nascia aberta numa vaga já cancelada, que o gatilho vaga_cancelada_fecha_chamadas (20261117050000)
-- não alcança mais.
--
-- A disputa em si só aparece com duas conexões: scripts/corrida-chamada.sh, cenário 7. Aqui fica o
-- caminho numa sessão só:
--   1. Catálogo: no ramo com vaga_id, a vaga é relida FOR UPDATE depois das travas da casa e do
--      profissional (ordem casa -> profissional -> vaga), e o 409 vaga_encerrada vem depois da trava.
--   2. A 2ª chamada numa vaga direta aberta segue entrando.
--   3. Vaga direta cancelada: 409 vaga_encerrada, e nenhuma chamada nasce.
--   4. Vaga direta preenchida (a 1ª chamada aceita): 409 vaga_encerrada.
begin;
set local search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-880';
select no_plan();

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
-- Chamada que cria a vaga direta (trabalho novo).
create function pg_temp.nova(prof uuid, inicio text) returns text language sql as $$
  select format($a$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
    estabelecimento_id => 'c8800000-0000-4000-8000-0000000000e1', funcao_id => %L, inicio_em => %L,
    fim_em => %L::timestamptz + interval '5 hours', local => 'CLN 201', regiao_administrativa => 'Plano Piloto',
    ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 15000, inclui_refeicao => true,
    inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Maitre') $a$,
    prof, (select id from public.funcao where nome = 'garçom'), inicio, inicio) $$;
-- Mais uma chamada para uma vaga direta que já existe.
create function pg_temp.mais(prof uuid, vaga uuid) returns text language sql as $$
  select format($a$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
    estabelecimento_id => 'c8800000-0000-4000-8000-0000000000e1', vaga_id => %L) $a$, prof, vaga) $$;

-- Contas: 1 contratante (casa e1, CNPJ), 2, 3 e 4 profissionais (A, B, C) na equipe de confiança.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c8800000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '@t880.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 4) n;
select pg_temp.como(('c8800000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195555880%s', '1990-01-01', '2026-09-22') $$,
  case when n = 1 then 'contratante' else 'profissional' end, n, n)) from generate_series(1, 4) n;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('c8800000-0000-4000-8000-0000000000e1', 'Casa 880', '88012345000101', 'food_service', 'CLN 201',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c8800000-0000-4000-8000-000000000001', 'c8800000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (usuario_id, ponto_base)
select ('c8800000-0000-4000-8000-00000000000' || n)::uuid, 'POINT(-47.8822 -15.7800)'::extensions.geography
  from generate_series(2, 4) n;
create temp table ids as select
  (select id from public.profissional where usuario_id = 'c8800000-0000-4000-8000-000000000002') a,
  (select id from public.profissional where usuario_id = 'c8800000-0000-4000-8000-000000000003') b,
  (select id from public.profissional where usuario_id = 'c8800000-0000-4000-8000-000000000004') c;
insert into public.profissional_funcao select p, (select id from public.funcao where nome = 'garçom')
  from ids, unnest(array[a, b, c]) p;
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c8800000-0000-4000-8000-0000000000e1', p from ids, unnest(array[a, b, c]) p;
update privado.recurso set ligado = true where chave = 'chamada_direta';
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do nothing;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select p.usuario_id, 'tok-teste-' || p.usuario_id, 'ios', '1.2.0'
  from public.profissional p where p.usuario_id::text like 'c8800000-%'
on conflict (token_fcm) do nothing;

-- ── 1. Catálogo: a trava e a conferência depois dela ────────────────────────────
create temp table fonte as
select p.prosrc as src,
       strpos(p.prosrc, 'from public.profissional p where p.id = v_prof for update') as trava_prof,
       strpos(p.prosrc, 'from public.vaga g where g.id = v_vaga.id for update') as trava_vaga
  from pg_proc p
 where p.oid = 'public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int)'::regprocedure;
select ok((select trava_vaga > 0 from fonte),
  'no ramo com vaga_id, chamar_profissional relê a vaga direta FOR UPDATE');
select ok((select trava_prof > 0 and trava_prof < trava_vaga from fonte),
  'a trava da vaga vem depois das travas da casa e do profissional (casa -> profissional -> vaga)');
select ok((select trava_vaga > 0 and strpos(substr(src, trava_vaga), '''vaga_encerrada''') > 0 from fonte),
  'o estado da vaga é conferido de novo depois da trava (409 vaga_encerrada)');
select is((select prosecdef from pg_proc where proname = 'chamar_profissional' and pronamespace = 'public'::regnamespace), true,
  'chamar_profissional segue SECURITY DEFINER');
select ok((select proconfig from pg_proc where proname = 'chamar_profissional' and pronamespace = 'public'::regnamespace) @> array['search_path=""'],
  'chamar_profissional segue com search_path vazio');
select ok(has_function_privilege('authenticated', 'public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int)', 'execute')
      and not has_function_privilege('anon', 'public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int)', 'execute'),
  'authenticated executa e anon não');

-- ── 2. A 2ª chamada numa vaga direta aberta segue entrando ─────────────────────
create temp table ch1 as select pg_temp.como('c8800000-0000-4000-8000-000000000001',
  pg_temp.nova((select a from ids), '2026-11-08 18:00+00')) j;
create temp table ch2 as select pg_temp.como('c8800000-0000-4000-8000-000000000001',
  pg_temp.mais((select b from ids), (select (j->>'vaga_id')::uuid from ch1))) j;
select is((select estado from public.chamada where id = (select (j->>'id')::uuid from ch2)), 'aberta',
  'mais uma chamada (com vaga_id) numa vaga direta aberta nasce aberta');
select is((select j->>'vaga_id' from ch2), (select j->>'vaga_id' from ch1), 'e entra na mesma vaga');

-- ── 3. Vaga direta cancelada: 409, e nenhuma chamada nasce ──────────────────────
select is(pg_temp.r('c8800000-0000-4000-8000-000000000001',
  format($$ select public.cancelar_vaga(%L, 'Evento desmarcado') $$, (select j->>'vaga_id' from ch1))), 'ok',
  'a casa cancela a vaga direta');
select is(pg_temp.r('c8800000-0000-4000-8000-000000000001',
  pg_temp.mais((select c from ids), (select (j->>'vaga_id')::uuid from ch1))), 'vaga_encerrada',
  'chamar para a vaga cancelada: 409 vaga_encerrada');
select is((select count(*)::int from public.chamada where vaga_id = (select (j->>'vaga_id')::uuid from ch1) and estado = 'aberta'), 0,
  'nenhuma chamada aberta na vaga cancelada');
select is((select count(*)::int from public.chamada where profissional_id = (select c from ids)), 0,
  'C fica sem chamada');

-- ── 4. Vaga direta preenchida: 409 ─────────────────────────────────────────────
create temp table ch3 as select pg_temp.como('c8800000-0000-4000-8000-000000000001',
  pg_temp.nova((select a from ids), '2026-11-09 18:00+00')) j;
select is(pg_temp.r('c8800000-0000-4000-8000-000000000002',
  format($$ select public.responder_chamada(%L, 'aceitar') $$, (select j->>'id' from ch3))), 'ok', 'A aceita a chamada da vaga nova');
select is(pg_temp.r('c8800000-0000-4000-8000-000000000001',
  pg_temp.mais((select b from ids), (select (j->>'vaga_id')::uuid from ch3))), 'vaga_encerrada',
  'chamar para a vaga direta já preenchida: 409 vaga_encerrada');

select * from finish();
rollback;
