-- 15 recusas criticas do contrato lote 5 (06/10/2026).
--
-- Cobre os 15 pares de recusa do Lote 5:
-- 1.  pedirRevisaoDespacho (409 contestacao_ja_aberta)
-- 2.  avaliar (422 campo_obrigatorio)
-- 3.  criteriosDeNotificacao (403 sem_permissao)
-- 4.  criteriosDeNotificacao (404 nao_encontrado)
-- 5.  meusEstabelecimentos (403 sem_permissao)
-- 6.  registrarDispositivo (422 campo_obrigatorio)
-- 7.  pedirRevisaoDespacho (422 campo_obrigatorio)
-- 8.  cadastrarEstabelecimento (422 perfil_incompativel)
-- 9.  atualizarPerfilProfissional (422 campo_obrigatorio)
-- 10. publicarVaga (422 campo_obrigatorio)
-- 11. escolherCandidato (422 campo_obrigatorio)
-- 12. cancelarVaga (422 campo_obrigatorio)
-- 13. cancelarPosicao (422 campo_obrigatorio)
-- 14. fazerCheckin (422 campo_obrigatorio)
-- 15. fazerCheckout (422 campo_obrigatorio)
--
-- Ids proprios comecando em `c4890000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(15);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2027-05-01 12:00:00+00', true);

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
  'c4890000-0000-4000-8000-000000000001'::uuid as contratante_dono,
  'c4890000-0000-4000-8000-000000000002'::uuid as contratante_outro,
  'c4890000-0000-4000-8000-000000000003'::uuid as profissional_ativo,
  'c4890000-0000-4000-8000-000000000004'::uuid as profissional_suspenso,
  'c4890000-0000-4000-8000-000000000005'::uuid as usuario_sem_perfil;

select pg_temp.autenticar((select contratante_dono from ids), 'dono489@frila.test');
select pg_temp.autenticar((select contratante_outro from ids), 'outro489@frila.test');
select pg_temp.autenticar((select profissional_ativo from ids), 'ativo489@frila.test');
select pg_temp.autenticar((select profissional_suspenso from ids), 'suspenso489@frila.test');
select pg_temp.autenticar((select usuario_sem_perfil from ids), 'semperfil489@frila.test');

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values
  ((select contratante_dono from ids), 'contratante', 'Contratante Dono', '+5561999991001', 'dono489@frila.test', '1985-01-01', '1.0', now(), 'ativa'),
  ((select contratante_outro from ids), 'contratante', 'Contratante Outro', '+5561999991002', 'outro489@frila.test', '1988-02-02', '1.0', now(), 'suspensa'),
  ((select profissional_ativo from ids), 'profissional', 'Profissional Ativo', '+5561999991003', 'ativo489@frila.test', '1995-03-03', '1.0', now(), 'ativa'),
  ((select profissional_suspenso from ids), 'profissional', 'Profissional Suspenso', '+5561999991004', 'suspenso489@frila.test', '1996-04-04', '1.0', now(), 'suspensa'),
  ((select usuario_sem_perfil from ids), 'profissional', 'Profissional Sem Perfil', '+5561999991005', 'semperfil489@frila.test', '1997-05-05', '1.0', now(), 'ativa');

create temp table fn as select (select id from public.funcao where nome = 'garçom') as garcom;

select pg_temp.como((select profissional_ativo from ids), format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[], '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$,
  (select garcom from fn)));

-- Estabelecimento gerenciado por contratante_dono
create temp table casa1 as select (
  pg_temp.como((select contratante_dono from ids),
    $$ select public.cadastrar_estabelecimento('Casa Principal 489','04252011000110','food_service','CLN 108','{"latitude":-15.7905,"longitude":-47.8855}') $$)
)->>'id' as id;

-- 1. pedirRevisaoDespacho: 409 contestacao_ja_aberta (segunda contestacao pelo mesmo autor)
-- Primeira contestação registra normalmente
select pg_temp.como((select profissional_ativo from ids),
  $$ select public.pedir_revisao_despacho('Primeira contestacao de revisao de despacho com tamanho valido.') $$);

select throws_ok(
  pg_temp.por((select profissional_ativo from ids),
    $$ select public.pedir_revisao_despacho('Segunda tentativa de contestacao de despacho enquanto anterior existe.') $$),
  'PGRST',
  pg_temp.erro('contestacao_ja_aberta'),
  '1. pedirRevisaoDespacho: 409 contestacao_ja_aberta na segunda contestacao pelo mesmo autor'
);

-- 2. avaliar: 422 campo_obrigatorio (turno_id nulo)
select throws_ok(
  pg_temp.por((select profissional_ativo from ids),
    $$ select public.avaliar(null, true) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'turno_id'),
  '2. avaliar: 422 campo_obrigatorio quando turno_id e nulo'
);

-- 3. criteriosDeNotificacao: 403 sem_permissao (profissional suspenso tentando ler criterios)
select throws_ok(
  pg_temp.por((select profissional_suspenso from ids),
    $$ select public.criterios_de_notificacao() $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '3. criteriosDeNotificacao: 403 sem_permissao quando conta esta suspensa'
);

-- 4. criteriosDeNotificacao: 404 nao_encontrado (profissional ativo sem perfil criado)
select throws_ok(
  pg_temp.por((select usuario_sem_perfil from ids),
    $$ select public.criterios_de_notificacao() $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  '4. criteriosDeNotificacao: 404 nao_encontrado quando profissional nao possui perfil'
);

-- 5. meusEstabelecimentos: 403 sem_permissao (contratante suspenso tentando listar estabelecimentos)
select throws_ok(
  pg_temp.por((select contratante_outro from ids),
    $$ select public.meus_estabelecimentos() $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  '5. meusEstabelecimentos: 403 sem_permissao quando conta esta suspensa'
);

-- 6. registrarDispositivo: 422 campo_obrigatorio (token_fcm nulo)
select throws_ok(
  pg_temp.por((select profissional_ativo from ids),
    $$ select public.registrar_dispositivo(null, 'ios') $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'token_fcm'),
  '6. registrarDispositivo: 422 campo_obrigatorio quando token_fcm e nulo'
);

-- 7. pedirRevisaoDespacho: 422 campo_obrigatorio (relato nulo)
select throws_ok(
  pg_temp.por((select usuario_sem_perfil from ids),
    $$ select public.pedir_revisao_despacho(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'relato'),
  '7. pedirRevisaoDespacho: 422 campo_obrigatorio quando relato e nulo'
);

-- 8. cadastrarEstabelecimento: 422 perfil_incompativel (conta profissional tentando cadastrar estabelecimento)
select throws_ok(
  pg_temp.por((select profissional_ativo from ids),
    $$ select public.cadastrar_estabelecimento('Casa Incompativel', '29979036000140', 'food_service',
         'CLN 108', '{"latitude":-15.7905,"longitude":-47.8855}'::jsonb) $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  '8. cadastrarEstabelecimento: 422 perfil_incompativel quando chamado por profissional'
);

-- 9. atualizarPerfilProfissional: 422 campo_obrigatorio (funcoes vazias)
select throws_ok(
  pg_temp.por((select profissional_ativo from ids),
    $$ select public.atualizar_perfil_profissional(array[]::uuid[], null, null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'funcoes'),
  '9. atualizarPerfilProfissional: 422 campo_obrigatorio quando funcoes vem vazio'
);

-- 10. publicarVaga: 422 campo_obrigatorio (funcao_id nula)
select throws_ok(
  pg_temp.por((select contratante_dono from ids), format(
    $$ select public.publicar_vaga(%L::uuid, null, '2027-05-20 18:00:00+00'::timestamptz, '2027-05-20 23:00:00+00'::timestamptz,
         'CLN 108', '{"latitude":-15.7905,"longitude":-47.8855}'::jsonb, 15000::bigint, 1, true, false, false,
         'Garçom', 'urgencia'::public.modo_preenchimento, gen_random_uuid()) $$,
    (select id::uuid from casa1))),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'funcao_id'),
  '10. publicarVaga: 422 campo_obrigatorio quando funcao_id e nula'
);

-- 11. escolherCandidato: 422 campo_obrigatorio (candidatura_id nula)
select throws_ok(
  pg_temp.por((select contratante_dono from ids),
    $$ select public.escolher_candidato(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'candidatura_id'),
  '11. escolherCandidato: 422 campo_obrigatorio quando candidatura_id e nula'
);

-- 12. cancelarVaga: 422 campo_obrigatorio (vaga_id nula)
select throws_ok(
  pg_temp.por((select contratante_dono from ids),
    $$ select public.cancelar_vaga(null, 'motivo valido') $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'vaga_id'),
  '12. cancelarVaga: 422 campo_obrigatorio quando vaga_id e nula'
);

-- 13. cancelarPosicao: 422 campo_obrigatorio (posicao_id nula)
select throws_ok(
  pg_temp.por((select contratante_dono from ids),
    $$ select public.cancelar_posicao(null, 'motivo valido') $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'posicao_id'),
  '13. cancelarPosicao: 422 campo_obrigatorio quando posicao_id e nula'
);

-- 14. fazerCheckin: 422 campo_obrigatorio (turno_id nulo)
select throws_ok(
  pg_temp.por((select profissional_ativo from ids),
    $$ select public.fazer_checkin(null, 40, '2027-05-10 18:05:00+00'::timestamptz) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'turno_id'),
  '14. fazerCheckin: 422 campo_obrigatorio quando turno_id e nulo'
);

-- 15. fazerCheckout: 422 campo_obrigatorio (turno_id nulo)
select throws_ok(
  pg_temp.por((select profissional_ativo from ids),
    $$ select public.fazer_checkout(null, 40, '2027-05-10 23:05:00+00'::timestamptz) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'turno_id'),
  '15. fazerCheckout: 422 campo_obrigatorio quando turno_id e nulo'
);

select * from finish();
rollback;
