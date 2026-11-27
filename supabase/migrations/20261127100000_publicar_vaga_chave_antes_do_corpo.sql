-- ZFwcL4of: `public.publicar_vaga` confere a chave de idempotência (`chave_cliente`, RF04) ANTES do corpo (`privado.validar_nova_vaga`), como a `publicar_escala`.
--
-- Na definição vigente (20261117030000) o corpo inteiro era conferido antes da chave. No reenvio, nenhuma recusa de conteúdo provava que a primeira tentativa
-- não gravou: se a 1ª publicação gravou e a resposta se perdeu, e o reenvio chega depois que o início passou (ou sem a antecedência da seleção, ou com a função
-- desativada), a RPC recusava com 422, o app soltava a chave e a pessoa publicava OUTRA vaga. Android e iOS.
--
-- Corpo de 20261117030000 com o bloco da chave movido para antes de `validar_nova_vaga`; nada mais muda. A ordem das recusas que vêm antes do corpo
-- (401, perfil, conta suspensa, membro) é a mesma, então a chave só é consultada por quem é da casa. Sem chave (nula) nada casa e o corpo recusa como antes.
-- Assinatura, `security definer set search_path = ''`, grants e a forma da resposta (`vaga_id`, `posicoes`) não mudam.
-- contrato: corpo-sem-mudanca-de-superficie public.publicar_vaga 0.2.118

create or replace function public.publicar_vaga(
  estabelecimento_id      uuid,
  funcao_id               uuid,
  inicio_em               timestamptz,
  fim_em                  timestamptz,
  local                   text,
  ponto                   jsonb,
  valor_centavos          bigint,
  posicoes                integer,
  inclui_refeicao         boolean,
  inclui_transporte       boolean,
  exige_material_proprio  boolean,
  responsavel_local       text,
  modo                    public.modo_preenchimento,
  chave                   uuid,
  traje                   text    default null,
  participa_rateio        boolean default null,
  observacoes             text    default null,
  alerta_antecedencia_min int     default 180,
  regiao_administrativa   text    default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_estab_id  uuid;
  v_nova      public.vaga;
  v_vaga      public.vaga%rowtype;
  v_posicoes  uuid[];
  v_eh_demo   boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  perform privado.exigir_perfil('contratante');

  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  v_eh_demo := privado.conta_de_demonstracao();

  -- Resolução resiliente do estabelecimento para demonstração
  if publicar_vaga.estabelecimento_id is null and v_eh_demo then
    select m.estabelecimento_id into v_estab_id
      from public.membro_estabelecimento m
     where m.usuario_id = v_uid
     limit 1;
    if v_estab_id is null then
      v_estab_id := 'de000000-0000-4000-8000-000000000010'::uuid;
    end if;
  else
    v_estab_id := publicar_vaga.estabelecimento_id;
  end if;

  if v_eh_demo and not privado.eh_membro(v_estab_id) then
    insert into public.membro_estabelecimento (usuario_id, estabelecimento_id, papel)
    values (v_uid, v_estab_id, 'administrador')
    on conflict do nothing;
  end if;

  if not privado.eh_membro(v_estab_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- RF04: a chave de idempotência do cliente, ANTES do corpo (como a `publicar_escala`). O reenvio de uma publicação que já gravou devolve a vaga
  -- gravada sem conferir o corpo de novo: uma recusa de conteúdo que depende do relógio (início no passado, antecedência da seleção) ou do catálogo
  -- (função ou região desativada, piso e teto) não prova que a primeira tentativa não gravou, e o app soltaria a chave e publicaria OUTRA vaga.
  select * into v_vaga
    from public.vaga g
   where g.estabelecimento_id = v_estab_id
     and g.chave_cliente = publicar_vaga.chave;

  if found then
    select array_agg(p.id order by p.id) into v_posicoes
      from public.posicao p where p.vaga_id = v_vaga.id;
    return jsonb_build_object('vaga_id', v_vaga.id,
                              'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end if;

  -- O corpo: RN02, região, valores, horário, RN24, diretriz 1.2 e ponto, na ordem de sempre.
  v_nova := privado.validar_nova_vaga(
    null, 200, v_estab_id, v_eh_demo,
    publicar_vaga.funcao_id, publicar_vaga.inicio_em, publicar_vaga.fim_em,
    publicar_vaga.local, publicar_vaga.ponto, publicar_vaga.valor_centavos, publicar_vaga.posicoes,
    publicar_vaga.inclui_refeicao, publicar_vaga.inclui_transporte,
    publicar_vaga.exige_material_proprio, publicar_vaga.responsavel_local, publicar_vaga.modo,
    publicar_vaga.chave, publicar_vaga.traje, publicar_vaga.participa_rateio,
    publicar_vaga.observacoes, publicar_vaga.alerta_antecedencia_min,
    publicar_vaga.regiao_administrativa);

  begin
    insert into public.vaga (
      estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte,
      exige_material_proprio, responsavel_local, traje, participa_rateio,
      observacoes, modo, alerta_antecedencia, publicado_por, chave_cliente)
    values (
      v_nova.estabelecimento_id, v_nova.funcao_id, v_nova.inicio_em, v_nova.fim_em,
      v_nova.local, v_nova.regiao_administrativa, v_nova.ponto,
      v_nova.valor_centavos, v_nova.posicoes, v_nova.inclui_refeicao, v_nova.inclui_transporte,
      v_nova.exige_material_proprio, v_nova.responsavel_local, v_nova.traje,
      v_nova.participa_rateio, v_nova.observacoes, v_nova.modo, v_nova.alerta_antecedencia,
      v_uid, v_nova.chave_cliente)
    returning * into v_vaga;
  exception
    when unique_violation then
      select * into v_vaga
        from public.vaga g
       where g.estabelecimento_id = v_estab_id
         and g.chave_cliente = publicar_vaga.chave;
      select array_agg(p.id order by p.id) into v_posicoes
        from public.posicao p where p.vaga_id = v_vaga.id;
      return jsonb_build_object('vaga_id', v_vaga.id,
                                'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end;

  insert into public.posicao (vaga_id, inicio_em, fim_em)
  select v_vaga.id, v_vaga.inicio_em, v_vaga.fim_em
    from generate_series(1, publicar_vaga.posicoes);

  select array_agg(p.id order by p.id) into v_posicoes
    from public.posicao p where p.vaga_id = v_vaga.id;

  -- Isolamento de demonstração: contas de demonstração não entram na fila de despacho
  if not v_eh_demo then
    perform pgmq.send('despacho', jsonb_build_object(
      'vaga_id',      v_vaga.id,
      'publicada_em', v_vaga.publicado_em));
  end if;

  return jsonb_build_object('vaga_id', v_vaga.id, 'posicoes', to_jsonb(v_posicoes));
end $$;

comment on function public.publicar_vaga(
  uuid, uuid, timestamptz, timestamptz, text, jsonb, bigint, integer,
  boolean, boolean, boolean, text, public.modo_preenchimento, uuid,
  text, boolean, text, int, text
) is
  'Publica uma vaga e enfileira o despacho no pgmq. Idempotente pela chave gerada pelo app. regiao_administrativa obrigatória (0.2.20) e validada contra o catálogo ativo (RN44). O corpo é conferido por privado.validar_nova_vaga, a mesma conferência de cada item de publicar_escala (0.2.96). Desde a ZFwcL4of a chave é conferida antes do corpo: o reenvio devolve a vaga gravada mesmo que o corpo já não seja válido.';
