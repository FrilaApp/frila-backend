-- 884_expirar_chamadas_segunda_chamada.sql
--
-- B-053 (#550): privado.expirar_chamadas não encerra a vaga direta que ainda tem chamada aberta.
--
-- Numa sessão só, a função sempre conferiu "sem chamada aberta" antes de encerrar a vaga, e as
-- partes 1 a 3 já passavam antes da migração 20261117130000. O defeito é de disputa: o job conferia
-- sem trava e encerrava a vaga depois de esperar um chamar_profissional (com vaga_id) que ainda não
-- tinha feito commit, e a chamada nova ficava aberta numa vaga encerrada. Isso só aparece com duas
-- conexões: scripts/corrida-chamada.sh, cenário 8. Aqui fica o caminho numa sessão só:
--   1. Duas chamadas na mesma vaga direta, a 1ª vence e a 2ª está no prazo: a vaga segue publicada.
--   2. A última chamada aberta vence: a vaga encerra, como antes.
--   3. Duas chamadas da mesma vaga vencem na mesma execução: as duas expiram e a vaga encerra.
--   4. Catálogo: a vaga é travada e as chamadas abertas são conferidas de novo antes do update
--      (é a parte que falha sem a migração).
begin;
set local search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-884';
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
-- Chamada que cria a vaga direta (trabalho novo).
create function pg_temp.nova(prof uuid, inicio text) returns text language sql as $$
  select format($a$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
    estabelecimento_id => 'c8840000-0000-4000-8000-0000000000e1', funcao_id => %L, inicio_em => %L,
    fim_em => %L::timestamptz + interval '5 hours', local => 'CLN 201', regiao_administrativa => 'Plano Piloto',
    ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 15000, inclui_refeicao => true,
    inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Maitre') $a$,
    prof, (select id from public.funcao where nome = 'garçom'), inicio, inicio) $$;
-- Mais uma chamada para uma vaga direta que já existe.
create function pg_temp.mais(prof uuid, vaga uuid) returns text language sql as $$
  select format($a$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
    estabelecimento_id => 'c8840000-0000-4000-8000-0000000000e1', vaga_id => %L) $a$, prof, vaga) $$;
create function pg_temp.chamada(j jsonb) returns text language sql as $$
  select estado from public.chamada where id = (j->>'id')::uuid $$;
create function pg_temp.vaga(j jsonb) returns text language sql as $$
  select estado::text from public.vaga where id = (j->>'vaga_id')::uuid $$;

-- Contas: 1 contratante (casa e1, CNPJ), 2, 3 e 4 profissionais (A, B, C) na equipe de confiança.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c8840000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '@t884.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 4) n;
select pg_temp.como(('c8840000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195555884%s', '1990-01-01', '2026-09-22') $$,
  case when n = 1 then 'contratante' else 'profissional' end, n, n)) from generate_series(1, 4) n;
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('c8840000-0000-4000-8000-0000000000e1', 'Casa 884', '88412345000101', 'food_service', 'CLN 201',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c8840000-0000-4000-8000-000000000001', 'c8840000-0000-4000-8000-0000000000e1', 'administrador');
insert into public.profissional (usuario_id, ponto_base)
select ('c8840000-0000-4000-8000-00000000000' || n)::uuid, 'POINT(-47.8822 -15.7800)'::extensions.geography
  from generate_series(2, 4) n;
create temp table ids as select
  (select id from public.profissional where usuario_id = 'c8840000-0000-4000-8000-000000000002') a,
  (select id from public.profissional where usuario_id = 'c8840000-0000-4000-8000-000000000003') b,
  (select id from public.profissional where usuario_id = 'c8840000-0000-4000-8000-000000000004') c;
insert into public.profissional_funcao select p, (select id from public.funcao where nome = 'garçom')
  from ids, unnest(array[a, b, c]) p;
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c8840000-0000-4000-8000-0000000000e1', p from ids, unnest(array[a, b, c]) p;
update privado.recurso set ligado = true where chave = 'chamada_direta';
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do nothing;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select p.usuario_id, 'tok-teste-' || p.usuario_id, 'ios', '1.2.0'
  from public.profissional p where p.usuario_id::text like 'c8840000-%'
on conflict (token_fcm) do nothing;

-- ── 1. A 1ª chamada vence e a 2ª está no prazo: a vaga segue publicada ──────────
-- ch1 (A), criada às 15:00 de 07/11 (12:00 em Brasília): vence às 03:00 de 08/11 (12 h).
-- ch2 (B), na mesma vaga, criada às 19:00: vence às 07:00 de 08/11.
create temp table ch1 as select pg_temp.como('c8840000-0000-4000-8000-000000000001',
  pg_temp.nova((select a from ids), '2026-11-09 18:00+00')) j;
select set_config('frila.agora', '2026-11-07 19:00:00+00', true);
create temp table ch2 as select pg_temp.como('c8840000-0000-4000-8000-000000000001',
  pg_temp.mais((select b from ids), (select (j->>'vaga_id')::uuid from ch1))) j;
select is((select j->>'vaga_id' from ch2), (select j->>'vaga_id' from ch1), 'a 2ª chamada entra na mesma vaga direta');
select is((select (j->>'expira_em')::timestamptz from ch1), '2026-11-08 03:00:00+00'::timestamptz, 'a 1ª vence às 03:00');
select is((select (j->>'expira_em')::timestamptz from ch2), '2026-11-08 07:00:00+00'::timestamptz, 'a 2ª vence às 07:00');

select set_config('frila.agora', '2026-11-08 04:00:00+00', true);
select is(privado.expirar_chamadas(), 1, 'às 04:00, o job expira só a 1ª chamada');
select is((select pg_temp.chamada(j) from ch1), 'expirada', 'a 1ª chamada fica expirada');
select is((select pg_temp.chamada(j) from ch2), 'aberta', 'a 2ª chamada segue aberta');
select is((select pg_temp.vaga(j) from ch1), 'publicada',
  'a vaga direta com a 2ª chamada aberta NÃO é encerrada pela expiração da 1ª (#550)');
select is((select count(*)::int from public.posicao where vaga_id = (select (j->>'vaga_id')::uuid from ch1) and estado = 'aberta'), 1,
  'a posição da vaga segue aberta para a 2ª chamada');
select is((select count(*)::int from public.notificacao
            where usuario_id = 'c8840000-0000-4000-8000-000000000003' and tipo = 'chamada_expirada'), 0,
  'B não recebe chamada_expirada: a chamada dele está no prazo');

-- ── 3 (montagem). Outra vaga direta com duas chamadas que vencem juntas ────────
-- Às 04:00 (01:00 em Brasília, no silêncio), o prazo conta das 07:00 de lá: ch3 (C) e ch4 (A, já
-- sem chamada aberta com a casa) vencem as duas às 22:00 de 08/11.
create temp table ch3 as select pg_temp.como('c8840000-0000-4000-8000-000000000001',
  pg_temp.nova((select c from ids), '2026-11-10 18:00+00')) j;
create temp table ch4 as select pg_temp.como('c8840000-0000-4000-8000-000000000001',
  pg_temp.mais((select a from ids), (select (j->>'vaga_id')::uuid from ch3))) j;
select is((select (j->>'expira_em')::timestamptz from ch3), (select (j->>'expira_em')::timestamptz from ch4),
  'as duas chamadas da outra vaga vencem na mesma hora');

-- ── 2. A última chamada aberta vence: a vaga encerra ───────────────────────────
select set_config('frila.agora', '2026-11-08 08:00:00+00', true);
select is(privado.expirar_chamadas(), 1, 'às 08:00, o job expira a 2ª chamada');
select is((select pg_temp.chamada(j) from ch2), 'expirada', 'a 2ª chamada fica expirada');
select is((select pg_temp.vaga(j) from ch1), 'encerrada', 'sem chamada aberta nem turno, a vaga direta encerra');
select is((select pg_temp.vaga(j) from ch3), 'publicada', 'a outra vaga, com chamadas no prazo, segue publicada');

-- ── 3. Duas chamadas da mesma vaga vencem na mesma execução ────────────────────
select set_config('frila.agora', '2026-11-08 23:00:00+00', true);
select is(privado.expirar_chamadas(), 2, 'às 23:00, o job expira as duas chamadas da outra vaga');
select is((select count(*)::int from public.chamada
            where vaga_id = (select (j->>'vaga_id')::uuid from ch3) and estado = 'expirada'), 2,
  'as duas ficam expiradas');
select is((select pg_temp.vaga(j) from ch3), 'encerrada', 'e a vaga encerra na última delas');
select is(privado.expirar_chamadas(), 0, 'rodar de novo não expira nada');

-- ── 4. Catálogo: a trava da vaga e a conferência depois dela ────────────────────
-- Sem a 20261117130000, a função encerra a vaga pelo que leu antes de esperar a trava.
create temp table fonte as
select f.src,
       -- A 20261117170000 pôs outra trava de vaga no começo: vale a que vem depois deste select.
       case when strpos(substr(f.src, strpos(f.src, 'from public.vaga g where g.id = r.vaga_id')), 'for no key update') > 0
            then strpos(f.src, 'from public.vaga g where g.id = r.vaga_id')
                 + strpos(substr(f.src, strpos(f.src, 'from public.vaga g where g.id = r.vaga_id')), 'for no key update') - 1
            else 0 end as trava,
       strpos(f.src, 'update public.vaga set estado = ''encerrada''') as encerra
  from (select regexp_replace(p.prosrc, '\s+', ' ', 'g') as src
          from pg_proc p where p.oid = 'privado.expirar_chamadas()'::regprocedure) f;
select ok((select trava > 0 and strpos(src, 'from public.vaga g where g.id = r.vaga_id') between 1 and trava from fonte),
  'expirar_chamadas trava a vaga direta (FOR NO KEY UPDATE) antes de encerrá-la');
select ok((select trava > 0 and trava < encerra from fonte), 'a trava vem antes do update que encerra a vaga');
select ok((select trava > 0 and encerra > trava
              and strpos(substr(src, trava, encerra - trava), 'x.estado = ''aberta''') > 0 from fonte),
  'as chamadas abertas da vaga são conferidas de novo depois da trava e antes de encerrar');
select is((select prosecdef from pg_proc where oid = 'privado.expirar_chamadas()'::regprocedure), true,
  'expirar_chamadas segue SECURITY DEFINER');
select ok((select proconfig from pg_proc where oid = 'privado.expirar_chamadas()'::regprocedure) @> array['search_path=""'],
  'expirar_chamadas segue com search_path vazio');
select ok(has_function_privilege('service_role', 'privado.expirar_chamadas()', 'execute')
      and not has_function_privilege('authenticated', 'privado.expirar_chamadas()', 'execute')
      and not has_function_privilege('anon', 'privado.expirar_chamadas()', 'execute'),
  'service_role executa; authenticated e anon não');

select * from finish();
rollback;
