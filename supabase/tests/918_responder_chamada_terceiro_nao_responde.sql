-- 918_responder_chamada_terceiro_nao_responde.sql
--
-- Cee75aIn: `public.responder_chamada` só aceita a resposta do profissional CHAMADO. Um terceiro (outro profissional, com a mesma função e na
-- mesma equipe) que conhece o `chamada_id` recebe 404 `nao_encontrado`, como se a chamada não existisse, e nada muda: a chamada segue `aberta`, a
-- posição segue `aberta`, nenhum turno nasce e o profissional chamado ainda pode responder. O único 404 coberto antes era o do bloqueio (808).
--   A  o terceiro aceita → 404; o terceiro recusa → 404
--   B  o 404 é o mesmo de uma chamada que não existe (não vaza que a chamada existe)
--   C  nada muda no banco (chamada, posição, turno, vaga) e o chamado ainda aceita depois
-- Ids próprios (`c9180000`). Só dados sintéticos. Fixtures de usuário e casa copiados do 808.

begin;
update privado.recurso set ligado = false where chave in ('chamada_direta', 'perfil_rico');
update privado.configuracao_app set foto_de_perfil = false;
delete from privado.recurso_versao_minima where recurso in ('foto_de_perfil', 'chamada_direta', 'perfil_rico');

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-07 15:00:00+00', true);
set local frila.agendador_secret = 'segredo-de-teste-918';

select plan(18);

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
select '00000000-0000-0000-0000-000000000000', ('c9180000-0000-4000-8000-00000000000' || n)::uuid,
       'authenticated', 'authenticated', 'u' || n || '@t918.test', privado.agora(), privado.agora(), false, false
  from generate_series(1, 6) n;

select pg_temp.como(('c9180000-0000-4000-8000-00000000000' || n)::uuid, format(
  $$ select public.criar_conta(%L, 'Pessoa %s', '+556195555918%s', '1990-01-01', '2026-09-22') $$,
  case when n in (1, 2, 6) then 'contratante' else 'profissional' end, n, n)) from generate_series(1, 6) n;

-- Estabelecimento 1 (Casa 1 - CNPJ)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c9180000-0000-4000-8000-0000000000e1', 'Restaurante 918', '91812345000101', 'food_service', 'CLN 201',
        'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c9180000-0000-4000-8000-000000000001', 'c9180000-0000-4000-8000-0000000000e1', 'administrador');

-- Estabelecimento 2 (Casa 2 - CNPJ)
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('c9180000-0000-4000-8000-0000000000e2', 'Bar 918', '91812345000102', 'food_service', 'CLN 202',
        'POINT(-47.8825 -15.7945)'::extensions.geography, 'Plano Piloto');
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c9180000-0000-4000-8000-000000000006', 'c9180000-0000-4000-8000-0000000000e2', 'administrador');

-- Profissionais
insert into public.profissional (usuario_id, ponto_base)
select ('c9180000-0000-4000-8000-00000000000' || n)::uuid, 'POINT(-47.8822 -15.7800)'::extensions.geography
  from generate_series(3, 5) n;

create temp table prof_ids as select
  (select id from public.profissional where usuario_id = 'c9180000-0000-4000-8000-000000000003') as a,
  (select id from public.profissional where usuario_id = 'c9180000-0000-4000-8000-000000000004') as b,
  (select id from public.profissional where usuario_id = 'c9180000-0000-4000-8000-000000000005') as c;

insert into public.profissional_funcao select p, (select id from public.funcao where nome = 'garçom')
  from prof_ids, unnest(array[a, b, c]) p;

insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c9180000-0000-4000-8000-0000000000e1', p from prof_ids, unnest(array[a, b, c]) p;

insert into public.equipe_confianca (estabelecimento_id, profissional_id)
select 'c9180000-0000-4000-8000-0000000000e2', p from prof_ids, unnest(array[a, b, c]) p;

-- Histórico prévio de turno cumprido e verificado para Casa 1 (CD-C14 / B5d)
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, traje, estado, modo, publicado_em, chave_cliente, publicado_por)
values ('c9180000-0000-4000-8000-000000000010', 'c9180000-0000-4000-8000-0000000000e1', (select id from public.funcao where nome = 'garçom'),
        '2026-10-01 18:00+00', '2026-10-01 23:00+00', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 15000, 1, true, false, false, 'Carlos', 'social', 'encerrada', 'urgencia', '2026-09-30 10:00+00', gen_random_uuid(), 'c9180000-0000-4000-8000-000000000001');

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values ('c9180000-0000-4000-8000-000000000020', 'c9180000-0000-4000-8000-000000000010', 'cumprida', (select a from prof_ids), '2026-10-01 17:00+00', '2026-10-01 18:00+00', '2026-10-01 23:00+00');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkout_em, verificacao, valor_acordado_centavos)
values ('c9180000-0000-4000-8000-000000000030', 'c9180000-0000-4000-8000-000000000020', '2026-10-01 18:00+00', 'geolocalizado', 50, '2026-10-01 23:00+00', 'verificado', 15000);

-- Liga o interruptor para os demais testes
update privado.recurso set ligado = true where chave = 'chamada_direta';
-- 0.2.66 (20261108160000): só se chama quem tem aparelho na versão mínima de chamada_direta.
-- Este arquivo mede a chamada com o portão satisfeito; o portão em si é o 830.
insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima) values ('chamada_direta', 'ios', '1.2.0')
on conflict (recurso, plataforma) do nothing;
insert into public.dispositivo (usuario_id, token_fcm, plataforma, versao_app)
select p.usuario_id, 'tok-teste-' || p.usuario_id, 'ios', '1.2.0'
  from public.profissional p where p.usuario_id::text like 'c9180000-%'
on conflict (token_fcm) do nothing;


-- Uma chamada aberta da Casa 1 para o profissional A. B e C são terceiros: da mesma equipe e da mesma função, mas não foram chamados.
create temp table vaga1 as select pg_temp.como('c9180000-0000-4000-8000-000000000001', format(
  $$ select public.chamar_profissional(chave => gen_random_uuid(), profissional_id => %L,
     estabelecimento_id => 'c9180000-0000-4000-8000-0000000000e1', funcao_id => (select id from public.funcao where nome = 'garçom'),
     inicio_em => '2026-11-08 18:00+00', fim_em => '2026-11-08 23:00+00', local => 'CLN 201 Bloco A',
     regiao_administrativa => 'Plano Piloto', ponto => '{"latitude":-15.7942,"longitude":-47.8822}', valor_centavos => 16000,
     inclui_refeicao => true, inclui_transporte => false, exige_material_proprio => false, responsavel_local => 'Gerente Carlos',
     recado => 'Chegar 10 min antes') $$, (select a from prof_ids))) as j;

create temp table ch as select (j->>'id')::uuid as chamada, (j->>'vaga_id')::uuid as vaga from vaga1;
select is((select estado::text from public.chamada where id = (select chamada from ch)), 'aberta', '0 a chamada para o profissional A nasce aberta');
select is((select profissional_id from public.chamada where id = (select chamada from ch)), (select a from prof_ids), '0b e é do profissional A');

create temp table antes as select
  (select estado::text from public.chamada where id = (select chamada from ch)) as chamada_estado,
  (select respondida_em from public.chamada where id = (select chamada from ch)) as respondida_em,
  (select count(*)::int from public.turno t join public.posicao p on p.id = t.posicao_id where p.vaga_id = (select vaga from ch)) as turnos,
  (select count(*)::int from public.posicao where vaga_id = (select vaga from ch) and estado = 'aberta') as posicoes_abertas,
  (select estado::text from public.vaga where id = (select vaga from ch)) as vaga_estado;
select is((select turnos from antes), 0, '0c sem turno antes');

-- ── A. O terceiro aceita ou recusa: 404 ───────────────────────────────────────

select is(pg_temp.r('c9180000-0000-4000-8000-000000000005',
  format($$ select public.responder_chamada(%L, 'aceitar') $$, (select chamada from ch))), 'nao_encontrado', 'A1 o terceiro (C) aceita a chamada do A: 404 nao_encontrado');
select is(pg_temp.r('c9180000-0000-4000-8000-000000000004',
  format($$ select public.responder_chamada(%L, 'aceitar') $$, (select chamada from ch))), 'nao_encontrado', 'A2 outro terceiro (B) aceita: 404 nao_encontrado');
select is(pg_temp.r('c9180000-0000-4000-8000-000000000005',
  format($$ select public.responder_chamada(%L, 'recusar', 'agenda') $$, (select chamada from ch))), 'nao_encontrado', 'A3 o terceiro recusa: 404 nao_encontrado');

-- ── B. É o mesmo 404 de uma chamada que não existe ────────────────────────────

select is(pg_temp.r('c9180000-0000-4000-8000-000000000005',
  $$ select public.responder_chamada('c9180000-0000-4000-8000-0000000000ff', 'aceitar') $$), 'nao_encontrado', 'B1 chamada que não existe: 404 nao_encontrado');
select is(
  pg_temp.r('c9180000-0000-4000-8000-000000000005', format($$ select public.responder_chamada(%L, 'aceitar') $$, (select chamada from ch))),
  pg_temp.r('c9180000-0000-4000-8000-000000000005', $$ select public.responder_chamada('c9180000-0000-4000-8000-0000000000ff', 'aceitar') $$),
  'B2 a recusa do terceiro é idêntica à da chamada inexistente: não diz que a chamada existe');

-- ── C. Nada mudou ─────────────────────────────────────────────────────────────

select is((select estado::text from public.chamada where id = (select chamada from ch)), 'aberta', 'C1 a chamada segue aberta');
select is((select respondida_em from public.chamada where id = (select chamada from ch)), (select respondida_em from antes), 'C2 sem respondida_em (nem a recusa do terceiro encerrou)');
select is((select profissional_id from public.chamada where id = (select chamada from ch)), (select a from prof_ids), 'C3 o chamado continua sendo o A');
select is((select count(*)::int from public.turno t join public.posicao p on p.id = t.posicao_id where p.vaga_id = (select vaga from ch)), 0, 'C4 nenhum turno nasceu');
select is((select count(*)::int from public.posicao where vaga_id = (select vaga from ch) and estado = 'aberta'), (select posicoes_abertas from antes), 'C5 a posição segue aberta');
select is((select estado::text from public.vaga where id = (select vaga from ch)), (select vaga_estado from antes), 'C6 a vaga não mudou');
select is((select motivo_recusa from public.chamada where id = (select chamada from ch)), null, 'C7 a recusa do terceiro não gravou motivo na chamada');

-- O profissional chamado ainda aceita, e agora sim nasce o turno.
select is(pg_temp.r('c9180000-0000-4000-8000-000000000003',
  format($$ select public.responder_chamada(%L, 'aceitar') $$, (select chamada from ch))), 'ok', 'C8 o profissional chamado aceita depois dos 404 do terceiro');
select is((select estado::text from public.chamada where id = (select chamada from ch)), 'aceita', 'C9 e a chamada vira aceita');
select is((select count(*)::int from public.turno t join public.posicao p on p.id = t.posicao_id where p.vaga_id = (select vaga from ch)), 1, 'C10 com um turno só');

select * from finish();
rollback;
