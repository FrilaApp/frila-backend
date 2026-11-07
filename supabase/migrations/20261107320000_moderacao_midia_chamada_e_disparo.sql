-- B4c: Tabela de consumo de moderação (privado.moderacao_chamada),
-- disparo via net.http_post e agendamento cron para moderar-midia (RN37, RN15).

-- 1. Tabela de consumo de chamadas a provedores de moderação (teto mensal e limite por foto)
create table if not exists privado.moderacao_chamada (
  id bigserial primary key,
  midia_id uuid not null references privado.midia(id) on delete cascade,
  provedor text not null,
  mes text not null,
  criado_em timestamptz not null default privado.agora()
);

create index if not exists idx_moderacao_chamada_mes_provedor on privado.moderacao_chamada(mes, provedor);
create index if not exists idx_moderacao_chamada_midia_id on privado.moderacao_chamada(midia_id);

comment on table privado.moderacao_chamada is
  'Registro atômico de chamadas a provedores de moderação de imagem para controle de teto mensal e limite por foto (B4c / RN37).';

revoke all on table privado.moderacao_chamada from public, anon, authenticated;
grant select, insert, delete on table privado.moderacao_chamada to service_role;
grant usage, select on sequence privado.moderacao_chamada_id_seq to service_role;
alter table privado.moderacao_chamada enable row level security;

-- 2. Disparador da Edge Function moderar-midia via pg_net
create or replace function privado.disparar_moderar_midia()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'moderar_midia_function_url' limit 1),
    nullif(current_setting('frila.moderar_midia_function_url', true), ''),
    (select replace(decrypted_secret, '/despachar', '/moderar-midia')
       from vault.decrypted_secrets where name = 'edge_function_url' limit 1),
    'http://127.0.0.1:54321/functions/v1/moderar-midia'
  );
  v_secret text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.agendador_secret', true), '')
  );
  v_req_id bigint;
begin
  if v_secret is null or v_secret = '' then
    raise warning 'frila.agendador_secret ausente: a moderação de mídia não foi disparada';
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
      body    => jsonb_build_object('origem', 'enfileirado'),
      timeout_milliseconds => 5000
    );
  exception when others then
    v_req_id := null;
  end;

  return v_req_id;
end $$;

comment on function privado.disparar_moderar_midia() is
  'Dispara a Edge Function moderar-midia via pg_net com segredo do agendador. Nunca aborta a transação chamadora.';
revoke execute on function privado.disparar_moderar_midia() from public, anon, authenticated;
grant  execute on function privado.disparar_moderar_midia() to service_role;

-- 3. Trigger ao enfileirar em pgmq.q_moderacao_midia
create or replace function privado.trg_disparar_moderar_midia()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform privado.disparar_moderar_midia();
  return new;
end $$;

comment on function privado.trg_disparar_moderar_midia() is
  'Trigger que acorda a Edge Function moderar-midia imediatamente após inserção na fila pgmq.';
revoke execute on function privado.trg_disparar_moderar_midia() from public, anon, authenticated;
grant  execute on function privado.trg_disparar_moderar_midia() to service_role;

drop trigger if exists trg_moderacao_midia_enfileirada on pgmq.q_moderacao_midia;
create trigger trg_moderacao_midia_enfileirada
  after insert on pgmq.q_moderacao_midia
  for each row
  execute function privado.trg_disparar_moderar_midia();

-- 4. Agendamento periódico por pg_cron (fallback caso o trigger pg_net falhe)
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('processar_fila_moderacao_midia')
      where exists (select 1 from cron.job where jobname = 'processar_fila_moderacao_midia');
    perform cron.schedule(
      'processar_fila_moderacao_midia',
      '* * * * *',
      'select privado.disparar_moderar_midia()'
    );
  end if;
end $$;
