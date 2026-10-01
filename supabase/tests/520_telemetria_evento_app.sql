-- Telemetria do piloto: eventos do funil e tabela evento_app (Cartão 3zsjXW60 · T-0017).
--
-- Cobre:
--   1. Estrutura, RLS e permissões de public.evento_app e public.registrar_evento
--   2. Validações da RPC (401 nao_autenticado, 422 campo_obrigatorio, 422 campo_invalido, 422 registro_no_futuro)
--   3. Registro dos 14 eventos do dicionário fechado (EventoDeTelemetria)
--   4. RN15: nenhum dado pessoal, coordenada ou campo livre na tabela
--   5. Retenção de 90 dias via privado.limpar_eventos_app e privado.executar_retencao_diaria
--   6. View metrica.eventos_app_por_dia excluindo contas de demonstração e equipe
--
-- Ids próprios começando em `3e000000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(42);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2027-03-01 12:00:00+00', true);

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

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create temp table ids as select
  '3e000000-0000-4000-8000-000000000001'::uuid as normal,
  '3e000000-0000-4000-8000-000000000002'::uuid as demo,
  '3e000000-0000-4000-8000-000000000003'::uuid as equipe,
  '3e000000-0000-4000-8000-000000000004'::uuid as contratante;

select pg_temp.autenticar((select normal from ids),      'normal@telemetria.test');
select pg_temp.autenticar((select demo from ids),        'demo@telemetria.test');
select pg_temp.autenticar((select equipe from ids),      'equipe@telemetria.test');
select pg_temp.autenticar((select contratante from ids), 'casa@telemetria.test');

select pg_temp.como((select normal from ids),
  $$ select public.criar_conta('profissional','Usuario Normal','+5561977770001','1995-01-01','2026-09-22') $$);
select pg_temp.como((select demo from ids),
  $$ select public.criar_conta('profissional','Usuario Demo','+5561977770002','1995-01-01','2026-09-22') $$);
select pg_temp.como((select equipe from ids),
  $$ select public.criar_conta('profissional','Usuario Equipe','+5561977770003','1995-01-01','2026-09-22') $$);
select pg_temp.como((select contratante from ids),
  $$ select public.criar_conta('contratante','Casa Telemetria','+5561977770004','1980-01-01','2026-09-22') $$);

update public.usuario set demonstracao = true where id = (select demo from ids);
insert into privado.conta_equipe (usuario_id) values ((select equipe from ids));

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

create temp table casa as
  select (pg_temp.como((select contratante from ids),
    $$ select public.cadastrar_estabelecimento('Bar da Telemetria','04252011000110','food_service',
         'CLN 308','{"latitude":-15.7900,"longitude":-47.8800}') $$)->>'id')::uuid as id;

create temp table vaga_teste as
  select (pg_temp.como((select contratante from ids), format(
    $$ select public.publicar_vaga(%L, %L, '2027-03-05 18:00:00+00'::timestamptz, '2027-03-06 00:00:00+00'::timestamptz,
         'CLN 308','{"latitude":-15.7900,"longitude":-47.8800}'::jsonb, 18000, 1, true, true, false,
         'Gerente','urgencia','3e000000-0000-4000-8000-0000000000aa'::uuid) $$,
    (select id from casa), (select garcom from fn)))->>'vaga_id')::uuid as id;

-- ── 1. Estrutura e Permissões ──────────────────────────────────────────────────

select has_type('public', 'evento_de_telemetria', 'enum public.evento_de_telemetria existe');

select has_table('public', 'evento_app', 'tabela public.evento_app existe');

select has_function('public', 'registrar_evento',
  array['text', 'uuid', 'uuid', 'timestamp with time zone'],
  'public.registrar_evento existe com a assinatura correta');

select is(
  has_function_privilege('authenticated', 'public.registrar_evento(text, uuid, uuid, timestamp with time zone)', 'execute'),
  true,
  'public.registrar_evento é executável por authenticated');

select is(
  has_function_privilege('anon', 'public.registrar_evento(text, uuid, uuid, timestamp with time zone)', 'execute'),
  false,
  'public.registrar_evento não é executável diretamente por anon');

select is(
  has_table_privilege('authenticated', 'public.evento_app', 'select'),
  false,
  'authenticated não tem select em public.evento_app (sem leitura para clientes)');

select is(
  has_table_privilege('authenticated', 'public.evento_app', 'insert'),
  false,
  'authenticated não tem insert direto em public.evento_app (apenas via RPC)');

select is(
  (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'evento_app'),
  true,
  'RLS está ativado em public.evento_app');

-- ── 2. Validações e Recusas da RPC ─────────────────────────────────────────────

select throws_ok(
  $$ select public.registrar_evento('app_aberto') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'registrar_evento sem token recusa 401 nao_autenticado');

select throws_ok(
  format($$ select pg_temp.como(%L, $$ select public.registrar_evento(null) $$) $$, (select normal from ids)),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'evento'),
  'registrar_evento com evento nulo recusa 422 campo_obrigatorio (details: evento)');

select throws_ok(
  format($$ select pg_temp.como(%L, $$ select public.registrar_evento('   ') $$) $$, (select normal from ids)),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'evento'),
  'registrar_evento com evento em branco recusa 422 campo_obrigatorio (details: evento)');

select throws_ok(
  format($$ select pg_temp.como(%L, $$ select public.registrar_evento('evento_inexistente') $$) $$, (select normal from ids)),
  'PGRST', pg_temp.erro('campo_invalido', 'evento'),
  'registrar_evento fora do enum recusa 422 campo_invalido (details: evento)');

select throws_ok(
  format($$ select pg_temp.como(%L, $$ select public.registrar_evento('app_aberto', ocorrido_em => '2027-03-01 13:00:00+00') $$) $$, (select normal from ids)),
  'PGRST', pg_temp.erro('registro_no_futuro'),
  'registrar_evento com ocorrido_em no futuro recusa 422 registro_no_futuro');

select throws_ok(
  format($$ select pg_temp.como(%L, $$ select public.registrar_evento('vaga_vista', vaga_id => '3e000000-0000-4000-8000-000000000099'::uuid) $$) $$, (select normal from ids)),
  'PGRST', pg_temp.erro('campo_invalido', 'vaga_id'),
  'registrar_evento com vaga_id inexistente recusa 422 campo_invalido (details: vaga_id)');

select throws_ok(
  format($$ select pg_temp.como(%L, $$ select public.registrar_evento('checkin_tentado', turno_id => '3e000000-0000-4000-8000-000000000099'::uuid) $$) $$, (select normal from ids)),
  'PGRST', pg_temp.erro('campo_invalido', 'turno_id'),
  'registrar_evento com turno_id inexistente recusa 422 campo_invalido (details: turno_id)');

-- ── 3. Caminho Feliz e Registro dos Eventos ─────────────────────────────────────

select is(
  (pg_temp.como((select normal from ids), $$ select public.registrar_evento('app_aberto') $$)->>'registrado')::boolean,
  true,
  'registrar_evento app_aberto devolve registrado: true');

select is(
  (select count(*)::int from public.evento_app
    where usuario_id = (select normal from ids) and evento = 'app_aberto'),
  1,
  'evento gravado em public.evento_app com usuario_id correto');

select is(
  (pg_temp.como((select normal from ids), format(
    $$ select public.registrar_evento('vaga_vista', vaga_id => %L, ocorrido_em => '2027-03-01 11:30:00+00'::timestamptz) $$,
    (select id from vaga_teste)))->>'registrado')::boolean,
  true,
  'registrar_evento vaga_vista com vaga_id e ocorrido_em passado devolve registrado: true');

select is(
  (select count(*)::int from public.evento_app
    where usuario_id = (select normal from ids)
      and evento = 'vaga_vista'
      and vaga_id = (select id from vaga_teste)
      and ocorrido_em = '2027-03-01 11:30:00+00'::timestamptz),
  1,
  'ocorrido_em do cliente preservado com sucesso');

-- Prova que todos os 14 eventos do dicionário são aceitos
select lives_ok(
  format($$ select pg_temp.como(%L, format('select public.registrar_evento(%%L)', evento)) $$, (select normal from ids)),
  format('evento %s do dicionário é registrado com sucesso', evento))
from unnest(array[
  'cadastro_concluido',
  'permissao_push_negada',
  'vaga_detalhe_aberto',
  'candidatura_enviada',
  'candidatura_retirada',
  'checkin_tentado',
  'checkin_concluido',
  'checkout_concluido',
  'avaliacao_enviada',
  'contato_aberto',
  'acao_enfileirada_offline',
  'atualizacao_obrigatoria_exibida'
]) as evento;

-- ── 4. RN15: Proteção de Dados e Estrutura Rígida ─────────────────────────────

select is(
  (select count(*)::int from information_schema.columns
    where table_schema = 'public' and table_name = 'evento_app'
      and column_name in ('email', 'telefone', 'coordenada', 'latitude', 'longitude', 'texto', 'payload', 'detalhes')),
  0,
  'RN15: nenhum campo de texto livre, contato ou coordenada em public.evento_app');

-- ── 5. Retenção de 90 dias ─────────────────────────────────────────────────────

select has_function('privado', 'limpar_eventos_app', array['integer'],
  'privado.limpar_eventos_app existe');

-- Insere evento antigo com 95 dias
insert into public.evento_app (usuario_id, evento, ocorrido_em, criado_em)
values ((select normal from ids), 'app_aberto', '2026-11-20 12:00:00+00', '2026-11-20 12:00:00+00');

select is(
  (select count(*)::int from public.evento_app where criado_em < '2027-03-01 12:00:00+00'::timestamptz - interval '90 days'),
  1,
  'evento antigo de teste existe antes da limpeza');

select is(
  privado.limpar_eventos_app(90),
  1,
  'privado.limpar_eventos_app remove exatamente 1 evento com mais de 90 dias');

select is(
  (select count(*)::int from public.evento_app where criado_em < '2027-03-01 12:00:00+00'::timestamptz - interval '90 days'),
  0,
  'nenhum evento com mais de 90 dias permanece');

select lives_ok(
  $$ select privado.executar_retencao_diaria() $$,
  'privado.executar_retencao_diaria roda e inclui a limpeza de telemetria');

-- ── 6. View de Métricas (sem demo e sem equipe) ───────────────────────────────

-- Registra evento para demo e equipe
select pg_temp.como((select demo from ids), $$ select public.registrar_evento('app_aberto') $$);
select pg_temp.como((select equipe from ids), $$ select public.registrar_evento('app_aberto') $$);

select is(
  (select count(*)::int from public.evento_app where evento = 'app_aberto'),
  3,
  '3 eventos app_aberto registrados no total (1 normal, 1 demo, 1 equipe)');

select is(
  (select total::int from metrica.eventos_app_por_dia where dia = '2027-03-01' and evento = 'app_aberto'),
  1,
  'metrica.eventos_app_por_dia contabiliza apenas 1 evento (exclui demo e equipe)');

select * from finish();
rollback;
