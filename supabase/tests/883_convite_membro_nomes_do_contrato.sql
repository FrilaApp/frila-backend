-- 883_convite_membro_nomes_do_contrato.sql
--
-- convidar_membro, aceitar_convite_membro, remover_membro e transferir_administracao com os nomes de
-- parâmetro do CONTRATO (B-052, migração 20261117120000). O PostgREST chama a RPC pelos nomes do corpo
-- JSON, como `convidar_membro(estabelecimento_id := ..., email := ..., papel := ...)`; com
-- p_estabelecimento_id, p_email, p_papel, p_token, p_membro_id e p_novo_admin_id a chamada dava 404
-- PGRST202. Aqui as quatro são chamadas por nome (=>), do jeito do PostgREST, e os nomes antigos não
-- existem mais.
--
--   assinatura: nomes e tipos dos parâmetros · os nomes antigos (p_*) não existem · chamada por p_* falha
--   convidar_membro (nomeada): 200 com token · 401 sem sessão · 403 não administrador · 404 casa inexistente
--                              · 422 e-mail inválido · 422 papel ausente
--   aceitar_convite_membro (nomeada): 200 vira membro · 401 sem sessão · 422 perfil_incompativel
--                              · 422 convite_invalido (token já usado e token vazio)
--   remover_membro (nomeada): 401 · 403 · 404 · 422 ultimo_administrador · 200 removido
--   transferir_administracao (nomeada): 401 · 403 · 404 · 200 promovido
-- Só dados sintéticos.
begin;
select plan(31);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local "frila.agora" = '2026-11-17 15:00:00+00';

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

-- A recusa por inteiro: o envelope de public.erro (message) mais o status (detail).
create function pg_temp.erro(conta uuid, sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  if conta is null then
    execute 'set local role authenticated';
    execute 'set local request.jwt.claims = ''{"role":"authenticated"}''';
    execute sql;
  else
    perform pg_temp.como(conta, sql);
  end if;
  return null;
exception when others then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return msg::jsonb || det::jsonb;
end $$;

insert into auth.users (id, email) values
  ('88300000-0000-4000-8000-000000000001', 'admin.883@teste.invalid'),
  ('88300000-0000-4000-8000-000000000002', 'novo.883@teste.invalid'),
  ('88300000-0000-4000-8000-000000000003', 'prof.883@teste.invalid'),
  ('88300000-0000-4000-8000-000000000004', 'alheio.883@teste.invalid');

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em, estado) values
  ('88300000-0000-4000-8000-000000000001', 'contratante',  'Admin 883',   'admin.883@teste.invalid',  '+5561955508831', '1985-01-01', '1.0', now(), 'ativa'),
  ('88300000-0000-4000-8000-000000000002', 'contratante',  'Novo 883',    'novo.883@teste.invalid',   '+5561955508832', '1990-02-02', '1.0', now(), 'ativa'),
  ('88300000-0000-4000-8000-000000000003', 'profissional', 'Prof 883',    'prof.883@teste.invalid',   '+5561955508833', '1995-03-03', '1.0', now(), 'ativa'),
  ('88300000-0000-4000-8000-000000000004', 'contratante',  'Alheio 883',  'alheio.883@teste.invalid', '+5561955508834', '1992-04-04', '1.0', now(), 'ativa');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('88300000-0000-4000-8000-000000000030', '88300000-0000-4000-8000-000000000003', 'POINT(-47.8822 -15.7942)'::extensions.geography);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('88300000-0000-4000-8000-0000000000e1', 'Bar Central 883', '88311222000199', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('88300000-0000-4000-8000-0000000000e1', '88300000-0000-4000-8000-000000000001', 'administrador');

-- ── 1. Assinaturas: os nomes do contrato ──────────────────────────────────────

select is(
  (select proargnames from pg_proc where oid = 'public.convidar_membro(uuid, text, public.papel_membro)'::regprocedure),
  array['estabelecimento_id', 'email', 'papel'],
  'convidar_membro tem os parâmetros estabelecimento_id, email e papel (os do contrato)'
);

select is(
  (select proargnames from pg_proc where oid = 'public.aceitar_convite_membro(text)'::regprocedure),
  array['token'],
  'aceitar_convite_membro tem o parâmetro token (o do contrato)'
);

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in ('convidar_membro', 'aceitar_convite_membro', 'remover_membro', 'transferir_administracao')
      and p.proargnames && array['p_estabelecimento_id', 'p_email', 'p_papel', 'p_token', 'p_membro_id', 'p_novo_admin_id']),
  0,
  'os nomes antigos (p_estabelecimento_id, p_email, p_papel, p_token) não existem mais em nenhuma versão'
);

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('convidar_membro', 'aceitar_convite_membro', 'remover_membro', 'transferir_administracao')),
  4,
  'sobrou uma função de cada, sem versão velha ao lado'
);

select throws_ok(
  $$ select public.convidar_membro(p_estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                   p_email => 'x@teste.invalid', p_papel => 'operador') $$,
  '42883', null,
  'chamar convidar_membro pelos nomes antigos falha: função inexistente'
);

select throws_ok(
  $$ select public.aceitar_convite_membro(p_token => 'qualquer') $$,
  '42883', null,
  'chamar aceitar_convite_membro pelo nome antigo falha: função inexistente'
);

select is(
  (select proargnames from pg_proc where oid = 'public.remover_membro(uuid, uuid)'::regprocedure),
  array['estabelecimento_id', 'membro_id'],
  'remover_membro tem os parâmetros estabelecimento_id e membro_id (os do contrato)'
);

select is(
  (select proargnames from pg_proc where oid = 'public.transferir_administracao(uuid, uuid)'::regprocedure),
  array['estabelecimento_id', 'novo_admin_id'],
  'transferir_administracao tem os parâmetros estabelecimento_id e novo_admin_id (os do contrato)'
);

select throws_ok(
  $$ select public.remover_membro(p_estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                  p_membro_id => '88300000-0000-4000-8000-000000000001'::uuid) $$,
  '42883', null,
  'chamar remover_membro pelos nomes antigos falha: função inexistente'
);

select throws_ok(
  $$ select public.transferir_administracao(p_estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                            p_novo_admin_id => '88300000-0000-4000-8000-000000000002'::uuid) $$,
  '42883', null,
  'chamar transferir_administracao pelos nomes antigos falha: função inexistente'
);

-- ── 2. convidar_membro, chamada nomeada como o PostgREST faz ──────────────────

create temp table conv as
  select pg_temp.como('88300000-0000-4000-8000-000000000001',
    $$ select public.convidar_membro(
         estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
         email => 'Novo.883@teste.invalid',
         papel => 'operador') $$) as r;

select is(
  length((select r->>'token' from conv)) = 64
    and (select r->>'email' from conv) = 'novo.883@teste.invalid'
    and (select r->>'papel' from conv) = 'operador'
    and (select r->>'estabelecimento_id' from conv) = '88300000-0000-4000-8000-0000000000e1',
  true,
  '200: administrador convida pelos nomes do contrato e recebe token de 64 hex, e-mail em minúsculas, papel e casa'
);

select is(
  (select count(*)::int from privado.convite_membro
    where id = ((select r from conv)->>'convite_id')::uuid
      and estabelecimento_id = '88300000-0000-4000-8000-0000000000e1'
      and email = 'novo.883@teste.invalid' and papel = 'operador' and usado_em is null),
  1,
  'o convite ficou gravado com a casa, o e-mail e o papel enviados'
);

select is(
  (pg_temp.erro(null,
    $$ select public.convidar_membro(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                     email => 'x@teste.invalid', papel => 'operador') $$))->>'status',
  '401',
  '401: sem sessão'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000004',
    $$ select public.convidar_membro(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                     email => 'x@teste.invalid', papel => 'operador') $$))->>'code',
  'sem_permissao',
  '403: quem não é administrador da casa'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000001',
    $$ select public.convidar_membro(estabelecimento_id => '88300000-0000-4000-8000-00000000ffff'::uuid,
                                     email => 'x@teste.invalid', papel => 'operador') $$))->>'status',
  '403',
  'casa que não existe: quem não é administrador dela leva 403 antes do 404 (a casa não vaza)'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000001',
    $$ select public.convidar_membro(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                     email => 'sem-arroba', papel => 'operador') $$))->>'code',
  'campo_invalido',
  '422: e-mail inválido'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000001',
    $$ select public.convidar_membro(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                     email => 'x@teste.invalid', papel => null) $$))->>'code',
  'campo_obrigatorio',
  '422: papel ausente'
);

-- ── 3. aceitar_convite_membro, chamada nomeada ────────────────────────────────

select is(
  (pg_temp.erro(null, $$ select public.aceitar_convite_membro(token => 'qualquer') $$))->>'status',
  '401',
  '401: sem sessão'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000003', format(
    $$ select public.aceitar_convite_membro(token => %L) $$, (select r->>'token' from conv)
  )))->>'code',
  'perfil_incompativel',
  '422: conta de profissional'
);

create temp table aceite as
  select pg_temp.como('88300000-0000-4000-8000-000000000002', format(
    $$ select public.aceitar_convite_membro(token => %L) $$, (select r->>'token' from conv)
  )) as r;

select is(
  (select r->>'papel' from aceite) = 'operador'
    and (select r->>'estabelecimento_id' from aceite) = '88300000-0000-4000-8000-0000000000e1'
    and (select r->>'usuario_id' from aceite) = '88300000-0000-4000-8000-000000000002'
    and (select r->>'membro_id' from aceite) is not null,
  true,
  '200: contratante aceita pelo nome token e vira operador da casa'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000004', format(
    $$ select public.aceitar_convite_membro(token => %L) $$, (select r->>'token' from conv)
  )))->>'code',
  'convite_invalido',
  '422: token já usado'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000004',
    $$ select public.aceitar_convite_membro(token => '') $$))->>'code',
  'convite_invalido',
  '422: token vazio'
);

-- ── 4. transferir_administracao e remover_membro, chamada nomeada ─────────────
-- Neste ponto: admin (...01) é o único administrador e o convidado (...02) é operador da casa.

select is(
  (pg_temp.erro(null,
    $$ select public.transferir_administracao(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                              novo_admin_id => '88300000-0000-4000-8000-000000000002'::uuid) $$))->>'status',
  '401',
  'transferir_administracao 401: sem sessão'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000002',
    $$ select public.transferir_administracao(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                              novo_admin_id => '88300000-0000-4000-8000-000000000002'::uuid) $$))->>'code',
  'sem_permissao',
  'transferir_administracao 403: o operador não é administrador'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000001',
    $$ select public.transferir_administracao(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                              novo_admin_id => '88300000-0000-4000-8000-00000000ffff'::uuid) $$))->>'code',
  'nao_encontrado',
  'transferir_administracao 404: o membro indicado não é da casa'
);

select is(
  (pg_temp.erro(null,
    $$ select public.remover_membro(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                    membro_id => '88300000-0000-4000-8000-000000000001'::uuid) $$))->>'status',
  '401',
  'remover_membro 401: sem sessão'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000004',
    $$ select public.remover_membro(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                    membro_id => '88300000-0000-4000-8000-000000000001'::uuid) $$))->>'code',
  'sem_permissao',
  'remover_membro 403: quem não é administrador da casa'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000001',
    $$ select public.remover_membro(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                    membro_id => '88300000-0000-4000-8000-00000000ffff'::uuid) $$))->>'code',
  'nao_encontrado',
  'remover_membro 404: o membro indicado não é da casa'
);

select is(
  (pg_temp.erro('88300000-0000-4000-8000-000000000001',
    $$ select public.remover_membro(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                    membro_id => '88300000-0000-4000-8000-000000000001'::uuid) $$))->>'code',
  'ultimo_administrador',
  'remover_membro 422: o único administrador não sai'
);

select is(
  (pg_temp.como('88300000-0000-4000-8000-000000000001',
    $$ select public.transferir_administracao(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                              novo_admin_id => '88300000-0000-4000-8000-000000000002'::uuid) $$))->>'papel',
  'administrador',
  'transferir_administracao 200: o operador vira administrador'
);

select is(
  (pg_temp.como('88300000-0000-4000-8000-000000000002',
    $$ select public.remover_membro(estabelecimento_id => '88300000-0000-4000-8000-0000000000e1'::uuid,
                                    membro_id => '88300000-0000-4000-8000-000000000001'::uuid) $$))->>'removido',
  'true',
  'remover_membro 200: com outro administrador na casa, o primeiro sai'
);

select * from finish();
rollback;
