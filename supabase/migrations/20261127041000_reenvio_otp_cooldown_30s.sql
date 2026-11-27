-- Reduz cooldown mínimo de reenvio OTP do desafio `login_dispositivo` de 60s para 30s,
-- preservando o teto de 3 reenvios por desafio, expiração de 10 minutos e todas as
-- guardas de rate limit (IP/e-mail) e anti-replay.

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
  v_row        privado.desafios_dispositivo%rowtype;
begin
  -- Mantém o mesmo desafio_id e NÃO incrementa tentativas de verificação OTP.
  -- Exige cooldown mínimo de 30s entre reenvios e teto de 3 reenvios por desafio.
  update privado.desafios_dispositivo
     set reenvios          = reenvios + 1,
         ultimo_reenvio_em = v_agora,
         expira_em         = v_nova_exp
   where id = p_desafio_id
     and usado_em is null
     and expira_em > v_agora
     and reenvios < 3
     and coalesce(ultimo_reenvio_em, criado_em) <= v_agora - interval '30 seconds'
  returning * into v_row;

  if found then
    return jsonb_build_object(
      'status',            'ok',
      'desafio_id',        v_row.id,
      'email_normalizado', v_row.email_normalizado,
      'email_hash',        v_row.email_hash,
      'expira_em',         v_row.expira_em
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
