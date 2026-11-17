-- 885_publicar_vaga_direta_preenchida.sql
--
-- publicar_a_partir_da_chamada recusa a vaga direta já preenchida (migração 20261117150000,
-- contrato 0.2.95, frila-backend#523): 409 vaga_encerrada, sem criar vaga nova.
--   A  a direta preenchida (a pessoa aceitou), antes do início: 409 vaga_encerrada; nada criado; a vaga e o
--      turno confirmado ficam como estavam; reenviar com outra chave recusa igual
--   B  o que já passava continua: direta com chamada aberta converte; reenviar a mesma chave devolve a mesma
--      vaga; direta cancelada segue 409 vaga_encerrada
--   C  a ordem: quem não é da casa recebe 403 antes de saber que a vaga está preenchida; vaga que não existe
--      segue 404
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
-- 16/11/2026, 12:00 em Brasília (fora do silêncio das chamadas).
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-885';
select plan(16);

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
  select ('c8850000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.p(n int) returns uuid language sql immutable as $$
  select ('c8850000-0000-4000-8000-0000000001' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.casa(n int) returns uuid language sql immutable as $$
  select ('c8850000-0000-4000-8000-00000000e0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.k(n int) returns uuid language sql immutable as $$
  select ('c8850000-0000-4000-8000-00000000c0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.garcom() returns uuid language sql stable as $$ select id from public.funcao where nome = 'garçom' $$;

-- chamar_profissional sem vaga_id, com o corpo inteiro: cria a vaga direta e a chamada.
create function pg_temp.chamar(conta uuid, casa uuid, prof int, inicio text, fim text) returns text
language sql as $$
  select pg_temp.tenta(conta, format($a$ select public.chamar_profissional(chave => %L,
    profissional_id => %L, estabelecimento_id => %L, funcao_id => %L, inicio_em => %L, fim_em => %L,
    local => 'CLN 201', regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}',
    valor_centavos => 15000, inclui_refeicao => true, inclui_transporte => false,
    exige_material_proprio => false, responsavel_local => 'Maitre') $a$,
    gen_random_uuid(), pg_temp.p(prof), casa, pg_temp.garcom(), inicio::timestamptz, fim::timestamptz)) $$;
create function pg_temp.vaga_de(casa uuid, prof int) returns uuid language sql stable as $$
  select c.vaga_id from public.chamada c where c.estabelecimento_id = casa and c.profissional_id = pg_temp.p(prof)
   order by c.criada_em desc limit 1 $$;
create function pg_temp.chamada_de(casa uuid, prof int) returns uuid language sql stable as $$
  select c.id from public.chamada c where c.estabelecimento_id = casa and c.profissional_id = pg_temp.p(prof)
   order by c.criada_em desc limit 1 $$;
create function pg_temp.publicar(conta uuid, vaga uuid, chave uuid) returns text language sql as $$
  select pg_temp.tenta(conta, format($a$ select public.publicar_a_partir_da_chamada(vaga_id => %L, chave => %L) $a$, vaga, chave)) $$;

-- ── Massa ─────────────────────────────────────────────────────────────────────
-- Contratantes 1 (casa 1) e 2 (casa 2); profissionais 11 a 13, na equipe de confiança da casa 1.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.u(n), 'authenticated', 'authenticated',
       'p' || n || '@t885.test', privado.agora(), privado.agora(), false, false
  from (select generate_series(1, 2) union all select generate_series(11, 13)) s(n);
select pg_temp.como(pg_temp.u(n), format(
  $$ select public.criar_conta(%L, %L, %L, '1990-01-01', '2026-11-13') $$,
  case when n <= 2 then 'contratante' else 'profissional' end, 'Pessoa ' || n || ' Sintética',
  '+55619555885' || lpad(n::text, 2, '0')))
  from (select generate_series(1, 2) union all select generate_series(11, 13)) s(n);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  (pg_temp.casa(1), 'Casa 885 Um',   '88512345000169', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  (pg_temp.casa(2), 'Casa 885 Dois', '88512345000270', 'food_service', 'CLN 202', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  (pg_temp.u(1), pg_temp.casa(1), 'administrador'), (pg_temp.u(2), pg_temp.casa(2), 'administrador');
insert into public.profissional (id, usuario_id, ponto_base)
select pg_temp.p(n), pg_temp.u(n), 'POINT(-47.8822 -15.7852)'::extensions.geography from generate_series(11, 13) n;
insert into public.profissional_funcao (profissional_id, funcao_id)
select pg_temp.p(n), pg_temp.garcom() from generate_series(11, 13) n;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select pg_temp.u(n), 'tok-885-' || n || '-000000000000000000', 'ios', '1.2.0' from generate_series(11, 13) n;
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select pg_temp.casa(1), pg_temp.p(n) from generate_series(11, 13) n;
update privado.recurso set ligado = true where chave = 'chamada_direta';
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

create temp table vagas (nome text primary key, id uuid);

-- Três trabalhos em dias diferentes, para que um não conte como "trabalho aberto" do outro.
-- VP: 20/11, a pessoa aceitou (preenchida). VA: 21/11, chamada aberta. VC: 22/11, a casa cancela.
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 11, '2026-11-20 18:00:00+00', '2026-11-20 23:00:00+00'), 'ok',
  '(montagem) VP: a casa chama o 11');
insert into vagas values ('VP', pg_temp.vaga_de(pg_temp.casa(1), 11));
select is(pg_temp.tenta(pg_temp.u(11), format($a$ select public.responder_chamada(%L, 'aceitar') $a$, pg_temp.chamada_de(pg_temp.casa(1), 11))), 'ok',
  '(montagem) o 11 aceita: a VP fica preenchida');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 12, '2026-11-21 18:00:00+00', '2026-11-21 23:00:00+00'), 'ok',
  '(montagem) VA: a casa chama o 12, que não responde');
insert into vagas values ('VA', pg_temp.vaga_de(pg_temp.casa(1), 12));
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 13, '2026-11-22 18:00:00+00', '2026-11-22 23:00:00+00'), 'ok',
  '(montagem) VC: a casa chama o 13');
insert into vagas values ('VC', pg_temp.vaga_de(pg_temp.casa(1), 13));

-- ══ A. Direta preenchida ══════════════════════════════════════════════════════
select is((select estado::text from public.vaga where id = (select id from vagas where nome = 'VP')), 'preenchida',
  'A0 (montagem) a VP está preenchida e começa em 20/11, depois do relógio de 16/11');
select is(pg_temp.publicar(pg_temp.u(1), (select id from vagas where nome = 'VP'), pg_temp.k(1)), '409 vaga_encerrada',
  'A1 publicar a direta já preenchida: 409 vaga_encerrada');
select is((select count(*)::int from public.vaga where vaga_origem_id = (select id from vagas where nome = 'VP')
                                                     or chave_cliente = pg_temp.k(1)), 0,
  'A2 a recusa não cria vaga nova');
select is((select estado::text from public.vaga where id = (select id from vagas where nome = 'VP')), 'preenchida',
  'A3 a vaga continua preenchida (não vai a encerrada)');
select is((select p.estado::text from public.posicao p where p.vaga_id = (select id from vagas where nome = 'VP')), 'confirmada',
  'A4 o turno confirmado continua');
select is(pg_temp.publicar(pg_temp.u(1), (select id from vagas where nome = 'VP'), pg_temp.k(2)), '409 vaga_encerrada',
  'A5 reenviar com outra chave recusa igual');

-- ══ B. O que já passava ═══════════════════════════════════════════════════════
select is(pg_temp.publicar(pg_temp.u(1), (select id from vagas where nome = 'VA'), pg_temp.k(3)), 'ok',
  'B1 direta com chamada aberta converte');
select is(pg_temp.publicar(pg_temp.u(1), (select id from vagas where nome = 'VA'), pg_temp.k(3)), 'ok',
  'B2 reenviar a mesma chave devolve a mesma conversão');
select is((select count(*)::int from public.vaga where vaga_origem_id = (select id from vagas where nome = 'VA')), 1,
  'B3 uma só vaga nova para a VA');
update public.vaga set estado = 'cancelada' where id = (select id from vagas where nome = 'VC');
select is(pg_temp.publicar(pg_temp.u(1), (select id from vagas where nome = 'VC'), pg_temp.k(4)), '409 vaga_encerrada',
  'B4 direta cancelada segue 409 vaga_encerrada');

-- ══ C. A ordem ════════════════════════════════════════════════════════════════
select is(pg_temp.publicar(pg_temp.u(2), (select id from vagas where nome = 'VP'), pg_temp.k(5)), '403 sem_permissao',
  'C1 quem não é da casa recebe 403 sem_permissao, antes de saber que a vaga está preenchida');
select is(pg_temp.publicar(pg_temp.u(1), gen_random_uuid(), pg_temp.k(6)), '404 nao_encontrado',
  'C2 vaga que não existe segue 404');

select * from finish();
rollback;
