-- Teto e agrupamento de notificações de vaga (RN23). Cartão ee3MT3fH.
--
-- No máximo uma notificação de vaga a cada 30 minutos por profissional. O despacho que
-- chega dentro da janela espera (`despacho.notificacao_id` nulo) e, no fim dela, os que
-- esperaram viram uma notificação só ('3 vagas novas perto de você'). A vaga que começa em
-- menos de 2 h fura o agrupamento, sai na hora e reinicia o teto. Lembretes e avisos de
-- turno não contam.
--
-- Relógio controlado por `frila.agora`. Ids próprios, começando em `c3300000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(52);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

-- ── 1. A configuração e as funções ────────────────────────────────────────────

select has_table('privado', 'parametro_notificacao', 'os parâmetros do teto moram em tabela');
select has_table('privado', 'tipo_no_teto', 'os tipos que contam no teto moram em tabela');

select is(privado.parametro_de_notificacao('teto_janela'), interval '30 minutes',
  'RN23: a janela do teto é de 30 minutos, lida da configuração');
select is(privado.parametro_de_notificacao('urgente_antecedencia'), interval '2 hours',
  'RN23: urgente é a vaga que começa em menos de 2 horas, lido da configuração');

select throws_ok(
  $$ select privado.parametro_de_notificacao('nao_existe') $$,
  'P0002', null,
  'parâmetro ausente é erro, e não um teto que some em silêncio');

select set_eq(
  $$ select tipo::text from privado.tipo_no_teto $$,
  array['vaga', 'vagas_agrupadas'],
  'só vaga e vagas_agrupadas contam no teto (lembrete e aviso de turno não)');

select throws_ok(
  $$ update privado.parametro_notificacao set valor = interval '0' where chave = 'teto_janela' $$,
  '23514', null,
  'CHECK parametro_positivo: janela zero ou negativa é recusada');

select throws_ok(
  $$ insert into privado.parametro_notificacao (chave, valor, finalidade)
     values ('sem_finalidade', interval '1 minute', ' ') $$,
  '23514', null,
  'CHECK finalidade_declarada: parâmetro sem finalidade é recusado');

select throws_ok(
  $$ insert into privado.tipo_no_teto (tipo, finalidade) values ('lembrete_3h', '') $$,
  '23514', null,
  'CHECK finalidade_declarada: tipo no teto sem finalidade é recusado');

select has_column('public', 'notificacao', 'esperou_teto',
  'notificacao diz se esperou o teto (a RNF03 mede só as que não esperaram)');

select is(
  has_function_privilege('authenticated', 'privado.liberar_teto(integer)', 'execute'),
  false, 'privado.liberar_teto não é chamável por authenticated');
select is(
  has_function_privilege('anon', 'privado.liberar_teto_do_profissional(uuid)', 'execute'),
  false, 'privado.liberar_teto_do_profissional não é chamável por anon');
select is(
  has_function_privilege('authenticated', 'privado.contexto_do_push(uuid)', 'execute'),
  false, 'privado.contexto_do_push não é chamável por authenticated');
select is(
  has_function_privilege('service_role', 'privado.contexto_do_push(uuid)', 'execute'),
  true, 'privado.contexto_do_push é chamável pela Edge Function (service_role)');

select ok(
  exists (select 1 from cron.job where jobname = 'liberar_teto'
             and command = 'select privado.liberar_teto()'),
  'o pg_cron libera os despachos que esperaram o teto a cada minuto');

-- ── 2. O cenário: um profissional com a grade inteira, perto do Bar do Cerrado ─

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

select pg_temp.autenticar('c3300000-0000-4000-8000-0000000000e1', 'teto@rn23.test');
select pg_temp.como('c3300000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Prof do Teto','+5561933330001','1995-01-01','2026-09-22') $$);
select pg_temp.como('c3300000-0000-4000-8000-0000000000e1', format(
  $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
          '{"latitude":-15.7620,"longitude":-47.8869}'::jsonb) $sql$,
  (select id from public.funcao where nome = 'garçom')));

create temp table eu as
  select p.id as prof, p.usuario_id as usr
    from public.profissional p
   where p.usuario_id = 'c3300000-0000-4000-8000-0000000000e1';

insert into public.disponibilidade (profissional_id, dia_semana, hora_inicio, hora_fim)
select (select prof from eu), d, '00:00'::time, '23:59'::time
  from generate_series(0, 6) as d;

-- Vaga do Bar do Cerrado, publicada por quem publicou a vaga de referência do seed.
-- `inicio` é relativo ao relógio do produto no momento da criação.
create function pg_temp.vaga(p_id uuid, p_inicio interval) returns uuid
language plpgsql as $$
begin
  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, publicado_por, modo,
                           estado, chave_cliente)
  values (p_id, 'c0000000-0000-4000-8000-000000000001',
          (select id from public.funcao where nome = 'garçom'),
          privado.agora() + p_inicio, privado.agora() + p_inicio + interval '4 hours',
          'CLN 208', 'POINT(-47.8869 -15.7620)'::extensions.geography,
          12000, 1, false, false, false, 'Gerente',
          (select publicado_por from public.vaga
            where id = 'd0000000-0000-4000-8000-000000000001'),
          'urgencia', 'publicada', gen_random_uuid());
  return p_id;
end $$;

-- Publica (vaga + despacho) num instante do relógio.
create function pg_temp.publicar(p_quando timestamptz, p_id uuid, p_inicio interval,
                                 p_motivo text default null)
returns int language plpgsql as $$
begin
  perform set_config('frila.agora', p_quando::text, true);
  perform pg_temp.vaga(p_id, p_inicio);
  return privado.despachar_vaga(p_id, p_motivo, null);
end $$;

create function pg_temp.liberar(p_quando timestamptz) returns int
language plpgsql as $$
begin
  perform set_config('frila.agora', p_quando::text, true);
  return privado.liberar_teto();
end $$;

-- As notificações de vaga do profissional, na ordem em que saíram.
create function pg_temp.minhas() returns table (tipo text, enviada_em timestamptz,
                                                urgente boolean, esperou boolean, ref uuid)
language sql as $$
  select n.tipo::text, n.enviada_em, n.urgente, n.esperou_teto, n.referencia_id
    from public.notificacao n
   where n.usuario_id = (select usr from eu)
     and n.tipo in ('vaga', 'vagas_agrupadas')
   order by n.enviada_em, n.tipo;
$$;

create function pg_temp.esperando() returns bigint
language sql as $$
  select count(*) from public.despacho d
    join public.vaga v on v.id = d.vaga_id and v.estado = 'publicada'
   where d.profissional_id = (select prof from eu) and d.notificacao_id is null;
$$;

-- ── 3. Critério 1: 4 vagas em 5 minutos viram duas notificações ──────────────
-- t0 = 05/10 12:00 UTC. Vagas para o dia seguinte: nenhuma é urgente.

-- A vaga também vai para os elegíveis do seed; aqui importa só o profissional do teto.
select pg_temp.publicar('2026-10-05 12:00:00+00', 'c3300000-0000-4000-8000-00000000a001', interval '1 day');

select ok(
  exists (select 1 from pg_locks
           where locktype = 'advisory' and pid = pg_backend_pid() and granted),
  'a decisão do teto tomou a trava por profissional (pg_advisory_xact_lock)');

select pg_temp.publicar('2026-10-05 12:01:00+00', 'c3300000-0000-4000-8000-00000000a002', interval '1 day');
select pg_temp.publicar('2026-10-05 12:03:00+00', 'c3300000-0000-4000-8000-00000000a003', interval '1 day');
select pg_temp.publicar('2026-10-05 12:05:00+00', 'c3300000-0000-4000-8000-00000000a004', interval '1 day');

select results_eq(
  $$ select tipo, enviada_em, urgente, esperou from pg_temp.minhas() $$,
  $$ values ('vaga'::text, '2026-10-05 12:00:00+00'::timestamptz, false, false) $$,
  'critério 1: a primeira vaga sai na hora, sozinha, sem ter esperado');

select is(pg_temp.esperando(), 3::bigint,
  'critério 1: as outras três esperam o teto, com despacho e sem notificação');

select is(
  (select d.notificacao_id is not null from public.despacho d
    where d.vaga_id = 'c3300000-0000-4000-8000-00000000a001'
      and d.profissional_id = (select prof from eu)),
  true, 'o despacho da vaga que saiu aponta para a notificação');

select is(pg_temp.liberar('2026-10-05 12:29:00+00'), 0,
  'um minuto antes do fim da janela, nada é liberado');
select is((select count(*) from pg_temp.minhas()), 1::bigint,
  'dentro da janela continua uma notificação só');

select is(pg_temp.liberar('2026-10-05 12:30:00+00'), 1,
  'no fim da janela, o profissional que esperava é liberado');

select results_eq(
  $$ select tipo, enviada_em, urgente, esperou from pg_temp.minhas() $$,
  $$ values ('vaga'::text, '2026-10-05 12:00:00+00'::timestamptz, false, false),
            ('vagas_agrupadas'::text, '2026-10-05 12:30:00+00'::timestamptz, false, true) $$,
  'critério 1: duas notificações — a primeira na hora e as outras três juntas no fim da janela');

select is(pg_temp.esperando(), 0::bigint, 'nenhum despacho continua esperando');

select is(
  (select count(*) from public.despacho d
     join public.notificacao n on n.id = d.notificacao_id
    where d.profissional_id = (select prof from eu) and n.tipo = 'vagas_agrupadas'),
  3::bigint, 'a notificação agrupada tem três despachos apontando para ela');

select is(
  (select privado.contexto_do_push(n.id) from public.notificacao n
    where n.usuario_id = (select usr from eu) and n.tipo = 'vagas_agrupadas'),
  '{"quantidade": 3}'::jsonb,
  'o envio lê a contagem para o texto "3 vagas novas perto de você"');

select is(
  (select n.payload from public.notificacao n
    where n.usuario_id = (select usr from eu) and n.tipo = 'vagas_agrupadas'),
  '{"tipo": "vagas_agrupadas"}'::jsonb,
  'o toque da agrupada abre a aba de vagas: payload só com o tipo (RN15)');

select is(
  (select n.referencia_id from public.notificacao n
    where n.usuario_id = (select usr from eu) and n.tipo = 'vagas_agrupadas'),
  (select v.id from public.vaga v
    where v.id in ('c3300000-0000-4000-8000-00000000a002', 'c3300000-0000-4000-8000-00000000a003',
                   'c3300000-0000-4000-8000-00000000a004')
    order by v.inicio_em desc limit 1),
  'a agrupada referencia a vaga que começa por último: só expira quando todas começaram');

select is(pg_temp.liberar('2026-10-05 12:31:00+00'), 0,
  'rodar o agendador de novo não gera segunda notificação (idempotente)');
select is((select count(*) from pg_temp.minhas()), 2::bigint,
  'continuam duas notificações');

-- O despacho que esperou ganhou a notificação uma vez; depois disso, não muda (RNF13).
select throws_ok(
  $$ update public.despacho d set notificacao_id = (
       select n.id from public.notificacao n
        where n.usuario_id = (select usr from eu) and n.tipo = 'vaga' limit 1)
      where d.vaga_id = 'c3300000-0000-4000-8000-00000000a002'
        and d.profissional_id = (select prof from eu) $$,
  '23001', null,
  'RNF13: o despacho com notificação não é repontado para outra');

select throws_ok(
  $$ update public.despacho d set reaberta = true
      where d.vaga_id = 'c3300000-0000-4000-8000-00000000a002'
        and d.profissional_id = (select prof from eu) $$,
  '23001', null,
  'RNF13: fora o notificacao_id, o despacho continua sem se reescrever');

-- ── 4. Critério 2: a urgente sai na hora dentro da janela ─────────────────────
-- A agrupada saiu às 12:30; a janela vai até 13:00.

select pg_temp.publicar('2026-10-05 12:35:00+00', 'c3300000-0000-4000-8000-00000000a005', interval '1 day');
select is(pg_temp.esperando(), 1::bigint, 'a vaga comum dentro da janela espera');

select pg_temp.publicar('2026-10-05 12:40:00+00', 'c3300000-0000-4000-8000-00000000a006', interval '90 minutes');

select results_eq(
  $$ select tipo, enviada_em, urgente, esperou from pg_temp.minhas() where enviada_em > '2026-10-05 12:30:00+00' $$,
  $$ values ('vaga'::text, '2026-10-05 12:40:00+00'::timestamptz, true, false) $$,
  'critério 2: a vaga que começa em menos de 2 h sai na hora, sozinha, marcada urgente');

select is(
  (select n.referencia_id from public.notificacao n
    where n.usuario_id = (select usr from eu) and n.urgente),
  'c3300000-0000-4000-8000-00000000a006'::uuid,
  'a urgente fura o agrupamento: não leva a vaga comum que esperava');
select is(pg_temp.esperando(), 1::bigint, 'a vaga comum continua esperando');

-- ── 5. Critério 3: depois da urgente, a próxima comum espera 30 min ───────────

select is(pg_temp.liberar('2026-10-05 13:00:00+00'), 0,
  'critério 3: 30 min depois da agrupada, mas só 20 depois da urgente, a comum ainda espera');
select is(pg_temp.liberar('2026-10-05 13:09:00+00'), 0,
  'critério 3: um minuto antes de a janela da urgente fechar, ainda espera');
select is(pg_temp.liberar('2026-10-05 13:10:00+00'), 1,
  'critério 3: 30 min depois da urgente, a comum sai');

select results_eq(
  $$ select tipo, enviada_em, urgente, esperou, ref from pg_temp.minhas() where enviada_em > '2026-10-05 12:40:00+00' $$,
  $$ values ('vaga'::text, '2026-10-05 13:10:00+00'::timestamptz, false, true,
             'c3300000-0000-4000-8000-00000000a005'::uuid) $$,
  'uma vaga só que esperou sai como vaga, e não como agrupada de uma');

select is(
  (select n.payload from public.notificacao n
    where n.usuario_id = (select usr from eu) and n.referencia_id = 'c3300000-0000-4000-8000-00000000a005'),
  '{"tipo": "vaga", "vaga_id": "c3300000-0000-4000-8000-00000000a005"}'::jsonb,
  'a vaga que esperou leva o destino do toque para o detalhe da vaga');

-- ── 6. Critério 4: lembrete e aviso de turno não contam no teto ───────────────

select set_config('frila.agora', '2026-10-05 13:45:00+00', true);
select privado.notificar((select usr from eu), 'lembrete_3h',
                         'c3300000-0000-4000-8000-00000000f001',
                         '{"turno_id": "c3300000-0000-4000-8000-00000000f001"}');
select privado.notificar((select usr from eu), 'confirmacao',
                         'c3300000-0000-4000-8000-00000000f002',
                         '{"turno_id": "c3300000-0000-4000-8000-00000000f002"}');

select pg_temp.publicar('2026-10-05 13:46:00+00', 'c3300000-0000-4000-8000-00000000a007', interval '1 day');
select is(pg_temp.esperando(), 0::bigint,
  'critério 4: lembrete e confirmação um minuto antes não seguram a vaga');
select is(
  (select count(*) from pg_temp.minhas() where enviada_em = '2026-10-05 13:46:00+00'),
  1::bigint, 'critério 4: a vaga saiu na hora');

select set_config('frila.agora', '2026-10-05 13:47:00+00', true);
select privado.notificar((select usr from eu), 'lembrete_24h',
                         'c3300000-0000-4000-8000-00000000f003',
                         '{"turno_id": "c3300000-0000-4000-8000-00000000f003"}');
select is(
  (select n.estado_entrega::text || '/' || n.esperou_teto::text from public.notificacao n
    where n.usuario_id = (select usr from eu) and n.tipo = 'lembrete_24h'),
  'pendente/false',
  'critério 4: o lembrete logo depois de uma vaga não espera o teto');

-- ── 7. Critério 3, a regra inteira: fora a urgente, nunca duas em 30 min ──────

select is(
  (select count(*) from public.notificacao a
     join public.notificacao b
       on b.usuario_id = a.usuario_id and b.id <> a.id
      and b.enviada_em > a.enviada_em
      and b.enviada_em < a.enviada_em + interval '30 minutes'
    where a.usuario_id = (select usr from eu)
      and a.tipo in ('vaga', 'vagas_agrupadas') and b.tipo in ('vaga', 'vagas_agrupadas')
      and not b.urgente),
  0::bigint,
  'critério 3: nenhuma notificação de vaga não urgente saiu menos de 30 min depois de outra');

-- ── 8. O que esperava e deixou de valer não é notificado ─────────────────────

select pg_temp.publicar('2026-10-05 13:50:00+00', 'c3300000-0000-4000-8000-00000000a008', interval '1 day');
select pg_temp.publicar('2026-10-05 13:51:00+00', 'c3300000-0000-4000-8000-00000000a009', interval '1 day', 'reabertura');
select is(pg_temp.esperando(), 2::bigint, 'duas vagas esperam o teto');

update public.vaga set estado = 'cancelada' where id = 'c3300000-0000-4000-8000-00000000a008';

select is(pg_temp.liberar('2026-10-05 14:16:00+00'), 1, 'no fim da janela, libera');
select results_eq(
  $$ select tipo, ref from pg_temp.minhas() where enviada_em = '2026-10-05 14:16:00+00' $$,
  $$ values ('vaga'::text, 'c3300000-0000-4000-8000-00000000a009'::uuid) $$,
  'a vaga cancelada enquanto esperava não é notificada; a que sobrou sai sozinha');
select is(
  (select n.payload from public.notificacao n
    where n.usuario_id = (select usr from eu) and n.referencia_id = 'c3300000-0000-4000-8000-00000000a009'),
  '{"tipo": "vaga", "vaga_id": "c3300000-0000-4000-8000-00000000a009", "reaberta": true}'::jsonb,
  'a vaga reaberta que esperou continua dizendo que é reaberta');

-- ── 9. Os parâmetros vêm da configuração, não do código ───────────────────────

update privado.parametro_notificacao set valor = interval '10 minutes' where chave = 'teto_janela';
select pg_temp.publicar('2026-10-05 14:20:00+00', 'c3300000-0000-4000-8000-00000000a010', interval '1 day');
select is(pg_temp.esperando(), 1::bigint, 'com janela de 10 min, 4 min depois ainda espera');
select is(pg_temp.liberar('2026-10-05 14:26:00+00'), 1,
  'com janela de 10 min configurada, a vaga sai 10 min depois da anterior');

update privado.parametro_notificacao set valor = interval '3 hours' where chave = 'urgente_antecedencia';
select pg_temp.publicar('2026-10-05 14:27:00+00', 'c3300000-0000-4000-8000-00000000a011', interval '150 minutes');
select is(
  (select n.urgente from public.notificacao n
    where n.usuario_id = (select usr from eu) and n.referencia_id = 'c3300000-0000-4000-8000-00000000a011'),
  true, 'com antecedência de urgência de 3 h configurada, a vaga a 2h30 fura o teto');

select * from finish();
rollback;
