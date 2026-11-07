-- Validação da constraint midia_tipo em transação separada (ADR / Postgres Best Practices).
-- O VALIDATE CONSTRAINT roda em transação posterior, adquirindo apenas ShareUpdateExclusiveLock
-- e liberando leituras e escritas concorrentes na tabela durante a validação.
set lock_timeout = '2s';
alter table privado.midia validate constraint midia_tipo;
