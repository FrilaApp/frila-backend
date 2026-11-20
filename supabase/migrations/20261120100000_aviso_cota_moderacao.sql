-- Aviso de cota mensal da moderação de mídia (cartão yPhXgTCY).
--
-- A reserva de uma chamada ao provedor deixa de ser SQL solto na Edge Function e passa a ser
-- privado.reservar_chamada_moderacao: confere o teto do mês e o limite por foto, grava o consumo e
-- decide, na mesma transação e sob a mesma trava, se esta reserva deve avisar que o consumo chegou
-- a 80% do teto. A marca (provedor, mês, limiar) em privado.moderacao_aviso_cota garante um único
-- aviso por mês e por limiar, mesmo que o teto mude no meio do mês ou que uma reserva seja devolvida
-- e o consumo cruze o limiar outra vez.
--
-- Aditiva: a tabela privado.moderacao_chamada não muda. A trava é a mesma da Edge Function atual
-- (hashtext('moderacao_chamada')), então uma versão antiga da função e a nova se serializam.

select set_config('lock_timeout', '2s', true);

create table privado.moderacao_aviso_cota (
  provedor          text not null,
  mes               text not null,
  limiar_percentual smallint not null constraint moderacao_aviso_cota_limiar_valido
                      check (limiar_percentual between 1 and 100),
  criado_em         timestamptz not null default privado.agora(),

  primary key (provedor, mes, limiar_percentual)
);

comment on table privado.moderacao_aviso_cota is
  'Marca de que o aviso de cota mensal da moderação de mídia já saiu para o provedor, o mês e o limiar. Uma linha por mês e por limiar; nunca é apagada pela moderação.';
comment on column privado.moderacao_aviso_cota.limiar_percentual is
  'Percentual do teto mensal que disparou o aviso (hoje só 80).';

alter table privado.moderacao_aviso_cota enable row level security;
revoke all on table privado.moderacao_aviso_cota from public, anon, authenticated, service_role;

create function privado.reservar_chamada_moderacao(
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
  v_marcas     integer;
begin
  if p_teto_mensal is null or p_maximo_por_foto is null or p_limiar_percentual is null then
    raise exception 'parametro_nulo' using errcode = '22004';
  end if;

  -- Mesma trava da versão da Edge Function que fazia isto em SQL solto: a conta, o insert e a marca
  -- de aviso acontecem uma reserva por vez.
  perform pg_advisory_xact_lock(hashtext('moderacao_chamada'));

  select count(*)::integer into v_mes_total
    from privado.moderacao_chamada
   where mes = p_mes and provedor = p_provedor;
  if v_mes_total >= p_teto_mensal then
    return query select 'teto_mensal'::text, v_mes_total, false;
    return;
  end if;

  select count(*)::integer into v_foto_total
    from privado.moderacao_chamada
   where midia_id = p_midia_id;
  if v_foto_total >= p_maximo_por_foto then
    return query select 'limite_foto'::text, v_mes_total, false;
    return;
  end if;

  insert into privado.moderacao_chamada (midia_id, provedor, mes)
  values (p_midia_id, p_provedor, p_mes);
  v_mes_total := v_mes_total + 1;

  -- O aviso sai quando o consumo está no limiar ou acima dele E a marca ainda não existe. Comparar com
  -- >= (e não com igualdade) é o que faz um teto reduzido no meio do mês avisar; a marca é o que
  -- impede o segundo aviso. O INSERT ... ON CONFLICT e a conta estão na mesma trava.
  v_limiar := ceil(p_teto_mensal::numeric * p_limiar_percentual / 100)::integer;
  if v_mes_total >= v_limiar then
    insert into privado.moderacao_aviso_cota (provedor, mes, limiar_percentual)
    values (p_provedor, p_mes, p_limiar_percentual)
    on conflict do nothing;
    get diagnostics v_marcas = row_count;
    return query select 'ok'::text, v_mes_total, v_marcas = 1;
    return;
  end if;

  return query select 'ok'::text, v_mes_total, false;
end $$;

comment on function privado.reservar_chamada_moderacao(uuid, text, text, integer, integer, integer) is
  'Reserva de forma atômica uma chamada ao provedor de moderação: devolve ok, teto_mensal ou limite_foto, o consumo do mês depois da reserva e se esta reserva deve emitir o aviso de cota (consumo no limiar ou acima, marca ainda não gravada). Só o service_role executa.';

revoke all on function privado.reservar_chamada_moderacao(uuid, text, text, integer, integer, integer)
  from public, anon, authenticated;
grant execute on function privado.reservar_chamada_moderacao(uuid, text, text, integer, integer, integer)
  to service_role;
