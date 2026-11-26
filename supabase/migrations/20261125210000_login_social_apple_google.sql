-- Fundação server-side de login social Apple e Google (contrato 0.2.117).
--
-- Mantém modo sombra (privado.config_auth.exigir_dispositivo_verificado permanece inalterado).
-- 1. privado.transacoes_oauth_social: vincula atomicamente (transacao_id, provedor,
--    code_challenge_hash, callback_url) com TTL de 10 min e consumo de uso único. Na troca PKCE,
--    privado.consumir_transacao_oauth_social confere também auth.flow_state (auth_code,
--    provider_type, code_challenge, code_challenge_method='s256') no banco do GoTrue ANTES de
--    chamar /auth/v1/token?grant_type=pkce, impedindo substituição do código via /authorize público
--    em contas multivinculadas Apple+Google.
-- 2. privado.tokens_sociais_consumidos: registra apenas o hash SHA-256 canônico (nunca token bruto)
--    de id_tokens já validados pelo GoTrue para proteção atômica contra replay.
-- 3. privado.limpar_artefatos_login_social_expirados(): limpeza limitada de linhas expiradas há
--    mais de 1 hora (margem de segurança contra remoção prematura).
-- 4. privado.usuario_precisa_definir_senha(): isenta contas com identidade social ativa
--    (apple/google) quando não há pendência explícita em privado.contas_senha_pendente.
-- 5. privado.concluir_login_social(): comprova identidade social, aplica proteção atômica contra
--    replay de id_token (quando informado) e grava privado.sessoes_verificadas (revogável online).

create table if not exists privado.transacoes_oauth_social (
  id                  uuid primary key default gen_random_uuid(),
  provedor            text not null check (provedor in ('apple', 'google')),
  plataforma          text not null check (plataforma in ('ios', 'android', 'web')),
  code_challenge_hash text not null unique,
  callback_url        text not null check (char_length(callback_url) between 8 and 512),
  criada_em           timestamptz not null default privado.agora(),
  expira_em           timestamptz not null,
  consumida_em        timestamptz
);

create index if not exists idx_transacoes_oauth_social_expira
  on privado.transacoes_oauth_social (expira_em)
  where consumida_em is null;

create table if not exists privado.tokens_sociais_consumidos (
  token_hash   text primary key check (char_length(token_hash) = 64),
  provedor     text not null check (provedor in ('apple', 'google')),
  usuario_id   uuid not null references auth.users (id) on delete cascade,
  consumido_em timestamptz not null default privado.agora(),
  expira_em    timestamptz not null
);

create index if not exists idx_tokens_sociais_consumidos_expira
  on privado.tokens_sociais_consumidos (expira_em);

revoke all on table privado.transacoes_oauth_social from public, anon, authenticated;
revoke all on table privado.tokens_sociais_consumidos from public, anon, authenticated;

alter table privado.transacoes_oauth_social enable row level security;
alter table privado.tokens_sociais_consumidos enable row level security;

create or replace function privado.usuario_precisa_definir_senha(
  p_usuario_id uuid,
  p_session_id uuid default null
)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select case
    when privado.eh_conta_demonstracao_auth(p_usuario_id) then false
    when exists (
      select 1 from privado.contas_senha_pendente p where p.usuario_id = p_usuario_id
    ) then true
    when privado.sessao_eh_pre_corte(p_session_id, p_usuario_id) then false
    when not privado.exigir_dispositivo_verificado_ativo() then false
    when exists (
      select 1
        from auth.identities ai
       where ai.user_id = p_usuario_id
         and ai.provider in ('apple', 'google')
    ) then false
    else exists (
      select 1
        from auth.users au
       where au.id = p_usuario_id
         and coalesce(au.encrypted_password, '') = ''
    )
  end
$$;

revoke execute on function privado.usuario_precisa_definir_senha(uuid, uuid) from public, anon, authenticated;

create or replace function privado.criar_transacao_oauth_social(
  p_provedor            text,
  p_plataforma          text,
  p_code_challenge_hash text,
  p_callback_url        text
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora  timestamptz := privado.agora();
  v_expira timestamptz := v_agora + interval '10 minutes';
  v_id     uuid;
begin
  if p_provedor not in ('apple', 'google')
     or p_plataforma not in ('ios', 'android', 'web')
     or p_code_challenge_hash is null
     or char_length(p_code_challenge_hash) <> 64
     or p_callback_url is null
     or char_length(p_callback_url) < 8 then
    return jsonb_build_object('ok', false, 'motivo', 'parametro_invalido');
  end if;

  insert into privado.transacoes_oauth_social (
    provedor, plataforma, code_challenge_hash, callback_url, criada_em, expira_em
  )
  values (p_provedor, p_plataforma, p_code_challenge_hash, p_callback_url, v_agora, v_expira)
  on conflict (code_challenge_hash) do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('ok', false, 'motivo', 'desafio_ja_usado');
  end if;

  return jsonb_build_object(
    'ok', true,
    'transacao_id', v_id,
    'expira_em', v_expira
  );
end $$;

revoke execute on function privado.criar_transacao_oauth_social(text, text, text, text) from public, anon, authenticated;

-- Consome atomicamente a transação OAuth PKCE exigindo correspondência exata de:
-- (a) transação server-side (transacao_id, provedor, code_challenge_hash) não consumida e válida;
-- (b) estado autoritativo do GoTrue em auth.flow_state (auth_code, provider_type, code_challenge,
--     code_challenge_method = 's256') ANTES de trocar o código no GoTrue.
-- Fecha substituição de código emitido por /auth/v1/authorize público com outro provider usando o
-- mesmo code_challenge em contas multivinculadas Apple+Google.
create or replace function privado.consumir_transacao_oauth_social(
  p_transacao_id        uuid,
  p_provedor            text,
  p_code_challenge_hash text,
  p_auth_code           text,
  p_code_challenge      text
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora               timestamptz := privado.agora();
  v_row                 privado.transacoes_oauth_social%rowtype;
  v_flow_provider_type  text;
  v_flow_code_challenge text;
  v_flow_method         text;
begin
  if p_transacao_id is null
     or p_provedor not in ('apple', 'google')
     or p_code_challenge_hash is null
     or char_length(p_code_challenge_hash) <> 64
     or p_auth_code is null
     or btrim(p_auth_code) = ''
     or p_code_challenge is null
     or char_length(p_code_challenge) <> 43 then
    return jsonb_build_object('ok', false, 'motivo', 'transacao_invalida');
  end if;

  select *
    into v_row
    from privado.transacoes_oauth_social t
   where t.id = p_transacao_id
     for update;

  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'transacao_invalida');
  end if;

  if v_row.consumida_em is not null then
    return jsonb_build_object('ok', false, 'motivo', 'desafio_ja_usado');
  end if;

  if v_row.expira_em <= v_agora then
    return jsonb_build_object('ok', false, 'motivo', 'desafio_expirado');
  end if;

  if v_row.provedor <> p_provedor or v_row.code_challenge_hash <> p_code_challenge_hash then
    return jsonb_build_object('ok', false, 'motivo', 'provedor_divergente');
  end if;

  select fs.provider_type, fs.code_challenge, fs.code_challenge_method::text
    into v_flow_provider_type, v_flow_code_challenge, v_flow_method
    from auth.flow_state fs
   where fs.auth_code = p_auth_code
   limit 1;

  if not found then
    return jsonb_build_object('ok', false, 'motivo', 'transacao_invalida');
  end if;

  if v_flow_provider_type <> p_provedor
     or v_flow_code_challenge <> p_code_challenge
     or v_flow_method <> 's256' then
    return jsonb_build_object('ok', false, 'motivo', 'provedor_divergente');
  end if;

  update privado.transacoes_oauth_social
     set consumida_em = v_agora
   where id = v_row.id;

  return jsonb_build_object('ok', true, 'provedor', v_row.provedor);
end $$;

revoke execute on function privado.consumir_transacao_oauth_social(uuid, text, text, text, text) from public, anon, authenticated;

-- Limpeza limitada de transações PKCE e hashes de id_token expirados há mais de 1 hora
-- (margem de 1h impede remoção prematura antes do término da janela efetiva de replay).
create or replace function privado.limpar_artefatos_login_social_expirados(
  p_limite integer default 500
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_corte    timestamptz := privado.agora() - interval '1 hour';
  v_lim      integer := least(greatest(coalesce(p_limite, 500), 1), 5000);
  v_tx_apag  integer := 0;
  v_tok_apag integer := 0;
begin
  with alvo as (
    select id
      from privado.transacoes_oauth_social
     where expira_em < v_corte
     order by expira_em asc
     limit v_lim
  ),
  del as (
    delete from privado.transacoes_oauth_social t
     using alvo a
     where t.id = a.id
    returning 1
  )
  select count(*)::integer into v_tx_apag from del;

  with alvo as (
    select token_hash
      from privado.tokens_sociais_consumidos
     where expira_em < v_corte
     order by expira_em asc
     limit v_lim
  ),
  del as (
    delete from privado.tokens_sociais_consumidos t
     using alvo a
     where t.token_hash = a.token_hash
    returning 1
  )
  select count(*)::integer into v_tok_apag from del;

  return jsonb_build_object(
    'transacoes_removidas', v_tx_apag,
    'tokens_removidos', v_tok_apag
  );
end $$;

revoke execute on function privado.limpar_artefatos_login_social_expirados(integer) from public, anon, authenticated;

create or replace function privado.concluir_login_social(
  p_usuario_id        uuid,
  p_session_id        uuid,
  p_provedor          text,
  p_id_token_hash     text default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora          timestamptz := privado.agora();
  v_tem_identidade boolean;
  v_token_gravado  text;
begin
  if p_usuario_id is null or p_session_id is null or p_provedor not in ('apple', 'google') then
    return jsonb_build_object('ok', false, 'motivo', 'parametro_invalido');
  end if;

  if exists (
    select 1 from public.usuario u where u.id = p_usuario_id and u.estado = 'anonimizada'
  ) then
    return jsonb_build_object('ok', false, 'motivo', 'conta_anonimizada');
  end if;

  select exists (
    select 1
      from auth.identities ai
     where ai.user_id = p_usuario_id
       and ai.provider = p_provedor
  ) into v_tem_identidade;

  if not v_tem_identidade then
    return jsonb_build_object('ok', false, 'motivo', 'identidade_social_ausente');
  end if;

  -- Proteção atômica contra replay de id_token (nunca persiste token bruto; apenas hash de 64 hex).
  if p_id_token_hash is not null then
    if char_length(p_id_token_hash) <> 64 then
      return jsonb_build_object('ok', false, 'motivo', 'parametro_invalido');
    end if;

    insert into privado.tokens_sociais_consumidos (token_hash, provedor, usuario_id, consumido_em, expira_em)
    values (p_id_token_hash, p_provedor, p_usuario_id, v_agora, v_agora + interval '24 hours')
    on conflict (token_hash) do nothing
    returning token_hash into v_token_gravado;

    if v_token_gravado is null then
      return jsonb_build_object('ok', false, 'motivo', 'token_ja_usado');
    end if;
  end if;

  insert into privado.sessoes_verificadas (session_id, usuario_id, dispositivo_id)
  values (p_session_id, p_usuario_id, null)
  on conflict (session_id) do nothing;

  return jsonb_build_object(
    'ok', true,
    'precisa_definir_senha', privado.usuario_precisa_definir_senha(p_usuario_id, p_session_id)
  );
end $$;

revoke execute on function privado.concluir_login_social(uuid, uuid, text, text) from public, anon, authenticated;
