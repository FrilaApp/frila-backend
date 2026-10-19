-- 726_rpc_retirar_candidatura.sql
--
-- Cobertura completa da RPC public.retirar_candidatura(candidatura_id uuid)
-- Top 3 do Mapa de Cobertura de RPCs (Rodada 4).
--
-- Regras validadas:
--   1. Permissões de catálogo: SECURITY DEFINER, search_path='', EXECUTE revogado de anon e concedido a authenticated.
--   2. Autenticação e Perfil: 401 sem token, 422 perfil_incompativel para perfil contratante (exigir_perfil('profissional')).
--   3. Validação de entrada e Não-existência / Sigilo:
--      - 422 campo_obrigatorio se candidatura_id is null;
--      - 404 nao_encontrado se candidatura_id inexistente;
--      - 404 nao_encontrado se candidatura_id pertencer a outro profissional (não vaza existência com 403).
--   4. Máquina de Estados de Candidatura (public.estado_candidatura):
--      - 409 candidatura_indisponivel se estado = 'aceita' (RN24: já virou posição confirmada/turno, exige cancelar_posicao);
--      - 409 candidatura_indisponivel se estado = 'recusada';
--      - 409 candidatura_indisponivel se estado = 'expirada'.
--   5. Caminho Feliz (estado 'pendente'):
--      - Devolve envelope jsonb canônico (id, vaga, estado, criada_em, turno_id);
--      - Candidatura atualizada para estado = 'retirada';
--      - turno_id é null (contrato 0.2.32: preenchido estritamente em 'aceita');
--      - Auditoria do ciclo (candidatura_auditoria) registra transição 'pendente' -> 'retirada' em public.auditoria;
--      - Contagem de candidaturas pendentes na posição é decrementada.
--   6. Idempotência / Reenvio:
--      - Rechamada em candidatura já 'retirada' devolve sucesso com o mesmo payload;
--      - Estado permanece 'retirada' sem erro.
--   7. Provas de Mutação Dinâmica via pg_get_functiondef:
--      - Mutante 1: Omissão da mutação para 'retirada' (mantém 'pendente');
--      - Mutante 2: Omissão da trava 409 em estados não-retirada (aceita chamada em 'aceita');
--      - Mutante 3: Omissão da tolerância de idempotência em 'retirada' (falha 409 no reenvio);
--      - Restauração dinâmica após cada mutante via replace inverso.
--
-- Prefixo de IDs: c7260000-0000-4000-8000-0000000000xx.
-- Datas determinísticas, sem now() livre e com rollback limpo.

begin;
select plan(23);

-- Ambiente de teste e relógio congelado
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-15 10:00:00+00', true);

-- ── Helpers ───────────────────────────────────────────────────────────────────

create function pg_temp.autenticar(conta uuid, email text) returns void
language plpgsql as $$
begin
  insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          is_sso_user, is_anonymous)
  values ('00000000-0000-0000-0000-000000000000', conta, 'authenticated', 'authenticated',
          email, '2026-10-01 10:00:00+00', '{"provider":"email"}'::jsonb, '{}'::jsonb,
          '2026-10-01 10:00:00+00', '2026-10-01 10:00:00+00', false, false)
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
  select format('select pg_temp.como(%L, %L)', conta, sql);
$$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'));
$$;

-- ── 1. Catálogo e Permissões ──────────────────────────────────────────────────

select has_function('public', 'retirar_candidatura', array['uuid'],
  'funcao public.retirar_candidatura(uuid) existe no catalogo');

select is(
  (select coalesce(p.proconfig, '{}') @> array['search_path=""'] and p.prosecdef
     from pg_proc p
    where p.proname = 'retirar_candidatura'
      and p.pronamespace = 'public'::regnamespace),
  true,
  'retirar_candidatura e SECURITY DEFINER com search_path="" estrito'
);

select ok(
  not has_function_privilege('anon', 'public.retirar_candidatura(uuid)', 'execute'),
  'papel anon nao tem privilegio de EXECUTE em retirar_candidatura'
);

select ok(
  has_function_privilege('authenticated', 'public.retirar_candidatura(uuid)', 'execute'),
  'papel authenticated tem privilegio de EXECUTE em retirar_candidatura'
);

-- ── Fixtures de Teste ─────────────────────────────────────────────────────────

select pg_temp.autenticar('c7260000-0000-4000-8000-000000000001', 'ze@barze.test');
select pg_temp.autenticar('c7260000-0000-4000-8000-000000000002', 'ana@prof.test');
select pg_temp.autenticar('c7260000-0000-4000-8000-000000000003', 'beto@prof.test');

insert into public.usuario (id, perfil, estado, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('c7260000-0000-4000-8000-000000000001', 'contratante',  'ativa', 'Zé',   '+5561972600001', 'ze@barze.test',  '1980-01-01', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7260000-0000-4000-8000-000000000002', 'profissional', 'ativa', 'Ana',  '+5561972600002', 'ana@prof.test',  '1995-05-10', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7260000-0000-4000-8000-000000000003', 'profissional', 'ativa', 'Beto', '+5561972600003', 'beto@prof.test', '1992-07-20', '2026-09-22', '2026-10-01 10:00:00+00');

insert into public.profissional (id, usuario_id, ponto_base, turnos_realizados, taxa_comparecimento) values
  ('c7260000-0000-4000-8000-000000000020', 'c7260000-0000-4000-8000-000000000002', 'POINT(-47.88 -15.79)'::extensions.geography, 3, 1.000),
  ('c7260000-0000-4000-8000-000000000030', 'c7260000-0000-4000-8000-000000000003', 'POINT(-47.89 -15.80)'::extensions.geography, 2, 1.000);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('c7260000-0000-4000-8000-000000000010', 'Bar do Zé', '72600000000101', 'food_service', 'CLN 201 Bloco A', 'POINT(-47.8840 -15.7960)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c7260000-0000-4000-8000-000000000001', 'c7260000-0000-4000-8000-000000000010', 'administrador');

-- Vagas e Posições do Cenário

-- Vaga 1 (20/11 18h..23h): Modo Seleção, publicada
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7260000-0000-4000-8000-000000000101',
  'c7260000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-20 18:00:00+00', '2026-11-20 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'selecao', 'publicada',
  'c7260000-0000-4000-8000-000000000901'::uuid,
  'c7260000-0000-4000-8000-000000000001'::uuid,
  '2026-11-10 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id) values
  ('c7260000-0000-4000-8000-000000000201', 'c7260000-0000-4000-8000-000000000101',
   '2026-11-20 18:00:00+00', '2026-11-20 23:00:00+00', 'aberta', null);

-- Candidatura 501: Ana, pendente (caminho feliz e idempotência)
insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado) values
  ('c7260000-0000-4000-8000-000000000501', 'c7260000-0000-4000-8000-000000000201',
   'c7260000-0000-4000-8000-000000000020', '2026-11-11 12:00:00+00', 'pendente');

-- Candidatura 502: Beto, pendente na mesma posição (teste de sigilo/isolamento)
insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado) values
  ('c7260000-0000-4000-8000-000000000502', 'c7260000-0000-4000-8000-000000000201',
   'c7260000-0000-4000-8000-000000000030', '2026-11-11 13:00:00+00', 'pendente');

-- Vaga 2 (21/11 18h..23h): Candidatura em estado 'aceita'
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7260000-0000-4000-8000-000000000102',
  'c7260000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-21 18:00:00+00', '2026-11-21 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'selecao', 'preenchida',
  'c7260000-0000-4000-8000-000000000902'::uuid,
  'c7260000-0000-4000-8000-000000000001'::uuid,
  '2026-11-10 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7260000-0000-4000-8000-000000000202', 'c7260000-0000-4000-8000-000000000102',
   '2026-11-21 18:00:00+00', '2026-11-21 23:00:00+00', 'confirmada',
   'c7260000-0000-4000-8000-000000000020', '2026-11-12 10:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7260000-0000-4000-8000-000000000302', 'c7260000-0000-4000-8000-000000000202', null, null, null, 'pendente', 18000, null);

insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado) values
  ('c7260000-0000-4000-8000-000000000503', 'c7260000-0000-4000-8000-000000000202',
   'c7260000-0000-4000-8000-000000000020', '2026-11-11 12:00:00+00', 'aceita');

-- Vaga 3 (22/11 18h..23h): Candidatura em estado 'recusada'
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7260000-0000-4000-8000-000000000103',
  'c7260000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-22 18:00:00+00', '2026-11-22 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'selecao', 'preenchida',
  'c7260000-0000-4000-8000-000000000903'::uuid,
  'c7260000-0000-4000-8000-000000000001'::uuid,
  '2026-11-10 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7260000-0000-4000-8000-000000000203', 'c7260000-0000-4000-8000-000000000103',
   '2026-11-22 18:00:00+00', '2026-11-22 23:00:00+00', 'confirmada',
   'c7260000-0000-4000-8000-000000000030', '2026-11-12 10:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7260000-0000-4000-8000-000000000303', 'c7260000-0000-4000-8000-000000000203', null, null, null, 'pendente', 18000, null);

insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado) values
  ('c7260000-0000-4000-8000-000000000504', 'c7260000-0000-4000-8000-000000000203',
   'c7260000-0000-4000-8000-000000000020', '2026-11-11 12:00:00+00', 'recusada');

-- Vaga 4 (23/11 18h..23h): Candidatura em estado 'expirada'
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7260000-0000-4000-8000-000000000104',
  'c7260000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-23 18:00:00+00', '2026-11-23 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'selecao', 'encerrada',
  'c7260000-0000-4000-8000-000000000904'::uuid,
  'c7260000-0000-4000-8000-000000000001'::uuid,
  '2026-11-10 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id) values
  ('c7260000-0000-4000-8000-000000000204', 'c7260000-0000-4000-8000-000000000104',
   '2026-11-23 18:00:00+00', '2026-11-23 23:00:00+00', 'aberta', null);

insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado) values
  ('c7260000-0000-4000-8000-000000000505', 'c7260000-0000-4000-8000-000000000204',
   'c7260000-0000-4000-8000-000000000020', '2026-11-11 12:00:00+00', 'expirada');

-- Vagas 5 e 6: Para provas de mutação
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7260000-0000-4000-8000-000000000105',
  'c7260000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-24 18:00:00+00', '2026-11-24 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'selecao', 'publicada',
  'c7260000-0000-4000-8000-000000000905'::uuid,
  'c7260000-0000-4000-8000-000000000001'::uuid,
  '2026-11-10 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id) values
  ('c7260000-0000-4000-8000-000000000205', 'c7260000-0000-4000-8000-000000000105',
   '2026-11-24 18:00:00+00', '2026-11-24 23:00:00+00', 'aberta', null);

-- Candidatura 506: Ana, pendente na Vaga 5 (para mutação 1)
insert into public.candidatura (id, posicao_id, profissional_id, criada_em, estado) values
  ('c7260000-0000-4000-8000-000000000506', 'c7260000-0000-4000-8000-000000000205',
   'c7260000-0000-4000-8000-000000000020', '2026-11-11 12:00:00+00', 'pendente');

-- ── 2. Autenticação e Perfis ──────────────────────────────────────────────────

select throws_ok(
  $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000501'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  'sem sessao (auth.uid nulo): recusa com 401 nao_autenticado'
);

select throws_ok(
  pg_temp.por('c7260000-0000-4000-8000-000000000001', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000501'::uuid) $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  'contratante chamando: recusa com 422 perfil_incompativel'
);

-- ── 3. Validação de Entrada e Sigilo ──────────────────────────────────────────

select throws_ok(
  pg_temp.por('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'candidatura_id'),
  'candidatura_id nulo: recusa com 422 campo_obrigatorio'
);

select throws_ok(
  pg_temp.por('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000999'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'candidatura_id inexistente: recusa com 404 nao_encontrado'
);

select throws_ok(
  pg_temp.por('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000502'::uuid) $$),
  'PGRST',
  pg_temp.erro('nao_encontrado'),
  'candidatura de outro profissional: recusa com 404 nao_encontrado (sigilo, nao vaza existencia)'
);

-- ── 4. Recusas por Estado de Negócio (409 candidatura_indisponivel) ───────────

select throws_ok(
  pg_temp.por('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000503'::uuid) $$),
  'PGRST',
  pg_temp.erro('candidatura_indisponivel'),
  'candidatura em estado aceita: recusa com 409 candidatura_indisponivel (RN24)'
);

select throws_ok(
  pg_temp.por('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000504'::uuid) $$),
  'PGRST',
  pg_temp.erro('candidatura_indisponivel'),
  'candidatura em estado recusada: recusa com 409 candidatura_indisponivel'
);

select throws_ok(
  pg_temp.por('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000505'::uuid) $$),
  'PGRST',
  pg_temp.erro('candidatura_indisponivel'),
  'candidatura em estado expirada: recusa com 409 candidatura_indisponivel'
);

-- ── 5. Caminho Feliz: Retirada de Candidatura Pendente ────────────────────────

select is(
  (pg_temp.como('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000501'::uuid) $$) ?& array['id', 'vaga', 'estado', 'criada_em', 'turno_id']),
  true,
  'caminho feliz: envelope devolve id, vaga, estado, criada_em e turno_id'
);

select is(
  (select k.estado || '|' || (k.turno_id is null)::text
     from (select pg_temp.como('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000501'::uuid) $$) as r) sub,
          jsonb_to_record(sub.r) as k(estado text, turno_id uuid)),
  'retirada|true',
  'caminho feliz: estado retornado e retirada e turno_id e null'
);

select is(
  (select c.estado from public.candidatura c where c.id = 'c7260000-0000-4000-8000-000000000501'),
  'retirada'::public.estado_candidatura,
  'caminho feliz: estado persistido em public.candidatura e retirada'
);

select is(
  (select count(*)::int from privado.auditoria_ciclo a
    where a.entidade = 'candidatura'
      and a.entidade_id = 'c7260000-0000-4000-8000-000000000501'
      and a.estado_anterior = 'pendente'
      and a.estado_novo = 'retirada'),
  1,
  'caminho feliz: gatilho candidatura_auditoria gravou transicao pendente -> retirada'
);

select is(
  (select count(*)::int from public.candidatura c
    where c.posicao_id = 'c7260000-0000-4000-8000-000000000201' and c.estado = 'pendente'),
  1,
  'caminho feliz: contagem de pendentes na posicao decrementou (resta apenas Beto)'
);

-- ── 6. Idempotência e Reenvio ─────────────────────────────────────────────────

select is(
  (pg_temp.como('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000501'::uuid) $$)->>'estado'),
  'retirada',
  'idempotencia: rechamada em candidatura ja retirada devolve envelope com estado retirada'
);

select is(
  (select c.estado from public.candidatura c where c.id = 'c7260000-0000-4000-8000-000000000501'),
  'retirada'::public.estado_candidatura,
  'idempotencia: estado no banco permanece retirada sem erro'
);

-- ── 7. Provas de Mutação Real via pg_get_functiondef ─────────────────────────

-- Mutação 1: Omissão do UPDATE de estado para 'retirada' (grava 'pendente')
do $$
begin
  execute replace(
    pg_get_functiondef('public.retirar_candidatura(uuid)'::regprocedure),
    'set estado = ''retirada''',
    'set estado = ''pendente'''
  );
end $$;

select is(
  (pg_temp.como('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000506'::uuid) $$)->>'estado'),
  'pendente',
  'mutante 1 (sem update para retirada): chamada executaria mas estado continuaria pendente; prova discriminacao do update'
);

-- Restauração dinâmica da mutação 1
do $$
begin
  execute replace(
    pg_get_functiondef('public.retirar_candidatura(uuid)'::regprocedure),
    'set estado = ''pendente''',
    'set estado = ''retirada'''
  );
end $$;

-- Mutação 2: Omissão da trava 409 em estados não-retirada
do $$
begin
  execute replace(
    pg_get_functiondef('public.retirar_candidatura(uuid)'::regprocedure),
    'elsif v_estado <> ''retirada'' then',
    'elsif false and v_estado <> ''retirada'' then'
  );
end $$;

select is(
  (pg_temp.como('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000503'::uuid) $$)->>'estado'),
  'aceita',
  'mutante 2 (sem trava 409): chamada em aceita passaria sem 409; prova discriminacao da trava de estado'
);

-- Restauração dinâmica da mutação 2
do $$
begin
  execute replace(
    pg_get_functiondef('public.retirar_candidatura(uuid)'::regprocedure),
    'elsif false and v_estado <> ''retirada'' then',
    'elsif v_estado <> ''retirada'' then'
  );
end $$;

-- Mutação 3: Omissão da tolerância de idempotência em 'retirada' (rejeita 409 na rechamada)
do $$
begin
  execute replace(
    pg_get_functiondef('public.retirar_candidatura(uuid)'::regprocedure),
    'elsif v_estado <> ''retirada'' then',
    'else'
  );
end $$;

select throws_ok(
  pg_temp.por('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000501'::uuid) $$),
  'PGRST',
  pg_temp.erro('candidatura_indisponivel'),
  'mutante 3 (sem idempotencia): rechamada em retirada falharia com 409; prova discriminacao da idempotencia'
);

-- Restauração dinâmica da mutação 3
do $$
begin
  execute replace(
    pg_get_functiondef('public.retirar_candidatura(uuid)'::regprocedure),
    'else',
    'elsif v_estado <> ''retirada'' then'
  );
end $$;

-- Confirmação canônica final
select throws_ok(
  pg_temp.por('c7260000-0000-4000-8000-000000000002', $$ select public.retirar_candidatura('c7260000-0000-4000-8000-000000000503'::uuid) $$),
  'PGRST',
  pg_temp.erro('candidatura_indisponivel'),
  'restauracao canonica: chamada em aceita volta a recusar 409 candidatura_indisponivel'
);

select * from finish();
rollback;
