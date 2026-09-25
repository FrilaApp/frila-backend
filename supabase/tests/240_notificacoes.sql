-- Notificação para qualquer conta, marca de envio e payload do destino do toque.
--
-- A tabela `notificacao` só sabia falar com profissional. Metade dos avisos do produto
-- vai para a casa (confirmação, check-in, cancelamento), então o destinatário passou a
-- ser a conta, e o profissional só existe nas notificações de vaga — as que o teto da
-- RN23 conta.
--
-- Ids próprios, começando em `c1000000`.

begin;
select plan(42);

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

select pg_temp.autenticar('c1000000-0000-4000-8000-0000000000d1','dona@notif.test');
select pg_temp.autenticar('c1000000-0000-4000-8000-0000000000d2','socio@notif.test');
select pg_temp.autenticar('c1000000-0000-4000-8000-0000000000e1','e1@notif.test');
select pg_temp.autenticar('c1000000-0000-4000-8000-0000000000e2','e2@notif.test');
select pg_temp.autenticar('c1000000-0000-4000-8000-0000000000e3','e3@notif.test');
select pg_temp.autenticar('c1000000-0000-4000-8000-0000000000e4','e4@notif.test');
select pg_temp.autenticar('c1000000-0000-4000-8000-0000000000e5','e5@notif.test');

select pg_temp.como('c1000000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona da Notificacao','+5561944440001','1980-01-01','2026-09-22') $$);
select pg_temp.como('c1000000-0000-4000-8000-0000000000d2',
  $$ select public.criar_conta('contratante','Socio da Notificacao','+5561944440002','1980-01-01','2026-09-22') $$);
select pg_temp.como('c1000000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Prof Um Geo','+5561944440011','1995-01-01','2026-09-22') $$);
select pg_temp.como('c1000000-0000-4000-8000-0000000000e2',
  $$ select public.criar_conta('profissional','Prof Dois Manual','+5561944440012','1995-01-01','2026-09-22') $$);
select pg_temp.como('c1000000-0000-4000-8000-0000000000e3',
  $$ select public.criar_conta('profissional','Prof Tres Desiste','+5561944440013','1995-01-01','2026-09-22') $$);
select pg_temp.como('c1000000-0000-4000-8000-0000000000e4',
  $$ select public.criar_conta('profissional','Prof Quatro Cancelado','+5561944440014','1995-01-01','2026-09-22') $$);
select pg_temp.como('c1000000-0000-4000-8000-0000000000e5',
  $$ select public.criar_conta('profissional','Prof Cinco Vaga Cancelada','+5561944440015','1995-01-01','2026-09-22') $$);

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create function pg_temp.perfil(conta uuid) returns void
language plpgsql as $corpo$
begin
  perform pg_temp.como(conta, format(
    $sql$ select public.criar_perfil_profissional(array[%L]::uuid[],
            '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $sql$, (select garcom from fn)));
end $corpo$;

select pg_temp.perfil('c1000000-0000-4000-8000-0000000000e1');
select pg_temp.perfil('c1000000-0000-4000-8000-0000000000e2');
select pg_temp.perfil('c1000000-0000-4000-8000-0000000000e3');
select pg_temp.perfil('c1000000-0000-4000-8000-0000000000e4');
select pg_temp.perfil('c1000000-0000-4000-8000-0000000000e5');

create temp table casa as
  select (pg_temp.como('c1000000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa da Notificacao','04252011000110','food_service',
         'SCLN 406','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

-- Um segundo membro, para provar que o aviso vai para a casa e não só para quem
-- publicou. Não há RPC de convite ainda; a linha entra como o convite entrará.
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('c1000000-0000-4000-8000-0000000000d2', (select id from casa), 'operador');

create function pg_temp.publicar(chave uuid, dias int) returns uuid
language plpgsql as $corpo$
begin
  return (pg_temp.como('c1000000-0000-4000-8000-0000000000d1', format(
    $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 406',
         '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
         18000, 1, true, true, false, 'Seu Zé', 'urgencia', %L) $sql$,
    (select id from casa), (select garcom from fn),
    privado.agora() + (dias || ' days')::interval,
    privado.agora() + (dias || ' days 6 hours')::interval, chave))->>'vaga_id')::uuid;
end $corpo$;

create function pg_temp.candidatar(conta uuid, vaga uuid) returns jsonb
language sql as $$
  select pg_temp.como(conta, format($x$ select public.candidatar(%L) $x$, vaga))
$$;

create temp table v as
  select pg_temp.publicar('c1000000-0000-4000-8000-000000000001', 2) as geo,
         pg_temp.publicar('c1000000-0000-4000-8000-000000000002', 2) as manual,
         pg_temp.publicar('c1000000-0000-4000-8000-000000000003', 4) as desiste,
         pg_temp.publicar('c1000000-0000-4000-8000-000000000004', 5) as cancelada_pela_casa,
         pg_temp.publicar('c1000000-0000-4000-8000-000000000005', 6) as vaga_cancelada;

create temp table c as
  select pg_temp.candidatar('c1000000-0000-4000-8000-0000000000e1', (select geo from v)) as geo,
         pg_temp.candidatar('c1000000-0000-4000-8000-0000000000e2', (select manual from v)) as manual,
         pg_temp.candidatar('c1000000-0000-4000-8000-0000000000e3', (select desiste from v)) as desiste,
         pg_temp.candidatar('c1000000-0000-4000-8000-0000000000e4', (select cancelada_pela_casa from v)) as casa,
         pg_temp.candidatar('c1000000-0000-4000-8000-0000000000e5', (select vaga_cancelada from v)) as vaga;

-- Quem recebeu o quê, para a referência dada, como texto ordenado.
create function pg_temp.destinatarios(t public.tipo_notificacao, ref uuid) returns text
language sql as $$
  select coalesce(string_agg(right(usuario_id::text, 2), ',' order by usuario_id), '')
    from public.notificacao where tipo = t and referencia_id = ref
$$;

-- ── A estrutura ───────────────────────────────────────────────────────────────
select has_column('public', 'notificacao', 'usuario_id',    'notificacao tem destinatário');
select has_column('public', 'notificacao', 'tipo',          'notificacao tem tipo');
select has_column('public', 'notificacao', 'referencia_id', 'notificacao tem referência');
select has_column('public', 'notificacao', 'payload',       'notificacao tem payload');
select has_column('public', 'notificacao', 'tentativas',    'notificacao conta tentativas');
select has_column('public', 'notificacao', 'aceita_em',     'notificacao marca quando o FCM aceitou');
select col_is_null('public', 'notificacao', 'profissional_id',
  'profissional_id é anulável: aviso de contratante não tem profissional');

-- ── privado.notificar: a marca de envio ───────────────────────────────────────
select privado.notificar('c1000000-0000-4000-8000-0000000000e1', 'lembrete_24h',
  (c.geo->>'turno_id')::uuid, jsonb_build_object('turno_id', c.geo->>'turno_id'))
  from c;
select privado.notificar('c1000000-0000-4000-8000-0000000000e1', 'lembrete_24h',
  (c.geo->>'turno_id')::uuid, jsonb_build_object('turno_id', c.geo->>'turno_id'))
  from c;

select is(
  (select count(*)::int from public.notificacao
    where tipo = 'lembrete_24h' and usuario_id = 'c1000000-0000-4000-8000-0000000000e1'),
  1,
  'marca de envio: o mesmo tipo agendado, referência e conta não cria segunda linha');

select privado.notificar('c1000000-0000-4000-8000-0000000000d1', 'lembrete_24h',
  (c.geo->>'turno_id')::uuid, jsonb_build_object('turno_id', c.geo->>'turno_id'))
  from c;
select is(
  (select count(*)::int from public.notificacao where tipo = 'lembrete_24h'),
  2,
  'a marca é por conta: outro destinatário do mesmo turno recebe o seu lembrete');

select throws_ok(
  $$ select privado.notificar('c1000000-0000-4000-8000-0000000000e1', 'lembrete_3h',
       gen_random_uuid(), '{"nome":"Fulano"}'::jsonb) $$,
  '22023',
  null,
  'RN15: chave fora do vocabulário de ids não entra no payload');

select throws_ok(
  $$ select privado.notificar('c1000000-0000-4000-8000-0000000000e1', 'lembrete_3h',
       gen_random_uuid(), '{"turno_id":"+5561944440011"}'::jsonb) $$,
  '22023',
  null,
  'RN15: o valor de um id tem que ser um uuid, não um telefone');

-- As restrições de coerência entre o tipo e o profissional.
select throws_ok(
  $$ insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
     values ('c1000000-0000-4000-8000-0000000000e1', 'vaga', gen_random_uuid(), '{}') $$,
  '23514',
  null,
  'notificação de vaga sem profissional é recusada: o teto da RN23 precisa dele');

select throws_ok(
  format($$ insert into public.notificacao (usuario_id, profissional_id, tipo, referencia_id, payload)
     values ('c1000000-0000-4000-8000-0000000000d1', %L, 'checkin', gen_random_uuid(), '{}') $$,
     (select id from public.profissional limit 1)),
  '23514',
  null,
  'só as notificações de vaga carregam profissional_id');

select throws_ok(
  $$ insert into public.notificacao (usuario_id, tipo, referencia_id, tentativas)
     values ('c1000000-0000-4000-8000-0000000000d1', 'checkin', gen_random_uuid(), -1) $$,
  '23514',
  null,
  'tentativas de envio nunca é negativa');

-- ── RN23: o teto só para as de vaga ───────────────────────────────────────────
select ok(
  (select indexdef from pg_indexes
    where schemaname = 'public' and indexname = 'notificacao_teto') ~ 'vaga',
  'RN23: o índice do teto é parcial, só para os tipos de vaga');

select ok(
  (select indexdef from pg_indexes
    where schemaname = 'public' and tablename = 'notificacao'
      and indexdef ilike '%unique%' and indexdef ~ 'tipo, referencia_id, usuario_id') is not null,
  'a marca de envio é um índice único (tipo, referencia_id, usuario_id)');

select is(
  (select count(*)::int from public.notificacao
    where tipo in ('confirmacao','checkin','cancelamento') and profissional_id is not null),
  0,
  'RN23: aviso de contratante ou de turno nunca entra na conta do teto');

-- O teto ainda não tem quem o aplique (entra com o motor de despacho). O que já dá para
-- provar é a pergunta que ele vai fazer — "quantas notificações de vaga esta pessoa
-- recebeu" — pelo caminho real, `privado.notificar`: o lembrete que a e1 já recebeu
-- lá em cima não pode entrar na resposta, e a de vaga tem de entrar.
select privado.notificar('c1000000-0000-4000-8000-0000000000e1', 'vaga',
  'c1000000-0000-4000-8000-00000000aa01',
  '{"vaga_id":"c1000000-0000-4000-8000-00000000aa01"}');

select is(
  (select array_agg(n.tipo::text order by n.tipo::text) from public.notificacao n
    where n.profissional_id = (select p.id from public.profissional p
                                where p.usuario_id = 'c1000000-0000-4000-8000-0000000000e1')),
  array['vaga'],
  'RN23: pelo notificar, a conta do teto da e1 vê a de vaga e não vê o lembrete que ela também recebeu');

select cmp_ok(
  (select count(*)::int from public.notificacao
    where usuario_id = 'c1000000-0000-4000-8000-0000000000e1' and tipo <> 'vaga'), '>', 0,
  'a e1 tem aviso de outro tipo, então a asserção anterior mede alguma coisa');

-- ── candidatar: confirmacao ao profissional e a cada membro (RF10) ────────────
select is(
  pg_temp.destinatarios('confirmacao', (select (geo->>'turno_id')::uuid from c)),
  'd1,d2,e1',
  'RF10: a confirmação vai para o profissional e para os dois membros da casa');

select is(
  (select payload from public.notificacao
    where tipo = 'confirmacao' and usuario_id = 'c1000000-0000-4000-8000-0000000000d2'
      and referencia_id = (select (geo->>'turno_id')::uuid from c)),
  (select jsonb_build_object('tipo', 'confirmacao',
            'turno_id', geo->>'turno_id', 'vaga_id', (select geo from v)) from c),
  'o payload da confirmação leva o tipo e os ids do destino do toque');

select pg_temp.candidatar('c1000000-0000-4000-8000-0000000000e1', (select geo from v));
select is(
  (select count(*)::int from public.notificacao
    where tipo = 'confirmacao' and referencia_id = (select (geo->>'turno_id')::uuid from c)),
  3,
  'reenviar a candidatura não enfileira a confirmação de novo');

-- ── fazer_checkin: geolocalizado é aviso, manual é pedido de confirmação ──────
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora',
  (select (p.inicio_em - interval '30 minutes')::text
     from public.posicao p where p.id = (select (geo->>'posicao_id')::uuid from c)), true);

select pg_temp.como('c1000000-0000-4000-8000-0000000000e1',
  format($$ select public.fazer_checkin(%L, 80, %L) $$,
    (select geo->>'turno_id' from c), privado.agora()));
select pg_temp.como('c1000000-0000-4000-8000-0000000000e2',
  format($$ select public.fazer_checkin(%L, 900, %L) $$,
    (select manual->>'turno_id' from c), privado.agora()));

select is(
  pg_temp.destinatarios('checkin', (select (geo->>'turno_id')::uuid from c)),
  'd1,d2',
  'check-in geolocalizado enfileira `checkin` para os membros');

select is(
  pg_temp.destinatarios('checkin_manual_pendente', (select (geo->>'turno_id')::uuid from c)),
  '',
  'check-in geolocalizado não pede confirmação');

select is(
  pg_temp.destinatarios('checkin_manual_pendente', (select (manual->>'turno_id')::uuid from c)),
  'd1,d2',
  'check-in manual gera `checkin_manual_pendente` para os membros');

select is(
  pg_temp.destinatarios('checkin', (select (manual->>'turno_id')::uuid from c)),
  '',
  'check-in manual ainda não é presença: não sai `checkin`');

select pg_temp.como('c1000000-0000-4000-8000-0000000000e1',
  format($$ select public.fazer_checkin(%L, 80, %L) $$,
    (select geo->>'turno_id' from c), privado.agora()));
select is(
  (select count(*)::int from public.notificacao where tipo = 'checkin'),
  2,
  'reenviar o check-in não enfileira de novo');

select set_config('frila.agora', '', true);

-- ── cancelamento: a outra parte, inclusive a vaga inteira ─────────────────────
select pg_temp.como('c1000000-0000-4000-8000-0000000000e3',
  format($$ select public.cancelar_posicao(%L, 'imprevisto de saúde') $$, (select desiste->>'posicao_id' from c)));

select is(
  pg_temp.destinatarios('cancelamento', (select (desiste->>'posicao_id')::uuid from c)),
  'd1,d2',
  'o profissional cancela: os membros da casa recebem `cancelamento`');

select pg_temp.como('c1000000-0000-4000-8000-0000000000d2',
  format($$ select public.cancelar_posicao(%L, 'evento suspenso') $$, (select casa->>'posicao_id' from c)));

select is(
  pg_temp.destinatarios('cancelamento', (select (casa->>'posicao_id')::uuid from c)),
  'e4',
  'a casa cancela: só o profissional recebe, e quem cancelou não é avisado');

select pg_temp.como('c1000000-0000-4000-8000-0000000000d1',
  format($$ select public.cancelar_vaga(%L, 'casa fechada') $$, (select vaga_cancelada from v)));

select is(
  pg_temp.destinatarios('cancelamento', (select (vaga->>'posicao_id')::uuid from c)),
  'e5',
  'cancelar a vaga avisa o profissional de cada posição confirmada');

select is(
  (select (payload->>'reaberta')::boolean from public.notificacao
    where tipo = 'cancelamento' and referencia_id = (select (vaga->>'posicao_id')::uuid from c)),
  false,
  'vaga cancelada não reabre: o payload diz reaberta = false');

select is(
  (select (payload->>'reaberta')::boolean from public.notificacao
    where tipo = 'cancelamento' and referencia_id = (select (desiste->>'posicao_id')::uuid from c)
      and usuario_id = 'c1000000-0000-4000-8000-0000000000d1'),
  true,
  'antes do início a posição reabre: o payload diz reaberta = true');

-- ── RN15: nenhum payload carrega dado pessoal ─────────────────────────────────
select cmp_ok(
  (select count(*)::int from public.notificacao), '>', 10,
  'há notificações suficientes para a varredura valer alguma coisa');

select is(
  (select count(*)::int from public.notificacao n, public.usuario u
    where n.payload::text like '%' || u.telefone || '%'
       or n.payload::text ilike '%' || split_part(u.nome, ' ', 1) || '%'
       or n.payload::text like '%@%'),
  0,
  'RN15: nenhum payload tem telefone, e-mail ou nome');

select is(
  (select count(*)::int from public.notificacao n, jsonb_object_keys(n.payload) k
    where k not in ('tipo','vaga_id','posicao_id','turno_id','estabelecimento_id','reaberta')),
  0,
  'RN15: as chaves do payload são só o tipo e os ids do destino do toque');

select is(
  (select count(*)::int from public.notificacao where payload->>'tipo' is distinct from tipo::text),
  0,
  'o payload sempre diz o tipo, igual à coluna');

-- ── A leitura é da conta; a escrita não é de ninguém ──────────────────────────
select is(
  pg_temp.como('c1000000-0000-4000-8000-0000000000d2',
    $$ select to_jsonb(count(*)::int) from public.notificacao
        where usuario_id <> (select auth.uid()) $$),
  '0'::jsonb,
  'RLS: a conta só lê as notificações em que é destinatária');

select cmp_ok(
  (pg_temp.como('c1000000-0000-4000-8000-0000000000d2',
    $$ select to_jsonb(count(*)::int) from public.notificacao $$))::int, '>', 0,
  'RLS: o contratante lê as próprias, que antes não existiam para ele');

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and tablename = 'notificacao' and cmd <> 'SELECT'),
  0,
  'nenhuma política de escrita em notificacao: quem grava é a RPC');

select is(
  has_function_privilege('authenticated',
    'privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb)', 'execute'),
  false,
  'privado.notificar não é chamável pelo app');

select is(
  has_function_privilege('authenticated',
    'privado.notificar_membros(uuid, public.tipo_notificacao, uuid, jsonb)', 'execute'),
  false,
  'privado.notificar_membros não é chamável pelo app');

select is(
  has_function_privilege('anon',
    'privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb)', 'execute')
  or has_function_privilege('anon',
    'privado.notificar_membros(uuid, public.tipo_notificacao, uuid, jsonb)', 'execute'),
  false,
  'nenhuma das duas é chamável sem sessão');

select * from finish();
rollback;
