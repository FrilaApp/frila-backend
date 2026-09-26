-- Testes do registro do aparelho, estado de entrega e métricas RNF02 / RNF03.
-- Cartão 36fU0CEO: Envio de push pelo FCM, registro do aparelho e estado de entrega.
--
-- Prefixo 270: reservado para o ciclo de push e dispositivos.

begin;
select plan(43);

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

-- Contas de teste com prefixo c7000000
select pg_temp.autenticar('c7000000-0000-4000-8000-000000000001', 'user_a@push.test');
select pg_temp.autenticar('c7000000-0000-4000-8000-000000000002', 'user_b@push.test');

select pg_temp.como('c7000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('profissional', 'Usuario Push A', '+5561955550001', '1992-05-10', '2026-09-22') $$);
select pg_temp.como('c7000000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('contratante', 'Usuario Push B', '+5561955550002', '1985-08-20', '2026-09-22') $$);

-- ── 1. Privilégios e Molde da RPC registrar_dispositivo ───────────────────────

select is(
  has_function_privilege('authenticated', 'public.registrar_dispositivo(text, text)', 'execute'),
  true,
  'public.registrar_dispositivo é executável por authenticated');

select is(
  has_function_privilege('anon', 'public.registrar_dispositivo(text, text)', 'execute'),
  false,
  'public.registrar_dispositivo não é executável por anon');

select is(
  (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'registrar_dispositivo'),
  true,
  'public.registrar_dispositivo é security definer');

select is(
  (select coalesce(p.proconfig, '{}') @> array['search_path=""'] from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'registrar_dispositivo'),
  true,
  'public.registrar_dispositivo roda com search_path = ''''');

-- ── 2. Validações e Recusas da RPC ─────────────────────────────────────────────

select throws_ok(
  $$ select public.registrar_dispositivo('fcm_token_valido_com_mais_de_20_caracteres', 'ios') $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'Sem sessão: recusa com 401 nao_autenticado');

select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000001',
       $x$ select public.registrar_dispositivo(null, 'ios') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "token_fcm", "hint" : null}',
  'token_fcm nulo recusa com 422 campo_obrigatorio');

select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000001',
       $x$ select public.registrar_dispositivo('   ', 'ios') $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "token_fcm", "hint" : null}',
  'token_fcm vazio recusa com 422 campo_obrigatorio');

select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000001',
       $x$ select public.registrar_dispositivo(repeat('x', 19), 'ios') $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "token_fcm", "hint" : null}',
  'token_fcm com menos de 20 caracteres recusa com 422 campo_invalido');

select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000001',
       $x$ select public.registrar_dispositivo('fcm_token_valido_com_mais_de_20_caracteres', null) $x$) $$,
  'PGRST',
  '{"code" : "campo_obrigatorio", "message" : "campo_obrigatorio", "details" : "plataforma", "hint" : null}',
  'plataforma nula recusa com 422 campo_obrigatorio');

select throws_ok(
  $$ select pg_temp.como('c7000000-0000-4000-8000-000000000001',
       $x$ select public.registrar_dispositivo('fcm_token_valido_com_mais_de_20_caracteres', 'windows') $x$) $$,
  'PGRST',
  '{"code" : "campo_invalido", "message" : "campo_invalido", "details" : "plataforma", "hint" : null}',
  'plataforma fora do enum recusa com 422 campo_invalido');

-- ── 3. Registro e Idempotência ────────────────────────────────────────────────

create temp table res_reg1 as
  select pg_temp.como('c7000000-0000-4000-8000-000000000001',
    $$ select public.registrar_dispositivo('fcm_token_aparelho_user_a_1234567890', 'ios') $$) as res;

select is(
  (select res->>'plataforma' from res_reg1),
  'ios',
  'Resposta traz plataforma: ios');

select ok(
  (select (res->>'atualizado_em') is not null from res_reg1),
  'Resposta traz atualizado_em');

select is(
  (select res ? 'token_fcm' or res ? 'usuario_id' or res ? 'id' from res_reg1),
  false,
  'Resposta NÃO vaza dados internos (token, usuario_id, id); segue schema Dispositivo');

select is(
  (select count(*)::int from public.dispositivo
    where usuario_id = 'c7000000-0000-4000-8000-000000000001'
      and token_fcm = 'fcm_token_aparelho_user_a_1234567890'
      and plataforma = 'ios'),
  1,
  'Dispositivo gravado na tabela public.dispositivo para o Usuário A');

-- Idempotência: reenviar o mesmo token atualiza a data e não duplica
create temp table res_reg2 as
  select pg_temp.como('c7000000-0000-4000-8000-000000000001',
    $$ select public.registrar_dispositivo('fcm_token_aparelho_user_a_1234567890', 'ios') $$) as res;

select is(
  (select count(*)::int from public.dispositivo
    where token_fcm = 'fcm_token_aparelho_user_a_1234567890'),
  1,
  'Idempotência: reenviar mesmo token não cria segunda linha');

-- ── 4. Troca de Dono e Múltiplos Dispositivos ──────────────────────────────────

-- Usuário B faz login no mesmo aparelho (mesmo token)
create temp table res_reg_troca as
  select pg_temp.como('c7000000-0000-4000-8000-000000000002',
    $$ select public.registrar_dispositivo('fcm_token_aparelho_user_a_1234567890', 'ios') $$) as res;

select is(
  (select usuario_id from public.dispositivo
    where token_fcm = 'fcm_token_aparelho_user_a_1234567890'),
  'c7000000-0000-4000-8000-000000000002'::uuid,
  'Troca de dono: token transferido para o Usuário B');

select is(
  (select count(*)::int from public.dispositivo
    where usuario_id = 'c7000000-0000-4000-8000-000000000001'),
  0,
  'Usuário A não é mais dono daquele aparelho');

-- Usuário B registra um segundo aparelho (android)
select pg_temp.como('c7000000-0000-4000-8000-000000000002',
  $$ select public.registrar_dispositivo('fcm_token_aparelho_user_b_segundo_device_android', 'android') $$);

select is(
  (select count(*)::int from public.dispositivo
    where usuario_id = 'c7000000-0000-4000-8000-000000000002'),
  2,
  'Usuário B possui dois aparelhos registrados');

-- ── 5. RLS em dispositivo ─────────────────────────────────────────────────────

select is(
  pg_temp.como('c7000000-0000-4000-8000-000000000001',
    $$ select to_jsonb(count(*)::int) from public.dispositivo $$),
  '0'::jsonb,
  'RLS: Usuário A não enxerga aparelhos de terceiros');

select is(
  pg_temp.como('c7000000-0000-4000-8000-000000000002',
    $$ select to_jsonb(count(*)::int) from public.dispositivo $$),
  '2'::jsonb,
  'RLS: Usuário B enxerga seus 2 aparelhos');

select is(
  (select count(*)::int from pg_policies
    where schemaname = 'public' and tablename = 'dispositivo' and cmd <> 'SELECT'),
  0,
  'RLS: Nenhuma política de escrita em dispositivo; escrita só pela RPC');

-- ── 6. Auxiliares de Envio e Estado de Entrega ────────────────────────────────

select is(
  has_function_privilege('authenticated',
    'privado.gravar_aceite_push(uuid, timestamptz, timestamptz)', 'execute')
  or has_function_privilege('anon',
    'privado.gravar_aceite_push(uuid, timestamptz, timestamptz)', 'execute'),
  false,
  'privado.gravar_aceite_push não é pública nem de authenticated');

select is(
  has_function_privilege('service_role',
    'privado.gravar_aceite_push(uuid, timestamptz, timestamptz)', 'execute'),
  true,
  'privado.gravar_aceite_push é liberada para service_role');

select is(
  has_function_privilege('authenticated',
    'privado.gravar_falha_push(uuid, text, boolean, int, timestamptz, timestamptz)', 'execute')
  or has_function_privilege('anon',
    'privado.gravar_falha_push(uuid, text, boolean, int, timestamptz, timestamptz)', 'execute'),
  false,
  'privado.gravar_falha_push não é pública nem de authenticated');

select is(
  has_function_privilege('service_role',
    'privado.gravar_falha_push(uuid, text, boolean, int, timestamptz, timestamptz)', 'execute'),
  true,
  'privado.gravar_falha_push é liberada para service_role');

-- Cria uma notificação pendente para testar aceite e falha
create temp table n_teste as
  select privado.notificar(
    'c7000000-0000-4000-8000-000000000002',
    'cancelamento',
    'c7000000-0000-4000-8000-000000000099'::uuid,
    '{}'::jsonb
  ) as id;

select is(
  (select estado_entrega from public.notificacao where id = (select id from n_teste)),
  'pendente'::public.estado_entrega,
  'Notificação nasce com estado_entrega = pendente');

select is(
  (select proxima_tentativa_em is null from public.notificacao where id = (select id from n_teste)),
  true,
  'Notificação nasce com proxima_tentativa_em nulo');

-- Simula que a notificação foi criada há 15 minutos (tempo na fila)
update public.notificacao
   set enviada_em = privado.agora() - interval '15 minutes'
 where id = (select id from n_teste);

-- Simula aceite do FCM gravando instante real do despacho (privado.agora()) e aceite 2 segundos depois
do $$
begin
  perform privado.gravar_aceite_push(
    (select id from n_teste),
    privado.agora() + interval '2 seconds',
    privado.agora()
  );
end $$;

select is(
  (select estado_entrega from public.notificacao where id = (select id from n_teste)),
  'enviada'::public.estado_entrega,
  'Aceite do FCM: estado_entrega passa para enviada');

select ok(
  (select aceita_em is not null from public.notificacao where id = (select id from n_teste)),
  'Aceite do FCM: aceita_em é preenchido');

select is(
  (select tentativas from public.notificacao where id = (select id from n_teste)),
  1,
  'Aceite do FCM: tentativas incrementada para 1');

select is(
  (select proxima_tentativa_em is null from public.notificacao where id = (select id from n_teste)),
  true,
  'Aceite do FCM: proxima_tentativa_em é limpo (nulo)');

-- Prova Bloqueio 4: enviada_em foi atualizado com o instante real do envio, superando a data da criação
select is(
  (select enviada_em >= privado.agora() - interval '1 second' from public.notificacao where id = (select id from n_teste)),
  true,
  'Bloqueio 4: gravar_aceite_push atualiza enviada_em com o instante real do despacho');

select is(
  (select (aceita_em - enviada_em) <= interval '60 seconds' from public.notificacao where id = (select id from n_teste)),
  true,
  'Bloqueio 4: aceita_em - enviada_em mede a latência real de envio ao FCM (<= 60 s)');

-- Cria notificação para testar erro transitório e retentativa
create temp table n_transitorio as
  select privado.notificar(
    'c7000000-0000-4000-8000-000000000002',
    'cancelamento',
    'c7000000-0000-4000-8000-000000000098'::uuid,
    '{}'::jsonb
  ) as id;

-- Erro transitório abaixo do teto: continua pendente para retry com backoff exponencial
do $$
begin
  perform privado.gravar_falha_push((select id from n_transitorio), 'erro_503_fcm', false, 5);
end $$;

select is(
  (select estado_entrega from public.notificacao where id = (select id from n_transitorio)),
  'pendente'::public.estado_entrega,
  'Erro transitório abaixo do teto: continua pendente para reenvio');

select is(
  (select tentativas from public.notificacao where id = (select id from n_transitorio)),
  1,
  'Tentativa é contabilizada');

select is(
  (select proxima_tentativa_em >= privado.agora() + interval '9 seconds' from public.notificacao where id = (select id from n_transitorio)),
  true,
  'Bloqueio 3: Erro transitório agenda proxima_tentativa_em no futuro com backoff exponencial');

-- Força atingir o teto de 5 tentativas
do $$
begin
  update public.notificacao set tentativas = 4 where id = (select id from n_transitorio);
  perform privado.gravar_falha_push((select id from n_transitorio), 'teto_excedido', false, 5);
end $$;

select is(
  (select estado_entrega from public.notificacao where id = (select id from n_transitorio)),
  'falhou'::public.estado_entrega,
  'Teto de tentativas atingido: estado_entrega vira falhou');

select is(
  (select proxima_tentativa_em is null from public.notificacao where id = (select id from n_transitorio)),
  true,
  'Bloqueio 3: Teto de tentativas limpa proxima_tentativa_em');

-- Remoção de token inválido (UNREGISTERED)
select is(
  privado.remover_token_fcm('fcm_token_aparelho_user_b_segundo_device_android'),
  1,
  'privado.remover_token_fcm remove exatamente 1 aparelho');

select is(
  (select count(*)::int from public.dispositivo
    where token_fcm = 'fcm_token_aparelho_user_b_segundo_device_android'),
  0,
  'Token UNREGISTERED foi removido do banco');

-- ── 7. Expiração da Notificação (não reenviar após início) ────────────────────

create temp table n_expirada as
  select gen_random_uuid() as vaga_id, gen_random_uuid() as notif_id;

do $$
declare
  v_vaga uuid := (select vaga_id from n_expirada);
  v_notif uuid := (select notif_id from n_expirada);
  v_agora timestamptz := privado.agora();
  v_prof uuid;
begin
  select id into v_prof from public.profissional limit 1;

  -- Vaga que já iniciou há 1 hora
  insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                           valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                           exige_material_proprio, responsavel_local, publicado_por, modo, estado, chave_cliente)
  values (v_vaga,
          'c0000000-0000-4000-8000-000000000001',
          (select id from public.funcao where nome = 'garçom'),
          v_agora - interval '1 hour',
          v_agora + interval '5 hours',
          'Local Teste', 'POINT(-47.8825 -15.7940)'::extensions.geography,
          15000, 1, false, false, false, 'Gerente',
          'c7000000-0000-4000-8000-000000000002', 'urgencia', 'publicada', gen_random_uuid());

  insert into public.notificacao (id, usuario_id, profissional_id, tipo, referencia_id, estado_entrega)
  values (v_notif, (select usuario_id from public.profissional where id = v_prof), v_prof, 'vaga', v_vaga, 'pendente');
end $$;

select is(
  privado.notificacao_expirada((select notif_id from n_expirada)),
  true,
  'Notificação de vaga cujo início já passou é considerada expirada');

-- ── 8. Consulta / Métrica RNF02 (99% em até 60 s nos últimos 7 dias) ──────────

-- Limpa notificações para testar o cálculo da taxa de forma determinística
delete from public.notificacao;

-- 1. Enfileirada há 2 horas, despachada há 1 minuto, aceita 2 segundos depois -> dentro dos 60 s (RNF02 cumprido)
insert into public.notificacao (usuario_id, tipo, referencia_id, enviada_em, aceita_em, estado_entrega)
values ('c7000000-0000-4000-8000-000000000002', 'cancelamento', gen_random_uuid(),
        privado.agora() - interval '1 minute', privado.agora() - interval '1 minute' + interval '2 seconds', 'enviada');

-- 2. Despachada há 2 minutos, aceita 75 segundos depois -> fora dos 60 s (> 60s)
insert into public.notificacao (usuario_id, tipo, referencia_id, enviada_em, aceita_em, estado_entrega)
values ('c7000000-0000-4000-8000-000000000002', 'cancelamento', gen_random_uuid(),
        privado.agora() - interval '2 minutes', privado.agora() - interval '2 minutes' + interval '75 seconds', 'enviada');

-- 3. Falhou -> fora dos 60s
insert into public.notificacao (usuario_id, tipo, referencia_id, enviada_em, estado_entrega, tentativas, motivo_falha)
values ('c7000000-0000-4000-8000-000000000002', 'cancelamento', gen_random_uuid(),
        privado.agora() - interval '5 minutes', 'falhou', 5, 'teto_excedido');

-- 4. Pendente -> fora dos 60s
insert into public.notificacao (usuario_id, tipo, referencia_id, enviada_em, estado_entrega)
values ('c7000000-0000-4000-8000-000000000002', 'cancelamento', gen_random_uuid(),
        privado.agora() - interval '30 seconds', 'pendente');

-- Total na janela de 7 dias: 4. Aceitas em até 60s do despacho: 1. Taxa: 25.00%
select is(
  (select taxa_aceite_pct from privado.taxa_aceite_notificacoes_7d()),
  25.00,
  'RNF02: taxa_aceite_notificacoes_7d mede a partir do envio real até o aceite (1 de 4 = 25%)');

-- Adiciona notificação com mais de 7 dias (não deve entrar no cálculo)
insert into public.notificacao (usuario_id, tipo, referencia_id, enviada_em, aceita_em, estado_entrega)
values ('c7000000-0000-4000-8000-000000000002', 'cancelamento', gen_random_uuid(),
        privado.agora() - interval '8 days', privado.agora() - interval '8 days' + interval '10 seconds', 'enviada');

select is(
  (select total_despachadas from privado.taxa_aceite_notificacoes_7d()),
  4::bigint,
  'Notificações anteriores a 7 dias são excluídas do RNF02');

select * from finish();
rollback;

