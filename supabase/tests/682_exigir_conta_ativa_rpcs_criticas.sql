-- 682_exigir_conta_ativa_rpcs_criticas.sql
--
-- Cobertura pgTAP por RPC crítica:
-- Validação de exigir_conta_ativa e imunidade a regressão em pg_context.
--
-- RPCs críticas cobertas (10):
-- 1. publicar_vaga
-- 2. candidatar
-- 3. escolher_candidato
-- 4. cancelar_posicao
-- 5. cancelar_vaga
-- 6. fazer_checkin
-- 7. fazer_checkout
-- 8. avaliar
-- 9. denunciar
-- 10. bloquear
--
-- Exceções contratuais na regex de exigir_conta_ativa cobertas:
-- candidatar, contestar_suspensao, registrar_dispositivo, remover_dispositivo, privado.excluir_conta.

begin;
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-16 12:00:00-03';

-- 10 RPCs com conta suspensa (10)
-- 10 RPCs com conta anonimizada (10)
-- 10 RPCs com conta inexistente (10)
-- 4 Exceções contratuais que NÃO devem tomar 403 (contestar_suspensao, registrar_dispositivo, remover_dispositivo, privado.excluir_conta) (4)
-- 1 Verificação de integridade da regex de pg_context em privado.exigir_conta_ativa (1)
-- Total = 10 + 10 + 10 + 4 + 1 = 35 asserções.
select plan(35);

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

create function pg_temp.erro(codigo text, detalhe text default null) returns text
language sql as $$
  select format('{"code" : "%s", "message" : "%s", "details" : %s, "hint" : null}',
                codigo, codigo, coalesce('"' || detalhe || '"', 'null'))
$$;

-- ── 1. Cenário de teste (prefixo f8) ──────────────────────────────────────────

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado, anonimizado_em) values
  ('f8000000-0000-4000-8000-000000000001', 'contratante',  'Contratante Ativo',    '+5561999980001', 'c_ativo@f8.test',   '1985-01-01', '2026-09-22', now(), 'ativa', null),
  ('f8000000-0000-4000-8000-000000000002', 'profissional', 'Profissional Ativo',   '+5561999980002', 'p_ativo@f8.test',   '1992-02-02', '2026-09-22', now(), 'ativa', null),
  ('f8000000-0000-4000-8000-000000000003', 'contratante',  'Contratante Suspenso', '+5561999980003', 'c_susp@f8.test',    '1988-03-03', '2026-09-22', now(), 'suspensa', null),
  ('f8000000-0000-4000-8000-000000000004', 'profissional', 'Profissional Suspenso', '+5561999980004', 'p_susp@f8.test',    '1994-04-04', '2026-09-22', now(), 'suspensa', null),
  ('f8000000-0000-4000-8000-000000000005', 'profissional', 'Conta encerrada',     null,             null,                 '1990-05-05', '2026-09-22', now(), 'anonimizada', now()),
  ('f8000000-0000-4000-8000-000000000006', 'profissional', 'Profissional Exclusao', '+5561999980006', 'p_excl@f8.test',    '1993-06-06', '2026-09-22', now(), 'suspensa', null);

insert into public.profissional (id, usuario_id, ponto_base) values
  ('f8000000-0000-4000-8000-000000000012', 'f8000000-0000-4000-8000-000000000002', 'POINT(-47.8825 -15.7942)'::extensions.geography),
  ('f8000000-0000-4000-8000-000000000004', 'f8000000-0000-4000-8000-000000000004', 'POINT(-47.8825 -15.7942)'::extensions.geography),
  ('f8000000-0000-4000-8000-000000000015', 'f8000000-0000-4000-8000-000000000005', 'POINT(-47.8825 -15.7942)'::extensions.geography),
  ('f8000000-0000-4000-8000-000000000016', 'f8000000-0000-4000-8000-000000000006', 'POINT(-47.8825 -15.7942)'::extensions.geography);

insert into public.profissional_funcao (profissional_id, funcao_id)
select p.id, f.id
  from (values
    ('f8000000-0000-4000-8000-000000000012'::uuid),
    ('f8000000-0000-4000-8000-000000000004'::uuid),
    ('f8000000-0000-4000-8000-000000000015'::uuid),
    ('f8000000-0000-4000-8000-000000000016'::uuid)
  ) as p(id)
  cross join (select id from public.funcao where nome = 'garçom' limit 1) f;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('f8000000-0000-4000-8000-000000000010', 'Restaurante F8', '11222333000199', 'food_service', 'SCLN 302 Bloco B',
   'POINT(-47.8825 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('f8000000-0000-4000-8000-000000000010', 'f8000000-0000-4000-8000-000000000001', 'administrador'),
  ('f8000000-0000-4000-8000-000000000010', 'f8000000-0000-4000-8000-000000000003', 'administrador');

-- ── 2. Conta suspensa: 10 RPCs críticas ────────────────────────────────────────

-- 1. publicar_vaga: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000003',
       'select public.publicar_vaga(
          ''f8000000-0000-4000-8000-000000000010''::uuid,
          (select id from public.funcao where nome = ''garçom'' limit 1),
          now() + interval ''2 hours'', now() + interval ''8 hours'',
          ''Local'', ''{"tipo":"ponto"}''::jsonb, 12000, 1, true, false, false,
          ''Chefe'', ''urgencia''::public.modo_preenchimento, gen_random_uuid()
        )') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'publicar_vaga com contratante suspensa devolve 403 conta_suspensa'
);

-- 2. candidatar: 422 inelegivel/perfil_suspenso (RN13 / exceção contratual à regex)
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000004',
       'select public.candidatar(gen_random_uuid())') $$,
  'PGRST', pg_temp.erro('inelegivel', 'perfil_suspenso'),
  'candidatar com profissional suspensa devolve 422 inelegivel/perfil_suspenso (não 403)'
);

-- 3. escolher_candidato: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000003',
       'select public.escolher_candidato(gen_random_uuid())') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'escolher_candidato com contratante suspensa devolve 403 conta_suspensa'
);

-- 4. cancelar_posicao: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000004',
       'select public.cancelar_posicao(gen_random_uuid(), ''Imprevisto com transporte'')') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'cancelar_posicao com conta suspensa devolve 403 conta_suspensa'
);

-- 5. cancelar_vaga: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000003',
       'select public.cancelar_vaga(gen_random_uuid(), ''Evento cancelado pelo cliente'')') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'cancelar_vaga com contratante suspensa devolve 403 conta_suspensa'
);

-- 6. fazer_checkin: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000004',
       'select public.fazer_checkin(gen_random_uuid(), 50, now())') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'fazer_checkin com profissional suspensa devolve 403 conta_suspensa'
);

-- 7. fazer_checkout: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000004',
       'select public.fazer_checkout(gen_random_uuid(), 50, now())') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'fazer_checkout com profissional suspensa devolve 403 conta_suspensa'
);

-- 8. avaliar: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000004',
       'select public.avaliar(gen_random_uuid(), true)') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'avaliar com conta suspensa devolve 403 conta_suspensa'
);

-- 9. denunciar: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000004',
       'select public.denunciar(
          ''estabelecimento'', gen_random_uuid(),
          ''comportamento_inadequado'', ''Relato detalhado com mais de dez caracteres'',
          gen_random_uuid()
        )') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'denunciar com conta suspensa devolve 403 conta_suspensa'
);

-- 10. bloquear: 403 conta_suspensa
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000004',
       'select public.bloquear(''estabelecimento'', gen_random_uuid())') $$,
  'PGRST', pg_temp.erro('sem_permissao', 'conta_suspensa'),
  'bloquear com conta suspensa devolve 403 conta_suspensa'
);

-- ── 3. Conta anonimizada: 10 RPCs críticas (401 nao_autenticado) ───────────────

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000005',
       'select public.publicar_vaga(
          ''f8000000-0000-4000-8000-000000000010''::uuid,
          (select id from public.funcao where nome = ''garçom'' limit 1),
          now() + interval ''2 hours'', now() + interval ''8 hours'',
          ''Local'', ''{"tipo":"ponto"}''::jsonb, 12000, 1, true, false, false,
          ''Chefe'', ''urgencia''::public.modo_preenchimento, gen_random_uuid()
        )') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'publicar_vaga com conta anonimizada devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000005',
       'select public.candidatar(gen_random_uuid())') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'candidatar com conta anonimizada devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000005',
       'select public.escolher_candidato(gen_random_uuid())') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'escolher_candidato com conta anonimizada devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000005',
       'select public.cancelar_posicao(gen_random_uuid(), ''Imprevisto'')') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'cancelar_posicao com conta anonimizada devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000005',
       'select public.cancelar_vaga(gen_random_uuid(), ''Cancelado'')') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'cancelar_vaga com conta anonimizada devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000005',
       'select public.fazer_checkin(gen_random_uuid(), 50, now())') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'fazer_checkin com conta anonimizada devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000005',
       'select public.fazer_checkout(gen_random_uuid(), 50, now())') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'fazer_checkout com conta anonimizada devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000005',
       'select public.avaliar(gen_random_uuid(), true)') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'avaliar com conta anonimizada devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000005',
       'select public.denunciar(
          ''estabelecimento'', gen_random_uuid(),
          ''comportamento_inadequado'', ''Relato detalhado com mais de dez caracteres'',
          gen_random_uuid()
        )') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'denunciar com conta anonimizada devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000005',
       'select public.bloquear(''estabelecimento'', gen_random_uuid())') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'bloquear com conta anonimizada devolve 401 nao_autenticado'
);

-- ── 4. Conta inexistente: 10 RPCs críticas (401 nao_autenticado) ───────────────

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000099',
       'select public.publicar_vaga(
          ''f8000000-0000-4000-8000-000000000010''::uuid,
          (select id from public.funcao where nome = ''garçom'' limit 1),
          now() + interval ''2 hours'', now() + interval ''8 hours'',
          ''Local'', ''{"tipo":"ponto"}''::jsonb, 12000, 1, true, false, false,
          ''Chefe'', ''urgencia''::public.modo_preenchimento, gen_random_uuid()
        )') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'publicar_vaga com conta inexistente devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000099',
       'select public.candidatar(gen_random_uuid())') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'candidatar com conta inexistente devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000099',
       'select public.escolher_candidato(gen_random_uuid())') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'escolher_candidato com conta inexistente devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000099',
       'select public.cancelar_posicao(gen_random_uuid(), ''Imprevisto'')') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'cancelar_posicao com conta inexistente devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000099',
       'select public.cancelar_vaga(gen_random_uuid(), ''Cancelado'')') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'cancelar_vaga com conta inexistente devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000099',
       'select public.fazer_checkin(gen_random_uuid(), 50, now())') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'fazer_checkin com conta inexistente devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000099',
       'select public.fazer_checkout(gen_random_uuid(), 50, now())') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'fazer_checkout com conta inexistente devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000099',
       'select public.avaliar(gen_random_uuid(), true)') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'avaliar com conta inexistente devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000099',
       'select public.denunciar(
          ''estabelecimento'', gen_random_uuid(),
          ''comportamento_inadequado'', ''Relato detalhado com mais de dez caracteres'',
          gen_random_uuid()
        )') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'denunciar com conta inexistente devolve 401 nao_autenticado'
);

select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000099',
       'select public.bloquear(''estabelecimento'', gen_random_uuid())') $$,
  'PGRST', pg_temp.erro('nao_autenticado'),
  'bloquear com conta inexistente devolve 401 nao_autenticado'
);

-- ── 5. Exceções contratuais de conta suspensa em exigir_conta_ativa ─────────────
-- As funções a seguir são permitidas para conta suspensa via regex de pg_context:
-- public.(contestar_suspensao|registrar_dispositivo|remover_dispositivo|candidatar)|privado.excluir_conta

-- 1. contestar_suspensao: conta suspensa NÃO recebe 403 (recebe 422 se relato curto ou sucesso)
select throws_ok(
  $$ select pg_temp.como('f8000000-0000-4000-8000-000000000004',
       'select public.contestar_suspensao(''curto'')') $$,
  'PGRST', pg_temp.erro('campo_invalido', 'relato'),
  'contestar_suspensao com conta suspensa passa pelo 403 e valida relato (422 campo_invalido)'
);

-- 2. registrar_dispositivo: conta suspensa NÃO recebe 403 (registra normalmente)
select is(
  ((pg_temp.como('f8000000-0000-4000-8000-000000000004',
     'select public.registrar_dispositivo(''token_fcm_f8_suspensa_01'', ''android'')'))->>'plataforma'),
  'android',
  'registrar_dispositivo com conta suspensa não toma 403 e registra com sucesso'
);

-- 3. remover_dispositivo: conta suspensa NÃO recebe 403
select is(
  ((pg_temp.como('f8000000-0000-4000-8000-000000000004',
     'select public.remover_dispositivo(''token_fcm_f8_suspensa_01'')'))->>'removido')::boolean,
  true,
  'remover_dispositivo com conta suspensa não toma 403 e remove com sucesso'
);

-- 4. privado.excluir_conta: conta suspensa NÃO recebe 403
select ok(
  (privado.excluir_conta('f8000000-0000-4000-8000-000000000006')->>'perfil_removido_em') is not null,
  'privado.excluir_conta com conta suspensa não toma 403 e conclui exclusão'
);

-- ── 6. Integridade da regex em pg_proc ─────────────────────────────────────────



-- Prova que a regex em exigir_conta_ativa está sincronizada com a lista contratual
select ok(
  position('PL/pgSQL function (public\.(contestar_suspensao|registrar_dispositivo|remover_dispositivo|candidatar)|privado\.excluir_conta)\('
           in (select prosrc from pg_proc where proname = 'exigir_conta_ativa' and pronamespace = 'privado'::regnamespace)) > 0,
  'definicao de privado.exigir_conta_ativa contem a regex exata com as 5 excecoes contratuais'
);

select * from finish();
rollback;
