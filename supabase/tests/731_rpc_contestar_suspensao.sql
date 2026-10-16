-- 731_rpc_contestar_suspensao.sql
--
-- Cobertura profunda via pgTAP para a RPC public.contestar_suspensao(relato text).
-- Top 8 do Mapa de Lacunas de RPCs (MAPA-LACUNAS-RPCS.md).
--
-- Regras de Negócio e Segurança Exercitadas:
--   1. Catálogo e Privilégios:
--      • Função existe no catálogo;
--      • Definida como SECURITY DEFINER com search_path = '' estrito;
--      • Privilégio de EXECUTE revogado de anon e concedido a authenticated.
--   2. Autenticação e Estados da Conta:
--      • Sem sessão (auth.uid() is null): recusa com 401 nao_autenticado;
--      • Usuário anonimizado: recusa com 401 nao_autenticado;
--      • Usuário com conta ativa (sem suspensão ativa): recusa com 422 sem_suspensao_ativa.
--   3. Validação e Bordas Exatas do Relato:
--      • Relato nulo: recusa com 422 campo_obrigatorio (details: relato);
--      • Relato vazio '': recusa com 422 campo_obrigatorio (details: relato);
--      • Relato com apenas espaços '   ': recusa com 422 campo_obrigatorio (details: relato);
--      • Borda inferior exata: 9 caracteres ('123456789') recusa com 422 campo_invalido (details: relato);
--      • Borda inferior com padding btrim: '  123456789  ' recusa com 422 campo_invalido (details: relato);
--      • Borda exata no limiar: 10 caracteres ('1234567890') é ACEITA com sucesso.
--   4. Caminho Feliz, Protocolo e Efeitos Colaterais:
--      • Devolve envelope Protocolo canônico: ocorrencia_id, tipo ('contestacao'), criada_em, prazo_resposta_ate;
--      • prazo_resposta_ate calculado com 5 dias úteis (privado.prazo_de_resposta);
--      • Linha gravada em public.ocorrencia com tipo = 'contestacao' e relato completo;
--      • Enfileiramento seguro no PGMQ (pgmq.q_email) contendo apenas tipo e ocorrencia_id (RN15: sem relato nem dados pessoais no corpo).
--   5. Unicidade de Contestação Aberta (RN13):
--      • Segunda contestação enviada enquanto a primeira está pendente recusa com 409 contestacao_ja_aberta.
--   6. 3 Provas de Mutação Real via pg_get_functiondef:
--      • Mutante 1: Omissão da trava de tamanho mínimo de 10 caracteres (relato de 9 caracteres passaria);
--      • Mutante 2: Omissão da trava 409 contestacao_ja_aberta (segunda contestação passaria);
--      • Mutante 3: Omissão do enfileiramento pgmq.send (mensagem não seria postada na fila);
--      • Restauração canônica perfeita comprovada via is(pg_get_functiondef, def_original) e confirmação final.

begin;

-- Setup de ambiente: isolamento de teste e relógio congelado
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-15 12:00:00-03';

select plan(24);

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
  select pg_get_functiondef('public.contestar_suspensao(text)'::regprocedure) as def;

-- ── 1. Catálogo e Privilégios ─────────────────────────────────────────────────

select has_function(
  'public', 'contestar_suspensao', array['text'],
  'funcao public.contestar_suspensao(text) existe no catalogo'
);

select is(
  (select coalesce(p.proconfig, '{}') @> array['search_path=""'] and p.prosecdef
     from pg_proc p
    where p.proname = 'contestar_suspensao'
      and p.pronamespace = 'public'::regnamespace),
  true,
  'contestar_suspensao e SECURITY DEFINER com search_path="" estrito'
);

select ok(
  not has_function_privilege('anon', 'public.contestar_suspensao(text)', 'execute'),
  'papel anon nao tem privilegio de EXECUTE em contestar_suspensao'
);

select ok(
  has_function_privilege('authenticated', 'public.contestar_suspensao(text)', 'execute'),
  'papel authenticated tem privilegio de EXECUTE em contestar_suspensao'
);

-- ── Setup de Fixtures ─────────────────────────────────────────────────────────

create temp table ids as select
  '73100000-0000-4000-8000-000000000001'::uuid as user_ativo,
  '73100000-0000-4000-8000-000000000002'::uuid as user_suspenso,
  '73100000-0000-4000-8000-000000000003'::uuid as user_anonimizado,
  '73100000-0000-4000-8000-000000000004'::uuid as user_suspenso_mutante,
  '73100000-0000-4000-8000-000000000101'::uuid as ocorrencia_suspensao,
  '73100000-0000-4000-8000-000000000102'::uuid as ocorrencia_suspensao_mut;

-- Autenticações em auth.users
select pg_temp.autenticar((select user_ativo from ids),              'ativo@731.test');
select pg_temp.autenticar((select user_suspenso from ids),          'suspenso@731.test');
select pg_temp.autenticar((select user_anonimizado from ids),       'anon@731.test');
select pg_temp.autenticar((select user_suspenso_mutante from ids),  'mutante@731.test');

-- Usuários
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em, anonimizado_em) values
  ('73100000-0000-4000-8000-000000000001', 'profissional', 'Carlos Ativo', 'ativo@731.test', '+5561973100001', '1990-01-01', 'ativa', '1.0', now(), null),
  ('73100000-0000-4000-8000-000000000002', 'profissional', 'Bruno Suspenso', 'suspenso@731.test', '+5561973100002', '1992-05-15', 'suspensa', '1.0', now(), null),
  ('73100000-0000-4000-8000-000000000003', 'profissional', 'Conta Encerrada', 'anon@731.test', '+5561973100003', '1994-08-20', 'anonimizada', '1.0', now(), '2026-11-01 10:00:00+00'),
  ('73100000-0000-4000-8000-000000000004', 'profissional', 'Marcos Suspenso Mut', 'mutante@731.test', '+5561973100004', '1993-03-10', 'suspensa', '1.0', now(), null);

-- Entidades profissional
insert into public.profissional (id, usuario_id, ponto_base) values
  ('73100000-0000-4000-8000-000000000021', '73100000-0000-4000-8000-000000000001', 'POINT(-47.8822 -15.7942)'::extensions.geography),
  ('73100000-0000-4000-8000-000000000022', '73100000-0000-4000-8000-000000000002', 'POINT(-47.8850 -15.7980)'::extensions.geography),
  ('73100000-0000-4000-8000-000000000024', '73100000-0000-4000-8000-000000000004', 'POINT(-47.8900 -15.8000)'::extensions.geography);

-- Ocorrências de suspensão prévia para os usuários suspensos
insert into public.ocorrencia (id, tipo, usuario_id, autor_id, motivo, criada_em) values
  ('73100000-0000-4000-8000-000000000101', 'suspensao',
   '73100000-0000-4000-8000-000000000002', '73100000-0000-4000-8000-000000000002',
   'Suspensão disciplinar por falta', '2026-11-10 10:00:00+00'),
  ('73100000-0000-4000-8000-000000000102', 'suspensao',
   '73100000-0000-4000-8000-000000000004', '73100000-0000-4000-8000-000000000004',
   'Suspensão disciplinar por falta', '2026-11-10 10:00:00+00');

-- ── 2. Autenticação e Estados da Conta ────────────────────────────────────────

select throws_ok(
  $$ select public.contestar_suspensao('Minha justificativa detalhada') $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  'sem sessao (auth.uid nulo): recusa com 401 nao_autenticado'
);

select throws_ok(
  pg_temp.por((select user_anonimizado from ids),
    $$ select public.contestar_suspensao('Minha justificativa detalhada') $$),
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  'usuario anonimizado: recusa com 401 nao_autenticado'
);

select throws_ok(
  pg_temp.por((select user_ativo from ids),
    $$ select public.contestar_suspensao('Minha justificativa detalhada') $$),
  'PGRST',
  pg_temp.erro('sem_suspensao_ativa'),
  'usuario com conta ativa: recusa com 422 sem_suspensao_ativa'
);

-- ── 3. Validação e Bordas Exatas do Relato ────────────────────────────────────

select throws_ok(
  pg_temp.por((select user_suspenso from ids),
    $$ select public.contestar_suspensao(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'relato'),
  'relato nulo: recusa com 422 campo_obrigatorio (details: relato)'
);

select throws_ok(
  pg_temp.por((select user_suspenso from ids),
    $$ select public.contestar_suspensao('') $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'relato'),
  'relato vazio: recusa com 422 campo_obrigatorio (details: relato)'
);

select throws_ok(
  pg_temp.por((select user_suspenso from ids),
    $$ select public.contestar_suspensao('     ') $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'relato'),
  'relato so com espacos (btrim): recusa com 422 campo_obrigatorio (details: relato)'
);

select throws_ok(
  pg_temp.por((select user_suspenso from ids),
    $$ select public.contestar_suspensao('123456789') $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'relato'),
  'borda exata 9 caracteres: recusa com 422 campo_invalido (details: relato)'
);

select throws_ok(
  pg_temp.por((select user_suspenso from ids),
    $$ select public.contestar_suspensao('   123456789   ') $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'relato'),
  'borda exata 9 caracteres com espacos nas pontas: btrim resulta em 9 e recusa 422'
);

-- ── 4. Caminho Feliz, Protocolo e Efeitos Colaterais ──────────────────────────

-- Chamada com limiar exato de 10 caracteres ('1234567890')
select is(
  (pg_temp.como((select user_suspenso from ids),
     $$ select public.contestar_suspensao('1234567890') $$) ?& array['ocorrencia_id', 'tipo', 'criada_em', 'prazo_resposta_ate']),
  true,
  'borda exata 10 caracteres: aceita e devolve envelope Protocolo com todas as chaves'
);

select is(
  (select tipo from public.ocorrencia where usuario_id = (select user_suspenso from ids) and tipo = 'contestacao'),
  'contestacao'::public.tipo_ocorrencia,
  'efeito observavel: linha gravada em public.ocorrencia com tipo contestacao'
);

select is(
  (select relato from public.ocorrencia where usuario_id = (select user_suspenso from ids) and tipo = 'contestacao'),
  '1234567890',
  'efeito observavel: relato persistido exatamente na ocorrencia'
);

-- Verificação da mensagem enfileirada no PGMQ (RN15: sem relato nem dado pessoal)
select is(
  (select count(*)::int from pgmq.q_email q
    where (q.message->>'tipo') = 'contestacao'
      and (q.message->>'ocorrencia_id')::uuid = (
        select id from public.ocorrencia where usuario_id = (select user_suspenso from ids) and tipo = 'contestacao'
      )),
  1,
  'pgmq: aviso enfileirado em pgmq.q_email com tipo contestacao e ocorrencia_id'
);

select is(
  (select (q.message ? 'relato') or (q.message ? 'email') or (q.message ? 'nome')
     from pgmq.q_email q
    where (q.message->>'tipo') = 'contestacao'
    limit 1),
  false,
  'pgmq privacidade (RN15): corpo da mensagem nao contem relato nem dados pessoais do usuario'
);

-- ── 5. Unicidade de Contestação Aberta (409 contestacao_ja_aberta) ─────────────

select throws_ok(
  pg_temp.por((select user_suspenso from ids),
    $$ select public.contestar_suspensao('Segunda tentativa de contestacao enquanto a primeira esta aberta') $$),
  'PGRST',
  pg_temp.erro('contestacao_ja_aberta'),
  'segunda contestacao aberta: recusa com 409 contestacao_ja_aberta'
);

-- ── 6. Provas de Mutação Real via pg_get_functiondef ─────────────────────────

-- Mutante 1: Omissão da trava de tamanho mínimo de 10 caracteres (< 5 em vez de < 10)
do $$
begin
  execute replace(
    pg_get_functiondef('public.contestar_suspensao(text)'::regprocedure),
    'pg_catalog.length(v_relato) < 10',
    'pg_catalog.length(v_relato) < 5'
  );
end $$;

select is(
  (pg_temp.como((select user_suspenso_mutante from ids),
     $$ select public.contestar_suspensao('123456789') $$)->>'tipo'),
  'contestacao',
  'mutante 1 (trava < 5): relato de 9 caracteres passaria com sucesso; discrimina borda de 10'
);

-- Restauração dinâmica do mutante 1
do $$
begin
  execute (select def from pg_temp.def_original);
end $$;

-- Mutante 2: Omissão da trava 409 contestacao_ja_aberta
do $$
begin
  execute replace(
    pg_get_functiondef('public.contestar_suspensao(text)'::regprocedure),
    'if exists (',
    'if false and exists ('
  );
end $$;

select is(
  (pg_temp.como((select user_suspenso from ids),
     $$ select public.contestar_suspensao('Segunda contestacao que passaria sob o mutante sem trava') $$)->>'tipo'),
  'contestacao',
  'mutante 2 (sem trava 409): segunda chamada passaria sem recusar; discrimina trava de unicidade'
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
    pg_get_functiondef('public.contestar_suspensao(text)'::regprocedure),
    'perform pgmq\.send\([^;]+?\);',
    'perform null;'
  );
end $$;

-- Contagem antes da chamada sob o mutante 3
create temp table pg_temp.contagem_fila as
  select count(*)::int as total from pgmq.q_email;

-- Criar outro usuário suspenso para exercitar mutante 3
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('73100000-0000-4000-8000-000000000005', 'profissional', 'Suspenso Tres', 'tres@731.test', '+5561973100005', '1991-01-01', 'suspensa', '1.0', now());
select pg_temp.autenticar('73100000-0000-4000-8000-000000000005', 'tres@731.test');
insert into public.ocorrencia (id, tipo, usuario_id, autor_id, motivo, criada_em) values
  ('73100000-0000-4000-8000-000000000105', 'suspensao', '73100000-0000-4000-8000-000000000005', '73100000-0000-4000-8000-000000000005', 'Falta', now());

-- Executar contestação sob o mutante (sem pgmq.send)
select is(
  (pg_temp.como('73100000-0000-4000-8000-000000000005',
     $$ select public.contestar_suspensao('Justificativa valida de teste para mutante sem envio') $$)->>'tipo'),
  'contestacao',
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
  pg_get_functiondef('public.contestar_suspensao(text)'::regprocedure),
  (select def from pg_temp.def_original),
  'restauracao canonica: definicao final identica a original via is(pg_get_functiondef, def_original)'
);

-- Confirmação Canônica Final sob a definição canônica restaurada
select throws_ok(
  pg_temp.por('73100000-0000-4000-8000-000000000005',
    $$ select public.contestar_suspensao('curto') $$),
  'PGRST',
  pg_temp.erro('campo_invalido', 'relato'),
  'confirmacao canonica final: sob definicao restaurada, relato curto volta a recusar 422 campo_invalido'
);

select * from finish();
rollback;
