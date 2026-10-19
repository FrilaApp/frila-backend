-- Moderação do texto denunciado, e o prazo de 24 h da diretriz 1.2 (cartão FrpxqCxp ·
-- RF26, RN13 · App Store 1.2).
--
-- ── O que já existia, e por isso não está aqui ───────────────────────────────
--
-- O cartão `Oxh0AWE7` (Operação da Equipe Frila) entregou a metade grande deste: a
-- tabela `privado.vaga_ocultada`, o predicado `privado.vaga_oculta` e a
-- `privado.operacao_moderar_conteudo`, que oculta e reexibe a **vaga inteira** gravando
-- `ocorrencia`. A marca já filtra `vagas_abertas`, `detalhe_vaga`, `candidatar`,
-- `republicar_vaga` e o despacho, e o teste `460` fixa cada um desses caminhos.
--
-- O que faltava do critério 2 é a outra granularidade: **"texto ocultado deixa de
-- aparecer"**. Nem toda denúncia de conteúdo justifica tirar a vaga do ar — uma linha
-- ofensiva nas observações não é motivo para cancelar o turno de quem já confirmou. O
-- que precisa sumir é a linha.
--
-- ── Por que apagar o texto, e não filtrá-lo na leitura ──────────────────────
--
-- A alternativa seria uma marca e um `case` em cada função que devolve o texto. Duas
-- coisas contra:
--
--   1. `detalhe_vaga` e `painel_estabelecimento` são funções de `public`, e mexer nelas
--      obriga o contrato a mudar por uma alteração que não muda campo nenhum;
--   2. um filtro na leitura protege só as leituras que alguém lembrou de filtrar. O
--      texto continuaria na linha, e a próxima função que o devolvesse nasceria
--      vazando — que é exatamente como este repositório descreve o `enviar-push` que
--      consultava a vaga direto.
--
-- Aqui o texto sai da linha e vai para `privado.texto_da_vaga_ocultado`. Some de toda
-- leitura ao mesmo tempo, inclusive das que ainda não existem, e volta inteiro na
-- reexibição. O registro do que foi escrito não se perde: ele muda de lugar, para um
-- schema que o PostgREST não expõe e que só o `service_role` lê.
--
-- `responsavel_local` é `not null` e não pode virar nulo: recebe o marcador neutro, o
-- mesmo idioma que a retenção já usa em `ocorrencia.motivo`. `local` fica de fora de
-- propósito — é o endereço, é como se chega ao turno, e quem tem turno confirmado
-- precisa dele. Endereço ofensivo é caso de ocultar a vaga inteira, que já existe.

-- ── 1. Onde o texto fica guardado ─────────────────────────────────────────────

create table privado.texto_da_vaga_ocultado (
  vaga_id           uuid primary key references public.vaga(id) on delete cascade,
  ocorrencia_id     uuid not null references public.ocorrencia(id),
  oculto_em         timestamptz not null,
  -- Os originais, para a reexibição devolver exatamente o que estava lá.
  responsavel_local text not null,
  traje             text,
  observacoes       text
);

comment on table privado.texto_da_vaga_ocultado is
  'Texto livre que a Equipe Frila ocultou de uma vaga (moderação, Diretriz 1.2): o original sai da linha da vaga e fica aqui até a reexibição. Fora do PostgREST, só service_role. A linha some quando o texto volta.';
comment on column privado.texto_da_vaga_ocultado.responsavel_local is
  'O valor original. Na vaga ele é substituído pelo marcador neutro, porque a coluna é not null.';

revoke all on table privado.texto_da_vaga_ocultado from public, anon, authenticated;
grant  all on table privado.texto_da_vaga_ocultado to service_role;

create or replace function privado.texto_da_vaga_oculto(v uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from privado.texto_da_vaga_ocultado o where o.vaga_id = v)
$$;

comment on function privado.texto_da_vaga_oculto(uuid) is
  'Verdadeiro enquanto o texto livre da vaga estiver sob moderação (Diretriz 1.2).';

revoke execute on function privado.texto_da_vaga_oculto(uuid) from public, anon, authenticated;
grant  execute on function privado.texto_da_vaga_oculto(uuid) to service_role;

-- ── 2. O prazo de 24 h ────────────────────────────────────────────────────────
--
-- A RN13 continua inteira: a Equipe Frila responde em até 5 dias úteis, e é isso que
-- `privado.prazo_de_resposta` devolve e que o `Protocolo` do contrato promete. O que a
-- diretriz 1.2 pede é diferente e mais curto — **agir sobre o conteúdo denunciado** em
-- até 24 h —, e as duas coisas convivem: ocultar em 24 h, responder em 5 dias.
--
-- Uma definição só, para que o prazo não vire um número repetido no script, no teste e
-- na cabeça de quem está de plantão no fim de semana do piloto.
create or replace function privado.prazo_de_moderacao(instante timestamptz)
returns timestamptz
language sql
immutable
set search_path = ''
as $$
  select instante + interval '24 hours'
$$;

comment on function privado.prazo_de_moderacao(timestamptz) is
  'Diretriz 1.2: o conteúdo denunciado é tratado em até 24 h corridas do registro da denúncia, inclusive no fim de semana. Não substitui a RN13, que é o prazo de 5 dias úteis da resposta.';

revoke execute on function privado.prazo_de_moderacao(timestamptz) from public, anon, authenticated;
grant  execute on function privado.prazo_de_moderacao(timestamptz) to service_role;

-- A fila de plantão. Sem ela, "tratado em 24 h" é uma frase no cartão: ninguém consegue
-- perguntar ao banco o que está vencendo. Devolve só o que a Equipe precisa para agir —
-- protocolo, prazo e o que falta —, e nunca o relato, que ela lê abrindo a ocorrência.
create or replace function privado.moderacao_pendente(p_prazo interval default interval '24 hours')
returns table (
  ocorrencia_id uuid,
  criada_em     timestamptz,
  tratar_ate    timestamptz,
  vencida       boolean,
  motivo        text
)
language sql
stable
security definer
set search_path = ''
as $$
  select o.id,
         o.criada_em,
         o.criada_em + p_prazo,
         privado.agora() > o.criada_em + p_prazo,
         o.motivo
    from public.ocorrencia o
   where o.tipo = 'denuncia'
     and o.resolvido_em is null
   order by o.criada_em
$$;

comment on function privado.moderacao_pendente(interval) is
  'Denúncias ainda não tratadas, com o prazo de 24 h da Diretriz 1.2 e a marca do que já venceu. Sem o relato: a Equipe o lê abrindo a ocorrência. Restrito a service_role.';

revoke execute on function privado.moderacao_pendente(interval) from public, anon, authenticated;
grant  execute on function privado.moderacao_pendente(interval) to service_role;

-- ── 3. Ocultar e reexibir o texto ─────────────────────────────────────────────
--
-- Mesmo molde da `operacao_moderar_conteudo`: operador conferido, ação fechada em duas
-- palavras, ocorrência de `suporte` assinada por quem agiu, e reenvio idempotente.
create or replace function privado.operacao_moderar_texto(
  vaga_id     uuid,
  acao        text,
  motivo      text,
  operador_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_vaga_id  uuid := operacao_moderar_texto.vaga_id;
  v_acao     text := pg_catalog.btrim(operacao_moderar_texto.acao);
  v_motivo   text := pg_catalog.btrim(operacao_moderar_texto.motivo);
  v_operador uuid := operacao_moderar_texto.operador_id;
  v_vaga     public.vaga%rowtype;
  v_guardado privado.texto_da_vaga_ocultado%rowtype;
  v_agora    timestamptz := privado.agora();
  v_oc_id    uuid;
begin
  if v_vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;
  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  select * into v_vaga from public.vaga g where g.id = v_vaga_id for update;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_vaga.publicado_por);

  if v_acao is null or v_acao not in ('ocultar', 'reexibir') then
    perform public.erro(422, 'campo_invalido', 'acao');
  end if;

  if v_acao = 'ocultar' then
    -- Reenvio: devolve o que já foi feito, sem gravar uma segunda ocorrência.
    if privado.texto_da_vaga_oculto(v_vaga_id) then
      return jsonb_build_object(
        'vaga_id',              v_vaga_id,
        'texto_oculto',        true,
        'ja_estava_oculto',    true);
    end if;

    insert into public.ocorrencia (
      tipo, usuario_id, estabelecimento_id, autor_id, motivo, criada_em, resolvido_em, resultado
    ) values (
      'suporte',
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_operador,
      'Moderação Diretriz 1.2 (texto): ' || v_motivo,
      v_agora,
      v_agora,
      'Texto livre da vaga ocultado em até 24h pela Equipe Frila; a vaga segue no ar.'
    ) returning id into v_oc_id;

    insert into privado.texto_da_vaga_ocultado
      (vaga_id, ocorrencia_id, oculto_em, responsavel_local, traje, observacoes)
    values
      (v_vaga_id, v_oc_id, v_agora, v_vaga.responsavel_local, v_vaga.traje, v_vaga.observacoes);

    -- O texto sai da linha. `responsavel_local` é not null e recebe o marcador neutro,
    -- como a retenção faz com o motivo da ocorrência.
    update public.vaga g
       set responsavel_local = '[removido pela moderação]',
           traje             = null,
           observacoes       = null
     where g.id = v_vaga_id;

    return jsonb_build_object(
      'vaga_id',       v_vaga_id,
      'texto_oculto',  true,
      'ocorrencia_id', v_oc_id,
      'acao',          'ocultar',
      'moderado_em',   v_agora);

  else -- reexibir
    select * into v_guardado
      from privado.texto_da_vaga_ocultado o where o.vaga_id = v_vaga_id;
    if not found then
      perform public.erro(422, 'campo_invalido', 'texto_nao_ocultado');
    end if;

    update public.vaga g
       set responsavel_local = v_guardado.responsavel_local,
           traje             = v_guardado.traje,
           observacoes       = v_guardado.observacoes
     where g.id = v_vaga_id;

    delete from privado.texto_da_vaga_ocultado o where o.vaga_id = v_vaga_id;

    insert into public.ocorrencia (
      tipo, usuario_id, estabelecimento_id, autor_id, motivo, criada_em, resolvido_em, resultado
    ) values (
      'suporte',
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_operador,
      'Moderação Reexibir (texto): ' || v_motivo,
      v_agora,
      v_agora,
      'Texto livre da vaga reexibido pela Equipe Frila após análise.'
    ) returning id into v_oc_id;

    return jsonb_build_object(
      'vaga_id',       v_vaga_id,
      'texto_oculto',  false,
      'ocorrencia_id', v_oc_id,
      'acao',          'reexibir',
      'reexibido_em',  v_agora);
  end if;
end $$;

comment on function privado.operacao_moderar_texto(uuid, text, text, uuid) is
  'Oculta e reexibe o texto livre denunciado de uma vaga em até 24h (Diretriz 1.2), sem tirar a vaga do ar: o original sai da linha para privado.texto_da_vaga_ocultado e volta inteiro na reexibição. Ocorrência de suporte assinada pelo operador. Restrito a service_role.';

revoke execute on function privado.operacao_moderar_texto(uuid, text, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_moderar_texto(uuid, text, text, uuid) to service_role;
