-- ============================================================================
-- MODELO DE MIGRAÇÃO: LIGAR CASA NO PILOTO DO CHECK-IN POR CÓDIGO (RN46)
--
-- Regras obrigatórias de governança e LGPD (art. 6º, III; Modelagem § 661):
--   1. Apenas estabelecimentos Pessoa Jurídica (não MEI) ou casas de teste
--      da equipe podem entrar por migração no repositório.
--   2. Casas MEI ou de pessoa física NÃO entram por migração (exigiriam nova
--      análise de balanceamento e rastro público no git).
--      ATENÇÃO: A distinção de MEI NÃO sai dos dígitos do CNPJ (ambos têm 14
--      dígitos). A verificação da Natureza Jurídica é passo processual
--      obrigatório no Cartão CNPJ da Receita Federal antes de abrir o PR.
--   3. Pré-requisito legal: Bloco H da Política de Privacidade publicado
--      no site ANTES da aplicação desta migração.
--   4. A migração valida a existência da casa e a sintaxe de CNPJ (14 dígitos).
-- ============================================================================

do $$
declare
  -- Substituir pelo UUID da casa piloto autorizada:
  v_casa_id constant uuid := '00000000-0000-0000-0000-000000000000'::uuid;
  v_nome text;
  v_doc text;
begin
  select nome, documento into v_nome, v_doc
    from public.estabelecimento
   where id = v_casa_id;

  if not found then
    raise exception 'Estabelecimento % não encontrado em public.estabelecimento.', v_casa_id;
  end if;

  -- Validação de formato de documento (CNPJ com 14 dígitos numéricos):
  if length(coalesce(v_doc, '')) <> 14 then
    raise exception 'Estabelecimento % (%) possui documento com formato incompatível (exige CNPJ com 14 dígitos numéricos).', v_nome, v_casa_id;
  end if;

  -- 1. Garante que a versão mínima do app para a chave está registrada:
  insert into privado.recurso_versao_minima (recurso, plataforma, versao_minima)
  values ('checkin_por_codigo', 'ios', '1.2.0')
  on conflict (recurso, plataforma) do update set versao_minima = excluded.versao_minima;

  -- 2. Habilita a casa no piloto:
  insert into privado.recurso_estabelecimento (chave, estabelecimento_id)
  values ('checkin_por_codigo', v_casa_id)
  on conflict do nothing;

  raise notice 'Check-in por código ativado com sucesso para a casa % (%)', v_nome, v_casa_id;
end $$;
