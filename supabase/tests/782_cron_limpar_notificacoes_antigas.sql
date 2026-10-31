-- 782_cron_limpar_notificacoes_antigas.sql
-- Cobertura pgTAP do job pg_cron 'limpar_notificacoes_antigas' e da função privado.limpar_notificacoes_antigas()
-- Mapeamento pg_cron: purga de notificações com mais de 60 dias (K-001, LGPD art. 37, RN23, RF25).
--
-- Afere:
--   1. Existência da função privado.limpar_notificacoes_antigas(), retorno integer, definer, search_path='' e privilégios mínimos;
--   2. Agendamento ativo no pg_cron às 06:19 UTC ('19 6 * * *') chamando select privado.limpar_notificacoes_antigas();
--   3. Comportamento com tabela vazia: retorna 0 sem erro;
--   4. Borda estrita de 60 dias com relógio fixo (frila.agora):
--      - 59 dias e 23 horas (59d23h): PRESERVADO;
--      - Exatamente 60 dias (60d00h): PRESERVADO (a cláusula é estrita: enviada_em < corte);
--      - 59 dias, 23 horas e 59 minutos (59d23h59m59s): PRESERVADO;
--      - 60 dias e 1 segundo (60d00h01s): PURGADO;
--      - 60 dias e 1 hora (60d01h): PURGADO;
--      - Notificação recente (5 dias): PRESERVADA;
--      - Notificação muito antiga (120 dias): PURGADA;
--   5. Idempotência: execuções sucessivas sem passagem de tempo retornam 0;
--   6. Desvinculação de despacho: notificação associada a despacho_notificacao_id é purgada e
--      despacho.notificacao_id passa a null sem violar integridade nem gatilho despacho_imutavel.

begin;

set local timezone = 'UTC';
select plan(29);

-- ── 1. Estrutura e Controle de Acesso ──────────────────────────────────────────

select has_function(
  'privado',
  'limpar_notificacoes_antigas',
  array['integer']::text[],
  'privado.limpar_notificacoes_antigas(integer) existe no schema privado'
);

select function_returns(
  'privado',
  'limpar_notificacoes_antigas',
  array['integer']::text[],
  'integer',
  'privado.limpar_notificacoes_antigas() retorna integer (número de notificações removidas)'
);

select is_definer(
  'privado',
  'limpar_notificacoes_antigas',
  array['integer']::text[],
  'privado.limpar_notificacoes_antigas() é SECURITY DEFINER'
);

select ok(
  (select proconfig from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'limpar_notificacoes_antigas')
  @> array['search_path=""'],
  'privado.limpar_notificacoes_antigas() opera com search_path vazio'
);

select is(
  has_function_privilege('service_role', 'privado.limpar_notificacoes_antigas(integer)', 'execute'),
  true,
  'service_role pode executar privado.limpar_notificacoes_antigas()'
);

select is(
  has_function_privilege('authenticated', 'privado.limpar_notificacoes_antigas(integer)', 'execute'),
  false,
  'authenticated NÃO tem permissão de execute em privado.limpar_notificacoes_antigas()'
);

select is(
  has_function_privilege('anon', 'privado.limpar_notificacoes_antigas(integer)', 'execute'),
  false,
  'anon NÃO tem permissão de execute em privado.limpar_notificacoes_antigas()'
);

select is(
  has_function_privilege('public', 'privado.limpar_notificacoes_antigas(integer)', 'execute'),
  false,
  'public NÃO tem permissão de execute em privado.limpar_notificacoes_antigas()'
);

select is(
  (select obj_description('privado.limpar_notificacoes_antigas(integer)'::regprocedure, 'pg_proc') is not null),
  true,
  'privado.limpar_notificacoes_antigas() possui comment on documentando finalidade'
);

-- ── 2. Agendamento Periódico no pg_cron ────────────────────────────────────────

select is(
  (select count(*)::int from cron.job where jobname = 'limpar_notificacoes_antigas'),
  1,
  'Job limpar_notificacoes_antigas existe agendado no pg_cron'
);

select is(
  (select schedule from cron.job where jobname = 'limpar_notificacoes_antigas'),
  '19 6 * * *',
  'Job limpar_notificacoes_antigas agendado para 06:19 UTC (fora da janela quente RNF12)'
);

select is(
  (select command from cron.job where jobname = 'limpar_notificacoes_antigas'),
  'select privado.limpar_notificacoes_antigas()',
  'Job invoca exatamente select privado.limpar_notificacoes_antigas()'
);

select ok(
  (select active from cron.job where jobname = 'limpar_notificacoes_antigas'),
  'Job limpar_notificacoes_antigas está ativo no pg_cron'
);

-- ── 3. Comportamento com Tabela Vazia ──────────────────────────────────────────

insert into privado.ambiente (eh_teste) values (true);

-- Permite deleção prévia para isolamento na transação de teste
set local "privado.retencao" = 'on';
delete from public.despacho;
delete from public.notificacao;
set local "privado.retencao" = 'off';

select is(
  privado.limpar_notificacoes_antigas(),
  0,
  'Com tabela vazia, privado.limpar_notificacoes_antigas() retorna 0 e não lança exceção'
);

-- ── 4. Borda Estrita de 60 Dias ────────────────────────────────────────────────

-- Fixa o relógio de referência em 2026-10-31 12:00:00 UTC
-- Corte exato de 60 dias atrás: 2026-09-01 12:00:00 UTC
select set_config('frila.agora', '2026-10-31 12:00:00+00', true);

insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values
  ('78200000-0000-4000-8000-000000000001', 'profissional', 'Conta Notif A', '+5561978200001', 'notif_a@teste.frila', '1990-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('78200000-0000-4000-8000-000000000002', 'profissional', 'Conta Notif B', '+5561978200002', 'notif_b@teste.frila', '1992-06-15', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00')
on conflict (id) do nothing;

-- Inserção de 7 notificações nos pontos estratégicos de borda:
-- N1: 59 dias e 23 horas atrás (2026-09-01 13:00:00 UTC) -> DEVE PRESERVAR
-- N2: Exatamente 60 dias atrás  (2026-09-01 12:00:00 UTC) -> DEVE PRESERVAR (< estrito)
-- N3: 60 dias e 1 hora atrás   (2026-09-01 11:00:00 UTC) -> DEVE PURGAR
-- N4: 60 dias e 1 segundo atrás(2026-09-01 11:59:59 UTC) -> DEVE PURGAR
-- N5: 59d 23h 59m 59s atrás    (2026-09-01 12:00:01 UTC) -> DEVE PRESERVAR
-- N6: Recente (5 dias atrás)    (2026-10-26 12:00:00 UTC) -> DEVE PRESERVAR
-- N7: Muito antiga (120 dias)  (2026-07-03 12:00:00 UTC) -> DEVE PURGAR

insert into public.notificacao (id, usuario_id, tipo, referencia_id, payload, enviada_em)
values
  ('78200000-0000-4000-8000-000000000011', '78200000-0000-4000-8000-000000000001', 'lembrete_24h', gen_random_uuid(), '{"n": 1}'::jsonb, '2026-09-01 13:00:00+00'),
  ('78200000-0000-4000-8000-000000000012', '78200000-0000-4000-8000-000000000001', 'lembrete_24h', gen_random_uuid(), '{"n": 2}'::jsonb, '2026-09-01 12:00:00+00'),
  ('78200000-0000-4000-8000-000000000013', '78200000-0000-4000-8000-000000000001', 'lembrete_24h', gen_random_uuid(), '{"n": 3}'::jsonb, '2026-09-01 11:00:00+00'),
  ('78200000-0000-4000-8000-000000000014', '78200000-0000-4000-8000-000000000002', 'lembrete_24h', gen_random_uuid(), '{"n": 4}'::jsonb, '2026-09-01 11:59:59+00'),
  ('78200000-0000-4000-8000-000000000015', '78200000-0000-4000-8000-000000000002', 'lembrete_24h', gen_random_uuid(), '{"n": 5}'::jsonb, '2026-09-01 12:00:01+00'),
  ('78200000-0000-4000-8000-000000000016', '78200000-0000-4000-8000-000000000002', 'lembrete_24h', gen_random_uuid(), '{"n": 6}'::jsonb, '2026-10-26 12:00:00+00'),
  ('78200000-0000-4000-8000-000000000017', '78200000-0000-4000-8000-000000000002', 'lembrete_24h', gen_random_uuid(), '{"n": 7}'::jsonb, '2026-07-03 12:00:00+00');

select is(
  privado.limpar_notificacoes_antigas(),
  3,
  'privado.limpar_notificacoes_antigas() remove exatamente as 3 notificações além de 60 dias (N3, N4, N7)'
);

select is(
  (select count(*)::int from public.notificacao
    where id in ('78200000-0000-4000-8000-000000000013', '78200000-0000-4000-8000-000000000014', '78200000-0000-4000-8000-000000000017')),
  0,
  'Notificações com mais de 60 dias foram purgadas da tabela public.notificacao'
);

select is(
  (select count(*)::int from public.notificacao
    where id in ('78200000-0000-4000-8000-000000000011', '78200000-0000-4000-8000-000000000012', '78200000-0000-4000-8000-000000000015', '78200000-0000-4000-8000-000000000016')),
  4,
  'Notificações com 60 dias ou menos continuam íntegras no banco'
);

select is(
  (select count(*)::int from public.notificacao where id = '78200000-0000-4000-8000-000000000011'),
  1,
  'Notificação de 59 dias e 23 horas (59d23h) é preservada'
);

select is(
  (select count(*)::int from public.notificacao where id = '78200000-0000-4000-8000-000000000012'),
  1,
  'Notificação de exatamente 60 dias (60d00h) é preservada (< estrito)'
);

select is(
  (select count(*)::int from public.notificacao where id = '78200000-0000-4000-8000-000000000013'),
  0,
  'Notificação de 60 dias e 1 hora (60d01h) foi purgada'
);

select is(
  (select count(*)::int from public.notificacao where id = '78200000-0000-4000-8000-000000000015'),
  1,
  'Notificação de 59 dias, 23 horas e 59 minutos (59d23h59m59s) é preservada'
);

select is(
  privado.limpar_notificacoes_antigas(),
  0,
  'Idempotência: segunda execução consecutiva no mesmo instante retorna 0'
);

-- ── 5. Desvinculação e Integridade com Despacho (RF25, RN23) ──────────────────

-- Cria estabelecimento, vaga e profissional para montar vínculo de despacho
insert into public.estabelecimento (id, nome, documento, tipo, endereco, ponto)
values (
  '78200000-0000-4000-8000-000000000020',
  'Bar Teste 782',
  '12345678000199',
  'food_service',
  'Rua 782, 1',
  extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography
) on conflict (id) do nothing;

insert into public.funcao (id, nome, categoria)
values ('78200000-0000-4000-8000-000000000030', 'Garçom 782', 'sala')
on conflict (id) do nothing;

insert into public.profissional (id, usuario_id, ponto_base)
values (
  '78200000-0000-4000-8000-000000000040',
  '78200000-0000-4000-8000-000000000001',
  extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography
) on conflict (id) do nothing;

insert into public.vaga (
  id, estabelecimento_id, funcao_id, publicado_por, inicio_em, fim_em, local, ponto,
  valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
  responsavel_local, modo, estado, chave_cliente
) values (
  '78200000-0000-4000-8000-000000000050',
  '78200000-0000-4000-8000-000000000020',
  '78200000-0000-4000-8000-000000000030',
  '78200000-0000-4000-8000-000000000001',
  '2026-11-15 18:00:00+00',
  '2026-11-15 23:00:00+00',
  'Local 782',
  extensions.st_setsrid(extensions.st_makepoint(-47.9, -15.8), 4326)::extensions.geography,
  15000, 1, false, false, false, 'Gerente 782', 'urgencia', 'publicada', gen_random_uuid()
) on conflict (id) do nothing;

-- Notificação vinculada a despacho com mais de 60 dias (70 dias atrás: 2026-08-22)
insert into public.notificacao (id, usuario_id, profissional_id, tipo, referencia_id, payload, enviada_em)
values (
  '78200000-0000-4000-8000-000000000099',
  '78200000-0000-4000-8000-000000000001',
  '78200000-0000-4000-8000-000000000040',
  'vaga',
  '78200000-0000-4000-8000-000000000050',
  '{"vaga_id": "78200000-0000-4000-8000-000000000050"}'::jsonb,
  '2026-08-22 12:00:00+00'
);

insert into public.despacho (id, vaga_id, profissional_id, notificacao_id, criado_em)
values (
  '78200000-0000-4000-8000-000000000088',
  '78200000-0000-4000-8000-000000000050',
  '78200000-0000-4000-8000-000000000040',
  '78200000-0000-4000-8000-000000000099',
  '2026-08-22 12:00:00+00'
);

-- Executa a purga
select is(
  privado.limpar_notificacoes_antigas(),
  1,
  'Purga remove notificação com mais de 60 dias mesmo vinculada a despacho'
);

select is(
  (select count(*)::int from public.notificacao where id = '78200000-0000-4000-8000-000000000099'),
  0,
  'Notificação vinculada a despacho foi removida da tabela notificacao'
);

select is(
  (select notificacao_id from public.despacho where id = '78200000-0000-4000-8000-000000000088'),
  null,
  'Despacho associado à notificação purgada tem notificacao_id desvinculado para null com integridade preservada'
);

select ok(
  (select expurgado_em from public.despacho where id = '78200000-0000-4000-8000-000000000088') is not null,
  'Despacho expurgado tem coluna expurgado_em preenchida com timestamp de retenção (Item 4)'
);

select is(
  privado.liberar_teto_do_profissional('78200000-0000-4000-8000-000000000040'),
  null,
  'liberar_teto_do_profissional NÃO reenvia notificação de vaga futura cujo despacho foi expurgado (Item 4)'
);

select is(
  (select count(*)::int from privado.marca_notificacao where referencia_id = '78200000-0000-4000-8000-000000000050'),
  1,
  'Marca durável em privado.marca_notificacao sobrevive à purga da notificação (Item 4)'
);

select is(
  privado.notificar(
    '78200000-0000-4000-8000-000000000001',
    'vaga',
    '78200000-0000-4000-8000-000000000050',
    '{"vaga_id": "78200000-0000-4000-8000-000000000050"}'::jsonb
  ),
  null,
  'privado.notificar não recria notificação expurgada respeitando marca durável (Item 4)'
);

select * from finish();
rollback;
