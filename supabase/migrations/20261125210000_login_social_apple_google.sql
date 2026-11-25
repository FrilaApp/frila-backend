-- Fundação server-side de login social Apple e Google (contrato 0.2.117).
--
-- Mantém modo sombra (privado.config_auth.exigir_dispositivo_verificado permanece inalterado).
-- 1. Atualiza privado.usuario_precisa_definir_senha() para NÃO exigir senha de contas que possuam
--    identidade social ativa (apple/google) em auth.identities quando não há pendência explícita em
--    privado.contas_senha_pendente. Contas legadas OTP-only sem identidade social continuam exigindo
--    senha sob enforcement.
-- 2. Cria privado.concluir_login_social(p_usuario_id, p_session_id, p_provedor) para validar a
--    identidade social no servidor e registrar a sessão em privado.sessoes_verificadas (sujeita a
--    revogação online imediata por privado.revogar_todos_dispositivos). Bypass direto no GoTrue sem
--    passar por esta função não grava sessoes_verificadas e é bloqueado sob enforcement.

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

create or replace function privado.concluir_login_social(
  p_usuario_id uuid,
  p_session_id uuid,
  p_provedor   text
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_tem_identidade boolean;
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

  insert into privado.sessoes_verificadas (session_id, usuario_id, dispositivo_id)
  values (p_session_id, p_usuario_id, null)
  on conflict (session_id) do nothing;

  return jsonb_build_object(
    'ok', true,
    'precisa_definir_senha', privado.usuario_precisa_definir_senha(p_usuario_id, p_session_id)
  );
end $$;

revoke execute on function privado.concluir_login_social(uuid, uuid, text) from public, anon, authenticated;
