-- 824_lgpd_registro_acessos_teto_do_slot.sql · LGPD-J6 R11 (migração 20261108110000).
-- Autoproteção do slot lógico: o atraso acima da metade do teto acende o alerta; acima do teto, o consumidor derruba o
-- slot (o WAL fica livre), registra o buraco em falha_execucao sem dado pessoal, e a verificar_saude também vigia.
-- O atraso é medido pelo restart_lsn, que é o que retém o WAL: a própria transação deste arquivo, aberta, segura o
-- restart_lsn enquanto o confirmed_flush_lsn avança (o caso E7b do Lince AG 2, numa sessão só).
-- Arquivo próprio porque o consumidor só pode ser chamado UMA vez por sessão (ver o 822).
begin;
-- Slot de teste TEMPORÁRIO, antes de qualquer escrita (o Postgres exige), com o nome real.
select 1 from pg_create_logical_replication_slot('frila_registro_acesso', 'test_decoding', true);
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-08 12:00:00+00', true);
select plan(12);

select is((privado.definir_coleta_registro_acesso(true) ->> 'slot')::boolean, true, 'coleta ligada, com o slot');
delete from privado.alerta_emitido where codigo like 'registro_acesso_%';
delete from privado.falha_execucao where codigo like 'registro_acesso_%';

-- O teto fica entre 16 e 192 MB, bem abaixo do max_slot_wal_keep_size de 1 GB do Prod (o mínimo que o Supabase aceita,
-- desde 08/11/2026). Acima do teto do servidor, ele invalidaria o slot antes de a autoproteção agir.
select lives_ok($$ update privado.registro_acesso_coleta set teto_wal_mb = 192 $$, 'teto de 192 MB é aceito');
select throws_ok($$ update privado.registro_acesso_coleta set teto_wal_mb = 193 $$, '23514', null,
  'teto de 193 MB é recusado (o máximo da autoproteção é 192 MB)');
select lives_ok($$ update privado.registro_acesso_coleta set teto_wal_mb = 16 $$, 'teto de 16 MB é aceito');
select throws_ok($$ update privado.registro_acesso_coleta set teto_wal_mb = 15 $$, '23514', null, 'teto de 15 MB é recusado');

-- WAL de verdade para o atraso: ~20 MB numa tabela desta transação (desfeita no rollback).
update privado.registro_acesso_coleta set teto_wal_mb = 32, consumido_em = privado.agora();
create table privado.zz_824_wal as select repeat(md5(n::text), 32) as x from generate_series(1, 20000) n;
-- O confirmed_flush_lsn avança até agora; o restart_lsn não passa do começo desta transação, que segue aberta.
-- O avanço não passa do WAL que já foi ao disco: a mensagem com flush força o disco antes.
select pg_logical_emit_message(false, 'zz_824_flush', 'x', true) is not null as flush;
select 1 from pg_replication_slot_advance('frila_registro_acesso', pg_current_wal_lsn());
select ok((select pg_wal_lsn_diff(confirmed_flush_lsn, restart_lsn) > 16 * 1048576
             from pg_replication_slots where slot_name = 'frila_registro_acesso'),
  'transação longa: o confirmed_flush_lsn avançou mais de 16 MB à frente do restart_lsn, que segue retendo o WAL');
select privado.verificar_saude();
select ok(exists (select 1 from privado.alerta_emitido where codigo = 'registro_acesso_wal_atrasado'),
  'atraso do slot acima da metade do teto: alerta registro_acesso_wal_atrasado');
select ok(exists (select 1 from pg_replication_slots where slot_name = 'frila_registro_acesso'),
  'abaixo do teto, o slot fica');

-- Acima do teto, o consumidor derruba o slot e registra o buraco.
update privado.registro_acesso_coleta set teto_wal_mb = 16;
select privado.consumir_registro_acesso() ->> 'protecao' is not null as consumiu;
select ok(not exists (select 1 from pg_replication_slots where slot_name = 'frila_registro_acesso'),
  'atraso acima do teto: o slot cai e o WAL fica livre');
select results_eq($$ select detalhes ->> 'motivo', (detalhes ->> 'teto_mb')::int, detalhes ? 'desde', detalhes ? 'ate'
                       from privado.falha_execucao where codigo = 'registro_acesso_buraco' $$,
  $$ values ('slot_acima_do_teto'::text, 16, true, true) $$,
  'o buraco vai para falha_execucao com motivo, teto e período');
-- Aqui a transação já escreveu, e o Postgres não deixa recriar o slot: o buraco diz isso.
select is((select (detalhes ->> 'recriado')::boolean from privado.falha_execucao where codigo = 'registro_acesso_buraco'), false,
  'sem poder recriar agora, o buraco registra recriado = false (o pg_cron recria na rodada seguinte)');
select privado.verificar_saude();
select ok(exists (select 1 from privado.falha_execucao where codigo = 'registro_acesso_buraco' and origem = 'verificar_saude'
                   and detalhes ->> 'motivo' = 'slot_ausente'),
  'a verificar_saude também vigia: slot ausente com a coleta ligada é buraco');

select * from finish();
rollback;
