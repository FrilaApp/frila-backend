-- Auditoria de segurança de 30/09: o que ela achou, medido.
--
-- Dois achados, e os dois foram provados contra o banco antes de virar teste.
--
-- 1. O `privado` executável por quem não precisa. A migração de 22/09 deu `execute` em
--    todas as funções do `privado` a `authenticated`, e as funções criadas depois sem
--    `revoke` explícito nasceram executáveis por PUBLIC — `anon` incluído. Entre elas
--    `contato_do_profissional`, que devolve o telefone de qualquer profissional pelo id da
--    posição, e `gravar_funcoes` e `gravar_disponibilidade`, que reescrevem o perfil de
--    qualquer profissional pelo id. Hoje nada disso é alcançável: o PostgREST e o GraphQL
--    só expõem `public`. É uma linha de configuração de distância — expor o `privado` no
--    painel — de virar vazamento de telefone e escrita em perfil alheio. Quem precisa de
--    `execute` como `authenticated` são só as doze funções que as políticas de RLS chamam,
--    porque a política roda com a identidade de quem lê.
--
-- 2. A presença confirmada numa posição cancelada. O profissional faz check-in manual,
--    desiste (`cancelar_posicao`, que não olha o check-in) e a casa confirma o check-in
--    depois: o turno da posição cancelada, com falta, virava `verificado`. A mesma posição
--    contava como presença e como falta na taxa (0,5 em vez de 0), e abria avaliação de um
--    turno que não aconteceu. O check-in já era recusado em posição cancelada pelo gatilho
--    `turno_checkin_nunca_em_posicao_cancelada`; a confirmação não.
--
-- Ids próprios, começando em `ae480000`.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(14);

-- ── 1. O privado fechado ──────────────────────────────────────────────────────

-- As que as políticas chamam. A lista é derivada de `pg_policies` e conferida aqui pelo
-- nome: uma política nova que chame outra função do `privado` falha este teste e obriga
-- quem a escreveu a decidir, em vez de herdar a concessão.
create temp table funcoes_das_politicas as
  select unnest(array[
    'bloqueado_com_estabelecimento', 'candidatou_na_vaga', 'eh_membro',
    'estabelecimento_da_posicao', 'estabelecimento_da_vaga', 'lado_da_posicao',
    'mesma_populacao', 'meu_profissional_id', 'ocupa_posicao_na_vaga',
    'perfil_da_conta', 'usuario_do_profissional', 'vaga_oculta']) as nome;

select is(
  (select array_agg(distinct m[1] order by m[1])
     from pg_policies, regexp_matches(coalesce(qual, '') || ' ' || coalesce(with_check, ''),
                                      'privado\.(\w+)', 'g') m),
  (select array_agg(nome order by nome) from funcoes_das_politicas),
  'as políticas de RLS chamam exatamente as doze funções do privado da lista');

select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado'
      and has_function_privilege('authenticated', p.oid, 'execute')
      and p.proname not in (select nome from funcoes_das_politicas)),
  null,
  'authenticated não executa nenhuma função do privado além das que as políticas chamam');

select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado'
      and has_function_privilege('authenticated', p.oid, 'execute')),
  (select array_agg(nome order by nome) from funcoes_das_politicas),
  'as doze funções das políticas continuam executáveis por authenticated (o RLS depende delas)');

select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado'
      and has_function_privilege('anon', p.oid, 'execute')),
  null,
  'anon não executa nenhuma função do privado');

select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado'
      and (p.proacl is null or p.proacl::text like '%"=X/%' or p.proacl::text like '%,=X/%'
           or p.proacl::text like '{=X/%')),
  null,
  'nenhuma função do privado é executável por PUBLIC, nem pela concessão padrão');

-- A função que nascer amanhã sem `revoke` não pode voltar ao estado de antes.
create function privado.nasce_depois_da_auditoria() returns int
language sql set search_path = '' as $$ select 1 $$;

select ok(
  not has_function_privilege('authenticated', 'privado.nasce_depois_da_auditoria()', 'execute')
  and not has_function_privilege('anon', 'privado.nasce_depois_da_auditoria()', 'execute'),
  'função nova no privado nasce sem execute para PUBLIC (privilégio padrão do schema)');

drop function privado.nasce_depois_da_auditoria();

-- O que a concessão abria, tentado como authenticated.
create function pg_temp.tentar_como_authenticated(sql text) returns void
language plpgsql as $$
declare
  v_fn text;
  v_oid oid;
begin
  v_fn := (regexp_match(sql, 'privado\.(\w+)'))[1];
  if v_fn is not null then
    select p.oid into v_oid
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'privado' and p.proname = v_fn
     limit 1;
    if v_oid is not null and not has_function_privilege('authenticated', v_oid, 'execute') then
      raise exception using errcode = '42501', message = 'permission denied for function ' || v_fn;
    end if;
  end if;
  set local role authenticated;
  execute sql;
  reset role;
exception when others then
  reset role;
  raise;
end $$;

select throws_ok(
  format('select pg_temp.tentar_como_authenticated(%L)',
         $$select privado.contato_do_profissional('ae480000-0000-4000-8000-000000000999')$$),
  '42501', null,
  'authenticated não lê o telefone de um profissional por privado.contato_do_profissional');

select throws_ok(
  format('select pg_temp.tentar_como_authenticated(%L)',
         $$select privado.gravar_funcoes('ae480000-0000-4000-8000-000000000999', array[]::uuid[])$$),
  '42501', null,
  'authenticated não reescreve as funções de outro profissional por privado.gravar_funcoes');

select throws_ok(
  format('select pg_temp.tentar_como_authenticated(%L)',
         $$select privado.gravar_disponibilidade('ae480000-0000-4000-8000-000000000999', '[]'::jsonb)$$),
  '42501', null,
  'authenticated não reescreve a grade de outro profissional por privado.gravar_disponibilidade');

-- ── 2. A confirmação que não pode acontecer ───────────────────────────────────

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

select pg_temp.autenticar('ae480000-0000-4000-8000-0000000000d1', 'dona@auditoria.test');
select pg_temp.autenticar('ae480000-0000-4000-8000-0000000000e1', 'e1@auditoria.test');

select pg_temp.como('ae480000-0000-4000-8000-0000000000d1',
  $$ select public.criar_conta('contratante','Dona da Auditoria','+5561944480001','1980-01-01','2026-09-22') $$);
select pg_temp.como('ae480000-0000-4000-8000-0000000000e1',
  $$ select public.criar_conta('profissional','Auditado Um','+5561944480011','1995-01-01','2026-09-22') $$);
select pg_temp.como('ae480000-0000-4000-8000-0000000000e1', format(
  $$ select public.criar_perfil_profissional(array[%L]::uuid[],
       '{"latitude":-15.7900,"longitude":-47.8850}'::jsonb) $$,
  (select id from public.funcao where nome = 'garçom')));

create temp table casa as
  select (pg_temp.como('ae480000-0000-4000-8000-0000000000d1',
    $$ select public.cadastrar_estabelecimento('Casa da Auditoria','11222333000181','food_service',
         'SCLN 407','{"latitude":-15.7910,"longitude":-47.8860}') $$)->>'id')::uuid as id;

create temp table quando as
  select (privado.agora() + interval '2 days')         as ini,
         (privado.agora() + interval '2 days 6 hours') as fim;

create temp table t as
  select (pg_temp.como('ae480000-0000-4000-8000-0000000000e1', format(
            $$ select public.candidatar(%L) $$,
            (pg_temp.como('ae480000-0000-4000-8000-0000000000d1', format(
               $sql$ select public.publicar_vaga(%L, %L, %L, %L, 'CLN 407',
                    '{"latitude":-15.7910,"longitude":-47.8860}'::jsonb,
                    18000, 1, true, true, false, 'Seu Zé', 'urgencia',
                    'ae480000-0000-4000-8000-000000000001') $sql$,
               (select id from casa), (select id from public.funcao where nome = 'garçom'),
               (select ini from quando), (select fim from quando)))->>'vaga_id')))->>'turno_id')::uuid as id;

insert into privado.ambiente (id, eh_teste) values (true, true) on conflict do nothing;
select set_config('frila.agora', (select (ini + interval '10 minutes')::text from quando), true);

-- Check-in manual (longe), e a desistência depois dele.
select pg_temp.como('ae480000-0000-4000-8000-0000000000e1', format(
  $$ select public.fazer_checkin(%L, 5000, %L) $$,
  (select id from t), (select ini + interval '10 minutes' from quando)));
select pg_temp.como('ae480000-0000-4000-8000-0000000000e1', format(
  $$ select public.cancelar_posicao(%L, 'imprevisto de família') $$,
  (select posicao_id from public.turno where id = (select id from t))));

select is(
  (select p.estado::text || '/' || tu.verificacao::text
     from public.turno tu join public.posicao p on p.id = tu.posicao_id
    where tu.id = (select id from t)),
  'cancelada/nao_verificado',
  'pré-condição: a posição foi cancelada depois do check-in manual, e o turno saiu nao_verificado');

select throws_ok(
  format($$ select pg_temp.como('ae480000-0000-4000-8000-0000000000d1',
             $sql$ select public.confirmar_checkin_manual('%s') $sql$) $$, (select id from t)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : "posicao_cancelada", "hint" : null}',
  'RN22: a casa não confirma o check-in manual de uma posição cancelada (409 vaga_encerrada)');

select is(
  (select verificacao::text from public.turno where id = (select id from t)),
  'nao_verificado',
  'o turno da posição cancelada continua nao_verificado');

select is(
  (select pr.turnos_realizados::text || '/' || coalesce(pr.taxa_comparecimento::text, 'nula')
     from public.profissional pr
    where pr.usuario_id = 'ae480000-0000-4000-8000-0000000000e1'),
  '0/0.000',
  'a falta conta sozinha: nenhuma presença fabricada na taxa de comparecimento');

-- A escrita direta de serviço (sem a RPC) também é recusada: a trava é do dado.
select throws_ok(
  format($$ update public.turno set verificacao = 'verificado' where id = %L $$, (select id from t)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : "posicao_cancelada", "hint" : null}',
  'nem a escrita direta marca verificado o turno de uma posição cancelada');

select set_config('frila.agora', '', true);

select * from finish();
rollback;
