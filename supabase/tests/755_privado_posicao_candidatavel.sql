-- 755_privado_posicao_candidatavel.sql
--
-- Cobertura pgTAP de privado.posicao_candidatavel(p public.posicao, agora timestamptz).
-- Regra de negócio (RN19, contrato 0.2.19, item 5):
--   1. Posição aberta antes do início (inicio_em > agora) aceita candidatura (retorna true).
--   2. Posição aberta após o início (inicio_em <= agora) sem reabertura recusa candidatura (retorna false).
--   3. Posição reaberta por atraso aceita candidatura até 1h antes do término (agora < fim_em - 1h) e recusa quando resta menos de 1h (agora >= fim_em - 1h).

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select plan(3);

-- Setup de Dados de Teste (prefixo 755)
create temp table ids as select
  '75500000-0000-4000-8000-000000000001'::uuid as user_dono,
  '75500000-0000-4000-8000-000000000010'::uuid as estab_id,
  '75500000-0000-4000-8000-000000000030'::uuid as vaga_id,
  '75500000-0000-4000-8000-0000000000a1'::uuid as pos_normal,
  '75500000-0000-4000-8000-0000000000a2'::uuid as pos_reaberta;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('75500000-0000-4000-8000-000000000001', 'contratante', 'Dono 755', 'dono@755.test', '+5561975500001', '1985-01-01', 'ativa', '1.0', now());

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('75500000-0000-4000-8000-000000000010', 'Restaurante 755', '75500000000110', 'food_service', 'CLN 300', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('75500000-0000-4000-8000-000000000001', '75500000-0000-4000-8000-000000000010', 'administrador');

insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por,
  publicado_em
) values (
  '75500000-0000-4000-8000-000000000030', '75500000-0000-4000-8000-000000000010',
  (select id from public.funcao limit 1), 'POINT(-47.8822 -15.7942)'::extensions.geography,
  'Salão 755', 15000, 2, true, false, false, 'Dono 755',
  '2026-10-18 18:00:00-03', '2026-10-18 23:00:00-03', 'urgencia', 'publicada',
  'Plano Piloto', gen_random_uuid(), '75500000-0000-4000-8000-000000000001',
  '2026-10-18 12:00:00-03'
);

-- Posição 1: aberta normal (início 18h, fim 23h)
insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em) values
  ('75500000-0000-4000-8000-0000000000a1', '75500000-0000-4000-8000-000000000030', 'aberta', '2026-10-18 18:00:00-03', '2026-10-18 23:00:00-03');

-- Posição 2: reaberta por atraso (reaberta_por_atraso_de preenchido)
insert into public.posicao (id, vaga_id, estado, inicio_em, fim_em, reaberta_por_atraso_de) values
  ('75500000-0000-4000-8000-0000000000a2', '75500000-0000-4000-8000-000000000030', 'aberta', '2026-10-18 18:00:00-03', '2026-10-18 23:00:00-03', '75500000-0000-4000-8000-0000000000a1');

-- ── 1. Posição normal aberta antes do início ─────────────────────────────────────
select is(
  (select privado.posicao_candidatavel(p.*, '2026-10-18 17:00:00-03'::timestamptz)
     from public.posicao p where p.id = (select pos_normal from ids)),
  true,
  'privado.posicao_candidatavel retorna true para posição aberta antes de inicio_em'
);

-- ── 2. Posição normal aberta após o início ────────────────────────────────────────
select is(
  (select privado.posicao_candidatavel(p.*, '2026-10-18 18:30:00-03'::timestamptz)
     from public.posicao p where p.id = (select pos_normal from ids)),
  false,
  'privado.posicao_candidatavel retorna false para posição aberta com horário de início ultrapassado'
);

-- ── 3. Posição reaberta por atraso: válida até fim - 1h, inválida depois ──────────
select is(
  (select jsonb_build_array(
            privado.posicao_candidatavel(p.*, '2026-10-18 21:59:00-03'::timestamptz),
            privado.posicao_candidatavel(p.*, '2026-10-18 22:00:00-03'::timestamptz)
          )
     from public.posicao p where p.id = (select pos_reaberta from ids)),
  '[true, false]'::jsonb,
  'privado.posicao_candidatavel aceita reaberta até 1h antes do fim e recusa dentro da última hora'
);

select * from finish();

rollback;
