-- Ciclo de vida do token de push: troca de conta, saída e reinstalação (RN25, RF06, RN15).
-- Cartão wpNabtCO.
--
-- O token é do aparelho, não da pessoa. Com duas contas no mesmo iPhone, o push da conta
-- anterior não pode chegar com a outra aberta, e o aparelho que saiu da conta não pode
-- continuar recebendo vagas.
--
-- Prefixo 300.

begin;
select plan(37);

insert into privado.ambiente (eh_teste) values (true);
select set_config('frila.agora', '2026-10-20 12:00:00-03', true);

-- A limpeza varre a tabela inteira; sem os aparelhos do cenário de demonstração, a
-- contagem que ela devolve é só a deste teste. O rollback no fim devolve tudo.
delete from public.dispositivo;

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

-- Quantos aparelhos a conta tem, lido como o agendador lê: por usuario_id.
create function pg_temp.aparelhos(conta uuid) returns int
language sql as $$
  select count(*)::int from public.dispositivo where usuario_id = conta
$$;

-- A conta A e a conta B são a mesma pessoa, com um perfil cada (RN25), no mesmo iPhone.
select pg_temp.autenticar('c3000000-0000-4000-8000-000000000001', 'conta_a@token.test');
select pg_temp.autenticar('c3000000-0000-4000-8000-000000000002', 'conta_b@token.test');

select pg_temp.como('c3000000-0000-4000-8000-000000000001',
  $$ select public.criar_conta('profissional', 'Conta Token A', '+5561933330001', '1992-05-10', '2026-09-22') $$);
select pg_temp.como('c3000000-0000-4000-8000-000000000002',
  $$ select public.criar_conta('contratante', 'Conta Token B', '+5561933330002', '1992-05-10', '2026-09-22') $$);

-- ── 1. O molde de remover_dispositivo ─────────────────────────────────────────

select is(
  has_function_privilege('authenticated', 'public.remover_dispositivo(text)', 'execute'),
  true,
  'public.remover_dispositivo é executável por authenticated');

select is(
  has_function_privilege('anon', 'public.remover_dispositivo(text)', 'execute'),
  false,
  'public.remover_dispositivo não é executável por anon');

select is(
  (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'remover_dispositivo'),
  true,
  'public.remover_dispositivo é security definer');

select is(
  (select coalesce(p.proconfig, '{}') @> array['search_path=""'] from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'remover_dispositivo'),
  true,
  'public.remover_dispositivo roda com search_path = ''''');

select throws_ok(
  $$ select public.remover_dispositivo('fcm_token_aparelho_compartilhado_0001') $$,
  'PGRST',
  '{"code" : "nao_autenticado", "message" : "nao_autenticado", "details" : null, "hint" : null}',
  'Sem sessão: remover_dispositivo recusa com 401 nao_autenticado');

-- O contrato 0.2.17 só declara 200 e 401: token nulo, em branco ou curto demais não
-- está registrado, e a saída "deu no mesmo". O logout do app não pode falhar por isso.
select is(
  pg_temp.como('c3000000-0000-4000-8000-000000000001',
    $$ select public.remover_dispositivo(null) $$),
  '{"removido": false}'::jsonb,
  'token_fcm nulo devolve removido false, sem erro');

select is(
  pg_temp.como('c3000000-0000-4000-8000-000000000001',
    $$ select public.remover_dispositivo('   ') $$),
  '{"removido": false}'::jsonb,
  'token_fcm em branco devolve removido false, sem erro');

select is(
  pg_temp.como('c3000000-0000-4000-8000-000000000001',
    $$ select public.remover_dispositivo(repeat('x', 19)) $$),
  '{"removido": false}'::jsonb,
  'token_fcm abaixo de 20 caracteres devolve removido false, sem erro');

-- ── 2. Troca de conta no mesmo aparelho: o token troca de dono ────────────────

select pg_temp.como('c3000000-0000-4000-8000-000000000001',
  $$ select public.registrar_dispositivo('fcm_token_aparelho_compartilhado_0001', 'ios') $$);

select is(pg_temp.aparelhos('c3000000-0000-4000-8000-000000000001'), 1,
  'Conta A registrou o aparelho');

-- A conta B entra no mesmo iPhone sem que a A tenha chamado remover_dispositivo
-- (app morto, sem rede no signOut): o registro de B toma o token.
select pg_temp.como('c3000000-0000-4000-8000-000000000002',
  $$ select public.registrar_dispositivo('fcm_token_aparelho_compartilhado_0001', 'ios') $$);

select is(pg_temp.aparelhos('c3000000-0000-4000-8000-000000000002'), 1,
  'Troca de dono: conta B passa a ter o aparelho');

select is(pg_temp.aparelhos('c3000000-0000-4000-8000-000000000001'), 0,
  'Troca de dono: conta A não tem mais aparelho, então o push de A não sai para ele');

select is(
  (select count(*)::int from public.dispositivo
    where token_fcm = 'fcm_token_aparelho_compartilhado_0001'),
  1,
  'Troca de dono: o token continua numa linha só');

select is(
  pg_temp.como('c3000000-0000-4000-8000-000000000001',
    $$ select to_jsonb(count(*)::int) from public.dispositivo $$),
  '0'::jsonb,
  'Pela leitura da conta A, o aparelho que passou para B não aparece');

-- ── 3. remover_dispositivo só tira o token da própria conta ──────────────────

select is(
  pg_temp.como('c3000000-0000-4000-8000-000000000001',
    $$ select public.remover_dispositivo('fcm_token_aparelho_compartilhado_0001') $$),
  '{"removido": false}'::jsonb,
  'Conta A tentando tirar o token que agora é de B: removido false');

select is(pg_temp.aparelhos('c3000000-0000-4000-8000-000000000002'), 1,
  'A saída atrasada da conta A não tira o aparelho da conta B');

-- ── 4. Saída da conta: remover_dispositivo antes do signOut ───────────────────

select is(
  pg_temp.como('c3000000-0000-4000-8000-000000000002',
    $$ select public.remover_dispositivo('fcm_token_aparelho_compartilhado_0001') $$),
  '{"removido": true}'::jsonb,
  'Conta B sai: removido true');

select is(pg_temp.aparelhos('c3000000-0000-4000-8000-000000000002'), 0,
  'Depois de sair, a conta B não tem aparelho para receber push');

select is(
  (select count(*)::int from public.dispositivo
    where token_fcm = 'fcm_token_aparelho_compartilhado_0001'),
  0,
  'Depois de sair, o token não está registrado para conta nenhuma');

select is(
  pg_temp.como('c3000000-0000-4000-8000-000000000002',
    $$ select public.remover_dispositivo('fcm_token_aparelho_compartilhado_0001') $$),
  '{"removido": false}'::jsonb,
  'Idempotente: repetir a saída devolve removido false, sem erro');

select is(
  pg_temp.como('c3000000-0000-4000-8000-000000000001',
    $$ select public.remover_dispositivo('  fcm_token_que_nunca_foi_registrado_01  ') $$),
  '{"removido": false}'::jsonb,
  'Token que nunca foi registrado devolve removido false, sem erro');

-- Saída que não é a única: a conta tem outro aparelho, e ele continua recebendo.
select pg_temp.como('c3000000-0000-4000-8000-000000000001',
  $$ select public.registrar_dispositivo('fcm_token_iphone_da_conta_a_000001', 'ios') $$);
select pg_temp.como('c3000000-0000-4000-8000-000000000001',
  $$ select public.registrar_dispositivo('fcm_token_ipad_da_conta_a_00000001', 'ios') $$);

select is(
  pg_temp.como('c3000000-0000-4000-8000-000000000001',
    $$ select public.remover_dispositivo('  fcm_token_iphone_da_conta_a_000001  ') $$),
  '{"removido": true}'::jsonb,
  'remover_dispositivo apara espaços do token, como o registro');

select is(
  (select array_agg(token_fcm) from public.dispositivo
    where usuario_id = 'c3000000-0000-4000-8000-000000000001'),
  array['fcm_token_ipad_da_conta_a_00000001'],
  'Sair de um aparelho não tira o outro aparelho da mesma conta');

-- ── 5. Reinstalação: o token novo entra, o antigo sai pela limpeza ────────────

select is(
  has_function_privilege('service_role', 'privado.limpar_dispositivos_inativos()', 'execute'),
  true,
  'privado.limpar_dispositivos_inativos é executável por service_role');

select is(
  has_function_privilege('authenticated', 'privado.limpar_dispositivos_inativos()', 'execute'),
  false,
  'privado.limpar_dispositivos_inativos não é executável por authenticated');

select is(
  has_function_privilege('anon', 'privado.limpar_dispositivos_inativos()', 'execute'),
  false,
  'privado.limpar_dispositivos_inativos não é executável por anon');

select is(
  (select coalesce(p.proconfig, '{}') @> array['search_path=""'] from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'limpar_dispositivos_inativos'),
  true,
  'privado.limpar_dispositivos_inativos roda com search_path = ''''');

-- A conta B reinstala o app: o token antigo nunca foi removido (o app foi apagado), e
-- o novo é registrado na primeira abertura.
select set_config('frila.agora', '2026-08-20 12:00:00-03', true);
select pg_temp.como('c3000000-0000-4000-8000-000000000002',
  $$ select public.registrar_dispositivo('fcm_token_antes_da_reinstalacao_01', 'ios') $$);
select set_config('frila.agora', '2026-08-22 12:00:00-03', true);
select pg_temp.como('c3000000-0000-4000-8000-000000000002',
  $$ select public.registrar_dispositivo('fcm_token_de_59_dias_sem_abrir_001', 'android') $$);
select set_config('frila.agora', '2026-10-20 12:00:00-03', true);
select pg_temp.como('c3000000-0000-4000-8000-000000000002',
  $$ select public.registrar_dispositivo('fcm_token_depois_da_reinstalacao_1', 'ios') $$);

select is(pg_temp.aparelhos('c3000000-0000-4000-8000-000000000002'), 3,
  'Antes da limpeza, a conta B tem o token antigo, o de 59 dias e o novo');

select is(privado.limpar_dispositivos_inativos(), 1,
  'A limpeza tira exatamente o token sem atualização há mais de 60 dias');

select is(
  (select array_agg(token_fcm order by token_fcm) from public.dispositivo
    where usuario_id = 'c3000000-0000-4000-8000-000000000002'),
  array['fcm_token_de_59_dias_sem_abrir_001', 'fcm_token_depois_da_reinstalacao_1'],
  'O token de 59 dias e o novo continuam; o de antes da reinstalação saiu');

select is(privado.limpar_dispositivos_inativos(), 0,
  'A limpeza é idempotente: a segunda rodada não tira nada');

-- Exatamente 60 dias ainda não é "há mais de 60 dias".
select set_config('frila.agora', '2026-10-21 12:00:00-03', true);
select is(privado.limpar_dispositivos_inativos(), 0,
  'Token com exatamente 60 dias sem atualização continua');

select set_config('frila.agora', '2026-10-21 12:00:01-03', true);
select is(privado.limpar_dispositivos_inativos(), 1,
  'Um segundo depois dos 60 dias, o token sai');

-- Reabrir o app renova o prazo: o token que o app reenvia não envelhece.
select set_config('frila.agora', '2026-12-19 12:00:00-03', true);
select pg_temp.como('c3000000-0000-4000-8000-000000000002',
  $$ select public.registrar_dispositivo('fcm_token_depois_da_reinstalacao_1', 'ios') $$);
select set_config('frila.agora', '2027-02-10 12:00:00-03', true);
select is(privado.limpar_dispositivos_inativos(), 1,
  'O token reenviado na abertura teve o prazo renovado; só o do iPad da conta A saiu');

select is(
  (select count(*)::int from public.dispositivo
    where token_fcm = 'fcm_token_depois_da_reinstalacao_1'),
  1,
  'O token que o app reenviou há menos de 60 dias continua');

-- ── 6. O agendamento da limpeza ───────────────────────────────────────────────

select is(
  (select count(*)::int from cron.job
    where jobname = 'limpar_dispositivos_inativos'
      and command = 'select privado.limpar_dispositivos_inativos()'),
  1,
  'A limpeza está agendada no pg_cron');

select is(
  (select schedule from cron.job where jobname = 'limpar_dispositivos_inativos'),
  '17 6 * * *',
  'A limpeza roda uma vez por dia, às 06:17 UTC');

select is(
  (select obj_description('privado.limpar_dispositivos_inativos()'::regprocedure, 'pg_proc')
          is not null),
  true,
  'privado.limpar_dispositivos_inativos tem comment on com a finalidade');

select * from finish();
rollback;
