-- 15 recusas criticas do contrato lote 9 (08/10/2026).
--
-- Cobertura de regras de negócio (422 regras de incompatibilidade de perfil e 401 perímetro de autenticação):
-- 1.  criteriosDeNotificacao (422 perfil_incompativel)
-- 2.  incluirNaEquipe (422 perfil_incompativel)
-- 3.  removerDaEquipe (422 perfil_incompativel)
-- 4.  minhaConta (401 nao_autenticado)
-- 5.  meuPerfilProfissional (401 nao_autenticado)
-- 6.  atualizarPerfilProfissional (401 nao_autenticado)
-- 7.  criarPerfilProfissional (401 nao_autenticado)
-- 8.  cadastrarEstabelecimento (401 nao_autenticado)
-- 9.  criteriosDeNotificacao (401 nao_autenticado)
-- 10. incluirNaEquipe (401 nao_autenticado)
-- 11. removerDaEquipe (401 nao_autenticado)
-- 12. perfilPublico (401 nao_autenticado)
-- 13. registrarDispositivo (401 nao_autenticado)
-- 14. removerDispositivo (401 nao_autenticado)
-- 15. registrarEvento (401 nao_autenticado)
--
-- Ids próprios começando em `c4940000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(15);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

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

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create temp table ids as select
  'c4940000-0000-4000-8000-000000000001'::uuid as usuario_contratante_id,
  'c4940000-0000-4000-8000-000000000002'::uuid as usuario_profissional_id;

select pg_temp.autenticar((select usuario_contratante_id from ids), 'contratante494@test.local');
select pg_temp.autenticar((select usuario_profissional_id from ids), 'profissional494@test.local');

select pg_temp.como((select usuario_contratante_id from ids),
  $$ select public.criar_conta('contratante','Contratante 494','+5561911114941','1985-01-01','2026-09-22') $$);

select pg_temp.como((select usuario_profissional_id from ids),
  $$ select public.criar_conta('profissional','Profissional 494','+5561911114942','1990-01-01','2026-09-22') $$);

-- 1. criteriosDeNotificacao: 422 perfil_incompativel (chamador contratante)
select throws_ok(
  pg_temp.por((select usuario_contratante_id from ids),
    $$ select public.criterios_de_notificacao() $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  '1. criteriosDeNotificacao com perfil contratante recusa 422 perfil_incompativel'
);

-- 2. incluirNaEquipe: 422 perfil_incompativel (chamador profissional)
select throws_ok(
  pg_temp.por((select usuario_profissional_id from ids),
    $$ select public.incluir_na_equipe('c4940000-0000-4000-8000-000000000001'::uuid, 'c4940000-0000-4000-8000-000000000002'::uuid) $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  '2. incluirNaEquipe com perfil profissional recusa 422 perfil_incompativel'
);

-- 3. removerDaEquipe: 422 perfil_incompativel (chamador profissional)
select throws_ok(
  pg_temp.por((select usuario_profissional_id from ids),
    $$ select public.remover_da_equipe('c4940000-0000-4000-8000-000000000001'::uuid, 'c4940000-0000-4000-8000-000000000002'::uuid) $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  '3. removerDaEquipe com perfil profissional recusa 422 perfil_incompativel'
);

-- 4. minhaConta: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.minha_conta() $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '4. minhaConta sem token recusa 401 nao_autenticado'
);

-- 5. meuPerfilProfissional: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.meu_perfil_profissional() $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '5. meuPerfilProfissional sem token recusa 401 nao_autenticado'
);

-- 6. atualizarPerfilProfissional: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.atualizar_perfil_profissional(ponto_base => '{"latitude":-15.7901,"longitude":-47.8851}'::jsonb) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '6. atualizarPerfilProfissional sem token recusa 401 nao_autenticado'
);

-- 7. criarPerfilProfissional: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.criar_perfil_profissional(array[]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '7. criarPerfilProfissional sem token recusa 401 nao_autenticado'
);

-- 8. cadastrarEstabelecimento: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.cadastrar_estabelecimento('Casa Sem Token','29979036000140','food_service','CLN 108','{"latitude":-15.7905,"longitude":-47.8855}') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '8. cadastrarEstabelecimento sem token recusa 401 nao_autenticado'
);

-- 9. criteriosDeNotificacao: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.criterios_de_notificacao() $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '9. criteriosDeNotificacao sem token recusa 401 nao_autenticado'
);

-- 10. incluirNaEquipe: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.incluir_na_equipe('c4940000-0000-4000-8000-000000000001'::uuid, 'c4940000-0000-4000-8000-000000000002'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '10. incluirNaEquipe sem token recusa 401 nao_autenticado'
);

-- 11. removerDaEquipe: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.remover_da_equipe('c4940000-0000-4000-8000-000000000001'::uuid, 'c4940000-0000-4000-8000-000000000002'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '11. removerDaEquipe sem token recusa 401 nao_autenticado'
);

-- 12. perfilPublico: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.perfil_publico('c4940000-0000-4000-8000-000000000001'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '12. perfilPublico sem token recusa 401 nao_autenticado'
);

-- 13. registrarDispositivo: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.registrar_dispositivo('fcm_token_teste_harness_contrato_anon_1234', 'ios') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '13. registrarDispositivo sem token recusa 401 nao_autenticado'
);

-- 14. removerDispositivo: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.remover_dispositivo('fcm_token_teste_harness_contrato_anon_1234') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '14. removerDispositivo sem token recusa 401 nao_autenticado'
);

-- 15. registrarEvento: 401 nao_autenticado (chamador sem sessão / anonimo)
select throws_ok(
  $$ select public.registrar_evento('app_aberto') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  '15. registrarEvento sem token recusa 401 nao_autenticado'
);

rollback;
