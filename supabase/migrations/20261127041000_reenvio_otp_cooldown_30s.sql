-- Torna o cooldown mínimo de reenvio OTP do desafio `login_dispositivo` configurável em
-- `privado.config_auth` (default seguro 60s, reduzível para 30s somente após alinhamento de
-- `max_frequency` no Supabase Auth do ambiente), preservando teto de 3 reenvios por desafio,
-- expiração de 10 minutos, reserva atômica pré-fetch e todas as guardas de rate limit/anti-replay.

alter table privado.config_auth
  add column if not exists cooldown_reenvio_otp_segundos integer not null default 60
  check (cooldown_reenvio_otp_segundos in (30, 60));

create or replace function privado.reservar_reenvio_desafio(
  p_desafio_id uuid
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora      timestamptz := privado.agora();
  v_nova_exp   timestamptz := v_agora + interval '10 minutes';
  v_cooldown   integer     := 60;
  v_row        privado.desafios_dispositivo%rowtype;
begin
  select coalesce(c.cooldown_reenvio_otp_segundos, 60)
    into v_cooldown
    from privado.config_auth c
   where c.id = 1;

  v_cooldown := case when v_cooldown in (30, 60) then v_cooldown else 60 end;

  -- Mantém o mesmo desafio_id e NÃO incrementa tentativas de verificação OTP.
  -- Exige cooldown mínimo configurável (default 60s, mínimo 30s) e teto de 3 reenvios por desafio.
  update privado.desafios_dispositivo
     set reenvios          = reenvios + 1,
         ultimo_reenvio_em = v_agora,
         expira_em         = v_nova_exp
   where id = p_desafio_id
     and usado_em is null
     and expira_em > v_agora
     and reenvios < 3
     and coalesce(ultimo_reenvio_em, criado_em) <= v_agora - make_interval(secs => v_cooldown)
  returning * into v_row;

  if found then
    return jsonb_build_object(
      'status',            'ok',
      'desafio_id',        v_row.id,
      'email_normalizado', v_row.email_normalizado,
      'email_hash',        v_row.email_hash,
      'expira_em',         v_row.expira_em,
      'cooldown_segundos', v_cooldown
    );
  end if;

  select * into v_row from privado.desafios_dispositivo where id = p_desafio_id;
  if not found or v_row.expira_em <= v_agora then
    return jsonb_build_object('status', 'desafio_expirado');
  end if;
  if v_row.usado_em is not null then
    return jsonb_build_object('status', 'desafio_ja_usado');
  end if;
  return jsonb_build_object('status', 'limite_excedido');
end $$;

revoke execute on function privado.reservar_reenvio_desafio(uuid) from public, anon, authenticated;
