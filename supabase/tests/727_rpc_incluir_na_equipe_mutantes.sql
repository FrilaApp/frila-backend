-- 727_rpc_incluir_na_equipe_mutantes.sql
--
-- Cobertura pgTAP de follow-up do #256 para public.incluir_na_equipe, public.remover_da_equipe
-- e public.confirmar_checkin_manual.
-- Foco em mutantes específicos sobreviventes:
--   1. Mutante M3 (incluir_na_equipe): remoção da cláusula 'and v.estabelecimento_id = incluir_na_equipe.estabelecimento_id'.
--      Prova que ter turno verificado em OUTRO estabelecimento não qualifica o profissional para a equipe da casa (UC11, RF18).
--   2. Mutante M4 (incluir_na_equipe e remover_da_equipe): remoção da checagem de conta suspensa (RN13).
--      Prova que administrador com conta suspensa não altera equipe (403 sem_permissao / conta_suspensa).
--   3. Mutante M5 (incluir_na_equipe): remoção da checagem de usuário anonimizado (RF25).
--      Prova que profissional com conta anonimizada (mesmo tendo cumprido turno no passado) é recusado com 404 nao_encontrado.
--   4. Mutante M6 (remover_da_equipe): autoridade restrita a administrador, idempotência e menor privilégio.
--   5. Mutante M7 (confirmar_checkin_manual): conta suspensa (403 conta_suspensa) e posição cancelada (409 vaga_encerrada / posicao_cancelada).

begin;

-- 1. Setup de ambiente: garantir teste ativo e fixar relógio inicial antes de inserir dados
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local frila.agora = '2026-10-16 12:00:00-03';

select plan(19);

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

-- ── 1. Metadados e Privilégios de remover_da_equipe ─────────────────────────────

select ok(
  has_function_privilege('authenticated', 'public.remover_da_equipe(uuid, uuid)', 'execute'),
  'authenticated executa public.remover_da_equipe(uuid, uuid)'
);

select ok(
  not has_function_privilege('anon', 'public.remover_da_equipe(uuid, uuid)', 'execute'),
  'anon NÃO executa public.remover_da_equipe(uuid, uuid)'
);

select is(
  (select prosecdef and (proconfig @> array['search_path=""'])
     from pg_proc where proname = 'remover_da_equipe' and pronamespace = 'public'::regnamespace),
  true,
  'public.remover_da_equipe(uuid, uuid) é SECURITY DEFINER com search_path="" fixado'
);

-- ── Setup de Dados de Teste ──────────────────────────────────────────────────────

create temp table ids as select
  '72700000-0000-4000-8000-000000000001'::uuid as user_dono_ze,
  '72700000-0000-4000-8000-000000000002'::uuid as user_op_ze,
  '72700000-0000-4000-8000-000000000003'::uuid as user_dono_ze_suspenso,
  '72700000-0000-4000-8000-000000000004'::uuid as user_dona_rita,
  '72700000-0000-4000-8000-000000000011'::uuid as user_ana,
  '72700000-0000-4000-8000-000000000012'::uuid as user_beatriz,
  '72700000-0000-4000-8000-000000000013'::uuid as user_caio_anonimizado,
  '72700000-0000-4000-8000-000000000014'::uuid as user_danilo_cancelado,
  '72700000-0000-4000-8000-000000000021'::uuid as prof_ana,
  '72700000-0000-4000-8000-000000000022'::uuid as prof_beatriz,
  '72700000-0000-4000-8000-000000000023'::uuid as prof_caio,
  '72700000-0000-4000-8000-000000000024'::uuid as prof_danilo,
  '72700000-0000-4000-8000-000000000031'::uuid as estab_ze,
  '72700000-0000-4000-8000-000000000032'::uuid as estab_rita,
  '72700000-0000-4000-8000-000000000101'::uuid as vaga_ze,
  '72700000-0000-4000-8000-000000000102'::uuid as vaga_rita,
  '72700000-0000-4000-8000-000000000201'::uuid as pos_ana_ze,
  '72700000-0000-4000-8000-000000000202'::uuid as pos_beatriz_rita,
  '72700000-0000-4000-8000-000000000203'::uuid as pos_caio_ze,
  '72700000-0000-4000-8000-000000000204'::uuid as pos_danilo_cancelada,
  '72700000-0000-4000-8000-000000000301'::uuid as turno_ana_ze,
  '72700000-0000-4000-8000-000000000302'::uuid as turno_beatriz_rita,
  '72700000-0000-4000-8000-000000000303'::uuid as turno_caio_ze,
  '72700000-0000-4000-8000-000000000304'::uuid as turno_danilo_cancelado;

-- Autenticações em auth.users
select pg_temp.autenticar((select user_dono_ze from ids),          'dono@727.test');
select pg_temp.autenticar((select user_op_ze from ids),            'op@727.test');
select pg_temp.autenticar((select user_dono_ze_suspenso from ids), 'suspenso@727.test');
select pg_temp.autenticar((select user_dona_rita from ids),        'rita@727.test');
select pg_temp.autenticar((select user_ana from ids),              'ana@727.test');
select pg_temp.autenticar((select user_beatriz from ids),          'beatriz@727.test');
select pg_temp.autenticar((select user_caio_anonimizado from ids), 'caio@727.test');
select pg_temp.autenticar((select user_danilo_cancelado from ids), 'danilo@727.test');

-- Usuários
insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em, anonimizado_em) values
  ('72700000-0000-4000-8000-000000000001', 'contratante', 'Zé Dono', 'dono@727.test', '+5561972700001', '1980-01-01', 'ativa', '1.0', now(), null),
  ('72700000-0000-4000-8000-000000000002', 'contratante', 'Zé Operador', 'op@727.test', '+5561972700002', '1985-01-01', 'ativa', '1.0', now(), null),
  ('72700000-0000-4000-8000-000000000003', 'contratante', 'Zé Suspenso', 'suspenso@727.test', '+5561972700003', '1982-01-01', 'suspensa', '1.0', now(), null),
  ('72700000-0000-4000-8000-000000000004', 'contratante', 'Dona Rita', 'rita@727.test', '+5561972700004', '1984-01-01', 'ativa', '1.0', now(), null),
  ('72700000-0000-4000-8000-000000000011', 'profissional', 'Ana Cumpridora', 'ana@727.test', '+5561972700011', '1995-01-01', 'ativa', '1.0', now(), null),
  ('72700000-0000-4000-8000-000000000012', 'profissional', 'Beatriz Da Outra Casa', 'beatriz@727.test', '+5561972700012', '1994-01-01', 'ativa', '1.0', now(), null),
  ('72700000-0000-4000-8000-000000000013', 'profissional', 'Caio Excluído', 'caio@727.test', '+5561972700013', '1993-01-01', 'anonimizada', '1.0', now(), '2026-10-15 12:00:00+00'),
  ('72700000-0000-4000-8000-000000000014', 'profissional', 'Danilo Desistente', 'danilo@727.test', '+5561972700014', '1992-01-01', 'ativa', '1.0', now(), null);

-- Estabelecimentos
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('72700000-0000-4000-8000-000000000031', 'Bar do Zé 727', '72700000000131', 'food_service', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('72700000-0000-4000-8000-000000000032', 'Buffet da Rita 727', '72700000000132', 'evento', 'CLS 302', 'POINT(-47.8900 -15.8100)'::extensions.geography, 'Plano Piloto');

-- Membros dos estabelecimentos
insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('72700000-0000-4000-8000-000000000001', '72700000-0000-4000-8000-000000000031', 'administrador'),
  ('72700000-0000-4000-8000-000000000002', '72700000-0000-4000-8000-000000000031', 'operador'),
  ('72700000-0000-4000-8000-000000000003', '72700000-0000-4000-8000-000000000031', 'administrador'), -- Zé Suspenso
  ('72700000-0000-4000-8000-000000000004', '72700000-0000-4000-8000-000000000032', 'administrador');

-- Profissionais
insert into public.profissional (id, usuario_id, ponto_base) values
  ('72700000-0000-4000-8000-000000000021', '72700000-0000-4000-8000-000000000011', 'POINT(-47.8850 -15.7900)'::extensions.geography),
  ('72700000-0000-4000-8000-000000000022', '72700000-0000-4000-8000-000000000012', 'POINT(-47.8850 -15.7900)'::extensions.geography),
  ('72700000-0000-4000-8000-000000000023', '72700000-0000-4000-8000-000000000013', 'POINT(-47.8850 -15.7900)'::extensions.geography),
  ('72700000-0000-4000-8000-000000000024', '72700000-0000-4000-8000-000000000014', 'POINT(-47.8850 -15.7900)'::extensions.geography);

-- Vagas:
-- Vaga 1 no Bar do Zé
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em,
                         publicado_por)
values ('72700000-0000-4000-8000-000000000101', '72700000-0000-4000-8000-000000000031',
        (select id from public.funcao limit 1),
        '2026-10-16 18:00+00', '2026-10-16 23:00+00', 'CLN 201', 'POINT(-47.8822 -15.7942)'::extensions.geography,
        15000, 3, true, false, false, 'Zé', 'urgencia', gen_random_uuid(), '2026-10-16 12:00+00',
        '72700000-0000-4000-8000-000000000001');

-- Vaga 2 no Buffet da Rita
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
                         valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
                         exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_em,
                         publicado_por)
values ('72700000-0000-4000-8000-000000000102', '72700000-0000-4000-8000-000000000032',
        (select id from public.funcao limit 1),
        '2026-10-16 18:00+00', '2026-10-16 23:00+00', 'CLS 302', 'POINT(-47.8900 -15.8100)'::extensions.geography,
        15000, 1, true, false, false, 'Rita', 'urgencia', gen_random_uuid(), '2026-10-16 12:00+00',
        '72700000-0000-4000-8000-000000000004');

-- Posições:
-- Ana cumpriu turno no Bar do Zé (confirmada)
insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em) values
  ('72700000-0000-4000-8000-000000000201', '72700000-0000-4000-8000-000000000101', 'confirmada', '72700000-0000-4000-8000-000000000021', '2026-10-16 13:00+00', false, '2026-10-16 18:00+00', '2026-10-16 23:00+00');

-- Beatriz cumpriu turno no Buffet da Rita (confirmada)
insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em) values
  ('72700000-0000-4000-8000-000000000202', '72700000-0000-4000-8000-000000000102', 'confirmada', '72700000-0000-4000-8000-000000000022', '2026-10-16 13:00+00', false, '2026-10-16 18:00+00', '2026-10-16 23:00+00');

-- Caio cumpriu turno no Bar do Zé no passado, mas foi anonimizado
insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em) values
  ('72700000-0000-4000-8000-000000000203', '72700000-0000-4000-8000-000000000101', 'confirmada', '72700000-0000-4000-8000-000000000023', '2026-10-15 13:00+00', false, '2026-10-15 18:00+00', '2026-10-15 23:00+00');

-- Danilo teve posição cancelada no Bar do Zé
insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, falta, inicio_em, fim_em) values
  ('72700000-0000-4000-8000-000000000204', '72700000-0000-4000-8000-000000000101', 'cancelada', '72700000-0000-4000-8000-000000000024', '2026-10-16 13:00+00', true, '2026-10-16 18:00+00', '2026-10-16 23:00+00');

-- Turnos:
-- Ana: turno verificado no Bar do Zé
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkin_confirmado_em, verificacao, valor_acordado_centavos)
values ('72700000-0000-4000-8000-000000000301', '72700000-0000-4000-8000-000000000201', '2026-10-16 18:05+00', 'manual', null, '2026-10-16 18:20+00', 'verificado', 15000);

-- Beatriz: turno verificado no Buffet da Rita (NUNCA no Bar do Zé!)
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkin_confirmado_em, verificacao, valor_acordado_centavos)
values ('72700000-0000-4000-8000-000000000302', '72700000-0000-4000-8000-000000000202', '2026-10-16 18:02+00', 'geolocalizado', 50, null, 'verificado', 15000);

-- Caio: turno verificado no Bar do Zé no passado
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkin_confirmado_em, verificacao, valor_acordado_centavos)
values ('72700000-0000-4000-8000-000000000303', '72700000-0000-4000-8000-000000000203', '2026-10-15 18:02+00', 'geolocalizado', 50, null, 'verificado', 15000);

-- Danilo: checkin manual em posição cancelada -> verificacao pendente
insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, checkin_confirmado_em, verificacao, valor_acordado_centavos)
values ('72700000-0000-4000-8000-000000000304', '72700000-0000-4000-8000-000000000204', '2026-10-16 18:05+00', 'manual', null, null, 'pendente', 15000);

-- ── 2. Eliminação de Mutantes em incluir_na_equipe ───────────────────────────────

-- 4. MUTANTE M3: Turno verificado cumprido em OUTRO estabelecimento (Beatriz cumpriu na Rita, nunca no Zé).
-- Bar do Zé tenta incluir Beatriz na sua equipe de confiança: DEVE RECUSAR 403 sem_turno_cumprido!
-- Se o mutante remover 'and v.estabelecimento_id = incluir_na_equipe.estabelecimento_id', este teste falha!
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_beatriz from ids))),
  'PGRST', pg_temp.erro('sem_permissao', 'sem_turno_cumprido'),
  'incluir_na_equipe recusa profissional com turno verificado em outra casa (mata mutante sem v.estabelecimento_id)'
);

-- 5. MUTANTE M4: Administrador com conta suspensa (RN13)
select throws_ok(
  pg_temp.por((select user_dono_ze_suspenso from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'incluir_na_equipe por administrador com conta suspensa recusa 403 conta_suspensa (RN13)'
);

-- 6. MUTANTE M5: Profissional com conta anonimizada (RF25)
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_caio from ids))),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'incluir_na_equipe com profissional anonimizado recusa 404 nao_encontrado mesmo com turno previo (RF25)'
);

-- 7. Profissional inexistente na tabela profissional
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), gen_random_uuid())),
  'PGRST', pg_temp.erro('nao_encontrado'),
  'incluir_na_equipe de profissional inexistente recusa 404 nao_encontrado'
);

-- 8. Inclusão legítima de Ana (tem turno verificado no Bar do Zé)
select is(
  pg_temp.como((select user_dono_ze from ids),
    format($$ select public.incluir_na_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  jsonb_build_object(
    'estabelecimento_id', '72700000-0000-4000-8000-000000000031'::uuid,
    'profissional_id',    '72700000-0000-4000-8000-000000000021'::uuid
  ),
  'incluir_na_equipe inclui Ana com sucesso na equipe do Bar do Zé'
);

-- 9. Linha persistida em equipe_confianca
select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id = (select estab_ze from ids)
      and profissional_id = (select prof_ana from ids)),
  1,
  'Ana consta gravada na tabela equipe_confianca'
);

-- ── 3. Testes de remover_da_equipe e Mutantes ───────────────────────────────────

-- 10. Sem autenticação: 401
select throws_ok(
  format($$ select public.remover_da_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids)),
  'PGRST', pg_temp.erro('nao_autenticado'),
  'remover_da_equipe sem autenticação recusa 401 nao_autenticado'
);

-- 11. Perfil incompatível: chamado por profissional recusa 422 perfil_incompativel
select throws_ok(
  pg_temp.por((select user_ana from ids),
    format($$ select public.remover_da_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  'PGRST', pg_temp.erro('perfil_incompativel'),
  'remover_da_equipe por chamador profissional recusa 422 perfil_incompativel (RN25)'
);

-- 12. Administrador com conta suspensa recusa 403 conta_suspensa
select throws_ok(
  pg_temp.por((select user_dono_ze_suspenso from ids),
    format($$ select public.remover_da_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'remover_da_equipe por administrador com conta suspensa recusa 403 conta_suspensa (RN13)'
);

-- 13. Operador do estabelecimento recusa 403 sem_permissao (RF21)
select throws_ok(
  pg_temp.por((select user_op_ze from ids),
    format($$ select public.remover_da_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'remover_da_equipe por operador recusa 403 sem_permissao (RF21)'
);

-- 14. Administrador de outro estabelecimento recusa 403 sem_permissao
select throws_ok(
  pg_temp.por((select user_dona_rita from ids),
    format($$ select public.remover_da_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  'PGRST', pg_temp.erro('sem_permissao'),
  'remover_da_equipe por administrador de outro estabelecimento recusa 403 sem_permissao'
);

-- 15. Remoção legítima de Ana da equipe do Bar do Zé por administrador ativo
select is(
  pg_temp.como((select user_dono_ze from ids),
    format($$ select public.remover_da_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  jsonb_build_object(
    'estabelecimento_id', '72700000-0000-4000-8000-000000000031'::uuid,
    'profissional_id',    '72700000-0000-4000-8000-000000000021'::uuid
  ),
  'remover_da_equipe remove Ana com sucesso e devolve MembroDaEquipe'
);

-- 16. Linha foi de fato removida de equipe_confianca
select is(
  (select count(*)::int from public.equipe_confianca
    where estabelecimento_id = (select estab_ze from ids)
      and profissional_id = (select prof_ana from ids)),
  0,
  'Ana foi fisicamente removida de equipe_confianca'
);

-- 17. Idempotência de remover_da_equipe: segunda remoção devolve o mesmo payload
select is(
  pg_temp.como((select user_dono_ze from ids),
    format($$ select public.remover_da_equipe(%L, %L) $$, (select estab_ze from ids), (select prof_ana from ids))),
  jsonb_build_object(
    'estabelecimento_id', '72700000-0000-4000-8000-000000000031'::uuid,
    'profissional_id',    '72700000-0000-4000-8000-000000000021'::uuid
  ),
  'segunda chamada de remover_da_equipe é idempotente e devolve MembroDaEquipe'
);

-- ── 4. Testes de confirmar_checkin_manual: Conta Suspensa e Posição Cancelada ───

-- 18. Contratante com conta suspensa chamando confirmar_checkin_manual: 403 conta_suspensa
select throws_ok(
  pg_temp.por((select user_dono_ze_suspenso from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select turno_danilo_cancelado from ids))),
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'confirmar_checkin_manual por membro com conta suspensa recusa 403 conta_suspensa'
);

-- 19. Turno em posição cancelada: gatilho de segurança recusa 409 vaga_encerrada / posicao_cancelada
select throws_ok(
  pg_temp.por((select user_dono_ze from ids),
    format($$ select public.confirmar_checkin_manual(%L) $$, (select turno_danilo_cancelado from ids))),
  'PGRST', pg_temp.erro('vaga_encerrada', 'posicao_cancelada'),
  'confirmar_checkin_manual em turno de posicao cancelada recusa 409 vaga_encerrada (RN22/RN07)'
);

select * from finish();

rollback;
