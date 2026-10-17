-- 728_rpc_candidatos_da_vaga.sql
--
-- Cobertura profunda via pgTAP para a RPC public.candidatos_da_vaga(vaga_id uuid).
-- Top 6 do Mapa de Lacunas de RPCs (MAPA-LACUNAS-RPCS.md).
--
-- Regras de Negócio e Segurança Exercitadas:
--   1. Catálogo e Privilégios:
--      • Função existe no catálogo;
--      • Definida como SECURITY DEFINER com search_path = '' estrito;
--      • Privilégio de EXECUTE revogado de anon e concedido a authenticated.
--   2. Autenticação e Perfis:
--      • Sem sessão (auth.uid() is null): recusa com 401 nao_autenticado;
--      • Chamador profissional concorrente: recusa com 422 perfil_incompativel (RN25 / sigilo entre concorrentes);
--      • Chamador contratante com conta suspensa: recusa com 403 sem_permissao, details: conta_suspensa (RN13).
--   3. Validação de Parâmetros e Existência da Vaga:
--      • vaga_id nulo: recusa com 422 campo_obrigatorio (details: vaga_id);
--      • vaga_id inexistente: recusa com 404 nao_encontrado.
--   4. Isolamento Societário e Permissões de Estabelecimento:
--      • Contratante de outro estabelecimento: recusa com 403 sem_permissao;
--      • Administrador do estabelecimento da vaga: leitura autorizada;
--      • Operador do estabelecimento da vaga: leitura autorizada (privado.eh_membro).
--   5. Resposta Vazia e Filtragem de Máquina de Estados:
--      • Vaga sem candidatos: devolve array JSON vazio '[]'::jsonb (não nulo);
--      • Filtragem estrita de c.estado = 'pendente': candidaturas recusada, retirada e expirada são ignoradas.
--   6. Bloqueio Mútuo Bidirecional (Achado 1 / RF26 / RN10):
--      • Profissional que bloqueou membro do estabelecimento: ocultado silenciosamente;
--      • Profissional bloqueado por membro do estabelecimento: ocultado silenciosamente.
--   7. Ordenação Estrita por Ordem de Chegada (RN06):
--      • A lista é estritamente ordenada por (c.criada_em, c.id);
--      • Candidato que se candidatou antes com nota mais baixa precede candidato posterior com nota mais alta.
--   8. Envelope Canônico de Resposta (Contrato):
--      • Cada elemento contém candidatura_id, criada_em e objeto profissional com id, tipo, nome, funcoes e reputacao.
--   9. Provas de Mutação Real via pg_get_functiondef:
--      • Mutante 1: Omissão da cláusula de bloqueio mútuo (bloqueados passam a aparecer); restaurado dinamicamente;
--      • Mutante 2: Inversão da ordenação por chegada para DESC (o mais recente passa a vir primeiro); restaurado dinamicamente;
--      • Mutante 3: Omissão do filtro c.estado = 'pendente' (não-pendentes passam a vir); restaurado dinamicamente;
--      • Restauração Canônica com is(pg_get_functiondef, def_original) e confirmação final.

begin;

-- Setup de ambiente: isolamento de teste e relógio congelado
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-11-15 12:00:00-03';

select plan(23);

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
  select pg_get_functiondef('public.candidatos_da_vaga(uuid)'::regprocedure) as def;

-- ── 1. Catálogo e Privilégios ─────────────────────────────────────────────────

select has_function(
  'public', 'candidatos_da_vaga', array['uuid'],
  'funcao public.candidatos_da_vaga(uuid) existe no catalogo'
);

select is(
  (select coalesce(p.proconfig, '{}') @> array['search_path=""'] and p.prosecdef
     from pg_proc p
    where p.proname = 'candidatos_da_vaga'
      and p.pronamespace = 'public'::regnamespace),
  true,
  'candidatos_da_vaga e SECURITY DEFINER com search_path="" estrito'
);

select ok(
  not has_function_privilege('anon', 'public.candidatos_da_vaga(uuid)', 'execute'),
  'papel anon nao tem privilegio de EXECUTE em candidatos_da_vaga'
);

select ok(
  has_function_privilege('authenticated', 'public.candidatos_da_vaga(uuid)', 'execute'),
  'papel authenticated tem privilegio de EXECUTE em candidatos_da_vaga'
);

-- ── Setup de Fixtures ─────────────────────────────────────────────────────────

create temp table ids as select
  -- Contratantes
  '72800000-0000-4000-8000-000000000001'::uuid as user_dono_ze,
  '72800000-0000-4000-8000-000000000002'::uuid as user_op_ze,
  '72800000-0000-4000-8000-000000000003'::uuid as user_dono_ze_suspenso,
  '72800000-0000-4000-8000-000000000004'::uuid as user_dona_rita,
  -- Profissionais (contas de usuario)
  '72800000-0000-4000-8000-000000000011'::uuid as user_ana,
  '72800000-0000-4000-8000-000000000012'::uuid as user_bruno,
  '72800000-0000-4000-8000-000000000013'::uuid as user_carla,
  '72800000-0000-4000-8000-000000000014'::uuid as user_daniel,
  '72800000-0000-4000-8000-000000000015'::uuid as user_eduardo,
  '72800000-0000-4000-8000-000000000016'::uuid as user_fernanda,
  '72800000-0000-4000-8000-000000000017'::uuid as user_gabriel,
  -- Profissionais (entidades profissional)
  '72800000-0000-4000-8000-000000000021'::uuid as prof_ana,
  '72800000-0000-4000-8000-000000000022'::uuid as prof_bruno,
  '72800000-0000-4000-8000-000000000023'::uuid as prof_carla,
  '72800000-0000-4000-8000-000000000024'::uuid as prof_daniel,
  '72800000-0000-4000-8000-000000000025'::uuid as prof_eduardo,
  '72800000-0000-4000-8000-000000000026'::uuid as prof_fernanda,
  '72800000-0000-4000-8000-000000000027'::uuid as prof_gabriel,
  -- Estabelecimentos
  '72800000-0000-4000-8000-000000000031'::uuid as estab_ze,
  '72800000-0000-4000-8000-000000000032'::uuid as estab_rita,
  -- Vagas
  '72800000-0000-4000-8000-000000000101'::uuid as vaga_ze_selecao,
  '72800000-0000-4000-8000-000000000102'::uuid as vaga_ze_vazia,
  '72800000-0000-4000-8000-000000000103'::uuid as vaga_rita_selecao,
  -- Posicoes
  '72800000-0000-4000-8000-000000000201'::uuid as pos_ze_selecao,
  '72800000-0000-4000-8000-000000000202'::uuid as pos_ze_vazia,
  '72800000-0000-4000-8000-000000000203'::uuid as pos_rita_selecao,
  -- Candidaturas
  '72800000-0000-4000-8000-000000000501'::uuid as cand_bruno,
  '72800000-0000-4000-8000-000000000502'::uuid as cand_ana,
  '72800000-0000-4000-8000-000000000503'::uuid as cand_carla,
  '72800000-0000-4000-8000-000000000504'::uuid as cand_daniel,
  '72800000-0000-4000-8000-000000000505'::uuid as cand_eduardo,
  '72800000-0000-4000-8000-000000000506'::uuid as cand_fernanda,
  '72800000-0000-4000-8000-000000000507'::uuid as cand_gabriel;

-- Autenticações em auth.users
select pg_temp.autenticar((select user_dono_ze from ids),          'dono_ze@728.test');
select pg_temp.autenticar((select user_op_ze from ids),            'op_ze@728.test');
select pg_temp.autenticar((select user_dono_ze_suspenso from ids), 'suspenso@728.test');
select pg_temp.autenticar((select user_dona_rita from ids),        'rita@728.test');
select pg_temp.autenticar((select user_ana from ids),              'ana@728.test');
select pg_temp.autenticar((select user_bruno from ids),            'bruno@728.test');
select pg_temp.autenticar((select user_carla from ids),            'carla@728.test');
select pg_temp.autenticar((select user_daniel from ids),           'daniel@728.test');
select pg_temp.autenticar((select user_eduardo from ids),          'eduardo@728.test');
select pg_temp.autenticar((select user_fernanda from ids),         'fernanda@728.test');
select pg_temp.autenticar((select user_gabriel from ids),          'gabriel@728.test');

-- Usuários
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('72800000-0000-4000-8000-000000000001', 'contratante', 'Seu Zé', 'dono_ze@728.test', '+5561972800001', '1975-01-01', 'ativa', '1.0', now()),
  ('72800000-0000-4000-8000-000000000002', 'contratante', 'Gerente Zé', 'op_ze@728.test', '+5561972800002', '1988-01-01', 'ativa', '1.0', now()),
  ('72800000-0000-4000-8000-000000000003', 'contratante', 'Zé Suspenso', 'suspenso@728.test', '+5561972800003', '1980-01-01', 'suspensa', '1.0', now()),
  ('72800000-0000-4000-8000-000000000004', 'contratante', 'Dona Rita', 'rita@728.test', '+5561972800004', '1982-01-01', 'ativa', '1.0', now()),
  ('72800000-0000-4000-8000-000000000011', 'profissional', 'Ana Silva', 'ana@728.test', '+5561972800011', '1995-05-10', 'ativa', '1.0', now()),
  ('72800000-0000-4000-8000-000000000012', 'profissional', 'Bruno Souza', 'bruno@728.test', '+5561972800012', '1992-03-15', 'ativa', '1.0', now()),
  ('72800000-0000-4000-8000-000000000013', 'profissional', 'Carla Dias', 'carla@728.test', '+5561972800013', '1996-07-20', 'ativa', '1.0', now()),
  ('72800000-0000-4000-8000-000000000014', 'profissional', 'Daniel Lima', 'daniel@728.test', '+5561972800014', '1990-11-25', 'ativa', '1.0', now()),
  ('72800000-0000-4000-8000-000000000015', 'profissional', 'Eduardo Ramos', 'eduardo@728.test', '+5561972800015', '1994-09-05', 'ativa', '1.0', now()),
  ('72800000-0000-4000-8000-000000000016', 'profissional', 'Fernanda Costa', 'fernanda@728.test', '+5561972800016', '1993-02-18', 'ativa', '1.0', now()),
  ('72800000-0000-4000-8000-000000000017', 'profissional', 'Gabriel Rocha', 'gabriel@728.test', '+5561972800017', '1997-12-30', 'ativa', '1.0', now());

-- Entidades profissional com reputações discriminadas
insert into public.profissional (
  id, usuario_id, ponto_base, taxa_comparecimento, turnos_realizados, aval_positivas, aval_total
) values
  -- Ana: alta reputação (10 de 10)
  ('72800000-0000-4000-8000-000000000021', '72800000-0000-4000-8000-000000000011',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 1.000, 10, 10, 10),
  -- Bruno: reputação moderada (3 de 10)
  ('72800000-0000-4000-8000-000000000022', '72800000-0000-4000-8000-000000000012',
   'POINT(-47.8850 -15.7980)'::extensions.geography, 0.700, 3, 3, 10),
  -- Carla
  ('72800000-0000-4000-8000-000000000023', '72800000-0000-4000-8000-000000000013',
   'POINT(-47.8900 -15.8000)'::extensions.geography, 0.900, 5, 5, 5),
  -- Daniel
  ('72800000-0000-4000-8000-000000000024', '72800000-0000-4000-8000-000000000014',
   'POINT(-47.8920 -15.8050)'::extensions.geography, 0.850, 6, 6, 7),
  -- Eduardo
  ('72800000-0000-4000-8000-000000000025', '72800000-0000-4000-8000-000000000015',
   'POINT(-47.8800 -15.7900)'::extensions.geography, 1.000, 2, 2, 2),
  -- Fernanda
  ('72800000-0000-4000-8000-000000000026', '72800000-0000-4000-8000-000000000016',
   'POINT(-47.8810 -15.7910)'::extensions.geography, 1.000, 4, 4, 4),
  -- Gabriel
  ('72800000-0000-4000-8000-000000000027', '72800000-0000-4000-8000-000000000017',
   'POINT(-47.8830 -15.7930)'::extensions.geography, 1.000, 1, 1, 1);

-- Estabelecimentos
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('72800000-0000-4000-8000-000000000031', 'Bar do Zé 728', '72800000000131', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('72800000-0000-4000-8000-000000000032', 'Buffet da Rita 728', '72800000000132', 'evento', 'CLS 302', 'POINT(-47.8900 -15.8100)'::extensions.geography, 'Plano Piloto');

-- Membros dos estabelecimentos
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('72800000-0000-4000-8000-000000000001', '72800000-0000-4000-8000-000000000031', 'administrador'),
  ('72800000-0000-4000-8000-000000000002', '72800000-0000-4000-8000-000000000031', 'operador'),
  ('72800000-0000-4000-8000-000000000003', '72800000-0000-4000-8000-000000000031', 'administrador'),
  ('72800000-0000-4000-8000-000000000004', '72800000-0000-4000-8000-000000000032', 'administrador');

-- Bloqueios Mútuos (RF26 / RN10):
-- 1. Carla bloqueou Seu Zé (Dono)
insert into public.bloqueio (id, autor_id, bloqueado_id, criado_em) values
  ('72800000-0000-4000-8000-000000000601',
   '72800000-0000-4000-8000-000000000013', '72800000-0000-4000-8000-000000000001',
   '2026-11-01 10:00:00+00');

-- 2. Seu Zé bloqueou Daniel
insert into public.bloqueio (id, autor_id, bloqueado_id, criado_em) values
  ('72800000-0000-4000-8000-000000000602',
   '72800000-0000-4000-8000-000000000001', '72800000-0000-4000-8000-000000000014',
   '2026-11-02 10:00:00+00');

-- Vagas
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values
  -- Vaga 1: Vaga com seleção e múltiplos candidatos
  ('72800000-0000-4000-8000-000000000101', '72800000-0000-4000-8000-000000000031',
   (select id from public.funcao where ativo is true limit 1),
   '2026-11-20 18:00:00+00', '2026-11-20 23:00:00+00', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 18000, 1,
   true, false, false, 'Seu Zé', 'selecao', 'publicada',
   '72800000-0000-4000-8000-000000000901'::uuid,
   '72800000-0000-4000-8000-000000000001'::uuid, '2026-11-10 10:00:00+00'),
  -- Vaga 2: Vaga sem candidaturas
  ('72800000-0000-4000-8000-000000000102', '72800000-0000-4000-8000-000000000031',
   (select id from public.funcao where ativo is true limit 1),
   '2026-11-21 18:00:00+00', '2026-11-21 23:00:00+00', 'CLN 201 Bloco A',
   'POINT(-47.8822 -15.7942)'::extensions.geography, 18000, 1,
   true, false, false, 'Seu Zé', 'selecao', 'publicada',
   '72800000-0000-4000-8000-000000000902'::uuid,
   '72800000-0000-4000-8000-000000000001'::uuid, '2026-11-10 10:00:00+00'),
  -- Vaga 3: Vaga de outro estabelecimento (Rita)
  ('72800000-0000-4000-8000-000000000103', '72800000-0000-4000-8000-000000000032',
   (select id from public.funcao where ativo is true limit 1),
   '2026-11-22 18:00:00+00', '2026-11-22 23:00:00+00', 'CLS 302',
   'POINT(-47.8900 -15.8100)'::extensions.geography, 20000, 1,
   true, false, false, 'Dona Rita', 'selecao', 'publicada',
   '72800000-0000-4000-8000-000000000903'::uuid,
   '72800000-0000-4000-8000-000000000004'::uuid, '2026-11-10 10:00:00+00');

-- Posições
insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id) values
  ('72800000-0000-4000-8000-000000000201', '72800000-0000-4000-8000-000000000101', '2026-11-20 18:00:00+00', '2026-11-20 23:00:00+00', 'aberta', null),
  ('72800000-0000-4000-8000-000000000202', '72800000-0000-4000-8000-000000000102', '2026-11-21 18:00:00+00', '2026-11-21 23:00:00+00', 'aberta', null),
  ('72800000-0000-4000-8000-000000000203', '72800000-0000-4000-8000-000000000103', '2026-11-22 18:00:00+00', '2026-11-22 23:00:00+00', 'aberta', null);

-- Candidaturas na Vaga 101:
-- Note: Bruno chegou em 10:00 com nota menor; Ana chegou em 10:05 com nota maior (RN06).
insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado) values
  ('72800000-0000-4000-8000-000000000501', '72800000-0000-4000-8000-000000000201',
   '72800000-0000-4000-8000-000000000022', '2026-11-15 10:00:00+00', 'pendente'), -- Bruno (10:00)
  ('72800000-0000-4000-8000-000000000502', '72800000-0000-4000-8000-000000000201',
   '72800000-0000-4000-8000-000000000021', '2026-11-15 10:05:00+00', 'pendente'), -- Ana (10:05)
  ('72800000-0000-4000-8000-000000000503', '72800000-0000-4000-8000-000000000201',
   '72800000-0000-4000-8000-000000000023', '2026-11-15 10:10:00+00', 'pendente'), -- Carla (bloqueou dono)
  ('72800000-0000-4000-8000-000000000504', '72800000-0000-4000-8000-000000000201',
   '72800000-0000-4000-8000-000000000024', '2026-11-15 10:15:00+00', 'pendente'), -- Daniel (bloqueado pelo dono)
  ('72800000-0000-4000-8000-000000000505', '72800000-0000-4000-8000-000000000201',
   '72800000-0000-4000-8000-000000000025', '2026-11-15 10:20:00+00', 'recusada'), -- Eduardo (recusada)
  ('72800000-0000-4000-8000-000000000506', '72800000-0000-4000-8000-000000000201',
   '72800000-0000-4000-8000-000000000026', '2026-11-15 10:25:00+00', 'retirada'), -- Fernanda (retirada)
  ('72800000-0000-4000-8000-000000000507', '72800000-0000-4000-8000-000000000201',
   '72800000-0000-4000-8000-000000000027', '2026-11-15 10:30:00+00', 'expirada'); -- Gabriel (expirada)

-- ── 2. Autenticação e Perfis ──────────────────────────────────────────────────

select throws_ok(
  $$ select public.candidatos_da_vaga('72800000-0000-4000-8000-000000000101'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  'sem sessao (auth.uid nulo): recusa com 401 nao_autenticado'
);

select throws_ok(
  pg_temp.por((select user_ana from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids))),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  'chamador profissional concorrente: recusa com 422 perfil_incompativel (sigilo de concorrentes)'
);

select throws_ok(
  pg_temp.por((select user_dono_ze_suspenso from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids))),
  'PGRST',
  pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'contratante com conta suspensa: recusa com 403 sem_permissao (conta_suspensa)'
);

-- ── 3. Validação de Parâmetros e Existência da Vaga ──────────────────────────

select throws_ok(
  pg_temp.por((select user_dono_ze from ids), $$ select public.candidatos_da_vaga(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'vaga_id'),
  'vaga_id nulo: recusa com 422 campo_obrigatorio (details: vaga_id)'
);

select throws_ok(
  pg_temp.por((select user_dono_ze from ids), $$ select public.candidatos_da_vaga('72800000-0000-4000-8000-000000000999'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'vaga_id inexistente: recusa com 404 nao_encontrado'
);

-- ── 4. Isolamento Societário e Permissões de Estabelecimento ─────────────────

select throws_ok(
  pg_temp.por((select user_dona_rita from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids))),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  'contratante de outro estabelecimento: recusa com 403 sem_permissao'
);

-- ── 5. Caminho Feliz, Resposta Vazia e Papeis do Estabelecimento ──────────────

select is(
  pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_vazia from ids))),
  '[]'::jsonb,
  'vaga sem candidatos: devolve array json vazio [] (nao nulo)'
);

select is(
  jsonb_array_length(pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))),
  2,
  'administrador da casa: le com sucesso e devolve array com exatamente 2 candidatos'
);

select is(
  jsonb_array_length(pg_temp.como((select user_op_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))),
  2,
  'operador da casa: le com sucesso e devolve o mesmo array de 2 candidatos'
);

-- ── 6. Regras de Negócio Críticas (RN06 Ordenação de Chegada e RF26/RN10 Bloqueio)

select is(
  (select jsonb_agg(elem->>'candidatura_id')
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))) elem),
  jsonb_build_array(
    (select cand_bruno from ids)::text,
    (select cand_ana from ids)::text
  ),
  'ordenacao estrita de chegada (RN06): Bruno (10:00, nota menor) precede Ana (10:05, nota maior)'
);

select ok(
  not exists (
    select 1
      from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))) elem
     where (elem->>'candidatura_id')::uuid in (
       (select cand_eduardo from ids),
       (select cand_fernanda from ids),
       (select cand_gabriel from ids)
     )
  ),
  'filtragem de estados: candidatos com candidatura recusada, retirada ou expirada nao sao retornados'
);

select ok(
  not exists (
    select 1
      from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))) elem
     where (elem->>'candidatura_id')::uuid = (select cand_carla from ids)
  ),
  'bloqueio mutuo (RF26/RN10): Carla (que bloqueou o Dono) e ocultada silenciosamente'
);

select ok(
  not exists (
    select 1
      from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))) elem
     where (elem->>'candidatura_id')::uuid = (select cand_daniel from ids)
  ),
  'bloqueio mutuo (RF26/RN10): Daniel (bloqueado pelo Dono) e ocultado silenciosamente'
);

-- ── 7. Envelope Canônico de Resposta ──────────────────────────────────────────

select is(
  (select (elem ?& array['candidatura_id', 'criada_em', 'profissional', 'da_equipe'])
      and ((elem->'profissional') ?& array['id', 'tipo', 'nome', 'funcoes', 'reputacao'])
      and ((elem->'profissional'->'reputacao') ?& array['positivas', 'total', 'taxa_comparecimento', 'turnos_realizados', 'turnos_considerados'])
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))) elem
    limit 1),
  true,
  'envelope canonico: cada candidato possui candidatura_id, criada_em, profissional e da_equipe'
);

-- ── 8. Provas de Mutação Real via pg_get_functiondef ─────────────────────────

-- Mutante 1: Omissão da cláusula de bloqueio mútuo (bloqueados Carla e Daniel passam a vir)
do $$
begin
  execute regexp_replace(
    pg_get_functiondef('public.candidatos_da_vaga(uuid)'::regprocedure),
    'and not privado\.bloqueado_com_estabelecimento\([^;]+?\)\),',
    '),'
  );
end $$;

select is(
  jsonb_array_length(pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))),
  4,
  'mutante 1 (sem filtro de bloqueio mutuo): candidatos bloqueados Carla e Daniel passam a aparecer (total 4)'
);

-- Restauração dinâmica do mutante 1
do $$
begin
  execute (select def from pg_temp.def_original);
end $$;

-- Mutante 2: Inversão da ordenação por chegada para DESC (o mais recente vem primeiro)
do $$
begin
  execute replace(
    pg_get_functiondef('public.candidatos_da_vaga(uuid)'::regprocedure),
    'order by c.criada_em, c.id',
    'order by c.criada_em desc, c.id desc'
  );
end $$;

select is(
  (pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))->0->>'candidatura_id')::uuid,
  (select cand_ana from ids),
  'mutante 2 (ordem invertida criada_em desc): Ana (10:05) passa a vir antes de Bruno (10:00)'
);

-- Restauração dinâmica do mutante 2
do $$
begin
  execute (select def from pg_temp.def_original);
end $$;

-- Mutante 3: Omissão do filtro c.estado = 'pendente' (não-pendentes passam a vir)
do $$
begin
  execute replace(
    pg_get_functiondef('public.candidatos_da_vaga(uuid)'::regprocedure),
    'and c.estado = ''pendente''',
    'and true'
  );
end $$;

select is(
  jsonb_array_length(pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))),
  5,
  'mutante 3 (sem filtro de estado pendente): candidaturas recusada, retirada e expirada passam a vir'
);

-- Restauração dinâmica do mutante 3
do $$
begin
  execute (select def from pg_temp.def_original);
end $$;

-- Restauração Canônica Verificada
select is(
  pg_get_functiondef('public.candidatos_da_vaga(uuid)'::regprocedure),
  (select def from pg_temp.def_original),
  'restauracao canonica: definicao final identica a original via is(pg_get_functiondef, def_original)'
);

-- Confirmação Canônica Final sob a definição canônica restaurada
select is(
  (select jsonb_agg(elem->>'candidatura_id')
     from jsonb_array_elements(pg_temp.como((select user_dono_ze from ids), format($$ select public.candidatos_da_vaga(%L) $$, (select vaga_ze_selecao from ids)))) elem),
  jsonb_build_array(
    (select cand_bruno from ids)::text,
    (select cand_ana from ids)::text
  ),
  'confirmacao canonica final: chamada volta a retornar exatamente os 2 candidatos nao bloqueados na ordem de chegada'
);

select * from finish();
rollback;
