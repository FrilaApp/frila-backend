-- expirar_chamadas pega a vaga antes da chamada, como o resto (B-065, issue #562).
--
-- Três funções: privado.expirar_chamadas (a vaga antes da chamada, por id), privado.lembrar_chamadas
-- (as chamadas por id, a mesma ordem) e public.publicar_a_partir_da_chamada (a origem e as irmãs que
-- ela encerra, travadas por id num comando só; seção no fim). As três seguem a regra vaga -> chamada
-- -> usuario, com as vagas em ordem de id. Medido com a ordem forçada por uma terceira conexão em
-- scripts/corrida-chamada.sh, cenários 14 a 23; a matriz das funções que travam vaga ou chamada contra
-- o job, com o antes e o depois, está no PR #563.
--
-- A regra única de travas da chamada direta é vaga -> chamada -> usuario (20261117010000,
-- 20261117140000). O job (pg_cron, a cada minuto) era a exceção que a 20261117130000 deixou como
-- resíduo: pegava as chamadas vencidas (FOR UPDATE of c) e só depois a vaga, para encerrar a vaga
-- direta que ficou sem chamada aberta. Quem já tinha a vaga e queria a mesma chamada fechava o
-- ciclo. Medido com a ordem forçada por uma terceira conexão (scripts/corrida-chamada.sh, cenários
-- 14 a 18; números no PR): o aceite que fez a conferência do prazo antes de a chamada vencer, o
-- cancelamento da vaga direta (o gatilho vaga_cancelada_fecha_chamadas quer a chamada ainda no
-- prazo), a exclusão e a suspensão da conta.
--
-- Conserto: o job trava primeiro, num comando só e em ordem de id, as vagas das chamadas vencidas
-- (FOR NO KEY UPDATE, o modo que o update de estado da vaga já pegava: não há troca de modo no
-- meio), e só depois as chamadas vencidas dessas vagas, também em ordem de id. A chamada é relida
-- sob a trava (o FOR UPDATE reconfere "aberta e expira_em <= agora" na versão mais nova):
--   - Quem chegou antes na vaga termina primeiro e vence; o job pula a chamada que não está mais
--     aberta (aceita, cancelada, encerrada) e expira só a que continua aberta e vencida.
--   - A chamada que venceu entre os dois comandos e cuja vaga não foi travada fica para o minuto
--     seguinte (a lista das chamadas é limitada às vagas travadas): nenhuma expiração se perde.
--   - A vaga direta só é encerrada pela conferência da 20261117130000 (B-053), igual: sem chamada
--     aberta nem turno, e de novo sem chamada aberta depois da trava. A trava dela agora já é do
--     job desde o começo (o mesmo modo), então o bloco só reconfirma.
-- skip locked foi descartado: pularia a vaga ocupada e adiaria a expiração sem garantia de que o
-- próximo minuto a encontre livre; a espera em ordem não perde nada e não fecha ciclo.
--
-- Com isto a regra vaga -> chamada -> usuario vale para o job sem resíduo: vagas, depois chamadas,
-- depois o usuario (FOR KEY SHARE, a chave estrangeira do aviso). Ninguém mais pega a chamada e
-- depois a vaga (git grep nas migrações: a recusa, cancelar_chamada e o lembrete pegam só a
-- chamada e não pedem a vaga depois).
--
-- O lembrete (privado.lembrar_chamadas, vigente na 20261107370000, outro job a cada minuto) também
-- passa a pegar as chamadas em ordem de id (parecer do Lince no #563). Ele pegava por lembrete_em,
-- inclusive as vencidas (o prazo só é olhado depois da trava). Com o expirar por id, duas chamadas
-- em que a ordem de id é a inversa da de lembrete_em e expira_em (os jobs retomando depois de um
-- atraso) fechavam ciclo entre os dois jobs: o lembrete com B esperando A, o expirar com A esperando
-- B. Medido com a ordem forçada por uma terceira conexão (scripts/corrida-chamada.sh, cenário 19):
-- 40P01 em 4 de 4 rodadas antes; os dois por id, nenhum. O lembrete não pede vaga (nem antes nem
-- agora): fica chamada só. Corpo, regras (silêncio das 22h às 7h, um lembrete só, aviso só no
-- prazo), retorno, assinatura e grants iguais; só o order by mudou.
--
-- Custo: o job passa a esperar trava de vaga que antes não pegava. Antes ele só pedia a vaga da
-- direta que ia encerrar, e só no fim; agora pede, logo no começo, a vaga de toda chamada aberta e
-- vencida (só essas vagas: nenhuma outra). Espera quem segura uma delas (um aceite, um
-- cancelamento, uma chamada nova, uma exclusão), e quem chega depois espera o job, como já
-- esperava no update de estado. São transações curtas; o job roda a cada minuto.
--
-- Corpo copiado de 20261117130000 (a vigente: develop e PRs abertos, conferido com git grep e
-- gh pr diff), com as duas travas em ordem no começo e o FOR UPDATE das chamadas em ordem de id
-- (era por expira_em). Assinatura e grants iguais. A função é do esquema privado e não está no
-- contrato.

select set_config('lock_timeout', '2s', true);

create or replace function privado.expirar_chamadas()
returns int
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_count   int := 0;
  v_vagas   uuid[];
  r         record;
  v_membro  uuid;
begin
  -- B-065 (#562): a vaga antes da chamada, como o aceite, o cancelamento, a exclusão e a
  -- suspensão. Por id, num comando só, para dois jobs (ou o job e a exclusão de uma conta com
  -- várias vagas) não se cruzarem entre vagas.
  select array_agg(x.id) into v_vagas
    from (select g.id
            from public.vaga g
           where g.id in (select c.vaga_id from public.chamada c
                           where c.estado = 'aberta'
                             and c.expira_em <= v_agora)
           order by g.id
             for no key update) x;

  if v_vagas is null then
    return 0;
  end if;

  for r in
    select c.id, c.vaga_id, c.estabelecimento_id, p.usuario_id as prof_usuario_id
      from public.chamada c
      join public.profissional p on p.id = c.profissional_id
     where c.estado = 'aberta'
       and c.expira_em <= v_agora
       and c.vaga_id = any (v_vagas)
     order by c.id
     for update of c
  loop
    update public.chamada
       set estado = 'expirada',
           respondida_em = v_agora
     where id = r.id;

    -- Notifica o profissional
    insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
    values (r.prof_usuario_id, 'chamada_expirada', r.id, jsonb_build_object('chamada_id', r.id, 'vaga_id', r.vaga_id))
    on conflict do nothing;

    -- Notifica os membros do estabelecimento
    for v_membro in
      select me.usuario_id from public.membro_estabelecimento me where me.estabelecimento_id = r.estabelecimento_id
    loop
      insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
      values (v_membro, 'chamada_expirada', r.id, jsonb_build_object('chamada_id', r.id, 'vaga_id', r.vaga_id))
      on conflict do nothing;
    end loop;

    -- Encerra vaga direta se não houver mais chamadas abertas nem turnos
    if not exists (select 1 from public.chamada x where x.vaga_id = r.vaga_id and x.estado = 'aberta')
       and not exists (select 1 from public.turno t join public.posicao pos on pos.id = t.posicao_id where pos.vaga_id = r.vaga_id) then
      -- B-053 (#550): a vaga é travada e as chamadas abertas são conferidas de novo, já depois da
      -- trava. Um chamar_profissional (com vaga_id) que a segurava terminou antes: a chamada dele
      -- aparece aqui, e a vaga fica publicada. O modo é o do update abaixo. Desde a B-065 a vaga já
      -- é do job (a trava do começo, no mesmo modo): este comando só reconfirma.
      perform 1 from public.vaga g
        where g.id = r.vaga_id and g.estado = 'publicada' and g.origem = 'chamada_direta'
          for no key update;
      if found and not exists (select 1 from public.chamada x where x.vaga_id = r.vaga_id and x.estado = 'aberta') then
        update public.vaga set estado = 'encerrada' where id = r.vaga_id and estado = 'publicada' and origem = 'chamada_direta';
      end if;
    end if;

    v_count := v_count + 1;
  end loop;

  return v_count;
end $$;

comment on function privado.expirar_chamadas() is
  'Expira chamadas cujo prazo venceu (expira_em <= now()), emitindo notificações chamada_expirada (RN31, RN33, B5c). A vaga direta sem chamada aberta nem turno é encerrada. Trava as vagas das chamadas vencidas antes delas, em ordem de id (vaga -> chamada -> usuario, como o aceite, o cancelamento, a exclusão e a suspensão), e a conferência das chamadas abertas roda com a vaga travada, para não encerrar a vaga que acabou de receber mais uma chamada (B-053, B-065).';
revoke all on function privado.expirar_chamadas() from public, anon, authenticated;
grant execute on function privado.expirar_chamadas() to service_role;

-- O lembrete: corpo da 20261107370000 (a vigente: develop e PRs abertos, conferido com git grep e
-- gh pr diff), com o FOR UPDATE das chamadas em ordem de id (era por lembrete_em), como o expirar.
create or replace function privado.lembrar_chamadas()
returns int
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_hora_sp int         := extract(hour from (v_agora at time zone 'America/Sao_Paulo'))::int;
  v_count   int         := 0;
  r         record;
begin
  -- Não dispara lembretes durante o horário de silêncio (22h às 7h horário de Brasília)
  if v_hora_sp >= 22 or v_hora_sp < 7 then
    return 0;
  end if;

  -- B-065 (#562): por id, a mesma ordem do expirar_chamadas, para os dois jobs não se cruzarem.
  for r in
    select c.id, c.vaga_id, c.expira_em, p.usuario_id as prof_usuario_id
      from public.chamada c
      join public.profissional p on p.id = c.profissional_id
     where c.estado = 'aberta'
       and c.lembrete_em is not null
       and c.lembrete_em <= v_agora
     order by c.id
     for update of c
  loop
    update public.chamada
       set lembrete_em = null
     where id = r.id;

    -- Só notifica se a chamada ainda não tiver expirado
    if r.expira_em > v_agora then
      insert into public.notificacao (usuario_id, tipo, referencia_id, payload)
      values (r.prof_usuario_id, 'chamada_lembrete', r.id, jsonb_build_object('chamada_id', r.id, 'vaga_id', r.vaga_id))
      on conflict do nothing;

      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end $$;

comment on function privado.lembrar_chamadas() is
  'Dispara lembrete único para chamadas com lembrete_em atingido (RN31, CD-RF11, B5c). Trava as chamadas em ordem de id, a mesma do expirar_chamadas, para os dois jobs não fecharem ciclo (B-065).';
revoke all on function privado.lembrar_chamadas() from public, anon, authenticated;
grant execute on function privado.lembrar_chamadas() to service_role;

-- ── publicar_a_partir_da_chamada: a origem e as irmãs em ordem de id (parecer do Lince r2, #563) ──
--
-- A pré-trava das vagas por id do expirar_chamadas cruzava com a conversão. publicar_a_partir_da_chamada
-- travava a origem (FOR UPDATE) e só depois, no update das irmãs (as outras vagas diretas da casa para o
-- mesmo trabalho, ainda publicadas: CD-C15), pegava as irmãs, sem ordem. A trava da casa não serializa
-- com o job, que não a pega. Com duas irmãs G1 < G2, cada uma com uma chamada vencida e outra no prazo,
-- e a conversão de G2: a conversão segurava G2 e esperava G1; o job segurava G1 e esperava G2. Medido
-- com a ordem forçada por uma terceira conexão (scripts/corrida-chamada.sh, cenário 20): 40P01 antes.
--
-- Conserto: depois da trava da casa, a origem é lida sem trava; a origem e as irmãs candidatas (mesma
-- casa, chamada_direta, publicada, mesma função, início e fim até o minuto, o filtro do update) são
-- travadas FOR UPDATE num comando só, em ordem de id; a origem é relida e o corpo segue igual
-- (idempotência, conferências, 409 vaga_encerrada de #523, encerramento das irmãs e das chamadas, avisos,
-- despacho). Ler a origem sem trava é seguro para achar as irmãs: função, início e fim de uma vaga não
-- mudam depois de criada (git grep nas migrações: nenhum update de vaga os altera; o gatilho
-- vaga_horario_sincroniza só copia o horário para a posição). Uma vaga que vire irmã publicada entre a
-- trava e o update (reabrir_por_atraso de uma direta preenchida já confirmada) ainda é pega no update,
-- como antes.
--
-- Corpo copiado de 20261117150000 (a vigente: develop e PRs abertos, conferido com git grep e
-- gh pr diff), só com a trava acima. Comentário, assinatura e grants iguais.

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

  -- B-065 (#563): a origem e as irmãs que o update abaixo encerra são travadas num comando só, em
  -- ordem de id, a ordem do expirar_chamadas (que não pega a trava da casa). Antes, a origem era
  -- travada primeiro e as irmãs só no update, fora de ordem. A origem é lida sem trava para achar as
  -- irmãs: função, início e fim de uma vaga não mudam (nenhuma função os altera).
  select * into v_orig from public.vaga where id = publicar_a_partir_da_chamada.vaga_id;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;
  perform 1
    from public.vaga g
   where g.id = v_orig.id
      or (g.estabelecimento_id = v_orig.estabelecimento_id
          and g.origem = 'chamada_direta' and g.estado = 'publicada'
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

  -- Janela de conversão: antes do início OU reaberta por atraso até fim_em - 1h (RN35). Direta já preenchida: 409.
  if v_orig.estado in ('cancelada', 'encerrada', 'preenchida')
     or (v_orig.inicio_em <= v_agora and not exists (
           select 1 from public.posicao pos where pos.vaga_id = v_orig.id and pos.estado = 'aberta' and pos.falta
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
