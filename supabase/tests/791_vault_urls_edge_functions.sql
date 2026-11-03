-- 791_vault_urls_edge_functions.sql
--
-- Prova que privado.disparar_despacho e privado.disparar_email:
--   1. Leem as URLs das Edge Functions do Supabase Vault (vault.decrypted_secrets) quando existem;
--   2. O Vault tem prioridade sobre os parâmetros GUC (frila.edge_function_url / frila.email_function_url);
--   3. Caem no fallback de compatibilidade do GUC quando o Vault não possui o segredo;
--   4. Caem no fallback estático padrão (127.0.0.1:54321) quando nem Vault nem GUC estão configurados;
--   5. Não imprimem nem registram a URL com o segredo em falhas de transporte ou exceções;
--   6. O bloco de configuração idempotente via frila.project_ref atualiza os segredos sem duplicar.

begin;
select plan(23);

-- Isola o teste: limpa dados de execuções anteriores na transação
delete from vault.secrets where name in ('edge_function_url', 'email_function_url', 'agendador_secret');
delete from pgmq.q_email;
delete from net.http_request_queue;
delete from privado.falha_execucao;

-- Configura segredo do agendador e mensagem sintética na fila de e-mail
set local frila.agendador_secret = 'segredo-sintetico-vault-791';
select pgmq.send('email', '{"tipo":"teste_url_vault_791"}'::jsonb);

-- =========================================================================
-- 1. Lê do Vault quando existe
-- =========================================================================
select vault.create_secret('https://vault-proj.supabase.co/functions/v1/despachar', 'edge_function_url');
select vault.create_secret('https://vault-proj.supabase.co/functions/v1/enviar-email', 'email_function_url');

create temporary table reqs_791 (funcao text, req_id bigint) on commit drop;

insert into reqs_791 values
  ('despacho', privado.disparar_despacho()),
  ('email', privado.disparar_email());

select ok(req_id is not null, funcao || ': retorna id de requisição válido')
  from reqs_791 order by funcao;

select is(q.url, 'https://vault-proj.supabase.co/functions/v1/despachar',
          'despacho: lê URL de edge_function_url do Vault')
  from reqs_791 r join net.http_request_queue q on q.id = r.req_id
 where r.funcao = 'despacho';

select is(q.url, 'https://vault-proj.supabase.co/functions/v1/enviar-email',
          'email: lê URL de email_function_url do Vault')
  from reqs_791 r join net.http_request_queue q on q.id = r.req_id
 where r.funcao = 'email';

-- =========================================================================
-- 2. Precedência: Vault tem prioridade sobre GUC
-- =========================================================================
set local frila.edge_function_url = 'https://guc-ignorado.local/despachar';
set local frila.email_function_url = 'https://guc-ignorado.local/enviar-email';

truncate reqs_791;
delete from net.http_request_queue;

insert into reqs_791 values
  ('despacho', privado.disparar_despacho()),
  ('email', privado.disparar_email());

select is(q.url, 'https://vault-proj.supabase.co/functions/v1/despachar',
          'despacho: Vault tem precedência sobre GUC')
  from reqs_791 r join net.http_request_queue q on q.id = r.req_id
 where r.funcao = 'despacho';

select is(q.url, 'https://vault-proj.supabase.co/functions/v1/enviar-email',
          'email: Vault tem precedência sobre GUC')
  from reqs_791 r join net.http_request_queue q on q.id = r.req_id
 where r.funcao = 'email';

-- =========================================================================
-- 3. Fallback 1: Cai no GUC quando não existe no Vault
-- =========================================================================
delete from vault.secrets where name in ('edge_function_url', 'email_function_url');
set local frila.edge_function_url = 'https://guc-fallback.local/functions/v1/despachar';
set local frila.email_function_url = 'https://guc-fallback.local/functions/v1/enviar-email';

truncate reqs_791;
delete from net.http_request_queue;

insert into reqs_791 values
  ('despacho', privado.disparar_despacho()),
  ('email', privado.disparar_email());

select is(q.url, 'https://guc-fallback.local/functions/v1/despachar',
          'despacho: sem Vault, cai no fallback do GUC')
  from reqs_791 r join net.http_request_queue q on q.id = r.req_id
 where r.funcao = 'despacho';

select is(q.url, 'https://guc-fallback.local/functions/v1/enviar-email',
          'email: sem Vault, cai no fallback do GUC')
  from reqs_791 r join net.http_request_queue q on q.id = r.req_id
 where r.funcao = 'email';

-- =========================================================================
-- 4. Fallback 2: Cai no default estático quando nem Vault nem GUC existem
-- =========================================================================
set local frila.edge_function_url = '';
set local frila.email_function_url = '';

truncate reqs_791;
delete from net.http_request_queue;

insert into reqs_791 values
  ('despacho', privado.disparar_despacho()),
  ('email', privado.disparar_email());

select is(q.url, 'http://127.0.0.1:54321/functions/v1/despachar',
          'despacho: sem Vault e sem GUC, cai no default estático 127.0.0.1')
  from reqs_791 r join net.http_request_queue q on q.id = r.req_id
 where r.funcao = 'despacho';

select is(q.url, 'http://127.0.0.1:54321/functions/v1/enviar-email',
          'email: sem Vault e sem GUC, cai no default estático 127.0.0.1')
  from reqs_791 r join net.http_request_queue q on q.id = r.req_id
 where r.funcao = 'email';

-- =========================================================================
-- 5. Segurança: Não imprime URL com segredo em falhas
-- =========================================================================
-- URL que força erro de rede no net.http_post
set local frila.edge_function_url = 'http://[url-malformada-para-erro';
set local frila.email_function_url = 'http://[url-malformada-para-erro';

delete from privado.falha_execucao;

-- Despacho: captura erro de transporte e registra em privado.falha_execucao
select lives_ok(
  $$ select privado.disparar_despacho('a0000000-0000-4000-8000-000000000791'::uuid) $$,
  'despacho sob erro de rede não aborta transação'
);

select is(count(*)::int, 1, 'falha de transporte do despacho gravou exatamente 1 registro')
  from privado.falha_execucao
 where origem = 'despacho_imediato' and codigo = 'falha_transporte_pg_net';

-- Confere que NENHUM campo de falha_execucao vaza o segredo
select is(count(*)::int, 0, 'segredo do agendador NÃO aparece na tabela de falhas')
  from privado.falha_execucao
 where detalhes::text like '%segredo-sintetico-vault-791%'
    or codigo like '%segredo-sintetico-vault-791%';

-- E-mail: sob falha de transporte, não grava nada e devolve null
select is(privado.disparar_email(), null::bigint,
          'email sob erro de rede retorna null silenciosamente');

-- Confere que a mensagem segue na fila de e-mail íntegra
select is(count(*)::int, 1, 'mensagem de e-mail permanece íntegra na fila após falha de transporte')
  from pgmq.q_email;

-- Sem segredo: exceção do despacho não expõe URL nem dados sensíveis
set local frila.agendador_secret = '';
select throws_ok(
  $$ select privado.disparar_despacho() $$,
  'P0001',
  'Configuração frila.agendador_secret ausente no banco de dados',
  'despacho sem segredo lança exceção padronizada sem vazar URL'
);

select is(privado.disparar_email(), null::bigint,
          'email sem segredo retorna null');

-- =========================================================================
-- 6. Bloco DO idempotente via frila.project_ref
-- =========================================================================
-- 6.1 Execução sem parâmetro (ou com <ref>) não altera o Vault
set local frila.project_ref = '';
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

    select id into v_secret_id from vault.secrets where name = 'edge_function_url';
    if v_secret_id is not null then
      perform vault.update_secret(v_secret_id, v_url_despacho, 'edge_function_url', 'URL da Edge Function de despacho');
    else
      perform vault.create_secret(v_url_despacho, 'edge_function_url', 'URL da Edge Function de despacho');
    end if;

    select id into v_secret_id from vault.secrets where name = 'email_function_url';
    if v_secret_id is not null then
      perform vault.update_secret(v_secret_id, v_url_email, 'email_function_url', 'URL da Edge Function de e-mails transacionais');
    else
      perform vault.create_secret(v_url_email, 'email_function_url', 'URL da Edge Function de e-mails transacionais');
    end if;
  end if;
end $$;

select is(count(*)::int, 0, 'bloco DO sem frila.project_ref não cria segredos no Vault')
  from vault.secrets where name in ('edge_function_url', 'email_function_url');

-- 6.2 Execução com parâmetro cria os dois segredos
set local frila.project_ref = 'ref-teste-791';
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

    select id into v_secret_id from vault.secrets where name = 'edge_function_url';
    if v_secret_id is not null then
      perform vault.update_secret(v_secret_id, v_url_despacho, 'edge_function_url', 'URL da Edge Function de despacho');
    else
      perform vault.create_secret(v_url_despacho, 'edge_function_url', 'URL da Edge Function de despacho');
    end if;

    select id into v_secret_id from vault.secrets where name = 'email_function_url';
    if v_secret_id is not null then
      perform vault.update_secret(v_secret_id, v_url_email, 'email_function_url', 'URL da Edge Function de e-mails transacionais');
    else
      perform vault.create_secret(v_url_email, 'email_function_url', 'URL da Edge Function de e-mails transacionais');
    end if;
  end if;
end $$;

select is(decrypted_secret, 'https://ref-teste-791.supabase.co/functions/v1/despachar',
          'bloco DO cria edge_function_url no Vault com a project_ref informada')
  from vault.decrypted_secrets where name = 'edge_function_url';

select is(decrypted_secret, 'https://ref-teste-791.supabase.co/functions/v1/enviar-email',
          'bloco DO cria email_function_url no Vault com a project_ref informada')
  from vault.decrypted_secrets where name = 'email_function_url';

-- 6.3 Reexecução atualiza de forma idempotente sem duplicar
set local frila.project_ref = 'ref-atualizada-791';
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

    select id into v_secret_id from vault.secrets where name = 'edge_function_url';
    if v_secret_id is not null then
      perform vault.update_secret(v_secret_id, v_url_despacho, 'edge_function_url', 'URL da Edge Function de despacho');
    else
      perform vault.create_secret(v_url_despacho, 'edge_function_url', 'URL da Edge Function de despacho');
    end if;

    select id into v_secret_id from vault.secrets where name = 'email_function_url';
    if v_secret_id is not null then
      perform vault.update_secret(v_secret_id, v_url_email, 'email_function_url', 'URL da Edge Function de e-mails transacionais');
    else
      perform vault.create_secret(v_url_email, 'email_function_url', 'URL da Edge Function de e-mails transacionais');
    end if;
  end if;
end $$;

select is(decrypted_secret, 'https://ref-atualizada-791.supabase.co/functions/v1/despachar',
          'bloco DO atualiza edge_function_url de forma idempotente')
  from vault.decrypted_secrets where name = 'edge_function_url';

select is(decrypted_secret, 'https://ref-atualizada-791.supabase.co/functions/v1/enviar-email',
          'bloco DO atualiza email_function_url de forma idempotente')
  from vault.decrypted_secrets where name = 'email_function_url';

select is(count(*)::int, 2, 'Vault contém exatamente 2 segredos de URL sem duplicação')
  from vault.secrets where name in ('edge_function_url', 'email_function_url');

select * from finish();
rollback;
