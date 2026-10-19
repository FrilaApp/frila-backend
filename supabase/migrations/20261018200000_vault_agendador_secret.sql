-- Lê o segredo do Vault com fallback ao GUC, preservando os corpos atuais da develop.
-- Mantém falhas de transporte do despacho em privado.falha_execucao.

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
