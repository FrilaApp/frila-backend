-- 602_relogio_cancelamento_posicao.sql
--
-- Portão de relógio do produto (relogio-do-produto.sh):
-- privado.cancelamento_da_posicao deve usar privado.agora() e não now()
-- quando confirmado_em é nulo e não há ocorrência registrada.

begin;
select plan(7);

-- Ativa ambiente de teste e fixa o relógio inicial
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-20 15:30:00-03', true);

-- Usa uma vaga existente de cenarios.sql
create temp table dados as
select
  v.id as vaga_id,
  p.id as profissional_id
from public.vaga v
cross join public.profissional p
limit 1;

-- Cria uma posição cancelada sem ocorrência e com confirmado_em nulo
create temp table pos_teste as
with ins as (
  insert into public.posicao (
    vaga_id,
    estado,
    profissional_id,
    confirmado_em,
    falta,
    inicio_em,
    fim_em
  )
  select
    d.vaga_id,
    'cancelada'::public.estado_posicao,
    d.profissional_id,
    null::timestamptz,
    false,
    '2026-11-25 18:00:00-03'::timestamptz,
    '2026-11-25 23:00:00-03'::timestamptz
  from dados d
  returning id
)
select id from ins;

-- 1. Verifica cancelamento_da_posicao com relógio em 2026-11-20 15:30:00-03
create temp table res1 as
select privado.cancelamento_da_posicao((select id from pos_teste)) as c;

select is(
  (select c->>'causa' from res1),
  'outro',
  'causa de cancelamento sem ocorrência é outro');

select is(
  (select (c->>'falta')::boolean from res1),
  false,
  'falta é preservada como false');

select is(
  (select c->>'motivo' from res1),
  null,
  'motivo é nulo');

select is(
  (select (c->>'cancelada_em')::timestamptz from res1),
  '2026-11-20 15:30:00-03'::timestamptz,
  'cancelada_em sai igual a privado.agora() quando confirmado_em é nulo');

-- 2. Verifica também que cancelamento_do_turno respeita o relógio
select is(
  (select (privado.cancelamento_do_turno((select id from pos_teste))->>'cancelada_em')::timestamptz),
  '2026-11-20 15:30:00-03'::timestamptz,
  'privado.cancelamento_do_turno também respeita o relógio congelado');

-- 3. Desloca o relógio e confira que cancelada_em acompanha o relógio e não now()
select set_config('frila.agora', '2026-12-05 09:00:00-03', true);

create temp table res2 as
select privado.cancelamento_da_posicao((select id from pos_teste)) as c;

select is(
  (select (c->>'cancelada_em')::timestamptz from res2),
  '2026-12-05 09:00:00-03'::timestamptz,
  'ao avançar o relógio do produto, cancelada_em acompanha o novo valor de frila.agora');

-- 4. Quando confirmado_em está presente, ele prevalece sobre o relógio
update public.posicao
   set confirmado_em = '2026-11-10 12:00:00-03'
 where id = (select id from pos_teste);

create temp table res3 as
select privado.cancelamento_da_posicao((select id from pos_teste)) as c;

select is(
  (select (c->>'cancelada_em')::timestamptz from res3),
  '2026-11-10 12:00:00-03'::timestamptz,
  'quando confirmado_em está preenchido, ele tem precedência');

select * from finish();
rollback;
