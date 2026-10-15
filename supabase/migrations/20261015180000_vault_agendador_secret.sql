-- 20261015180000_vault_agendador_secret.sql
--
-- Leitura de agendador_secret via Supabase Vault com fallback ao parâmetro GUC
-- (docs/proposta-vault-agendador-secret.md).
--
-- Contexto:
-- No Supabase gerenciado (AWS), o usuário postgres não possui privilégios de superusuário
-- e não pode executar 'alter database postgres set frila.agendador_secret = ...'.
-- A extensão supabase_vault permite armazenar e ler segredos criptografados em repouso
-- via vault.decrypted_secrets sem privilégios de superusuário.
--
-- Mantém fallback transparente para current_setting('frila.agendador_secret', true)
-- para compatibilidade com suítes de testes unitários locais e migrações efêmeras.

create or replace function privado.disparar_despacho(p_vaga_id uuid default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    current_setting('frila.edge_function_url', true),
    'http://127.0.0.1:54321/functions/v1/despachar'
  );
  v_secret text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.agendador_secret', true), '')
  );
  v_req_id bigint;
  v_autor_id uuid;
begin
  if v_secret is null or v_secret = '' then
    raise exception 'Configuração frila.agendador_secret ausente no banco de dados';
  end if;

  -- Dispara o webhook assíncrono pós-commit via pg_net
  begin
    v_req_id := net.http_post(
      url => v_url,
      headers => jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_secret,
        'x-agendador-secret', v_secret
      ),
      body => jsonb_build_object(
        'vaga_id', p_vaga_id,
        'origem', 'pos_commit'
      ),
      timeout_milliseconds => 5000
    );
  exception when others then
    -- Só falha de transporte é recuperável: registra sem dado pessoal e deixa a
    -- mensagem na fila para o pg_cron reprocessar.
    select publicado_por into v_autor_id
    from public.vaga
     where id = p_vaga_id;
    insert into public.ocorrencia (tipo, usuario_id, autor_id, motivo)
    values (
      'revisao_despacho',
      v_autor_id,
      v_autor_id,
      'Falha de transporte no despacho imediato; mensagem mantida na fila para reprocessamento'
    );
    v_req_id := null;
  end;
  return v_req_id;
end $$;

comment on function privado.disparar_despacho(uuid) is
  'Dispara a Edge Function despachar na hora via net.http_post (sai pós-commit). Lê segredo agendador_secret do Supabase Vault com fallback ao GUC.';

revoke execute on function privado.disparar_despacho(uuid) from public, anon, authenticated;

create or replace function privado.disparar_email()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    current_setting('frila.email_function_url', true),
    'http://127.0.0.1:54321/functions/v1/enviar-email'
  );
  v_secret text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.agendador_secret', true), '')
  );
  v_req_id bigint;
begin
  -- Fila vazia não acorda ninguém: o job de um minuto rodaria um POST por minuto para
  -- sempre, e o provedor de e-mail cobra por chamada em quase todo plano.
  if not exists (select 1 from pgmq.q_email limit 1) then
    return null;
  end if;

  if v_secret is null or v_secret = '' then
    raise warning 'frila.agendador_secret ausente: o pedido de e-mail fica na fila até o segredo voltar';
    return null;
  end if;

  begin
    v_req_id := net.http_post(
      url     => v_url,
      headers => jsonb_build_object(
        'Content-Type',       'application/json',
        'Authorization',      'Bearer ' || v_secret,
        'x-agendador-secret', v_secret
      ),
      body    => jsonb_build_object('origem', 'fila'),
      timeout_milliseconds => 5000
    );
  exception when others then
    -- Só falha de transporte cai aqui, e ela é recuperável por desenho: a mensagem
    -- continua na fila e o job do minuto seguinte tenta de novo. Nada é registrado,
    -- porque o texto do erro de rede pode trazer a URL com o segredo no cabeçalho.
    v_req_id := null;
  end;

  return v_req_id;
end $$;

comment on function privado.disparar_email() is
  'Acorda a Edge Function enviar-email por net.http_post quando há pedido na fila. Sai pós-commit. Lê segredo agendador_secret do Supabase Vault com fallback ao GUC.';

revoke execute on function privado.disparar_email() from public, anon, authenticated;
grant  execute on function privado.disparar_email() to service_role;
