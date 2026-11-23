-- O teto real do servidor nos comentários da coleta do registro de acessos (B-449-NIT, sobras do #449).
--
-- A Management API do Supabase recusa max_slot_wal_keep_size abaixo de 1 GB (400: "Allowed values: >= 1GB <= 2TB",
-- medido no frila-prod em 08/11/2026, 19:08). O Prod ficou em 1 GB, e a coleta foi ligada nesse teto (08/11, 19:32).
-- Os comentários da 20261108110000 citavam 256 MB e justificavam o máximo da autoproteção pelo confirmed_flush_lsn
-- (o nit do Lince AG 2 na linha 85). O porquê certo: acima do max_slot_wal_keep_size, o servidor invalida o slot (lost)
-- antes de a autoproteção agir, e o intervalo se perde.
--
-- Só os dois comentários mudam: nenhum corpo, assinatura, CHECK ou grant. O teto da autoproteção
-- (registro_acesso_coleta.teto_wal_mb: 128 MB, entre 16 e 192) não muda.

select set_config('lock_timeout', '2s', true);

comment on table privado.registro_acesso_coleta is
  'Chave da coleta de registros de acesso (uma linha só). Nasce desligada; liga e desliga só por privado.definir_coleta_registro_acesso, que cria ou derruba o slot lógico. consumido_em é o último consumo bem-sucedido (o alerta registro_acesso_parado e o início de um buraco). teto_wal_mb é o atraso máximo do slot antes de a autoproteção o derrubar (128 MB; o service_role ajusta entre 16 e 192). O servidor tem o próprio teto, o max_slot_wal_keep_size, que no Prod é 1 GB, o mínimo que o Supabase aceita: acima dele, o servidor invalida o slot (lost) antes de a autoproteção agir, e o intervalo se perde. O máximo de 192 MB fica bem abaixo desse teto. Subir o máximo da autoproteção exige migração e, antes, conferir o max_slot_wal_keep_size. Não guarda dado pessoal.';

comment on function privado.definir_coleta_registro_acesso(boolean) is
  'Liga ou desliga a coleta de registros de acesso. Ligar cria o slot lógico antes de virar a chave; desligar vira a chave e derruba o slot (sem coleta, nada retém WAL). Operação manual do Prod: ligar só depois do max_slot_wal_keep_size de 1 GB (o mínimo que o Supabase aceita) aplicado e lido de volta, e com a prova de que um GET grava o cf-connecting-ip. Desligar antes de qualquer upgrade do Postgres.';
