-- Segurança: Revoga privilégios nos objetos do schema `net` (extensão pg_net)
-- para PUBLIC, anon e authenticated (Achado do Item 0e / 10c / AUDITORIA-PG-NET.md).
--
-- ATENÇÃO ARQUITETURAL CRÍTICA:
-- No Supabase hospedado (nuvem), as migrações e o SQL Editor rodam sob a role `postgres`,
-- mas a extensão `pg_net` e seus objetos pertencem a `supabase_admin` (superuser).
-- No modelo de segurança do PostgreSQL, o usuário `postgres` NÃO consegue revogar concessões
-- outorgadas por `supabase_admin` (o comando emite apenas o aviso "no privileges could be revoked"
-- e não modifica as ACLs em produção).
--
-- Portanto, esta migração NÃO fecha o risco em produção/hospedado (funciona apenas como defesa
-- em profundidade no ambiente local/CI onde o executor tem privilégio).
-- A mitigação real em produção é arquitetural (proposta na nota PROPOSTA-SEGREDO-DESPACHO.md:
-- segredo por função + tokens efêmeros HMAC de ~60 s sem expor credenciais fixas nos cabeçalhos).
--
-- Protegido com bloco DO / EXCEPTION para garantir que mesmo sob restrições estritas de privilégio
-- de não-dono no ambiente hospedado, o deploy da migração nunca falhe por erro fatal de permissão.

do $$
begin
  -- 1. Revogações no schema net
  begin
    revoke all on schema net from public, anon, authenticated;
  exception when others then
    null;
  end;

  -- 2. Revogações em tabelas e sequências
  begin
    revoke all on all tables in schema net from public, anon, authenticated;
    revoke all on all sequences in schema net from public, anon, authenticated;
  exception when others then
    null;
  end;

  -- 3. Revogações em rotinas HTTP de saída
  begin
    revoke execute on function net.http_get(text, jsonb, jsonb, integer) from public, anon, authenticated;
    revoke execute on function net.http_post(url text, body jsonb, params jsonb, headers jsonb, timeout_milliseconds integer) from public, anon, authenticated;
    revoke execute on function net.http_delete(url text, params jsonb, headers jsonb, timeout_milliseconds integer, body jsonb) from public, anon, authenticated;
  exception when others then
    null;
  end;

  -- 4. Alteração de default privileges
  begin
    alter default privileges in schema net revoke all on tables from public, anon, authenticated;
    alter default privileges in schema net revoke all on routines from public, anon, authenticated;
    alter default privileges in schema net revoke all on sequences from public, anon, authenticated;
  exception when others then
    null;
  end;
end $$;
