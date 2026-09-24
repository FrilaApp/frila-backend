-- O ciclo inteiro numa transação só, com o relógio do produto sob controle.
--
-- Cartão `yKUkCjSU`. Cada cartão de RPC entrega os próprios testes, e eles cobrem bem o
-- que cada função recusa. O que faltava era **o caminho completo**: criar conta →
-- publicar → listar → candidatar → acompanhar → contato → check-in → check-out → avaliar
-- → perfil público → cancelar, sem nenhuma escrita direta na tabela pelo meio.
--
-- Por que isso não é redundante com os arquivos por RPC:
--
--   1. Eles montam o estado à mão. Aqui cada passo é a saída do passo anterior, então uma
--      RPC que grave uma coluna a menos aparece três passos adiante — que é o modo de
--      falha que nenhum teste isolado enxerga.
--   2. O `ciclo-completo.sh` faz o caminho por HTTP, mas **não alcança o caminho feliz**:
--      o relógio do produto só é sobreponível dentro da transação, e sem isso não dá para
--      chegar ao fim do turno, ao check-out nem à avaliação. Ali estão as recusas; o
--      caminho feliz é aqui.
--   3. Prazo é a regra que mais some sem ninguém ver. Este arquivo anda com o relógio de
--      véspera até depois do fim do turno, e é isso que prova que os prazos existem.

begin;
select plan(20);

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role;
  execute 'reset request.jwt.claims';
  return r;
end $$;

-- ── O relógio ─────────────────────────────────────────────────────────────────
--
-- Escrito aqui dentro e levado pelo rollback, como em 180. Todas as datas deste arquivo
-- estão no futuro do `now()` real: se alguma regra olhar `now()` em vez de
-- `privado.agora()`, o caminho feliz fica vermelho em vez de passar por acidente.
insert into privado.ambiente (id, eh_teste) values (true, true);

-- Véspera da publicação. O turno é no dia 20; o modo é `urgencia`, que não exige as 24 h
-- da RN24 — o modo seleção é recusado na v1.0.
set local frila.agora = '2026-11-18 09:00:00+00';

-- ── As duas contas ────────────────────────────────────────────────────────────
--
-- Ids próprios, prefixo `c9`, que não existe em `cenarios.sql` nem nos outros arquivos de
-- teste. Nada aqui conta linha da tabela inteira: tudo é por id.
insert into auth.users (instance_id, id, aud, role, email, created_at, updated_at,
                        is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000','c9000000-0000-4000-8000-000000000001',
        'authenticated','authenticated','ciclo-casa@t.test',
        privado.agora(), privado.agora(), false, false),
       ('00000000-0000-0000-0000-000000000000','c9000000-0000-4000-8000-000000000002',
        'authenticated','authenticated','ciclo-prof@t.test',
        privado.agora(), privado.agora(), false, false);

select is(
  pg_temp.como('c9000000-0000-4000-8000-000000000001',
    $$ select public.criar_conta('contratante','Dona do Ciclo','+5561977770001','1980-02-02','2026-09-22') $$)
    ->>'perfil',
  'contratante',
  'RN25: a conta do contratante nasce com um perfil, e é o dela');

select is(
  pg_temp.como('c9000000-0000-4000-8000-000000000002',
    $$ select public.criar_conta('profissional','Pê do Ciclo','+5561977770002','1996-03-03','2026-09-22') $$)
    ->>'perfil',
  'profissional',
  'RN25: e a do profissional também, e as duas são contas diferentes');

create temp table funcao_do_ciclo as
  select id from public.funcao where nome = 'garçom';

select isnt(
  pg_temp.como('c9000000-0000-4000-8000-000000000002', format(
    $$ select public.criar_perfil_profissional(array[%L]::uuid[],
         '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb,
         '[{"dia_semana":4,"hora_inicio":"18:00","hora_fim":"23:59"}]'::jsonb) $$,
    (select id from funcao_do_ciclo))),
  null,
  'o perfil profissional entra com função, ponto base e grade');

create temp table casa_do_ciclo as
  select (pg_temp.como('c9000000-0000-4000-8000-000000000001',
    $$ select public.cadastrar_estabelecimento('Casa do Ciclo','06990590000123','food_service',
         'CLN 210','{"latitude":-15.7905,"longitude":-47.8855}') $$)->>'id')::uuid as id;

select isnt(
  (select id from casa_do_ciclo), null,
  'o estabelecimento é cadastrado pela RPC, e devolve o id');

-- ── Publicar ──────────────────────────────────────────────────────────────────
create temp table vaga_do_ciclo as
  select (pg_temp.como('c9000000-0000-4000-8000-000000000001', format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2026-11-20 22:00:00+00'::timestamptz, '2026-11-21 04:00:00+00'::timestamptz,
         'CLN 210', '{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
         15000::bigint, 1, true, false, false, 'Gerente do Ciclo',
         'urgencia'::public.modo_preenchimento, %L::uuid) $$,
    (select id from casa_do_ciclo), (select id from funcao_do_ciclo),
    gen_random_uuid()))->>'vaga_id')::uuid as id;

select isnt(
  (select id from vaga_do_ciclo), null,
  'a vaga é publicada e devolve o id');

select is(
  (select count(*)::int from public.posicao p, vaga_do_ciclo v
    where p.vaga_id = v.id and p.estado = 'aberta'),
  1,
  'e nasce com a posição aberta que `posicoes` pediu — sem escrita direta na tabela');

-- A fila do despacho recebe a mensagem que o Sprint 2 vai consumir.
select is(
  (select count(*)::int from pgmq.q_despacho q, vaga_do_ciclo v
    where (q.message->>'vaga_id')::uuid = v.id),
  1,
  'e a publicação enfileira o despacho, com o vaga_id que o motor do Sprint 2 espera');

-- ── Achar a vaga ──────────────────────────────────────────────────────────────
select is(
  (select count(*)::int
     from jsonb_array_elements(
       coalesce(pg_temp.como('c9000000-0000-4000-8000-000000000002',
         $$ select public.vagas_abertas(-15.7900, -47.8850) $$), '[]'::jsonb)) e,
          vaga_do_ciclo v
    where (e->>'id')::uuid = v.id),
  1,
  'o profissional acha a vaga em vagas_abertas — a lista é a porta de entrada do ciclo');

-- ── Candidatar, que no modo urgência já confirma ──────────────────────────────
create temp table turno_do_ciclo as
  select (pg_temp.como('c9000000-0000-4000-8000-000000000002', format(
    $$ select public.candidatar(%L::uuid) $$, (select id from vaga_do_ciclo)))->>'turno_id')::uuid as id;

select isnt(
  (select id from turno_do_ciclo), null,
  'RN19: no modo urgência a candidatura já confirma a posição e abre o turno');

select is(
  (select p.estado::text from public.posicao p, vaga_do_ciclo v where p.vaga_id = v.id),
  'confirmada',
  'e a posição fica confirmada, com dono');

-- ── Acompanhar e pedir o contato ──────────────────────────────────────────────
select is(
  (select count(*)::int
     from jsonb_array_elements(
       coalesce(pg_temp.como('c9000000-0000-4000-8000-000000000002',
         $$ select public.meus_turnos() $$), '[]'::jsonb)) e,
          turno_do_ciclo t
    where (e->>'id')::uuid = t.id),
  1,
  'o turno aparece em meus_turnos, do lado do profissional');

-- RN10: o contato sai pela RPC, e só depois da confirmação.
select isnt(
  pg_temp.como('c9000000-0000-4000-8000-000000000002', format(
    $$ select public.contato_do_turno(%L::uuid) $$, (select id from turno_do_ciclo)))->>'telefone',
  null,
  'RN10: o contato da casa sai por contato_do_turno depois de confirmado, e não antes');

-- ── A presença, no relógio do turno ───────────────────────────────────────────
--
-- Daqui para a frente o relógio anda. Este é o trecho que o `ciclo-completo.sh` não
-- alcança: por HTTP o relógio é o de verdade, e o turno do ciclo começa dias à frente.
set local frila.agora = '2026-11-20 22:05:00+00';

select is(
  pg_temp.como('c9000000-0000-4000-8000-000000000002', format(
    $$ select public.fazer_checkin(%L::uuid, 45, '2026-11-20 22:05:00+00'::timestamptz) $$,
    (select id from turno_do_ciclo)))
    ->>'verificacao',
  'verificado',
  'RN22: check-in geolocalizado a 45 m nasce verificado — dentro dos 200 m');

set local frila.agora = '2026-11-21 04:00:00+00';

-- Medido aqui: o check-out tem de cair **dentro** da janela, e `privado.exigir_janela`
-- recusa `registrado_em > fim` com `fora_da_janela`. Bater o ponto às 04:05 num turno que
-- termina às 04:00 é recusado. Não é defeito deste teste: o aviso de hora excedida é um
-- cartão do Sprint 2, e até ele existir o fim previsto é o teto.
select isnt(
  pg_temp.como('c9000000-0000-4000-8000-000000000002', format(
    $$ select public.fazer_checkout(%L::uuid, 60, '2026-11-21 03:58:00+00'::timestamptz) $$,
    (select id from turno_do_ciclo)))
    ->>'registrado_em',
  null,
  'e o check-out fecha o turno dentro da janela, antes do fim previsto');

-- ── Avaliar, dos dois lados ───────────────────────────────────────────────────
set local frila.agora = '2026-11-21 05:00:00+00';

select is(
  (pg_temp.como('c9000000-0000-4000-8000-000000000001', format(
    $$ select public.avaliar(%L::uuid, true) $$, (select id from turno_do_ciclo)))
    ->>'resposta')::boolean,
  true,
  'RN07: a casa avalia depois do fim, com presença verificada');

select is(
  (pg_temp.como('c9000000-0000-4000-8000-000000000002', format(
    $$ select public.avaliar(%L::uuid, true) $$, (select id from turno_do_ciclo)))
    ->>'resposta')::boolean,
  true,
  'e o profissional avalia o outro lado, na mesma janela');

select is(
  pg_temp.como('c9000000-0000-4000-8000-000000000001', format(
    $$ select public.perfil_publico(%L::uuid) $$,
    (select p.id from public.profissional p
      where p.usuario_id = 'c9000000-0000-4000-8000-000000000002')))->'reputacao',
  '{"total": 1, "positivas": 1, "turnos_realizados": 1, "turnos_considerados": 1, "taxa_comparecimento": 1.000}'::jsonb,
  'RN08: a reputação do profissional fecha o ciclo — 1 de 1, e a taxa cheia');

-- ── Cancelar, numa vaga nova ──────────────────────────────────────────────────
--
-- A posição cancelada não volta para `aberta`: a vaga ganha uma posição nova. Uma vaga
-- própria, para não desfazer o turno que acabou de ser avaliado.
set local frila.agora = '2026-11-21 06:00:00+00';

create temp table vaga_cancelada as
  select (pg_temp.como('c9000000-0000-4000-8000-000000000001', format(
    $$ select public.publicar_vaga(%L::uuid, %L::uuid,
         '2026-11-27 22:00:00+00'::timestamptz, '2026-11-28 04:00:00+00'::timestamptz,
         'CLN 210', '{"latitude":-15.7905,"longitude":-47.8855}'::jsonb,
         15000::bigint, 1, true, false, false, 'Gerente do Ciclo',
         'urgencia'::public.modo_preenchimento, %L::uuid) $$,
    (select id from casa_do_ciclo), (select id from funcao_do_ciclo),
    gen_random_uuid()))->>'vaga_id')::uuid as id;

select isnt(
  pg_temp.como('c9000000-0000-4000-8000-000000000002', format(
    $$ select public.candidatar(%L::uuid) $$, (select id from vaga_cancelada)))->>'turno_id',
  null,
  'RN21: o profissional aceita a segunda vaga, que não cruza com a primeira');

create temp table cancelamento as
  select pg_temp.como('c9000000-0000-4000-8000-000000000002', format(
    $$ select public.cancelar_posicao(%L::uuid, 'imprevisto') $$,
    (select p.id from public.posicao p, vaga_cancelada v
      where p.vaga_id = v.id and p.estado = 'confirmada'))) as r;

select is(
  (select (r->>'reaberta')::boolean from cancelamento),
  true,
  'RN12: cancelar antes do início reabre a vaga');

select is(
  (select count(*)::int from public.posicao p, vaga_cancelada v
    where p.vaga_id = v.id and p.estado = 'aberta'),
  1,
  'e a posição nova nasce aberta — a cancelada guarda de quem era, e não volta atrás');

select * from finish();
rollback;
