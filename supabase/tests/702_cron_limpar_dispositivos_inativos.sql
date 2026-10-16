-- 702_cron_limpar_dispositivos_inativos.sql
-- Cobertura pgTAP do job pg_cron 'limpar_dispositivos_inativos' e da função privado.limpar_dispositivos_inativos()
-- Mapeamento pg_cron: purga de tokens de push inativos há mais de 60 dias (RN25, RF06, RN15, RNF12, RNF13).
--
-- Afere:
--   1. Existência da função privado.limpar_dispositivos_inativos(), retorno integer, definer, search_path='' e privilégios mínimos;
--   2. Agendamento ativo no pg_cron às 06:17 UTC ('17 6 * * *') chamando select privado.limpar_dispositivos_inativos();
--   3. Comportamento com tabela vazia: retorna 0 sem erro;
--   4. Borda estrita de 60 dias com relógio fixo (frila.agora):
--      - 59 dias e 23 horas (59d23h): PRESERVADO;
--      - Exatamente 60 dias (60d00h): PRESERVADO (a cláusula é estrita: atualizado_em < corte);
--      - 59 dias, 23 horas e 59 minutos (59d23h59m59s): PRESERVADO;
--      - 60 dias e 1 segundo (60d00h01s): PURGADO;
--      - 60 dias e 1 hora (60d01h): PURGADO;
--      - Token recente (5 dias): PRESERVADO;
--      - Token muito antigo (120 dias): PURGADO;
--   5. Idempotência: execuções sucessivas sem passagem de tempo retornam 0;
--   6. Avanço temporal dinâmico e renovação de token pelo app:
--      - Token reenviado tem atualizado_em renovado e não é purgado ao cruzar a borda temporal.

begin;

set local timezone = 'UTC';
select plan(27);

-- ── 1. Estrutura e Controle de Acesso ──────────────────────────────────────────

select has_function(
  'privado',
  'limpar_dispositivos_inativos',
  array[]::text[],
  'privado.limpar_dispositivos_inativos() existe no schema privado'
);

select function_returns(
  'privado',
  'limpar_dispositivos_inativos',
  array[]::text[],
  'integer',
  'privado.limpar_dispositivos_inativos() retorna integer (número de dispositivos removidos)'
);

select is_definer(
  'privado',
  'limpar_dispositivos_inativos',
  array[]::text[],
  'privado.limpar_dispositivos_inativos() é SECURITY DEFINER'
);

select ok(
  (select proconfig from pg_proc p
     join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'privado' and p.proname = 'limpar_dispositivos_inativos')
  @> array['search_path=""'],
  'privado.limpar_dispositivos_inativos() opera com search_path vazio'
);

select is(
  has_function_privilege('service_role', 'privado.limpar_dispositivos_inativos()', 'execute'),
  true,
  'service_role pode executar privado.limpar_dispositivos_inativos()'
);

select is(
  has_function_privilege('authenticated', 'privado.limpar_dispositivos_inativos()', 'execute'),
  false,
  'authenticated NÃO tem permissão de execute em privado.limpar_dispositivos_inativos()'
);

select is(
  has_function_privilege('anon', 'privado.limpar_dispositivos_inativos()', 'execute'),
  false,
  'anon NÃO tem permissão de execute em privado.limpar_dispositivos_inativos()'
);

select is(
  has_function_privilege('public', 'privado.limpar_dispositivos_inativos()', 'execute'),
  false,
  'public NÃO tem permissão de execute em privado.limpar_dispositivos_inativos()'
);

select is(
  (select obj_description('privado.limpar_dispositivos_inativos()'::regprocedure, 'pg_proc') is not null),
  true,
  'privado.limpar_dispositivos_inativos() possui comment on documentando finalidade'
);

-- ── 2. Agendamento Periódico no pg_cron ────────────────────────────────────────

select is(
  (select count(*)::int from cron.job where jobname = 'limpar_dispositivos_inativos'),
  1,
  'Job limpar_dispositivos_inativos existe agendado no pg_cron'
);

select is(
  (select schedule from cron.job where jobname = 'limpar_dispositivos_inativos'),
  '17 6 * * *',
  'Job limpar_dispositivos_inativos agendado para 06:17 UTC (fora da janela quente RNF12)'
);

select is(
  (select command from cron.job where jobname = 'limpar_dispositivos_inativos'),
  'select privado.limpar_dispositivos_inativos()',
  'Job invoca exatamente select privado.limpar_dispositivos_inativos()'
);

select ok(
  (select active from cron.job where jobname = 'limpar_dispositivos_inativos'),
  'Job limpar_dispositivos_inativos está ativo no pg_cron'
);

-- ── 3. Comportamento com Tabela Vazia ──────────────────────────────────────────

-- Ambiente de teste com relógio sobreponível
insert into privado.ambiente (eh_teste) values (true);

-- Isola os dispositivos do teste removendo registros pré-existentes na transação
delete from public.dispositivo;

select is(
  privado.limpar_dispositivos_inativos(),
  0,
  'Com tabela vazia, privado.limpar_dispositivos_inativos() retorna 0 e não lança exceção'
);

-- ── 4. Borda Estrita de 60 Dias (59d23h Preservado vs 60d01h Purgado) ──────────

-- Fixa o relógio de referência em 2026-10-20 12:00:00 UTC
-- Corte exato de 60 dias atrás: 2026-08-21 12:00:00 UTC
select set_config('frila.agora', '2026-10-20 12:00:00+00', true);

-- Cria duas contas reais de usuário para vincular os dispositivos
insert into public.usuario (id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em)
values
  ('70200000-0000-4000-8000-000000000001', 'profissional', 'Conta Push A', '+5561970200001', 'push_a@teste.frila', '1990-01-01', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00'),
  ('70200000-0000-4000-8000-000000000002', 'profissional', 'Conta Push B', '+5561970200002', 'push_b@teste.frila', '1992-06-15', 'ativa', '2026-09-22', '2026-09-22 12:00:00+00')
on conflict (id) do nothing;

-- Inserção de 7 dispositivos nos pontos estratégicos de borda:
-- D1: 59 dias e 23 horas atrás (2026-08-21 13:00:00 UTC) -> DEVE PRESERVAR
-- D2: Exatamente 60 dias atrás  (2026-08-21 12:00:00 UTC) -> DEVE PRESERVAR (< estrito)
-- D3: 60 dias e 1 hora atrás   (2026-08-21 11:00:00 UTC) -> DEVE PURGAR
-- D4: 60 dias e 1 segundo atrás(2026-08-21 11:59:59 UTC) -> DEVE PURGAR
-- D5: 59d 23h 59m 59s atrás    (2026-08-21 12:00:01 UTC) -> DEVE PRESERVAR
-- D6: Recente (5 dias atrás)    (2026-10-15 12:00:00 UTC) -> DEVE PRESERVAR
-- D7: Muito antigo (120 dias)  (2026-06-22 12:00:00 UTC) -> DEVE PURGAR

insert into public.dispositivo (usuario_id, token_fcm, plataforma, atualizado_em)
values
  ('70200000-0000-4000-8000-000000000001', 'fcm_tok_59d23h_000000000001', 'ios',     '2026-08-21 13:00:00+00'),
  ('70200000-0000-4000-8000-000000000001', 'fcm_tok_60d00h_000000000002', 'ios',     '2026-08-21 12:00:00+00'),
  ('70200000-0000-4000-8000-000000000001', 'fcm_tok_60d01h_000000000003', 'ios',     '2026-08-21 11:00:00+00'),
  ('70200000-0000-4000-8000-000000000002', 'fcm_tok_60d01s_000000000004', 'android', '2026-08-21 11:59:59+00'),
  ('70200000-0000-4000-8000-000000000002', 'fcm_tok_59d24s_000000000005', 'android', '2026-08-21 12:00:01+00'),
  ('70200000-0000-4000-8000-000000000002', 'fcm_tok_05d00h_000000000006', 'android', '2026-10-15 12:00:00+00'),
  ('70200000-0000-4000-8000-000000000002', 'fcm_tok_120d0h_000000000007', 'android', '2026-06-22 12:00:00+00');

select is(
  privado.limpar_dispositivos_inativos(),
  3,
  'privado.limpar_dispositivos_inativos() remove exatamente os 3 tokens além do limite de 60 dias (D3, D4, D7)'
);

select is(
  (select count(*)::int from public.dispositivo
    where token_fcm in ('fcm_tok_60d01h_000000000003', 'fcm_tok_60d01s_000000000004', 'fcm_tok_120d0h_000000000007')),
  0,
  'Tokens com mais de 60 dias de inatividade foram purgados da tabela public.dispositivo'
);

select is(
  (select count(*)::int from public.dispositivo
    where token_fcm in ('fcm_tok_59d23h_000000000001', 'fcm_tok_60d00h_000000000002', 'fcm_tok_59d24s_000000000005', 'fcm_tok_05d00h_000000000006')),
  4,
  'Tokens com 60 dias ou menos continuam íntegros no banco'
);

select is(
  (select count(*)::int from public.dispositivo where token_fcm = 'fcm_tok_59d23h_000000000001'),
  1,
  'Token de 59 dias e 23 horas (59d23h) é preservado'
);

select is(
  (select count(*)::int from public.dispositivo where token_fcm = 'fcm_tok_60d00h_000000000002'),
  1,
  'Token com exatamente 60 dias (60d00h) é preservado (borda estrita: não é mais de 60 dias)'
);

select is(
  (select count(*)::int from public.dispositivo where token_fcm = 'fcm_tok_60d01h_000000000003'),
  0,
  'Token com 60 dias e 1 hora (60d01h) foi purgado do banco'
);

select is(
  (select count(*)::int from public.dispositivo where token_fcm = 'fcm_tok_59d24s_000000000005'),
  1,
  'Token de 59 dias, 23 horas e 59 minutos (59d23h59m59s) é preservado'
);


-- ── 5. Idempotência ────────────────────────────────────────────────────────────

select is(
  privado.limpar_dispositivos_inativos(),
  0,
  'Execução subsequente imediata retorna 0 (idempotência confirmada)'
);

select is(
  (select count(*)::int from public.dispositivo),
  4,
  'Total de dispositivos na tabela permanece 4 após execução idempotente'
);

-- ── 6. Avanço Temporal Dinâmico e Renovação de Token ────────────────────────────

-- O app abre e renova o token D1 (59d23h) para a data corrente
update public.dispositivo
   set atualizado_em = '2026-10-20 13:30:00+00'
 where token_fcm = 'fcm_tok_59d23h_000000000001';

-- Avança o relógio em 2 horas: 2026-10-20 14:00:00 UTC
-- Novo corte de 60 dias: 2026-08-21 14:00:00 UTC
-- Dispositivos D2 (12:00:00) e D5 (12:00:01) agora ultrapassam a marca de 60 dias e devem sair.
-- D1 (renovado às 13:30) e D6 (recente de 5 dias) continuam preservados.
select set_config('frila.agora', '2026-10-20 14:00:00+00', true);

select is(
  privado.limpar_dispositivos_inativos(),
  2,
  'Após 2 horas, D2 e D5 cruzam os 60 dias e saem (2 removidos); D1 renovado e D6 recente continuam'
);

select is(
  (select count(*)::int from public.dispositivo where token_fcm = 'fcm_tok_59d23h_000000000001'),
  1,
  'Token D1 que foi renovado pelo app não foi purgado'
);

select is(
  (select count(*)::int from public.dispositivo where token_fcm = 'fcm_tok_05d00h_000000000006'),
  1,
  'Token D6 recente continua preservado'
);

select is(
  (select count(*)::int from public.dispositivo),
  2,
  'Restam apenas os 2 dispositivos válidos na tabela public.dispositivo'
);

select * from finish();
rollback;
