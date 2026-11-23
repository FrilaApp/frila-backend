-- Fallback derivado de edge_function_url em privado.disparar_email (B-083).
--
-- Quando email_function_url não está cadastrado no Vault e o parâmetro GUC frila.email_function_url
-- está vazio, privado.disparar_email passa a derivar a URL do segredo edge_function_url do Vault,
-- substituindo o sufixo '/despachar' por '/enviar-email' (apenas se terminar em '/despachar').
--
-- Caso caia no padrão local (127.0.0.1:54321), emite um warning defensivo para alertar em logs
-- que a URL remota de e-mail não foi configurada.

select set_config('lock_timeout', '2s', true);

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
    (select replace(decrypted_secret, '/despachar', '/enviar-email')
       from vault.decrypted_secrets
      where name = 'edge_function_url'
        and decrypted_secret like '%/despachar'
      limit 1)
  );
  v_url_padrao boolean := (v_url is null);
  v_secret text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.agendador_secret', true), '')
  );
  v_req_id bigint;
begin
  if v_url_padrao then
    v_url := 'http://127.0.0.1:54321/functions/v1/enviar-email';
  end if;

  -- Fila vazia não acorda ninguém: o job de um minuto rodaria um POST por minuto para
  -- sempre, e o provedor de e-mail cobra por chamada em quase todo plano.
  if not exists (select 1 from pgmq.q_email limit 1) then
    return null;
  end if;

  if v_secret is null or v_secret = '' then
    raise warning 'frila.agendador_secret ausente: o pedido de e-mail fica na fila até o segredo voltar';
    return null;
  end if;

  if v_url_padrao then
    raise warning 'email_function_url ausente: usando o endereço local padrão; grave email_function_url (ou edge_function_url) no Vault';
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
  'Dispara a Edge Function de envio de e-mails via pg_net. Lê email_function_url do Vault, com fallback ao GUC frila.email_function_url, fallback derivado de edge_function_url (se terminar em /despachar) e padrão local.';
revoke execute on function privado.disparar_email() from public, anon, authenticated;
grant  execute on function privado.disparar_email() to service_role;
