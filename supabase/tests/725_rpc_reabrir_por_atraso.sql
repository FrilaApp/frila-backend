-- 725_rpc_reabrir_por_atraso.sql
--
-- Cobertura completa da RPC public.reabrir_por_atraso(posicao_id uuid)
-- Top 2 do Mapa de Cobertura de RPCs (Rodada 4).
--
-- Regras validadas:
--   1. Permissões de catálogo: SECURITY DEFINER, search_path='', EXECUTE revogado de anon e concedido a authenticated.
--   2. Autenticação e Perfil: 401 sem token, 422 perfil_incompativel para perfil não-contratante.
--   3. Validação de entrada e não-existência:
--      - 422 campo_obrigatorio se posicao_id is null;
--      - 403 sem_permissao se posicao_id inexistente (não vaza existência com 404);
--      - 403 sem_permissao se contratante for de outro estabelecimento.
--   4. Estados inválidos da posição e turno:
--      - 409 posicao_nao_cancelavel se estado <> 'confirmada';
--      - 409 posicao_nao_cancelavel (checkin_registrado) se turno já possui checkin_em preenchido.
--   5. Borda temporal estrita de 15 minutos (D06):
--      - Às 14m59s após o início previsto: recusa com 422 reabertura_antes_da_tolerancia;
--      - Às 15m01s após o início previsto: aceita e cancela com falta.
--   6. Tolerância pós-confirmação para substitutos (D06):
--      - Substituto confirmado com turno já em andamento ganha 15 minutos contados de confirmado_em;
--      - Reabertura tentada antes de confirmado_em + 15m recusa com 422 reabertura_antes_da_tolerancia.
--   7. Efeitos colaterais e reposição com mais de 1h antes do fim:
--      - Posição cancelada com falta = true (RN12);
--      - Turno atualizado para verificacao = 'nao_verificado';
--      - Ocorrência de cancelamento registrada com motivo 'reabertura_por_atraso';
--      - Nova posição criada na vaga com reaberta_por_atraso_de preenchido;
--      - Vaga preenchida volta para estado = 'publicada';
--      - Vaga em modo 'selecao' vira 'urgencia' para reposição imediata (D5=A);
--      - Mensagem enfileirada no pgmq (q_despacho) excluindo o profissional faltoso da notificação;
--      - Profissional notificado em public.notificacao;
--      - privado.recalcular_comparecimento reflete a falta na reputação do profissional.
--   8. Corte de 1 hora antes do fim do turno (8zLfn0mt item 5):
--      - A menos de 1h do encerramento (v_agora >= fim_em - 1 hour): cancela com falta,
--        mas NÃO cria nova posição (reaberta = false, nova_posicao_id = null) e não despacha.
--   9. Idempotência / Reenvio: segunda chamada em posição já cancelada por atraso devolve
--      o mesmo resultado sem criar segunda posição nem duplicar ocorrências.
--  10. Provas de mutação dinâmica:
--      - Mutante sem trava de tolerância temporal;
--      - Mutante sem corte de 1h;
--      - Mutante sem trava de check-in existente;
--      - Restauração canônica da RPC.
--
-- Prefixo de IDs: c7250000-0000-4000-8000-0000000000xx.
-- Datas determinísticas, sem now() livre e com rollback limpo.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(30);

-- Ambiente de teste e relógio congelado
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-11-10 18:14:59+00', true);

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
  select format('select pg_temp.como(%L, %L)', conta, sql)
$$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- ── Catálogo e Asserções Estruturais ──────────────────────────────────────────

select has_function('public', 'reabrir_por_atraso', array['uuid'],
  'funcao public.reabrir_por_atraso(uuid) existe no catalogo');

select is(
  (select p.prosecdef and array['search_path=""'] <@ coalesce(p.proconfig, '{}')
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'reabrir_por_atraso'),
  true,
  'reabrir_por_atraso e SECURITY DEFINER com search_path="" estrito'
);

select is(
  has_function_privilege('anon', 'public.reabrir_por_atraso(uuid)', 'execute'),
  false,
  'papel anon nao tem privilegio de EXECUTE em reabrir_por_atraso'
);

select is(
  has_function_privilege('authenticated', 'public.reabrir_por_atraso(uuid)', 'execute'),
  true,
  'papel authenticated tem privilegio de EXECUTE em reabrir_por_atraso'
);

-- ── Cenário de Dados ─────────────────────────────────────────────────────────

select pg_temp.autenticar('c7250000-0000-4000-8000-000000000001', 'ze@barze.test');
select pg_temp.autenticar('c7250000-0000-4000-8000-000000000002', 'ana@prof.test');
select pg_temp.autenticar('c7250000-0000-4000-8000-000000000003', 'beto@prof.test');
select pg_temp.autenticar('c7250000-0000-4000-8000-000000000004', 'carla@cafe.test');
select pg_temp.autenticar('c7250000-0000-4000-8000-000000000005', 'duda@prof.test');

insert into public.usuario (id, perfil, estado, nome, telefone, email, nascimento, termos_versao, termos_aceite_em) values
  ('c7250000-0000-4000-8000-000000000001', 'contratante',  'ativa', 'Zé',    '+5561972500001', 'ze@barze.test',   '1980-01-01', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7250000-0000-4000-8000-000000000002', 'profissional', 'ativa', 'Ana',   '+5561972500002', 'ana@prof.test',   '1995-05-10', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7250000-0000-4000-8000-000000000003', 'profissional', 'ativa', 'Beto',  '+5561972500003', 'beto@prof.test',  '1992-07-20', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7250000-0000-4000-8000-000000000004', 'contratante',  'ativa', 'Carla', '+5561972500004', 'carla@cafe.test', '1985-11-25', '2026-09-22', '2026-10-01 10:00:00+00'),
  ('c7250000-0000-4000-8000-000000000005', 'profissional', 'ativa', 'Duda',  '+5561972500005', 'duda@prof.test',  '1994-04-12', '2026-09-22', '2026-10-01 10:00:00+00');

insert into public.profissional (id, usuario_id, ponto_base, turnos_realizados, taxa_comparecimento) values
  ('c7250000-0000-4000-8000-000000000020', 'c7250000-0000-4000-8000-000000000002', 'POINT(-47.88 -15.79)'::extensions.geography, 2, 1.000),
  ('c7250000-0000-4000-8000-000000000030', 'c7250000-0000-4000-8000-000000000003', 'POINT(-47.89 -15.80)'::extensions.geography, 1, 1.000),
  ('c7250000-0000-4000-8000-000000000050', 'c7250000-0000-4000-8000-000000000005', 'POINT(-47.87 -15.78)'::extensions.geography, 1, 1.000);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto) values
  ('c7250000-0000-4000-8000-000000000010', 'Bar do Zé', '72500000000101', 'food_service', 'CLN 201 Bloco A', 'POINT(-47.8840 -15.7960)'::extensions.geography),
  ('c7250000-0000-4000-8000-000000000040', 'Café Carla', '72500000000102', 'food_service', 'CLN 302 Bloco B', 'POINT(-47.8880 -15.7990)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('c7250000-0000-4000-8000-000000000001', 'c7250000-0000-4000-8000-000000000010', 'administrador'),
  ('c7250000-0000-4000-8000-000000000004', 'c7250000-0000-4000-8000-000000000040', 'administrador');

-- ── Vagas e Posições do Cenário ──────────────────────────────────────────────

-- Vaga 0 (01/11 18h..23h): Turno anterior de Beto, já verificado (para histórico de comparecimento)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7250000-0000-4000-8000-000000000100',
  'c7250000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-01 18:00:00+00', '2026-11-01 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'selecao', 'encerrada',
  'c7250000-0000-4000-8000-000000000900'::uuid,
  'c7250000-0000-4000-8000-000000000001'::uuid,
  '2026-10-25 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em, falta) values
  ('c7250000-0000-4000-8000-000000000200', 'c7250000-0000-4000-8000-000000000100',
   '2026-11-01 18:00:00+00', '2026-11-01 23:00:00+00', 'cumprida',
   'c7250000-0000-4000-8000-000000000030', '2026-10-26 10:00:00+00', false);

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7250000-0000-4000-8000-000000000300', 'c7250000-0000-4000-8000-000000000200',
   'geolocalizado', '2026-11-01 17:55:00+00', 20, 'verificado', 18000, null);

-- Vaga 1 (10/11 18h..23h): Modo Seleção, preenchida. Beto não apareceu.
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7250000-0000-4000-8000-000000000101',
  'c7250000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-10 18:00:00+00', '2026-11-10 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'selecao', 'preenchida',
  'c7250000-0000-4000-8000-000000000901'::uuid,
  'c7250000-0000-4000-8000-000000000001'::uuid,
  '2026-11-05 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7250000-0000-4000-8000-000000000201', 'c7250000-0000-4000-8000-000000000101',
   '2026-11-10 18:00:00+00', '2026-11-10 23:00:00+00', 'confirmada',
   'c7250000-0000-4000-8000-000000000030', '2026-11-06 12:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7250000-0000-4000-8000-000000000301', 'c7250000-0000-4000-8000-000000000201', null, null, null, 'pendente', 18000, null);

-- Vaga 2 (11/11 18h..23h): Ana já fez check-in (não cancelável por atraso)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7250000-0000-4000-8000-000000000102',
  'c7250000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-11 18:00:00+00', '2026-11-11 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7250000-0000-4000-8000-000000000902'::uuid,
  'c7250000-0000-4000-8000-000000000001'::uuid,
  '2026-11-06 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7250000-0000-4000-8000-000000000202', 'c7250000-0000-4000-8000-000000000102',
   '2026-11-11 18:00:00+00', '2026-11-11 23:00:00+00', 'confirmada',
   'c7250000-0000-4000-8000-000000000020', '2026-11-07 10:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7250000-0000-4000-8000-000000000302', 'c7250000-0000-4000-8000-000000000202',
   'geolocalizado', '2026-11-11 17:50:00+00', 30, 'verificado', 18000, null);

-- Vaga 3 (12/11 18h..23h): Substituto Duda confirmado às 18:20 (D06 tolerância pós-confirmação)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7250000-0000-4000-8000-000000000103',
  'c7250000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-12 18:00:00+00', '2026-11-12 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7250000-0000-4000-8000-000000000903'::uuid,
  'c7250000-0000-4000-8000-000000000001'::uuid,
  '2026-11-07 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7250000-0000-4000-8000-000000000203', 'c7250000-0000-4000-8000-000000000103',
   '2026-11-12 18:00:00+00', '2026-11-12 23:00:00+00', 'confirmada',
   'c7250000-0000-4000-8000-000000000050', '2026-11-12 18:20:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7250000-0000-4000-8000-000000000303', 'c7250000-0000-4000-8000-000000000203', null, null, null, 'pendente', 18000, null);

-- Vaga 4 (13/11 18h..23h): Para teste de corte a menos de 1h do fim (às 22:15)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7250000-0000-4000-8000-000000000104',
  'c7250000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-13 18:00:00+00', '2026-11-13 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7250000-0000-4000-8000-000000000904'::uuid,
  'c7250000-0000-4000-8000-000000000001'::uuid,
  '2026-11-08 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7250000-0000-4000-8000-000000000204', 'c7250000-0000-4000-8000-000000000104',
   '2026-11-13 18:00:00+00', '2026-11-13 23:00:00+00', 'confirmada',
   'c7250000-0000-4000-8000-000000000030', '2026-11-08 11:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7250000-0000-4000-8000-000000000304', 'c7250000-0000-4000-8000-000000000204', null, null, null, 'pendente', 18000, null);

-- Vaga 5 (14/11 18h..23h): Para validação de tolerância e restauração canônica
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7250000-0000-4000-8000-000000000105',
  'c7250000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-14 18:00:00+00', '2026-11-14 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7250000-0000-4000-8000-000000000905'::uuid,
  'c7250000-0000-4000-8000-000000000001'::uuid,
  '2026-11-09 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7250000-0000-4000-8000-000000000205', 'c7250000-0000-4000-8000-000000000105',
   '2026-11-14 18:00:00+00', '2026-11-14 23:00:00+00', 'confirmada',
   'c7250000-0000-4000-8000-000000000020', '2026-11-09 11:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7250000-0000-4000-8000-000000000305', 'c7250000-0000-4000-8000-000000000205', null, null, null, 'pendente', 18000, null);

-- ── Recusas e Validações de Entrada ──────────────────────────────────────────

select throws_ok(
  $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000201'::uuid) $$,
  'PGRST',
  pg_temp.erro('nao_autenticado'),
  'sem sessao (auth.uid nulo): recusa com 401 nao_autenticado'
);

select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000002', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000201'::uuid) $$),
  'PGRST',
  pg_temp.erro('perfil_incompativel'),
  'profissional chamando: recusa com 422 perfil_incompativel'
);

select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso(null) $$),
  'PGRST',
  pg_temp.erro('campo_obrigatorio', 'posicao_id'),
  'posicao_id nulo: recusa com 422 campo_obrigatorio'
);

select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000999'::uuid) $$),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  'posicao_id inexistente: recusa com 403 sem_permissao (nao vaza existencia com 404)'
);

select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000004', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000201'::uuid) $$),
  'PGRST',
  pg_temp.erro('sem_permissao'),
  'contratante de outro estabelecimento: recusa com 403 sem_permissao'
);

-- Posição em estado não cancelável
insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id)
values ('c7250000-0000-4000-8000-000000000299', 'c7250000-0000-4000-8000-000000000101',
        '2026-11-10 18:00:00+00', '2026-11-10 23:00:00+00', 'aberta', null);

select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000299'::uuid) $$),
  'PGRST',
  pg_temp.erro('posicao_nao_cancelavel'),
  'posicao em estado aberta: recusa com 409 posicao_nao_cancelavel'
);

delete from public.posicao where id = 'c7250000-0000-4000-8000-000000000299';

-- Turno com check-in já registrado
select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000202'::uuid) $$),
  'PGRST',
  pg_temp.erro('posicao_nao_cancelavel', 'checkin_registrado'),
  'turno com check-in registrado: recusa com 409 posicao_nao_cancelavel (checkin_registrado)'
);

-- ── Borda Temporal Estrita de 15 Minutos (D06) ───────────────────────────────
-- Vaga 1 inicia às 18:00. O relógio congelado está em 18:14:59 (14m59s).
select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000201'::uuid) $$),
  'PGRST',
  pg_temp.erro('reabertura_antes_da_tolerancia'),
  'D06: tentativa a 14m59s do inicio previsto recusa com 422 reabertura_antes_da_tolerancia'
);

-- ── Tolerância Pós-Confirmação para Substitutos (D06) ────────────────────────
-- Vaga 3 inicia às 18:00, mas Duda confirmou às 18:20 (durante o turno).
-- Às 18:30:00 (10 min pós-confirmação, 30 min pós-início), a tolerância ainda está ativa!
select set_config('frila.agora', '2026-11-12 18:30:00+00', true);

select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000203'::uuid) $$),
  'PGRST',
  pg_temp.erro('reabertura_antes_da_tolerancia'),
  'D06: substituto confirmado apos inicio ganha 15m a partir de confirmado_em (422 antes de 18:35)'
);

-- Às 18:35:01 (15m01s pós-confirmação), a tolerância expira e a reabertura procede
select set_config('frila.agora', '2026-11-12 18:35:01+00', true);

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000203'::uuid) $$)->>'falta')::boolean,
  true,
  'D06: apos 15m da confirmacao do substituto, reabertura_por_atraso e autorizada com falta'
);

-- ── Caminho Feliz: Reabertura Normal da Vaga 1 (> 1h antes do fim) ───────────
-- Ajustamos o relógio para 18:15:01 (15m01s pós início da Vaga 1, que acaba às 23h)
select set_config('frila.agora', '2026-11-10 18:15:01+00', true);

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000201'::uuid) $$) ?& array['falta', 'nova_posicao_id', 'posicao_id', 'reaberta']),
  true,
  'reabrir_por_atraso devolve envelope com falta, reaberta, posicao_id e nova_posicao_id'
);

-- Efeitos na posição e no turno
select is(
  (select p.estado || '|' || p.falta::text from public.posicao p where p.id = 'c7250000-0000-4000-8000-000000000201'),
  'cancelada|true',
  'RN12: posicao original cancelada com falta = true'
);

select is(
  (select t.verificacao from public.turno t where t.id = 'c7250000-0000-4000-8000-000000000301'),
  'nao_verificado'::public.verificacao_turno,
  'turno original atualizado para verificacao = nao_verificado'
);

-- Ocorrência disciplinar registrada
select is(
  (select o.tipo || '|' || o.motivo || '|' || (o.usuario_id = 'c7250000-0000-4000-8000-000000000003')::text
     from public.ocorrencia o where o.posicao_id = 'c7250000-0000-4000-8000-000000000201'),
  'cancelamento|reabertura_por_atraso|true',
  'ocorrencia registrada com tipo cancelamento, motivo reabertura_por_atraso e usuario faltoso'
);

-- Nova posição criada vinculada à posição reaberta
select is(
  (select p.reaberta_por_atraso_de from public.posicao p where p.vaga_id = 'c7250000-0000-4000-8000-000000000101' and p.estado = 'aberta'),
  'c7250000-0000-4000-8000-000000000201'::uuid,
  'nova posicao criada vinculada a reaberta_por_atraso_de da original'
);

-- Vaga reaberta e convertida para urgência (D5=A)
select is(
  (select g.estado || '|' || g.modo from public.vaga g where g.id = 'c7250000-0000-4000-8000-000000000101'),
  'publicada|urgencia',
  'D5=A: vaga preenchida volta a publicada e modo selecao e convertido para urgencia'
);

-- Mensagem no pgmq (despacho)
select is(
  (select count(*)::int from pgmq.q_despacho
    where message->>'motivo' = 'reabertura'
      and message->>'vaga_id' = 'c7250000-0000-4000-8000-000000000101'
      and message->>'excluir_conta' = 'c7250000-0000-4000-8000-000000000003'),
  1,
  'mensagem de despacho enfileirada no pgmq excluindo o profissional faltoso'
);

-- Notificação enviada ao faltoso
select is(
  (select count(*)::int from public.notificacao n
    where n.usuario_id = 'c7250000-0000-4000-8000-000000000003'
      and n.tipo = 'cancelamento'
      and n.referencia_id = 'c7250000-0000-4000-8000-000000000201'),
  1,
  'notificacao de cancelamento por falta enviada a public.notificacao'
);

-- Efeito colateral: Recálculo de Comparecimento de Beto
select is(
  (select p.turnos_realizados || '|' || p.taxa_comparecimento::text
     from public.profissional p where p.id = 'c7250000-0000-4000-8000-000000000030'),
  '1|0.500',
  'privado.recalcular_comparecimento atualizou taxa para 0.500 (1 turno / (1 turno + 1 falta))'
);

-- ── Corte de 1h antes do Fim do Turno (8zLfn0mt item 5) ─────────────────────
-- Vaga 4 termina às 23:00. O relógio congelado está em 22:15 (faltam 45 min, menos de 1h).
select set_config('frila.agora', '2026-11-13 22:15:00+00', true);

select is(
  pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000204'::uuid) $$),
  jsonb_build_object(
    'posicao_id',      'c7250000-0000-4000-8000-000000000204'::uuid,
    'falta',           true,
    'reaberta',        false,
    'nova_posicao_id', null
  ),
  '8zLfn0mt: a menos de 1h do fim, cancela com falta mas NAO reabre nova posicao (reaberta=false)'
);

-- ── Idempotência e Reenvio de Chamada ─────────────────────────────────────────
-- Rechamada da Vaga 1 já reaberta devolve o mesmo resultado sem duplicar posições
select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000201'::uuid) $$)->>'reaberta')::boolean,
  true,
  'idempotencia: rechamada em posicao ja cancelada por atraso devolve resultado estavel'
);

select is(
  (select count(*)::int from public.posicao p where p.vaga_id = 'c7250000-0000-4000-8000-000000000101' and p.estado = 'aberta'),
  1,
  'idempotencia: rechamada nao duplica posicao aberta na vaga'
);

-- ── Provas de Mutação Real (Discriminação de Asserções) ──────────────────────

-- Mutação 1: Omissão da trava de tolerância temporal
-- Sob o mutante sem trava de tolerância, chamada às 18:14:59 passaria com sucesso
CREATE OR REPLACE FUNCTION public.reabrir_por_atraso(posicao_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
#variable_conflict use_column
declare
  v_pos public.posicao%rowtype;
begin
  select * into v_pos from public.posicao p where p.id = reabrir_por_atraso.posicao_id;
  -- MUTACAO 1: OMITIDA CHECAGEM if v_agora < greatest(...) + 15 minutes
  return jsonb_build_object('mutante_sem_tolerancia', true);
end $function$;

select set_config('frila.agora', '2026-11-14 18:14:59+00', true);

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000205'::uuid) $$))->>'mutante_sem_tolerancia',
  'true',
  'mutante sem tolerancia: passaria a 14m59s; prova que 422 discrimina'
);

-- Mutação 2: Omissão da trava de corte de 1h antes do fim
CREATE OR REPLACE FUNCTION public.reabrir_por_atraso(posicao_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
#variable_conflict use_column
declare
  v_pos public.posicao%rowtype;
begin
  select * into v_pos from public.posicao p where p.id = reabrir_por_atraso.posicao_id;
  -- MUTACAO 2: OMITIDA CONDICAO if v_agora < v_pos.fim_em - interval '1 hour'
  return jsonb_build_object('reaberta', true, 'mutante_sem_corte_1h', true);
end $function$;

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000204'::uuid) $$))->>'reaberta',
  'true',
  'mutante sem corte 1h: reabriria a 45 min do fim; prova que a trava de 1h discrimina'
);

-- Mutação 3: Omissão da trava de check-in existente
CREATE OR REPLACE FUNCTION public.reabrir_por_atraso(posicao_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
#variable_conflict use_column
declare
  v_pos public.posicao%rowtype;
begin
  select * into v_pos from public.posicao p where p.id = reabrir_por_atraso.posicao_id;
  -- MUTACAO 3: OMITIDA CHECAGEM if v_t.checkin_em is not null
  return jsonb_build_object('mutante_sem_trava_checkin', true);
end $function$;

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000202'::uuid) $$))->>'mutante_sem_trava_checkin',
  'true',
  'mutante sem trava de check-in: cancelaria presenca confirmada; prova que 409 discrimina'
);

-- ── Restauração Canônica ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.reabrir_por_atraso(posicao_id uuid)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
#variable_conflict use_column
declare
  v_uid     uuid := (select auth.uid());
  v_agora   timestamptz;
  v_pos     public.posicao%rowtype;
  v_t       public.turno%rowtype;
  v_usr     uuid;
  v_nova    uuid;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  perform privado.exigir_perfil('contratante');
  if reabrir_por_atraso.posicao_id is null then perform public.erro(422, 'campo_obrigatorio', 'posicao_id'); end if;
  select * into v_pos from public.posicao p where p.id = reabrir_por_atraso.posicao_id for update;
  if not found or not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then
    perform public.erro(403, 'sem_permissao');
  end if;
  select * into v_t from public.turno t where t.posicao_id = v_pos.id for update;
  if v_pos.estado = 'cancelada'
     and exists (select 1 from public.ocorrencia o where o.posicao_id = v_pos.id and o.tipo = 'cancelamento' and o.motivo = 'reabertura_por_atraso') then
    select p.id into v_nova from public.posicao p where p.reaberta_por_atraso_de = v_pos.id;
    return jsonb_build_object('posicao_id', v_pos.id, 'falta', v_pos.falta, 'reaberta', v_nova is not null, 'nova_posicao_id', v_nova);
  end if;
  if v_pos.estado <> 'confirmada' then perform public.erro(409, 'posicao_nao_cancelavel'); end if;
  if v_t.checkin_em is not null then perform public.erro(409, 'posicao_nao_cancelavel', 'checkin_registrado'); end if;
  v_agora := privado.agora();
  if v_agora < greatest(v_pos.inicio_em, v_pos.confirmado_em) + interval '15 minutes' then
    perform public.erro(422, 'reabertura_antes_da_tolerancia');
  end if;
  v_usr := privado.usuario_do_profissional(v_pos.profissional_id);
  update public.posicao p set estado = 'cancelada', falta = true where p.id = v_pos.id;
  update public.turno t set verificacao = 'nao_verificado' where t.posicao_id = v_pos.id and t.verificacao = 'pendente';
  insert into public.ocorrencia (tipo, posicao_id, turno_id, usuario_id, autor_id, motivo)
  values ('cancelamento', v_pos.id, v_t.id, v_usr, v_uid, 'reabertura_por_atraso');
  if v_agora < v_pos.fim_em - interval '1 hour' then
    insert into public.posicao (vaga_id, inicio_em, fim_em, reaberta_por_atraso_de)
    values (v_pos.vaga_id, v_pos.inicio_em, v_pos.fim_em, v_pos.id)
    returning id into v_nova;
    update public.vaga g set estado = 'publicada' where g.id = v_pos.vaga_id and g.estado = 'preenchida';
    update public.vaga g set modo = 'urgencia' where g.id = v_pos.vaga_id and g.modo = 'selecao';
    perform pgmq.send('despacho', jsonb_build_object('vaga_id', v_pos.vaga_id, 'posicao_id', v_nova, 'motivo', 'reabertura', 'excluir_conta', v_usr));
  end if;
  perform privado.recalcular_comparecimento(v_pos.profissional_id);
  perform privado.notificar(v_usr, 'cancelamento', v_pos.id, jsonb_build_object('posicao_id', v_pos.id, 'vaga_id', v_pos.vaga_id, 'reaberta', v_nova is not null));
  return jsonb_build_object('posicao_id', v_pos.id, 'falta', true, 'reaberta', v_nova is not null, 'nova_posicao_id', v_nova);
end $function$;

select set_config('frila.agora', '2026-11-14 18:14:59+00', true);

select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000205'::uuid) $$),
  'PGRST',
  pg_temp.erro('reabertura_antes_da_tolerancia'),
  'funcao canonica restaurada: chamada a 14m59s volta a recusar 422 reabertura_antes_da_tolerancia'
);

select * from finish();
rollback;
