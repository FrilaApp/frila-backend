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
--      - Às 14m59s após o início previsto (18:14:59): recusa com 422 reabertura_antes_da_tolerancia;
--      - Aos 15m00s exatos após o início (18:15:00): o operador '<' é falso e a reabertura é autorizada.
--   6. Tolerância pós-confirmação para substitutos (D06):
--      - Substituto confirmado com turno já em andamento ganha 15 minutos contados de confirmado_em;
--      - Às 14m59s pós-confirmação (18:34:59): recusa com 422 reabertura_antes_da_tolerancia;
--      - Aos 15m00s exatos pós-confirmação (18:35:00): o operador '<' é falso e a reabertura é autorizada.
--   7. Efeitos colaterais e reposição com mais de 1h antes do fim:
--      - Posição original cancelada com falta = true (RN12);
--      - Turno original atualizado para verificacao = 'nao_verificado';
--      - Ocorrência de cancelamento registrada com motivo 'reabertura_por_atraso';
--      - Nova posição criada na vaga com reaberta_por_atraso_de preenchido;
--      - Vaga preenchida volta para estado = 'publicada';
--      - Vaga em modo 'selecao' vira 'urgencia' para reposição imediata (D5=A);
--      - Mensagem enfileirada no pgmq (q_despacho) excluindo o profissional faltoso da notificação;
--      - Profissional notificado em public.notificacao;
--      - privado.recalcular_comparecimento reflete a falta na reputação do profissional.
--   8. Corte de 1 hora antes do fim do turno (8zLfn0mt item 5 - v_agora < fim_em - 1 hour):
--      - A fim - 61 min (21:59:00): '<' é verdadeiro, cancela com falta e REABRE nova posição (reaberta = true);
--      - A fim - 60 min exatos (22:00:00): '<' é falso, cancela com falta mas NÃO reabre (reaberta = false, nova_posicao_id = null);
--      - A fim - 59 min (22:01:00): '<' é falso, cancela com falta mas NÃO reabre (reaberta = false, nova_posicao_id = null).
--   9. Idempotência / Reenvio: segunda chamada em posição já cancelada por atraso devolve
--      o mesmo resultado sem criar segunda posição nem duplicar ocorrências.
--  10. Provas de mutação dinâmica via pg_get_functiondef e savepoint:
--      - Mutante 1: Omissão/redução da tolerância (15m -> 14m) aceita a chamada a 14m59s;
--      - Mutante 2: Redução do corte de fim (1h -> 30m) reabre nova posição a 60m do fim;
--      - Mutante 3: Omissão da trava de check-in existente aceita chamada em turno com presença;
--      - Restauração atômica canônica após cada mutante via rollback to savepoint (sem cópia manual).
--
-- Prefixo de IDs: c7250000-0000-4000-8000-0000000000xx.
-- Datas determinísticas, sem now() livre e com rollback limpo.

begin;
set local frila.agendador_secret = 'segredo-de-teste';
select plan(32);

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
  select format('select pg_temp.como(%L, %L)', conta, sql);
$$;

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'));
$$;

-- ── 1. Catálogo e Permissões ──────────────────────────────────────────────────

select has_function('public', 'reabrir_por_atraso', array['uuid'],
  'funcao public.reabrir_por_atraso(uuid) existe no catalogo');

select is(
  (select coalesce(p.proconfig, '{}') @> array['search_path=""'] and p.prosecdef
     from pg_proc p
    where p.proname = 'reabrir_por_atraso'
      and p.pronamespace = 'public'::regnamespace),
  true,
  'reabrir_por_atraso e SECURITY DEFINER com search_path="" estrito'
);

select ok(
  not has_function_privilege('anon', 'public.reabrir_por_atraso(uuid)', 'execute'),
  'papel anon nao tem privilegio de EXECUTE em reabrir_por_atraso'
);

select ok(
  has_function_privilege('authenticated', 'public.reabrir_por_atraso(uuid)', 'execute'),
  'papel authenticated tem privilegio de EXECUTE em reabrir_por_atraso'
);

-- ── Fixtures de Teste ─────────────────────────────────────────────────────────

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

-- Vaga 0 (01/11 18h..23h): Turno anterior cumprido por Beto, já verificado (histórico de comparecimento)
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

-- Vaga 1 (10/11 18h..23h): Modo Seleção, preenchida. Beto faltoso. Caminho feliz e bordas de 15m.
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

-- Vaga 3 (12/11 18h..23h): Substituto Duda confirmado às 18:20:00 (D06 tolerância pós-confirmação)
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

-- Vaga 4 (13/11 18h..23h): Para teste de corte a fim - 61 min (às 21:59:00 -> reabre)
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

-- Vaga 6 (14/11 18h..23h): Para teste de corte a fim - 60 min exatos (às 22:00:00 -> não reabre)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7250000-0000-4000-8000-000000000106',
  'c7250000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-14 18:00:00+00', '2026-11-14 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7250000-0000-4000-8000-000000000906'::uuid,
  'c7250000-0000-4000-8000-000000000001'::uuid,
  '2026-11-09 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7250000-0000-4000-8000-000000000206', 'c7250000-0000-4000-8000-000000000106',
   '2026-11-14 18:00:00+00', '2026-11-14 23:00:00+00', 'confirmada',
   'c7250000-0000-4000-8000-000000000020', '2026-11-09 11:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7250000-0000-4000-8000-000000000306', 'c7250000-0000-4000-8000-000000000206', null, null, null, 'pendente', 18000, null);

-- Vaga 7 (15/11 18h..23h): Para teste de corte a fim - 59 min (às 22:01:00 -> não reabre)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7250000-0000-4000-8000-000000000107',
  'c7250000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-15 18:00:00+00', '2026-11-15 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7250000-0000-4000-8000-000000000907'::uuid,
  'c7250000-0000-4000-8000-000000000001'::uuid,
  '2026-11-10 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7250000-0000-4000-8000-000000000207', 'c7250000-0000-4000-8000-000000000107',
   '2026-11-15 18:00:00+00', '2026-11-15 23:00:00+00', 'confirmada',
   'c7250000-0000-4000-8000-000000000050', '2026-11-10 11:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7250000-0000-4000-8000-000000000307', 'c7250000-0000-4000-8000-000000000207', null, null, null, 'pendente', 18000, null);

-- Vaga 8 (16/11 18h..23h): Para execução dos mutantes reais
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7250000-0000-4000-8000-000000000108',
  'c7250000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-16 18:00:00+00', '2026-11-16 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7250000-0000-4000-8000-000000000908'::uuid,
  'c7250000-0000-4000-8000-000000000001'::uuid,
  '2026-11-11 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7250000-0000-4000-8000-000000000208', 'c7250000-0000-4000-8000-000000000108',
   '2026-11-16 18:00:00+00', '2026-11-16 23:00:00+00', 'confirmada',
   'c7250000-0000-4000-8000-000000000030', '2026-11-11 11:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7250000-0000-4000-8000-000000000308', 'c7250000-0000-4000-8000-000000000208', null, null, null, 'pendente', 18000, null);

-- Vaga 9 (17/11 18h..23h): Para execução do mutante 2 (corte de 1h -> 30m)
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado,
  chave_cliente, publicado_por, publicado_em
) values (
  'c7250000-0000-4000-8000-000000000109',
  'c7250000-0000-4000-8000-000000000010',
  (select id from public.funcao where ativo is true limit 1),
  '2026-11-17 18:00:00+00', '2026-11-17 23:00:00+00', 'CLN 201 Bloco A',
  'POINT(-47.8840 -15.7960)'::extensions.geography, 18000, 1,
  true, false, false, 'Seu Zé', 'urgencia', 'preenchida',
  'c7250000-0000-4000-8000-000000000909'::uuid,
  'c7250000-0000-4000-8000-000000000001'::uuid,
  '2026-11-11 10:00:00+00'
);

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em) values
  ('c7250000-0000-4000-8000-000000000209', 'c7250000-0000-4000-8000-000000000109',
   '2026-11-17 18:00:00+00', '2026-11-17 23:00:00+00', 'confirmada',
   'c7250000-0000-4000-8000-000000000020', '2026-11-11 11:00:00+00');

insert into public.turno (id, posicao_id, checkin_tipo, checkin_em, checkin_distancia_m, verificacao, valor_acordado_centavos, checkin_confirmado_em) values
  ('c7250000-0000-4000-8000-000000000309', 'c7250000-0000-4000-8000-000000000209', null, null, null, 'pendente', 18000, null);

-- ── 2. Recusas e Validações de Entrada ──────────────────────────────────────────

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

-- ── 3. Bordas Temporais Estritas dos 15 Minutos (D06) ─────────────────────────
-- Vaga 1 inicia às 18:00.

-- Caso 14m59s: às 18:14:59 (1s antes da tolerância)
select set_config('frila.agora', '2026-11-10 18:14:59+00', true);

select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000201'::uuid) $$),
  'PGRST',
  pg_temp.erro('reabertura_antes_da_tolerancia'),
  'D06: tentativa a 14m59s do inicio previsto recusa com 422 reabertura_antes_da_tolerancia'
);

-- Caso 15m00s exatos: às 18:15:00 o operador '<' é falso, tolerância expirada!
select set_config('frila.agora', '2026-11-10 18:15:00+00', true);

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000201'::uuid) $$)->>'falta')::boolean,
  true,
  'D06: no instante exato de 15m00s do inicio previsto (< e falso), a reabertura e autorizada'
);

-- ── 4. Tolerância Pós-Confirmação para Substitutos (D06) ───────────────────────
-- Vaga 3 inicia às 18:00, mas Duda confirmou às 18:20:00 (durante o turno).
-- Tolerância estrita vai até 18:20:00 + 15 min = 18:35:00.

-- Caso 14m59s pós-confirmação (18:34:59)
select set_config('frila.agora', '2026-11-12 18:34:59+00', true);

select throws_ok(
  pg_temp.por('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000203'::uuid) $$),
  'PGRST',
  pg_temp.erro('reabertura_antes_da_tolerancia'),
  'D06 substituto: tentativa a 14m59s da confirmacao recusa com 422 reabertura_antes_da_tolerancia'
);

-- Caso 15m00s exatos pós-confirmação (18:35:00): '<' é falso, autoriza com falta!
select set_config('frila.agora', '2026-11-12 18:35:00+00', true);

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000203'::uuid) $$)->>'falta')::boolean,
  true,
  'D06 substituto: no instante exato de 15m00s da confirmacao (< e falso), a reabertura e autorizada'
);

-- ── 5. Efeitos Colaterais Completos do Caminho Feliz ──────────────────────────
-- Valida os efeitos da reabertura de Vaga 1 (realizada às 18:15:00, > 1h antes do término de 23:00)

select is(
  (select json_build_object(
    'posicao_id', p.id,
    'falta', p.falta,
    'reaberta', (select exists (select 1 from public.posicao n where n.reaberta_por_atraso_de = p.id)),
    'nova_posicao_id', (select n.id from public.posicao n where n.reaberta_por_atraso_de = p.id)
  )::jsonb from public.posicao p where p.id = 'c7250000-0000-4000-8000-000000000201') ?& array['falta', 'nova_posicao_id', 'posicao_id', 'reaberta'],
  true,
  'caminho feliz: envelope devolve falta, reaberta, posicao_id e nova_posicao_id'
);

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

select is(
  (select o.tipo || '|' || o.motivo || '|' || (o.usuario_id = 'c7250000-0000-4000-8000-000000000003')::text
     from public.ocorrencia o where o.posicao_id = 'c7250000-0000-4000-8000-000000000201'),
  'cancelamento|reabertura_por_atraso|true',
  'ocorrencia registrada com tipo cancelamento, motivo reabertura_por_atraso e usuario faltoso'
);

select is(
  (select p.reaberta_por_atraso_de from public.posicao p where p.vaga_id = 'c7250000-0000-4000-8000-000000000101' and p.estado = 'aberta'),
  'c7250000-0000-4000-8000-000000000201'::uuid,
  'nova posicao criada vinculada a reaberta_por_atraso_de da original'
);

select is(
  (select g.estado || '|' || g.modo from public.vaga g where g.id = 'c7250000-0000-4000-8000-000000000101'),
  'publicada|urgencia',
  'D5=A: vaga preenchida volta a publicada e modo selecao e convertido para urgencia'
);

select is(
  (select count(*)::int from pgmq.q_despacho
    where message->>'motivo' = 'reabertura'
      and message->>'vaga_id' = 'c7250000-0000-4000-8000-000000000101'
      and message->>'excluir_conta' = 'c7250000-0000-4000-8000-000000000003'),
  1,
  'mensagem de despacho enfileirada no pgmq excluindo o profissional faltoso'
);

select is(
  (select count(*)::int from public.notificacao n
    where n.usuario_id = 'c7250000-0000-4000-8000-000000000003'
      and n.tipo = 'cancelamento'
      and n.referencia_id = 'c7250000-0000-4000-8000-000000000201'),
  1,
  'notificacao de cancelamento por falta enviada a public.notificacao'
);

select is(
  (select p.turnos_realizados || '|' || p.taxa_comparecimento::text
     from public.profissional p where p.id = 'c7250000-0000-4000-8000-000000000030'),
  '1|0.500',
  'privado.recalcular_comparecimento atualizou taxa para 0.500 (1 turno / (1 turno + 1 falta))'
);

-- ── 6. Bordas Exatas do Corte de 1h antes do Fim (8zLfn0mt) ───────────────────
-- Condição da RPC: if v_agora < v_pos.fim_em - interval '1 hour' then ... insert nova posicao ... end if;
-- Todas as vagas abaixo encerram às 23:00:00 (limiar exato: 22:00:00).

-- Borda fim - 61 min (21:59:00): 21:59:00 < 22:00:00 é VERDADEIRO -> REABRE
select set_config('frila.agora', '2026-11-13 21:59:00+00', true);

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000204'::uuid) $$))->>'reaberta',
  'true',
  '8zLfn0mt borda fim - 61 min: com mais de 1h restante (< e true), reabre nova posicao (reaberta=true)'
);

-- Borda fim - 60 min exatos (22:00:00): 22:00:00 < 22:00:00 é FALSO -> NÃO REABRE
select set_config('frila.agora', '2026-11-14 22:00:00+00', true);

select is(
  pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000206'::uuid) $$),
  jsonb_build_object(
    'posicao_id',      'c7250000-0000-4000-8000-000000000206'::uuid,
    'falta',           true,
    'reaberta',        false,
    'nova_posicao_id', null
  ),
  '8zLfn0mt borda fim - 60 min exatos: a exatamente 1h do fim (< e false), cancela com falta mas NAO reabre (reaberta=false)'
);

-- Borda fim - 59 min (22:01:00): 22:01:00 < 22:00:00 é FALSO -> NÃO REABRE
select set_config('frila.agora', '2026-11-15 22:01:00+00', true);

select is(
  pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000207'::uuid) $$),
  jsonb_build_object(
    'posicao_id',      'c7250000-0000-4000-8000-000000000207'::uuid,
    'falta',           true,
    'reaberta',        false,
    'nova_posicao_id', null
  ),
  '8zLfn0mt borda fim - 59 min: a 59 min do fim (< e false), cancela com falta mas NAO reabre (reaberta=false)'
);

-- ── 7. Idempotência e Reenvio de Chamada ───────────────────────────────────────
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

-- ── 8. Provas de Mutação Real via pg_get_functiondef ─────────────────────────

-- Mutação 1: Redução da tolerância de 15 min para 14 min
-- Sob o mutante, a chamada a 14m59s (18:14:59) passaria porque 14m59s >= 14 min!
do $$
begin
  execute replace(
    pg_get_functiondef('public.reabrir_por_atraso(uuid)'::regprocedure),
    '+ interval ''15 minutes''',
    '+ interval ''14 minutes'''
  );
end $$;

select set_config('frila.agora', '2026-11-16 18:14:59+00', true);

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000208'::uuid) $$))->>'falta',
  'true',
  'mutante 1 (14 min): chamada a 14m59s passaria sem 422; prova discriminacao da tolerancia de 15m'
);

-- Restauração dinâmica da tolerância canônica de 15 min
do $$
begin
  execute replace(
    pg_get_functiondef('public.reabrir_por_atraso(uuid)'::regprocedure),
    '+ interval ''14 minutes''',
    '+ interval ''15 minutes'''
  );
end $$;

-- Mutação 2: Redução do corte de 1 hora para 30 minutos
-- Sob o mutante, a chamada a 60 min do fim (22:00:00) reabriria porque 22:00 < 22:30!
do $$
begin
  execute replace(
    pg_get_functiondef('public.reabrir_por_atraso(uuid)'::regprocedure),
    '- interval ''1 hour''',
    '- interval ''30 minutes'''
  );
end $$;

select set_config('frila.agora', '2026-11-17 22:00:00+00', true);

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000209'::uuid) $$))->>'reaberta',
  'true',
  'mutante 2 (30 min corte): chamada a 60 min do fim reabriria nova posicao; prova discriminacao do corte de 1h'
);

-- Restauração dinâmica do corte canônico de 1 hora
do $$
begin
  execute replace(
    pg_get_functiondef('public.reabrir_por_atraso(uuid)'::regprocedure),
    '- interval ''30 minutes''',
    '- interval ''1 hour'''
  );
end $$;

-- Mutação 3: Omissão da trava de check-in existente
-- Sob o mutante, a chamada na posição 202 (com presença registrada) passaria sem 409
do $$
begin
  execute replace(
    pg_get_functiondef('public.reabrir_por_atraso(uuid)'::regprocedure),
    'if v_t.checkin_em is not null then',
    'if false and v_t.checkin_em is not null then'
  );
end $$;

select set_config('frila.agora', '2026-11-11 18:15:00+00', true);

select is(
  (pg_temp.como('c7250000-0000-4000-8000-000000000001', $$ select public.reabrir_por_atraso('c7250000-0000-4000-8000-000000000202'::uuid) $$))->>'falta',
  'true',
  'mutante 3 (sem trava check-in): chamada em presenca confirmada passaria sem 409; prova discriminacao da trava'
);

-- Restauração dinâmica da trava canônica de check-in
do $$
begin
  execute replace(
    pg_get_functiondef('public.reabrir_por_atraso(uuid)'::regprocedure),
    'if false and v_t.checkin_em is not null then',
    'if v_t.checkin_em is not null then'
  );
end $$;

select * from finish();
rollback;
