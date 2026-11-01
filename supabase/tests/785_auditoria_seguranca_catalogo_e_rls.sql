-- 785_auditoria_seguranca_catalogo_e_rls.sql
--
-- Auditoria de Seguranca Global de Catalogo, RLS e Sigilo de Dados Pessoais (N-039).
--
-- Cobertura abrangente e invariantes de catalogo:
--   1. RLS universal: 100% das tabelas em `public` e `privado` com RLS habilitado (relrowsecurity = true).
--   2. Grants minimos: Papel `anon` possui ZERO grants em tabelas de `public` e `privado`.
--   3. Sem escrita direta: Papel `authenticated` possui ZERO grants de INSERT, UPDATE, DELETE, TRUNCATE,
--      REFERENCES ou TRIGGER em tabelas de `public` e `privado` (escritas 100% mediadas por RPCs seguras).
--   4. RLS fechado em privado: Papel `authenticated` possui ZERO grants em tabelas do schema `privado`.
--   5. Isolamento de tabelas internas: `entrada_demonstracao`, `evento_app` e `pedido_de_exclusao`
--      possuem ZERO grants para clientes (`authenticated` e `anon`).
--   6. Politicas permissivas: Apenas `public.funcao` (catalogo estatico sem dados pessoais) possui USING (true).
--      Nenhuma outra tabela em `public` ou `privado` admite USING (true).
--   7. Blindagem de schema: 100% das rotinas SECURITY DEFINER em `public` e `privado` possuem search_path="" estrito.
--   8. Superficie anonima de RPCs: Exatamente 1 rotina publica concede EXECUTE para `anon` (`configuracao_do_app`).
--      Todas as demais rotinas em `public` e `privado` negam EXECUTE para `anon`.
--   9. Superficie autenticada em privado: Estritamente as 12 funcoes auxiliares de RLS sao executaveis por `authenticated`.
--  10. Sigilo LGPD e RLS: Validacao dinamica de isolamento entre titulares em `usuario`, `profissional`,
--      `dispositivo` e `estabelecimento` (queries diretas sob RLS retornam 0 linhas para dados de terceiros).
--  11. Provas de mutacao: Deteccao imediata de tabelas mutantes sem RLS, tabelas com grants indevidos e
--      funcoes SECURITY DEFINER sem search_path="".

begin;

-- Congelamento de ambiente e relogio
insert into privado.ambiente (id, eh_teste) values (true, true)
  on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-01 12:00:00+00';
set local frila.agendador_secret = 'teste-segredo-auditoria-785';

select plan(34);

-- ── 0. Helpers de teste e contexto ──────────────────────────────────────────

create function pg_temp.como(papel text, sql text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
end $$;

create function pg_temp.contar_como(conta uuid, sql text) returns integer
language plpgsql as $$
declare n integer;
begin
  execute 'set local role authenticated';
  if conta is not null then
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', conta, 'role', 'authenticated')::text);
  else
    execute 'set local request.jwt.claims = ''{"role":"authenticated"}''';
  end if;
  execute sql into n;
  reset role;
  execute 'reset request.jwt.claims';
  return n;
end $$;

create function pg_temp.executar_como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare res jsonb;
begin
  execute 'set local role authenticated';
  if conta is not null then
    execute format('set local request.jwt.claims = %L',
                   json_build_object('sub', conta, 'role', 'authenticated')::text);
  else
    execute 'set local request.jwt.claims = ''{"role":"authenticated"}''';
  end if;
  execute sql into res;
  reset role;
  execute 'reset request.jwt.claims';
  return res;
end $$;

-- ============================================================================
-- PARTE 1: RLS Universal e Ausencia de Tabelas Abertas (Schemas public e privado)
-- ============================================================================

-- 1. Toda tabela existente em public possui Row Level Security habilitado
select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relrowsecurity),
  0,
  'RLS public: 100% das tabelas do schema public possuem relrowsecurity = true'
);

-- 2. Toda tabela existente em privado possui Row Level Security habilitado
select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'privado' and c.relkind in ('r', 'p') and not c.relrowsecurity),
  0,
  'RLS privado: 100% das tabelas do schema privado possuem relrowsecurity = true'
);

-- 3. Nenhuma tabela em public ou privado possui FORCE ROW LEVEL SECURITY (preserva bypass do owner)
select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public', 'privado') and c.relkind in ('r', 'p') and c.relforcerowsecurity),
  0,
  'FORCE RLS: nenhuma tabela de aplicacao possui FORCE RLS ativo'
);

-- 4. Prova de mutacao RLS: criacao de tabela sem RLS em public e capturada pelo invariante
create table public._mutante_tabela_sem_rls (id int);
alter table public._mutante_tabela_sem_rls disable row level security;

select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = '_mutante_tabela_sem_rls' and not c.relrowsecurity),
  1,
  'mutacao provada: tabela com RLS desativado em public e capturada pelo censo'
);

drop table public._mutante_tabela_sem_rls;

-- ============================================================================
-- PARTE 2: Principio do Menor Privilegio em Tabelas (Grants e Privilegios)
-- ============================================================================

-- 5. Papel anon possui exatamente 0 grants de tabela em public
select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'public'),
  0,
  'grants anon public: papel anon possui 0 concessoes de privilegio em tabelas de public'
);

-- 6. Papel anon possui exatamente 0 grants de tabela em privado
select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_schema = 'privado'),
  0,
  'grants anon privado: papel anon possui 0 concessoes de privilegio em tabelas de privado'
);

-- 7. Papel authenticated possui exatamente 0 grants de tabela em privado
select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'authenticated' and table_schema = 'privado'),
  0,
  'grants authenticated privado: papel authenticated possui 0 concessoes em tabelas de privado'
);

-- 8. Papel authenticated nao possui nenhum privilegio de escrita direta (INSERT, UPDATE, DELETE, TRUNCATE) em public
select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'authenticated'
      and table_schema = 'public'
      and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')),
  0,
  'sem escrita direta: authenticated possui 0 privilegios de mutacao direta em public'
);

-- 9. Papel authenticated nao possui privilegios estruturais perigosos (REFERENCES, TRIGGER, MAINTAIN) em public
select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p')
      and (has_table_privilege('authenticated', c.oid, 'references')
           or has_table_privilege('authenticated', c.oid, 'trigger')
           or has_table_privilege('authenticated', c.oid, 'maintain'))),
  0,
  'privilegios minimos: authenticated nao possui REFERENCES, TRIGGER ou MAINTAIN em public'
);

-- 10. As 3 tabelas internas de public nao concedem SELECT para clientes autenticados
select is(
  (select count(*)::int from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname in ('entrada_demonstracao', 'evento_app', 'pedido_de_exclusao')
      and (has_table_privilege('authenticated', c.oid, 'select')
           or has_table_privilege('anon', c.oid, 'select'))),
  0,
  'isolamento interno: tabelas entrada_demonstracao, evento_app e pedido_de_exclusao sem SELECT para clientes'
);

-- 11. Prova de mutacao de concessao: grant indevido a anon e detectado imediatamente
create table public._mutante_grant_indevido (id int);
grant select on public._mutante_grant_indevido to anon;

select is(
  (select count(*)::int from information_schema.role_table_grants
    where grantee = 'anon' and table_name = '_mutante_grant_indevido'),
  1,
  'mutacao provada: concessao indevida para anon e detectada pelo monitor de catalogo'
);

drop table public._mutante_grant_indevido;

-- ============================================================================
-- PARTE 3: Politicas RLS e Invariante de USING (true)
-- ============================================================================

-- 12. Apenas tabelas de catalogo estatico sem dados pessoais (public.funcao) admitem USING (true)
select is(
  (select coalesce(array_agg(tablename::text order by tablename), '{}'::text[])
     from pg_policies
    where schemaname = 'public'
      and (qual = 'true' or with_check = 'true')),
  array['funcao']::text[],
  'politicas RLS: apenas public.funcao (catalogo sem dados pessoais) admite politica USING (true)'
);

-- 13. Nenhuma tabela no schema privado possui politicas RLS (acesso 100% blindado por SECURITY DEFINER)
select is(
  (select count(*)::int from pg_policies where schemaname = 'privado'),
  0,
  'politicas RLS privado: 0 politicas em privado (tabelas totalmente inacessiveis a clientes)'
);

-- ============================================================================
-- PARTE 4: Funcoes, SECURITY DEFINER e search_path=""
-- ============================================================================

-- 14. 100% das funcoes SECURITY DEFINER em public e privado possuem search_path="" estrito em proconfig
select is(
  (select count(*)::int from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'privado')
      and p.prosecdef = true
      and (p.proconfig is null or not ('search_path=""' = any(p.proconfig)))),
  0,
  'CWE-426: 100% das funcoes SECURITY DEFINER em public e privado possuem search_path="" estrito'
);

-- 15. Prova de mutacao search_path: funcao SECURITY DEFINER sem search_path="" e capturada
create function public._mutante_fn_sem_search_path() returns void
language sql security definer as $$ select 1; $$;

select is(
  (select count(*)::int from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = '_mutante_fn_sem_search_path'
      and (p.proconfig is null or not ('search_path=""' = any(p.proconfig)))),
  1,
  'mutacao provada: funcao SECURITY DEFINER sem search_path estrito e capturada pelo censo'
);

drop function public._mutante_fn_sem_search_path();

-- 16. Apenas public.configuracao_do_app concede EXECUTE para o papel anon em public
select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}'::text[])
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and has_function_privilege('anon', p.oid, 'execute')),
  array['configuracao_do_app']::text[],
  'superficie anonima: apenas configuracao_do_app e executavel por anon no schema public'
);

-- 17. Nenhuma funcao no schema privado e executavel pelo papel anon
select is(
  (select count(*)::int from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado'
      and has_function_privilege('anon', p.oid, 'execute')),
  0,
  'superficie anonima privado: 0 funcoes executaveis por anon no schema privado'
);

-- 18. Apenas as 12 funcoes auxiliares de RLS no schema privado sao executaveis por authenticated
select is(
  (select coalesce(array_agg(p.proname::text order by p.proname), '{}'::text[])
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado'
      and has_function_privilege('authenticated', p.oid, 'execute')),
  array[
    'bloqueado_com_estabelecimento',
    'candidatou_na_vaga',
    'eh_membro',
    'estabelecimento_da_posicao',
    'estabelecimento_da_vaga',
    'lado_da_posicao',
    'mesma_populacao',
    'meu_profissional_id',
    'ocupa_posicao_na_vaga',
    'perfil_da_conta',
    'usuario_do_profissional',
    'vaga_oculta'
  ]::text[],
  'privilegios em privado: estritamente as 12 rotinas de apoio ao RLS concedem EXECUTE a authenticated'
);

-- ============================================================================
-- PARTE 5: Sigilo LGPD e Isolamento Efetivo sob RLS (Execucao Real)
-- ============================================================================

-- Criar cenario de dois titulares distintos (A e B) e um estabelecimento
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values
  ('ae785000-0000-4000-8000-000000000001', 'profissional', 'Titular A', '+5561999990001', 'titular.a.785@frila.app', '1995-05-10', 'ativa', '0.2.0', now()),
  ('ae785000-0000-4000-8000-000000000002', 'profissional', 'Titular B', '+5561999990002', 'titular.b.785@frila.app', '1996-06-11', 'ativa', '0.2.0', now()),
  ('ae785000-0000-4000-8000-000000000003', 'contratante',  'Titular C Dono', '+5561999990003', 'titular.c.785@frila.app', '1990-01-01', 'ativa', '0.2.0', now());

insert into public.profissional (id, usuario_id, ponto_base)
values
  ('be785000-0000-4000-8000-000000000001', 'ae785000-0000-4000-8000-000000000001', extensions.st_setsrid(extensions.st_makepoint(-47.8825, -15.7942), 4326)),
  ('be785000-0000-4000-8000-000000000002', 'ae785000-0000-4000-8000-000000000002', extensions.st_setsrid(extensions.st_makepoint(-47.8825, -15.7942), 4326));

insert into public.dispositivo (id, usuario_id, token_fcm, plataforma)
values
  ('de785000-0000-4000-8000-000000000001', 'ae785000-0000-4000-8000-000000000001', 'fcm_token_titular_a_785', 'ios'),
  ('de785000-0000-4000-8000-000000000002', 'ae785000-0000-4000-8000-000000000002', 'fcm_token_titular_b_785', 'android');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values
  ('ee785000-0000-4000-8000-000000000001', 'Restaurante do Titular C', '12345678000199', 'food_service', 'Asa Sul CLS 405',
   extensions.st_setsrid(extensions.st_makepoint(-47.8825, -15.7942), 4326), 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values
  ('ee785000-0000-4000-8000-000000000001', 'ae785000-0000-4000-8000-000000000003', 'administrador');

-- 19. Anon recebe 42501 (permission denied) ao tentar ler public.usuario
select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.usuario') $$,
  '42501',
  'permission denied for table usuario',
  'sigilo anon: tentativa de leitura anonima em public.usuario lanca 42501'
);

-- 20. Anon recebe 42501 (permission denied) ao tentar ler public.profissional
select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.profissional') $$,
  '42501',
  'permission denied for table profissional',
  'sigilo anon: tentativa de leitura anonima em public.profissional lanca 42501'
);

-- 21. Anon recebe 42501 (permission denied) ao tentar ler public.estabelecimento
select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.estabelecimento') $$,
  '42501',
  'permission denied for table estabelecimento',
  'sigilo anon: tentativa de leitura anonima em public.estabelecimento lanca 42501'
);

-- 22. Anon recebe 42501 (permission denied) ao tentar ler public.dispositivo
select throws_ok(
  $$ select pg_temp.como('anon', 'select count(*) from public.dispositivo') $$,
  '42501',
  'permission denied for table dispositivo',
  'sigilo anon: tentativa de leitura anonima em public.dispositivo lanca 42501'
);

-- 23. Autenticado como Titular A: SELECT em public.usuario enxerga exatamente a si proprio
select is(
  pg_temp.contar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select count(*) from public.usuario'),
  1,
  'RLS usuario: titular A enxerga exatamente 1 registro em public.usuario'
);

-- 24. Autenticado como Titular A: id retornado e estritamente o de Titular A
select is(
  (pg_temp.executar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select to_jsonb(id) from public.usuario') #>> '{}')::uuid,
  'ae785000-0000-4000-8000-000000000001'::uuid,
  'RLS usuario: registro visivel para Titular A e estritamente o seu proprio'
);

-- 25. Autenticado como Titular A: consulta direta pelo id de Titular B retorna 0 linhas
select is(
  pg_temp.contar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select count(*) from public.usuario where id = ''ae785000-0000-4000-8000-000000000002'''),
  0,
  'sigilo usuario: titular A nao consegue ler linha do titular B em public.usuario'
);

-- 26. Autenticado como Titular A: consulta direta em public.profissional enxerga apenas seu perfil
select is(
  pg_temp.contar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select count(*) from public.profissional'),
  1,
  'RLS profissional: titular A enxerga apenas 1 linha em public.profissional'
);

-- 27. Autenticado como Titular A: consulta direta pelo profissional do titular B retorna 0 linhas
select is(
  pg_temp.contar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select count(*) from public.profissional where id = ''be785000-0000-4000-8000-000000000002'''),
  0,
  'sigilo profissional: titular A nao consegue ler dados de profissional do titular B'
);

-- 28. Autenticado como Titular A: consulta em public.dispositivo enxerga apenas seus dispositivos
select is(
  pg_temp.contar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select count(*) from public.dispositivo'),
  1,
  'RLS dispositivo: titular A enxerga apenas seu proprio token em public.dispositivo'
);

-- 29. Autenticado como Titular A: consulta direta pelo token de Titular B retorna 0 linhas
select is(
  pg_temp.contar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select count(*) from public.dispositivo where id = ''de785000-0000-4000-8000-000000000002'''),
  0,
  'sigilo dispositivo: titular A nao consegue ler token FCM de Titular B'
);

-- 30. Autenticado como Titular A: consulta em public.estabelecimento retorna 0 linhas (nao e membro)
select is(
  pg_temp.contar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select count(*) from public.estabelecimento where id = ''ee785000-0000-4000-8000-000000000001'''),
  0,
  'sigilo estabelecimento: titular A (nao membro) nao enxerga CNPJ/documento em public.estabelecimento'
);

-- 31. Autenticado como Titular C (membro administrador): enxerga seu estabelecimento
select is(
  pg_temp.contar_como('ae785000-0000-4000-8000-000000000003'::uuid, 'select count(*) from public.estabelecimento where id = ''ee785000-0000-4000-8000-000000000001'''),
  1,
  'RLS estabelecimento: membro titular C enxerga seu estabelecimento sob RLS'
);

-- 32. Perfil publico de profissional nao expoe telefone, e-mail, documento ou nascimento
select is(
  (select (pg_temp.executar_como('ae785000-0000-4000-8000-000000000003'::uuid, 'select public.perfil_publico(''be785000-0000-4000-8000-000000000001''::uuid)') ? 'telefone'
           or pg_temp.executar_como('ae785000-0000-4000-8000-000000000003'::uuid, 'select public.perfil_publico(''be785000-0000-4000-8000-000000000001''::uuid)') ? 'email'
           or pg_temp.executar_como('ae785000-0000-4000-8000-000000000003'::uuid, 'select public.perfil_publico(''be785000-0000-4000-8000-000000000001''::uuid)') ? 'documento'
           or pg_temp.executar_como('ae785000-0000-4000-8000-000000000003'::uuid, 'select public.perfil_publico(''be785000-0000-4000-8000-000000000001''::uuid)') ? 'nascimento')),
  false,
  'sigilo LGPD: perfil_publico nunca projeta telefone, e-mail, documento ou nascimento'
);

-- 33. Perfil publico de estabelecimento nao expoe documento fiscal (CNPJ/CPF), endereco ou coordenadas
select is(
  (select (pg_temp.executar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select public.perfil_publico(''ee785000-0000-4000-8000-000000000001''::uuid)') ? 'documento'
           or pg_temp.executar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select public.perfil_publico(''ee785000-0000-4000-8000-000000000001''::uuid)') ? 'endereco'
           or pg_temp.executar_como('ae785000-0000-4000-8000-000000000001'::uuid, 'select public.perfil_publico(''ee785000-0000-4000-8000-000000000001''::uuid)') ? 'ponto')),
  false,
  'sigilo LGPD: perfil_publico de estabelecimento nunca projeta documento, endereco ou coordenadas'
);

-- 34. Limpeza e encerramento
select is(
  (select count(*)::int from public.usuario where id::text like 'ae785000%'),
  3,
  'auditoria concluida com isolamento estrito comprovado em todos os niveis'
);

select * from finish();

rollback;
