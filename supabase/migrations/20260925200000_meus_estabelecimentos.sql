-- `meus_estabelecimentos`: por qual casa o contratante está falando.
--
-- RF02, RF21, UC07, cartão `AvockvHx`. O contrato descreve esta operação desde a 0.2.1 e
-- ela nunca foi implementada: o cartão que deveria tê-la trazido a citava em "O que
-- fazer", mas nenhum item da checklist a mencionava, então ele fechou com a checklist
-- inteira marcada e a função faltando.
--
-- Por que ela é bloqueio de tela, e não conveniência: `publicar_vaga`,
-- `painel_estabelecimento` e `republicar_vaga` recebem `estabelecimento_id`. Sem esta
-- leitura o app só descobre esse id cadastrando um estabelecimento novo — o caminho
-- errado para quem já tem, e que criaria uma casa duplicada a cada tentativa.
--
-- ── Três decisões ─────────────────────────────────────────────────────────────────────
--
-- **O papel vai junto** (RF21). `operador` não publica vaga em nome da casa nem mexe na
-- equipe, e o servidor recusa com `403 sem_permissao`. A tela precisa esconder o botão
-- antes, e para isso ela precisa do papel aqui — pedir por estabelecimento seria uma
-- chamada por casa só para saber o que já cabia nesta.
--
-- **Lista vazia é resposta, não erro.** É o estado do contratante recém-criado, que é o
-- caso mais comum do primeiro minuto de uso. Um `404` aqui esconderia a tela de "cadastre
-- sua primeira casa" atrás de um erro.
--
-- **A reputação sai por `privado.estabelecimento_publico`**, que já existe e já devolve o
-- `Reputacao` do contrato com a taxa nula e os turnos em zero — a taxa de comparecimento
-- é do profissional, porque é ele que comparece ou falta. Agregar aqui criaria uma
-- segunda definição da mesma coisa.

-- **Sem rótulo de volatilidade**, como as outras leituras do produto. `stable` foi a
-- primeira tentativa e o `plpgsql_check` reprovou: ela chama `privado.exigir_perfil` e
-- `public.erro`, que são VOLATILE. Rótulo que mente sobre o corpo é o tipo de coisa que
-- passa despercebida até o planejador tomar uma decisão errada com ela.
create or replace function public.meus_estabelecimentos()
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_lista jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('contratante');

  -- `coalesce` para o array vazio: sem ele, `jsonb_agg` de zero linhas devolve NULL, e o
  -- cliente gerado a partir do contrato quebraria ao desserializar um array obrigatório.
  select coalesce(jsonb_agg(x.item order by x.nome), '[]'::jsonb) into v_lista
    from (
      select e.nome,
             jsonb_build_object(
               'id',        e.id,
               'nome',      e.nome,
               'tipo',      e.tipo,
               'papel',     m.papel,
               'reputacao', privado.estabelecimento_publico(e.id)->'reputacao') as item
        from public.membro_estabelecimento m
        join public.estabelecimento e on e.id = m.estabelecimento_id
       where m.usuario_id = v_uid
    ) x;

  return v_lista;
end $$;

comment on function public.meus_estabelecimentos() is
  'Estabelecimentos de que a conta é membro, com o papel em cada um (RF02, RF21, UC07). Sem documento, endereço, ponto ou contato: é leitura de tela, não de cadastro (RN10). Lista vazia é resposta legítima.';

revoke execute on function public.meus_estabelecimentos() from public, anon;
grant  execute on function public.meus_estabelecimentos() to authenticated;
