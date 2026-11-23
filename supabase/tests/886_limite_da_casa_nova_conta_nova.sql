-- 886_limite_da_casa_nova_conta_nova.sql
--
-- O limite da casa sem turno cumprido (5 chamadas em 7 dias) responde `422 limite_de_chamadas` com
-- `details = conta_nova`, como o contrato (openapi.yaml:91), e não `por_semana` (migração 20261117160000,
-- frila-backend#524).
--   A  a casa sem turno cumprido: as 5 primeiras chamadas (todas respondidas, nenhuma aberta) entram; a 6ª
--      recebe 422 limite_de_chamadas conta_nova, sem criar vaga nem chamada
--   B  a outra recusa da casa nova segue com o próprio details: 3 abertas, a 4ª recusa com `abertas`
--   C  com um turno cumprido e verificado a casa deixa de ser nova: a mesma chamada entra
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
-- 16/11/2026, 12:00 em Brasília (fora do silêncio das chamadas).
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-886';
select plan(12);

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
  select ('c8860000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.p(n int) returns uuid language sql immutable as $$
  select ('c8860000-0000-4000-8000-0000000001' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.casa(n int) returns uuid language sql immutable as $$
  select ('c8860000-0000-4000-8000-00000000e0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.garcom() returns uuid language sql stable as $$ select id from public.funcao where nome = 'garçom' $$;

-- chamar_profissional sem vaga_id, com o corpo inteiro: o trabalho do dia d (18:00 às 23:00 UTC).
create function pg_temp.chamar(conta uuid, casa uuid, prof int, dia int) returns text
language sql as $$
  select pg_temp.tenta(conta, format($a$ select public.chamar_profissional(chave => %L,
    profissional_id => %L, estabelecimento_id => %L, funcao_id => %L, inicio_em => %L, fim_em => %L,
    local => 'CLN 201', regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
    valor_centavos => 15000, inclui_refeicao => true, inclui_transporte => false,
    exige_material_proprio => false, responsavel_local => 'Maitre') $a$,
    gen_random_uuid(), pg_temp.p(prof), casa, pg_temp.garcom(),
    ('2026-11-' || lpad(dia::text, 2, '0') || ' 18:00:00+00')::timestamptz,
    ('2026-11-' || lpad(dia::text, 2, '0') || ' 23:00:00+00')::timestamptz)) $$;
create function pg_temp.chamar_vaga(conta uuid, casa uuid, prof int, vaga uuid) returns text language sql as $$
  select pg_temp.tenta(conta, format($a$ select public.chamar_profissional(chave => %L,
    profissional_id => %L, estabelecimento_id => %L, vaga_id => %L) $a$, gen_random_uuid(), pg_temp.p(prof), casa, vaga)) $$;
create function pg_temp.vaga_de(casa uuid, prof int) returns uuid language sql stable as $$
  select c.vaga_id from public.chamada c where c.estabelecimento_id = casa and c.profissional_id = pg_temp.p(prof)
   order by c.criada_em desc limit 1 $$;
create function pg_temp.recusar(prof int, casa uuid) returns text language sql as $$
  select pg_temp.tenta(pg_temp.u(prof), format($a$ select public.responder_chamada(%L, 'recusar', 'agenda') $a$,
    (select c.id from public.chamada c where c.estabelecimento_id = casa and c.profissional_id = pg_temp.p(prof)
      order by c.criada_em desc limit 1))) $$;
-- Um turno cumprido e verificado da casa (tira a casa do limite de casa nova).
create function pg_temp.turno(p_estab uuid, p_prof uuid, p_inicio timestamptz) returns void language plpgsql as $$
declare v_vaga uuid := gen_random_uuid(); v_pos uuid := gen_random_uuid();
begin
  insert into public.vaga (id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto, valor_centavos,
                           posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo,
                           chave_cliente, publicado_em, estado)
  values (v_vaga, p_estab, pg_temp.garcom(), (select usuario_id from public.membro_estabelecimento where estabelecimento_id = p_estab limit 1),
          p_inicio, p_inicio + interval '6 hours', 'Local 886', 'POINT(-47.88 -15.78)'::extensions.geography, 15000, 1,
          true, false, false, 'Responsável 886', 'urgencia', gen_random_uuid(), p_inicio - interval '2 days', 'encerrada');
  insert into public.posicao (id, vaga_id, profissional_id, estado, confirmado_em, falta, inicio_em, fim_em)
  values (v_pos, v_vaga, p_prof, 'cumprida', p_inicio - interval '1 day', false, p_inicio, p_inicio + interval '6 hours');
  insert into public.turno (id, posicao_id, checkin_em, checkout_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
  values (gen_random_uuid(), v_pos, p_inicio, p_inicio + interval '6 hours', 'geolocalizado', 50, 'verificado', 15000);
end $$;

-- ── Massa ─────────────────────────────────────────────────────────────────────
-- Contratantes 1 (casa 1) e 2 (casa 2); profissionais 11 a 20, na equipe de confiança das duas casas.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.u(n), 'authenticated', 'authenticated',
       'p' || n || '@t886.test', privado.agora(), privado.agora(), false, false
  from (select generate_series(1, 2) union all select generate_series(11, 20)) s(n);
select pg_temp.como(pg_temp.u(n), format(
  $$ select public.criar_conta(%L, %L, %L, '1990-01-01', '2026-11-13') $$,
  case when n <= 2 then 'contratante' else 'profissional' end, 'Pessoa ' || n || ' Sintética',
  '+55619555886' || lpad(n::text, 2, '0')))
  from (select generate_series(1, 2) union all select generate_series(11, 20)) s(n);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  (pg_temp.casa(1), 'Casa 886 Um',   '88612345000169', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  (pg_temp.casa(2), 'Casa 886 Dois', '88612345000270', 'food_service', 'CLN 202', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  (pg_temp.u(1), pg_temp.casa(1), 'administrador'), (pg_temp.u(2), pg_temp.casa(2), 'administrador');
insert into public.profissional (id, usuario_id, ponto_base)
select pg_temp.p(n), pg_temp.u(n), 'POINT(-47.8822 -15.7852)'::extensions.geography from generate_series(11, 20) n;
insert into public.profissional_funcao (profissional_id, funcao_id)
select pg_temp.p(n), pg_temp.garcom() from generate_series(11, 20) n;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select pg_temp.u(n), 'tok-886-' || n || '-000000000000000000', 'ios', '1.2.0' from generate_series(11, 20) n;
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select c, pg_temp.p(n) from generate_series(11, 20) n, unnest(array[pg_temp.casa(1), pg_temp.casa(2)]) c;
update privado.recurso set ligado = true where chave = 'chamada_direta';
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

-- ══ A. O limite de 5 em 7 dias da casa sem turno cumprido ═════════════════════
-- Cinco trabalhos em dias diferentes (20 a 24/11), cada um chamado e recusado: nenhuma chamada fica aberta,
-- então só o limite da semana pode recusar a 6ª.
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 11 + d - 20, d), 'ok', 'A' || (d - 19) || ' a ' || (d - 19) || 'ª chamada da casa nova entra')
  from generate_series(20, 21) d;
select is(pg_temp.recusar(11, pg_temp.casa(1)) || pg_temp.recusar(12, pg_temp.casa(1)), 'okok', 'A3 (montagem) as duas primeiras são recusadas');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 13, 22) || pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 14, 23)
          || pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 15, 24), 'okokok', 'A4 a 3ª, a 4ª e a 5ª entram (nunca 3 abertas ao mesmo tempo depois das recusas)');
select is(pg_temp.recusar(13, pg_temp.casa(1)) || pg_temp.recusar(14, pg_temp.casa(1)) || pg_temp.recusar(15, pg_temp.casa(1)), 'okokok',
  'A5 (montagem) as outras três são recusadas: nenhuma chamada aberta');
select is((select count(*)::int from public.chamada c where c.estabelecimento_id = pg_temp.casa(1) and c.estado = 'aberta'), 0,
  'A6 nenhuma chamada aberta: o limite de abertas não pode ser o que recusa');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 16, 25), '422 limite_de_chamadas conta_nova',
  'A7 a 6ª chamada em 7 dias, casa sem turno cumprido: 422 limite_de_chamadas, details conta_nova');
select is((select count(*)::int from public.chamada c where c.estabelecimento_id = pg_temp.casa(1)), 5,
  'A8 a recusa não cria chamada');

-- ══ B. As outras recusas seguem com o próprio details ═════════════════════════
-- Casa 2, sem turno: 3 abertas e a 4ª recusa por abertas (esse limite vem antes do da semana).
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 11, 20) || pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 12, 21)
          || pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 13, 22), 'okokok', 'B1 (montagem) três chamadas abertas na casa 2');
select is(pg_temp.chamar(pg_temp.u(2), pg_temp.casa(2), 14, 23), '422 limite_de_chamadas abertas',
  'B2 a 4ª chamada aberta da casa sem turno: details abertas, como antes');

-- ══ C. A casa com turno cumprido e verificado deixa de ser nova ═══════════════
select pg_temp.turno(pg_temp.casa(1), pg_temp.p(20), '2026-11-01 10:00-03');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 16, 25), 'ok',
  'C1 a mesma chamada que recusava (6ª em 7 dias) entra depois do primeiro turno verificado');
select is((select count(*)::int from public.chamada c where c.estabelecimento_id = pg_temp.casa(1) and c.estado = 'aberta'), 1,
  'C2 a chamada ficou aberta');

select * from finish();
rollback;
