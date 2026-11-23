-- Aviso de cota mensal da moderação de mídia com entrega durável e retentativa (B-080).
--
-- Corrige a marca de aviso de cota mensal (80%):
-- 1. Cria as colunas tentativa_em e emitido_em em privado.moderacao_aviso_cota, permitindo lease
--    de envio. Marcas já existentes são consideradas emitidas para evitar repetição de aviso.
-- 2. Valida p_limiar_percentual na entrada de privado.reservar_chamada_moderacao (1..100).
-- 3. Caso o aviso não seja confirmado pela Edge Function, uma nova reserva após 5 minutos tenta
--    emitir o aviso novamente (pelo menos uma vez, com retentativa após 5 min), mesmo se a reserva
--    for barrada por teto mensal ou limite por foto.
-- 4. Introduz privado.confirmar_aviso_cota_moderacao para confirmação após o envio bem-sucedido.

select set_config('lock_timeout', '2s', true);

alter table privado.moderacao_aviso_cota
  add column tentativa_em timestamptz,
  add column emitido_em timestamptz;

update privado.moderacao_aviso_cota
   set tentativa_em = criado_em,
       emitido_em = criado_em
 where emitido_em is null;

comment on column privado.moderacao_aviso_cota.tentativa_em is
  'Momento da tentativa mais recente de emissão do aviso de cota.';
comment on column privado.moderacao_aviso_cota.emitido_em is
  'Momento em que a Edge Function confirmou a emissão do aviso. Nulo enquanto pendente de confirmação.';

create or replace function privado.reservar_chamada_moderacao(
  p_midia_id          uuid,
  p_provedor          text,
  p_mes               text,
  p_teto_mensal       integer,
  p_maximo_por_foto   integer,
  p_limiar_percentual integer default 80
)
returns table (resultado text, consumo_mes integer, avisar_cota boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_mes_total  integer;
  v_foto_total integer;
  v_limiar     integer;
  v_linhas     integer;
  v_reenviar   boolean := false;
begin
  if p_teto_mensal is null or p_maximo_por_foto is null or p_limiar_percentual is null then
    raise exception 'parametro_nulo' using errcode = '22004';
  end if;

  if p_limiar_percentual < 1 or p_limiar_percentual > 100 then
    raise exception 'limiar_invalido' using errcode = '22023';
  end if;

  -- Mesma trava da versão da Edge Function que fazia isto em SQL solto: a conta, o insert e a marca
  -- de aviso acontecem uma reserva por vez.
  perform pg_advisory_xact_lock(hashtext('moderacao_chamada'));

  -- Retentativa de aviso de cota com lease vencido (> 5 minutos) e ainda não confirmado.
  -- Roda antes das checagens de teto e limite por foto para que a pendência seja despachada
  -- mesmo que a cota do mês ou da foto já esteja esgotada (B-080 ajuste 2).
  update privado.moderacao_aviso_cota
     set tentativa_em = privado.agora()
   where provedor = p_provedor
     and mes = p_mes
     and limiar_percentual = p_limiar_percentual
     and emitido_em is null
     and tentativa_em < privado.agora() - interval '5 minutes';
  get diagnostics v_linhas = row_count;
  v_reenviar := (v_linhas = 1);

  select count(*)::integer into v_mes_total
    from privado.moderacao_chamada
   where mes = p_mes and provedor = p_provedor;
  if v_mes_total >= p_teto_mensal then
    return query select 'teto_mensal'::text, v_mes_total, v_reenviar;
    return;
  end if;

  select count(*)::integer into v_foto_total
    from privado.moderacao_chamada
   where midia_id = p_midia_id;
  if v_foto_total >= p_maximo_por_foto then
    return query select 'limite_foto'::text, v_mes_total, v_reenviar;
    return;
  end if;

  insert into privado.moderacao_chamada (midia_id, provedor, mes)
  values (p_midia_id, p_provedor, p_mes);
  v_mes_total := v_mes_total + 1;

  -- O aviso sai quando o consumo está no limiar ou acima dele.
  -- Mecanismo de lease: grava tentativa_em = privado.agora() e emitido_em = null.
  -- Se inseriu (row_count = 1), devolve avisar_cota = true.
  -- Se não inseriu (marca já existia), devolve avisar_cota = v_reenviar (atualizado no início da função).
  -- Dentro de 5 minutos não repete (duas reservas concorrentes continuam dando um único aviso).
  v_limiar := ceil(p_teto_mensal::numeric * p_limiar_percentual / 100)::integer;
  if v_mes_total >= v_limiar then
    insert into privado.moderacao_aviso_cota (provedor, mes, limiar_percentual, tentativa_em, emitido_em)
    values (p_provedor, p_mes, p_limiar_percentual, privado.agora(), null)
    on conflict do nothing;
    get diagnostics v_linhas = row_count;
    if v_linhas = 1 then
      return query select 'ok'::text, v_mes_total, true;
      return;
    end if;

    return query select 'ok'::text, v_mes_total, v_reenviar;
    return;
  end if;

  return query select 'ok'::text, v_mes_total, v_reenviar;
end $$;

comment on function privado.reservar_chamada_moderacao(uuid, text, text, integer, integer, integer) is
  'Reserva de forma atômica uma chamada ao provedor de moderação: devolve ok, teto_mensal ou limite_foto, o consumo do mês depois da reserva e se esta reserva deve emitir o aviso de cota (consumo no limiar ou acima, marca ainda não gravada ou pendente após 5 min, mesmo em retornos de teto ou limite por foto). Pelo menos uma vez, com retentativa após 5 min. Só o service_role executa.';

create or replace function privado.confirmar_aviso_cota_moderacao(
  p_provedor          text,
  p_mes               text,
  p_limiar_percentual integer
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update privado.moderacao_aviso_cota
     set emitido_em = privado.agora()
   where provedor = p_provedor
     and mes = p_mes
     and limiar_percentual = p_limiar_percentual
     and emitido_em is null;
  return found;
end $$;

comment on function privado.confirmar_aviso_cota_moderacao(text, text, integer) is
  'Confirma a emissão do aviso de cota mensal da moderação de mídia, gravando emitido_em. Devolve se a marca pendente foi confirmada. Pelo menos uma vez, com retentativa após 5 min. Só o service_role executa.';

revoke all on function privado.reservar_chamada_moderacao(uuid, text, text, integer, integer, integer)
  from public, anon, authenticated;
grant execute on function privado.reservar_chamada_moderacao(uuid, text, text, integer, integer, integer)
  to service_role;

revoke all on function privado.confirmar_aviso_cota_moderacao(text, text, integer)
  from public, anon, authenticated;
grant execute on function privado.confirmar_aviso_cota_moderacao(text, text, integer)
  to service_role;
