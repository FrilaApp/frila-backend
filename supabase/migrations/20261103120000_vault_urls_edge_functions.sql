-- supabase/migrations/20261020190000_vault_urls_edge_functions.sql
--
-- Lê as URLs das Edge Functions do Supabase Vault (vault.decrypted_secrets)
-- com fallback para o parâmetro GUC e fallback estático padrão (127.0.0.1:54321).
--
-- Inclui bloco DO idempotente que cadastra ou atualiza os segredos 'edge_function_url'
-- e 'email_function_url' no Vault a partir do parâmetro frila.project_ref, sem URL de Prod hardcoded.

create or replace function privado.disparar_despacho(p_vaga_id uuid default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'edge_function_url' limit 1),
    nullif(current_setting('frila.edge_function_url', true), ''),
    'http://127.0.0.1:54321/functions/v1/despachar'
  );
  v_secret text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.agendador_secret', true), '')
  );
  v_req_id bigint;
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
    -- Só falha de transporte é recuperável: registra sem dado pessoal em privado.falha_execucao
    -- e deixa a mensagem na fila para o pg_cron reprocessar.
    perform privado.registrar_falha_execucao(
      'despacho_imediato',
      'falha_transporte_pg_net',
      case when p_vaga_id is not null then jsonb_build_object('vaga_id', p_vaga_id) else null end
    );
    v_req_id := null;
  end;
  return v_req_id;
end $$;

comment on function privado.disparar_despacho(uuid) is
  'Dispara a Edge Function de despacho via pg_net. Lê edge_function_url e agendador_secret do Vault com fallback ao GUC. Trata erro de rede sem perder a mensagem nem abortar transação.';
revoke execute on function privado.disparar_despacho(uuid) from public, anon, authenticated;
grant  execute on function privado.disparar_despacho(uuid) to service_role;

create or replace function privado.disparar_email()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'email_function_url' limit 1),
    nullif(current_setting('frila.email_function_url', true), ''),
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
  'Dispara a Edge Function de envio de e-mails via pg_net. Lê email_function_url e agendador_secret do Vault com fallback ao GUC.';
revoke execute on function privado.disparar_email() from public, anon, authenticated;
grant  execute on function privado.disparar_email() to service_role;

-- Bloco idempotente para configuração inicial a partir de parâmetro de ambiente.
-- Se frila.project_ref estiver definido, cadastra ou atualiza os dois segredos no Vault.
-- Template de URL para ambientes Supabase remotos: https://<ref>.supabase.co/functions/v1/...
do $$
declare
  v_ref text := coalesce(nullif(current_setting('frila.project_ref', true), ''), '<ref>');
  v_url_despacho text;
  v_url_email    text;
  v_secret_id    uuid;
begin
  if v_ref is not null and v_ref <> '' and v_ref <> '<ref>' then
    v_url_despacho := 'https://' || v_ref || '.supabase.co/functions/v1/despachar';
    v_url_email    := 'https://' || v_ref || '.supabase.co/functions/v1/enviar-email';

    -- 1. Configura edge_function_url de forma idempotente
    select id into v_secret_id from vault.secrets where name = 'edge_function_url';
    if v_secret_id is not null then
      perform vault.update_secret(v_secret_id, v_url_despacho, 'edge_function_url', 'URL da Edge Function de despacho');
    else
      perform vault.create_secret(v_url_despacho, 'edge_function_url', 'URL da Edge Function de despacho');
    end if;

    -- 2. Configura email_function_url de forma idempotente
    select id into v_secret_id from vault.secrets where name = 'email_function_url';
    if v_secret_id is not null then
      perform vault.update_secret(v_secret_id, v_url_email, 'email_function_url', 'URL da Edge Function de e-mails transacionais');
    else
      perform vault.create_secret(v_url_email, 'email_function_url', 'URL da Edge Function de e-mails transacionais');
    end if;
  end if;
end $$;
