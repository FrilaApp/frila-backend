-- 808_chamada_direta_responder_cancelar_f4.sql
-- F4, parte B (contrato 0.2.55, RN32, RN33, RN36, RN42, RN46, RN12, RN16, RN19, RN21, RF26, CA7-CA12):
-- Testes exaustivos de responder_chamada, cancelar_chamada, concorrência, anti-sobreposição RN21,
-- garantia de 1 turno por posição, desfechos atômicos, suspensão, bloqueio, exclusão e retenção (15 e 90 dias).

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-808';

select plan(44);

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
select '00000000-0000-0000-0000-000000000000', ('c8080000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '@t808.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 6) n;

select pg_temp.como(('c8080000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195555808%s', '1990-01-01', '2026-09-22') $$,
  case when n in (1, 2, 6) then 'contratante' else 'profissional' end, n, n)) from generate_series(1, 6) n;

-- Estabelecimento 1 (Casa 1 - CNPJ)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c8080000-0000-4000-8000-0000000000e1', 'Restaurante 808', '80812345000101', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c8080000-0000-4000-8000-000000000001', 'c8080000-0000-4000-8000-0000000000e1', 'administrador');

-- Estabelecimento 2 (Casa 2 - CNPJ)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c8080000-0000-4000-8000-0000000000e2', 'Bar 808', '80812345000102', 'food_service', 'CLN 202',
        'POINT(-47.8825 -15.7945)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c8080000-0000-4000-8000-000000000006', 'c8080000-0000-4000-8000-0000000000e2', 'administrador');

-- Profissionais
insert into public.profissional (usuario_id, ponto_base)
select ('c8080000-0000-4000-8000-00000000000' || n)::uuid, 'POINT(-47.8822 -15.7800)'::extensions.geography
  from generate_series(3, 5) n;

create temp table prof_ids as select
  (select id from public.profissional where usuario_id = 'c8080000-0000-4000-8000-000000000003') as a,
  (select id from public.profissional where usuario_id = 'c8080000-0000-4000-8000-000000000004') as b,
  (select id from public.profissional where usuario_id = 'c8080000-0000-4000-8000-000000000005') as c;

insert into public.profissional_funcao select p, (select id from public.funcao where nome = 'garçom')
  from prof_ids, unnest(array[a, b, c]) p;

insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c8080000-0000-4000-8000-0000000000e1', p from prof_ids, unnest(array[a, b, c]) p;

insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c8080000-0000-4000-8000-0000000000e2', p from prof_ids, unnest(array[a, b, c]) p;

-- ── 1. Teste de Interruptor de Recurso (RN46) ───────────────────────────────────
select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000003',
    $$ select public.responder_chamada('c8080000-0000-4000-8000-0000000000c1', 'aceitar') $$),
  'sem_permissao:recurso_desligado',
  'responder_chamada com recurso desligado retorna 403 recurso_desligado'
);

select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000001',
    $$ select public.cancelar_chamada('c8080000-0000-4000-8000-0000000000c1') $$),
  'sem_permissao:recurso_desligado',
  'cancelar_chamada com recurso desligado retorna 403 recurso_desligado'
);

-- Liga o interruptor para os demais testes
update privado.recurso set ligado = true where chave = 'chamada_direta';

-- ── 2. Autenticação e Perfis ──────────────────────────────────────────────────
select is(
  pg_temp.r(null, $$ select public.responder_chamada('c8080000-0000-4000-8000-0000000000c1', 'aceitar') $$),
  'nao_autenticado',
  'responder_chamada sem autenticação retorna 401'
);

select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000001',
    $$ select public.responder_chamada('c8080000-0000-4000-8000-0000000000c1', 'aceitar') $$),
  'perfil_incompativel',
  'responder_chamada por contratante retorna 422 perfil_incompativel'
);

select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000003',
    $$ select public.cancelar_chamada('c8080000-0000-4000-8000-0000000000c1') $$),
  'perfil_incompativel',
  'cancelar_chamada por profissional retorna 422 perfil_incompativel'
);

select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000003',
    $$ select public.responder_chamada('c8080000-0000-4000-8000-0000000000c1', 'talvez') $$),
  'campo_invalido:resposta',
  'resposta inválida retorna 422 campo_invalido:resposta'
);

-- ── 3. Critério 1 (CA7): 3 chamadas concorrentes para a mesma vaga ────────────
-- Cria a vaga e as 3 chamadas abertas para prof A, B e C
create temp table vaga1 as select pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e1', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-08 18:00+00', fim_em => '2026-11-08 23:00+00', local => 'CLN 201 Bloco A',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 16000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Carlos',
     recado => 'Chegar 10 min antes') $$, (select a from prof_ids))) as j1;

create temp table ch_ids as select
  (select j1->>'id' from vaga1)::uuid as ch_a,
  (select j1->>'vaga_id' from vaga1)::uuid as vaga_id;

-- Chama B para a mesma vaga
select pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e1', vaga_id => %L) $$,
  (select b from prof_ids), (select vaga_id from ch_ids)));

-- Chama C para a mesma vaga
select pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e1', vaga_id => %L) $$,
  (select c from prof_ids), (select vaga_id from ch_ids)));

create temp table chamadas_vaga1 as select
  (select id from public.chamada where vaga_id = (select vaga_id from ch_ids) and profissional_id = (select a from prof_ids)) as id_a,
  (select id from public.chamada where vaga_id = (select vaga_id from ch_ids) and profissional_id = (select b from prof_ids)) as id_b,
  (select id from public.chamada where vaga_id = (select vaga_id from ch_ids) and profissional_id = (select c from prof_ids)) as id_c;

-- Profissional A aceita a chamada
create temp table resp_a as select pg_temp.como('c8080000-0000-4000-8000-000000000003', format(
  $$ select public.responder_chamada(%L, 'aceitar') $$, (select id_a from chamadas_vaga1))) as j;

select is((select j->'chamada'->>'estado' from resp_a), 'aceita', 'CA7: Profissional A tem chamada aceita com sucesso');
select ok((select j->>'turno_id' from resp_a) is not null, 'CA7: nasce o turno do Profissional A');
select is((select j->>'local' from resp_a), 'CLN 201 Bloco A', 'CA7: aceite confirmado libera o campo local');
select is((select j->>'responsavel_local' from resp_a), 'Gerente Carlos', 'CA7: aceite confirmado libera responsavel_local');
select ok((select j->'ponto'->>'latitude' from resp_a) is not null, 'CA7: aceite confirmado libera coordenadas');
select ok((select j->>'telefone' from resp_a) is null, 'CA11: NENHUM telefone é devolvido no aceite');

-- Vaga passou para preenchida
select is(
  (select estado::text from public.vaga where id = (select vaga_id from ch_ids)),
  'preenchida',
  'CA7: vaga passa para estado preenchida após confirmação'
);

-- Profissional B tenta aceitar a chamada concorrente perdedora
select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000004', format(
    $$ select public.responder_chamada(%L, 'aceitar') $$, (select id_b from chamadas_vaga1))),
  'chamada_indisponivel:encerrada',
  'CA7: perdedor da corrida simultânea recebe 409 chamada_indisponivel:encerrada'
);

-- Profissional C teve sua chamada encerrada automaticamente sem penalidade
select is(
  (select estado from public.chamada where id = (select id_c from chamadas_vaga1)),
  'encerrada',
  'CA7: terceira chamada é encerrada automaticamente sem penalidade'
);

-- Idempotência: Profissional A repete aceitar e recebe o mesmo resultado
select is(
  pg_temp.como('c8080000-0000-4000-8000-000000000003', format(
    $$ select public.responder_chamada(%L, 'aceitar') $$, (select id_a from chamadas_vaga1)))->>'turno_id',
  (select j->>'turno_id' from resp_a),
  'Idempotência: repetir aceitar devolve o mesmo turno_id'
);

-- Resposta divergente (A tenta recusar depois de aceitar) resulta em 409 chamada_indisponivel:aceita
select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000003', format(
    $$ select public.responder_chamada(%L, 'recusar') $$, (select id_a from chamadas_vaga1))),
  'chamada_indisponivel:aceita',
  'Resposta divergente após aceite retorna 409 chamada_indisponivel:aceita'
);

-- ── 4. Critério 2: Anti-sobreposição de agenda RN21 ───────────────────────────
-- Casa 2 chama o Profissional A para horário sobreposto (19:00 às 23:00 cruza com 18:00 às 23:00)
create temp table vaga_sobreposta as select pg_temp.como('c8080000-0000-4000-8000-000000000006', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e2', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-08 19:00+00', fim_em => '2026-11-08 23:00+00', local => 'CLN 202 Bloco B',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7945,"longitude":-47.8825}', valor_centavos => 17000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Ana') $$,
  (select a from prof_ids))) as j;

select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000003', format(
    $$ select public.responder_chamada(%L, 'aceitar') $$, (select (j->>'id')::uuid from vaga_sobreposta))),
  'inelegivel:turno_sobreposto',
  'RN21 / CA2: aceite com horário sobreposto retorna 422 inelegivel:turno_sobreposto'
);

-- A chamada sem aceite PERMANECE aberta até o prazo
select is(
  (select estado from public.chamada where id = (select (j->>'id')::uuid from vaga_sobreposta)),
  'aberta',
  'RN21 / CA2: chamada com conflito de sobreposição permanece aberta até o prazo'
);

-- Casa 2 chama Profissional A para horário contíguo (23:00 às 03:00 do dia seguinte)
create temp table vaga_contigua as select pg_temp.como('c8080000-0000-4000-8000-000000000006', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e2', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-08 23:00+00', fim_em => '2026-11-09 03:00+00', local => 'CLN 202 Bloco B',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7945,"longitude":-47.8825}', valor_centavos => 18000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Ana') $$,
  (select b from prof_ids))) as j;

select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000004', format(
    $$ select public.responder_chamada(%L, 'aceitar') $$, (select (j->>'id')::uuid from vaga_contigua))),
  'ok',
  'CA2: horários contíguos não geram sobreposição artificial e confirmam normalmente'
);

-- ── 5. Critério 3 (CA8): Expiração pelo relógio do servidor ───────────────────
create temp table vaga_expira as select pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e1', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-08 18:00+00', fim_em => '2026-11-08 23:00+00', local => 'CLN 201',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 15000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Carlos') $$,
  (select c from prof_ids))) as j;

-- Adiantamos o relógio do servidor para além do expira_em (expira_em = 2026-11-08 03:00+00)
select set_config('frila.agora', '2026-11-08 04:00:00+00', true);

select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000005', format(
    $$ select public.responder_chamada(%L, 'aceitar') $$, (select (j->>'id')::uuid from vaga_expira))),
  'chamada_indisponivel:expirada',
  'CA8: expira_em vencido retorna 409 chamada_indisponivel:expirada'
);

select is(
  (select count(*)::int from public.turno where posicao_id in (
    select id from public.posicao where vaga_id = (select (j->>'vaga_id')::uuid from vaga_expira))),
  0,
  'CA8: nenhum turno é criado para chamada expirada'
);

-- Volta o relógio e libera o par (como no teste 803)
select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
update public.chamada set estado = 'cancelada' where id = (select (j->>'id')::uuid from vaga_expira);

-- ── 6. Critério 4 (CA10): Cancelamento vs Aceite ─────────────────────────────
create temp table vaga_cancelar as select pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e1', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-09 18:00+00', fim_em => '2026-11-09 23:00+00', local => 'CLN 201',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 15000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Carlos') $$,
  (select c from prof_ids))) as j;

-- Outro contratante (não membro) tenta cancelar -> 403 sem_permissao
select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000002', format(
    $$ select public.cancelar_chamada(%L) $$, (select (j->>'id')::uuid from vaga_cancelar))),
  'sem_permissao',
  'cancelar_chamada por não membro retorna 403 sem_permissao'
);

-- Membro da casa cancela chamada aberta com sucesso
select is(
  pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
    $$ select public.cancelar_chamada(%L) $$, (select (j->>'id')::uuid from vaga_cancelar)))->>'estado',
  'cancelada',
  'CA10: membro cancela chamada aberta com sucesso'
);

-- Idempotência de cancelar_chamada
select is(
  pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
    $$ select public.cancelar_chamada(%L) $$, (select (j->>'id')::uuid from vaga_cancelar)))->>'estado',
  'cancelada',
  'Idempotência: repetir cancelar_chamada devolve o mesmo registro com estado cancelada'
);

-- Profissional tenta aceitar chamada que foi cancelada
select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000005', format(
    $$ select public.responder_chamada(%L, 'aceitar') $$, (select (j->>'id')::uuid from vaga_cancelar))),
  'chamada_indisponivel:cancelada',
  'CA10: tentar aceitar chamada cancelada retorna 409 chamada_indisponivel:cancelada'
);

-- Para chamada já aceita (vaga1 Prof A), contratante tenta cancelar_chamada
select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000001', format(
    $$ select public.cancelar_chamada(%L) $$, (select id_a from chamadas_vaga1))),
  'chamada_indisponivel:aceita',
  'CA10: cancelar_chamada em chamada já aceita retorna 409 chamada_indisponivel:aceita (exige RN12)'
);

-- ── 7. Critério 5 (RN33 / CA11): Recusa e Limites ─────────────────────────────
create temp table vaga_recusa as select pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e1', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-10 18:00+00', fim_em => '2026-11-10 23:00+00', local => 'CLN 201',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 15000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Carlos') $$,
  (select c from prof_ids))) as j;

-- Recusa com motivo inválido
select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000005', format(
    $$ select public.responder_chamada(%L, 'recusar', 'preguiça') $$, (select (j->>'id')::uuid from vaga_recusa))),
  'campo_invalido:motivo_recusa',
  'Recusa com motivo fora do enum retorna 422 campo_invalido:motivo_recusa'
);

-- Recusa com sucesso e motivo válido
create temp table resp_recusa as select pg_temp.como('c8080000-0000-4000-8000-000000000005', format(
  $$ select public.responder_chamada(%L, 'recusar', 'agenda') $$, (select (j->>'id')::uuid from vaga_recusa))) as r;

select is((select r->'chamada'->>'estado' from resp_recusa), 'recusada', 'Recusa registrada com sucesso');
select is((select r->'chamada'->>'motivo_recusa' from resp_recusa), 'agenda', 'Motivo da recusa registrado');

-- Idempotência da recusa
select is(
  pg_temp.como('c8080000-0000-4000-8000-000000000005', format(
    $$ select public.responder_chamada(%L, 'recusar', 'agenda') $$, (select (j->>'id')::uuid from vaga_recusa)))->'chamada'->>'estado',
  'recusada',
  'Idempotência: repetir recusa devolve registro recusada'
);

-- Reputação e histórico não são afetados por recusa ou expiração
select is(
  (select count(*)::int from public.ocorrencia where autor_id = 'c8080000-0000-4000-8000-000000000005'),
  0,
  'RN33: nenhuma ocorrência ou falta registrada por recusa'
);

-- ── 8. Critério 6 (RN42 / CA12): Elegibilidade Dinâmica, Suspensão e Exclusão ──

-- A. Bloqueio mútuo: profissional bloqueado com estabelecimento
create temp table vaga_bloqueio as select pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e1', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-11 18:00+00', fim_em => '2026-11-11 23:00+00', local => 'CLN 201',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 15000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Carlos') $$,
  (select c from prof_ids))) as j;

-- Estabelecimento bloqueia o Profissional C
insert into public.bloqueio (autor_id, bloqueado_id)
values ('c8080000-0000-4000-8000-000000000001', 'c8080000-0000-4000-8000-000000000005');

select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000005', format(
    $$ select public.responder_chamada(%L, 'aceitar') $$, (select (j->>'id')::uuid from vaga_bloqueio))),
  'nao_encontrado',
  'RN42 / CA12: bloqueio mútuo retorna 404 nao_encontrado'
);

select is(
  (select estado from public.chamada where id = (select (j->>'id')::uuid from vaga_bloqueio)),
  'encerrada',
  'RN42 / CA12: chamada de profissional bloqueado é encerrada'
);

-- B. Função removida do perfil profissional
create temp table vaga_sem_funcao as select pg_temp.como('c8080000-0000-4000-8000-000000000006', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e2', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-12 18:00+00', fim_em => '2026-11-12 23:00+00', local => 'CLN 202',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7945,"longitude":-47.8825}', valor_centavos => 17000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Ana') $$,
  (select c from prof_ids))) as j;

-- Profissional C desmarca a função de garçom
delete from public.profissional_funcao
 where profissional_id = (select c from prof_ids)
   and funcao_id = (select id from public.funcao where nome = 'garçom');

select is(
  pg_temp.r('c8080000-0000-4000-8000-000000000005', format(
    $$ select public.responder_chamada(%L, 'aceitar') $$, (select (j->>'id')::uuid from vaga_sem_funcao))),
  'inelegivel:funcao_incompativel',
  'RN42 / CA12: função removida entre envio e resposta recusa com 422 inelegivel:funcao_incompativel'
);

-- C. Suspensão de contratante: encerra chamadas abertas dele com aviso ao profissional
create temp table vaga_susp_estab as select pg_temp.como('c8080000-0000-4000-8000-000000000006', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e2', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-13 18:00+00', fim_em => '2026-11-13 23:00+00', local => 'CLN 202',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7945,"longitude":-47.8825}', valor_centavos => 17000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Ana') $$,
  (select b from prof_ids))) as j;

-- Suspende o membro contratante u6
update public.usuario set estado = 'suspensa' where id = 'c8080000-0000-4000-8000-000000000006';

select is(
  (select estado from public.chamada where id = (select (j->>'id')::uuid from vaga_susp_estab)),
  'encerrada',
  'RN42 / CD-C18: gatilho de suspensão de contratante encerra chamadas abertas criadas por ele'
);

select ok(
  exists (select 1 from public.notificacao
           where usuario_id = 'c8080000-0000-4000-8000-000000000004'
             and tipo = 'chamada_encerrada'),
  'RN42 / CD-C18: notificação chamada_encerrada enviada ao profissional'
);

-- D. Suspensão de profissional: cancela chamadas abertas dele
create temp table vaga_susp_prof as select pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e1', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-14 18:00+00', fim_em => '2026-11-14 23:00+00', local => 'CLN 201',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 15000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Carlos') $$,
  (select b from prof_ids))) as j;

-- Suspende Profissional B (u4)
update public.usuario set estado = 'suspensa' where id = 'c8080000-0000-4000-8000-000000000004';

select is(
  (select estado from public.chamada where id = (select (j->>'id')::uuid from vaga_susp_prof)),
  'cancelada',
  'RN42 / CD-C18: gatilho de suspensão de profissional cancela chamadas abertas dele'
);

-- E. Exclusão de conta: cancela chamadas abertas na hora e sanitiza recado aos 15 dias
create temp table vaga_exclusao as select pg_temp.como('c8080000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c8080000-0000-4000-8000-0000000000e1', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-15 18:00+00', fim_em => '2026-11-15 23:00+00', local => 'CLN 201',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 15000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Carlos',
     recado => 'Recado confidencial de teste') $$,
  (select a from prof_ids))) as j;

-- Anonimiza / exclui a conta u1
update public.usuario
   set estado = 'anonimizada',
       anonimizado_em = privado.agora() - interval '16 days'
 where id = 'c8080000-0000-4000-8000-000000000001';

select is(
  (select estado from public.chamada where id = (select (j->>'id')::uuid from vaga_exclusao)),
  'cancelada',
  'RN42 / CD-C19: na exclusão de conta, chamadas abertas são canceladas na hora'
);

-- Rotina de 15 dias de exclusão de conta sanitiza recado
select ok(
  privado.limpar_contas_anonimizadas(15) >= 1,
  'RN42 / CD-C19: rotina limpar_contas_anonimizadas executa com sucesso'
);

select is(
  (select recado from public.chamada where id = (select (j->>'id')::uuid from vaga_exclusao)),
  null,
  'RN42 / CD-C19: recado é removido aos 15 dias de exclusão da conta'
);

-- F. Rotina de retenção de 90 dias apaga chamadas não aceitas
select ok(
  privado.limpar_chamadas_expurgadas(0) >= 1,
  'RN42 / CD-C19: limpar_chamadas_expurgadas remove chamadas com desfecho'
);

-- A chamada aceita com turno (vaga 1 Prof A) sobrevive à limpeza de 90 dias
select ok(
  exists (select 1 from public.chamada where id = (select id_a from chamadas_vaga1) and estado = 'aceita'),
  'RN42 / CD-C19: chamada aceita sobrevive à limpeza de 90 dias porque virou turno'
);

-- Executar retenção diária consolidada roda limpa
select ok(
  (privado.executar_retencao_diaria()->>'expurgo_chamadas_nao_aceitas') is not null,
  'privado.executar_retencao_diaria inclui expurgo de chamadas não aceitas'
);

select * from finish();
rollback;
