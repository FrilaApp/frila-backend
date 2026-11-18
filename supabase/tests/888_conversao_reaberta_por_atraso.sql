-- 888_conversao_reaberta_por_atraso.sql
--
-- publicar_a_partir_da_chamada converte a vaga direta que reabrir_por_atraso reabriu (migração
-- 20261117180000, contrato 0.2.95, frila-backend#564): o contrato promete a conversão "até fim_em - 1 h"
-- para a posição reaberta por atraso, mas a condição pós-início do corpo pedia posição aberta com
-- `falta`, e falta_so_em_cancelada (20260922150400) proíbe isso: a conversão nunca passava.
--   A  vaga direta preenchida, reaberta por atraso depois do início e antes de fim_em - 1 h: converte
--      (vaga nova pública, uma posição aberta, a direta encerrada); reenviar a mesma chave devolve a mesma
--   B  a janela fecha em fim_em - 1 h: reaberta e relógio depois disso: 409 vaga_encerrada, sem vaga nova
--   C  sem reabertura, depois do início: 409 vaga_encerrada (direta publicada sem posição aberta)
--   D  antes do início, segue convertendo
--   E  quem não é da casa recebe 403 antes de qualquer outra coisa
-- Só dados sintéticos.
begin;
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
-- 16/11/2026, 12:00 em Brasília (fora do silêncio das chamadas).
select set_config('frila.agora', '2026-11-16 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-888';
select plan(24);

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
  select ('c8880000-0000-4000-8000-0000000000' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.p(n int) returns uuid language sql immutable as $$
  select ('c8880000-0000-4000-8000-0000000001' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.casa(n int) returns uuid language sql immutable as $$
  select ('c8880000-0000-4000-8000-00000000e0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.k(n int) returns uuid language sql immutable as $$
  select ('c8880000-0000-4000-8000-00000000c0' || lpad(n::text, 2, '0'))::uuid $$;
create function pg_temp.garcom() returns uuid language sql stable as $$ select id from public.funcao where nome = 'garçom' $$;
create function pg_temp.relogio(t text) returns void language sql as $$
  select set_config('frila.agora', t::timestamptz::text, true) $$;

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
-- A posição confirmada da vaga (o turno de quem aceitou a chamada).
create function pg_temp.pos_de(vaga uuid) returns uuid language sql stable as $$
  select p.id from public.posicao p where p.vaga_id = vaga and p.estado = 'confirmada' $$;
create function pg_temp.reabrir(vaga uuid) returns text language sql as $$
  select pg_temp.tenta(pg_temp.u(1), format($a$ select public.reabrir_por_atraso(%L) $a$, pg_temp.pos_de(vaga))) $$;

-- ── Massa ─────────────────────────────────────────────────────────────────────
-- Contratantes 1 (casa 1) e 2 (casa 2); profissionais 11 a 15, na equipe de confiança da casa 1.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at, is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', pg_temp.u(n), 'authenticated', 'authenticated',
       'p' || n || '@t888.test', privado.agora(), privado.agora(), false, false
  from (select generate_series(1, 2) union all select generate_series(11, 15)) s(n);
select pg_temp.como(pg_temp.u(n), format(
  $$ select public.criar_conta(%L, %L, %L, '1990-01-01', '2026-11-13') $$,
  case when n <= 2 then 'contratante' else 'profissional' end, 'Pessoa ' || n || ' Sintética',
  '+55619555888' || lpad(n::text, 2, '0')))
  from (select generate_series(1, 2) union all select generate_series(11, 15)) s(n);
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  (pg_temp.casa(1), 'Casa 888 Um',   '88812345000169', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  (pg_temp.casa(2), 'Casa 888 Dois', '88812345000270', 'food_service', 'CLN 202', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  (pg_temp.u(1), pg_temp.casa(1), 'administrador'), (pg_temp.u(2), pg_temp.casa(2), 'administrador');
insert into public.profissional (id, usuario_id, ponto_base)
select pg_temp.p(n), pg_temp.u(n), 'POINT(-47.8822 -15.7852)'::extensions.geography from generate_series(11, 15) n;
insert into public.profissional_funcao (profissional_id, funcao_id)
select pg_temp.p(n), pg_temp.garcom() from generate_series(11, 15) n;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select pg_temp.u(n), 'tok-888-' || n || '-000000000000000000', 'ios', '1.2.0' from generate_series(11, 15) n;
insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select pg_temp.casa(1), pg_temp.p(n) from generate_series(11, 15) n;
update privado.recurso set ligado = true where chave = 'chamada_direta';
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

create temp table vagas (nome text primary key, id uuid);

-- Quatro trabalhos, cada um num dia (um não conta como "trabalho aberto" do outro): VR (reaberta e converte),
-- VT (reaberta e a janela fecha), VS (sem reabertura), VA (antes do início).
-- VR e VT são aceitas pela pessoa (preenchidas) no dia 16; VS e VA ficam com a chamada aberta.
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 11, '2026-11-20 18:00:00+00', '2026-11-20 23:00:00+00'), 'ok',
  '(montagem) VR: a casa chama o 11');
insert into vagas values ('VR', pg_temp.vaga_de(pg_temp.casa(1), 11));
select is(pg_temp.tenta(pg_temp.u(11), format($a$ select public.responder_chamada(%L, 'aceitar') $a$, pg_temp.chamada_de(pg_temp.casa(1), 11))), 'ok',
  '(montagem) o 11 aceita: a VR fica preenchida');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 12, '2026-11-21 18:00:00+00', '2026-11-21 23:00:00+00'), 'ok',
  '(montagem) VT: a casa chama o 12');
insert into vagas values ('VT', pg_temp.vaga_de(pg_temp.casa(1), 12));
select is(pg_temp.tenta(pg_temp.u(12), format($a$ select public.responder_chamada(%L, 'aceitar') $a$, pg_temp.chamada_de(pg_temp.casa(1), 12))), 'ok',
  '(montagem) o 12 aceita: a VT fica preenchida');
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 13, '2026-11-22 18:00:00+00', '2026-11-22 23:00:00+00'), 'ok',
  '(montagem) VS: a casa chama o 13, que não responde');
insert into vagas values ('VS', pg_temp.vaga_de(pg_temp.casa(1), 13));
select is(pg_temp.chamar(pg_temp.u(1), pg_temp.casa(1), 14, '2026-11-23 18:00:00+00', '2026-11-23 23:00:00+00'), 'ok',
  '(montagem) VA: a casa chama o 14, que não responde');
insert into vagas values ('VA', pg_temp.vaga_de(pg_temp.casa(1), 14));

-- ══ A. Reaberta por atraso, dentro da janela ══════════════════════════════════
-- 20/11, 15:20 em Brasília (18:20 UTC): a VR e a VT começaram há 20 min, o turno não fez check-in.
select pg_temp.relogio('2026-11-20 18:20:00+00');
select is(pg_temp.reabrir(pg_temp.vaga_de(pg_temp.casa(1), 11)), 'ok',
  'A0 (montagem) a casa reabre por atraso a posição da VR: ok');
select is((select g.estado::text from public.vaga g where g.id = (select id from vagas where nome = 'VR')), 'publicada',
  'A1 (montagem) a VR volta a publicada');
select is((select count(*)::int from public.posicao p
            where p.vaga_id = (select id from vagas where nome = 'VR') and p.estado = 'aberta'
              and p.reaberta_por_atraso_de is not null), 1,
  'A2 (montagem) a VR tem uma posição aberta marcada reaberta_por_atraso_de');
select pg_temp.relogio('2026-11-20 18:30:00+00');
select is(pg_temp.publicar(pg_temp.u(1), (select id from vagas where nome = 'VR'), pg_temp.k(1)), 'ok',
  'A3 converter a VR reaberta por atraso, antes de fim_em - 1 h: ok');
select is((select count(*)::int from public.vaga where vaga_origem_id = (select id from vagas where nome = 'VR')), 1,
  'A4 uma vaga nova pública para a VR');
select is((select g.estado::text from public.vaga g where g.id = (select id from vagas where nome = 'VR')), 'encerrada',
  'A5 a direta VR vai a encerrada');
select is((select count(*)::int from public.posicao p join public.vaga g on g.id = p.vaga_id
            where g.vaga_origem_id = (select id from vagas where nome = 'VR') and p.estado = 'aberta'), 1,
  'A6 a vaga nova tem uma posição aberta');
select is(pg_temp.publicar(pg_temp.u(1), (select id from vagas where nome = 'VR'), pg_temp.k(1)), 'ok',
  'A7 reenviar a mesma chave devolve a mesma conversão');
select is((select count(*)::int from public.vaga where vaga_origem_id = (select id from vagas where nome = 'VR')), 1,
  'A8 o reenvio não cria outra vaga');

-- ══ B. A janela fecha em fim_em - 1 h ═════════════════════════════════════════
-- 21/11, 15:20 em Brasília (18:20 UTC): a VT começou há 20 min e a casa a reabre; fim_em - 1 h = 22:00 UTC.
select pg_temp.relogio('2026-11-21 18:20:00+00');
select is(pg_temp.reabrir(pg_temp.vaga_de(pg_temp.casa(1), 12)), 'ok',
  'B0 (montagem) a casa reabre por atraso a posição da VT: ok');
select pg_temp.relogio('2026-11-21 22:00:00+00');
select is(pg_temp.publicar(pg_temp.u(1), (select id from vagas where nome = 'VT'), pg_temp.k(2)), '409 vaga_encerrada',
  'B1 em fim_em - 1 h a conversão fecha: 409 vaga_encerrada');
select is((select count(*)::int from public.vaga where vaga_origem_id = (select id from vagas where nome = 'VT')), 0,
  'B2 a recusa não cria vaga nova');
select is((select g.estado::text from public.vaga g where g.id = (select id from vagas where nome = 'VT')), 'publicada',
  'B3 a VT continua publicada, como a reabertura a deixou');

-- ══ C. Depois do início, sem reabertura ═══════════════════════════════════════
-- 22/11, 16:00 em Brasília (19:00 UTC): a VS começou há 1 h; a chamada ficou sem resposta, não há posição.
select pg_temp.relogio('2026-11-22 19:00:00+00');
select is(pg_temp.publicar(pg_temp.u(1), (select id from vagas where nome = 'VS'), pg_temp.k(3)), '409 vaga_encerrada',
  'C1 direta que já começou, sem reabertura por atraso: 409 vaga_encerrada');
select is((select count(*)::int from public.vaga where vaga_origem_id = (select id from vagas where nome = 'VS')), 0,
  'C2 a recusa não cria vaga nova');

-- ══ D. Antes do início segue convertendo ══════════════════════════════════════
-- Ainda 22/11 19:00 UTC: a VA começa em 23/11.
select is(pg_temp.publicar(pg_temp.u(1), (select id from vagas where nome = 'VA'), pg_temp.k(4)), 'ok',
  'D1 direta com chamada aberta, antes do início: ok');
select is((select count(*)::int from public.vaga where vaga_origem_id = (select id from vagas where nome = 'VA')), 1,
  'D2 uma vaga nova pública para a VA');

-- ══ E. A ordem ════════════════════════════════════════════════════════════════
select is(pg_temp.publicar(pg_temp.u(2), (select id from vagas where nome = 'VT'), pg_temp.k(5)), '403 sem_permissao',
  'E1 quem não é da casa recebe 403 sem_permissao');

select * from finish();
rollback;
