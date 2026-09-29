-- S2 · Backend · Jobs que só existiam em comentário passam a ser agendados no pg_cron
--
-- Achado do ESTADO de 29/09: `fechar_turnos_passados`, `reconciliar_reputacao_diaria` e
-- `fechar-turnos-e-vagas` estavam documentados em comentário de migração, mas nenhum
-- `cron.schedule` os registrava. Turno passado não fechava, a posição não virava
-- cumprida, a avaliação não abria e o cache da taxa de comparecimento não era conferido.
--
-- O fechamento de turnos passados roda dentro de `privado.fechar_turnos_e_vagas()`,
-- antes de concluir as posições. Um job separado para ele seria a mesma função rodando
-- duas vezes no mesmo minuto, disputando as mesmas linhas, sem garantir a ordem
-- "no-show antes de cumprida". Por isso há um job só, e este teste prova as duas coisas:
-- o job existe e a função dele chama o fechamento de turnos.
begin;

select plan(11);

-- ── 1. Fechamento de turnos e vagas a cada cinco minutos ──────────────────────────
select is(
  (select count(*)::int from cron.job
    where jobname = 'fechar_turnos_e_vagas'
      and command = 'select privado.fechar_turnos_e_vagas()'),
  1,
  'Job fechar_turnos_e_vagas está agendado no pg_cron chamando privado.fechar_turnos_e_vagas()');

select is(
  (select schedule from cron.job where jobname = 'fechar_turnos_e_vagas'),
  '*/5 * * * *',
  'Job fechar_turnos_e_vagas roda a cada cinco minutos');

select ok(
  (select active from cron.job where jobname = 'fechar_turnos_e_vagas'),
  'Job fechar_turnos_e_vagas está ativo');

select ok(
  pg_get_functiondef('privado.fechar_turnos_e_vagas()'::regprocedure)
    like '%privado.fechar_turnos_passados()%',
  'privado.fechar_turnos_e_vagas() chama privado.fechar_turnos_passados(): o fechamento de turnos passados roda a cada cinco minutos');

select is(
  (select count(*)::int from cron.job
    where jobname in ('fechar_turnos_passados', 'fechar-turnos-e-vagas')),
  0,
  'Nenhum job paralelo para fechar_turnos_passados nem com o nome antigo com hífen');

-- ── 2. Reconciliação diária da reputação ─────────────────────────────────────────
select is(
  (select count(*)::int from cron.job
    where jobname = 'reconciliar_reputacao_diaria'
      and command = 'select privado.reconciliar_comparecimento()'),
  1,
  'Job reconciliar_reputacao_diaria está agendado no pg_cron chamando privado.reconciliar_comparecimento()');

select is(
  (select schedule from cron.job where jobname = 'reconciliar_reputacao_diaria'),
  '0 6 * * *',
  'Job reconciliar_reputacao_diaria roda uma vez por dia às 06:00 UTC (03:00 em Brasília)');

select ok(
  (select active from cron.job where jobname = 'reconciliar_reputacao_diaria'),
  'Job reconciliar_reputacao_diaria está ativo');

-- ── 3. O conjunto inteiro de jobs ──────────────────────────────────────────────────
-- Todo job agendado é `select privado.<função>()` e a função existe e aceita a chamada
-- sem argumento (todos os parâmetros com default, como `liberar_teto(p_limite)`). Um job
-- cujo comando aponta para função renomeada ou removida falha em silêncio a cada execução.
select is(
  (select count(*)::int from cron.job j
    where j.command !~ '^select privado\.[a-z_]+\(\)$'
       or not exists (
         select 1
           from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'privado'
            and p.proname = substring(j.command from '^select privado\.([a-z_]+)\(\)$')
            and p.pronargs = p.pronargdefaults)),
  0,
  'Todo job do pg_cron chama uma função privado.* que existe e aceita a chamada sem argumento');

select is(
  (select count(*)::int from cron.job where not active),
  0,
  'Nenhum job do pg_cron está desativado');

select set_eq(
  'select jobname::text from cron.job',
  array[
    'reprocessar_despacho',
    'limpar_dispositivos_inativos',
    'retencao_e_limpeza_diaria',
    'enviar_lembretes_turno',
    'alertar_vagas_vazias',
    'liberar_teto',
    'alertar_atrasos',
    'fechar_turnos_e_vagas',
    'reconciliar_reputacao_diaria'
  ],
  'Os jobs agendados são exatamente os nove conhecidos: job novo entra aqui junto com a migração');

select * from finish();
rollback;
