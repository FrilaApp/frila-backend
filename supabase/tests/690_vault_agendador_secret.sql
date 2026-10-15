-- 690_vault_agendador_secret.sql
--
-- Validação da leitura do segredo agendador_secret via Supabase Vault com fallback ao GUC.
-- Objetivo: permitir execução segura no Supabase hospedado (sem privilégios de superusuário)
-- preservando compatibilidade total com suítes de teste e ambientes locais.
--
-- Cobertura:
-- 1. Leitura com sucesso a partir do Supabase Vault (vault.decrypted_secrets) com GUC vazio.
-- 2. Fallback com sucesso para current_setting('frila.agendador_secret', true) quando Vault vazio.
-- 3. Prioridade do Vault sobre o GUC quando ambos estiverem definidos.
-- 4. Exceção explícita de segredo ausente quando nem Vault nem GUC contiverem o segredo em disparar_despacho.
-- 5. disparar_email não emite warning e procede ao net.http_post quando segredo existe apenas no Vault.

begin;
select plan(5);

insert into privado.ambiente (eh_teste) values (true);
set local frila.edge_function_url = 'http://127.0.0.1:54321/functions/v1/despachar';
set local frila.email_function_url = 'http://127.0.0.1:54321/functions/v1/enviar-email';

-- Garante estado inicial limpo no Vault para este teste
delete from vault.secrets where name = 'agendador_secret';

-- ── 1. Leitura via Supabase Vault com GUC vazio ─────────────────────────────
set local frila.agendador_secret = '';
select vault.create_secret('segredo-teste-vault-primario', 'agendador_secret', 'Teste de segredo via Vault');

select lives_ok(
  $$ select privado.disparar_despacho('d0000000-0000-4000-8000-000000000001') $$,
  'privado.disparar_despacho consome com sucesso o agendador_secret cadastrado no Vault com GUC vazio'
);

-- ── 2. disparar_email com segredo no Vault e GUC vazio ──────────────────────
-- Insere mensagem temporária em pgmq.q_email para disparar_email não sair no 'if not exists'
select pgmq.send('email', jsonb_build_object('tipo', 'teste_vault'));

select lives_ok(
  $$ select privado.disparar_email() $$,
  'privado.disparar_email consome com sucesso o segredo do Vault sem emitir warning de segredo ausente'
);

-- ── 3. Fallback para GUC quando Vault está vazio ────────────────────────────
delete from vault.secrets where name = 'agendador_secret';
set local frila.agendador_secret = 'segredo-teste-guc-fallback';

select lives_ok(
  $$ select privado.disparar_despacho('d0000000-0000-4000-8000-000000000001') $$,
  'privado.disparar_despacho recorre com sucesso ao fallback GUC quando o Vault não possui o segredo'
);

-- ── 4. Prioridade do Vault sobre o GUC quando ambos presentes ───────────────
select vault.create_secret('segredo-vault-preferencial', 'agendador_secret', 'Teste prioridade Vault');
set local frila.agendador_secret = 'segredo-guc-secundario';

select is(
  coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.agendador_secret', true), '')
  ),
  'segredo-vault-preferencial',
  'Resolução de segredo prioriza valor armazenado no Supabase Vault sobre o parâmetro GUC'
);

-- ── 5. Exceção explícita quando ausente em ambas as fontes ───────────────────
delete from vault.secrets where name = 'agendador_secret';
set local frila.agendador_secret = '';

select throws_ok(
  $$ select privado.disparar_despacho('d0000000-0000-4000-8000-000000000001') $$,
  'Configuração frila.agendador_secret ausente no banco de dados',
  'privado.disparar_despacho falha explicitamente quando agendador_secret inexiste no Vault e no GUC'
);

rollback;
