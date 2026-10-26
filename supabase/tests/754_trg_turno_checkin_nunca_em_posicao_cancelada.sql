-- 754_trg_turno_checkin_nunca_em_posicao_cancelada.sql
--
-- Cobertura pgTAP do gatilho turno_checkin_nunca_em_posicao_cancelada e da função privado.checkin_nunca_em_posicao_cancelada().
-- Regra: impede registro de check-in em turno cuja posição já foi cancelada (reaberta por atraso ou cancelada por uma das partes).
-- Migração: 20260928220000_alerta_de_atraso_e_reabrir_por_atraso.sql.

begin;

insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;
set local frila.agora = '2026-10-18 12:00:00-03';

select plan(3);

-- Setup de Dados de Teste (prefixo 754)
create temp table ids as select
  '75400000-0000-4000-8000-000000000001'::uuid as user_dono,
  '75400000-0000-4000-8000-000000000002'::uuid as user_prof,
  '75400000-0000-4000-8000-000000000010'::uuid as estab_id,
  '75400000-0000-4000-8000-000000000020'::uuid as prof_id,
  '75400000-0000-4000-8000-000000000030'::uuid as vaga_id,
  '75400000-0000-4000-8000-0000000000a1'::uuid as pos_cancelada,
  '75400000-0000-4000-8000-0000000000a2'::uuid as pos_confirmada,
  '75400000-0000-4000-8000-0000000000b1'::uuid as turno_cancelado,
  '75400000-0000-4000-8000-0000000000b2'::uuid as turno_confirmado;

insert into public.usuario (id, perfil, nome, email, telefone, nascimento, estado, termos_versao, termos_aceite_em) values
  ('75400000-0000-4000-8000-000000000001', 'contratante',  'Dono 754',  'dono@754.test',  '+5561975400001', '1985-01-01', 'ativa', '1.0', now()),
  ('75400000-0000-4000-8000-000000000002', 'profissional', 'Prof 754',  'prof@754.test',  '+5561975400002', '1995-01-01', 'ativa', '1.0', now());

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto, regiao_administrativa) values
  ('75400000-0000-4000-8000-000000000010', 'Casa 754', '75400000000110', 'food_service', 'CLN 300', 'POINT(-47.8822 -15.7942)'::extensions.geography, 'Plano Piloto');

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel) values
  ('75400000-0000-4000-8000-000000000001', '75400000-0000-4000-8000-000000000010', 'administrador');

insert into public.profissional (id, usuario_id, ponto_base) values
  ('75400000-0000-4000-8000-000000000020', '75400000-0000-4000-8000-000000000002', 'POINT(-47.8850 -15.7900)'::extensions.geography);

insert into public.vaga (
  id, estabelecimento_id, funcao_id, ponto, local, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  inicio_em, fim_em, modo, estado, regiao_administrativa, chave_cliente, publicado_por,
  publicado_em
) values (
  '75400000-0000-4000-8000-000000000030', '75400000-0000-4000-8000-000000000010',
  (select id from public.funcao limit 1), 'POINT(-47.8822 -15.7942)'::extensions.geography,
  'Cozinha 754', 15000, 2, true, false, false, 'Gerente 754',
  '2026-10-18 18:00:00-03', '2026-10-18 23:00:00-03', 'urgencia', 'publicada',
  'Plano Piloto', gen_random_uuid(), '75400000-0000-4000-8000-000000000001',
  '2026-10-18 12:00:00-03'
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em) values
  ('75400000-0000-4000-8000-0000000000a1', '75400000-0000-4000-8000-000000000030', 'cancelada',  null, null, '2026-10-18 18:00:00-03', '2026-10-18 23:00:00-03'),
  ('75400000-0000-4000-8000-0000000000a2', '75400000-0000-4000-8000-000000000030', 'confirmada', '75400000-0000-4000-8000-000000000020', now(), '2026-10-18 18:00:00-03', '2026-10-18 23:00:00-03');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_confirmado_em, verificacao, valor_acordado_centavos) values
  ('75400000-0000-4000-8000-0000000000b1', '75400000-0000-4000-8000-0000000000a1', null, null, null, 'pendente', 15000),
  ('75400000-0000-4000-8000-0000000000b2', '75400000-0000-4000-8000-0000000000a2', null, null, null, 'pendente', 15000);

-- ── 1. Bloqueia update de checkin_em em turno de posição cancelada ────────────────
select throws_ok(
  format('update public.turno set checkin_em = %L where id = %L',
         '2026-10-18 18:05:00-03'::timestamptz,
         (select turno_cancelado from ids)),
  'PGRST',
  '{"code" : "vaga_encerrada", "message" : "vaga_encerrada", "details" : "posicao_cancelada", "hint" : null}',
  'Gatilho turno_checkin_nunca_em_posicao_cancelada bloqueia check-in em posição cancelada'
);

-- ── 2. Permite update de checkin_em em turno de posição confirmada ────────────────
select lives_ok(
  format('update public.turno set checkin_em = %L where id = %L',
         '2026-10-18 18:05:00-03'::timestamptz,
         (select turno_confirmado from ids)),
  'Gatilho turno_checkin_nunca_em_posicao_cancelada permite check-in em posição confirmada'
);

-- ── 3. Permite update em turno de posição cancelada se checkin_em permanecer nulo ─
select lives_ok(
  format('update public.turno set checkin_tipo = %L where id = %L',
         'manual',
         (select turno_cancelado from ids)),
  'Update que não altera checkin_em para não-nulo é permitido mesmo em posição cancelada'
);

select * from finish();

rollback;
