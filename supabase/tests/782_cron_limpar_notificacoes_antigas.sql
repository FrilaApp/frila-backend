-- 782_cron_limpar_notificacoes_antigas.sql
-- Cobertura pgTAP do job pg_cron 'limpar_notificacoes_antigas' e da função privado.limpar_notificacoes_antigas()
-- Mapeamento pg_cron: purga de notificações com mais de 60 dias (K-001, LGPD art. 37, RN23, RF25, K-001g).
--
-- Afere:
--   1. Existência da função privado.limpar_notificacoes_antigas(), retorno integer, definer, search_path='' e privilégios mínimos;
--   2. Agendamento ativo no pg_cron às 06:19 UTC ('19 6 * * *') chamando select privado.limpar_notificacoes_antigas();
--   3. Validação da FK em transação separada (convalidated = true em pg_constraint);
--   4. Comportamento com tabela vazia: retorna 0 sem erro;
--   5. Borda estrita de 60 dias com relógio fixo (frila.agora):
--      - 59 dias e 23 horas (59d23h): PRESERVADO;
--      - Exatamente 60 dias (60d00h): PRESERVADO (a cláusula é estrita: enviada_em < corte);
--      - 59 dias, 23 horas e 59 minutos (59d23h59m59s): PRESERVADO;
--      - 60 dias e 1 segundo (60d00h01s): PURGADO;
--      - 60 dias e 1 hora (60d01h): PURGADO;
--      - Notificação recente (5 dias): PRESERVADA;
--      - Notificação muito antiga (120 dias): PURGADA;
--   6. Idempotência: execuções sucessivas sem passagem de tempo retornam 0;
--   7. Desvinculação de despacho e coluna expurgado_em (Item 4 e K-001g);
--   8. Purga em lotes por chamada/transação (Item 5 e K-001g):
--      - A purga consome no máximo p_limite por chamada;
--      - Reagenda continuação no pg_cron enquanto há backlog e des-agenda ao concluir;
--      - Purga termina em N chamadas delimitadas.

begin;

set local timezone = 'UTC';
select plan(35);

-- ── 1. Estrutura e Controle de Acesso ──────────────────────────────────────────

select has_function(
  'privado',
  'limpar_notificacoes_antigas',
  'privado.limpar_notificacoes_antigas existe no schema privado'
);

select function_returns(
  'privado',
  'limpar_notificacoes_antigas',
  'integer',
  'privado.limpar_notificacoes_antigas() retorna integer (número de notificações removidas)'
);

select is_definer(
  'privado',
  'limpar_notificacoes_antigas',
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
  has_function_privilege('service_role', 'privado.limpar_notificacoes_antigas(integer, integer)', 'execute'),
  true,
  'service_role pode executar privado.limpar_notificacoes_antigas()'
);

select is(
  has_function_privilege('authenticated', 'privado.limpar_notificacoes_antigas(integer, integer)', 'execute'),
  false,
  'authenticated NÃO tem permissão de execute em privado.limpar_notificacoes_antigas()'
);

select is(
  has_function_privilege('anon', 'privado.limpar_notificacoes_antigas(integer, integer)', 'execute'),
  false,
  'anon NÃO tem permissão de execute em privado.limpar_notificacoes_antigas()'
);

select is(
  has_function_privilege('public', 'privado.limpar_notificacoes_antigas(integer, integer)', 'execute'),
  false,
  'public NÃO tem permissão de execute em privado.limpar_notificacoes_antigas()'
);

select is(
  (select obj_description(p.oid, 'pg_proc') is not null
     from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'limpar_notificacoes_antigas'),
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
  'Job limpar_notificacoes_antigas executa select privado.limpar_notificacoes_antigas()'
);

-- ── 3. Validação da FK em transação separada (K-001g) ─────────────────────────

select is(
  (select convalidated
     from pg_constraint c
     join pg_class t on t.oid = c.conrelid
     join pg_namespace n on n.oid = t.relnamespace
    where n.nspname = 'public'
      and t.relname = 'despacho'
      and c.conname = 'despacho_notificacao_id_fkey'),
  true,
  'Chave estrangeira despacho_notificacao_id_fkey está validada (convalidated = true na migração 20261031150100)'
);

-- ── 4. Comportamento com Tabela Vazia ──────────────────────────────────────────

select is(
  privado.limpar_notificacoes_antigas(),
  0,
  'privado.limpar_notificacoes_antigas() retorna 0 quando não há notificações vencidas'
);

-- ── 5. Borda Estrita de 60 Dias (LGPD art. 37, RN23) ──────────────────────────

-- Habilita mock de tempo no ambiente de teste e fixa relógio em 2026-10-31 12:00:00 UTC
insert into privado.ambiente (id, eh_teste) values (true, true)
on conflict (id) do update set eh_teste = true;

select set_config('frila.agora', '2026-10-31 12:00:00+00', true);

-- Cria usuário teste para ser destinatário das notificações
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, termos_versao, termos_aceite_em, estado)
values (
  '78200000-0000-4000-8000-000000000001',
  'profissional',
  'Destinatario 782',
  '+5561988880782',
  'teste782@exemplo.test',
  '1995-05-10',
  '1.0',
  now(),
  'ativa'
) on conflict (id) do nothing;

-- Fixture 1: Notificação de 5 dias atrás (recente, deve permanecer)
insert into public.notificacao (id, usuario_id, tipo, referencia_id, enviada_em)
values (
  '78200000-0000-4000-8000-000000000002',
  '78200000-0000-4000-8000-000000000001',
  'inicio_sem_checkin',
  gen_random_uuid(),
  '2026-10-26 12:00:00+00'
);

-- Fixture 2: Notificação de 59 dias e 23 horas atrás (quase 60 dias, deve permanecer)
insert into public.notificacao (id, usuario_id, tipo, referencia_id, enviada_em)
values (
  '78200000-0000-4000-8000-000000000003',
  '78200000-0000-4000-8000-000000000001',
  'atraso_15min',
  gen_random_uuid(),
  '2026-09-01 13:00:00+00'
);

-- Fixture 3: Notificação exatamente no limite de 60 dias (2026-09-01 12:00:00 UTC)
-- Como a regra é estrita (< corte), o corte é 2026-09-01 12:00:00. Igualdade NÃO é menor. Deve permanecer.
insert into public.notificacao (id, usuario_id, tipo, referencia_id, enviada_em)
values (
  '78200000-0000-4000-8000-000000000004',
  '78200000-0000-4000-8000-000000000001',
  'fim_sem_checkout',
  gen_random_uuid(),
  '2026-09-01 12:00:00+00'
);

-- Fixture 4: Notificação de 59 dias, 23 horas e 59 minutos atrás (deve permanecer)
insert into public.notificacao (id, usuario_id, tipo, referencia_id, enviada_em)
values (
  '78200000-0000-4000-8000-000000000005',
  '78200000-0000-4000-8000-000000000001',
  'vaga_vazia',
  gen_random_uuid(),
  '2026-09-01 12:01:00+00'
);

-- Fixture 5: Notificação de 60 dias e 1 segundo atrás (2026-09-01 11:59:59 UTC - deve ser purgada)
insert into public.notificacao (id, usuario_id, tipo, referencia_id, enviada_em)
values (
  '78200000-0000-4000-8000-000000000006',
  '78200000-0000-4000-8000-000000000001',
  'avaliacao_disponivel',
  gen_random_uuid(),
  '2026-09-01 11:59:59+00'
);

-- Fixture 6: Notificação de 60 dias e 1 hora atrás (2026-09-01 11:00:00 UTC - deve ser purgada)
insert into public.notificacao (id, usuario_id, tipo, referencia_id, enviada_em)
values (
  '78200000-0000-4000-8000-000000000007',
  '78200000-0000-4000-8000-000000000001',
  'vaga_sem_elegiveis',
  gen_random_uuid(),
  '2026-09-01 11:00:00+00'
);

-- Fixture 7: Notificação muito antiga (120 dias atrás: 2026-07-03 12:00:00 UTC - deve ser purgada)
insert into public.notificacao (id, usuario_id, tipo, referencia_id, enviada_em)
values (
  '78200000-0000-4000-8000-000000000008',
  '78200000-0000-4000-8000-000000000001',
  'lembrete_24h',
  gen_random_uuid(),
  '2026-07-03 12:00:00+00'
);

-- Executa a purga
select is(
  privado.limpar_notificacoes_antigas(),
  3,
  'Purga remove exatamente as 3 notificações com mais de 60 dias (60d01s, 60d01h, 120d)'
);

select is(
  (select count(*)::int from public.notificacao where id in (
    '78200000-0000-4000-8000-000000000006',
    '78200000-0000-4000-8000-000000000007',
    '78200000-0000-4000-8000-000000000008'
  )),
  0,
  'Notificações vencidas foram de fato excluídas do banco'
);

select is(
  (select count(*)::int from public.notificacao where id = '78200000-0000-4000-8000-000000000002'),
  1,
  'Notificação recente (5 dias) é preservada'
);

select is(
  (select count(*)::int from public.notificacao where id = '78200000-0000-4000-8000-000000000003'),
  1,
  'Notificação de 59 dias e 23 horas é preservada'
);

select is(
  (select count(*)::int from public.notificacao where id = '78200000-0000-4000-8000-000000000004'),
  1,
  'Notificação de exatamente 60 dias (corte estrito) é preservada'
);

select is(
  (select count(*)::int from public.notificacao where id = '78200000-0000-4000-8000-000000000005'),
  1,
  'Notificação de 59 dias, 23 horas e 59 minutos (59d23h59m59s) é preservada'
);

select is(
  privado.limpar_notificacoes_antigas(),
  0,
  'Idempotência: segunda execução consecutiva no mesmo instante retorna 0'
);

-- ── 6. Desvinculação e Integridade com Despacho (RF25, RN23, K-001d) ───────────

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

-- ── 7. Purga em Lotes e Continuação Reagendada no pg_cron (K-001g) ─────────────

-- Insere 5 notificações vencidas (75 dias atrás)
insert into public.notificacao (id, usuario_id, tipo, referencia_id, enviada_em)
values
  ('78200000-0000-4000-8000-000000000071', '78200000-0000-4000-8000-000000000001', 'lembrete_3h', gen_random_uuid(), '2026-08-15 10:00:00+00'),
  ('78200000-0000-4000-8000-000000000072', '78200000-0000-4000-8000-000000000001', 'lembrete_3h', gen_random_uuid(), '2026-08-15 10:01:00+00'),
  ('78200000-0000-4000-8000-000000000073', '78200000-0000-4000-8000-000000000001', 'lembrete_3h', gen_random_uuid(), '2026-08-15 10:02:00+00'),
  ('78200000-0000-4000-8000-000000000074', '78200000-0000-4000-8000-000000000001', 'lembrete_3h', gen_random_uuid(), '2026-08-15 10:03:00+00'),
  ('78200000-0000-4000-8000-000000000075', '78200000-0000-4000-8000-000000000001', 'lembrete_3h', gen_random_uuid(), '2026-08-15 10:04:00+00');

-- Chamada 1 com p_limite = 2: deve purgar exatamente 2 notificações e agendar continuação
select is(
  privado.limpar_notificacoes_antigas(60, 2),
  2,
  'Chamada 1 purga exatamente o lote delimitado de 2 registros (K-001g)'
);

select is(
  (select count(*)::int from cron.job where jobname = 'limpar_notificacoes_antigas_continua'),
  1,
  'Continuação limpar_notificacoes_antigas_continua é agendada no pg_cron enquanto há backlog pendente (K-001g)'
);

-- Chamada 2 com p_limite = 2: purga mais 2 notificações
select is(
  privado.limpar_notificacoes_antigas(60, 2),
  2,
  'Chamada 2 purga mais um lote delimitado de 2 registros (K-001g)'
);

-- Chamada 3 com p_limite = 2: purga a última notificação restante (1) e des-agenda continuação
select is(
  privado.limpar_notificacoes_antigas(60, 2),
  1,
  'Chamada 3 purga o registro restante de 1 notificação (K-001g)'
);

select is(
  (select count(*)::int from cron.job where jobname = 'limpar_notificacoes_antigas_continua'),
  0,
  'Continuação limpar_notificacoes_antigas_continua é des-agendada ao esgotar o backlog (K-001g)'
);

-- Chamada 4: idempotente, retorna 0
select is(
  privado.limpar_notificacoes_antigas(60, 2),
  0,
  'Chamada 4 após expurgo completo retorna 0 (K-001g)'
);

select is(
  (select count(*)::int from public.notificacao where enviada_em < privado.agora() - interval '60 days'),
  0,
  'Nenhuma notificação com mais de 60 dias remanesce após N chamadas em lotes (K-001g)'
);

select * from finish();
rollback;
