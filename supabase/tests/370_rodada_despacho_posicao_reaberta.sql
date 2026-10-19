-- Rodada de despacho da posição reaberta por atraso (cartão 9DbPXis7).
--
-- US07, US15 (cenário 4), US16 · RN05, RN12, RN22, RN23 · UC05 · decisão 8zLfn0mt item 2.
--
-- O eixo do arquivo é o relógio andando por uma vaga de duas posições que perde dois
-- profissionais seguidos:
--
--   10/10 08:00   publicação: rodada 1 para e1, e2, e3 e e4 (e5 mora a 20 km)
--                 e1 e e4 confirmam as duas posições
--   12/10 15:05   outra vaga sai para todos: a janela do teto (RN23) abre até 15:35
--   12/10 15:16   a casa reabre a posição de e1: rodada 2, urgente, fura a janela
--                 — e2 e e3 recebem de novo; e1 faltou, e4 já trabalha na vaga
--   12/10 15:20   a vaga que chega depois espera o teto, que a rodada 2 reiniciou;
--                 e2 pega a posição reaberta
--   12/10 15:36   a casa reabre a posição de e2: rodada 3 só para e3 — e1 continua
--                 fora, mesmo não sendo quem acabou de faltar
--
-- Ids próprios, começando em `d3700000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(45);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- A fila é compartilhada: começa vazia para `processar_fila_despacho` ver só o que este
-- arquivo enfileira. O rollback devolve o que havia.
delete from pgmq.q_despacho;

-- ── A estrutura: unicidade por rodada ─────────────────────────────────────────

select col_not_null('public', 'vaga', 'rodada_despacho',
  'vaga.rodada_despacho é obrigatória');
select col_default_is('public', 'vaga', 'rodada_despacho', '1',
  'a vaga nasce na rodada 1');
select col_not_null('public', 'despacho', 'rodada',
  'despacho.rodada é obrigatória');
select col_not_null('public', 'notificacao', 'rodada',
  'notificacao.rodada é obrigatória');

select ok(
  exists (select 1 from pg_constraint c
           where c.conrelid = 'public.despacho'::regclass and c.contype = 'u'
             and pg_get_constraintdef(c.oid) = 'UNIQUE (vaga_id, profissional_id, rodada)'),
  '8zLfn0mt item 2: despacho é único por (vaga_id, profissional_id, rodada)');

select ok(
  not exists (select 1 from pg_constraint c
               where c.conrelid = 'public.despacho'::regclass and c.contype = 'u'
                 and pg_get_constraintdef(c.oid) = 'UNIQUE (vaga_id, profissional_id)'),
  'a unicidade antiga, por vaga, saiu: ela é o que impedia a segunda rodada');

select ok(
  (select pg_get_indexdef('public.notificacao_marca_de_envio'::regclass)
     ~ '\(tipo, referencia_id, usuario_id, rodada\)'),
  'a marca de envio opera por rodada: (tipo, referencia_id, usuario_id, rodada)');

-- ── O elenco ──────────────────────────────────────────────────────────────────

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
  on conflict (id) do nothing;
end $$;

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

-- d1 é a casa. e1 falta primeiro; e2 é quem pega a posição reaberta e falta também; e3
-- só recebe; e4 confirma a outra posição da vaga; e5 mora a uns 20 km.
select pg_temp.autenticar('d3700000-0000-4000-8000-0000000000d1', 'd1@rodada.test');
select pg_temp.autenticar('d3700000-0000-4000-8000-0000000000e1', 'e1@rodada.test');
select pg_temp.autenticar('d3700000-0000-4000-8000-0000000000e2', 'e2@rodada.test');
select pg_temp.autenticar('d3700000-0000-4000-8000-0000000000e3', 'e3@rodada.test');
select pg_temp.autenticar('d3700000-0000-4000-8000-0000000000e4', 'e4@rodada.test');
select pg_temp.autenticar('d3700000-0000-4000-8000-0000000000e5', 'e5@rodada.test');

select set_config('frila.agora', '2026-10-10 08:00:00+00', true);

select pg_temp.como('d3700000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante', 'Casa da Rodada', '+5561955550001', '1980-01-01', '2026-09-22') $$);
select pg_temp.como('d3700000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional', 'Faltou Primeiro', '+5561955550011', '1995-01-01', '2026-09-22') $$);
select pg_temp.como('d3700000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional', 'Faltou Depois', '+5561955550012', '1995-01-01', '2026-09-22') $$);
select pg_temp.como('d3700000-0000-4000-8000-0000000000e3',
  $$ select public.criar_conta('profissional', 'Sempre Elegivel', '+5561955550013', '1995-01-01', '2026-09-22') $$);
select pg_temp.como('d3700000-0000-4000-8000-0000000000e4',
  $$ select public.criar_conta('profissional', 'Outra Posicao', '+5561955550014', '1995-01-01', '2026-09-22') $$);
select pg_temp.como('d3700000-0000-4000-8000-0000000000e5',
  $$ select public.criar_conta('profissional', 'Mora Longe', '+5561955550015', '1995-01-01', '2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid, latitude numeric default -15.7900) returns uuid
language plpgsql as $corpo$
declare v_prof uuid;
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            jsonb_build_object('latitude', %s, 'longitude', -47.8850)) $sql$,
    (select garcom from fn), latitude));
  select p.id into v_prof from public.profissional p where p.usuario_id = conta;
  -- Grade cobrindo a semana inteira: a elegibilidade deste arquivo é decidida pela
  -- distância, pela falta e pela posição, e não pelo horário.
  insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
  select v_prof, d, '00:00'::time, '23:59'::time from generate_series(0, 6) d;
  return v_prof;
end $corpo$;

create temp table pr as
  select pg_temp.perfil('d3700000-0000-4000-8000-0000000000e1') as e1,
         pg_temp.perfil('d3700000-0000-4000-8000-0000000000e2') as e2,
         pg_temp.perfil('d3700000-0000-4000-8000-0000000000e3') as e3,
         pg_temp.perfil('d3700000-0000-4000-8000-0000000000e4') as e4,
         pg_temp.perfil('d3700000-0000-4000-8000-0000000000e5', -15.6100) as e5;

create temp table casa as
  select (pg_temp.como('d3700000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa da Rodada', '04252011000110', 'food_service',
         'CLN 302 Bloco B', '{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create function pg_temp.publicar(chave uuid, inicio timestamptz, posicoes int default 1)
returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('d3700000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 302',
          '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
          15000, %s, true, true, false, 'Gerente', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn),
    inicio, inicio + interval '6 hours', posicoes, chave))->>'vaga_id')::uuid;
end $corpo$;

-- Despachos de uma vaga numa rodada, por profissional.
create function pg_temp.despachos(vaga uuid, rodada int) returns uuid[]
language sql as $$
  select coalesce(array_agg(d.profissional_id order by d.profissional_id), '{}')
    from public.despacho d
   where d.vaga_id = vaga and d.rodada = despachos.rodada
$$;

create function pg_temp.esperados(variadic ids uuid[]) returns uuid[]
language sql as $$
  select array_agg(x order by x) from unnest(ids) x
$$;

-- A notificação de vaga de uma conta numa rodada.
create function pg_temp.aviso(conta uuid, vaga uuid, rodada int) returns public.notificacao
language sql as $$
  select n.* from public.notificacao n
   where n.tipo = 'vaga' and n.usuario_id = conta and n.referencia_id = vaga
     and n.rodada = aviso.rodada
$$;

create function pg_temp.reabrir(posicao uuid) returns jsonb
language sql as $$
  select pg_temp.como('d3700000-0000-4000-8000-0000000000d1',
           format($x$ select public.reabrir_por_atraso(%L) $x$, posicao))
$$;

create function pg_temp.processar() returns int
language sql as $$
  select coalesce(sum(f.despachos), 0)::int from privado.processar_fila_despacho(10, 30) f
$$;

-- ── Rodada 1: a publicação ────────────────────────────────────────────────────

create temp table v as
  select pg_temp.publicar('d3700000-0000-4000-8000-000000000001',
                          '2026-10-12 15:00:00+00', 2) as id;

select is((select g.rodada_despacho from public.vaga g where g.id = (select id from v)), 1,
  'a vaga publicada está na rodada 1');

select is(pg_temp.processar(), 4, 'a fila despacha a rodada 1');

select is(pg_temp.despachos((select id from v), 1),
  (select pg_temp.esperados(e1, e2, e3, e4) from pr),
  'RN05: a rodada 1 vai a quem está a até 15 km, e não a quem mora a 20');

select is(
  (select count(*)::int from public.notificacao n
    where n.tipo = 'vaga' and n.referencia_id = (select id from v) and n.rodada = 1),
  4, 'cada despacho da rodada 1 vira uma notificação da rodada 1');

create temp table c1 as
  select pg_temp.como('d3700000-0000-4000-8000-0000000000e1',
           format($$ select public.candidatar(%L) $$, (select id from v))) as e1,
         pg_temp.como('d3700000-0000-4000-8000-0000000000e4',
           format($$ select public.candidatar(%L) $$, (select id from v))) as e4;

select is((select g.estado::text from public.vaga g where g.id = (select id from v)),
  'preenchida', 'e1 e e4 confirmam as duas posições e a vaga fica preenchida');

-- ── 15:05: outra vaga abre a janela do teto de todos ──────────────────────────

select set_config('frila.agora', '2026-10-12 15:05:00+00', true);

create temp table vb as
  select pg_temp.publicar('d3700000-0000-4000-8000-000000000002',
                          '2026-10-20 15:00:00+00') as id;
select pg_temp.processar();

select is(
  (select (pg_temp.aviso('d3700000-0000-4000-8000-0000000000e3', (select id from vb), 1)).enviada_em),
  '2026-10-12 15:05:00+00'::timestamptz,
  'às 15:05 e3 recebe outra vaga: a janela do teto dele vai até 15:35');

-- ── 15:16: a casa reabre a posição de e1 ──────────────────────────────────────

select set_config('frila.agora', '2026-10-12 15:16:00+00', true);

create temp table r1 as
  select pg_temp.reabrir((select (e1->>'posicao_id')::uuid from c1)) as res;

select is((select g.rodada_despacho from public.vaga g where g.id = (select id from v)), 2,
  'reabrir_por_atraso abre a rodada 2 da vaga');

select is((select g.estado::text from public.vaga g where g.id = (select id from v)),
  'publicada', 'e a vaga volta a publicada');

select is(pg_temp.processar(), 2, 'a fila despacha a rodada 2');

select is(pg_temp.despachos((select id from v), 2),
  (select pg_temp.esperados(e2, e3) from pr),
  '8zLfn0mt item 2: a rodada 2 vai de novo a quem recebeu a rodada 1, menos quem faltou e quem já trabalha na vaga');

select ok(
  (select e1 from pr) <> all (pg_temp.despachos((select id from v), 2)),
  'RN12: e1, que faltou, não recebe a vaga que deixou de cumprir');

select ok(
  (select e4 from pr) <> all (pg_temp.despachos((select id from v), 2)),
  'e4, confirmado na outra posição da mesma vaga, não é chamado para ela de novo');

select ok(
  (select e5 from pr) <> all (pg_temp.despachos((select id from v), 2)),
  'RN05: a rodada 2 respeita o raio de 15 km como a primeira');

select is(
  (select count(*)::int from public.notificacao n
    where n.tipo = 'vaga' and n.referencia_id = (select id from v)
      and n.usuario_id = 'd3700000-0000-4000-8000-0000000000e3'),
  2, 'e3 tem duas notificações da mesma vaga, uma por rodada');

select is(
  (select (pg_temp.aviso('d3700000-0000-4000-8000-0000000000e3', (select id from v), 2)).payload),
  jsonb_build_object('vaga_id', (select id from v), 'reaberta', true, 'tipo', 'vaga'),
  'Push 04: a notificação da rodada 2 é a de vaga reaberta, e o payload é só estrutura (RN15)');

select is(
  (select d.reaberta from public.despacho d
    where d.vaga_id = (select id from v) and d.rodada = 2
      and d.profissional_id = (select e3 from pr)),
  true, 'o despacho da rodada 2 guarda que a vaga foi reaberta');

select is(
  (select (pg_temp.aviso('d3700000-0000-4000-8000-0000000000e3', (select id from v), 2)).urgente),
  true, 'RN23: o turno já começou, então a rodada 2 é urgente');

select is(
  (select (pg_temp.aviso('d3700000-0000-4000-8000-0000000000e3', (select id from v), 2)).enviada_em),
  '2026-10-12 15:16:00+00'::timestamptz,
  'RN23: urgente fura a janela aberta às 15:05 e sai na hora');

select is(
  (select d.notificacao_id from public.despacho d
    where d.vaga_id = (select id from v) and d.rodada = 2
      and d.profissional_id = (select e3 from pr)),
  (select (pg_temp.aviso('d3700000-0000-4000-8000-0000000000e3', (select id from v), 2)).id),
  'o despacho da rodada 2 aponta para a notificação que o levou');

select is(
  privado.notificacao_expirada(
    (select (pg_temp.aviso('d3700000-0000-4000-8000-0000000000e3', (select id from v), 2)).id)),
  false, 'a notificação da rodada 2 não expira porque o turno começou: vale até 1 h antes do fim');

select is(
  privado.despachar_vaga((select id from v), 'reabertura',
                         'd3700000-0000-4000-8000-0000000000e1'::uuid),
  0, 'despachar a rodada 2 de novo não cria despacho');

select is(
  (select count(*)::int from public.notificacao n
    where n.tipo = 'vaga' and n.referencia_id = (select id from v) and n.rodada = 2),
  2, 'nem notificação: a marca de envio por rodada segura o reenvio');

select is(
  (select r1.res from r1),
  pg_temp.reabrir((select (e1->>'posicao_id')::uuid from c1)),
  'reenviar reabrir_por_atraso devolve o mesmo resultado');

select is((select g.rodada_despacho from public.vaga g where g.id = (select id from v)), 2,
  'e o reenvio não abre outra rodada');

select is((select count(*)::int from pgmq.q_despacho), 0,
  'nem enfileira outro despacho');

-- ── 15:20: a rodada 2 conta no teto ───────────────────────────────────────────

select set_config('frila.agora', '2026-10-12 15:20:00+00', true);

create temp table vc as
  select pg_temp.publicar('d3700000-0000-4000-8000-000000000003',
                          '2026-10-21 15:00:00+00') as id;
select pg_temp.processar();

select is(
  (select d.notificacao_id from public.despacho d
    where d.vaga_id = (select id from vc) and d.profissional_id = (select e3 from pr)),
  null,
  'RN23: a vaga não urgente das 15:20 espera o teto, que a rodada 2 das 15:16 reiniciou');

select is(
  (select pg_temp.aviso('d3700000-0000-4000-8000-0000000000e3', (select id from vc), 1)) is null,
  true, 'e nenhuma notificação dela sai antes de 15:46');

create temp table c2 as
  select pg_temp.como('d3700000-0000-4000-8000-0000000000e2',
           format($$ select public.candidatar(%L) $$, (select id from v))) as e2;

select is((select (e2->>'posicao_id')::uuid from c2),
  (select (res->>'nova_posicao_id')::uuid from r1),
  'e2 pega a posição reaberta');

-- ── 15:36: a casa reabre a posição de e2 ──────────────────────────────────────

select set_config('frila.agora', '2026-10-12 15:36:00+00', true);

create temp table r2 as
  select pg_temp.reabrir((select (e2->>'posicao_id')::uuid from c2)) as res;

select is((select (res->>'reaberta')::boolean from r2), true,
  'a segunda falta também reabre');

select is((select g.rodada_despacho from public.vaga g where g.id = (select id from v)), 3,
  'e abre a rodada 3');

select is(pg_temp.processar(), 1, 'a fila despacha a rodada 3');

select is(pg_temp.despachos((select id from v), 3),
  (select pg_temp.esperados(e3) from pr),
  'a rodada 3 vai só a e3');

select ok(
  (select e1 from pr) <> all (pg_temp.despachos((select id from v), 3)),
  'RN12: e1 continua fora, embora a conta excluída desta reabertura seja a de e2');

select is(
  (select (pg_temp.aviso('d3700000-0000-4000-8000-0000000000e3', (select id from v), 3)).payload
     ->> 'reaberta'),
  'true', 'Push 04 também na rodada 3');

-- ── As restrições ─────────────────────────────────────────────────────────────

select throws_ok(
  format($$ insert into public.despacho (vaga_id, profissional_id, rodada) values (%L, %L, 3) $$,
         (select id from v), (select e3 from pr)),
  '23505', null,
  'despacho_vaga_profissional_rodada_key: o mesmo profissional não é despachado duas vezes na mesma rodada');

select throws_ok(
  format($$ update public.vaga set rodada_despacho = 0 where id = %L $$, (select id from v)),
  '23514', null,
  'vaga_rodada_despacho_positiva: a rodada da vaga começa em 1');

select throws_ok(
  format($$ insert into public.despacho (vaga_id, profissional_id, rodada) values (%L, %L, 0) $$,
         (select id from v), (select e5 from pr)),
  '23514', null,
  'despacho_rodada_positiva: a rodada do despacho começa em 1');

select throws_ok(
  format($$ update public.notificacao set rodada = 0 where id = %L $$,
         (select (pg_temp.aviso('d3700000-0000-4000-8000-0000000000e3', (select id from v), 3)).id)),
  '23514', null,
  'notificacao_rodada_positiva: a rodada da notificação começa em 1');

select * from finish();
rollback;
