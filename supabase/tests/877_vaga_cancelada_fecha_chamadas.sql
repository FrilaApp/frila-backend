-- 877_vaga_cancelada_fecha_chamadas.sql
--
-- B-035: a vaga direta cancelada fecha as chamadas abertas dela (migração 20261117050000).
-- Antes, cancelar_vaga (20261005090000) não mexia em public.chamada: a chamada seguia aberta numa
-- vaga cancelada, o profissional ainda a via, e o índice chamada_uma_aberta_por_par (RN34) travava
-- o par casa × profissional até ela vencer.
--
-- Contrato (EstadoChamada): "encerrada (outra chamada do trabalho foi aceita, a vaga foi cancelada
-- ou convertida, ...)". Desfechos finais: aceita, recusada, expirada e cancelada não mudam.
-- Aviso: o que já existe para a chamada que a casa desfez (chamada_cancelada).
--   1. cancelar_vaga: as abertas viram encerrada, com respondida_em; a recusada fica; o par fica
--      livre para outra chamada; o profissional recebe chamada_cancelada uma vez (o reenvio
--      idempotente não repete); o aceite tardio recebe 409 chamada_indisponivel (encerrada).
--   2. Outro caminho que cancela a vaga (excluir_conta da casa de membro único): o mesmo desfecho.
--   3. A chamada já vencida e ainda aberta fica para privado.expirar_chamadas, que a expira.
--   4. Catálogo do gatilho e da função.
begin;
set local search_path = public, extensions;
create extension if not exists pgtap with schema extensions;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-877';
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
  if conta is null then execute sql; else perform pg_temp.como(conta, sql); end if;
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text;
  reset role; execute 'reset request.jwt.claims';
  return case when m ~ '^\s*\{' then (m::jsonb->>'code') || coalesce(':' || (m::jsonb->>'details'), '') else m end;
end $$;
-- Chamada que cria a vaga direta (trabalho novo) na casa dada.
create function pg_temp.nova(casa uuid, prof uuid, inicio text) returns text language sql as $$
  select format($a$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
    estabelecimento_id => %L, funcao_id => %L, inicio_em => %L,
    fim_em => %L::timestamptz + interval '5 hours', local => 'CLN 201', regiao_administrativa => 'Plano Piloto',
    ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 15000, inclui_refeicao => true,
    inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Maitre') $a$,
    prof, casa, (select id from public.funcao where nome = 'garçom'), inicio, inicio) $$;
-- Mais uma chamada para uma vaga direta que já existe.
create function pg_temp.mais(casa uuid, prof uuid, vaga uuid) returns text language sql as $$
  select format($a$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
    estabelecimento_id => %L, vaga_id => %L) $a$, prof, casa, vaga) $$;

-- Contas: 1 e 5 contratantes (casas e1 e e2, membro único cada), 2, 3 e 4 profissionais (A, B, C).
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', ('c8770000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '@t877.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 5) n;
select pg_temp.como(('c8770000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195555877%s', '1990-01-01', '2026-09-22') $$,
  case when n in (1, 5) then 'contratante' else 'profissional' end, n, n)) from generate_series(1, 5) n;
-- CNPJ: a confirmação de recorrência da casa CPF (J7) não entra no caminho.
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('c8770000-0000-4000-8000-0000000000e1', 'Casa 877 um', '87712345000101', 'food_service', 'CLN 201',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('c8770000-0000-4000-8000-0000000000e2', 'Casa 877 dois', '87712345000202', 'food_service', 'CLN 202',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c8770000-0000-4000-8000-000000000001', 'c8770000-0000-4000-8000-0000000000e1', 'administrador'),
  ('c8770000-0000-4000-8000-000000000005', 'c8770000-0000-4000-8000-0000000000e2', 'administrador');
insert into public.profissional (usuario_id, ponto_base)
select ('c8770000-0000-4000-8000-00000000000' || n)::uuid, 'POINT(-47.8822 -15.7800)'::extensions.geography
  from generate_series(2, 4) n;
create temp table ids as select
  (select id from public.profissional where usuario_id = 'c8770000-0000-4000-8000-000000000002') a,
  (select id from public.profissional where usuario_id = 'c8770000-0000-4000-8000-000000000003') b,
  (select id from public.profissional where usuario_id = 'c8770000-0000-4000-8000-000000000004') c;
insert into public.profissional_funcao select p, (select id from public.funcao where nome = 'garçom')
  from ids, unnest(array[a, b, c]) p;
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select e, p from ids, unnest(array[a, b, c]) p,
       unnest(array['c8770000-0000-4000-8000-0000000000e1'::uuid, 'c8770000-0000-4000-8000-0000000000e2'::uuid]) e;
update privado.recurso set ligado = true where chave = 'chamada_direta';
-- 0.2.66: só se chama quem tem aparelho na versão mínima de chamada_direta (o portão é o 830).
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do nothing;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select p.usuario_id, 'tok-teste-' || p.usuario_id, 'ios', '1.2.0'
  from public.profissional p where p.usuario_id::text like 'c8770000-%'
on conflict (token_fcm) do nothing;

-- ── 1. cancelar_vaga com três chamadas: A e B abertas, C recusou ───────────────
create temp table ch1 as select pg_temp.como('c8770000-0000-4000-8000-000000000001',
  pg_temp.nova('c8770000-0000-4000-8000-0000000000e1', (select a from ids), '2026-11-08 18:00+00')) j;
create temp table ch2 as select pg_temp.como('c8770000-0000-4000-8000-000000000001',
  pg_temp.mais('c8770000-0000-4000-8000-0000000000e1', (select b from ids), (select (j->>'vaga_id')::uuid from ch1))) j;
create temp table ch3 as select pg_temp.como('c8770000-0000-4000-8000-000000000001',
  pg_temp.mais('c8770000-0000-4000-8000-0000000000e1', (select c from ids), (select (j->>'vaga_id')::uuid from ch1))) j;
select is(pg_temp.r('c8770000-0000-4000-8000-000000000004',
  format($$ select public.responder_chamada(%L, 'recusar', 'agenda') $$, (select j->>'id' from ch3))), 'ok', 'C recusa a chamada dele');
select is((select count(*)::int from public.chamada where vaga_id = (select (j->>'vaga_id')::uuid from ch1) and estado = 'aberta'), 2,
  'montagem: duas chamadas abertas (A e B) e uma recusada (C) na mesma vaga direta');

select is(pg_temp.r('c8770000-0000-4000-8000-000000000001',
  format($$ select public.cancelar_vaga(%L, 'Evento desmarcado') $$, (select j->>'vaga_id' from ch1))), 'ok', 'a casa cancela a vaga direta');
select is((select estado from public.vaga where id = (select (j->>'vaga_id')::uuid from ch1))::text, 'cancelada', 'a vaga está cancelada');

select is((select estado from public.chamada where id = (select (j->>'id')::uuid from ch1)), 'encerrada',
  'a chamada aberta de A vira encerrada (contrato: a vaga foi cancelada)');
select is((select estado from public.chamada where id = (select (j->>'id')::uuid from ch2)), 'encerrada',
  'a chamada aberta de B também vira encerrada');
select is((select estado from public.chamada where id = (select (j->>'id')::uuid from ch3)), 'recusada',
  'a recusada de C não muda (desfecho final)');
select is((select respondida_em from public.chamada where id = (select (j->>'id')::uuid from ch1)), '2026-11-07 15:00:00+00'::timestamptz,
  'respondida_em registra o instante do cancelamento');
select is((select count(*)::int from public.chamada where vaga_id = (select (j->>'vaga_id')::uuid from ch1) and estado = 'aberta'), 0,
  'nenhuma chamada aberta sobra na vaga cancelada');

select is((select count(*)::int from public.notificacao
            where usuario_id = 'c8770000-0000-4000-8000-000000000002' and tipo = 'chamada_cancelada'
              and referencia_id = (select (j->>'id')::uuid from ch1)
              and payload->>'chamada_id' = (select j->>'id' from ch1)
              and payload->>'vaga_id' = (select j->>'vaga_id' from ch1)), 1,
  'A recebe chamada_cancelada, com chamada_id e vaga_id');
select is((select count(*)::int from public.notificacao
            where usuario_id = 'c8770000-0000-4000-8000-000000000003' and tipo = 'chamada_cancelada'), 1,
  'B recebe chamada_cancelada');
select is((select count(*)::int from public.notificacao
            where usuario_id = 'c8770000-0000-4000-8000-000000000004' and tipo in ('chamada_cancelada', 'chamada_encerrada')), 0,
  'C, que já tinha recusado, não é avisado de novo');

select is(pg_temp.r('c8770000-0000-4000-8000-000000000002',
  format($$ select public.responder_chamada(%L, 'aceitar') $$, (select j->>'id' from ch1))), 'chamada_indisponivel:encerrada',
  'o aceite depois do cancelamento recebe 409 chamada_indisponivel (encerrada)');
select is((select count(*)::int from public.posicao where vaga_id = (select (j->>'vaga_id')::uuid from ch1) and estado = 'confirmada'), 0,
  'nenhuma posição confirmada na vaga cancelada');

-- O par casa × A está livre (RN34, chamada_uma_aberta_por_par): outra chamada para outro trabalho entra.
create temp table ch4 as select pg_temp.como('c8770000-0000-4000-8000-000000000001',
  pg_temp.nova('c8770000-0000-4000-8000-0000000000e1', (select a from ids), '2026-11-09 18:00+00')) j;
select is((select estado from public.chamada where id = (select (j->>'id')::uuid from ch4)), 'aberta',
  'o par casa × A fica livre: a nova chamada nasce aberta, sem 409 chamada_ja_aberta');

-- Reenvio idempotente (0.2.35): 200, sem aviso repetido.
select is(pg_temp.r('c8770000-0000-4000-8000-000000000001',
  format($$ select public.cancelar_vaga(%L, 'Evento desmarcado') $$, (select j->>'vaga_id' from ch1))), 'ok', 'reenvio do cancelamento: 200');
select is((select count(*)::int from public.notificacao
            where usuario_id = 'c8770000-0000-4000-8000-000000000002' and tipo = 'chamada_cancelada'), 1,
  'o reenvio não repete o aviso a A');

-- ── 2. Outro caminho: a casa de membro único exclui a conta e a vaga é cancelada ──
create temp table ch5 as select pg_temp.como('c8770000-0000-4000-8000-000000000005',
  pg_temp.nova('c8770000-0000-4000-8000-0000000000e2', (select b from ids), '2026-11-10 18:00+00')) j;
select privado.excluir_conta('c8770000-0000-4000-8000-000000000005');
select is((select estado from public.vaga where id = (select (j->>'vaga_id')::uuid from ch5))::text, 'cancelada',
  'excluir_conta cancela a vaga da casa de membro único');
select is((select estado from public.chamada where id = (select (j->>'id')::uuid from ch5)), 'encerrada',
  'o gatilho vale para qualquer caminho: a chamada aberta da vaga cancelada vira encerrada');

-- ── 3. A chamada já vencida é do expirar_chamadas ──────────────────────────────
-- ch4 vence às 03:00 do dia 8 (início − 1 h, limitado a 12 h). Às 04:00 ela ainda está aberta,
-- à espera do job. O gatilho não a toca (o job a trava antes da vaga, na ordem inversa), e o job
-- a expira, com o aviso dele.
select set_config('frila.agora', '2026-11-08 04:00:00+00', true);
select is(pg_temp.r('c8770000-0000-4000-8000-000000000001',
  format($$ select public.cancelar_vaga(%L, 'Evento desmarcado') $$, (select j->>'vaga_id' from ch4))), 'ok',
  'a casa cancela a vaga cuja chamada já venceu');
select is((select estado from public.chamada where id = (select (j->>'id')::uuid from ch4)), 'aberta',
  'a chamada vencida fica para o job (o gatilho só fecha a que ainda está no prazo)');
select ok(privado.expirar_chamadas() >= 1, 'expirar_chamadas roda');
select is((select estado from public.chamada where id = (select (j->>'id')::uuid from ch4)), 'expirada',
  'o job a expira: nenhuma chamada aberta sobra na vaga cancelada');
select is((select count(*)::int from public.notificacao
            where usuario_id = 'c8770000-0000-4000-8000-000000000002' and tipo = 'chamada_cancelada'), 1,
  'a chamada vencida não ganha chamada_cancelada (o aviso dela é chamada_expirada)');

-- ── 4. Catálogo ──────────────────────────────────────────────────────────────
select has_trigger('public', 'vaga', 'vaga_cancelada_fecha_chamadas', 'public.vaga tem o gatilho vaga_cancelada_fecha_chamadas');
select is((select tgtype & 1 = 1 and tgtype & 2 = 0 from pg_trigger
            where tgrelid = 'public.vaga'::regclass and tgname = 'vaga_cancelada_fecha_chamadas'), true,
  'o gatilho é FOR EACH ROW e AFTER');
select is((select prosecdef from pg_proc where oid = 'privado.vaga_cancelada_fecha_chamadas()'::regprocedure), true,
  'a função do gatilho é SECURITY DEFINER');
select ok((select proconfig from pg_proc where oid = 'privado.vaga_cancelada_fecha_chamadas()'::regprocedure) @> array['search_path=""'],
  'a função do gatilho fixa search_path vazio');
select ok(not has_function_privilege('authenticated', 'privado.vaga_cancelada_fecha_chamadas()', 'execute')
      and not has_function_privilege('anon', 'privado.vaga_cancelada_fecha_chamadas()', 'execute'),
  'authenticated e anon não executam a função do gatilho');

select * from finish();
rollback;
