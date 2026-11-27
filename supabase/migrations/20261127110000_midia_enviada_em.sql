-- Z8V10ATg: `privado.midia_em_json` passa a devolver `enviada_em` (`Midia.enviada_em`, contrato 0.2.54), igual a `privado.midia.criado_em`.
--
-- O contrato `Midia` declara `enviada_em` e `decidida_em`; a definição vigente (20261108060000) não devolvia nenhum dos dois, e o iOS ordena as fotos
-- do dono por `enviadaEm`. Este PR faz só `enviada_em`. `decidida_em` precisa de decisão (usar `atualizado_em` nos estados decididos ou criar uma coluna
-- nova que guarde o instante da decisão) e fica de fora: ver o corpo do PR.
--
-- Corpo de 20261108060000 com uma chave a mais no fim do objeto. Assinatura, `stable security definer set search_path = ''` e permissões não mudam.
-- `privado.midia_em_json` alimenta `minhas_midias`, `confirmar_upload_midia`, `pedir_nova_analise_midia` e a exportação do titular (`privado.meus_dados`):
-- todas passam a trazer `enviada_em`. Função de `privado`: não toca a superfície pública do contrato (o campo já é declarado).

create or replace function privado.midia_em_json(m privado.midia) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'id', m.id,
    'tipo', m.tipo,
    'estado', case when m.estado = 'expurgada' then 'removida' else m.estado end,
    'motivo_recusa', m.motivo_recusa,
    'pode_pedir_nova_analise', privado.midia_pode_pedir_nova_analise(m),
    'estabelecimento_id', m.estabelecimento_id,
    -- `Midia.enviada_em` (contrato 0.2.54): quando a mídia foi enviada. O que o app usa para ordenar as fotos do dono.
    'enviada_em', m.criado_em)
$$;
