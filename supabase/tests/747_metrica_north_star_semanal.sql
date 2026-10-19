-- 747_metrica_north_star_semanal.sql
-- Prova de acesso, regras de negócio e cálculo da North Star do Frila (metrica.north_star_semanal).
-- Cartão SDeFULxG (Sprint 4, T-0017), PlanoDeMetricas.md seção 2.3.
--
-- Critérios cobertos:
-- 1. Schema metrica e view metrica.north_star_semanal restritos exclusivamente a service_role.
-- 2. Consistência e números sobre o seed (cenarios.sql):
--    - Total de turnos da North Star no seed é 3 (Bar do Cerrado d07: 1; Buffet Águas Claras d03: 2).
--    - Turnos não verificados do seed (d03: 303 e 304) excluídos.
-- 3. Os 5 casos obrigatórios de aceite:
--    - Caso 1: cumprida + verificado conta na semana do fim do turno.
--    - Caso 2: cumprida + nao_verificado NÃO conta.
--    - Caso 3: posição cancelada (mesmo com turno) NÃO conta.
--    - Caso 4: contas de demonstração (profissional e contratante) e equipe Frila NÃO contam.
--    - Caso 5: fronteira semanal no fuso de Brasília (domingo 23h30 BRT cai na semana de domingo, não na seguinte).

begin;
select plan(17);

create function pg_temp.como(papel text, sql text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', papel);
  execute sql;
  reset role;
end $$;

-- ── 1. Metadados e Permissões de Acesso ──────────────────────────────────────

select has_view(
  'metrica',
  'north_star_semanal',
  'view metrica.north_star_semanal existe'
);

select columns_are(
  'metrica',
  'north_star_semanal',
  array['semana_inicio', 'turnos_concluidos_com_presenca_verificada'],
  'metrica.north_star_semanal possui as colunas semana_inicio e turnos_concluidos_com_presenca_verificada'
);

select throws_ok(
  $$ select pg_temp.como('anon', 'select * from metrica.north_star_semanal') $$,
  '42501',
  null,
  'anon não pode consultar metrica.north_star_semanal'
);

select throws_ok(
  $$ select pg_temp.como('authenticated', 'select * from metrica.north_star_semanal') $$,
  '42501',
  null,
  'authenticated não pode consultar metrica.north_star_semanal'
);

select lives_ok(
  $$ select pg_temp.como('service_role', 'select count(*) from metrica.north_star_semanal') $$,
  'service_role pode consultar metrica.north_star_semanal'
);

-- ── 2. Números sobre o Seed (cenarios.sql) ──────────────────────────────────
-- No seed, há 3 turnos concluídos com presença verificada:
-- 1. Bar do Cerrado (vaga d07): turno 701 (geolocalizado verificado)
-- 2. Buffet Águas Claras (vaga d03): turno 301 (geolocalizado verificado)
-- 3. Buffet Águas Claras (vaga d03): turno 302 (manual confirmado verificado)
-- Os turnos 303 (manual sem confirmação, nao_verificado) e 304 (sem checkin) não entram.
select is(
  (select sum(turnos_concluidos_com_presenca_verificada)::bigint from metrica.north_star_semanal),
  3::bigint,
  'seed: total de turnos concluídos com presença verificada na North Star é 3'
);

select is(
  (select count(*)::bigint from metrica.north_star_semanal),
  1::bigint,
  'seed: exatamente 1 semana possui turnos concluídos no seed'
);

select is(
  (select turnos_concluidos_com_presenca_verificada
     from metrica.north_star_semanal
    where semana_inicio = date_trunc('week', (select p.fim_em at time zone 'America/Sao_Paulo' from public.posicao p where p.id = 'f1000000-0000-4000-8000-000000000301'::uuid))::date),
  3::bigint,
  'seed: a semana das vagas d03 e d07 consolida 3 turnos verificados (301 e 302 de d03 + 701 de d07; 303 e 304 não verificados excluídos)'
);

-- ── 3. Os 5 Casos de Aceite do Critério 2 ─────────────────────────────────────
-- Criação de contas e estabelecimentos de teste isolados (prefixo a747)

-- Contratante real e Estabelecimento
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('a7470000-0000-4000-8000-000000000001', 'contratante', 'Contratante NS', '+5561974700001', 'contratante_ns@test.invalid', '1985-01-01', '1.0', now());

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('a7470000-0000-4000-8000-000000000021', 'Bar Teste North Star', '74700000000101', 'food_service', 'CLN 208 Bloco B', 'POINT(-47.8869 -15.7620)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('a7470000-0000-4000-8000-000000000001', 'a7470000-0000-4000-8000-000000000021', 'administrador');

-- Profissionais reais
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('a7470000-0000-4000-8000-000000000002', 'profissional', 'Profissional NS 1', '+5561974700002', 'prof_ns1@test.invalid', '1992-01-01', '1.0', now()),
       ('a7470000-0000-4000-8000-000000000006', 'profissional', 'Profissional NS 2', '+5561974700006', 'prof_ns2@test.invalid', '1994-01-01', '1.0', now());

insert into public.profissional (id, usuario_id, ponto_base)
values ('a7470000-0000-4000-8000-000000000012', 'a7470000-0000-4000-8000-000000000002', 'POINT(-47.8869 -15.7620)'::extensions.geography),
       ('a7470000-0000-4000-8000-000000000016', 'a7470000-0000-4000-8000-000000000006', 'POINT(-47.8869 -15.7620)'::extensions.geography);

insert into public.profissional_funcao (profissional_id, funcao_id)
select p_id, (select id from public.funcao limit 1)
  from unnest(array['a7470000-0000-4000-8000-000000000012'::uuid, 'a7470000-0000-4000-8000-000000000016'::uuid]) as p_id;

-- Profissional demonstração
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values ('a7470000-0000-4000-8000-000000000003', 'profissional', 'Profissional Demo NS', '+5561974700003', 'demo_prof_ns@test.invalid', '1993-01-01', '1.0', now(), true);

insert into public.profissional (id, usuario_id, ponto_base)
values ('a7470000-0000-4000-8000-000000000013', 'a7470000-0000-4000-8000-000000000003', 'POINT(-47.8869 -15.7620)'::extensions.geography);

insert into public.profissional_funcao (profissional_id, funcao_id)
values ('a7470000-0000-4000-8000-000000000013', (select id from public.funcao limit 1));

-- Contratante demonstração
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, demonstracao)
values ('a7470000-0000-4000-8000-000000000004', 'contratante', 'Contratante Demo NS', '+5561974700004', 'demo_c_ns@test.invalid', '1986-01-01', '1.0', now(), true);

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('a7470000-0000-4000-8000-000000000024', 'Bar Demo North Star', '74700000000104', 'food_service', 'Endereço Demo NS', 'POINT(-47.8869 -15.7620)'::extensions.geography);

insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
values ('a7470000-0000-4000-8000-000000000004', 'a7470000-0000-4000-8000-000000000024', 'administrador');

-- Profissional Equipe Frila
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('a7470000-0000-4000-8000-000000000005', 'profissional', 'Profissional Equipe NS', '+5561974700005', 'equipe_prof_ns@test.invalid', '1990-01-01', '1.0', now());

insert into privado.conta_equipe (usuario_id)
values ('a7470000-0000-4000-8000-000000000005');

insert into public.profissional (id, usuario_id, ponto_base)
values ('a7470000-0000-4000-8000-000000000015', 'a7470000-0000-4000-8000-000000000005', 'POINT(-47.8869 -15.7620)'::extensions.geography);

insert into public.profissional_funcao (profissional_id, funcao_id)
values ('a7470000-0000-4000-8000-000000000015', (select id from public.funcao limit 1));

-- ── Caso 1: Posição cumprida + Turno verificado (deve contar) ─────────────────
-- Semana 2026-11-09 (segunda-feira). Turno na terça-feira 10/11/2026 das 10h às 14h.
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em,
  chave_cliente, publicado_por
) values (
  'a7470000-0000-4000-8000-000000000031', 'a7470000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
  '2026-11-10 10:00:00-03', '2026-11-10 14:00:00-03',
  'Local NS', 'POINT(-47.8869 -15.7620)'::extensions.geography,
  15000, 1, false, false, false, 'Gerente NS', 'urgencia', 'publicada',
  '2026-11-01 10:00:00-03', gen_random_uuid(), 'a7470000-0000-4000-8000-000000000001'
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values ('a7470000-0000-4000-8000-000000000041', 'a7470000-0000-4000-8000-000000000031',
        'cumprida', 'a7470000-0000-4000-8000-000000000012', '2026-11-01 12:00:00-03',
        '2026-11-10 10:00:00-03', '2026-11-10 14:00:00-03');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('a7470000-0000-4000-8000-000000000051', 'a7470000-0000-4000-8000-000000000041',
        '2026-11-10 10:05:00-03', 'geolocalizado', 50, 'verificado', 15000);

select is(
  (select turnos_concluidos_com_presenca_verificada
     from metrica.north_star_semanal
    where semana_inicio = '2026-11-09'::date),
  1::bigint,
  'caso 1: posição cumprida com turno verificado é contabilizada na semana'
);

-- ── Caso 2: Posição cumprida + Turno nao_verificado (NÃO deve contar) ──────────
-- Turno na quarta-feira 11/11/2026 das 10h às 14h. Manual sem confirmação.
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em,
  chave_cliente, publicado_por
) values (
  'a7470000-0000-4000-8000-000000000032', 'a7470000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
  '2026-11-11 10:00:00-03', '2026-11-11 14:00:00-03',
  'Local NS', 'POINT(-47.8869 -15.7620)'::extensions.geography,
  15000, 1, false, false, false, 'Gerente NS', 'urgencia', 'publicada',
  '2026-11-01 10:00:00-03', gen_random_uuid(), 'a7470000-0000-4000-8000-000000000001'
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values ('a7470000-0000-4000-8000-000000000042', 'a7470000-0000-4000-8000-000000000032',
        'cumprida', 'a7470000-0000-4000-8000-000000000012', '2026-11-01 12:00:00-03',
        '2026-11-11 10:00:00-03', '2026-11-11 14:00:00-03');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_confirmado_em, verificacao, valor_acordado_centavos)
values ('a7470000-0000-4000-8000-000000000052', 'a7470000-0000-4000-8000-000000000042',
        '2026-11-11 10:10:00-03', 'manual', null, 'nao_verificado', 15000);

select is(
  (select turnos_concluidos_com_presenca_verificada
     from metrica.north_star_semanal
    where semana_inicio = '2026-11-09'::date),
  1::bigint,
  'caso 2: posição cumprida com turno nao_verificado NÃO incrementa a North Star'
);

-- ── Caso 3: Posição cancelada (NÃO deve contar) ───────────────────────────────
-- Turno na quinta-feira 12/11/2026 das 10h às 14h. Posição cancelada.
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em,
  chave_cliente, publicado_por
) values (
  'a7470000-0000-4000-8000-000000000033', 'a7470000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
  '2026-11-12 10:00:00-03', '2026-11-12 14:00:00-03',
  'Local NS', 'POINT(-47.8869 -15.7620)'::extensions.geography,
  15000, 1, false, false, false, 'Gerente NS', 'urgencia', 'publicada',
  '2026-11-01 10:00:00-03', gen_random_uuid(), 'a7470000-0000-4000-8000-000000000001'
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em, falta)
values ('a7470000-0000-4000-8000-000000000043', 'a7470000-0000-4000-8000-000000000033',
        'cancelada', 'a7470000-0000-4000-8000-000000000012', '2026-11-01 12:00:00-03',
        '2026-11-12 10:00:00-03', '2026-11-12 14:00:00-03', false);

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_confirmado_em, verificacao, valor_acordado_centavos)
values ('a7470000-0000-4000-8000-000000000053', 'a7470000-0000-4000-8000-000000000043',
        null, null, null, 'nao_verificado', 15000);

select is(
  (select turnos_concluidos_com_presenca_verificada
     from metrica.north_star_semanal
    where semana_inicio = '2026-11-09'::date),
  1::bigint,
  'caso 3: posição cancelada NÃO incrementa a North Star'
);

-- ── Caso 4a: Profissional de demonstração (NÃO deve contar) ───────────────────
-- Turno na sexta-feira 13/11/2026 das 10h às 14h.
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em,
  chave_cliente, publicado_por
) values (
  'a7470000-0000-4000-8000-000000000034', 'a7470000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
  '2026-11-13 10:00:00-03', '2026-11-13 14:00:00-03',
  'Local NS', 'POINT(-47.8869 -15.7620)'::extensions.geography,
  15000, 1, false, false, false, 'Gerente NS', 'urgencia', 'publicada',
  '2026-11-01 10:00:00-03', gen_random_uuid(), 'a7470000-0000-4000-8000-000000000001'
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values ('a7470000-0000-4000-8000-000000000044', 'a7470000-0000-4000-8000-000000000034',
        'cumprida', 'a7470000-0000-4000-8000-000000000013', '2026-11-01 12:00:00-03',
        '2026-11-13 10:00:00-03', '2026-11-13 14:00:00-03');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('a7470000-0000-4000-8000-000000000054', 'a7470000-0000-4000-8000-000000000044',
        '2026-11-13 10:05:00-03', 'geolocalizado', 50, 'verificado', 15000);

select is(
  (select turnos_concluidos_com_presenca_verificada
     from metrica.north_star_semanal
    where semana_inicio = '2026-11-09'::date),
  1::bigint,
  'caso 4a: profissional de demonstração NÃO incrementa a North Star'
);

-- ── Caso 4b: Contratante de demonstração (NÃO deve contar) ───────────────────
-- Turno no sábado 14/11/2026 das 10h às 14h em vaga de contratante demo.
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em,
  chave_cliente, publicado_por
) values (
  'a7470000-0000-4000-8000-000000000037', 'a7470000-0000-4000-8000-000000000024', (select id from public.funcao limit 1),
  '2026-11-14 10:00:00-03', '2026-11-14 14:00:00-03',
  'Local Demo NS', 'POINT(-47.8869 -15.7620)'::extensions.geography,
  15000, 1, false, false, false, 'Gerente Demo NS', 'urgencia', 'publicada',
  '2026-11-01 10:00:00-03', gen_random_uuid(), 'a7470000-0000-4000-8000-000000000004'
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values ('a7470000-0000-4000-8000-000000000045', 'a7470000-0000-4000-8000-000000000037',
        'cumprida', 'a7470000-0000-4000-8000-000000000012', '2026-11-01 12:00:00-03',
        '2026-11-14 10:00:00-03', '2026-11-14 14:00:00-03');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('a7470000-0000-4000-8000-000000000055', 'a7470000-0000-4000-8000-000000000045',
        '2026-11-14 10:05:00-03', 'geolocalizado', 50, 'verificado', 15000);

select is(
  (select turnos_concluidos_com_presenca_verificada
     from metrica.north_star_semanal
    where semana_inicio = '2026-11-09'::date),
  1::bigint,
  'caso 4b: contratante de demonstração NÃO incrementa a North Star'
);

-- ── Caso 4c: Membro da Equipe Frila (NÃO deve contar) ─────────────────────────
-- Turno no sábado 14/11/2026 das 15h às 19h com profissional da equipe.
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em,
  chave_cliente, publicado_por
) values (
  'a7470000-0000-4000-8000-000000000038', 'a7470000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
  '2026-11-14 15:00:00-03', '2026-11-14 19:00:00-03',
  'Local NS', 'POINT(-47.8869 -15.7620)'::extensions.geography,
  15000, 1, false, false, false, 'Gerente NS', 'urgencia', 'publicada',
  '2026-11-01 10:00:00-03', gen_random_uuid(), 'a7470000-0000-4000-8000-000000000001'
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values ('a7470000-0000-4000-8000-000000000046', 'a7470000-0000-4000-8000-000000000038',
        'cumprida', 'a7470000-0000-4000-8000-000000000015', '2026-11-01 12:00:00-03',
        '2026-11-14 15:00:00-03', '2026-11-14 19:00:00-03');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('a7470000-0000-4000-8000-000000000056', 'a7470000-0000-4000-8000-000000000046',
        '2026-11-14 15:05:00-03', 'geolocalizado', 50, 'verificado', 15000);

select is(
  (select turnos_concluidos_com_presenca_verificada
     from metrica.north_star_semanal
    where semana_inicio = '2026-11-09'::date),
  1::bigint,
  'caso 4c: profissional membro da equipe Frila NÃO incrementa a North Star'
);

-- ── Caso 5a: Fuso de Brasília - Turno termina Domingo 23h30 BRT ───────────────
-- 15/11/2026 é Domingo. Às 23:30 BRT equivale a 16/11/2026 02:30 UTC (Segunda-feira).
-- No fuso de Brasília (America/Sao_Paulo), pertence à semana de Domingo (início 09/11/2026).
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em,
  chave_cliente, publicado_por
) values (
  'a7470000-0000-4000-8000-000000000035', 'a7470000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
  '2026-11-15 18:00:00-03', '2026-11-15 23:30:00-03',
  'Local Domingo', 'POINT(-47.8869 -15.7620)'::extensions.geography,
  15000, 1, false, false, false, 'Gerente Domingo', 'urgencia', 'publicada',
  '2026-11-01 10:00:00-03', gen_random_uuid(), 'a7470000-0000-4000-8000-000000000001'
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values ('a7470000-0000-4000-8000-000000000047', 'a7470000-0000-4000-8000-000000000035',
        'cumprida', 'a7470000-0000-4000-8000-000000000016', '2026-11-01 12:00:00-03',
        '2026-11-15 18:00:00-03', '2026-11-15 23:30:00-03');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('a7470000-0000-4000-8000-000000000057', 'a7470000-0000-4000-8000-000000000047',
        '2026-11-15 18:05:00-03', 'geolocalizado', 50, 'verificado', 15000);

select is(
  (select turnos_concluidos_com_presenca_verificada
     from metrica.north_star_semanal
    where semana_inicio = '2026-11-09'::date),
  2::bigint,
  'caso 5a: turno que termina domingo 23h30 BRT cai na semana de domingo (início 2026-11-09)'
);

select ok(
  not exists (
    select 1 from metrica.north_star_semanal where semana_inicio = '2026-11-16'::date
  ),
  'caso 5a: turno domingo 23h30 BRT NÃO cai na semana seguinte (2026-11-16)'
);

-- ── Caso 5b: Fuso de Brasília - Turno termina Segunda 00h30 BRT ───────────────
-- 16/11/2026 00:30 BRT já pertence à semana seguinte (início 16/11/2026).
insert into public.vaga (
  id, estabelecimento_id, funcao_id, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
  exige_material_proprio, responsavel_local, modo, estado, publicado_em,
  chave_cliente, publicado_por
) values (
  'a7470000-0000-4000-8000-000000000036', 'a7470000-0000-4000-8000-000000000021', (select id from public.funcao limit 1),
  '2026-11-15 20:00:00-03', '2026-11-16 00:30:00-03',
  'Local Segunda', 'POINT(-47.8869 -15.7620)'::extensions.geography,
  15000, 1, false, false, false, 'Gerente Segunda', 'urgencia', 'publicada',
  '2026-11-01 10:00:00-03', gen_random_uuid(), 'a7470000-0000-4000-8000-000000000001'
);

insert into public.posicao (id, vaga_id, estado, profissional_id, confirmado_em, inicio_em, fim_em)
values ('a7470000-0000-4000-8000-000000000048', 'a7470000-0000-4000-8000-000000000036',
        'cumprida', 'a7470000-0000-4000-8000-000000000012', '2026-11-01 12:00:00-03',
        '2026-11-15 20:00:00-03', '2026-11-16 00:30:00-03');

insert into public.turno (id, posicao_id, checkin_em, checkin_tipo, checkin_distancia_m, verificacao, valor_acordado_centavos)
values ('a7470000-0000-4000-8000-000000000058', 'a7470000-0000-4000-8000-000000000048',
        '2026-11-15 20:05:00-03', 'geolocalizado', 50, 'verificado', 15000);

select is(
  (select turnos_concluidos_com_presenca_verificada
     from metrica.north_star_semanal
    where semana_inicio = '2026-11-16'::date),
  1::bigint,
  'caso 5b: turno que termina segunda 00h30 BRT cai na semana seguinte (início 2026-11-16)'
);

rollback;
