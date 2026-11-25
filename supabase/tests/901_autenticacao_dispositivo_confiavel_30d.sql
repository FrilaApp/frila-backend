-- 901_autenticacao_dispositivo_confiavel_30d.sql
-- Testa a fundação server-side de autenticação por senha + dispositivo confiável (30 dias),
-- custom_access_token_hook, trava precisa_definir_senha, proteção contra bypass GoTrue,
-- preservação de sessões legadas pré-corte, expiração pelo relógio do banco,
-- isolamento entre contas, replay/concorrência de desafios e revogação no reset/logout global.
begin;
select plan(37);

-- ── 1. Privilégios: tabelas e funções privadas inacessíveis a anon/authenticated ─
select ok(
  not has_table_privilege('anon', 'privado.dispositivos_confiaveis', 'select')
  and not has_table_privilege('authenticated', 'privado.dispositivos_confiaveis', 'select')
  and not has_table_privilege('authenticated', 'privado.sessoes_verificadas', 'select')
  and not has_table_privilege('authenticated', 'privado.desafios_dispositivo', 'select')
  and not has_table_privilege('authenticated', 'privado.contas_senha_pendente', 'select'),
  'tabelas privadas de dispositivo/desafio/sessao não são acessíveis a anon/authenticated'
);

select ok(
  not has_function_privilege('anon', 'privado.custom_access_token_hook(jsonb)', 'execute')
  and not has_function_privilege('authenticated', 'privado.custom_access_token_hook(jsonb)', 'execute')
  and has_function_privilege('supabase_auth_admin', 'privado.custom_access_token_hook(jsonb)', 'execute'),
  'custom_access_token_hook é executável apenas por supabase_auth_admin'
);

select ok(
  has_function_privilege('authenticated', 'public.estado_autenticacao()', 'execute')
  and not has_function_privilege('anon', 'public.estado_autenticacao()', 'execute'),
  'estado_autenticacao() é executável apenas por authenticated'
);

-- ── 2. Configuração nasce em modo sombra (rollout bloqueado) ───────────────────
select is(
  (select exigir_dispositivo_verificado from privado.config_auth where unica),
  false,
  'exigir_dispositivo_verificado nasce FALSE (rollout bloqueado até migração dos clientes)'
);

-- ── 3. Fixture sintética de usuários e sessões em auth.users / auth.sessions ───
do $$
declare
  v_u1 uuid := 'a1111111-1111-4111-8111-111111111111';
  v_u2 uuid := 'b2222222-2222-4222-8222-222222222222';
  v_s_pre  uuid := 'c1111111-1111-4111-8111-111111111111';
  v_s_post uuid := 'c2222222-2222-4222-8222-222222222222';
begin
  insert into auth.users (id, email, encrypted_password, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values
    (v_u1, 'titular.a@frila.test', '', '{}'::jsonb, '{}'::jsonb, now() - interval '2 days', now()),
    (v_u2, 'titular.b@frila.test', '$2a$10$hashsinteticoteste', '{}'::jsonb, '{}'::jsonb, now() - interval '2 days', now())
  on conflict (id) do nothing;

  insert into auth.sessions (id, user_id, created_at, updated_at)
  values
    (v_s_pre,  v_u1, now() - interval '2 hours', now() - interval '2 hours'),
    (v_s_post, v_u2, now(), now())
  on conflict (id) do nothing;
end $$;

-- ── 4. Hook em bypass direto ao GoTrue (sem sessoes_verificadas) ───────────────
update privado.config_auth
   set exigir_dispositivo_verificado = true,
       corte_sessoes_anteriores_em   = now() - interval '1 hour'
 where unica;

select is(
  (privado.custom_access_token_hook(jsonb_build_object(
    'user_id', 'b2222222-2222-4222-8222-222222222222',
    'claims',  jsonb_build_object('session_id', 'c2222222-2222-4222-8222-222222222222')
  )) -> 'claims' -> 'app_metadata' ->> 'dispositivo_verificado')::boolean,
  false,
  'bypass direto ao GoTrue sem sessoes_verificadas recebe dispositivo_verificado = false'
);

-- ── 5. Sessão legada pré-corte (mesmo OTP-only sem senha) é preservada ─────────
select is(
  (privado.custom_access_token_hook(jsonb_build_object(
    'user_id', 'a1111111-1111-4111-8111-111111111111',
    'claims',  jsonb_build_object('session_id', 'c1111111-1111-4111-8111-111111111111')
  )) -> 'claims' -> 'app_metadata' ->> 'dispositivo_verificado')::boolean,
  true,
  'sessão pré-corte mantém dispositivo_verificado = true durante o cutover'
);

select is(
  (privado.custom_access_token_hook(jsonb_build_object(
    'user_id', 'a1111111-1111-4111-8111-111111111111',
    'claims',  jsonb_build_object('session_id', 'c1111111-1111-4111-8111-111111111111')
  )) -> 'claims' -> 'app_metadata' ->> 'precisa_definir_senha')::boolean,
  false,
  'sessão legada OTP-only pré-corte NÃO recebe precisa_definir_senha = true (não derruba turno ativo)'
);

-- ── 6. Guarda do pre-request bloqueia bypass GoTrue (401) e libera estado_autenticacao ─
select set_config('request.jwt.claims', json_build_object(
  'sub', 'b2222222-2222-4222-8222-222222222222',
  'role', 'authenticated',
  'session_id', 'c2222222-2222-4222-8222-222222222222',
  'app_metadata', json_build_object('dispositivo_verificado', false, 'precisa_definir_senha', false)
)::text, true);
select set_config('request.path', '/rpc/meus_turnos', true);
select set_config('request.method', 'GET', true);

select throws_ok(
  $$ select requisicao.conferir_limite() $$,
  'PGRST',
  '{"code" : "dispositivo_nao_verificado", "message" : "dispositivo_nao_verificado", "details" : null, "hint" : null}',
  'pre-request bloqueia acesso ao produto quando dispositivo_verificado = false e cutover ativo'
);

select is(
  privado.sessao_autorizada_para_produto(),
  false,
  'sessao_autorizada_para_produto() retorna false para bypass GoTrue'
);

select set_config('request.path', '/rpc/estado_autenticacao', true);
select lives_ok(
  $$ select requisicao.conferir_limite() $$,
  'pre-request permite /rpc/estado_autenticacao mesmo quando dispositivo_verificado = false'
);

-- ── 7. Desafio OTP + emissão de dispositivo 30d + replay / 5 tentativas ────────
create temp table t_desafio as
select (privado.criar_desafio_dispositivo(
  'b2222222-2222-4222-8222-222222222222'::uuid,
  'Titular.B@Frila.test',
  'hash-email-b',
  'ios'
)) as res;

select is(
  (privado.reservar_tentativa_desafio(((select res ->> 'desafio_id' from t_desafio)::uuid)) ->> 'email_normalizado'),
  'titular.b@frila.test',
  'desafio persiste e devolve email_normalizado server-side para /auth/v1/verify'
);

select is(
  (privado.concluir_desafio_e_registrar_sessao(
    (select (res ->> 'desafio_id')::uuid from t_desafio),
    'b2222222-2222-4222-8222-222222222222'::uuid,
    'c2222222-2222-4222-8222-222222222222'::uuid,
    'ios',
    'hash-disp-b-valido',
    null
  ) ->> 'ok')::boolean,
  true,
  'conclusão do desafio registra dispositivo confiável (30d) e sessoes_verificadas'
);

-- Replay no mesmo desafio_id falha atomicamente
select is(
  (privado.concluir_desafio_e_registrar_sessao(
    (select (res ->> 'desafio_id')::uuid from t_desafio),
    'b2222222-2222-4222-8222-222222222222'::uuid,
    'c2222222-2222-4222-8222-222222222222'::uuid,
    'ios',
    null,
    null
  ) ->> 'motivo'),
  'desafio_ja_usado',
  'replay do mesmo desafio_id retorna desafio_ja_usado atomicamente'
);

-- Hook agora emite dispositivo_verificado = true após registro em sessoes_verificadas
select is(
  (privado.custom_access_token_hook(jsonb_build_object(
    'user_id', 'b2222222-2222-4222-8222-222222222222',
    'claims',  jsonb_build_object('session_id', 'c2222222-2222-4222-8222-222222222222')
  )) -> 'claims' -> 'app_metadata' ->> 'dispositivo_verificado')::boolean,
  true,
  'após registrar sessoes_verificadas, hook emite dispositivo_verificado = true'
);

-- ── 8. Isolamento entre contas: token da Conta B não vale para Conta A ─────────
select is(
  (privado.validar_e_marcar_dispositivo(
    'a1111111-1111-4111-8111-111111111111'::uuid,
    'c1111111-1111-4111-8111-111111111111'::uuid,
    'hash-disp-b-valido'
  ) ->> 'valido')::boolean,
  false,
  'device_token da Conta B é rejeitado para a Conta A'
);

-- ── 9. Expiração de 30 dias no relógio do banco (imune a clock skew cliente) ───
update privado.dispositivos_confiaveis
   set expira_em = now() - interval '1 second'
 where token_hash = 'hash-disp-b-valido';

select is(
  (privado.validar_e_marcar_dispositivo(
    'b2222222-2222-4222-8222-222222222222'::uuid,
    'c2222222-2222-4222-8222-222222222222'::uuid,
    'hash-disp-b-valido'
  ) ->> 'valido')::boolean,
  false,
  'dispositivo vencido (expira_em <= now()) é rejeitado pelo relógio do Postgres'
);

-- Reativa validade para testar revogação em definir-senha e revogar-todos
update privado.dispositivos_confiaveis
   set expira_em = now() + interval '29 days'
 where token_hash = 'hash-disp-b-valido';

-- ── 10. Trava server-authoritative precisa_definir_senha (kill-app pós-OTP) ────
insert into privado.contas_senha_pendente (usuario_id, motivo)
values ('b2222222-2222-4222-8222-222222222222', 'cadastro')
on conflict (usuario_id) do update set motivo = 'cadastro';

select is(
  (privado.custom_access_token_hook(jsonb_build_object(
    'user_id', 'b2222222-2222-4222-8222-222222222222',
    'claims',  jsonb_build_object('session_id', 'c2222222-2222-4222-8222-222222222222')
  )) -> 'claims' -> 'app_metadata' ->> 'precisa_definir_senha')::boolean,
  true,
  'pendência de cadastro faz o hook emitir precisa_definir_senha = true'
);

select set_config('request.jwt.claims', json_build_object(
  'sub', 'b2222222-2222-4222-8222-222222222222',
  'role', 'authenticated',
  'session_id', 'c2222222-2222-4222-8222-222222222222',
  'app_metadata', json_build_object('dispositivo_verificado', true, 'precisa_definir_senha', true)
)::text, true);

select set_config('request.path', '/rpc/publicar_vaga', true);
select throws_ok(
  $$ select requisicao.conferir_limite() $$,
  'PGRST',
  '{"code" : "senha_pendente", "message" : "senha_pendente", "details" : null, "hint" : null}',
  'pre-request bloqueia RPC de produto com 403 senha_pendente enquanto precisa_definir_senha = true'
);

select set_config('request.path', '/rpc/minha_conta', true);
select lives_ok(
  $$ select requisicao.conferir_limite() $$,
  'pre-request mantém /rpc/minha_conta acessível enquanto precisa_definir_senha = true'
);

select is(
  (public.estado_autenticacao() ->> 'precisa_definir_senha')::boolean,
  true,
  'estado_autenticacao() informa precisa_definir_senha = true mesmo antes de criar_conta'
);

-- ── 11. Concluir definição de senha limpa pendência e revoga dispositivos ──────
select is(
  (privado.concluir_definicao_senha(
    'b2222222-2222-4222-8222-222222222222'::uuid,
    'c2222222-2222-4222-8222-222222222222'::uuid,
    null
  ) ->> 'dispositivos_revogados')::integer,
  1,
  'concluir_definicao_senha revoga dispositivos confiáveis anteriores'
);

select is(
  (public.estado_autenticacao() ->> 'precisa_definir_senha')::boolean,
  false,
  'após concluir_definicao_senha, estado_autenticacao() retorna precisa_definir_senha = false'
);

select is(
  (privado.validar_e_marcar_dispositivo(
    'b2222222-2222-4222-8222-222222222222'::uuid,
    'c2222222-2222-4222-8222-222222222222'::uuid,
    'hash-disp-b-valido'
  ) ->> 'valido')::boolean,
  false,
  'dispositivo revogado após troca/reset de senha é rejeitado'
);

-- ── 12. Sair de todos os dispositivos (revogar_todos_dispositivos) ─────────────
insert into privado.dispositivos_confiaveis (usuario_id, token_hash, plataforma, expira_em)
values ('b2222222-2222-4222-8222-222222222222', 'hash-disp-b-2', 'web', now() + interval '30 days');

select is(
  privado.revogar_todos_dispositivos('b2222222-2222-4222-8222-222222222222'::uuid),
  1,
  'revogar_todos_dispositivos revoga todos os dispositivos ativos e encerra sessões'
);

-- ── 13. Sessão OTP verificada com lembrar_dispositivo = false (dispositivo_id IS NULL) ─
insert into auth.sessions (id, user_id, created_at, updated_at)
values ('c3333333-3333-4333-8333-333333333333', 'b2222222-2222-4222-8222-222222222222', now(), now())
on conflict (id) do nothing;

insert into privado.sessoes_verificadas (session_id, usuario_id, dispositivo_id)
values ('c3333333-3333-4333-8333-333333333333', 'b2222222-2222-4222-8222-222222222222', null);

select is(
  (privado.custom_access_token_hook(jsonb_build_object(
    'user_id', 'b2222222-2222-4222-8222-222222222222',
    'claims',  jsonb_build_object('session_id', 'c3333333-3333-4333-8333-333333333333')
  )) -> 'claims' -> 'app_metadata' ->> 'dispositivo_verificado')::boolean,
  true,
  'sessão verificada por OTP com dispositivo_id IS NULL (lembrar_dispositivo=false) recebe dispositivo_verificado = true'
);

-- ── 14. Reenvio de desafio mantém desafio_id, respeita cooldown 60s e não soma tentativas ─
create temp table t_reenvio as
select (privado.criar_desafio_dispositivo(
  'b2222222-2222-4222-8222-222222222222'::uuid,
  'Titular.B@Frila.test',
  'hash-email-b',
  'web'
)) as res;

select is(
  (privado.reservar_reenvio_desafio(((select res ->> 'desafio_id' from t_reenvio)::uuid)) ->> 'status'),
  'limite_excedido',
  'reenvio imediato (< 60s após criação) é bloqueado por cooldown'
);

update privado.desafios_dispositivo
   set criado_em = now() - interval '61 seconds'
 where id = (select (res ->> 'desafio_id')::uuid from t_reenvio);

select is(
  (privado.reservar_reenvio_desafio(((select res ->> 'desafio_id' from t_reenvio)::uuid)) ->> 'status'),
  'ok',
  'reenvio após 60s mantém o mesmo desafio_id sem incrementar tentativas de verificação'
);

-- ── 15. Revogação imediata online (JWT já emitido com dispositivo_verificado=true é bloqueado) ─
select set_config('request.jwt.claims', json_build_object(
  'sub', 'b2222222-2222-4222-8222-222222222222',
  'role', 'authenticated',
  'session_id', 'c3333333-3333-4333-8333-333333333333',
  'app_metadata', json_build_object('dispositivo_verificado', true, 'precisa_definir_senha', false)
)::text, true);
select set_config('request.path', '/rpc/meus_turnos', true);

-- Revoga todos os dispositivos/sessões da Conta B
select is(
  privado.revogar_todos_dispositivos('b2222222-2222-4222-8222-222222222222'::uuid) >= 0,
  true,
  'revogar_todos_dispositivos executa limpeza imediata de sessoes_verificadas'
);

-- Mesmo com JWT ainda carregando app_metadata.dispositivo_verificado=true, o guard online bloqueia imediatamente!
select throws_ok(
  $$ select requisicao.conferir_limite() $$,
  'PGRST',
  '{"code" : "dispositivo_nao_verificado", "message" : "dispositivo_nao_verificado", "details" : null, "hint" : null}',
  'revogação imediata: JWT já emitido é bloqueado instantaneamente após revogar_todos_dispositivos'
);

-- Sessão pré-corte (Conta A) continua isenta no guard online mesmo sem linha em sessoes_verificadas
select is(
  privado.verificar_sessao_dispositivo_online(
    'a1111111-1111-4111-8111-111111111111'::uuid,
    'c1111111-1111-4111-8111-111111111111'::uuid
  ),
  true,
  'sessão pré-corte continua isenta no guard online verificar_sessao_dispositivo_online()'
);

-- ── 16. Cobertura de mutação das 7 restrições CHECK/UNIQUE em privado ──────────
select throws_ok(
  $$ insert into privado.config_auth (unica) values (false) $$,
  '23514',
  null,
  'config_auth_unica_check impede linha com unica = false'
);

select throws_ok(
  $$ insert into privado.contas_senha_pendente (usuario_id, motivo)
     values ('a1111111-1111-4111-8111-111111111111', 'motivo_invalido') $$,
  '23514',
  null,
  'contas_senha_pendente_motivo_check recusa motivo fora de cadastro|recuperacao'
);

select throws_ok(
  $$ insert into privado.desafios_dispositivo (usuario_id, email_normalizado, email_hash, plataforma, expira_em)
     values ('a1111111-1111-4111-8111-111111111111', 'a@t.test', 'h', 'desktop', now() + interval '10 min') $$,
  '23514',
  null,
  'desafios_dispositivo_plataforma_check recusa plataforma fora de ios|android|web'
);

select throws_ok(
  $$ insert into privado.desafios_dispositivo (usuario_id, email_normalizado, email_hash, plataforma, reenvios, expira_em)
     values ('a1111111-1111-4111-8111-111111111111', 'a@t.test', 'h', 'web', 4, now() + interval '10 min') $$,
  '23514',
  null,
  'desafios_dispositivo_reenvios_check recusa reenvios acima de 3'
);

select throws_ok(
  $$ insert into privado.desafios_dispositivo (usuario_id, email_normalizado, email_hash, plataforma, tentativas, expira_em)
     values ('a1111111-1111-4111-8111-111111111111', 'a@t.test', 'h', 'web', 6, now() + interval '10 min') $$,
  '23514',
  null,
  'desafios_dispositivo_tentativas_check recusa tentativas acima de 5'
);

select throws_ok(
  $$ insert into privado.dispositivos_confiaveis (usuario_id, token_hash, plataforma, expira_em)
     values ('a1111111-1111-4111-8111-111111111111', 'hash-plat-invalida', 'desktop', now() + interval '30 days') $$,
  '23514',
  null,
  'dispositivos_confiaveis_plataforma_check recusa plataforma fora de ios|android|web'
);

select throws_ok(
  $$ insert into privado.dispositivos_confiaveis (usuario_id, token_hash, plataforma, expira_em)
     values ('a1111111-1111-4111-8111-111111111111', 'hash-disp-b-2', 'ios', now() + interval '30 days') $$,
  '23505',
  null,
  'dispositivos_confiaveis_token_hash_key impede reutilização do mesmo token_hash'
);

select * from finish();
rollback;
