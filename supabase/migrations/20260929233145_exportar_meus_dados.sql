-- `privado.meus_dados`: a portabilidade da LGPD (cartão nUpPFCpM · US25, RF25, RNF08,
-- RN15, UC16 · LGPD art. 18 · contrato `MeusDados`).
--
-- O contrato põe a operação em `/functions/v1/exportar-meus-dados`, e não em `/rpc/`: o
-- JSON volta no corpo da resposta, sem link e sem e-mail. Esta função é só a coleta; a
-- Edge Function `exportar-meus-dados` resolve a identidade pelo token e devolve o corpo.
--
-- ── Por que ela é `stable`, e por que isso é o critério 2 ─────────────────────
--
-- O segundo critério do cartão é "nada fica guardado no servidor depois da resposta".
-- Escrever isso como promessa no código seria pedir que a próxima pessoa se lembrasse
-- dela. `stable` é a mesma frase dita ao Postgres: uma função `stable` **não consegue**
-- escrever — `INSERT`, `UPDATE` ou `DELETE` dentro dela é erro em tempo de execução. O
-- rótulo só se sustenta porque tudo que ela chama também é `stable` ou `immutable`
-- (`privado.agora`, `turno_em_json`, `perfil_profissional_em_json`,
-- `estabelecimento_publico`, `ponto_em_json`), e o `plpgsql_check` da CI reclama de
-- rótulo que mente.
--
-- Não há tabela de pedidos de exportação, nem arquivo, nem bucket, nem linha de log: o
-- corpo da resposta morre com a conexão, que é o que o contrato promete.
--
-- ── O que ela NÃO devolve, e por quê ─────────────────────────────────────────
--
-- **O token do aparelho** (`dispositivo.token_fcm`). O contrato declara só `plataforma`
-- e `atualizado_em` em `Dispositivo`. Um token de push é credencial de entrega, não
-- dado do titular, e um JSON que o cliente salva em Arquivos é o pior lugar para ele.
--
-- **O autor das avaliações recebidas.** É o que o contrato manda, e a razão está lá: a
-- avaliação é binária e agregada (RN07) justamente para que ninguém responda com medo de
-- retaliação. Devolver o autor aqui abriria pela porta da portabilidade o que todas as
-- outras leituras fecham.
--
-- ── O que o contrato deixa de fora, e não é decisão desta migração ───────────
--
-- `MeusDados` não tem lugar para `candidatura`, `ocorrencia`, `bloqueio`, `notificacao`,
-- `despacho`, `vaga` nem `equipe_confianca` — e todas guardam dado do titular. O cartão
-- pede "os dados de todas as tabelas com dado do usuário", o contrato descreve nove
-- coleções, e os dois discordam.
--
-- Aqui vale a regra do repositório: o documento ganha, ou o documento muda primeiro. A
-- função devolve exatamente `MeusDados`, e a divergência está registrada no cartão e
-- fixada no teste `440`, que enumera as tabelas pelo catálogo e obriga quem criar uma
-- tabela nova a decidir de que lado ela fica. Fechar o buraco aqui, em silêncio, faria o
-- iOS gerar um modelo sem os campos e quebraria o portão do contrato.

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
       where di.usuario_id = p_usuario), '[]'::jsonb)
  )
  from conta c
$$;

comment on function privado.meus_dados(uuid) is
  'Portabilidade da LGPD art. 18 no schema MeusDados do contrato (nUpPFCpM, RF25, UC16). É stable de propósito: uma função stable não consegue escrever, e é assim que "nada fica guardado no servidor depois da resposta" deixa de ser promessa. Sem token de aparelho e sem o autor das avaliações recebidas (RN07, RN15). Devolve null para conta que não existe.';

revoke execute on function privado.meus_dados(uuid) from public, anon, authenticated;
grant  execute on function privado.meus_dados(uuid) to service_role;
