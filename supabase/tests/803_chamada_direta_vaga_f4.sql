-- 803_chamada_direta_vaga_f4.sql · F4 parte A (contrato 0.2.55): chamar_profissional, a vaga
-- direta fora da lista e da tabela para terceiros, e uma violadora por restrição nova.
-- Casa CPF (J7). A: equipe de confiança. B: sem vínculo. C: turno cumprido e verificado.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-803';
select plan(34);

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
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_por, publicado_em)
values ('c8030000-0000-4000-8000-0000000000f1', 'c8030000-0000-4000-8000-0000000000e1',
  (select id from public.funcao where nome = 'garçom'), '2026-11-01 18:00+00', '2026-11-01 23:00+00', 'CLN 201',
  'POINT(-47.8822 -15.7942)'::extensions.geography, 12000, 1, true, false, false, 'Maitre', 'urgencia',
  gen_random_uuid(), 'c8030000-0000-4000-8000-000000000001', '2026-10-31 12:00+00');
insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
select 'c8030000-0000-4000-8000-0000000000f2', 'c8030000-0000-4000-8000-0000000000f1', 'cumprida', c,
       '2026-11-01 10:00+00', '2026-11-01 18:00+00', '2026-11-01 23:00+00' from ids;
insert into public.turno (posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('c8030000-0000-4000-8000-0000000000f2', '2026-11-01 18:00+00', 'geolocalizado', 50, 'verificado', 12000);

-- ── Interruptor e autorização ────────────────────────────────────────────────
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', pg_temp.nova((select a from ids))),
  'sem_permissao:recurso_desligado', 'F4 nasce desligada: 403 recurso_desligado');
update privado.recurso set ligado = true where chave = 'chamada_direta';
-- 0.2.66 (20261108160000): só se chama quem tem aparelho na versão mínima de chamada_direta.
-- Este arquivo mede a chamada com o portão satisfeito; o portão em si é o 830.
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do nothing;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select p.usuario_id, 'tok-teste-' || p.usuario_id, 'ios', '1.2.0'
  from public.profissional p where p.usuario_id::text like 'c8030000-%'
on conflict (token_fcm) do nothing;
select is(pg_temp.r(null, pg_temp.nova((select a from ids))), 'nao_autenticado', 'sem sessão: 401');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000005', pg_temp.nova((select a from ids))),
  'sem_permissao', 'contratante que não é membro: 403');

-- ── O caminho feliz ──────────────────────────────────────────────────────────
create temp table ch as select pg_temp.como('c8030000-0000-4000-8000-000000000001',
  pg_temp.nova((select a from ids), 'c8030000-0000-4000-8000-0000000000c1')) j;
select is((select j->>'estado' from ch), 'aberta', 'a chamada nasce aberta');
select is((select (j->>'expira_em')::timestamptz from ch), '2026-11-08 03:00+00'::timestamptz,
  'expira_em = menor entre envio + 12 h e início − 1 h');
select results_eq(format($$ select origem, modo::text, posicoes::int from public.vaga where id = %L $$,
  (select j->>'vaga_id' from ch)), $$ values ('chamada_direta', 'urgencia', 1) $$, 'vaga direta: urgência, uma posição');
select is((select pg_temp.como('c8030000-0000-4000-8000-000000000001',
  pg_temp.nova((select a from ids), 'c8030000-0000-4000-8000-0000000000c1'))->>'id'), (select j->>'id' from ch),
  'reenviar a mesma chave devolve a mesma chamada');
select is((select count(*)::int from public.chamada), 1, 'e não cria outra');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', pg_temp.nova((select a from ids))),
  'chamada_ja_aberta', '409: o par já tem chamada aberta (RN34)');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8030000-0000-4000-8000-0000000000e1', vaga_id => %L) $$,
  (select c from ids), (select j->>'vaga_id' from ch))), 'ok', 'chamar mais alguém (turno cumprido) para a mesma vaga');

-- ── As recusas ───────────────────────────────────────────────────────────────
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', pg_temp.nova('c8030000-0000-4000-8000-0000000000ff')),
  'nao_encontrado', '404: profissional inexistente');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', pg_temp.nova((select b from ids))),
  'profissional_indisponivel:nao_aceita_chamadas', '422: sem vínculo, a recusa genérica');
-- 0.2.66: a recusa genérica vem antes da validação do corpo, então sem vínculo o corpo inválido também
-- dá nao_aceita_chamadas (830). Para medir a RN02, o B ganha vínculo só nesta asserção.
insert into public.equipe_confianca (estabelecimento_id, profissional_id) select 'c8030000-0000-4000-8000-0000000000e1', b from ids;
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', replace(pg_temp.nova((select b from ids)), ', local => ''CLN 201''', '')),
  'campo_obrigatorio:local', '422: campo da RN02 ausente');
delete from public.equipe_confianca where estabelecimento_id = 'c8030000-0000-4000-8000-0000000000e1'
   and profissional_id = (select b from ids);
update public.chamada set estado = 'cancelada';
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', pg_temp.nova((select a from ids), inicio => '2026-11-07 16:30+00')),
  'profissional_indisponivel:antecedencia_insuficiente', '422: menos de 2 h para o início');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8030000-0000-4000-8000-0000000000e1', vaga_id => 'c8030000-0000-4000-8000-0000000000f1') $$,
  (select a from ids))), 'vaga_encerrada', '409: vaga_id de vaga que não é direta');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', pg_temp.nova((select c from ids))),
  'ok', '2ª chamada a C em 7 dias não pede confirmação');
update public.chamada set estado = 'cancelada';
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', pg_temp.nova((select c from ids))),
  'recorrencia_nao_confirmada', '409: 3ª chamada de casa CPF em 7 dias sem confirmação (J7)');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000001', pg_temp.nova((select c from ids), extra => ', confirmo_recorrencia => true')),
  'ok', 'com confirmo_recorrencia a chamada sai');

-- ── Fora da lista e da tabela ────────────────────────────────────────────────
select is((select count(*)::int from jsonb_array_elements(pg_temp.como('c8030000-0000-4000-8000-000000000002',
  $$ select public.vagas_abertas(-15.7942, -47.8822) $$)) e where e->'estabelecimento'->>'id' = 'c8030000-0000-4000-8000-0000000000e1'),
  0, 'vagas_abertas nunca lista vaga direta');
select is(pg_temp.como('c8030000-0000-4000-8000-000000000003',
  $$ select to_jsonb(count(*)) from public.vaga where origem = 'chamada_direta' $$), '0'::jsonb,
  'terceiro não lê a vaga direta pela tabela');
select ok((pg_temp.como('c8030000-0000-4000-8000-000000000001',
  $$ select to_jsonb(count(*)) from public.vaga where origem = 'chamada_direta' $$))::int >= 1, 'o membro lê');

-- detalhe_vaga e candidatar são SECURITY DEFINER: a recusa tem de estar nelas, não só na política.
select is(pg_temp.r('c8030000-0000-4000-8000-000000000003',
  $$ select public.detalhe_vaga('c8030000-0000-4000-8000-0000000000f1') $$),
  'ok', 'controle: o terceiro abre o detalhe de vaga de publicação');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000003',
  format($$ select public.detalhe_vaga(%L) $$, (select j->>'vaga_id' from ch))),
  'nao_encontrado', 'detalhe_vaga: 404 ao terceiro na vaga direta');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000003',
  format($$ select public.candidatar(%L) $$, (select j->>'vaga_id' from ch))),
  'nao_encontrado', 'candidatar: 404 ao terceiro na vaga direta');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000002',
  format($$ select public.candidatar(%L) $$, (select j->>'vaga_id' from ch))),
  'nao_encontrado', 'candidatar: 404 também ao chamado, o aceite é por responder_chamada (RN28)');
select is(pg_temp.r('c8030000-0000-4000-8000-000000000002',
  format($$ select public.detalhe_vaga(%L) $$, (select j->>'vaga_id' from ch))),
  'nao_encontrado', 'detalhe_vaga: 404 ao chamado antes do aceite (lê por detalhe_chamada)');
update public.posicao set estado = 'confirmada', profissional_id = (select a from ids), confirmado_em = privado.agora()
 where vaga_id = (select (j->>'vaga_id')::uuid from ch);
select is(pg_temp.como('c8030000-0000-4000-8000-000000000002',
  format($$ select public.detalhe_vaga(%L) $$, (select j->>'vaga_id' from ch)))->>'id', (select j->>'vaga_id' from ch),
  'detalhe_vaga: o profissional confirmado na vaga direta lê');

-- ── Uma violadora por restrição nova ─────────────────────────────────────────
select throws_ok($$ update public.vaga set origem = 'outra' where id = 'c8030000-0000-4000-8000-0000000000f1' $$,
  '23514', 'new row for relation "vaga" violates check constraint "vaga_origem_check"', 'vaga_origem_check');
select throws_ok($$ update public.chamada set estado = 'pendente' $$,
  '23514', 'new row for relation "chamada" violates check constraint "chamada_estado_check"', 'chamada_estado_check');
select throws_ok($$ update public.chamada set motivo_recusa = 'preguica' $$,
  '23514', 'new row for relation "chamada" violates check constraint "chamada_motivo_recusa_check"', 'chamada_motivo_recusa_check');
select throws_ok($$ update public.chamada set recado = repeat('a', 301) $$,
  '23514', 'new row for relation "chamada" violates check constraint "chamada_recado_check"', 'chamada_recado_check');
select throws_ok($$ insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, chave, estado)
  select 'c8030000-0000-4000-8000-0000000000f1', (select a from ids), estabelecimento_id, criada_por, expira_em, chave, 'cancelada'
    from public.chamada where profissional_id = (select c from ids) limit 1 $$,
  '23505', 'duplicate key value violates unique constraint "chamada_chave_unica"', 'chamada_chave_unica (idempotência)');
select throws_ok($$ insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, chave, estado)
  select vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, gen_random_uuid(), 'cancelada' from public.chamada limit 1 $$,
  '23505', 'duplicate key value violates unique constraint "chamada_uma_por_vaga_e_profissional"', 'chamada_uma_por_vaga_e_profissional');
select throws_ok($$ insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, chave)
  select 'c8030000-0000-4000-8000-0000000000f1', profissional_id, estabelecimento_id, criada_por, expira_em, gen_random_uuid()
    from public.chamada where estado = 'aberta' limit 1 $$,
  '23505', 'duplicate key value violates unique constraint "chamada_uma_aberta_por_par"', 'chamada_uma_aberta_por_par (RN34)');

select * from finish();
rollback;
