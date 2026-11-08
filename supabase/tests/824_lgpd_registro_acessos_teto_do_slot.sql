-- 824_lgpd_registro_acessos_teto_do_slot.sql · LGPD-J6 R11 (migração 20261108110000).
-- Autoproteção do slot lógico: o atraso acima da metade do teto acende o alerta; acima do teto, o consumidor derruba o
-- slot (o WAL fica livre), registra o buraco em falha_execucao sem dado pessoal, e a verificar_saude também vigia.
-- Arquivo próprio porque o consumidor só pode ser chamado UMA vez por sessão (ver o 822).
begin;
-- Slot de teste TEMPORÁRIO, antes de qualquer escrita (o Postgres exige), com o nome real.
select 1 from pg_create_logical_replication_slot('frila_registro_acesso', 'test_decoding', true);
insert into privado.ambiente (id, eh_teste) values (true, true) on conflict (id) do update set eh_teste = true;
select set_config('frila.agora', '2026-11-08 12:00:00+00', true);
select plan(11);

select is((privado.definir_coleta_registro_acesso(true) ->> 'slot')::boolean, true, 'coleta ligada, com o slot');
delete from privado.alerta_emitido where codigo like 'registro_acesso_%';
delete from privado.falha_execucao where codigo like 'registro_acesso_%';

-- O teto fica entre 16 e 192 MB: 192 é 75% do max_slot_wal_keep_size de 256 MB do Prod. Acima dele, o servidor
-- invalidaria o slot antes de a autoproteção agir.
select lives_ok($$ update privado.registro_acesso_coleta set teto_wal_mb = 192 $$, 'teto de 192 MB é aceito');
select throws_ok($$ update privado.registro_acesso_coleta set teto_wal_mb = 193 $$, '23514', null,
  'teto de 193 MB é recusado (acima de 75% do max_slot_wal_keep_size do Prod)');
select lives_ok($$ update privado.registro_acesso_coleta set teto_wal_mb = 16 $$, 'teto de 16 MB é aceito');
select throws_ok($$ update privado.registro_acesso_coleta set teto_wal_mb = 15 $$, '23514', null, 'teto de 15 MB é recusado');

-- WAL de verdade para o atraso: ~20 MB numa tabela desta transação (desfeita no rollback).
update privado.registro_acesso_coleta set teto_wal_mb = 32, consumido_em = privado.agora();
create table privado.zz_824_wal as select repeat(md5(n::text), 32) as x from generate_series(1, 20000) n;
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
