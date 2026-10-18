-- Falha de transporte no despacho imediato registra em privado.falha_execucao (Achado 3 da AUDITORIA-CRON.md).
--
-- Quando net.http_post falha (ex: timeout de rede, URL inacessível, erro de transporte):
--   1. A falha NÃO deve gravar ocorrência do tipo 'revisao_despacho' em public.ocorrencia contra o contratante.
--   2. A falha DEVE ser registrada em privado.falha_execucao com origem='despacho_imediato' e codigo='falha_transporte_pg_net'.
--   3. A mensagem deve permanecer íntegra na fila pgmq.q_despacho para repetição pelo pg_cron.

begin;

select plan(6);

set local frila.agendador_secret = 'segredo-de-teste';
-- URL inválida que força net.http_post a falhar/lançar exceção
set local frila.edge_function_url = 'http://[invalid-url-force-error';

-- Cria usuário contratante, estabelecimento e vaga para provar que a falha de transporte
-- NÃO imputa ocorrência de revisao_despacho ao autor da vaga (Achado 3 da AUDITORIA-CRON.md).
insert into auth.users (instance_id, id, aud, role, email, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                        is_sso_user, is_anonymous)
values ('00000000-0000-0000-0000-000000000000', 'c0000000-0000-4000-8000-000000000099',
        'authenticated', 'authenticated', 'contratante_739@teste.com', now(),
        '{"provider":"email"}'::jsonb, '{}'::jsonb, now(), now(), false, false)
on conflict do nothing;

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em)
values ('c0000000-0000-4000-8000-000000000099', 'contratante', 'Contratante 739', '+5561999990739',
        'contratante_739@teste.com', '1990-01-01'::date, '2026-09-22', now())
on conflict do nothing;

insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values ('e0000000-0000-4000-8000-000000000099', 'Est 739', '12345678000199', 'food_service',
        'Rua Teste', st_setsrid(st_makepoint(-47.88, -15.79), 4326))
on conflict do nothing;

insert into public.membro_estabelecimento (estabelecimento_id, usuario_id, papel)
values ('e0000000-0000-4000-8000-000000000099', 'c0000000-0000-4000-8000-000000000099', 'administrador')
on conflict do nothing;

insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por,
  inicio_em, fim_em, local, ponto, valor_centavos, posicoes,
  inclui_refeicao, inclui_transporte, exige_material_proprio, responsavel_local,
  modo, alerta_antecedencia, estado, publicado_em, chave_cliente
) values (
  'a0000000-0000-4000-8000-000000000099',
  'e0000000-0000-4000-8000-000000000099',
  (select id from public.funcao limit 1),
  'c0000000-0000-4000-8000-000000000099',
  now() + interval '2 hours',
  now() + interval '6 hours',
  'Local 739',
  st_setsrid(st_makepoint(-47.88, -15.79), 4326),
  15000,
  1,
  false, false, false, 'Chefe',
  'urgencia', '03:00:00'::interval, 'publicada', now(), gen_random_uuid()
) on conflict do nothing;

-- Dispara o despacho com vaga_id literal explícito
select lives_ok(
  $$ select privado.disparar_despacho('a0000000-0000-4000-8000-000000000099'::uuid) $$,
  'privado.disparar_despacho captura falha de transporte no exception when others sem abortar transação'
);

-- Asserção 1: NÃO deve ter inserido nada em public.ocorrencia contra o autor desta vaga
select is(
  (select count(*)::int from public.ocorrencia
    where tipo = 'revisao_despacho'
      and (usuario_id = 'c0000000-0000-4000-8000-000000000099'
           or autor_id = 'c0000000-0000-4000-8000-000000000099'
           or motivo like '%a0000000-0000-4000-8000-000000000099%'
           or resultado like '%a0000000-0000-4000-8000-000000000099%')),
  0,
  'falha de transporte do pg_net NÃO gera ocorrência de revisao_despacho contra o autor da vaga'
);

-- Asserção 2: DEVE ter registrado em privado.falha_execucao
select is(
  (select count(*)::int from privado.falha_execucao
    where origem = 'despacho_imediato' and codigo = 'falha_transporte_pg_net'),
  1,
  'falha de transporte é registrada em privado.falha_execucao'
);

-- Asserção 3: Detalhes preservam a vaga_id literal passada
select is(
  (select count(*)::int from privado.falha_execucao
    where origem = 'despacho_imediato'
      and codigo = 'falha_transporte_pg_net'
      and detalhes = jsonb_build_object('vaga_id', 'a0000000-0000-4000-8000-000000000099')),
  1,
  'detalhes da falha_execucao preservam a vaga_id literal para observabilidade'
);

-- Asserção 4: Se chamada sem vaga_id, também grava sem falhar
select lives_ok(
  $$ select privado.disparar_despacho(null) $$,
  'disparar_despacho(null) sob erro de transporte também grava em falha_execucao com detalhes nulos'
);

-- Asserção 5: Detalhes da segunda chamada são nulos
select is(
  (select count(*)::int from privado.falha_execucao
    where origem = 'despacho_imediato'
      and codigo = 'falha_transporte_pg_net'
      and detalhes is null),
  1,
  'detalhes são nulos quando disparar_despacho é invocado sem vaga_id'
);

select * from finish();
rollback;
