-- Segurança: Revoga privilégios nos objetos do schema `net` (extensão pg_net)
-- para PUBLIC, anon e authenticated (Achado do Item 0e / 10c / AUDITORIA-PG-NET.md).
--
-- AVISO DE ESCOPO E LIMITAÇÃO DE SEGURANÇA (PRODUÇÃO vs LOCAL/CI):
-- 1. Este REVOKE só tem efeito onde o papel executor da migração é dono dos objetos ou
--    superusuário (ambientes local e de CI).
-- 2. No Supabase hospedado (nuvem), as migrações rodam sob a role `postgres`, enquanto
--    a extensão `pg_net` e seus objetos pertencem ao superuser `supabase_admin`. No modelo
--    relacional do PostgreSQL, `postgres` NÃO consegue revogar privilégios outorgados por
--    `supabase_admin` (o banco apenas emite avisos "no privileges could be revoked" e mantém
--    as ACLs inalteradas).
-- 3. Portanto, esta migração NÃO fecha o risco de exposição em produção/hospedado.
--    A mitigação real em produção é arquitetural (proposta na nota PROPOSTA-SEGREDO-DESPACHO.md:
--    segredos por função + tokens HMAC efêmeros de ~60 s sem credenciais fixas nos cabeçalhos,
--    além de manter o schema `net` fora dos schemas expostos na API PostgREST).
-- 4. Para imunidade total a diferenças de versão do `pg_net` (como assinaturas de `http_delete`
--    presentes apenas no pg_net >= 0.15) e restrições de permissão de não-dono, a migração
--    itera dinamicamente o catálogo (`pg_class` e `pg_proc`) com blocos BEGIN/EXCEPTION
--    individuais por comando, garantindo que o deploy nunca seja abortado.

do $$
declare
  r record;
begin
  -- 1. Schema net
  begin
    execute 'revoke all on schema net from public, anon, authenticated';
  exception when others then
    null;
  end;

  -- 2. Classes do schema net (tabelas, sequências, views) via catálogo
  for r in (
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'net'
      and c.relkind in ('r', 'v', 'm', 'S', 'f', 'p')
  ) loop
    begin
      execute format('revoke all on %I.%I from public, anon, authenticated', 'net', r.relname);
    exception when others then
      null;
    end;
  end loop;

  -- 3. Rotinas/funções do schema net via pg_proc (imune a versões/assinaturas do pg_net)
  for r in (
    select p.oid::regprocedure as regproc
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'net'
  ) loop
    begin
      execute format('revoke execute on function %s from public, anon, authenticated', r.regproc);
    exception when others then
      null;
    end;
  end loop;

  -- 4. Default privileges para objetos futuros no schema net
  begin
    execute 'alter default privileges in schema net revoke all on tables from public, anon, authenticated';
  exception when others then
    null;
  end;
  begin
    execute 'alter default privileges in schema net revoke all on routines from public, anon, authenticated';
  exception when others then
    null;
  end;
  begin
    execute 'alter default privileges in schema net revoke all on sequences from public, anon, authenticated';
  exception when others then
    null;
  end;
end $$;

