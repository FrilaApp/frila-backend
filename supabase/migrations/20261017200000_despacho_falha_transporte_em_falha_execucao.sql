-- Correção do tratamento de falha de transporte no despacho imediato (Achado 3 da AUDITORIA-CRON.md).
--
-- Anteriormente, quando `net.http_post` falhava, o bloco `exception when others` inseria uma linha
-- em `public.ocorrencia` do tipo `revisao_despacho` atribuída ao contratante da vaga (`usuario_id = autor_id`).
-- Isso imputava erroneamente ao usuário uma falha de infraestrutura que ele não causou.
--
-- Agora, a falha é registrada em `privado.falha_execucao` via `privado.registrar_falha_execucao`,
-- mantendo os dados operacionais isolados, sem gerar ocorrência contra o contratante,
-- e deixando a mensagem em `pgmq.q_despacho` para reprocessamento pelo pg_cron.

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
  v_secret text := current_setting('frila.agendador_secret', true);
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
  'Dispara a Edge Function despachar na hora via net.http_post (sai pós-commit). Registra falha de transporte em privado.falha_execucao.';

revoke execute on function privado.disparar_despacho(uuid) from public, anon, authenticated;
