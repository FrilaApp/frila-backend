-- publicar_a_partir_da_chamada converte a vaga direta que reabrir_por_atraso reabriu (#564, B-067).
--
-- O contrato promete (publicar_a_partir_da_chamada): "Vale antes do início e, para posição reaberta por
-- atraso, até fim_em - 1 h, a mesma janela de reabrir_por_atraso." O corpo, porém, abria a janela pós-início
-- só com `pos.estado = 'aberta' and pos.falta`, e a falta só existe em posição cancelada
-- (falta_so_em_cancelada, 20260922150400:91). reabrir_por_atraso cancela a posição antiga com a falta e
-- insere uma NOVA, aberta, com `reaberta_por_atraso_de` preenchido (20261108070000:426); a vaga volta de
-- preenchida a publicada. Nenhuma linha era ao mesmo tempo aberta e com falta: depois do início a conversão
-- dava sempre 409 vaga_encerrada, inclusive na vaga reaberta.
--
-- Muda uma condição: a posição que abre a janela pós-início é a aberta e reaberta por atraso
-- (`pos.reaberta_por_atraso_de is not null`). O resto é o corpo da 20261117170000 (a vigente: develop e PRs
-- abertos, conferido com git grep e gh pr diff): assinatura, travas (casa -> origem e irmãs por id, #563),
-- conferências, idempotência, 409 do #523, avisos, comentário e grants iguais. O contrato não muda: o
-- servidor passa a cumprir o que ele diz. O limite fim_em - 1 h e a recusa da vaga preenchida seguem como
-- estavam.

-- contrato: corpo-sem-mudanca-de-superficie public.publicar_a_partir_da_chamada 0.2.105
create or replace function public.publicar_a_partir_da_chamada(
  vaga_id uuid default null,
  chave uuid default null,
  modo text default 'urgencia'
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_agora     timestamptz := privado.agora();
  v_orig      public.vaga%rowtype;
  v_nova      public.vaga%rowtype;
  v_pos_id    uuid;
  v_posicoes  uuid[];
  v_c         record;
  v_estab     uuid;
  v_irmas     uuid[];
  v_modo      public.modo_preenchimento := coalesce(publicar_a_partir_da_chamada.modo::public.modo_preenchimento, 'urgencia'::public.modo_preenchimento);
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  if not coalesce((select rec.ligado from privado.recurso rec where rec.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;
  perform privado.exigir_perfil('contratante');
  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;
  if publicar_a_partir_da_chamada.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;
  if publicar_a_partir_da_chamada.chave is null then
    perform public.erro(422, 'campo_obrigatorio', 'chave');
  end if;

  -- 0.2.95: a trava da casa (a mesma de chamar_profissional) antes da trava da vaga. Serializa a
  -- conversão com as chamadas da casa e com a conversão de uma vaga irmã. A casa da vaga não muda,
  -- então é lida antes, sem trava; 404 e 403 saem antes de travar.
  select g.estabelecimento_id into v_estab from public.vaga g where g.id = publicar_a_partir_da_chamada.vaga_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;
  if not privado.eh_membro(v_estab) then perform public.erro(403, 'sem_permissao'); end if;
  perform 1 from public.estabelecimento e where e.id = v_estab for update;

  -- B-065 (#563): a origem e todas as vagas diretas da casa para o mesmo trabalho são travadas num
  -- comando só, em ordem de id, a ordem do expirar_chamadas (que não pega a trava da casa). Sem
  -- filtro de estado: a preenchida que reabrir_por_atraso devolve a publicada já está travada, e o
  -- update abaixo, que encerra só as publicadas, não pega nenhuma vaga fora de ordem. Antes, a origem era travada primeiro e as irmãs só no update. A origem é lida sem
  -- trava para achar as irmãs: função, início e fim de uma vaga não mudam (nenhuma função os altera).
  select * into v_orig from public.vaga where id = publicar_a_partir_da_chamada.vaga_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;
  perform 1
    from public.vaga g
   where g.id = v_orig.id
      or (g.estabelecimento_id = v_orig.estabelecimento_id
          and g.origem = 'chamada_direta'
          and g.funcao_id = v_orig.funcao_id
          and date_trunc('minute', g.inicio_em) = date_trunc('minute', v_orig.inicio_em)
          and date_trunc('minute', g.fim_em) = date_trunc('minute', v_orig.fim_em))
   order by g.id
     for update;

  -- A origem é relida já travada, e o resto segue igual.
  select * into v_orig from public.vaga where id = publicar_a_partir_da_chamada.vaga_id for update;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;

  -- Idempotência: reenviar a mesma chave devolve a vaga nova já convertida
  select * into v_nova from public.vaga
   where estabelecimento_id = v_orig.estabelecimento_id
     and chave_cliente = publicar_a_partir_da_chamada.chave;
  if found then
    select array_agg(p.id order by p.id) into v_posicoes from public.posicao p where p.vaga_id = v_nova.id;
    return jsonb_build_object('vaga_id', v_nova.id, 'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end if;

  -- Se a vaga direta já foi convertida anteriormente
  select * into v_nova from public.vaga where vaga_origem_id = v_orig.id;
  if found then
    select array_agg(p.id order by p.id) into v_posicoes from public.posicao p where p.vaga_id = v_nova.id;
    return jsonb_build_object('vaga_id', v_nova.id, 'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
  end if;

  if v_orig.origem <> 'chamada_direta' then
    perform public.erro(422, 'campo_invalido', 'vaga_id');
  end if;

  -- Janela de conversão: antes do início OU, com posição aberta reaberta por atraso, até fim_em - 1h (RN35).
  -- Direta já preenchida: 409.
  if v_orig.estado in ('cancelada', 'encerrada', 'preenchida')
     or (v_orig.inicio_em <= v_agora and not exists (
           select 1 from public.posicao pos where pos.vaga_id = v_orig.id and pos.estado = 'aberta' and pos.reaberta_por_atraso_de is not null
        ))
     or (v_orig.inicio_em <= v_agora and v_agora >= v_orig.fim_em - interval '1 hour') then
    perform public.erro(409, 'vaga_encerrada');
  end if;

  -- RN24: modo selecao exige antecedência de 24h
  if v_modo = 'selecao' and v_orig.inicio_em < v_agora + interval '24 hours' then
    perform public.erro(422, 'selecao_sem_antecedencia');
  end if;

  -- Cria vaga normal pública apontando para a vaga direta original
  begin
    insert into public.vaga (
      estabelecimento_id, funcao_id, inicio_em, fim_em, local, regiao_administrativa, ponto,
      valor_centavos, posicoes, inclui_refeicao, inclui_transporte, exige_material_proprio,
      responsavel_local, modo, publicado_por, publicado_em, chave_cliente, origem, vaga_origem_id
    )
    values (
      v_orig.estabelecimento_id, v_orig.funcao_id, v_orig.inicio_em, v_orig.fim_em, v_orig.local,
      v_orig.regiao_administrativa, v_orig.ponto, v_orig.valor_centavos, 1, v_orig.inclui_refeicao,
      v_orig.inclui_transporte, v_orig.exige_material_proprio, v_orig.responsavel_local,
      v_modo, v_uid, v_agora, publicar_a_partir_da_chamada.chave, 'publicacao', v_orig.id
    )
    returning * into v_nova;
  exception when unique_violation then
    -- Em caso de colisão concorrente por vaga_origem_id ou chave_cliente, recupera a vaga convertida
    select * into v_nova from public.vaga where vaga_origem_id = v_orig.id;
    if found then
      select array_agg(p.id order by p.id) into v_posicoes from public.posicao p where p.vaga_id = v_nova.id;
      return jsonb_build_object('vaga_id', v_nova.id, 'posicoes', to_jsonb(coalesce(v_posicoes, '{}'::uuid[])));
    end if;
    raise;
  end;

  insert into public.posicao (vaga_id, inicio_em, fim_em)
  values (v_nova.id, v_nova.inicio_em, v_nova.fim_em)
  returning id into v_pos_id;
  v_posicoes := array[v_pos_id];

  -- Encerra a vaga direta e suas chamadas abertas
  update public.vaga set estado = 'encerrada' where id = v_orig.id;

  -- 0.2.95 (CD-C15): as outras vagas diretas da casa para o mesmo trabalho (função, início e fim até o
  -- minuto, como em chamar_profissional) que ainda estão publicada, com ou sem chamada aberta, vão a
  -- encerrada; as chamadas abertas delas encerram no laço abaixo, com o mesmo aviso. A preenchida não
  -- é tocada: é a outra pessoa do mesmo horário, já confirmada.
  with irmas as (
    update public.vaga g set estado = 'encerrada'
     where g.estabelecimento_id = v_orig.estabelecimento_id
       and g.id <> v_orig.id
       and g.origem = 'chamada_direta' and g.estado = 'publicada'
       and g.funcao_id = v_orig.funcao_id
       and date_trunc('minute', g.inicio_em) = date_trunc('minute', v_orig.inicio_em)
       and date_trunc('minute', g.fim_em) = date_trunc('minute', v_orig.fim_em)
    returning g.id)
  select coalesce(array_agg(i.id), '{}') into v_irmas from irmas i;

  for v_c in
    update public.chamada
       set estado = 'encerrada',
           respondida_em = v_agora
     where vaga_id = any(array[v_orig.id] || v_irmas) and estado = 'aberta'
    returning id, profissional_id, vaga_id
  loop
    insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
    values (
      privado.usuario_do_profissional(v_c.profissional_id),
      'chamada_encerrada',
      v_c.id,
      jsonb_build_object('chamada_id', v_c.id, 'vaga_id', v_c.vaga_id)
    )
    on conflict do nothing;
  end loop;

  -- Enfileira despacho para a vaga nova convertida
  perform pgmq.send('despacho', jsonb_build_object(
    'vaga_id',      v_nova.id,
    'publicada_em', v_nova.publicado_em
  ));

  return jsonb_build_object('vaga_id', v_nova.id, 'posicoes', to_jsonb(v_posicoes));
end $$;

comment on function public.publicar_a_partir_da_chamada(uuid, uuid, text) is
  '0.2.56 e 0.2.95. Converte vaga direta em vaga aberta ao público com vaga_origem_id, encerrando a direta e chamadas abertas (RN35, RN46). 0.2.95: sob a trava da casa, encerra também as outras vagas diretas da casa para o mesmo trabalho (função, início e fim até o minuto) ainda publicadas, e as chamadas abertas delas, com o mesmo aviso; a preenchida não é tocada (CD-C15). Vaga direta já preenchida, cancelada ou encerrada: 409 vaga_encerrada (#523).';
revoke execute on function public.publicar_a_partir_da_chamada(uuid, uuid, text) from public, anon;
grant  execute on function public.publicar_a_partir_da_chamada(uuid, uuid, text) to authenticated;
