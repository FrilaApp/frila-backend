-- Agendador do push: privado.disparar_push(), gatilho pós-insert e job de um minuto (hQDlvpHi).
--
-- Medido no Prod: `cron.job` não tinha nenhum job chamando `enviar-push`, e a função só
-- recebia chamada manual. As notificações ficavam em `pendente` para sempre.
--
-- Mesmo desenho de `disparar_email` (20261103120000): `net.http_post` sai pós-commit, com
-- `x-agendador-secret` e `Bearer`, e nunca aborta a escrita que gerou a notificação.
--
-- URL, na ordem: segredo `push_function_url` do Vault, GUC `frila.push_function_url`, a URL
-- `edge_function_url` do despacho trocando o final por `/enviar-push` (assim o Prod não
-- precisa de segredo novo: o do despacho já aponta para o projeto certo) e, por último, o
-- endereço do Supabase local.
--
-- Fila sem pendente elegível não acorda ninguém: o job de um minuto faria um POST por minuto
-- para sempre. Falha de transporte não registra nada, porque o texto do erro pode trazer a
-- URL; a notificação continua `pendente` e o minuto seguinte tenta de novo.

create or replace function privado.disparar_push()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'push_function_url' limit 1),
    nullif(current_setting('frila.push_function_url', true), ''),
    (select replace(decrypted_secret, '/despachar', '/enviar-push')
       from vault.decrypted_secrets where name = 'edge_function_url' limit 1),
    'http://127.0.0.1:54321/functions/v1/enviar-push'
  );
  v_secret text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.agendador_secret', true), '')
  );
  v_req_id bigint;
begin
  if not exists (
    select 1
      from public.notificacao n
     where n.estado_entrega = 'pendente'
       and (n.proxima_tentativa_em is null or n.proxima_tentativa_em <= privado.agora())
  ) then
    return null;
  end if;

  if v_secret is null or v_secret = '' then
    raise warning 'frila.agendador_secret ausente: a notificação fica pendente até o segredo voltar';
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
    v_req_id := null;
  end;

  return v_req_id;
end $$;

comment on function privado.disparar_push() is
  'Dispara a Edge Function enviar-push via pg_net quando há notificação pendente elegível. Lê push_function_url (ou deriva de edge_function_url) e agendador_secret do Vault, com fallback ao GUC. Nunca aborta quem chamou (hQDlvpHi).';
revoke execute on function privado.disparar_push() from public, anon, authenticated;
grant  execute on function privado.disparar_push() to service_role;

-- Uma chamada por comando, e não por linha: um despacho que cria cem notificações em um
-- INSERT acorda a Edge Function uma vez.
create or replace function privado.trg_disparar_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform privado.disparar_push();
  return null;
end $$;

revoke execute on function privado.trg_disparar_push() from public, anon, authenticated;

drop trigger if exists trg_notificacao_disparar_push on public.notificacao;
create trigger trg_notificacao_disparar_push
  after insert on public.notificacao
  for each statement
  execute function privado.trg_disparar_push();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('processar_fila_push')
      where exists (select 1 from cron.job where jobname = 'processar_fila_push');
    perform cron.schedule(
      'processar_fila_push',
      '* * * * *',
      'select privado.disparar_push()'
    );
  end if;
end $$;
