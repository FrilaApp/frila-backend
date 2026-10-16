-- 735_rpc_blindagem_global_catalogo.sql
--
-- Cobertura transversal e auditoria do catálogo das 44 RPCs expostas no schema public:
--   * Censo estrito de rotinas públicas (pg_proc e pg_namespace).
--   * Auditoria de SECURITY DEFINER e search_path="" em 100% das rotinas.
--   * Blindagem absoluta contra acesso anônimo: apenas public.configuracao_do_app
--     possui privilégio de EXECUTE concedido a anon (43 RPCs estritamente negadas).
--   * Revogação universal de EXECUTE do papel público (PUBLIC) em todas as rotinas.
--   * Prova de mutação dinâmica: detecção imediata caso qualquer RPC sofra grant inadvertido a anon.
--   * Prova de idempotência por chave em public.republicar_vaga(uuid, timestamptz, timestamptz, uuid)
--     (fechamento de lacuna transversal do MAPA-LACUNAS-RPCS.md).

begin;

-- 1. Congelamento do relógio e ativação do modo teste ANTES de qualquer inserção/função
insert into privado.ambiente(id, eh_teste)
values (true, true)
on conflict (id) do update set eh_teste = true;

set local "frila.agora" = '2026-11-20 12:00:00+00';
set local "frila.agendador_secret" = 'segredo_teste_agendador_123';

select plan(28);

-- 2. Helpers de autenticação e contexto
create or replace function pg_temp.autenticar(p_id uuid, p_role text default 'authenticated')
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_id::text,
    'role', p_role,
    'aud', 'authenticated'
  )::text, true);
end;
$$;

-- ============================================================================
-- PARTE 1: Censo de Rotinas e Blindagem de Catálogo do Schema public
-- ============================================================================

-- Total de rotinas existentes em public (44 RPCs + 1 event trigger + 3 helpers)
select is(
  (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace),
  48::bigint,
  'censo de catalogo: schema public contem exatamente 48 rotinas catalogadas'
);

-- Total de rotinas declaradas como SECURITY DEFINER (44 RPCs + 1 event trigger rls_auto_enable)
select is(
  (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef = true),
  45::bigint,
  'seguranca de privilegios: exatamente 45 rotinas sao SECURITY DEFINER (44 RPCs + rls_auto_enable)'
);

-- 100% das rotinas de public possuem search_path="" estrito configurado em proconfig
select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proconfig @> array['search_path=""']),
  48::bigint,
  'mitigacao de sequestro de schema: 100% das rotinas (48 de 48) possuem search_path="" estrito'
);

-- Apenas 1 única função possui privilégio de execução concedido ao papel anon
select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and has_function_privilege('anon', p.oid, 'execute')),
  1::bigint,
  'superficie anonima: exatamente 1 rotina em public e executavel pelo papel anon'
);

-- Prova nominal de que a única função executável por anon é configuracao_do_app
select is(
  (select p.proname::text
   from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and has_function_privilege('anon', p.oid, 'execute')),
  'configuracao_do_app'::text,
  'rotina anonima autorizada e estritamente configuracao_do_app'
);

-- 47 rotinas possuem EXECUTE estritamente FALSO para o papel anon
select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and not has_function_privilege('anon', p.oid, 'execute')),
  47::bigint,
  'superficie anonima blindada: 47 de 48 rotinas negam execucao para o papel anon'
);

-- Papel authenticated possui EXECUTE concedido em exatamente 44 RPCs
select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and has_function_privilege('authenticated', p.oid, 'execute')),
  44::bigint,
  'superficie autenticada: exatamente 44 RPCs publicas concedem execucao a authenticated'
);

-- Papel authenticated NÃO possui privilégio em rotinas internas (erro, conta_em_json, perfil_profissional_em_json, rls_auto_enable)
select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and not has_function_privilege('authenticated', p.oid, 'execute')),
  4::bigint,
  'isolamento interno: exatamente 4 rotinas nao-RPC sao inacessiveis a authenticated'
);

-- Revogação explícita de PUBLIC: nenhuma rotina do schema public concede EXECUTE a PUBLIC
select is(
  (select count(*) from information_schema.routine_privileges
   where specific_schema = 'public' and grantee = 'PUBLIC'),
  0::bigint,
  'higiene de privilegios: papel PUBLIC nao possui nenhum grant em rotinas de public'
);

-- ============================================================================
-- PARTE 2: Asserções Nominais de Blindagem em RPCs Críticas contra Papel anon
-- ============================================================================

select ok(not has_function_privilege('anon', 'public.candidatar(uuid)', 'execute'),
  'RPC critica blindada: anon nao executa candidatar');

select ok(not has_function_privilege('anon', 'public.escolher_candidato(uuid)', 'execute'),
  'RPC critica blindada: anon nao executa escolher_candidato');

select ok(not has_function_privilege('anon', 'public.cancelar_posicao(uuid, text)', 'execute'),
  'RPC critica blindada: anon nao executa cancelar_posicao');

select ok(not has_function_privilege('anon', 'public.cancelar_vaga(uuid, text)', 'execute'),
  'RPC critica blindada: anon nao executa cancelar_vaga');

select ok(not has_function_privilege('anon', 'public.fazer_checkin(uuid, integer, timestamp with time zone)', 'execute'),
  'RPC critica blindada: anon nao executa fazer_checkin');

select ok(not has_function_privilege('anon', 'public.fazer_checkout(uuid, integer, timestamp with time zone)', 'execute'),
  'RPC critica blindada: anon nao executa fazer_checkout');

select ok(not has_function_privilege('anon', 'public.confirmar_checkin_manual(uuid)', 'execute'),
  'RPC critica blindada: anon nao executa confirmar_checkin_manual');

select ok(not has_function_privilege('anon', 'public.reabrir_por_atraso(uuid)', 'execute'),
  'RPC critica blindada: anon nao executa reabrir_por_atraso');

select ok(not has_function_privilege('anon', 'public.retirar_candidatura(uuid)', 'execute'),
  'RPC critica blindada: anon nao executa retirar_candidatura');

select ok(not has_function_privilege('anon', 'public.contato_do_turno(uuid)', 'execute'),
  'RPC critica blindada: anon nao executa contato_do_turno');

select ok(not has_function_privilege('anon', 'public.perfil_publico(uuid)', 'execute'),
  'RPC critica blindada: anon nao executa perfil_publico');

select ok(not has_function_privilege('anon', 'public.candidatos_da_vaga(uuid)', 'execute'),
  'RPC critica blindada: anon nao executa candidatos_da_vaga');

select ok(not has_function_privilege('anon', 'public.pedir_revisao_despacho(text)', 'execute'),
  'RPC critica blindada: anon nao executa pedir_revisao_despacho');

select ok(not has_function_privilege('anon', 'public.remover_dispositivo(text)', 'execute'),
  'RPC critica blindada: anon nao executa remover_dispositivo');

-- ============================================================================
-- PARTE 3: Prova Real de Mutação Dinâmica de Privilégio
-- ============================================================================

-- Aplicamos mutação: grant inadvertido a anon em candidatar
grant execute on function public.candidatar(uuid) to anon;

select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and has_function_privilege('anon', p.oid, 'execute')),
  2::bigint,
  'mutante de privilegio: censo detecta imediatamente vazamento de EXECUTE para anon'
);

-- Restauramos a higienização canônica
revoke execute on function public.candidatar(uuid) from anon;

select is(
  (select count(*) from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and has_function_privilege('anon', p.oid, 'execute')),
  1::bigint,
  'restauracao canonica: censo de privilegios anônimos retorna estritamente a 1'
);

-- ============================================================================
-- PARTE 4: Idempotência de Chave em public.republicar_vaga
-- ============================================================================

-- Fixtures para teste de republicar_vaga
insert into public.usuario(id, perfil, telefone, nome, email, nascimento, termos_versao, termos_aceite_em)
values ('11111111-2222-3333-4444-555555555555', 'contratante', '+5561999990001', 'Dono Republicador', 'dono.rep@teste.com', '1990-01-01', '1.0', now());

insert into public.estabelecimento(id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
values ('22222222-2222-3333-4444-555555555555', 'Bar do Dono Republicador', '11222333000199', 'food_service', 'SCLN 305 Bloco B', 'POINT(-47.88 -15.79)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento(estabelecimento_id, usuario_id, papel)
values ('22222222-2222-3333-4444-555555555555', '11111111-2222-3333-4444-555555555555', 'administrador');

-- Cria vaga de origem diretamente no banco para ser republicada
insert into public.vaga(
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, modo, estado, chave_cliente, publicado_por, publicado_em, regiao_administrativa
) values (
  '33333333-2222-3333-4444-555555555555',
  '22222222-2222-3333-4444-555555555555',
  (select id from public.funcao limit 1),
  '2026-11-21 18:00:00+00',
  '2026-11-21 23:00:00+00',
  'Salão Principal',
  'POINT(-47.88 -15.79)'::extensions.geography,
  15000,
  1,
  true,
  true,
  false,
  'Gerente Carlos',
  'urgencia',
  'encerrada',
  '33333333-2222-3333-4444-555555555555',
  '11111111-2222-3333-4444-555555555555',
  '2026-11-20 10:00:00+00',
  'Plano Piloto'
);

-- Autentica como o contratante administrador da casa
select pg_temp.autenticar('11111111-2222-3333-4444-555555555555');

-- Variáveis de controle para as chamadas de republicar_vaga
do $$
declare
  v_chave_idemp uuid := '44444444-4444-4444-4444-444444444444';
  v_res1        jsonb;
  v_res2        jsonb;
  v_res3        jsonb;
  v_id1         uuid;
  v_id2         uuid;
  v_id3         uuid;
begin
  -- 1ª chamada: republica com chave idempotente
  v_res1 := public.republicar_vaga(
    '33333333-2222-3333-4444-555555555555',
    '2026-11-22 18:00:00+00'::timestamptz,
    '2026-11-22 23:00:00+00'::timestamptz,
    v_chave_idemp
  );
  v_id1 := (v_res1->>'vaga_id')::uuid;

  -- 2ª chamada: repete chamada com a MESMA chave idempotente
  v_res2 := public.republicar_vaga(
    '33333333-2222-3333-4444-555555555555',
    '2026-11-22 18:00:00+00'::timestamptz,
    '2026-11-22 23:00:00+00'::timestamptz,
    v_chave_idemp
  );
  v_id2 := (v_res2->>'vaga_id')::uuid;

  -- 3ª chamada: republica com chave DIFERENTE
  v_res3 := public.republicar_vaga(
    '33333333-2222-3333-4444-555555555555',
    '2026-11-22 18:00:00+00'::timestamptz,
    '2026-11-22 23:00:00+00'::timestamptz,
    '55555555-5555-5555-5555-555555555555'::uuid
  );
  v_id3 := (v_res3->>'vaga_id')::uuid;

  -- Grava IDs temporários para asserções pgTAP
  create temporary table pg_temp._teste_idemp as
  select v_id1 as id1, v_id2 as id2, v_id3 as id3;
end;
$$;

-- Asserção 1: A 2ª chamada devolveu o mesmo ID da 1ª chamada
select is(
  (select id2 from pg_temp._teste_idemp),
  (select id1 from pg_temp._teste_idemp),
  'idempotencia de republicar_vaga: 2a chamada com mesma chave devolve mesmo ID da vaga'
);

-- Asserção 2: Exatamente 1 vaga foi criada no banco com a chave v_chave_idemp
select is(
  (select count(*) from public.vaga where chave_cliente = '44444444-4444-4444-4444-444444444444'),
  1::bigint,
  'idempotencia de republicar_vaga: nenhuma vaga duplicada no banco sob repeticao de chave'
);

-- Asserção 3: A 3ª chamada com chave distinta gerou uma nova vaga com ID diferente
select is(
  (select id3 != id1 from pg_temp._teste_idemp),
  true,
  'republicar_vaga com chave distinta gera nova vaga diferenciada'
);

select * from finish();
rollback;
