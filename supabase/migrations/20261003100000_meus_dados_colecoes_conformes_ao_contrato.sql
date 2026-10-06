-- Corrige coleções de privado.meus_dados para estrita conformidade com o contrato 0.2.33.
--
-- O contrato 0.2.33 (frila-docs#32) declarou o schema de MeusDados.notificacoes apenas com
-- [tipo, referencia_id, payload, enviada_em, entregue_em], e despachos com [vaga_id, criado_em, reaberta].
-- A migração 20261003060000 incluía `id` e `urgente` em notificacoes e `id` e `rodada` em despachos,
-- fazendo o portão contrato-responde.sh reprovar por chaves não declaradas no schema da resposta.

create or replace function privado.meus_dados(p_usuario uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with conta as (
    select * from public.usuario u where u.id = p_usuario
  ),
  prof as (
    select p.* from public.profissional p where p.usuario_id = p_usuario
  ),
  casas as (
    select m.estabelecimento_id, m.papel, e.nome, e.tipo
      from public.membro_estabelecimento m
      join public.estabelecimento e on e.id = m.estabelecimento_id
     where m.usuario_id = p_usuario
  )
  select jsonb_build_object(
    'gerado_em', privado.agora(),

    'conta', jsonb_build_object(
      'id',         c.id,
      'perfil',     c.perfil,
      'nome',       c.nome,
      'telefone',   c.telefone,
      'email',      c.email,
      'nascimento', c.nascimento,
      'estado',     c.estado),

    -- `oneOf [PerfilProfissional, null]`: a conta de contratante não tem perfil, e a
    -- subconsulta sem linha vira `null` no JSON, que é o que o contrato declara.
    'perfil_profissional',
      (select public.perfil_profissional_em_json(p) from prof p),

    -- Mesmo objeto que `meus_estabelecimentos` devolve, e pelo mesmo caminho para a
    -- reputação: uma segunda definição da taxa de comparecimento seria uma segunda
    -- verdade.
    'estabelecimentos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',        k.estabelecimento_id,
               'nome',      k.nome,
               'tipo',      k.tipo,
               'papel',     k.papel,
               'reputacao', privado.estabelecimento_publico(k.estabelecimento_id)->'reputacao')
             order by k.nome)
        from casas k), '[]'::jsonb),

    -- O contrato pede a disponibilidade também no topo, além de dentro do perfil. Sai da
    -- mesma tabela, e não de uma cópia.
    'disponibilidade', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dia_semana',  d.dia_semana,
               'hora_inicio', to_char(d.hora_inicio, 'HH24:MI'),
               'hora_fim',    to_char(d.hora_fim,    'HH24:MI'))
             order by d.dia_semana, d.hora_inicio)
        from public.disponibilidade d
        join prof p on p.id = d.profissional_id), '[]'::jsonb),

    -- Os dois lados: os turnos que o titular trabalhou como profissional e os das casas
    -- de que ele é membro. `turno_em_json` já escolhe a contraparte pelo ponto de vista
    -- de quem pergunta, que é por que ela recebe o `uuid` do titular.
    'turnos', coalesce((
      select jsonb_agg(privado.turno_em_json(t.id, p_usuario) order by po.inicio_em desc)
        from public.turno t
        join public.posicao po on po.id = t.posicao_id
        join public.vaga v     on v.id = po.vaga_id
       where po.profissional_id in (select p.id from prof p)
          or v.estabelecimento_id in (select k.estabelecimento_id from casas k)),
      '[]'::jsonb),

    'avaliacoes_dadas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'turno_id',  a.turno_id,
               'resposta',  a.resposta,
               'criada_em', a.criada_em)
             order by a.criada_em desc)
        from public.avaliacao a
       where a.autor_id = p_usuario), '[]'::jsonb),

    -- Sem `autor_id`: é a única coisa que este JSON deliberadamente não conta ao próprio
    -- titular. Uma casa com dois membros vê aqui a mesma avaliação recebida, porque ela é
    -- da casa e os dois são a casa.
    'avaliacoes_recebidas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'turno_id',  a.turno_id,
               'resposta',  a.resposta,
               'criada_em', a.criada_em)
             order by a.criada_em desc)
        from public.avaliacao a
       where (a.alvo_tipo = 'profissional'
                and a.alvo_id in (select p.id from prof p))
          or (a.alvo_tipo = 'estabelecimento'
                and a.alvo_id in (select k.estabelecimento_id from casas k))),
      '[]'::jsonb),

    -- Sem `token_fcm`, que é credencial de entrega e não dado do titular.
    'dispositivos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'plataforma',    di.plataforma,
               'atualizado_em', di.atualizado_em)
             order by di.atualizado_em desc)
        from public.dispositivo di
       where di.usuario_id = p_usuario), '[]'::jsonb),

    -- ── As sete coleções do contrato 0.2.33 ───────────────────────────────────

    -- Inclusive retiradas, recusadas e expiradas: o histórico de ter se candidatado é
    -- dado do titular, e omitir o que não deu certo seria editar o passado dele.
    -- Pelo mesmo caminho de `minhas_candidaturas` (`candidatura_em_json`), para o objeto
    -- ser o `Candidatura` do contrato, com `vaga` como VagaResumo, e não uma segunda
    -- definição achatada.
    'candidaturas', coalesce((
      select jsonb_agg(privado.candidatura_em_json(cd.id) order by cd.criada_em desc, cd.id)
        from public.candidatura cd
       where cd.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    -- `papel` diz de que lado ele está. `motivo` sai só quando ele é o autor — texto
    -- escrito por outra pessoa sobre ele não é dado que ele forneceu — ou quando o tipo é
    -- `suspensao`, porque aí o motivo é a justificativa de uma medida contra ele, e RN07
    -- exige que ele possa contestar o que não conhece. `resultado` nunca sai: é a decisão
    -- interna do suporte, não dado do titular. `relato` também não, pelo mesmo motivo do
    -- `motivo`.
    'ocorrencias', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',        o.id,
               'tipo',      o.tipo,
               'papel',     case when o.autor_id = p_usuario then 'autor' else 'alvo' end,
               'criada_em',    o.criada_em,
               'resolvido_em', o.resolvido_em,
               'motivo',    case
                              when o.autor_id = p_usuario or o.tipo = 'suspensao'
                                then o.motivo
                              else null
                            end)
             order by o.criada_em desc)
        from public.ocorrencia o
       where o.autor_id = p_usuario or o.usuario_id = p_usuario), '[]'::jsonb),

    -- Só os que ele criou. Saber que foi bloqueado é exatamente o que RF26 esconde: o
    -- bloqueio é invisível para o bloqueado, e um JSON de portabilidade que o revelasse
    -- desfaria a regra por outro caminho. Por isso `autor_id = p_usuario` e nada de
    -- `bloqueado_id` apontando para ele em nenhuma profundidade.
    -- E devolve o PAR, nunca o id de conta. O schema `Bloqueio` do contrato diz com estas
    -- palavras: "Devolve o mesmo par que a chamada recebeu, e não o id de conta da outra
    -- parte: devolvê-lo abriria um caminho de leitura que RN10 fecha em todos os outros."
    'bloqueios', coalesce((
      select jsonb_agg(x.o order by x.criado_em desc)
        from (
          select distinct jsonb_build_object(
                   'alvo_tipo', 'profissional',
                   'alvo_id',   pb.id,
                   'criado_em', b.criado_em) as o,
                 b.criado_em
            from public.bloqueio b
            join public.profissional pb on pb.usuario_id = b.bloqueado_id
           where b.autor_id = p_usuario
          union
          select distinct jsonb_build_object(
                   'alvo_tipo', 'estabelecimento',
                   'alvo_id',   mb.estabelecimento_id,
                   'criado_em', b.criado_em) as o,
                 b.criado_em
            from public.bloqueio b
            join public.usuario ub on ub.id = b.bloqueado_id and ub.perfil = 'contratante'
            join public.membro_estabelecimento mb on mb.usuario_id = b.bloqueado_id
           where b.autor_id = p_usuario
        ) x), '[]'::jsonb),

    -- Sem `id`, `urgente`, `tentativas`, `motivo_falha`, `proxima_tentativa_em` nem `esperou_teto`:
    -- são o diário de bordo do provedor de push, não dado do titular (RN15).
    -- Conforme o schema MeusDados do contrato 0.2.33, traz exatamente tipo, referencia_id,
    -- payload, enviada_em e entregue_em.
    'notificacoes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tipo',          n.tipo,
               'referencia_id', n.referencia_id,
               'payload',       n.payload,
               'enviada_em',    n.enviada_em,
               'entregue_em',   n.entregue_em)
             order by n.enviada_em desc nulls last)
        from public.notificacao n
       where n.usuario_id = p_usuario), '[]'::jsonb),

    -- Uma linha por vaga para que ele foi considerado, com `reaberta`. É o registro de ter
    -- sido alcançado pelo despacho, e é o que explica ao titular por que recebeu — ou por
    -- que não recebeu — uma vaga. Sem `notificacao_id`, `id` ou `rodada`, estritamente
    -- conforme o schema MeusDados.despachos do contrato 0.2.33.
    'despachos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'vaga_id',   ds.vaga_id,
               'criado_em', ds.criado_em,
               'reaberta',  ds.reaberta)
             order by ds.criado_em desc)
        from public.despacho ds
       where ds.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    -- Só o lado do profissional: as casas de que ele faz parte. A equipe das casas que ele
    -- administra é dado dos profissionais dela, não dele, e entraria aqui como a lista de
    -- gente de outra pessoa.
    'equipe_confianca', coalesce((
      select jsonb_agg(jsonb_build_object(
               'estabelecimento_id', ec.estabelecimento_id,
               'nome',               es.nome,
               'adicionado_em',      ec.adicionado_em)
             order by ec.adicionado_em desc)
        from public.equipe_confianca ec
        join public.estabelecimento es on es.id = ec.estabelecimento_id
       where ec.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    -- `null` quando não há pedido, e não um objeto vazio: o contrato declara
    -- `oneOf [PedidoDeExclusao, null]`, e a subconsulta sem linha já vira `null`.
    'pedido_de_exclusao', (
      select jsonb_build_object(
               'pedido_em',    pe.pedido_em,
               'estado',       pe.estado,
               'tentativas',   pe.tentativas,
               'concluido_em', pe.concluido_em)
        from public.pedido_de_exclusao pe
       where pe.usuario_id = p_usuario
       order by pe.pedido_em desc
       limit 1)
  )
  from conta c
$$;

comment on function privado.meus_dados(uuid) is
  'Portabilidade da LGPD art. 18 no schema MeusDados do contrato 0.2.33 (nUpPFCpM, IrtkCWDz, RF25, UC16). É stable de propósito: uma função stable não consegue escrever, e é assim que "nada fica guardado no servidor depois da resposta" deixa de ser promessa. Leva as sete coleções conforme os schemas exatos do contrato 0.2.33. Sem token de aparelho, sem o autor das avaliações recebidas, sem os bloqueios feitos contra o titular (RF26), sem id/urgente em notificacoes e sem resultado de ocorrência (RN07, RN15).';
