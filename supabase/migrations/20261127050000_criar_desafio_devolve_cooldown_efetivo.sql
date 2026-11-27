-- Propaga o cooldown efetivo (`privado.config_auth.cooldown_reenvio_otp_segundos`, default 60s,
-- permitido apenas 30 ou 60) já na criação do desafio OTP (`privado.criar_desafio_dispositivo`),
-- permitindo que `POST /functions/v1/autenticar-senha` devolva o campo opcional `reenviar_em_segundos`
-- sem nunca inventar 30s antes da configuração do ambiente.

create or replace function privado.criar_desafio_dispositivo(
  p_usuario_id uuid,
  p_email      text,
  p_email_hash text,
  p_plataforma text
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora    timestamptz := privado.agora();
  v_expira   timestamptz := v_agora + interval '10 minutes';
  v_cooldown integer     := 60;
  v_id       uuid;
begin
  select coalesce(c.cooldown_reenvio_otp_segundos, 60)
    into v_cooldown
    from privado.config_auth c
   where c.unica = true;

  v_cooldown := case when v_cooldown in (30, 60) then v_cooldown else 60 end;

  insert into privado.desafios_dispositivo (
    usuario_id, email_normalizado, email_hash, plataforma, criado_em, expira_em
  )
  values (
    p_usuario_id, lower(btrim(p_email)), p_email_hash, p_plataforma, v_agora, v_expira
  )
  returning id into v_id;

  return jsonb_build_object(
    'desafio_id',        v_id,
    'expira_em',         v_expira,
    'cooldown_segundos', v_cooldown
  );
end $$;

revoke execute on function privado.criar_desafio_dispositivo(uuid, text, text, text) from public, anon, authenticated;
