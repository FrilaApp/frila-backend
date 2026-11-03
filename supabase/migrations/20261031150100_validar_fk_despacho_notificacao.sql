-- 20261031150100_validar_fk_despacho_notificacao.sql
--
-- Validação da chave estrangeira despacho_notificacao_id_fkey (K-001g).
--
-- Executada em transação e migração separadas da adição inicial (20261031150000).
-- O comando VALIDATE CONSTRAINT adquire apenas ShareUpdateExclusiveLock em public.despacho,
-- permitindo que leituras (SELECT) e modificações concorrentes (INSERT, UPDATE, DELETE)
-- continuem normalmente enquanto a integridade referencial é validada.

do $$
begin
  execute 'set local lock_timeout = ''2s''';
  alter table public.despacho validate constraint despacho_notificacao_id_fkey;
end $$;
