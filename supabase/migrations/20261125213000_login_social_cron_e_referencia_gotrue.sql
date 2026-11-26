-- Hardening operacional da fundação de login social Apple e Google (delta pós-#635 79bfa627).
--
-- 1. Agenda a limpeza limitada de transações PKCE e hashes de id_token expirados há mais de 1 hora
--    no padrão pg_cron do repositório (`17 * * * *`, máximo 500 linhas por execução, preservando
--    margem de 1h pós-expiração para nunca apagar entradas antes do fim da janela efetiva de replay).
-- 2. Fixa nos comentários de catálogo as referências primárias da tabela `auth.flow_state` na
--    versão suportada do GoTrue (`supabase/auth` empacotado pela Supabase CLI 2.121.0 usada em CI;
--    migrações primárias: `20230322519590_add_flow_state_table`,
--    `20230914180801_add_mfa_amr_claims_and_flow_state` e
--    `20240214120130_add_auth_code_issued_at`).
--
-- Mantém modo sombra (privado.config_auth.exigir_dispositivo_verificado permanece inalterado).
-- Volta: select cron.unschedule('limpar_artefatos_login_social_expirados').

select set_config('lock_timeout', '2s', true);

comment on function privado.consumir_transacao_oauth_social(uuid, text, text, text, text) is
  'Consome atomicamente a transação PKCE e valida auth.flow_state (auth_code, provider_type, code_challenge, code_challenge_method=s256) antes de chamar /auth/v1/token?grant_type=pkce. Referência primária GoTrue (github.com/supabase/auth, CLI 2.121.0): migrações 20230322519590_add_flow_state_table, 20230914180801_add_mfa_amr_claims_and_flow_state e 20240214120130_add_auth_code_issued_at.';

comment on function privado.limpar_artefatos_login_social_expirados(integer) is
  'Limpeza limitada (default 500, teto 5000) de privado.transacoes_oauth_social e privado.tokens_sociais_consumidos expirados há mais de 1 hora (margem de segurança de 1h). Ownership: backend auth; frequência: horária no pg_cron (minuto 17, 17 * * * *).';

-- Horária no minuto 17, fora das faixas de outros jobs de limpeza.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('limpar_artefatos_login_social_expirados')
      where exists (select 1 from cron.job where jobname = 'limpar_artefatos_login_social_expirados');
    perform cron.schedule(
      'limpar_artefatos_login_social_expirados',
      '17 * * * *',
      'select privado.limpar_artefatos_login_social_expirados()'
    );
  end if;
end $$;
