-- 757_privado_candidatura_em_json.sql
--
-- Cobertura pgTAP de privado.candidatura_em_json(candidatura uuid).
-- Contrato 0.2.32 (envelope Candidatura: id, vaga, estado, criada_em, turno_id).
--
-- Regras validadas:
--   1. Candidatura com estado 'aceita' devolve envelope completo com sub-objeto
--      vaga (VagaResumo) e turno_id preenchido com o UUID do turno associado à posição.
--   2. Candidatura com estado diferente de 'aceita' (ex.: 'pendente') devolve
--      o envelope com turno_id estritamente NULL.
--   3. Candidatura inexistente devolve NULL.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(3);

-- Setup de Dados de Teste
create temp table ids as select
  '75700000-0000-4000-8000-000000000001'::uuid as user_contratante,
  '75700000-0000-4000-8000-000000000002'::uuid as user_prof,
  '75700000-0000-4000-8000-000000000003'::uuid as prof_id,
  '75700000-0000-4000-8000-000000000010'::uuid as estab_id,
  '75700000-0000-4000-8000-000000000100'::uuid as vaga_id,
  '75700000-0000-4000-8000-000000000201'::uuid as pos_aceita_id,
  '75700000-0000-4000-8000-000000000202'::uuid as pos_pendente_id,
  '75700000-0000-4000-8000-000000000301'::uuid as cand_aceita_id,
  '75700000-0000-4000-8000-000000000302'::uuid as cand_pendente_id,
  '75700000-0000-4000-8000-000000000401'::uuid as turno_id;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', user_contratante, 'authenticated', 'authenticated',
       'contratante757@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
select '00000000-0000-0000-0000-000000000000', user_prof, 'authenticated', 'authenticated',
       'prof757@test.com', now(), '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false
from ids on conflict (id) do nothing;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('75700000-0000-4000-8000-000000000001', 'contratante',  'Dono 757', 'contratante757@test.com', '+5561975700001', '1980-01-01', 'ativa', '1.0', now()),
  ('75700000-0000-4000-8000-000000000002', 'profissional', 'Prof 757', 'prof757@test.com',        '+5561975700002', '1995-05-15', 'ativa', '1.0', now());

insert into public.profissional (id, usuario_id, ponto_base, turnos_realizados, taxa_comparecimento)
select prof_id, user_prof, 'POINT(-47.88 -15.79)'::extensions.geography, 5, 1.000
from ids;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa)
select estab_id, 'Restaurante 757', '75700000000100', 'food_service', 'CLN 102 Bloco C', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto'
from ids;

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
select user_contratante, estab_id, 'administrador'
from ids;

insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  regiao_administrativa, valor_centavos, posicoes, inclui_refeicao,
  inclui_transporte, exige_material_proprio, responsavel_local,
  modo, chave_cliente, publicado_por, estado
)
select
  vaga_id,
  estab_id,
  (select id from public.funcao limit 1),
  '2026-11-25 18:00:00+00'::timestamptz,
  '2026-11-25 23:00:00+00'::timestamptz,
  'CLN 102 Bloco C',
  'POINT(-47.8822 -15.7942)'::extensions.geography,
  'Plano Piloto',
  16000,
  2,
  true,
  false,
  false,
  'Gerente 757',
  'selecao',
  gen_random_uuid(),
  user_contratante,
  'publicada'
from ids;

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado, profissional_id, confirmado_em)
select pos_aceita_id, vaga_id, '2026-11-25 18:00:00+00'::timestamptz, '2026-11-25 23:00:00+00'::timestamptz, 'confirmada', prof_id, now()
from ids;

insert into public.posicao (id, vaga_id, inicio_em, fim_em, estado)
select pos_pendente_id, vaga_id, '2026-11-25 18:00:00+00'::timestamptz, '2026-11-25 23:00:00+00'::timestamptz, 'aberta'
from ids;

insert into public.turno (id, posicao_id, valor_acordado_centavos)
select turno_id, pos_aceita_id, 16000
from ids;

insert into public.candidatura (id, posicao_id, profissional_id, estado, criada_em)
select cand_aceita_id, pos_aceita_id, prof_id, 'aceita', '2026-11-20 10:00:00+00'::timestamptz
from ids;

insert into public.candidatura (id, posicao_id, profissional_id, estado, criada_em)
select cand_pendente_id, pos_pendente_id, prof_id, 'pendente', '2026-11-20 11:00:00+00'::timestamptz
from ids;

-- ── 1. Candidatura 'aceita' devolve envelope completo com turno_id preenchido ─────
select is(
  privado.candidatura_em_json((select cand_aceita_id from ids)),
  jsonb_build_object(
    'id',        (select cand_aceita_id from ids),
    'vaga',      jsonb_build_object(
                   'id',                    (select vaga_id from ids),
                   'funcao',                (select f.nome from public.funcao f join public.vaga v on v.funcao_id = f.id where v.id = (select vaga_id from ids)),
                   'local',                 'CLN 102 Bloco C',
                   'regiao_administrativa', 'Plano Piloto',
                   'inicio_em',             '2026-11-25 18:00:00+00'::timestamptz,
                   'fim_em',                '2026-11-25 23:00:00+00'::timestamptz,
                   'valor_centavos',        16000),
    'estado',    'aceita',
    'criada_em', '2026-11-20 10:00:00+00'::timestamptz,
    'turno_id',  (select turno_id from ids)
  ),
  'privado.candidatura_em_json devolve envelope completo com turno_id preenchido para estado aceita'
);

-- ── 2. Candidatura 'pendente' devolve turno_id estritamente NULL ───────────────────
select is(
  (privado.candidatura_em_json((select cand_pendente_id from ids))->>'turno_id'),
  null,
  'privado.candidatura_em_json devolve turno_id NULL para candidatura pendente'
);

-- ── 3. Candidatura inexistente devolve NULL ────────────────────────────────────────
select is(
  privado.candidatura_em_json('75700000-0000-4000-8000-ffffffffffff'::uuid),
  null,
  'privado.candidatura_em_json devolve NULL para candidatura inexistente'
);

select * from finish();

rollback;
