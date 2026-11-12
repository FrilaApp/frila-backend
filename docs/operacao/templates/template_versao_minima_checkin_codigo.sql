-- ============================================================================
-- MODELO DE MIGRAÇÃO: REGISTRO DE VERSÃO MÍNIMA DO APP (RN46)
--
-- Decisão de produto separada da habilitação de casas piloto:
--   1. Esta migração é aplicada UMA ÚNICA VEZ para todo o app no ecossistema.
--   2. Pré-requisitos mandatórios antes de aplicar:
--      a. Build 1.2.0 (ou superior) homologado e aprovado na App Store.
--      b. Bloco H da Política de Privacidade publicado em frilabr.com/privacidade.
--   3. Efeito: public.configuracao_do_app passa a responder checkin_por_codigo = true
--      para dispositivos na plataforma e versão informadas.
--   4. NÃO inclui estabelecimentos em privado.recurso_estabelecimento (isso é feito
--      casa por casa via template_ligar_casa_checkin_codigo.sql).
-- ============================================================================

do $$
declare
  v_recurso constant text := 'checkin_por_codigo';
  v_plataforma constant text := 'ios';
  v_versao_minima constant text := '1.2.0';
begin
  insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
  values (v_recurso, v_plataforma, v_versao_minima)
  on conflict (recurso, plataforma)
  do update set versao_minima = excluded.versao_minima;

  raise notice 'Versão mínima para o recurso % na plataforma % definida como %',
    v_recurso, v_plataforma, v_versao_minima;
end $$;
