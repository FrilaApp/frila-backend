-- 907_bloqueio_dois_sentidos_encerra_chamada.sql
--
-- Gatilho trg_bloqueio_encerrar_chamada -> privado.processar_bloqueio_chamada (20261107350000, única definição),
-- depois de um INSERT em public.bloqueio. A regra, lida no corpo da função:
--   encerra toda chamada 'aberta' do ESTABELECIMENTO (não importa qual membro a criou) com o profissional, quando
--     ramo 1: o AUTOR do bloqueio é membro da casa e o BLOQUEADO é o profissional; ou
--     ramo 2: o BLOQUEADO é membro da casa e o AUTOR é o profissional (o profissional bloqueia a casa, na prática
--             um membro dela, porque o bloqueio é entre usuários).
--   Só 'aberta' muda: aceita, recusada e as demais ficam como estão. O 808 cobre só o ramo 1 com o criador da chamada.
-- Cenário (`cenarios.sql`): casa c…01 com dois membros (b…01 administrador, b…04 operador); casa c…02 (b…02); profissionais
-- Ana a Heitor (a…01 a a…08). Só dados sintéticos.
begin;
select plan(16);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-27 12:00:00+00', true);

create temp table ids as select
  'c0000000-0000-4000-8000-000000000001'::uuid as casa1,
  'c0000000-0000-4000-8000-000000000002'::uuid as casa2,
  'd0000000-0000-4000-8000-000000000001'::uuid as vaga_casa1,
  'd0000000-0000-4000-8000-000000000003'::uuid as vaga_casa2;

create function pg_temp.prof(n int) returns uuid language sql as
  $$ select ('e0000000-0000-4000-8000-00000000000' || n)::uuid $$;
create function pg_temp.usr(n int) returns uuid language sql as
  $$ select ('a0000000-0000-4000-8000-00000000000' || n)::uuid $$;

-- Uma chamada por caso (o par casa+profissional só aceita uma 'aberta' por vez).
--   X1 Ana   casa1 aberta, criada por b…01        -> Ana bloqueia b…01 (ramo 2)
--   X1b Ana  casa2 aberta, criada por b…02        -> controle: outra casa de Ana
--   X1c Elisa casa1 aberta, criada por b…01       -> controle: outro profissional da casa1
--   X2 Bruno casa1 aberta, criada por b…04        -> Bruno bloqueia b…01, que NÃO a criou (ramo 2, outro membro)
--   X3 Carla casa1 aceita                         -> Carla bloqueia b…01: intocada
--   X4 Diego casa1 recusada                       -> Diego bloqueia b…01: intocada
--   X5 Gabi  casa1 aberta, criada por b…01        -> b…04 bloqueia Gabi (ramo 1, outro membro que não criou)
insert into public.chamada (id, vaga_id, profissional_id, estabelecimento_id, criada_por, estado, expira_em, respondida_em, chave)
select ('f9070000-0000-4000-8000-0000000000' || lpad(k::text, 2, '0'))::uuid, v, pg_temp.prof(p), est, criador, st,
       '2026-11-28 12:00:00+00', resp, gen_random_uuid()
  from (values
    (1, (select vaga_casa1 from ids), 1, (select casa1 from ids), 'b0000000-0000-4000-8000-000000000001'::uuid, 'aberta',   null::timestamptz),
    (2, (select vaga_casa2 from ids), 1, (select casa2 from ids), 'b0000000-0000-4000-8000-000000000002'::uuid, 'aberta',   null),
    (3, (select vaga_casa1 from ids), 5, (select casa1 from ids), 'b0000000-0000-4000-8000-000000000001'::uuid, 'aberta',   null),
    (4, (select vaga_casa1 from ids), 2, (select casa1 from ids), 'b0000000-0000-4000-8000-000000000004'::uuid, 'aberta',   null),
    (5, (select vaga_casa1 from ids), 3, (select casa1 from ids), 'b0000000-0000-4000-8000-000000000001'::uuid, 'aceita',   '2026-11-27 11:00:00+00'),
    (6, (select vaga_casa1 from ids), 4, (select casa1 from ids), 'b0000000-0000-4000-8000-000000000001'::uuid, 'recusada', '2026-11-27 11:30:00+00'),
    (7, (select vaga_casa1 from ids), 7, (select casa1 from ids), 'b0000000-0000-4000-8000-000000000001'::uuid, 'aberta',   null)
  ) t(k, v, p, est, criador, st, resp);

create function pg_temp.estado(k int) returns text language sql as
  $$ select estado from public.chamada where id = ('f9070000-0000-4000-8000-0000000000' || lpad(k::text, 2, '0'))::uuid $$;

select is(pg_temp.estado(1), 'aberta', '0 o cenário parte com as chamadas abertas (nenhum caso passa vazio)');
select is(pg_temp.estado(5), 'aceita',  '0b e com a chamada aceita como aceita');

-- ── 1. Ramo 2: o profissional bloqueia um membro da casa ─────────────────────

insert into public.bloqueio (autor_id, bloqueado_id)
values (pg_temp.usr(1), 'b0000000-0000-4000-8000-000000000001');

select is(pg_temp.estado(1), 'encerrada',
  '1 profissional bloqueia a casa: a chamada aberta da casa com ele é encerrada');
select isnt(
  (select respondida_em from public.chamada where id = 'f9070000-0000-4000-8000-000000000001'), null,
  '2 e o encerramento carimba respondida_em');
select is(
  (select respondida_em from public.chamada where id = 'f9070000-0000-4000-8000-000000000001'),
  '2026-11-27 12:00:00+00'::timestamptz,
  '3 com o relógio do produto (privado.agora)');
select is(pg_temp.estado(2), 'aberta',
  '4 a chamada do mesmo profissional em OUTRA casa continua aberta');
select is(pg_temp.estado(3), 'aberta',
  '5 a chamada de OUTRO profissional da mesma casa continua aberta');

-- ── 2. Ramo 2 com a chamada criada por outro membro ──────────────────────────

insert into public.bloqueio (autor_id, bloqueado_id)
values (pg_temp.usr(2), 'b0000000-0000-4000-8000-000000000001');

select is(pg_temp.estado(4), 'encerrada',
  '6 a chamada aberta por OUTRO membro da casa também é encerrada (a regra é por estabelecimento, não por criador)');

-- ── 3. Chamada já respondida fica intocada ───────────────────────────────────

insert into public.bloqueio (autor_id, bloqueado_id) values
  (pg_temp.usr(3), 'b0000000-0000-4000-8000-000000000001'),
  (pg_temp.usr(4), 'b0000000-0000-4000-8000-000000000001');

select is(pg_temp.estado(5), 'aceita',   '7 chamada aceita não é encerrada pelo bloqueio');
select is(pg_temp.estado(6), 'recusada', '8 chamada recusada não é encerrada pelo bloqueio');
select is(
  (select respondida_em from public.chamada where id = 'f9070000-0000-4000-8000-000000000005'),
  '2026-11-27 11:00:00+00'::timestamptz,
  '9 e a respondida_em da aceita não muda');
select is(
  (select respondida_em from public.chamada where id = 'f9070000-0000-4000-8000-000000000006'),
  '2026-11-27 11:30:00+00'::timestamptz,
  '10 nem a da recusada');

-- ── 4. Ramo 1 com a chamada criada por outro membro (o 808 cobre só o criador) ─

select is(pg_temp.estado(7), 'aberta', '11 antes do bloqueio a chamada da Gabi está aberta');

insert into public.bloqueio (autor_id, bloqueado_id)
values ('b0000000-0000-4000-8000-000000000004', pg_temp.usr(7));

select is(pg_temp.estado(7), 'encerrada',
  '12 a casa bloqueia o profissional por OUTRO membro que não criou a chamada: encerrada');

-- ── 5. O bloqueio sem relação com a chamada não encerra nada ─────────────────

select is(pg_temp.estado(3), 'aberta',
  '13 a chamada de quem não foi bloqueado (Elisa) segue aberta depois de todos os bloqueios');
select is(pg_temp.estado(2), 'aberta',
  '14 e a da outra casa também');

select * from finish();
rollback;
