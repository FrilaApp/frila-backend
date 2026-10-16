-- 732_rpc_pedir_revisao_despacho.sql
--
-- Cobertura profunda via pgTAP para a RPC public.pedir_revisao_despacho(relato text).
-- Top 9 do Mapa de Lacunas de RPCs (MAPA-LACUNAS-RPCS.md).
--
-- Regras de Negócio e Segurança Exercitadas:
--   1. Catálogo e Privilégios:
--      • Função existe no catálogo;
--      • Definida como SECURITY DEFINER com search_path = '' estrito;
--      • Privilégio de EXECUTE revogado de anon e concedido a authenticated.
--   2. Autenticação e Perfis:
--      • Sem sessão (auth.uid() is null): recusa com 401 nao_autenticado;
--      • Perfil contratante chamando: recusa com 422 perfil_incompativel;
--      • Conta suspensa: recusa com 403 sem_permissao, details: conta_suspensa (RN13);
--      • Conta anonimizada: recusa com 401 nao_autenticado.
--   3. Validação do Relato e Bordas Exatas:
--      • Relato nulo: recusa com 422 campo_obrigatorio (details: relato);
--      • Relato vazio '': recusa com 422 campo_obrigatorio (details: relato);
--      • Relato com espaços '   ': recusa com 422 campo_obrigatorio (details: relato);
--      • Borda exata 9 caracteres: recusa com 422 campo_invalido (details: relato);
--      • Borda exata 9 caracteres com espaços nas pontas ('  123456789  '): btrim resulta em 9 e recusa 422 campo_invalido;
--      • Borda exata 10 caracteres limpos ('1234567890'): ACEITO com sucesso.
--   4. Caminho Feliz, Protocolo e Efeitos Colaterais:
--      • Devolve envelope Protocolo canônico: ocorrencia_id, tipo ('revisao_despacho'), criada_em, prazo_resposta_ate;
--      • Linha gravada em public.ocorrencia com autor_id = v_uid e tipo = 'revisao_despacho';
--      • Relato gravado fidedignamente no banco de dados;
--      • Enfileiramento no PGMQ (pgmq.q_email) contendo apenas tipo e ocorrencia_id (RN15: sem relato nem dados pessoais);
--      • Decisão J1=B (cartão ggEzge6h, 13/10/2026): relato não filtra termos nem links, permitindo citação de defesa.
--   5. Opção B — Teto Estrito de 1 Contestação (0.2.37, RF27):
--      • Segunda tentativa pelo app recusa com 409 contestacao_ja_aberta.
--   6. 3 Provas de Mutação Real via pg_get_functiondef:
--      • Mutante 1: Omissão da trava de 10 caracteres (< 5 em vez de < 10);
--      • Mutante 2: Omissão da trava 409 de unicidade (Opção B);
--      • Mutante 3: Omissão do enfileiramento pgmq.send;
--      • Restauração canônica perfeita comprovada via is(pg_get_functiondef, def_original) e confirmação final.

begin;

-- Setup de ambiente: isolamento de teste e relógio congelado
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-15 12:00:00-03';

select plan(26);

-- Helpers temporários de teste
create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (
    instance_id, id, aud, role, email, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
    is_sso_user, is_anonymous
  ) values (
    '00000000-0000-4000-8000-000000000000', conta, 'authenticated', 'authenticated',
    email, now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(),
    false, false
  ) on conflict (id) do nothing;
end $$;

create function pg_temp.como(conta uuid, sql text) returns jsonb
language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local "request.jwt.claims" = %L',
                 json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute format('set local "request.jwt.claim.sub" = %L', conta::text);
  execute sql into r;
  reset role;
  execute 'reset "request.jwt.claims"';
  execute 'reset "request.jwt.claim.sub"';
  return r;
end $$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

create function pg_temp.por(conta uuid, sql text) returns text
language sql as $$
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

-- Snapshot da definição original para verificação de restauração perfeita
create temp table pg_temp.def_original as
  select pg_get_functiondef('public.pedir_revisao_despacho(text)'::regprocedure) as def;

-- ── 1. Catálogo e Privilégios ─────────────────────────────────────────────────

select has_function(
  'public', 'pedir_revisao_despacho', array['text'],
  'funcao public.pedir_revisao_despacho(text) existe no catalogo'
);

select is(
  (select coalesce(p.proconfig, '{}') @> array['search_path=""'] and p.prosecdef
     from pg_proc p
    where p.proname = 'pedir_revisao_despacho'
      and p.pronamespace = 'public'::regnamespace),
  true,
  'pedir_revisao_despacho e SECURITY DEFINER com search_path="" estrito'
);

select ok(
  not has_function_privilege('anon', 'public.pedir_revisao_despacho(text)', 'execute'),
  'papel anon nao tem privilegio de EXECUTE em pedir_revisao_despacho'
);

select ok(
  has_function_privilege('authenticated', 'public.pedir_revisao_despacho(text)', 'execute'),
  'papel authenticated tem privilegio de EXECUTE em pedir_revisao_despacho'
);

-- ── Setup de Fixtures ─────────────────────────────────────────────────────────

create temp table ids as select
  '73200000-0000-4000-8000-000000000001'::uuid as user_contratante,
  '73200000-0000-4000-8000-000000000002'::uuid as user_prof_ana,
  '73200000-0000-4000-8000-000000000003'::uuid as user_prof_suspenso,
  '73200000-0000-4000-8000-000000000004'::uuid as user_prof_anonimizado,
  '73200000-0000-4000-8000-000000000005'::uuid as user_prof_mutante,
  '73200000-0000-4000-8000-000000000007'::uuid as user_prof_j1b;

-- Autenticações em auth.users
select pg_temp.autenticar((select user_contratante from ids),       'dono@732.test');
select pg_temp.autenticar((select user_prof_ana from ids),           'ana@732.test');
select pg_temp.autenticar((select user_prof_suspenso from ids),      'suspenso@732.test');
select pg_temp.autenticar((select user_prof_anonimizado from ids),   'anon@732.test');
select pg_temp.autenticar((select user_prof_mutante from ids),       'mutante@732.test');
select pg_temp.autenticar((select user_prof_j1b from ids),           'j1b@732.test');

-- Usuários
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em, anonimizado_em) values
  ('73200000-0000-4000-8000-000000000001', 'contratante', 'Seu Zé', 'dono@732.test', '+5561973200001', '1980-01-01', 'ativa', '1.0', now(), null),
  ('73200000-0000-4000-8000-000000000002', 'profissional', 'Ana Silva', 'ana@732.test', '+5561973200002', '1995-05-10', 'ativa', '1.0', now(), null),
  ('73200000-0000-4000-8000-000000000003', 'profissional', 'Pedro Suspenso', 'suspenso@732.test', '+5561973200003', '1992-03-15', 'suspensa', '1.0', now(), null),
  ('73200000-0000-4000-8000-000000000004', 'profissional', 'Conta Encerrada', 'anon@732.test', '+5561973200004', '1990-11-25', 'anonimizada', '1.0', now(), '2026-11-01 10:00:00+00'),
  ('73200000-0000-4000-8000-000000000005', 'profissional', 'Lucas Mutante', 'mutante@732.test', '+5561973200005', '1993-07-20', 'ativa', '1.0', now(), null),
  ('73200000-0000-4000-8000-000000000007', 'profissional', 'Carlos J1B', 'j1b@732.test', '+5561973200007', '1994-04-12', 'ativa', '1.0', now(), null);

-- Entidades profissional
insert into public.profissional (id, usuario_id, ponto_base) values
  ('73200000-0000-4000-8000-000000000022', '73200000-0000-4000-8000-000000000002', 'POINT(-47.8822 -15.7942)'::extensions.geography),
  ('73200000-0000-4000-8000-000000000023', '73200000-0000-4000-8000-000000000003', 'POINT(-47.8850 -15.7980)'::extensions.geography),
  ('73200000-0000-4000-8000-000000000025', '73200000-0000-4000-8000-000000000005', 'POINT(-47.8900 -15.8000)'::extensions.geography),
  ('73200000-0000-4000-8000-000000000027', '73200000-0000-4000-8000-000000000007', 'POINT(-47.8920 -15.8020)'::extensions.geography);

-- ── 2. Autenticação e Perfis ──────────────────────────────────────────────────

select throws_ok(
  $$ select public.pedir_revisao_despacho('Relato de contestacao de despacho') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  'sem sessao (auth.uid nulo): recusa com 401 nao_autenticado'
);

select throws_ok(
  pg_temp.por((select user_contratante from ids),
    $$ select public.pedir_revisao_despacho('Relato de contestacao de despacho') $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  'contratante chamando: recusa com 422 perfil_incompativel'
);

select throws_ok(
  pg_temp.por((select user_prof_suspenso from ids),
    $$ select public.pedir_revisao_despacho('Relato de contestacao de despacho') $$),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'profissional com conta suspensa: recusa com 403 sem_permissao (conta_suspensa)'
);

select throws_ok(
  pg_temp.por((select user_prof_anonimizado from ids),
    $$ select public.pedir_revisao_despacho('Relato de contestacao de despacho') $$),
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  'profissional com conta anonimizada: recusa com 401 nao_autenticado'
);

-- ── 3. Validação do Relato e Bordas Exatas ────────────────────────────────────

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.pedir_revisao_despacho(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'relato'),
  'relato nulo: recusa com 422 campo_obrigatorio (details: relato)'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.pedir_revisao_despacho('') $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'relato'),
  'relato vazio: recusa com 422 campo_obrigatorio (details: relato)'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.pedir_revisao_despacho('   ') $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'relato'),
  'relato so com espacos (btrim): recusa com 422 campo_obrigatorio (details: relato)'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.pedir_revisao_despacho('123456789') $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'relato'),
  'borda exata 9 caracteres: recusa com 422 campo_invalido (details: relato)'
);

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.pedir_revisao_despacho('   123456789   ') $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'relato'),
  'borda exata 9 caracteres com espacos nas pontas: btrim resulta em 9 e recusa 422'
);

-- ── 4. Caminho Feliz, Protocolo e Efeitos Colaterais ──────────────────────────

-- Chamada com limiar exato de 10 caracteres limpos ('1234567890')
select is(
  (pg_temp.como((select user_prof_ana from ids),
     $$ select public.pedir_revisao_despacho('1234567890') $$) ?& array['ocorrencia_id', 'tipo', 'criada_em', 'prazo_resposta_ate']),
  true,
  'borda exata 10 caracteres: aceita e devolve envelope Protocolo com todas as chaves'
);

select is(
  (select tipo from public.ocorrencia where autor_id = (select user_prof_ana from ids)),
  'revisao_despacho'::public.tipo_ocorrencia,
  'efeito observavel: linha gravada em public.ocorrencia com tipo revisao_despacho'
);

select is(
  (select relato from public.ocorrencia where autor_id = (select user_prof_ana from ids)),
  '1234567890',
  'efeito observavel: relato persistido exatamente na ocorrencia'
);

select is(
  (select count(*)::int from pgmq.q_email q
    where (q.message->>'tipo') = 'revisao_despacho'
      and (q.message->>'ocorrencia_id')::uuid = (
        select id from public.ocorrencia where autor_id = (select user_prof_ana from ids)
      )),
  1,
  'pgmq: aviso enfileirado em pgmq.q_email com tipo revisao_despacho e ocorrencia_id'
);

select is(
  (select (q.message ? 'relato') or (q.message ? 'email') or (q.message ? 'nome')
     from pgmq.q_email q
    where (q.message->>'tipo') = 'revisao_despacho'
    limit 1),
  false,
  'pgmq privacidade (RN15): corpo da mensagem nao contem relato nem dados pessoais'
);

-- Decisão J1=B: profissional citando termos e links de prova não é barrado por filtro de moderação
select is(
  (pg_temp.como((select user_prof_j1b from ids),
     $$ select public.pedir_revisao_despacho('Relato de defesa citando babaca e link https://frila.app') $$)->>'tipo'),
  'revisao_despacho',
  'decisao J1=B: relato com termos sensiveis ou links e aceito para defesa sem bloqueio de moderacao'
);

-- ── 5. Opção B — Teto Estrito de 1 Contestação (RF27) ─────────────────────────

select throws_ok(
  pg_temp.por((select user_prof_ana from ids),
    $$ select public.pedir_revisao_despacho('Segunda tentativa de contestacao de despacho pelo mesmo profissional') $$),
  'PGRST',
  pg_temp.erro('contestacao_ja_aberta'),
  'opcao B (RF27): segunda contestacao pelo aplicativo recusa com 409 contestacao_ja_aberta'
);

-- ── 6. Provas de Mutação Real via pg_get_functiondef ─────────────────────────

-- Mutante 1: Omissão da trava de 10 caracteres (< 5 em vez de < 10)
do $$
begin
  execute replace(
    pg_get_functiondef('public.pedir_revisao_despacho(text)'::regprocedure),
    'pg_catalog.length(v_relato) < 10',
    'pg_catalog.length(v_relato) < 5'
  );
end $$;

select is(
  (pg_temp.como((select user_prof_mutante from ids),
     $$ select public.pedir_revisao_despacho('123456789') $$)->>'tipo'),
  'revisao_despacho',
  'mutante 1 (trava < 5): relato de 9 caracteres passaria com sucesso; discrimina borda de 10'
);

-- Restauração dinâmica do mutante 1
do $$
begin
  execute (select def from pg_temp.def_original);
end $$;

-- Mutante 2: Omissão da trava 409 contestacao_ja_aberta (Opção B)
do $$
begin
  execute replace(
    pg_get_functiondef('public.pedir_revisao_despacho(text)'::regprocedure),
    'if exists (',
    'if false and exists ('
  );
end $$;

select is(
  (pg_temp.como((select user_prof_ana from ids),
     $$ select public.pedir_revisao_despacho('Segunda contestacao sob mutante que omite a trava de unicidade') $$)->>'tipo'),
  'revisao_despacho',
  'mutante 2 (sem trava 409): segunda chamada passaria sem recusar; discrimina trava Opcao B'
);

-- Restauração dinâmica do mutante 2
do $$
begin
  execute (select def from pg_temp.def_original);
end $$;

-- Mutante 3: Omissão do enfileiramento pgmq.send
do $$
begin
  execute regexp_replace(
    pg_get_functiondef('public.pedir_revisao_despacho(text)'::regprocedure),
    'perform pgmq\.send\([^;]+?\);',
    'perform null;'
  );
end $$;

-- Contagem antes da chamada sob o mutante 3
create temp table pg_temp.contagem_fila as
  select count(*)::int as total from pgmq.q_email;

-- Criar outro profissional para exercitar mutante 3
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('73200000-0000-4000-8000-000000000006', 'profissional', 'Profissional Seis', 'seis@732.test', '+5561973200006', '1996-01-01', 'ativa', '1.0', now());
select pg_temp.autenticar('73200000-0000-4000-8000-000000000006', 'seis@732.test');
insert into public.profissional (id, usuario_id, ponto_base) values
  ('73200000-0000-4000-8000-000000000026', '73200000-0000-4000-8000-000000000006', 'POINT(-47.8822 -15.7942)'::extensions.geography);

select is(
  (pg_temp.como('73200000-0000-4000-8000-000000000006',
     $$ select public.pedir_revisao_despacho('Relato de teste valido para mutante sem envio') $$)->>'tipo'),
  'revisao_despacho',
  'mutante 3: chamada conclui com sucesso mas enfileiramento foi omitido'
);

select is(
  (select count(*)::int from pgmq.q_email) - (select total from pg_temp.contagem_fila),
  0,
  'mutante 3 (sem pgmq.send): nenhuma mensagem adicionada a pgmq.q_email; discrimina disparo pgmq'
);

-- Restauração dinâmica do mutante 3
do $$
begin
  execute (select def from pg_temp.def_original);
end $$;

-- Restauração Canônica Verificada
select is(
  pg_get_functiondef('public.pedir_revisao_despacho(text)'::regprocedure),
  (select def from pg_temp.def_original),
  'restauracao canonica: definicao final identica a original via is(pg_get_functiondef, def_original)'
);

-- Confirmação Canônica Final sob a definição canônica restaurada
select throws_ok(
  pg_temp.por('73200000-0000-4000-8000-000000000006',
    $$ select public.pedir_revisao_despacho('curto') $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'relato'),
  'confirmacao canonica final: sob definicao restaurada, relato curto volta a recusar 422 campo_invalido'
);

select * from finish();
rollback;
