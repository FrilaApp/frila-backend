-- 724_rpc_confirmar_checkin_e_equipe.sql
--
-- Cobertura pgTAP das RPCs críticas de escrita public.confirmar_checkin_manual e public.incluir_na_equipe.
-- Foco: autoridade, idempotência, integridade temporal e eliminação de mutantes sobreviventes.
-- Regras de Negócio e Requisitos:
--   - RN22 / RF20: confirmação de presença manual pela casa, idempotência estrita sem sobrescrita de timestamp.
--   - RF18 / RF21 / UC11: inclusão na equipe de confiança restrita a administradores e profissionais com turno estritamente 'verificado'.
--
-- Mutantes eliminados por este teste:
--   1. Mutante M1 (confirmar_checkin_manual): remoção do bloco de retorno antecipado de idempotência
--      (if v_t.checkin_confirmado_em is not null then return ... end if;), que causaria regravação indevida
--      de checkin_confirmado_em e re-execução redundante de recalcular_comparecimento.
--   2. Mutante M2 (incluir_na_equipe): remoção da cláusula 'and t.verificacao = ''verificado''' na consulta
--      de turnos cumpridos na casa, que permitiria erroneamente incluir profissionais com turno pendente ou não verificado.

begin;

-- 1. Setup de ambiente: garantir teste ativo e fixar relógio inicial antes de inserir dados
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-10-16 12:00:00-03';

select plan(32);

-- Funções auxiliares temporárias para autenticação e isolamento de contexto JWT
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

-- ── 1. Metadados e Privilégios das Funções ───────────────────────────────────────

select ok(
  has_function_privilege('authenticated', 'public.confirmar_checkin_manual(uuid)', 'execute'),
  'authenticated executa public.confirmar_checkin_manual(uuid)'
);

select ok(
  not has_function_privilege('anon', 'public.confirmar_checkin_manual(uuid)', 'execute'),
  'anon NÃO executa public.confirmar_checkin_manual(uuid)'
);

select is(
  (select prosecdef from pg_proc where proname = 'confirmar_checkin_manual' and pronamespace = 'public'::regnamespace),
  true,
  'public.confirmar_checkin_manual(uuid) é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'confirmar_checkin_manual' and pronamespace = 'public'::regnamespace) @> array['search_path=""'],
  true,
  'public.confirmar_checkin_manual(uuid) possui search_path="" fixado'
);

select ok(
  has_function_privilege('authenticated', 'public.incluir_na_equipe(uuid, uuid)', 'execute'),
  'authenticated executa public.incluir_na_equipe(uuid, uuid)'
);

select ok(
  not has_function_privilege('anon', 'public.incluir_na_equipe(uuid, uuid)', 'execute'),
  'anon NÃO executa public.incluir_na_equipe(uuid, uuid)'
);

select is(
  (select prosecdef from pg_proc where proname = 'incluir_na_equipe' and pronamespace = 'public'::regnamespace),
  true,
  'public.incluir_na_equipe(uuid, uuid) é SECURITY DEFINER'
);

select is(
  (select proconfig from pg_proc where proname = 'incluir_na_equipe' and pronamespace = 'public'::regnamespace) @> array['search_path=""'],
  true,
  'public.incluir_na_equipe(uuid, uuid) possui search_path="" fixado'
);

-- ── Setup de Dados de Teste ──────────────────────────────────────────────────────

create temp table ids as select
  '72400000-0000-4000-8000-000000000001'::uuid as user_dono_ze,
  '72400000-0000-4000-8000-000000000002'::uuid as user_op_ze,
  '72400000-0000-4000-8000-000000000003'::uuid as user_dona_rita,
  '72400000-0000-4000-8000-000000000004'::uuid as user_ana,
  '72400000-0000-4000-8000-000000000005'::uuid as user_beto,
  '72400000-0000-4000-8000-000000000006'::uuid as user_carlos,
  '72400000-0000-4000-8000-000000000007'::uuid as user_diana,
  '72400000-0000-4000-8000-000000000008'::uuid as user_eduardo,
  '72400000-0000-4000-8000-000000000010'::uuid as estab_ze,
  '72400000-0000-4000-8000-000000000020'::uuid as estab_rita,
  '72400000-0000-4000-8000-000000000014'::uuid as prof_ana,
  '72400000-0000-4000-8000-000000000015'::uuid as prof_beto,
  '72400000-0000-4000-8000-000000000016'::uuid as prof_carlos,
  '72400000-0000-4000-8000-000000000017'::uuid as prof_diana,
  '72400000-0000-4000-8000-000000000018'::uuid as prof_eduardo,
  '72400000-0000-4000-8000-000000000100'::uuid as vaga_ze,
  '72400000-0000-4000-8000-000000000201'::uuid as pos_ana,
  '72400000-0000-4000-8000-000000000202'::uuid as pos_beto,
  '72400000-0000-4000-8000-000000000203'::uuid as pos_carlos,
  '72400000-0000-4000-8000-000000000204'::uuid as pos_diana,
  '72400000-0000-4000-8000-000000000205'::uuid as pos_eduardo,
  '72400000-0000-4000-8000-000000000301'::uuid as turno_ana,
  '72400000-0000-4000-8000-000000000302'::uuid as turno_beto,
  '72400000-0000-4000-8000-000000000303'::uuid as turno_carlos,
  '72400000-0000-4000-8000-000000000304'::uuid as turno_diana,
  '72400000-0000-4000-8000-000000000305'::uuid as turno_eduardo;

-- Autenticações em auth.users
select pg_temp.autenticar((select user_dono_ze from ids),   'ze@724.test');
select pg_temp.autenticar((select user_op_ze from ids),     'op@724.test');
select pg_temp.autenticar((select user_dona_rita from ids), 'rita@724.test');
select pg_temp.autenticar((select user_ana from ids),       'ana@724.test');
select pg_temp.autenticar((select user_beto from ids),      'beto@724.test');
select pg_temp.autenticar((select user_carlos from ids),    'carlos@724.test');
select pg_temp.autenticar((select user_diana from ids),     'diana@724.test');
select pg_temp.autenticar((select user_eduardo from ids),   'eduardo@724.test');

-- Inserção de usuários contratantes e profissionais
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('72400000-0000-4000-8000-000000000001', 'contratante', 'Zé Dono', 'ze@724.test', '+5561972400001', '1980-01-01', 'ativa', '1.0', now()),
  ('72400000-0000-4000-8000-000000000002', 'contratante', 'Zé Operador', 'op@724.test', '+5561972400002', '1985-01-01', 'ativa', '1.0', now()),
  ('72400000-0000-4000-8000-000000000003', 'contratante', 'Dona Rita', 'rita@724.test', '+5561972400003', '1982-01-01', 'ativa', '1.0', now()),
  ('72400000-0000-4000-8000-000000000004', 'profissional', 'Ana Garçonete', 'ana@724.test', '+5561972400004', '1995-01-01', 'ativa', '1.0', now()),
  ('72400000-0000-4000-8000-000000000005', 'profissional', 'Beto Cozinheiro', 'beto@724.test', '+5561972400005', '1992-01-01', 'ativa', '1.0', now()),
  ('72400000-0000-4000-8000-000000000006', 'profissional', 'Carlos Bartender', 'carlos@724.test', '+5561972400006', '1990-01-01', 'ativa', '1.0', now()),
  ('72400000-0000-4000-8000-000000000007', 'profissional', 'Diana Cumpridora', 'diana@724.test', '+5561972400007', '1993-01-01', 'ativa', '1.0', now()),
  ('72400000-0000-4000-8000-000000000008', 'profissional', 'Eduardo Faltoso', 'eduardo@724.test', '+5561972400008', '1991-01-01', 'ativa', '1.0', now());

-- Estabelecimentos
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('72400000-0000-4000-8000-000000000010', 'Bar do Zé 724', '72400000000110', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('72400000-0000-4000-8000-000000000020', 'Buffet da Rita 724', '72400000000120', 'evento', 'CLS 302', 'POINT(-47.8900 -15.8100)'::extensions.geography, 'Plano Piloto');

-- Membros dos estabelecimentos
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('72400000-0000-4000-8000-000000000001', '72400000-0000-4000-8000-000000000010', 'administrador'),
  ('72400000-0000-4000-8000-000000000002', '72400000-0000-4000-8000-000000000010', 'operador'),
  ('72400000-0000-4000-8000-000000000003', '72400000-0000-4000-8000-000000000020', 'administrador');

-- Profissionais
insert into public.profissional (id, usuario_id, ponto_base) values
  ('72400000-0000-4000-8000-000000000014', '72400000-0000-4000-8000-000000000004', 'POINT(-47.8850 -15.7900)'::extensions.geography),
  ('72400000-0000-4000-8000-000000000015', '72400000-0000-4000-8000-000000000005', 'POINT(-47.8850 -15.7900)'::extensions.geography),
  ('72400000-0000-4000-8000-000000000016', '72400000-0000-4000-8000-000000000006', 'POINT(-47.8850 -15.7900)'::extensions.geography),
  ('72400000-0000-4000-8000-000000000017', '72400000-0000-4000-8000-000000000007', 'POINT(-47.8850 -15.7900)'::extensions.geography),
  ('72400000-0000-4000-8000-000000000018', '72400000-0000-4000-8000-000000000008', 'POINT(-47.8850 -15.7900)'::extensions.geography);

-- Vaga única com 5 posições no Bar do Zé
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em,
                         publicado_por)
values ('72400000-0000-4000-8000-000000000100', '72400000-0000-4000-8000-000000000010',
        (select id from public.funcao limit 1),
        '2026-10-16 18:00+00', '2026-10-16 23:00+00', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
        15000, 5, true, false, false, 'Zé', 'urgencia', gen_random_uuid(), '2026-10-16 12:00+00',
        '72400000-0000-4000-8000-000000000001');

-- Posições
insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em) values
  ('72400000-0000-4000-8000-000000000201', '72400000-0000-4000-8000-000000000100', 'confirmada', '72400000-0000-4000-8000-000000000014', '2026-10-16 13:00+00', false, '2026-10-16 18:00+00', '2026-10-16 23:00+00'),
  ('72400000-0000-4000-8000-000000000202', '72400000-0000-4000-8000-000000000100', 'confirmada', '72400000-0000-4000-8000-000000000015', '2026-10-16 13:00+00', false, '2026-10-16 18:00+00', '2026-10-16 23:00+00'),
  ('72400000-0000-4000-8000-000000000203', '72400000-0000-4000-8000-000000000100', 'confirmada', '72400000-0000-4000-8000-000000000016', '2026-10-16 13:00+00', false, '2026-10-16 18:00+00', '2026-10-16 23:00+00'),
  ('72400000-0000-4000-8000-000000000204', '72400000-0000-4000-8000-000000000100', 'confirmada', '72400000-0000-4000-8000-000000000017', '2026-10-16 13:00+00', false, '2026-10-16 18:00+00', '2026-10-16 23:00+00'),
  ('72400000-0000-4000-8000-000000000205', '72400000-0000-4000-8000-000000000100', 'confirmada', '72400000-0000-4000-8000-000000000018', '2026-10-16 13:00+00', false, '2026-10-16 18:00+00', '2026-10-16 23:00+00');

-- Turnos com diferentes estados de check-in e verificação:
-- 1. Ana: check-in manual a 350 m, verificacao pendente, ainda não confirmada
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('72400000-0000-4000-8000-000000000301', '72400000-0000-4000-8000-000000000201', '2026-10-16 18:05+00', 'manual', null, 'pendente', 15000);

-- 2. Beto: check-in geolocalizado a 50 m, verificado automaticamente
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('72400000-0000-4000-8000-000000000302', '72400000-0000-4000-8000-000000000202', '2026-10-16 18:02+00', 'geolocalizado', 50, 'verificado', 15000);

-- 3. Carlos: sem check-in realizado (checkin_em is null)
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('72400000-0000-4000-8000-000000000303', '72400000-0000-4000-8000-000000000203', null, null, null, 'pendente', 15000);

-- 4. Diana: check-in manual a 300 m, verificacao pendente (para teste de inclusão na equipe)
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('72400000-0000-4000-8000-000000000304', '72400000-0000-4000-8000-000000000204', '2026-10-16 18:10+00', 'manual', null, 'pendente', 15000);

-- 5. Eduardo: turno não verificado (cancelamento com falta após início)
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('72400000-0000-4000-8000-000000000305', '72400000-0000-4000-8000-000000000205', null, null, null, 'nao_verificado', 15000);

-- ── 2. Testes de confirmar_checkin_manual (RF20 / RN22) ──────────────────────────

-- 9. Sem token de autenticação: 401 nao_autenticado
select throws_ok(
  $$ select public.confirmar_checkin_manual('72400000-0000-4000-8000-000000000301'::uuid) $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'confirmar_checkin_manual sem autenticação recusa 401 nao_autenticado'
);

-- 10. Argumento turno_id nulo: 422 campo_obrigatorio
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    $$ select public.confirmar_checkin_manual(null) $$),
  'PGRST', pg_temp.erro('campo_obrigatorio', 'turno_id'),
  'confirmar_checkin_manual com turno_id null recusa 422 campo_obrigatorio'
);

-- 11. Turno inexistente: 404 nao_encontrado
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    $$ select public.confirmar_checkin_manual('72400000-0000-4000-8000-000000000999'::uuid) $$),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'confirmar_checkin_manual com turno inexistente recusa 404 nao_encontrado'
);

-- 12. Não membro do estabelecimento da vaga: 403 sem_permissao
select throws_ok(
  pg_temp.por((select user_dona_rita from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select turno_ana from ids))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'confirmar_checkin_manual por membro de outro estabelecimento recusa 403 sem_permissao (RF20)'
);

-- 13. O profissional do próprio turno tentando confirmar: 403 sem_permissao
select throws_ok(
  pg_temp.por((select user_ana from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select turno_ana from ids))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'confirmar_checkin_manual pelo profissional do próprio turno recusa 403 sem_permissao (RF20)'
);

-- 14. Turno sem check-in realizado (checkin_em is null): 409 checkin_pendente
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select turno_carlos from ids))),
  'PGRST', pg_temp.erro('checkin_pendente'),
  'confirmar_checkin_manual de turno sem check-in realizado recusa 409 checkin_pendente'
);

-- 15. Check-in geolocalizado já nasceu verificado: 409 checkin_ja_confirmado
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select turno_beto from ids))),
  'PGRST', pg_temp.erro('checkin_ja_confirmado'),
  'confirmar_checkin_manual de check-in geolocalizado recusa 409 checkin_ja_confirmado'
);

-- 16. Confirmação com sucesso no instante T1 (2026-10-16 18:20:00-03)
set local frila.agora = '2026-10-16 18:20:00-03';

select is(
  pg_temp.como((select user_dono_ze from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select turno_ana from ids))),
  jsonb_build_object(
    'turno_id',      '72400000-0000-4000-8000-000000000301'::uuid,
    'tipo',          'manual',
    'verificacao',   'verificado',
    'registrado_em', '2026-10-16 18:05:00+00'::timestamptz,
    'distancia_m',   null
  ),
  'confirmar_checkin_manual confirma presença manual com sucesso devolvendo jsonb esperado'
);

-- 17. No banco, turno vira verificado e checkin_confirmado_em é gravado no relógio T1
select is(
  (select jsonb_build_object('verificacao', verificacao::text, 'confirmado_em', checkin_confirmado_em)
     from public.turno where id = (select turno_ana from ids)),
  jsonb_build_object('verificacao', 'verificado', 'confirmado_em', '2026-10-16 18:20:00-03'::timestamptz),
  'turno no banco passa a verificado e checkin_confirmado_em reflete o instante T1 da confirmacao'
);

-- 18. Recalcular comparecimento foi acionado e atualizou taxa da Ana
select is(
  (select taxa_comparecimento from public.profissional where id = (select prof_ana from ids)),
  1.000::numeric,
  'confirmar_checkin_manual recalculou comparecimento da profissional para 1.000'
);

-- 19. IDEMPOTÊNCIA E PRESERVAÇÃO TEMPORAL (MATA MUTANTE M1):
-- Avançar o relógio para T2 = 18:50 (30 minutos depois)
set local frila.agora = '2026-10-16 18:50:00-03';

select is(
  pg_temp.como((select user_dono_ze from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select turno_ana from ids))),
  jsonb_build_object(
    'turno_id',      '72400000-0000-4000-8000-000000000301'::uuid,
    'tipo',          'manual',
    'verificacao',   'verificado',
    'registrado_em', '2026-10-16 18:05:00+00'::timestamptz,
    'distancia_m',   null
  ),
  're-execução de confirmar_checkin_manual em T2 é idempotente e devolve o mesmo payload'
);

-- 20. checkin_confirmado_em PERMANECE T1 (se o mutante M1 apagasse o if de retorno antecipado, viraria T2)
select is(
  (select checkin_confirmado_em from public.turno where id = (select turno_ana from ids)),
  '2026-10-16 18:20:00-03'::timestamptz,
  'checkin_confirmado_em não é sobrescrito na segunda chamada (mata Mutante M1)'
);

-- ── 3. Testes de incluir_na_equipe (RF18 / RF21 / RN22 / UC11) ───────────────────

-- 21. Sem autenticação: 401 nao_autenticado
select throws_ok(
  $$ select public.incluir_na_equipe('72400000-0000-4000-8000-000000000010'::uuid, '72400000-0000-4000-8000-000000000014'::uuid) $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'incluir_na_equipe sem autenticação recusa 401 nao_autenticado'
);

-- 22. Perfil incompatível: chamado por usuário profissional recusa 422 perfil_incompativel
select throws_ok(
  pg_temp.por((select user_ana from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'incluir_na_equipe por chamador com perfil profissional recusa 422 perfil_incompativel (RN25)'
);

-- 23. Operador do estabelecimento: 403 sem_permissao (RF21: apenas administrador altera equipe)
select throws_ok(
  pg_temp.por((select user_op_ze from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'incluir_na_equipe por operador do estabelecimento recusa 403 sem_permissao (RF21)'
);

-- 24. Administrador de OUTRO estabelecimento: 403 sem_permissao
select throws_ok(
  pg_temp.por((select user_dona_rita from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'incluir_na_equipe por administrador de outro estabelecimento recusa 403 sem_permissao'
);

-- 25. Profissional inexistente: 404 nao_encontrado
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), '72400000-0000-4000-8000-000000000999'::uuid)),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'incluir_na_equipe de profissional inexistente recusa 404 nao_encontrado'
);

-- 26. EXIGÊNCIA ESTRITA DE TURNO VERIFICADO - TURNO PENDENTE (MATA MUTANTE M2):
-- Diana possui turno no estabelecimento, mas com verificacao = 'pendente' (não verificado pela casa)
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_diana from ids))),
  'PGRST', pg_temp.erro('sem_permissao', 'sem_turno_cumprido'),
  'incluir_na_equipe com profissional tendo turno pendente é recusado com 403 sem_turno_cumprido (mata Mutante M2)'
);

-- 27. EXIGÊNCIA ESTRITA DE TURNO VERIFICADO - TURNO NÃO VERIFICADO (MATA MUTANTE M2):
-- Eduardo possui turno no estabelecimento, mas com verificacao = 'nao_verificado' (falta)
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_eduardo from ids))),
  'PGRST', pg_temp.erro('sem_permissao', 'sem_turno_cumprido'),
  'incluir_na_equipe com profissional tendo turno nao_verificado é recusado com 403 sem_turno_cumprido (mata Mutante M2)'
);

-- 28. Inclusão com sucesso de profissional com turno verificado (Ana) no instante T3 (19:00)
set local frila.agora = '2026-10-16 19:00:00-03';

select is(
  pg_temp.como((select user_dono_ze from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  jsonb_build_object(
    'estabelecimento_id', '72400000-0000-4000-8000-000000000010'::uuid,
    'profissional_id',    '72400000-0000-4000-8000-000000000014'::uuid
  ),
  'incluir_na_equipe com profissional que cumpriu turno verificado inclui com sucesso'
);

-- 29. Registro gravado na tabela equipe_confianca com adicionado_em = T3
select is(
  (select adicionado_em from public.equipe_confianca
    where estabelecimento_id = (select estab_ze from ids)
      and profissional_id = (select prof_ana from ids)),
  '2026-10-16 19:00:00-03'::timestamptz,
  'equipe_confianca registra adicionado_em com o relógio corrente da inclusão T3'
);

-- 30. IDEMPOTÊNCIA E PRESERVAÇÃO TEMPORAL EM incluir_na_equipe:
-- Avançar o relógio para T4 = 19:45 (45 minutos depois)
set local frila.agora = '2026-10-16 19:45:00-03';

select is(
  pg_temp.como((select user_dono_ze from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  jsonb_build_object(
    'estabelecimento_id', '72400000-0000-4000-8000-000000000010'::uuid,
    'profissional_id',    '72400000-0000-4000-8000-000000000014'::uuid
  ),
  're-execução de incluir_na_equipe é idempotente e devolve o mesmo payload'
);

-- 31. adicionado_em permanece estritamente T3 (19:00), on conflict do nothing não sobrescreve
select is(
  (select adicionado_em from public.equipe_confianca
    where estabelecimento_id = (select estab_ze from ids)
      and profissional_id = (select prof_ana from ids)),
  '2026-10-16 19:00:00-03'::timestamptz,
  'adicionado_em preserva o timestamp original da primeira inclusão'
);

-- 32. Contagem exata de 1 linha na equipe_confianca para o par (estabelecimento_id, profissional_id)
select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id = (select estab_ze from ids)
      and profissional_id = (select prof_ana from ids)),
  1,
  'exatamente uma linha mantida em public.equipe_confianca após re-inclusão'
);

select * from finish();

rollback;
