-- 874_trabalho_ja_aberto.sql
--
-- Um trabalho, uma vaga direta (migração 20261117020000, contrato 0.2.95, frila-backend#520).
--   A  os dois caminhos: sem vaga_id para trabalho já aberto, 409 trabalho_ja_aberto com o vaga_id dele,
--      nada criado; com esse vaga_id (e a mesma chave), a chamada entra; o horário compara até o minuto;
--      os termos não entram; outro minuto, outra função ou outra casa é outro trabalho
--   B  a ordem: depois de chamada_ja_aberta e de regiao_id; antes da pausa, das validações dos outros campos
--      e dos limites; só com função e horário conhecidos; vaga de outra casa segue 404
--   C  o que é "trabalho aberto": chamada vencida pelo relógio, vaga preenchida e vaga sem chamada aberta
--      não contam; vaga preenchida com outra aberta do mesmo trabalho = trabalho_ja_aberto (antes de
--      vaga_encerrada); duplicatas de antes da versão: vale a publicada primeiro
--   D  a chave: reenviar a da chamada que criou o trabalho devolve a mesma chamada
--   E  a casa lê os termos do trabalho aberto pelas próprias chamadas (minhas_chamadas, detalhe_chamada)
--   F  publicar_a_partir_da_chamada encerra as vagas diretas irmãs publicadas e as chamadas abertas delas,
--      com aviso; a preenchida, a de outro horário e a de outra casa ficam
--   G  a conferência e a releitura da chave vêm depois da trava da casa, nas duas funções (a corrida em si
--      é provada com duas conexões em scripts/corrida-chamada.sh, cenários 3b e 3c)
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
-- 16/11/2026, 12:00 em Brasília (fora do silêncio das chamadas).
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-874';
select plan(47);

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;
-- O envelope da recusa ("status code details"), ou 'ok'.
create function pg_temp.tenta(conta uuid, sql text) returns text language plpgsql as $$
declare m text; d text;
begin
  perform pg_temp.como(conta, sql);
  return 'ok';
exception when others then
  get stacked diagnostics m = message_text, d = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return case when m ~ '^\s*\{' then concat_ws(' ', d::jsonb->>'status', m::jsonb->>'code', m::jsonb->>'details') else m end;
end $$;
create function pg_temp.u(n int) returns uuid language sql immutable as $$
  select ('c8740000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.p(n int) returns uuid language sql immutable as $$
  select ('c8740000-0000-4000-8000-0000000001' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.casa(n int) returns uuid language sql immutable as $$
  select ('c8740000-0000-4000-8000-00000000e0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.k(n int) returns uuid language sql immutable as $$
  select ('c8740000-0000-4000-8000-00000000c0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.garcom() returns uuid language sql stable as $$ select id from public.funcao where nome = 'garçom' $$;
create function pg_temp.outra() returns uuid language sql stable as $$
  select id from public.funcao where nome <> 'garçom' order by nome limit 1 $$;

-- chamar_profissional sem vaga_id, com o corpo inteiro; extra acrescenta argumentos.
create function pg_temp.chamar(conta uuid, casa uuid, prof int, inicio text, fim text, extra text default '',
                               chave uuid default gen_random_uuid(), funcao uuid default null,
                               valor int default 15000) returns text
language sql as $$
  select pg_temp.tenta(conta, format($a$ select public.chamar_profissional(chave => %L,
    profissional_id => %L, estabelecimento_id => %L, funcao_id => %L, inicio_em => %L, fim_em => %L,
    local => 'CLN 201', regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
    valor_centavos => %s, inclui_refeicao => true, inclui_transporte => false,
    exige_material_proprio => false, responsavel_local => 'Maitre' %s) $a$,
    chave, pg_temp.p(prof), casa, coalesce(funcao, pg_temp.garcom()), inicio::timestamptz, fim::timestamptz, valor, extra)) $$;
-- A chamada pela vaga direta (sem os campos do trabalho).
create function pg_temp.chamar_vaga(conta uuid, casa uuid, prof int, vaga uuid, chave uuid default gen_random_uuid())
returns text language sql as $$
  select pg_temp.tenta(conta, format($a$ select public.chamar_profissional(chave => %L,
    profissional_id => %L, estabelecimento_id => %L, vaga_id => %L) $a$, chave, pg_temp.p(prof), casa, vaga)) $$;
-- A vaga e a chamada do profissional n na casa.
create function pg_temp.vaga_de(casa uuid, prof int) returns uuid language sql stable as $$
  select c.vaga_id from public.chamada c where c.estabelecimento_id = casa and c.profissional_id = pg_temp.p(prof)
   order by c.criada_em desc limit 1 $$;
create function pg_temp.chamada_de(casa uuid, prof int) returns uuid language sql stable as $$
  select c.id from public.chamada c where c.estabelecimento_id = casa and c.profissional_id = pg_temp.p(prof)
   order by c.criada_em desc limit 1 $$;
create function pg_temp.responder(prof int, chamada uuid, resposta text) returns text language sql as $$
  select pg_temp.tenta(pg_temp.u(prof), format($a$ select public.responder_chamada(%L, %L, %L) $a$,
    chamada, resposta, case when resposta = 'recusar' then 'agenda' end)) $$;
-- Um turno cumprido e verificado da casa (tira a casa do limite de casa nova: 10 abertas e 20 por dia).
create function pg_temp.turno(p_estab uuid, p_prof uuid, p_inicio timestamptz) returns void language plpgsql as $$
declare v_vaga uuid := gen_random_uuid(); v_pos uuid := gen_random_uuid();
begin
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto, valor_centavos,
                           posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo,
                           chave_cliente, publicado_em, estado)
  values (v_vaga, p_estab, pg_temp.garcom(), (select usuario_id from public.membro_estabelecimento where estabelecimento_id = p_estab limit 1),
          p_inicio, p_inicio + interval '6 hours', 'Local 874', 'POINT(-47.88 -15.78)'::extensions.geography, 15000, 1,
          true, false, false, 'Responsável 874', 'urgencia', gen_random_uuid(), p_inicio - interval '2 days', 'encerrada');
  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos, v_vaga, p_prof, 'cumprida', p_inicio - interval '1 day', false, p_inicio, p_inicio + interval '6 hours');
  insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
  values (gen_random_uuid(), v_pos, p_inicio, p_inicio + interval '6 hours', 'geolocalizado', 50, 'verificado', 15000);
end $$;
-- Uma vaga direta "de antes desta versão", com uma chamada aberta, inserida direto.
create function pg_temp.vaga_antiga(p_id uuid, p_estab uuid, p_prof uuid, p_inicio timestamptz, p_publicada timestamptz)
returns void language plpgsql as $$
begin
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto, valor_centavos,
                           posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo,
                           chave_cliente, publicado_em, estado, origem)
  values (p_id, p_estab, pg_temp.garcom(), pg_temp.u(1), p_inicio, p_inicio + interval '5 hours', 'CLN 201',
          'POINT(-47.8822 -15.7942)'::extensions.geography, 15000, 1, true, false, false, 'Maitre', 'urgencia',
          gen_random_uuid(), p_publicada, 'publicada', 'chamada_direta');
  insert into public.posicao (vaga_id, inicio_em, fim_em) values (p_id, p_inicio, p_inicio + interval '5 hours');
  insert into public.chamada (vaga_id, profissional_id, estabelecimento_id, criada_por, expira_em, chave, criada_em)
  values (p_id, p_prof, p_estab, pg_temp.u(1), '2026-11-17 03:00+00', gen_random_uuid(), p_publicada);
end $$;

-- ── Massa ─────────────────────────────────────────────────────────────────────
-- Contratantes 1 (casa 1) e 2 (casa 2); profissionais 11 a 33, na equipe de confiança das duas casas.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.u(n), 'authenticated', 'authenticated',
       'p' || n || '@t874.test', privado.agora(), privado.agora(), false, false
  from (select generate_series(1, 2) union all select generate_series(11, 33)) s(n);
select pg_temp.como(pg_temp.u(n), format(
  $$ select public.criar_conta(%L, %L, %L, '1990-01-01', '2026-11-13') $$,
  case when n <= 2 then 'contratante' else 'profissional' end, 'Pessoa ' || n || ' Sintética',
  '+55619555874' || lpad(n::text, 2, '0')))
  from (select generate_series(1, 2) union all select generate_series(11, 33)) s(n);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  (pg_temp.casa(1), 'Casa 874 Um',   '87412345000169', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  (pg_temp.casa(2), 'Casa 874 Dois', '87412345000270', 'food_service', 'CLN 202', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  (pg_temp.u(1), pg_temp.casa(1), 'administrador'), (pg_temp.u(2), pg_temp.casa(2), 'administrador');
insert into public.profissional (id, usuario_id, ponto_base)
select pg_temp.p(n), pg_temp.u(n), 'POINT(-47.8822 -15.7852)'::extensions.geography from generate_series(11, 33) n;
insert into public.profissional_funcao (profissional_id, funcao_id)
select pg_temp.p(n), case when n in (18, 23) then pg_temp.outra() else pg_temp.garcom() end from generate_series(11, 33) n;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select pg_temp.u(n), 'tok-874-' || n || '-000000000000000000', 'ios', '1.2.0' from generate_series(11, 33) n;
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select c, pg_temp.p(n) from generate_series(11, 33) n, unnest(array[pg_temp.casa(1), pg_temp.casa(2)]) c;
-- 13 está em pausa de chamadas.
insert into public.profissional_preferencia_chamada (profissional_id) values (pg_temp.p(13));
update public.profissional_preferencia_chamada set pausado_ate = '2026-11-30' where profissional_id = pg_temp.p(13);
select pg_temp.turno(pg_temp.casa(1), pg_temp.p(33), '2026-11-01 10:00-03');

update privado.recurso set ligado = true where chave = 'chamada_direta';
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

create temp table vagas (nome text primary key, id uuid);

-- ══ A. Os dois caminhos ═══════════════════════════════════════════════════════
-- O trabalho T: garçom, 20/11 das 18:00 às 23:00 (UTC), com os segundos do relógio, como os apps mandam.
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 11, '2026-11-20 18:00:05+00', '2026-11-20 23:00:07+00',
                         chave => pg_temp.k(11)), 'ok',
  'A1 a 1ª chamada sem vaga_id cria a vaga direta do trabalho');
insert into vagas values ('V1', pg_temp.vaga_de(pg_temp.casa(1), 11));
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 12, '2026-11-20 18:00:41+00', '2026-11-20 23:00:59+00',
                         chave => pg_temp.k(12)),
  '409 trabalho_ja_aberto ' || (select id from vagas where nome = 'V1'),
  'A2 outra pessoa, sem vaga_id, para o mesmo trabalho (outros segundos, o mesmo minuto): 409 trabalho_ja_aberto com o vaga_id em details');
select is((select count(*)::int from public.vaga g where g.estabelecimento_id = pg_temp.casa(1) and g.origem = 'chamada_direta'), 1,
  'A3 a recusa não cria vaga');
select is((select count(*)::int from public.chamada c where c.profissional_id = pg_temp.p(12)), 0,
  'A4 nem chamada');
select is(pg_temp.chamar_vaga(pg_temp.u(1), pg_temp.casa(1), 12, (select id from vagas where nome = 'V1'), pg_temp.k(12)), 'ok',
  'A5 repetida com o vaga_id da recusa e a MESMA chave (a recusa não a consumiu): a chamada entra');
select is(pg_temp.vaga_de(pg_temp.casa(1), 12), (select id from vagas where nome = 'V1'),
  'A6 e entra no trabalho que já estava aberto');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 14, '2026-11-20 18:00:00+00', '2026-11-20 23:00:00+00',
                         extra => ', recado => ''outro valor''', valor => 22000),
  '409 trabalho_ja_aberto ' || (select id from vagas where nome = 'V1'),
  'A7 outro valor e recado: os termos não entram no que identifica o trabalho');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 15, '2026-11-20 18:01:00+00', '2026-11-20 23:00:00+00'), 'ok',
  'A8 início em outro minuto: outro trabalho, a chamada cria a vaga');
insert into vagas values ('V2', pg_temp.vaga_de(pg_temp.casa(1), 15));
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 16, '2026-11-20 18:00:00+00', '2026-11-20 23:01:00+00'), 'ok',
  'A9 fim em outro minuto: outro trabalho');
insert into vagas values ('V3', pg_temp.vaga_de(pg_temp.casa(1), 16));
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 18, '2026-11-20 18:00:05+00', '2026-11-20 23:00:07+00',
                         funcao => pg_temp.outra()), 'ok',
  'A10 mesmo horário, outra função: outro trabalho');
insert into vagas values ('V4', pg_temp.vaga_de(pg_temp.casa(1), 18));
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 17, '2026-11-20 18:00:05+00', '2026-11-20 23:00:07+00'), 'ok',
  'A11 o mesmo horário e a mesma função em OUTRA casa: a trava é por casa');

-- ══ B. A ordem ════════════════════════════════════════════════════════════════
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 11, '2026-11-20 18:00:05+00', '2026-11-20 23:00:07+00'),
  '409 chamada_ja_aberta',
  'B1 o mesmo profissional de novo: 409 chamada_ja_aberta vem antes');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 13, '2026-11-20 18:00:05+00', '2026-11-20 23:00:07+00'),
  '409 trabalho_ja_aberto ' || (select id from vagas where nome = 'V1'),
  'B2 profissional em pausa: a recusa do trabalho vem antes de qualquer conferência sobre ele');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 13, '2026-11-20 19:00:00+00', '2026-11-20 23:00:00+00'),
  '422 profissional_indisponivel pausado',
  'B3 (controle) o mesmo profissional para outro horário: a pausa vale');
select is(pg_temp.tenta(pg_temp.u(1), format($a$ select public.chamar_profissional(chave => gen_random_uuid(),
    profissional_id => %L, estabelecimento_id => %L, funcao_id => %L,
    inicio_em => '2026-11-20 18:00:05+00', fim_em => '2026-11-20 23:00:07+00') $a$,
    pg_temp.p(19), pg_temp.casa(1), pg_temp.garcom())),
  '409 trabalho_ja_aberto ' || (select id from vagas where nome = 'V1'),
  'B4 corpo só com função e horário: a recusa vem antes das validações dos outros campos');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 19, '2026-11-20 18:00:05+00', '2026-11-20 23:00:07+00',
                         extra => ', regiao_id => 999'),
  '422 campo_invalido regiao_id',
  'B5 regiao_id inválido vem antes');
select is(pg_temp.tenta(pg_temp.u(1), format($a$ select public.chamar_profissional(chave => gen_random_uuid(),
    profissional_id => %L, estabelecimento_id => %L,
    inicio_em => '2026-11-20 18:00:05+00', fim_em => '2026-11-20 23:00:07+00') $a$, pg_temp.p(19), pg_temp.casa(1))),
  '422 campo_obrigatorio exige_material_proprio',
  'B6 sem a função a conferência não roda: segue a recusa de sempre (o 1º campo que falta)');
select is(pg_temp.chamar_vaga(pg_temp.u(1), pg_temp.casa(1), 19, pg_temp.vaga_de(pg_temp.casa(2), 17)),
  '404 nao_encontrado',
  'B7 vaga_id de outra casa: 404, como antes');

-- ══ C. O que é trabalho aberto ═════════════════════════════════════════════════
-- C1. Chamada vencida pelo relógio, ainda com estado aberta (a rotina de expiração não passou): não conta.
update public.chamada set criada_em = '2026-11-16 03:00+00', lembrete_em = null, expira_em = '2026-11-16 14:59+00'
 where vaga_id = (select id from vagas where nome = 'V2');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 20, '2026-11-20 18:01:30+00', '2026-11-20 23:00:30+00'), 'ok',
  'C1 a chamada do trabalho venceu (agora >= expira_em), mesmo "aberta": não há trabalho aberto, nasce vaga nova');
select isnt(pg_temp.vaga_de(pg_temp.casa(1), 20), (select id from vagas where nome = 'V2'),
  'C2 em outra vaga');
-- C3. Vaga preenchida: a pessoa aceitou. A chamada seguinte sem vaga_id cria outra vaga (duas pessoas, uma de cada vez).
select is(pg_temp.responder(16, pg_temp.chamada_de(pg_temp.casa(1), 16), 'aceitar'), 'ok', 'C3 (montagem) 16 aceita a V3');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 21, '2026-11-20 18:00:00+00', '2026-11-20 23:01:00+00'), 'ok',
  'C4 vaga preenchida não conta: a chamada sem vaga_id cria a vaga da 2ª pessoa');
insert into vagas values ('V3b', pg_temp.vaga_de(pg_temp.casa(1), 21));
select is(pg_temp.chamar_vaga(pg_temp.u(1), pg_temp.casa(1), 22, (select id from vagas where nome = 'V3')),
  '409 trabalho_ja_aberto ' || (select id from vagas where nome = 'V3b'),
  'C5 vaga_id da vaga preenchida com outra aberta do mesmo trabalho: trabalho_ja_aberto, antes de vaga_encerrada');
-- C6. Vaga sem chamada aberta (a única recusou): ninguém pode aceitá-la, a casa chama de novo com outros termos.
select is(pg_temp.responder(18, pg_temp.chamada_de(pg_temp.casa(1), 18), 'recusar'), 'ok', 'C6 (montagem) 18 recusa a V4');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 23, '2026-11-20 18:00:05+00', '2026-11-20 23:00:07+00',
                         funcao => pg_temp.outra(), valor => 18000), 'ok',
  'C7 sem chamada aberta não há trabalho aberto: a chamada sem vaga_id cria vaga nova');
select isnt(pg_temp.vaga_de(pg_temp.casa(1), 23), (select id from vagas where nome = 'V4'), 'C8 em outra vaga');
-- C9. Duas vagas abertas do mesmo trabalho, de antes desta versão: vale a publicada primeiro.
select pg_temp.vaga_antiga('c8740000-0000-4000-8000-0000000003a1', pg_temp.casa(1), pg_temp.p(24), '2026-11-21 18:00+00', '2026-11-16 10:00+00');
select pg_temp.vaga_antiga('c8740000-0000-4000-8000-0000000003a2', pg_temp.casa(1), pg_temp.p(25), '2026-11-21 18:00+00', '2026-11-16 11:00+00');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 26, '2026-11-21 18:00:00+00', '2026-11-21 23:00:00+00'),
  '409 trabalho_ja_aberto c8740000-0000-4000-8000-0000000003a1',
  'C9 duplicatas antigas: sem vaga_id, a recusa aponta a publicada primeiro');
select is(pg_temp.chamar_vaga(pg_temp.u(1), pg_temp.casa(1), 26, 'c8740000-0000-4000-8000-0000000003a2'),
  '409 trabalho_ja_aberto c8740000-0000-4000-8000-0000000003a1',
  'C10 com o vaga_id da duplicata mais nova: também aponta a primeira');
select is(pg_temp.chamar_vaga(pg_temp.u(1), pg_temp.casa(1), 26, 'c8740000-0000-4000-8000-0000000003a1'), 'ok',
  'C11 com o vaga_id da primeira: a chamada entra');
-- As duplicatas já cumpriram o papel: libera a cota de 10 abertas da casa para a seção F.
update public.chamada set estado = 'cancelada', respondida_em = privado.agora()
 where vaga_id in ('c8740000-0000-4000-8000-0000000003a1', 'c8740000-0000-4000-8000-0000000003a2');

-- ══ D. A chave ════════════════════════════════════════════════════════════════
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 11, '2026-11-20 18:00:05+00', '2026-11-20 23:00:07+00',
                         chave => pg_temp.k(11)), 'ok',
  'D1 reenviar a chave da chamada que criou o trabalho: nunca trabalho_ja_aberto');
select is((pg_temp.como(pg_temp.u(1), format($a$ select public.chamar_profissional(chave => %L, profissional_id => %L,
             estabelecimento_id => %L, funcao_id => %L, inicio_em => '2026-11-20 18:00:05+00', fim_em => '2026-11-20 23:00:07+00',
             local => 'CLN 201', regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
             valor_centavos => 15000, inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false,
             responsavel_local => 'Maitre') $a$, pg_temp.k(11), pg_temp.p(11), pg_temp.casa(1), pg_temp.garcom())) ->> 'id')::uuid,
  pg_temp.chamada_de(pg_temp.casa(1), 11),
  'D2 e devolve a mesma chamada');

-- ══ E. A casa lê os termos do trabalho aberto pelas próprias chamadas ══════════
select is((select count(*)::int
             from jsonb_array_elements(pg_temp.como(pg_temp.u(1), $$ select public.minhas_chamadas(estado => 'aberta') $$) -> 'itens') e
            where (e->>'vaga_id')::uuid = (select id from vagas where nome = 'V1')
              and (e->'funcao'->>'id')::uuid = pg_temp.garcom()
              and (e->>'inicio_em')::timestamptz = '2026-11-20 18:00:05+00'
              and (e->>'fim_em')::timestamptz = '2026-11-20 23:00:07+00'
              and (e->>'valor_centavos')::int = 15000), 2,
  'E1 minhas_chamadas (aberta) traz, nos itens com o vaga_id da recusa, a função, o início, o fim e o valor');
select is((select jsonb_build_object('r', d->'inclui_refeicao', 't', d->'inclui_transporte', 'm', d->'exige_material_proprio',
                                     'regiao', d->'regiao_administrativa')
             from pg_temp.como(pg_temp.u(1), format('select public.detalhe_chamada(%L)', pg_temp.chamada_de(pg_temp.casa(1), 11))) d),
  '{"r": true, "t": false, "m": false, "regiao": "Plano Piloto"}'::jsonb,
  'E2 detalhe_chamada traz à casa os inclusos e a região');

-- ══ F. publicar_a_partir_da_chamada encerra as irmãs ═══════════════════════════
-- Trabalho T6 (22/11, 18:00 às 23:00): VC preenchida (27 aceitou), VA sem chamada aberta (28 recusou), VB com a
-- chamada aberta de 29. Mais uma vaga do mesmo horário na casa 2, que não é irmã.
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 27, '2026-11-22 18:00:00+00', '2026-11-22 23:00:00+00'), 'ok', 'F1 (montagem) VC');
insert into vagas values ('VC', pg_temp.vaga_de(pg_temp.casa(1), 27));
select is(pg_temp.responder(27, pg_temp.chamada_de(pg_temp.casa(1), 27), 'aceitar'), 'ok', 'F2 (montagem) 27 aceita a VC');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 28, '2026-11-22 18:00:10+00', '2026-11-22 23:00:10+00'), 'ok', 'F3 (montagem) VA');
insert into vagas values ('VA', pg_temp.vaga_de(pg_temp.casa(1), 28));
select is(pg_temp.responder(28, pg_temp.chamada_de(pg_temp.casa(1), 28), 'recusar'), 'ok', 'F4 (montagem) 28 recusa a VA');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 29, '2026-11-22 18:00:30+00', '2026-11-22 23:00:30+00'), 'ok', 'F5 (montagem) VB');
insert into vagas values ('VB', pg_temp.vaga_de(pg_temp.casa(1), 29));
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 30, '2026-11-22 18:00:00+00', '2026-11-22 23:00:00+00'), 'ok', 'F6 (montagem) a da casa 2');
select ok((pg_temp.como(pg_temp.u(1), format($a$ select public.publicar_a_partir_da_chamada(vaga_id => %L, chave => %L) $a$,
            (select id from vagas where nome = 'VA'), pg_temp.k(40))) ->> 'vaga_id') is not null,
  'F7 "Publicar para todos" na VA, a vaga sem chamada aberta, converte');
select is((select array_agg(g.estado::text order by v.nome) from vagas v join public.vaga g on g.id = v.id
            where v.nome in ('VA', 'VB', 'VC')),
  array['encerrada', 'encerrada', 'preenchida'],
  'F8 a VA e a irmã VB vão a encerrada; a VC, preenchida, não é tocada');
select is((select estado from public.chamada where id = pg_temp.chamada_de(pg_temp.casa(1), 29)), 'encerrada',
  'F9 a chamada aberta da irmã encerra');
select is((select count(*)::int from public.notificacao n
            where n.usuario_id = pg_temp.u(29) and n.tipo = 'chamada_encerrada'
              and n.referencia_id = pg_temp.chamada_de(pg_temp.casa(1), 29)
              and (n.payload->>'vaga_id')::uuid = (select id from vagas where nome = 'VB')), 1,
  'F10 com o mesmo aviso (chamada_encerrada), apontando a vaga dela');
select is((select p.estado::text from public.posicao p where p.vaga_id = (select id from vagas where nome = 'VC')), 'confirmada',
  'F11 o turno confirmado da VC continua');
select is((select array_agg(g.estado::text order by g.id) from public.vaga g
            where g.id in ((select id from vagas where nome = 'V1'), pg_temp.vaga_de(pg_temp.casa(2), 30))),
  array['publicada', 'publicada'],
  'F12 a vaga direta de outro horário e a de outra casa ficam publicadas');

-- ══ G. Depois da trava da casa ═════════════════════════════════════════════════
select ok(l > 0
          and strpos(substr(d, l), 'c.chave = chamar_profissional.chave') > 0
          and strpos(substr(d, l), '''trabalho_ja_aberto''') > 0
          and strpos(substr(d, 1, l), '''trabalho_ja_aberto''') = 0,
  'G1 chamar_profissional relê a chave e confere o trabalho só depois da trava da casa')
  from (select d, strpos(d, 'from public.estabelecimento e where e.id = v_estab for update') l
          from (select pg_get_functiondef('public.chamar_profissional(uuid, uuid, uuid, uuid, uuid, timestamptz, timestamptz, text, text, jsonb, bigint, boolean, boolean, boolean, text, text, boolean, int)'::regprocedure) d) x) f;
select ok(strpos(d, 'from public.estabelecimento e where e.id = v_estab for update') > 0
          and strpos(d, 'from public.estabelecimento e where e.id = v_estab for update')
              < strpos(d, 'from public.vaga where id = publicar_a_partir_da_chamada.vaga_id for update'),
  'G2 publicar_a_partir_da_chamada toma a trava da casa antes da trava da vaga')
  from (select pg_get_functiondef('public.publicar_a_partir_da_chamada(uuid, uuid, text)'::regprocedure) d) f;

select * from finish();
rollback;
