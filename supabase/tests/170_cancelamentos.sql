-- `cancelar_posicao` e `cancelar_vaga`: desistir sem virar castigo.
--
-- O eixo do arquivo é a diferença entre 30 horas e 10 horas de antecedência — a mesma
-- ação, o mesmo motivo, e dois desfechos diferentes na taxa de comparecimento (RN12).
--
--   profissional, 30 h antes   sai da taxa: imprevisto com aviso não é falta
--   profissional, 10 h antes   conta como falta
--   contratante, qualquer hora não gera falta para ninguém
--   qualquer um               nunca muda o estado da conta (RN13)
--
-- Ids próprios, começando em `b0000000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(25);

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

select pg_temp.autenticar('b0000000-0000-4000-8000-0000000000d1','dona@cancel.test');
select pg_temp.autenticar('b0000000-0000-4000-8000-0000000000e1','e1@cancel.test');
select pg_temp.autenticar('b0000000-0000-4000-8000-0000000000e2','e2@cancel.test');
select pg_temp.autenticar('b0000000-0000-4000-8000-0000000000e3','e3@cancel.test');

select pg_temp.como('b0000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona do Cancelamento','+5561933330001','1980-01-01','2026-09-22') $$);
select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Cancela Cedo','+5561933330011','1995-01-01','2026-09-22') $$);
select pg_temp.como('b0000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Cancela Tarde','+5561933330012','1995-01-01','2026-09-22') $$);
select pg_temp.como('b0000000-0000-4000-8000-0000000000e3',
  $$ select public.criar_conta('profissional','De Fora','+5561933330013','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));
end $corpo$;

select pg_temp.perfil('b0000000-0000-4000-8000-0000000000e1');
select pg_temp.perfil('b0000000-0000-4000-8000-0000000000e2');
select pg_temp.perfil('b0000000-0000-4000-8000-0000000000e3');

create temp table casa as
  select (pg_temp.como('b0000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa do Cancelamento','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- Três vagas em dias diferentes: RN21 não deixa a mesma pessoa em dois turnos que se
-- cruzam, e duas delas são da mesma pessoa.
create function pg_temp.publicar(chave uuid, dias int, posicoes int default 1) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('b0000000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, %s, true, true, false, 'Seu Zé', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn),
    privado.agora() + (dias || ' days')::interval,
    privado.agora() + (dias || ' days 6 hours')::interval, posicoes, chave))->>'vaga_id')::uuid;
end $corpo$;

create temp table v as
  select pg_temp.publicar('b0000000-0000-4000-8000-000000000001', 5) as cedo,
         pg_temp.publicar('b0000000-0000-4000-8000-000000000002', 6) as tarde,
         pg_temp.publicar('b0000000-0000-4000-8000-000000000003', 7, 2) as da_casa;

create temp table p as
  select (pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
            format($$ select public.candidatar(%L) $$, (select cedo from v)))->>'posicao_id')::uuid as cedo,
         (pg_temp.como('b0000000-0000-4000-8000-0000000000e2',
            format($$ select public.candidatar(%L) $$, (select tarde from v)))->>'posicao_id')::uuid as tarde,
         (pg_temp.como('b0000000-0000-4000-8000-0000000000e3',
            format($$ select public.candidatar(%L) $$, (select da_casa from v)))->>'posicao_id')::uuid as da_casa;

-- ── As recusas ────────────────────────────────────────────────────────────────
select throws_ok(
  format($$ select public.cancelar_posicao(%L, 'qualquer coisa') $$, (select cedo from p)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não se cancela');

select throws_ok(
  format($$ select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
       $x$ select public.cancelar_posicao(%L, '  ') $x$) $$, (select cedo from p)),
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "motivo", "hint" : null}',
  'RN12: cancelar sem motivo é 422 — o motivo é o que a outra parte lê');

select throws_ok(
  format($$ select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
       $x$ select public.cancelar_posicao(%L, 'porque sim caralho') $x$) $$, (select cedo from p)),
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "motivo", "hint" : null}',
  'diretriz 1.2: o motivo passa pelo filtro de texto — ele vai para a tela da outra parte');

select throws_ok(
  format($$ select pg_temp.como('b0000000-0000-4000-8000-0000000000e3',
       $x$ select public.cancelar_posicao(%L, 'não vou poder') $x$) $$, (select cedo from p)),
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'quem não é de nenhum dos dois lados recebe 404');

-- ── 30 horas antes: sai da taxa ───────────────────────────────────────────────
--
-- O relógio do produto anda para 30 horas antes do início da primeira vaga. A mesma
-- ação, mais tarde, vira falta — e é só o relógio que muda.
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora',
  (select (p2.inicio_em - interval '30 hours')::text
     from public.posicao p2 where p2.id = (select cedo from p)), true);

create temp table r as
  select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
    format($$ select public.cancelar_posicao(%L, 'peguei um turno fixo') $$,
           (select cedo from p))) as j;

select is(
  (select array_agg(k order by k) from r, jsonb_object_keys((select j from r)) k),
  array['falta','nova_posicao_id','posicao_id','reaberta'],
  'a resposta traz exatamente os campos do schema ResultadoCancelamento');

select is((select (j->>'falta')::boolean from r), false,
  'RN12: cancelamento com 30 h de antecedência não conta como falta');

select is(
  (select p2.estado::text from public.posicao p2 where p2.id = (select cedo from p)),
  'cancelada',
  'a posição fica cancelada');

-- A posição cancelada guarda de quem ela era: é o que RN12 manda registrar, e o que a
-- taxa de comparecimento precisa ler depois.
select isnt(
  (select p2.profissional_id from public.posicao p2 where p2.id = (select cedo from p)),
  null,
  'e continua sabendo de quem era — a posição cancelada não perde o profissional');

select is((select (j->>'reaberta')::boolean from r), true,
  'antes do início, a vaga ganha posição nova');

select is(
  (select p2.estado::text from public.posicao p2
    where p2.id = (select (j->>'nova_posicao_id')::uuid from r)),
  'aberta',
  'e a posição nova nasce aberta, sem profissional');

select is(
  (select g.estado::text from public.vaga g where g.id = (select cedo from v)),
  'publicada',
  'a vaga volta a publicada: ela tem posição aberta de novo');

-- A reabertura enfileira o despacho, e a mensagem carrega quem **não** deve ser
-- notificado: receber a notificação da vaga que se acabou de largar é o tipo de detalhe
-- que faz desinstalar o app.
select is(
  (select count(*)::int from pgmq.q_despacho
    where (message->>'posicao_id')::uuid = (select (j->>'nova_posicao_id')::uuid from r)
      and message->>'motivo' = 'reabertura'
      and (message->>'excluir_conta')::uuid = 'b0000000-0000-4000-8000-0000000000e1'),
  1,
  'a reabertura enfileira o despacho, sem quem cancelou');

select is(
  (select count(*)::int from public.ocorrencia o
    where o.posicao_id = (select cedo from p) and o.tipo = 'cancelamento'),
  1,
  'RN12: o cancelamento fica registrado em ocorrencia, com o motivo');

select is(
  (select u.estado::text from public.usuario u
    where u.id = 'b0000000-0000-4000-8000-0000000000e1'),
  'ativa',
  'RN13: cancelar não muda o estado da conta');

select is(
  (select pr.taxa_comparecimento from public.profissional pr
    where pr.usuario_id = 'b0000000-0000-4000-8000-0000000000e1'),
  null,
  'e a taxa continua nula: cancelamento com aviso sai da conta, não entra como zero');

-- ── 10 horas antes: conta como falta ──────────────────────────────────────────
select set_config('frila.agora',
  (select (p2.inicio_em - interval '10 hours')::text
     from public.posicao p2 where p2.id = (select tarde from p)), true);

create temp table r2 as
  select pg_temp.como('b0000000-0000-4000-8000-0000000000e2',
    format($$ select public.cancelar_posicao(%L, 'não vou conseguir chegar') $$,
           (select tarde from p))) as j;

select is((select (j->>'falta')::boolean from r2), true,
  'RN12: cancelamento com 10 h de antecedência conta como falta');

select is(
  (select p2.falta from public.posicao p2 where p2.id = (select tarde from p)),
  true,
  'e a falta fica na posição cancelada, que é onde a taxa vai lê-la');

select is(
  (select pr.taxa_comparecimento from public.profissional pr
    where pr.usuario_id = 'b0000000-0000-4000-8000-0000000000e2'),
  0.000::numeric,
  'a taxa passa a existir, e é zero: uma falta em um turno considerado');

select is(
  (select u.estado::text from public.usuario u
    where u.id = 'b0000000-0000-4000-8000-0000000000e2'),
  'ativa',
  'RN13: nem a falta muda o estado da conta');

-- ── Depois do início não há reabertura ────────────────────────────────────────
select set_config('frila.agora',
  (select (p2.inicio_em + interval '1 hour')::text
     from public.posicao p2 where p2.id = (select da_casa from p)), true);

select is(
  pg_temp.como('b0000000-0000-4000-8000-0000000000d1',
    format($$ select public.cancelar_posicao(%L, 'a casa não vai abrir hoje') $$,
           (select da_casa from p)))->>'reaberta',
  'false',
  'depois do início não há reabertura: o turno ficou descoberto');

select is(
  (select p2.falta from public.posicao p2 where p2.id = (select da_casa from p)),
  false,
  'e cancelamento pelo contratante não gera falta para ninguém');

-- ── cancelar_vaga ─────────────────────────────────────────────────────────────
select set_config('frila.agora', '', true);

create temp table vc as
  select pg_temp.publicar('b0000000-0000-4000-8000-000000000004', 9, 3) as id;

select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
  format($$ select public.candidatar(%L) $$, (select id from vc)));

select throws_ok(
  format($$ select pg_temp.como('b0000000-0000-4000-8000-0000000000e1',
       $x$ select public.cancelar_vaga(%L, 'mudei de ideia') $x$) $$, (select id from vc)),
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'o profissional não cancela a vaga inteira: isso tiraria o turno de outras pessoas');

create temp table rv as
  select pg_temp.como('b0000000-0000-4000-8000-0000000000d1',
    format($$ select public.cancelar_vaga(%L, 'evento adiado') $$, (select id from vc))) as j;

select is((select j->>'posicoes_canceladas' from rv), '3',
  'cancelar_vaga cancela as três posições, abertas e confirmada');

select is(
  (select array_agg(k order by k) from rv, jsonb_object_keys((select j from rv)) k),
  array['estado','posicoes_canceladas','vaga_id'],
  'e a resposta traz exatamente os três campos que o contrato promete');

select is(
  (select count(*)::int from public.posicao p2
    where p2.vaga_id = (select id from vc) and p2.estado <> 'cancelada'),
  0,
  'e não sobra posição em nenhum outro estado');

select * from finish();
rollback;
