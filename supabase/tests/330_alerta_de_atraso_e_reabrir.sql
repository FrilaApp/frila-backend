-- Alerta de atraso aos 15 minutos e `reabrir_por_atraso` (cartão e8XpOZJN).
--
-- O eixo do arquivo é o relógio do produto andando pelo início de um turno sem check-in:
--
--   início − 1 min        nada sai
--   início + 1 min        o profissional recebe `inicio_sem_checkin`; reabrir é 422
--   início + 15 min       a casa recebe `atraso_15min`; reabrir passa a valer
--   reabrir               falta na taxa, posição nova marcada, vaga publicada, despacho
--   fim − 1 h             a posição reaberta que ninguém pegou é cancelada pelo agendador
--
-- E a 0.2.19 do contrato: a posição reaberta por atraso aceita candidatura depois do
-- início, até fim − 1 h; a exceção é da posição, e não da vaga.
--
-- Cada alerta sai uma vez por turno: o agendador roda a cada minuto e a marca de envio
-- (tipo, referência, conta) é o que impede o segundo push.
--
-- Ids próprios, começando em `e8a00000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(56);

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

-- d1 é a casa do turno; d2 é contratante de outra casa. e1 falta, e2 chega, e3 é o
-- terceiro turno (reaberto tarde demais para alguém chegar).
select pg_temp.autenticar('e8a00000-0000-4000-8000-0000000000d1','d1@atraso.test');
select pg_temp.autenticar('e8a00000-0000-4000-8000-0000000000d2','d2@atraso.test');
select pg_temp.autenticar('e8a00000-0000-4000-8000-0000000000e1','e1@atraso.test');
select pg_temp.autenticar('e8a00000-0000-4000-8000-0000000000e2','e2@atraso.test');
select pg_temp.autenticar('e8a00000-0000-4000-8000-0000000000e3','e3@atraso.test');

select pg_temp.como('e8a00000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Casa do Atraso','+5561944440001','1980-01-01','2026-09-22') $$);
select pg_temp.como('e8a00000-0000-4000-8000-0000000000d2',
  $$ select public.criar_conta('contratante','Outra Casa','+5561944440002','1980-01-01','2026-09-22') $$);
select pg_temp.como('e8a00000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Não Chegou','+5561944440011','1995-01-01','2026-09-22') $$);
select pg_temp.como('e8a00000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Chegou Cedo','+5561944440012','1995-01-01','2026-09-22') $$);
select pg_temp.como('e8a00000-0000-4000-8000-0000000000e3',
  $$ select public.criar_conta('profissional','Terceiro Turno','+5561944440013','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));
end $corpo$;

select pg_temp.perfil('e8a00000-0000-4000-8000-0000000000e1');
select pg_temp.perfil('e8a00000-0000-4000-8000-0000000000e2');
select pg_temp.perfil('e8a00000-0000-4000-8000-0000000000e3');

create temp table casa as
  select (pg_temp.como('e8a00000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa do Atraso','04252011000110','food_service',
         'SCLN 407','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

select pg_temp.como('e8a00000-0000-4000-8000-0000000000d2',
  $$ select public.cadastrar_estabelecimento('Outra Casa','11222333000181','food_service',
       'SCLN 408','{"latitude":-15.7920,"longitude":-47.8870}') $$);

-- Três vagas em dias diferentes, de seis horas cada.
create function pg_temp.publicar(chave uuid, dias int, posicoes int default 1) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('e8a00000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 407',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, %s, true, true, false, 'Seu Zé', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn),
    privado.agora() + (dias || ' days')::interval,
    privado.agora() + (dias || ' days 6 hours')::interval, posicoes, chave))->>'vaga_id')::uuid;
end $corpo$;

create temp table v as
  select pg_temp.publicar('e8a00000-0000-4000-8000-000000000001', 2) as falta,
         pg_temp.publicar('e8a00000-0000-4000-8000-000000000002', 3) as chegou,
         pg_temp.publicar('e8a00000-0000-4000-8000-000000000003', 4) as tarde,
         pg_temp.publicar('e8a00000-0000-4000-8000-000000000004', 5, 2) as dupla;

create temp table c as
  select pg_temp.como('e8a00000-0000-4000-8000-0000000000e1',
           format($$ select public.candidatar(%L) $$, (select falta from v))) as falta,
         pg_temp.como('e8a00000-0000-4000-8000-0000000000e2',
           format($$ select public.candidatar(%L) $$, (select chegou from v))) as chegou,
         pg_temp.como('e8a00000-0000-4000-8000-0000000000e3',
           format($$ select public.candidatar(%L) $$, (select tarde from v))) as tarde,
         pg_temp.como('e8a00000-0000-4000-8000-0000000000e2',
           format($$ select public.candidatar(%L) $$, (select dupla from v))) as dupla;

create temp table p as
  select (falta->>'posicao_id')::uuid  as falta,  (falta->>'turno_id')::uuid  as turno_falta,
         (chegou->>'posicao_id')::uuid as chegou, (chegou->>'turno_id')::uuid as turno_chegou,
         (tarde->>'posicao_id')::uuid  as tarde,
         (dupla->>'posicao_id')::uuid  as dupla
    from c;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

create function pg_temp.relogio(posicao uuid, desloc interval, pelo_fim boolean default false)
returns void language plpgsql as $$
begin
  perform set_config('frila.agora',
    (select ((case when pelo_fim then x.fim_em else x.inicio_em end) + desloc)::text
       from public.posicao x where x.id = posicao), true);
end $$;

create function pg_temp.avisos(tipo text, conta uuid, turno uuid) returns int
language sql as $$
  select count(*)::int from public.notificacao n
   where n.tipo::text = tipo and n.usuario_id = conta and n.referencia_id = turno
$$;

create function pg_temp.na_lista(conta uuid, vaga uuid) returns jsonb
language sql as $$
  select (select x from jsonb_array_elements(
            pg_temp.como(conta, $x$ select public.vagas_abertas(-15.7900, -47.8850) $x$)) x
           where (x->>'id')::uuid = vaga)
$$;

create function pg_temp.detalhe(conta uuid, vaga uuid) returns jsonb
language sql as $$
  select pg_temp.como(conta, format($x$ select public.detalhe_vaga(%L) $x$, vaga))
$$;

create function pg_temp.reabrir(conta uuid, posicao uuid) returns jsonb
language sql as $$
  select pg_temp.como(conta, format($x$ select public.reabrir_por_atraso(%L) $x$, posicao))
$$;

-- ── Antes do início, nada sai ─────────────────────────────────────────────────
select pg_temp.relogio((select falta from p), interval '-1 minute');
select privado.alertar_atrasos();

select is(
  pg_temp.avisos('inicio_sem_checkin', 'e8a00000-0000-4000-8000-0000000000e1',
                 (select turno_falta from p)),
  0, 'um minuto antes do início, o profissional não recebe aviso');

-- ── No início, o lembrete ao profissional ─────────────────────────────────────
select pg_temp.relogio((select falta from p), interval '1 minute');
select privado.alertar_atrasos();

select is(
  pg_temp.avisos('inicio_sem_checkin', 'e8a00000-0000-4000-8000-0000000000e1',
                 (select turno_falta from p)),
  1, 'RF13: no início sem check-in, o profissional recebe inicio_sem_checkin');

select is(
  (select n.payload from public.notificacao n
    where n.tipo = 'inicio_sem_checkin' and n.referencia_id = (select turno_falta from p)),
  jsonb_build_object('turno_id', (select turno_falta from p), 'tipo', 'inicio_sem_checkin'),
  'RN15: o payload do lembrete é só o turno');

select is(
  pg_temp.avisos('atraso_15min', 'e8a00000-0000-4000-8000-0000000000d1',
                 (select turno_falta from p)),
  0, 'um minuto depois do início, a casa ainda não é alertada');

select is(
  privado.notificacao_expirada((select n.id from public.notificacao n
    where n.tipo = 'inicio_sem_checkin' and n.referencia_id = (select turno_falta from p))),
  false, 'o lembrete de início não expira porque o turno começou: é depois do início que ele serve');

select throws_ok(
  format($$ select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d1', %L) $$,
         (select falta from p)),
  'PGRST',
  '{"code" : "reabertura_antes_da_tolerancia", "message" : "reabertura_antes_da_tolerancia", "details" : null, "hint" : null}',
  'D06: reabrir antes dos 15 minutos é 422 reabertura_antes_da_tolerancia');

select pg_temp.relogio((select falta from p), interval '14 minutes 59 seconds');

select throws_ok(
  format($$ select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d1', %L) $$,
         (select falta from p)),
  'PGRST',
  '{"code" : "reabertura_antes_da_tolerancia", "message" : "reabertura_antes_da_tolerancia", "details" : null, "hint" : null}',
  'D06: um segundo antes dos 15 minutos continua 422');

-- ── Aos 15 minutos, o alerta à casa ───────────────────────────────────────────
select pg_temp.relogio((select falta from p), interval '15 minutes');
select privado.alertar_atrasos();
select privado.alertar_atrasos();

select is(
  pg_temp.avisos('atraso_15min', 'e8a00000-0000-4000-8000-0000000000d1',
                 (select turno_falta from p)),
  1, 'aos 15 minutos sem check-in, cada membro da casa recebe atraso_15min — uma vez só');

select is(
  pg_temp.avisos('inicio_sem_checkin', 'e8a00000-0000-4000-8000-0000000000e1',
                 (select turno_falta from p)),
  1, 'o agendador rodando de novo não repete o lembrete do profissional');

select is(
  (select n.payload from public.notificacao n
    where n.tipo = 'atraso_15min' and n.referencia_id = (select turno_falta from p)),
  jsonb_build_object('turno_id', (select turno_falta from p),
                     'posicao_id', (select falta from p), 'tipo', 'atraso_15min'),
  'RN15: o payload do alerta é o turno e a posição que o botão de reabrir usa');

select is(
  pg_temp.avisos('atraso_15min', 'e8a00000-0000-4000-8000-0000000000e1',
                 (select turno_falta from p)),
  0, 'o alerta de atraso vai à casa, e não ao profissional');

select is(
  privado.notificacao_expirada((select n.id from public.notificacao n
    where n.tipo = 'atraso_15min' and n.referencia_id = (select turno_falta from p))),
  false, 'o alerta de atraso não expira enquanto a posição espera a decisão da casa');

-- ── As recusas ────────────────────────────────────────────────────────────────
select throws_ok(
  format($$ select public.reabrir_por_atraso(%L) $$, (select falta from p)),
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'sem token não se reabre');

select throws_ok(
  $$ select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d1', null) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "posicao_id", "hint" : null}',
  'posicao_id ausente é 422 campo_obrigatorio');

select throws_ok(
  format($$ select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000e3', %L) $$,
         (select falta from p)),
  'PGRST',
  '{"code" : "perfil_incompativel", "message" : "perfil_incompativel", "details" : null, "hint" : null}',
  'profissional não reabre: a decisão é da casa');

select throws_ok(
  format($$ select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d2', %L) $$,
         (select falta from p)),
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'contratante de outra casa recebe 403 sem_permissao');

select throws_ok(
  $$ select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d1',
                            'e8a00000-0000-4000-8000-00000000ffff') $$,
  'PGRST',
  '{"code" : "sem_permissao", "message" : "sem_permissao", "details" : null, "hint" : null}',
  'posição que não existe recebe o mesmo 403 de posição alheia');

-- ── Com check-in feito, 409 ───────────────────────────────────────────────────
select pg_temp.relogio((select chegou from p), interval '5 minutes');
select pg_temp.como('e8a00000-0000-4000-8000-0000000000e2',
  format($$ select public.fazer_checkin(%L, 50, %L) $$,
         (select turno_chegou from p), privado.agora()));

select pg_temp.relogio((select chegou from p), interval '20 minutes');
select privado.alertar_atrasos();

select is(
  pg_temp.avisos('atraso_15min', 'e8a00000-0000-4000-8000-0000000000d1',
                 (select turno_chegou from p)),
  0, 'turno com check-in não gera alerta de atraso');

select throws_ok(
  format($$ select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d1', %L) $$,
         (select chegou from p)),
  'PGRST',
  '{"code" : "posicao_nao_cancelavel", "message" : "posicao_nao_cancelavel", "details" : "checkin_registrado", "hint" : null}',
  'D06: com check-in feito, reabrir é 409');

-- ── Reabrir ───────────────────────────────────────────────────────────────────
select pg_temp.relogio((select falta from p), interval '20 minutes');

create temp table r as
  select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d1', (select falta from p)) as j;

select is(
  (select array_agg(k order by k) from r, jsonb_object_keys((select j from r)) k),
  array['falta','nova_posicao_id','posicao_id','reaberta'],
  'a resposta traz exatamente os campos do schema ResultadoCancelamento');

select is((select (j->>'falta')::boolean from r), true,
  'RN12: reabrir por atraso conta como falta');

select is((select (j->>'reaberta')::boolean from r), true,
  'e a vaga é reaberta');

select is(
  (select row(x.estado::text, x.falta) from public.posicao x where x.id = (select falta from p)),
  row('cancelada'::text, true),
  'a posição de quem não veio fica cancelada, com a falta');

select is(
  (select x.taxa_comparecimento from public.profissional x
    where x.usuario_id = 'e8a00000-0000-4000-8000-0000000000e1'),
  0.000::numeric,
  'RN12: a falta entra na taxa de comparecimento na hora');

select is(
  (select t.verificacao::text from public.turno t where t.id = (select turno_falta from p)),
  'nao_verificado',
  'o turno de quem não veio sai como não verificado');

select is(
  (select row(x.estado::text, x.profissional_id, x.reaberta_por_atraso_de)
     from public.posicao x where x.id = (select (j->>'nova_posicao_id')::uuid from r)),
  row('aberta'::text, null::uuid, (select falta from p)),
  'a posição nova nasce aberta, marcada como reaberta por atraso da anterior');

select is(
  (select g.estado::text from public.vaga g where g.id = (select falta from v)),
  'publicada',
  'a vaga volta a publicada');

select is(
  (select count(*)::int from pgmq.q_despacho
    where (message->>'posicao_id')::uuid = (select (j->>'nova_posicao_id')::uuid from r)
      and message->>'motivo' = 'reabertura'
      and (message->>'excluir_conta')::uuid = 'e8a00000-0000-4000-8000-0000000000e1'),
  1,
  'a reabertura gera novo despacho, sem notificar quem faltou');

select is(
  (select n.payload from public.notificacao n
    where n.tipo = 'cancelamento' and n.referencia_id = (select falta from p)
      and n.usuario_id = 'e8a00000-0000-4000-8000-0000000000e1'),
  jsonb_build_object('posicao_id', (select falta from p), 'vaga_id', (select falta from v),
                     'reaberta', true, 'tipo', 'cancelamento'),
  'o profissional é avisado de que a vaga foi reaberta');

select is(
  (select count(*)::int from public.notificacao n
    where n.tipo = 'cancelamento' and n.referencia_id = (select falta from p)
      and n.usuario_id = 'e8a00000-0000-4000-8000-0000000000d1'),
  0,
  'a casa, que decidiu, não recebe aviso da própria decisão');

select is(
  privado.notificacao_expirada((select n.id from public.notificacao n
    where n.tipo = 'cancelamento' and n.referencia_id = (select falta from p))),
  false,
  'o aviso de reabertura sai mesmo com o turno já começado');

select is(
  privado.notificacao_expirada((select n.id from public.notificacao n
    where n.tipo = 'atraso_15min' and n.referencia_id = (select turno_falta from p))),
  true,
  'o alerta de atraso ainda não enviado expira quando a casa já decidiu');

select is(
  (select o.motivo from public.ocorrencia o
    where o.posicao_id = (select falta from p) and o.tipo = 'cancelamento'),
  'reabertura_por_atraso',
  'RN12: a reabertura fica registrada em ocorrencia, com motivo estável');

-- Reenvio: a rede cai depois do commit e o app toca de novo.
select is(
  pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d1', (select falta from p)),
  (select j from r),
  'reenviar devolve o mesmo resultado, sem segunda posição');

select is(
  (select count(*)::int from public.posicao x where x.vaga_id = (select falta from v)),
  2,
  'e a vaga continua com duas posições: a cancelada e a reaberta');

-- O check-in que chega depois da decisão não ressuscita a posição cancelada.
select throws_ok(
  format($$ select pg_temp.como('e8a00000-0000-4000-8000-0000000000e1',
       $x$ select public.fazer_checkin(%L, 50, %L) $x$) $$,
         (select turno_falta from p), privado.agora()),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : "posicao_cancelada", "hint" : null}',
  'check-in depois da reabertura é 409: a posição não é mais dele');

-- ── 0.2.19: a vitrine mostra a posição reaberta ───────────────────────────────
select is(
  (pg_temp.na_lista('e8a00000-0000-4000-8000-0000000000e3', (select falta from v))
     ->>'posicoes_abertas')::int,
  1,
  '0.2.19: vaga começada com posição reaberta por atraso continua na lista, com 1 posição');

select is(
  (select row(d->>'estado', (d->>'posicoes_abertas')::int)
     from pg_temp.detalhe('e8a00000-0000-4000-8000-0000000000e3', (select falta from v)) d),
  row('publicada'::text, 1),
  '0.2.19: e o detalhe conta a posição reaberta');

-- ── Fim − 1 h: a posição reaberta que ninguém pegou fecha ─────────────────────
select pg_temp.relogio((select falta from p), interval '-61 minutes', true);
select privado.alertar_atrasos();

select is(
  (select x.estado::text from public.posicao x
    where x.id = (select (j->>'nova_posicao_id')::uuid from r)),
  'aberta',
  '61 minutos antes do fim, a posição reaberta ainda espera candidato');

select pg_temp.relogio((select falta from p), interval '-60 minutes', true);

select throws_ok(
  format($$ select pg_temp.como('e8a00000-0000-4000-8000-0000000000e3',
       $x$ select public.candidatar(%L) $x$) $$, (select falta from v)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : null, "hint" : null}',
  '0.2.19: a partir de fim − 1 h a posição reaberta recusa candidatura');

select is(
  (select row(d->>'estado', (d->>'posicoes_abertas')::int)
     from pg_temp.detalhe('e8a00000-0000-4000-8000-0000000000e3', (select falta from v)) d),
  row('publicada'::text, 0),
  '0.2.19: o detalhe continua respondendo, com o estado real e 0 posições');

select privado.alertar_atrasos();

select is(
  (select row(x.estado::text, x.falta) from public.posicao x
    where x.id = (select (j->>'nova_posicao_id')::uuid from r)),
  row('cancelada'::text, false),
  '8zLfn0mt item 5: a 1 h do fim, o agendador cancela a posição reaberta, sem falta para ninguém');

select is(
  (select count(*)::int from public.posicao x
    where x.vaga_id = (select falta from v) and x.estado = 'aberta'),
  0,
  'e a vaga fica sem posição aberta');

-- ── Tarde demais para reabrir: cancela com falta, sem posição nova ────────────
select pg_temp.relogio((select tarde from p), interval '-30 minutes', true);

create temp table rt as
  select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d1', (select tarde from p)) as j;

select is(
  (select j from rt),
  jsonb_build_object('posicao_id', (select tarde from p), 'falta', true,
                     'reaberta', false, 'nova_posicao_id', null),
  'a menos de 1 h do fim ninguém chega: a falta é marcada e a vaga não é reaberta');

select is(
  (select count(*)::int from pgmq.q_despacho
    where (message->>'vaga_id')::uuid = (select tarde from v)
      and message->>'motivo' = 'reabertura'),
  0,
  'e nenhum despacho sai para um turno que não aceita mais candidato');

select is(
  (select n.payload->'reaberta' from public.notificacao n
    where n.tipo = 'cancelamento' and n.referencia_id = (select tarde from p)),
  'false'::jsonb,
  'o profissional é avisado com reaberta = false');

-- ── 0.2.19: a exceção é da posição, e não da vaga ─────────────────────────────
--
-- A vaga dupla tem duas posições: e2 confirmou uma, a outra ficou aberta sem ninguém.
-- Depois do início, a original aberta não é oferecida; só a reaberta por atraso.
select pg_temp.relogio((select dupla from p), interval '20 minutes');

select is(
  pg_temp.na_lista('e8a00000-0000-4000-8000-0000000000e3', (select dupla from v)),
  null::jsonb,
  '0.2.19: vaga que já começou sai da lista, mesmo com posição original aberta');

select is(
  (select row(d->>'estado', (d->>'posicoes_abertas')::int)
     from pg_temp.detalhe('e8a00000-0000-4000-8000-0000000000e3', (select dupla from v)) d),
  row('publicada'::text, 0),
  '0.2.19: o detalhe da vaga começada responde 200, publicada e sem posição a pegar');

select throws_ok(
  format($$ select pg_temp.como('e8a00000-0000-4000-8000-0000000000e3',
       $x$ select public.candidatar(%L) $x$) $$, (select dupla from v)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : null, "hint" : null}',
  '0.2.19: vaga começada sem posição reaberta recusa a candidatura, mesmo com posição original aberta');

select throws_ok(
  $$ select pg_temp.como('e8a00000-0000-4000-8000-0000000000e3',
       $x$ select public.candidatar('e8a00000-0000-4000-8000-00000000ffff') $x$) $$,
  'PGRST',
  '{"code" : "nao_encontrado", "message" : "nao_encontrado", "details" : null, "hint" : null}',
  'vaga que não existe é 404');

create temp table rd as
  select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d1', (select dupla from p)) as j;

select pg_temp.relogio((select dupla from p), interval '21 minutes');

create temp table cd as
  select pg_temp.como('e8a00000-0000-4000-8000-0000000000e3',
    format($$ select public.candidatar(%L) $$, (select dupla from v))) as j;

select is(
  (select (j->>'posicao_id')::uuid from cd),
  (select (j->>'nova_posicao_id')::uuid from rd),
  '0.2.19: depois do início, o servidor escolhe a posição reaberta, nunca a original aberta');

-- O substituto tem os mesmos 15 minutos, contados da confirmação.
select pg_temp.relogio((select dupla from p), interval '30 minutes');
select privado.alertar_atrasos();

select throws_ok(
  format($$ select pg_temp.reabrir('e8a00000-0000-4000-8000-0000000000d1', %L) $$,
         (select j->>'posicao_id' from cd)),
  'PGRST',
  '{"code" : "reabertura_antes_da_tolerancia", "message" : "reabertura_antes_da_tolerancia", "details" : null, "hint" : null}',
  'D06: o substituto ganha 15 minutos contados da confirmação');

select is(
  pg_temp.avisos('atraso_15min', 'e8a00000-0000-4000-8000-0000000000d1',
                 (select (j->>'turno_id')::uuid from cd)),
  0, 'nem a casa é alertada antes de 15 minutos da confirmação do substituto');

select is(
  pg_temp.avisos('inicio_sem_checkin', 'e8a00000-0000-4000-8000-0000000000e3',
                 (select (j->>'turno_id')::uuid from cd)),
  0, 'o substituto não recebe lembrete de início colado na própria confirmação');

select pg_temp.relogio((select dupla from p), interval '36 minutes');
select privado.alertar_atrasos();

select is(
  pg_temp.avisos('atraso_15min', 'e8a00000-0000-4000-8000-0000000000d1',
                 (select (j->>'turno_id')::uuid from cd)),
  1, 'aos 15 minutos da confirmação sem check-in, a casa é alertada');

select throws_ok(
  format($$ select pg_temp.como('e8a00000-0000-4000-8000-0000000000e1',
       $x$ select public.candidatar(%L) $x$) $$, (select dupla from v)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : null, "hint" : null}',
  '0.2.19: preenchida a reaberta, a original aberta continua fora de alcance');

select * from finish();
rollback;
