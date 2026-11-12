-- ============================================================================
-- MODELO DE MIGRAÇÃO: DESLIGAR CASA DO PILOTO DO CHECK-IN POR CÓDIGO (RN46)
--
-- Rollback forward-only (migração linear):
--   1. Remove o estabelecimento de privado.recurso_estabelecimento.
--   2. A casa retorna imediatamente ao fluxo legado (geolocalizado automático <= 200 m).
--   3. Turnos em andamento com código pendente caem na contingência manual
--      (confirmar_checkin_manual).
-- ============================================================================

do $$
declare
  -- Substituir pelo UUID da casa a desativar:
  v_casa_id constant uuid := '00000000-0000-0000-0000-000000000000'::uuid;
  v_nome text;
begin
  select nome into v_nome
    from public.estabelecimento
   where id = v_casa_id;

  delete from privado.recurso_estabelecimento
   where chave = 'checkin_por_codigo'
     and estabelecimento_id = v_casa_id;

  raise notice 'Check-in por código desativado para a casa % (%). Retorno imediato ao fluxo legado.', coalesce(v_nome, 'desconhecida'), v_casa_id;
end $$;
