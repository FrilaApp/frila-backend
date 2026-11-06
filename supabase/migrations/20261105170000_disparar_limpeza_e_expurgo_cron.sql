-- Disparo diário de limpar-contas-orfas e expurgar-midias por pg_cron + pg_net (bebr4VIE).
--
-- As duas Edge Functions existem e validam o segredo do agendador, mas nenhum job as chamava:
-- `cron.job` não tinha entrada para elas. Sem o disparo, contas órfãs de `auth.users` não eram
-- purgadas e a segunda fase do expurgo da mídia de verificação de identidade (RN14) nunca
-- apagava o byte no Storage; a primeira fase, do banco, só enfileira.
--
-- Mesmo desenho de `privado.disparar_push` (20261104140200): `net.http_post` sai pós-commit com
-- `x-agendador-secret` e `Bearer`, e uma falha de transporte não aborta nem registra o erro,
-- porque o texto dela pode trazer a URL. Sem o segredo do agendador, só `warning` e retorno nulo.
-- `expurgar-midias` aceita exclusivamente `x-agendador-secret`; o `Bearer` vai por padronização
-- e é ignorado por ela.
--
-- URL, na ordem: segredo do Vault próprio da função, GUC próprio, a URL `edge_function_url` do
-- despacho trocando o final pelo nome da função e, por último, o Supabase local.
--
-- Horários (UTC): `retencao_e_limpeza_diaria` roda às 06:30 e, no banco, enfileira o que venceu
-- para o expurgo; `limpar_contas_orfas_diaria` roda às 06:45 e `expurgar_midias_diaria` às 07:00,
-- depois da fila estar cheia.

create or replace function privado.disparar_limpeza_contas_orfas()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'limpar_contas_function_url' limit 1),
    nullif(current_setting('frila.limpar_contas_function_url', true), ''),
    (select replace(decrypted_secret, '/despachar', '/limpar-contas-orfas')
       from vault.decrypted_secrets where name = 'edge_function_url' limit 1),
    'http://127.0.0.1:54321/functions/v1/limpar-contas-orfas'
  );
  v_secret text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.agendador_secret', true), '')
  );
  v_req_id bigint;
begin
  if v_secret is null or v_secret = '' then
    raise warning 'frila.agendador_secret ausente: a limpeza de contas órfãs não foi disparada';
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
      body    => jsonb_build_object('origem', 'cron'),
      timeout_milliseconds => 5000
    );
  exception when others then
    v_req_id := null;
  end;

  return v_req_id;
end $$;

comment on function privado.disparar_limpeza_contas_orfas() is
  'Dispara a Edge Function limpar-contas-orfas via pg_net. Lê limpar_contas_function_url (ou deriva de edge_function_url) e agendador_secret do Vault, com fallback ao GUC. Nunca aborta quem chamou (bebr4VIE).';
revoke execute on function privado.disparar_limpeza_contas_orfas() from public, anon, authenticated;
grant  execute on function privado.disparar_limpeza_contas_orfas() to service_role;

create or replace function privado.disparar_expurgo_midias()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'expurgar_midias_function_url' limit 1),
    nullif(current_setting('frila.expurgar_midias_function_url', true), ''),
    (select replace(decrypted_secret, '/despachar', '/expurgar-midias')
       from vault.decrypted_secrets where name = 'edge_function_url' limit 1),
    'http://127.0.0.1:54321/functions/v1/expurgar-midias'
  );
  v_secret text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.agendador_secret', true), '')
  );
  v_req_id bigint;
begin
  if v_secret is null or v_secret = '' then
    raise warning 'frila.agendador_secret ausente: o expurgo de mídias não foi disparado';
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
      body    => jsonb_build_object('origem', 'cron'),
      timeout_milliseconds => 5000
    );
  exception when others then
    v_req_id := null;
  end;

  return v_req_id;
end $$;

comment on function privado.disparar_expurgo_midias() is
  'Dispara a Edge Function expurgar-midias via pg_net. Lê expurgar_midias_function_url (ou deriva de edge_function_url) e agendador_secret do Vault, com fallback ao GUC. Nunca aborta quem chamou (bebr4VIE).';
revoke execute on function privado.disparar_expurgo_midias() from public, anon, authenticated;
grant  execute on function privado.disparar_expurgo_midias() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('limpar_contas_orfas_diaria')
      where exists (select 1 from cron.job where jobname = 'limpar_contas_orfas_diaria');
    perform cron.schedule(
      'limpar_contas_orfas_diaria',
      '45 6 * * *',
      'select privado.disparar_limpeza_contas_orfas()'
    );

    perform cron.unschedule('expurgar_midias_diaria')
      where exists (select 1 from cron.job where jobname = 'expurgar_midias_diaria');
    perform cron.schedule(
      'expurgar_midias_diaria',
      '0 7 * * *',
      'select privado.disparar_expurgo_midias()'
    );
  end if;
end $$;
