-- NEW-01: privado.disparar_email() substitui apenas o sufixo '/despachar' e remove Authorization redundante.
--
-- Achado da vistoria de segurança do backend (vistoria-backend-2026-11-22.md):
--   1. replace(decrypted_secret, '/despachar', '/enviar-email') substituía TODAS as ocorrências de
--      '/despachar' na URL (podendo corromper host ou prefixo de caminho que contenha '/despachar').
--      Passa a usar regexp_replace(decrypted_secret, '/despachar$', '/enviar-email'), alterando apenas
--      o sufixo final já filtrado por LIKE '%/despachar'.
--   2. Após o #587 (BE-03), a Edge Function enviar-email exige apenas o cabeçalho dedicado
--      x-agendador-secret por padrão (não Authorization: Bearer). O envio duplicado do segredo em
--      Authorization é removido.
--
-- Assinatura, SECURITY DEFINER, search_path vazio e grants permanecem inalterados.

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
    (select regexp_replace(decrypted_secret, '/despachar$', '/enviar-email')
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
  'Dispara a Edge Function de envio de e-mails via pg_net usando x-agendador-secret (NEW-01). Lê email_function_url do Vault, com fallback ao GUC frila.email_function_url, fallback derivado de edge_function_url substituindo apenas o sufixo /despachar por /enviar-email, e padrão local.';
revoke execute on function privado.disparar_email() from public, anon, authenticated;
grant  execute on function privado.disparar_email() to service_role;
