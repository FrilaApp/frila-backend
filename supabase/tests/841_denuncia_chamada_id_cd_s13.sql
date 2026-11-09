-- 841_denuncia_chamada_id_cd_s13.sql
--
-- Denúncia feita na chamada leva o chamada_id (CD-S13, contrato 0.2.71, cartão AGkBFg9a).
--
-- 1. Denúncia válida com chamada_id salva a referência na tabela public.ocorrencia.
-- 2. Sigilo RN15: grava apenas a referência chamada_id em ocorrencia, nunca o recado da chamada.
-- 3. Denúncia com chamada_id inválido ou de terceiros recusa com 422 campo_invalido (details: chamada_id).
-- 4. Denúncia sem chamada_id continua funcionando normalmente (regressão).

begin;
select plan(18);

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

set local "frila.agora" = '2026-11-09 15:00:00+00';
set local frila.agendador_secret = 'segredo-de-teste-841';

create function pg_temp.como(conta uuid, sql text) returns jsonb language plpgsql as $$
declare r jsonb;
begin
  execute 'set local role authenticated';
  execute format('set local request.jwt.claims = %L', json_build_object('sub', conta, 'role', 'authenticated')::text);
  execute sql into r;
  reset role; execute 'reset request.jwt.claims';
  return r;
end $$;

create function pg_temp.erro(conta uuid, sql text) returns jsonb language plpgsql as $$
declare msg text; det text;
begin
  perform pg_temp.como(conta, sql);
  return null;
exception when others then
  get stacked diagnostics msg = message_text, det = pg_exception_detail;
  reset role; execute 'reset request.jwt.claims';
  return msg::jsonb || det::jsonb;
end $$;

-- ── 1. Fixtures ───────────────────────────────────────────────────────────────

insert into auth.users (id, email) values
  ('84100000-0000-4000-8000-000000000001', 'casa1@841.test'),
  ('84100000-0000-4000-8000-000000000002', 'prof1@841.test'),
  ('84100000-0000-4000-8000-000000000003', 'casa2@841.test'),
  ('84100000-0000-4000-8000-000000000004', 'prof2@841.test');

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, termos_versao, termos_aceite_em, estado) values
  ('84100000-0000-4000-8000-000000000001', 'contratante', 'Contratante Um', 'casa1@841.test', '+5561955508411', '1990-01-01', '1.0', now(), 'ativa'),
  ('84100000-0000-4000-8000-000000000002', 'profissional', 'Profissional Um', 'prof1@841.test', '+5561955508412', '1995-01-01', '1.0', now(), 'ativa'),
  ('84100000-0000-4000-8000-000000000003', 'contratante', 'Contratante Dois', 'casa2@841.test', '+5561955508413', '1992-01-01', '1.0', now(), 'ativa'),
  ('84100000-0000-4000-8000-000000000004', 'profissional', 'Profissional Dois', 'prof2@841.test', '+5561955508414', '1994-01-01', '1.0', now(), 'ativa');

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('84100000-0000-4000-8000-0000000000e1', 'Bar 841 Um', '84112345000101', 'food_service', 'CLN 101', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'),
  ('84100000-0000-4000-8000-0000000000e2', 'Bar 841 Dois', '84112345000102', 'food_service', 'CLN 102', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel) values
  ('84100000-0000-4000-8000-0000000000e1', '84100000-0000-4000-8000-000000000001', 'administrador'),
  ('84100000-0000-4000-8000-0000000000e2', '84100000-0000-4000-8000-000000000003', 'administrador');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('84100000-0000-4000-8000-000000000012', '84100000-0000-4000-8000-000000000002', 'POINT(-47.8822 -15.7942)'::extensions.geography),
  ('84100000-0000-4000-8000-000000000014', '84100000-0000-4000-8000-000000000004', 'POINT(-47.8822 -15.7942)'::extensions.geography);

insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto, valor_centavos, posicoes,
                         inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local, modo, chave_cliente, publicado_por, publicado_em)
values
  ('84100000-0000-4000-8000-0000000000b1', '84100000-0000-4000-8000-0000000000e1', (select id from public.funcao where nome = 'garçom'),
   '2026-11-10 18:00+00', '2026-11-10 23:00+00', 'CLN 101', 'POINT(-47.8822 -15.7942)'::extensions.geography, 15000, 1,
   true, false, false, 'Gerente 1', 'urgencia', gen_random_uuid(), '84100000-0000-4000-8000-000000000001', now()),
  ('84100000-0000-4000-8000-0000000000b2', '84100000-0000-4000-8000-0000000000e2', (select id from public.funcao where nome = 'garçom'),
   '2026-11-10 18:00+00', '2026-11-10 23:00+00', 'CLN 102', 'POINT(-47.8822 -15.7942)'::extensions.geography, 15000, 1,
   true, false, false, 'Gerente 2', 'urgencia', gen_random_uuid(), '84100000-0000-4000-8000-000000000003', now());

insert into public.chamada (id, vaga_id, profissional_id, estabelecimento_id, criada_por, estado, recado, expira_em, criada_em, chave)
values
  ('84100000-0000-4000-8000-0000000000c1', '84100000-0000-4000-8000-0000000000b1', '84100000-0000-4000-8000-000000000012',
   '84100000-0000-4000-8000-0000000000e1', '84100000-0000-4000-8000-000000000001', 'aberta', 'Recado confidencial da chamada 1',
   now() + interval '1 day', now(), gen_random_uuid()),
  ('84100000-0000-4000-8000-0000000000c2', '84100000-0000-4000-8000-0000000000b2', '84100000-0000-4000-8000-000000000014',
   '84100000-0000-4000-8000-0000000000e2', '84100000-0000-4000-8000-000000000003', 'aberta', 'Recado confidencial da chamada 2',
   now() + interval '1 day', now(), gen_random_uuid());

-- ── 2. Assinatura e permissões ────────────────────────────────────────────────

select has_function('public', 'denunciar', array['text', 'uuid', 'text', 'text', 'uuid', 'uuid', 'uuid', 'uuid'],
  'public.denunciar aceita 8 parâmetros incluindo chamada_id');

select is(
  has_function_privilege('anon', 'public.denunciar(text, uuid, text, text, uuid, uuid, uuid, uuid)', 'execute'),
  false,
  'anon não chama denunciar');

select is(
  has_function_privilege('authenticated', 'public.denunciar(text, uuid, text, text, uuid, uuid, uuid, uuid)', 'execute'),
  true,
  'authenticated chama denunciar');

-- ── 3. Denúncia válida com chamada_id (Casa 1 denuncia Prof 1) ─────────────────

select is(
  (pg_temp.como('84100000-0000-4000-8000-000000000001', format(
    $$ select public.denunciar('profissional', '84100000-0000-4000-8000-000000000012'::uuid, 'outro',
                              'Relato de conduta na chamada direta número 1', gen_random_uuid(), null, null,
                              '84100000-0000-4000-8000-0000000000c1'::uuid) $$
  ))->>'tipo'),
  'denuncia',
  'denúncia da casa com chamada_id válida registrada');

select is(
  (select o.chamada_id from public.ocorrencia o
    where o.autor_id = '84100000-0000-4000-8000-000000000001'
      and o.chamada_id = '84100000-0000-4000-8000-0000000000c1'::uuid limit 1),
  '84100000-0000-4000-8000-0000000000c1'::uuid,
  'ocorrencia grava referência exata chamada_id');

-- Sigilo RN15: o recado confidencial da chamada não foi gravado em ocorrencia
select is(
  (select count(*) from public.ocorrencia o
    where o.chamada_id = '84100000-0000-4000-8000-0000000000c1'::uuid
      and o.relato like '%Recado confidencial%'),
  0::bigint,
  'RN15: recado da chamada não é gravado na ocorrencia');

-- ── 4. Denúncia válida com chamada_id (Prof 1 denuncia Casa 1) ─────────────────

select is(
  (pg_temp.como('84100000-0000-4000-8000-000000000002', format(
    $$ select public.denunciar('estabelecimento', '84100000-0000-4000-8000-0000000000e1'::uuid, 'outro',
                              'Relato do profissional sobre a casa na chamada', gen_random_uuid(), null, null,
                              '84100000-0000-4000-8000-0000000000c1'::uuid) $$
  ))->>'tipo'),
  'denuncia',
  'denúncia do profissional com chamada_id válida registrada');

select is(
  (select o.chamada_id from public.ocorrencia o
    where o.autor_id = '84100000-0000-4000-8000-000000000002'
      and o.chamada_id = '84100000-0000-4000-8000-0000000000c1'::uuid limit 1),
  '84100000-0000-4000-8000-0000000000c1'::uuid,
  'ocorrencia do profissional grava chamada_id');

-- ── 5. Denúncia sem chamada_id (Regressão) ────────────────────────────────────

select is(
  (pg_temp.como('84100000-0000-4000-8000-000000000001', format(
    $$ select public.denunciar('profissional', '84100000-0000-4000-8000-000000000012'::uuid, 'outro',
                              'Relato sem chamada_id (regressao padrao)', gen_random_uuid()) $$
  ))->>'tipo'),
  'denuncia',
  'denúncia sem chamada_id funciona perfeitamente');

select is(
  (select count(*) from public.ocorrencia o
    where o.autor_id = '84100000-0000-4000-8000-000000000001'
      and o.relato = 'Relato sem chamada_id (regressao padrao)'
      and o.chamada_id is null),
  1::bigint,
  'ocorrencia sem chamada_id mantém chamada_id nulo');

-- ── 6. Denúncia com chamada_id inexistente ─────────────────────────────────────

select is(
  (pg_temp.erro('84100000-0000-4000-8000-000000000001', format(
    $$ select public.denunciar('profissional', '84100000-0000-4000-8000-000000000012'::uuid, 'outro',
                              'Relato com chamada_id que nao existe', gen_random_uuid(), null, null,
                              '84100000-0000-4000-8000-000000000999'::uuid) $$
  ))->>'code'),
  'campo_invalido',
  'chamada inexistente recusa com 422 campo_invalido');

select is(
  (pg_temp.erro('84100000-0000-4000-8000-000000000001', format(
    $$ select public.denunciar('profissional', '84100000-0000-4000-8000-000000000012'::uuid, 'outro',
                              'Relato com chamada_id que nao existe detalhe', gen_random_uuid(), null, null,
                              '84100000-0000-4000-8000-000000000999'::uuid) $$
  ))->>'details'),
  'chamada_id',
  'detalhe da recusa por chamada inexistente é chamada_id');

-- ── 7. Denúncia com chamada_id de terceiros (alvo e casa não batem) ───────────

select is(
  (pg_temp.erro('84100000-0000-4000-8000-000000000001', format(
    $$ select public.denunciar('profissional', '84100000-0000-4000-8000-000000000012'::uuid, 'outro',
                              'Relato passando chamada de terceiros (ch2)', gen_random_uuid(), null, null,
                              '84100000-0000-4000-8000-0000000000c2'::uuid) $$
  ))->>'code'),
  'campo_invalido',
  'chamada de terceiros (ch2) recusa com campo_invalido');

select is(
  (pg_temp.erro('84100000-0000-4000-8000-000000000001', format(
    $$ select public.denunciar('profissional', '84100000-0000-4000-8000-000000000012'::uuid, 'outro',
                              'Relato passando chamada de terceiros (ch2) detalhe', gen_random_uuid(), null, null,
                              '84100000-0000-4000-8000-0000000000c2'::uuid) $$
  ))->>'details'),
  'chamada_id',
  'detalhe da recusa por chamada de terceiros é chamada_id');

-- ── 8. Denúncia com denunciante terceiro (outro contratante) ──────────────────

select is(
  (pg_temp.erro('84100000-0000-4000-8000-000000000003', format(
    $$ select public.denunciar('profissional', '84100000-0000-4000-8000-000000000012'::uuid, 'outro',
                              'Casa 2 tenta denunciar Prof 1 usando ch1', gen_random_uuid(), null, null,
                              '84100000-0000-4000-8000-0000000000c1'::uuid) $$
  ))->>'code'),
  'campo_invalido',
  'denunciante contratante não pertencente à casa da chamada recusa campo_invalido');

select is(
  (pg_temp.erro('84100000-0000-4000-8000-000000000003', format(
    $$ select public.denunciar('profissional', '84100000-0000-4000-8000-000000000012'::uuid, 'outro',
                              'Casa 2 tenta denunciar Prof 1 usando ch1 detalhe', gen_random_uuid(), null, null,
                              '84100000-0000-4000-8000-0000000000c1'::uuid) $$
  ))->>'details'),
  'chamada_id',
  'detalhe da recusa contratante alheio é chamada_id');

-- ── 9. Denúncia com denunciante terceiro (outro profissional) ─────────────────

select is(
  (pg_temp.erro('84100000-0000-4000-8000-000000000004', format(
    $$ select public.denunciar('estabelecimento', '84100000-0000-4000-8000-0000000000e1'::uuid, 'outro',
                              'Prof 2 tenta denunciar Casa 1 usando ch1', gen_random_uuid(), null, null,
                              '84100000-0000-4000-8000-0000000000c1'::uuid) $$
  ))->>'code'),
  'campo_invalido',
  'denunciante profissional não pertencente à chamada recusa campo_invalido');

select is(
  (pg_temp.erro('84100000-0000-4000-8000-000000000004', format(
    $$ select public.denunciar('estabelecimento', '84100000-0000-4000-8000-0000000000e1'::uuid, 'outro',
                              'Prof 2 tenta denunciar Casa 1 usando ch1 detalhe', gen_random_uuid(), null, null,
                              '84100000-0000-4000-8000-0000000000c1'::uuid) $$
  ))->>'details'),
  'chamada_id',
  'detalhe da recusa profissional alheio é chamada_id');

rollback;
