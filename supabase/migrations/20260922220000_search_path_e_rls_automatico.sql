-- Duas coisas que o advisor de segurança do Supabase apontou no frila-dev.
--
-- ── 1. Funções sem search_path imutável ────────────────────────────────────────
--
-- Três funções ficaram sem `set search_path`. Nenhuma é `security definer`, então o
-- risco é menor — mas `sincronizar_horario_da_posicao` escreve em `public.posicao`, e
-- uma função que resolve nomes pelo caminho de busca do chamador é uma função cujo
-- alvo depende de quem a chama. Fixar o caminho custa uma linha.

create or replace function public.erro(status int, codigo text, motivo text default null)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  raise sqlstate 'PGRST' using
    message = json_build_object('code', codigo, 'message', codigo,
                                'details', motivo, 'hint', null)::text,
    detail  = json_build_object('status', status)::text;
end $$;

revoke execute on function public.erro(int, text, text) from public, anon, authenticated;

create or replace function privado.perfil_imutavel() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'o perfil da conta não muda (RN25)' using errcode = 'check_violation';
end $$;

create or replace function privado.sincronizar_horario_da_posicao() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update public.posicao
     set inicio_em = new.inicio_em, fim_em = new.fim_em
   where vaga_id = new.id
     and estado = 'aberta';
  return new;
end $$;

-- ── 2. O event trigger que existia no frila-dev e não no local ────────────────
--
-- O advisor apontou `public.rls_auto_enable`, uma função que eu não escrevi: ela
-- estava no frila-dev, disparada pelo event trigger `ensure_rls`, e liga Row Level
-- Security sozinha em toda tabela nova do schema `public`. Veio do painel do Supabase,
-- não de migração.
--
-- Isso é o modo de falha que a Modelagem nomeia: "mudança feita pelo painel do Supabase
-- e não trazida para um arquivo é mudança que o próximo ambiente não tem". Enquanto o
-- local não tivesse isto e o frila-dev tivesse, os dois ambientes responderiam
-- diferente à mesma migração — e o ambiente onde a falha aparece não seria o ambiente
-- onde ela foi escrita.
--
-- Trazido para cá, em vez de removido de lá: a rede de proteção é boa. Ela **não**
-- substitui o `enable row level security` explícito nas migrações, e não substitui o
-- teste de `005_rls_fechado.sql`, que é quem realmente pega a tabela esquecida — o
-- event trigger, sozinho, esconderia o esquecimento em vez de denunciá-lo.

-- `search_path = ''` com tudo qualificado, e não o `pg_catalog` que veio do painel.
-- Os dois são seguros — `pg_catalog` não é sequestrável —, mas a regra do projeto é
-- uma só, e regra com exceção é regra que ninguém aplica sem consultar.
create or replace function public.rls_auto_enable() returns event_trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  cmd record;
begin
  for cmd in
    select *
      from pg_catalog.pg_event_trigger_ddl_commands()
     where command_tag in ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
       and object_type in ('table', 'partitioned table')
  loop
    if cmd.schema_name = 'public' then
      begin
        execute pg_catalog.format('alter table if exists %s enable row level security', cmd.object_identity);
        raise log 'rls_auto_enable: RLS ligado em %', cmd.object_identity;
      exception when others then
        raise log 'rls_auto_enable: não consegui ligar RLS em %', cmd.object_identity;
      end;
    end if;
  end loop;
end $$;

comment on function public.rls_auto_enable() is
  'Rede de proteção: liga RLS em toda tabela nova de public. Não substitui o enable explícito na migração nem o teste que confere.';

-- Nenhum cliente chama isto: é o Postgres que dispara, e a função roda como o dono.
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

do $$
begin
  if not exists (select 1 from pg_event_trigger where evtname = 'ensure_rls') then
    create event trigger ensure_rls on ddl_command_end
      execute function public.rls_auto_enable();
  end if;
end $$;
