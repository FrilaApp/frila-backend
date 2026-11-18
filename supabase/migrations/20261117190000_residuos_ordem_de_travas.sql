-- Os resíduos de ordem de travas depois do #562 (B-069, issue #565).
--
-- A 20261117170000 deixou registrados três riscos (cabeçalho dela, :10-27). Medidos com a ordem forçada
-- por uma terceira conexão (scripts/corrida-chamada.sh, cenários 25 a 27), os três fechavam ciclo: 40P01
-- em 10 de 10 rodadas cada, sempre no job. Todos têm a mesma forma: um update de várias linhas da mesma
-- tabela, sem ordem própria, contra um job que pega as mesmas linhas por id. Com A < B pelo id e o update
-- lendo B antes de A, o update pega B e para numa linha do meio; o job pega A e espera B; o update quer A.
--   1. privado.fechar_turnos_e_vagas (20261015140000:87-95, cron a cada 5 min) encerra as vagas terminadas
--      num update cujo plano é um hash anti join (sai na ordem do hash do id) x privado.expirar_chamadas,
--      que trava as vagas das chamadas vencidas por id. Pede o job atrasado: chamada aberta e vencida numa
--      vaga já terminada (cenário 25).
--   2. public.publicar_a_partir_da_chamada encerra as chamadas abertas da origem e das irmãs num update na
--      ordem física x privado.lembrar_chamadas, que trava as chamadas por id (cenário 26).
--   3. privado.limpar_contas_anonimizadas sanitiza, no passo 6, as vagas da conta excluída num update na
--      ordem física x privado.expirar_chamadas. Não é a chamada antes da vaga que a issue citava (essa a
--      anonimização afasta: as chamadas da conta já estão canceladas): é vaga contra vaga, com as chamadas
--      abertas de outro membro da casa nas vagas que a conta excluída publicou, e o job atrasado (cenário 27).
--   Fica de fora privado.anonimizar_contexto_das_vagas: os três chamadores pegam antes as vagas por id com
--   skip locked (20261109180000:208-216, 20261108100000:318-353), e ela só alcança vaga terminada há anos.
--
-- Conserto: antes de cada update, um comando só trava as mesmas linhas em ordem de id, no modo do update
-- (FOR NO KEY UPDATE para a vaga, FOR UPDATE para a chamada, o do lembrete). O update fica como estava,
-- com o filtro dele inteiro: o que muda de estado enquanto a trava espera é relido pelo próprio update, e
-- nada que ele fechava, encerrava ou sanitizava deixa de ser. A regra é a do #562: vaga -> chamada ->
-- usuario, vagas e chamadas por id.
--   1. fechar_turnos_e_vagas: antes do cancelamento das posições abertas e terminadas, as vagas que o
--      update vai encerrar (publicada ou preenchida, terminadas, sem posição confirmada nem aberta que
--      ainda não terminou: o filtro do update depois do cancelamento). Custo: as vagas que a rodada
--      encerra, que o update já travava até o fim da transação; com o job em dia, as que terminaram nos
--      últimos 5 minutos. Inferência: uma vaga que entre no filtro durante a espera (nenhuma função põe
--      vaga terminada em publicada) é pega pelo update como antes.
--   2. publicar_a_partir_da_chamada: depois das irmãs e antes do update das chamadas, as chamadas abertas
--      da origem e das irmãs. Custo: as chamadas abertas dessas vagas (uma por profissional chamado), que
--      o update já travava. Nenhuma nasce na espera: chamar_profissional pede a casa e a vaga, que já são
--      desta transação.
--   3. limpar_contas_anonimizadas: antes do update do passo 6, as vagas que ele sanitiza (o filtro dele,
--      igual). Custo: as vagas da conta que o update já travava. Inferência: uma vaga que entre no filtro
--      durante a espera (uma publicada futura cancelada nesse meio tempo) é pega pelo update como antes.
-- Nenhuma das três passa a esperar trava que não esperava: são as mesmas linhas, só que antes e em ordem.
--
-- Corpos copiados das vigentes (develop e PRs abertos, conferido com git grep e gh pr diff):
-- fechar_turnos_e_vagas da 20261015140000, publicar_a_partir_da_chamada da 20261117180000 e
-- limpar_contas_anonimizadas da 20261107350000, só com os blocos de pré-trava e uma frase no comentário.
-- Assinaturas, SECURITY DEFINER, search_path vazio e grants iguais. Só a conversão está no contrato, e a
-- superfície dela não muda.

select set_config('lock_timeout', '2s', true);

-- ── 1. privado.fechar_turnos_e_vagas ───────────────────────────────────────────

create or replace function privado.fechar_turnos_e_vagas()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora    timestamptz := privado.agora();
  v_fechados integer := 0;
  v_posicoes integer := 0;
  v_turno    record;
begin
  -- Reutiliza o fechamento de turnos manuais e a atualização dos contadores.
  v_fechados := privado.fechar_turnos_passados();

  -- A posição cumprida é o registro do turno encerrado; a verificação é atributo
  -- do turno e não impede o fechamento da posição.
  update public.posicao p
     set estado = 'cumprida'
   where p.estado = 'confirmada'
     and p.fim_em <= v_agora;
  get diagnostics v_posicoes = row_count;
  v_fechados := v_fechados + v_posicoes;

  -- Só a presença verificada abre avaliação. A chave (tipo, referência, conta)
  -- dentro de privado.notificar torna a execução idempotente.
  -- Achado 2: filtra por not exists para turnos que já receberam avaliacao_disponivel,
  -- além de janela retroativa de 7 dias, eliminando a varredura O(N) de todo o histórico.
  for v_turno in
    select t.id as turno_id,
           p.profissional_id,
           v.estabelecimento_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v on v.id = p.vaga_id
     where p.estado = 'cumprida'
       and p.fim_em <= v_agora
       and p.fim_em >= v_agora - interval '7 days'
       and t.verificacao = 'verificado'
       and not exists (
         select 1
           from public.notificacao n
          where n.tipo = 'avaliacao_disponivel'
            and n.referencia_id = t.id
       )
  loop
    perform privado.notificar(
      privado.usuario_do_profissional(v_turno.profissional_id),
      'avaliacao_disponivel',
      v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id));

    perform privado.notificar_membros(
      v_turno.estabelecimento_id,
      'avaliacao_disponivel',
      v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id));
  end loop;

  -- B-069 (#565): as vagas que o update abaixo vai encerrar são travadas antes, em ordem de id, a
  -- ordem do expirar_chamadas (20261117170000), num comando só; o update, sem ordem própria (o plano
  -- é um hash anti join: sai na ordem do hash do id), não pega mais nenhuma delas fora de ordem. O
  -- filtro é o do update depois do cancelamento das posições abertas e terminadas logo abaixo: sem
  -- posição confirmada nem aberta que ainda não terminou. O modo é o do update (FOR NO KEY UPDATE).
  -- O update segue com o filtro dele, inteiro, e encerra tudo o que encerrava.
  perform 1
    from public.vaga v
   where v.estado in ('publicada', 'preenchida')
     and v.fim_em <= v_agora
     and not exists (
       select 1
         from public.posicao p
        where p.vaga_id = v.id
          and (p.estado = 'confirmada' or (p.estado = 'aberta' and p.fim_em > v_agora)))
   order by v.id
     for no key update of v;

  -- Cancela posições abertas cujo turno terminou sem confirmação.
  -- Sem isto, posições não preenchidas ficavam como 'aberta' indefinidamente,
  -- impedindo o encerramento da vaga e acumulando registros no índice GiST.
  update public.posicao p
     set estado = 'cancelada'
   where p.estado = 'aberta'
     and p.fim_em <= v_agora;

  -- Uma vaga só deixa de aparecer como publicada/preenchida quando não há
  -- posição aberta ou confirmada para ela.
  update public.vaga v
     set estado = 'encerrada'
   where v.estado in ('publicada', 'preenchida')
     and v.fim_em <= v_agora
     and not exists (
       select 1
         from public.posicao p
        where p.vaga_id = v.id
          and p.estado in ('aberta', 'confirmada'));

  return v_fechados;
end $$;

comment on function privado.fechar_turnos_e_vagas() is
  'Job a cada cinco minutos: reutiliza o fechamento de turnos passados, conclui posições confirmadas, cancela posições abertas cujo turno terminou, enfileira avaliacao_disponivel para os dois lados (com not exists para evitar revarredura histórica) e encerra vagas sem posição aberta ou confirmada. As vagas que encerra são travadas antes, em ordem de id, a ordem do expirar_chamadas (B-069, #565).';

revoke execute on function privado.fechar_turnos_e_vagas() from public, anon, authenticated;
grant  execute on function privado.fechar_turnos_e_vagas() to service_role;

-- ── 2. public.publicar_a_partir_da_chamada ─────────────────────────────────────

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

  -- B-069 (#565): as chamadas abertas da origem e das irmãs são travadas antes do update, em ordem de
  -- id, a ordem do lembrar_chamadas e do expirar_chamadas (20261117170000). O update, sem ordem própria
  -- (varre na ordem física), pegava as chamadas fora de ordem. Nenhuma chamada nova nasce nessas vagas
  -- enquanto isso: chamar_profissional pede a casa e a vaga, que já são desta transação. O update segue
  -- com o filtro dele e encerra todas as abertas.
  perform 1
    from public.chamada c
   where c.vaga_id = any(array[v_orig.id] || v_irmas) and c.estado = 'aberta'
   order by c.id
     for update;

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
  '0.2.56 e 0.2.95. Converte vaga direta em vaga aberta ao público com vaga_origem_id, encerrando a direta e chamadas abertas (RN35, RN46). 0.2.95: sob a trava da casa, encerra também as outras vagas diretas da casa para o mesmo trabalho (função, início e fim até o minuto) ainda publicadas, e as chamadas abertas delas, com o mesmo aviso; a preenchida não é tocada (CD-C15). Vaga direta já preenchida, cancelada ou encerrada: 409 vaga_encerrada (#523). Trava a casa, as vagas do trabalho por id e as chamadas abertas que encerra por id (#563, #565).';
revoke execute on function public.publicar_a_partir_da_chamada(uuid, uuid, text) from public, anon;
grant  execute on function public.publicar_a_partir_da_chamada(uuid, uuid, text) to authenticated;

-- ── 3. privado.limpar_contas_anonimizadas ──────────────────────────────────────

create or replace function privado.limpar_contas_anonimizadas(p_dias integer default 15)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_candidato record;
  v_total     integer := 0;
begin
  for v_candidato in
    select u.id, p.id as profissional_id
      from public.usuario u
      left join public.profissional p on p.usuario_id = u.id
     where u.estado = 'anonimizada'
       and u.anonimizado_em <= privado.agora() - (p_dias || ' days')::interval
       and (
         u.nascimento is not null
         or p.ponto_base is not null
         or p.apresentacao is not null
         or p.onde_trabalhei is not null
         or p.experiencia_faixa is not null
         or p.cursos is not null
         or p.idiomas is not null
         or exists (select 1 from public.disponibilidade d where d.profissional_id = p.id)
         or exists (select 1 from public.profissional_funcao pf where pf.profissional_id = p.id)
         or exists (select 1 from public.dispositivo disp where disp.usuario_id = u.id)
         or exists (select 1 from public.ocorrencia o
                     where o.autor_id = u.id
                       and (o.motivo <> '[removido por exclusão de conta]' or o.relato is not null))
         or exists (
           select 1 from public.chamada c
            where (c.criada_por = u.id or c.profissional_id = p.id)
              and c.recado is not null
         )
         or exists (
           select 1 from public.vaga g
            where g.publicado_por = u.id
              and (
                (
                  not (
                    (g.estado = 'publicada' and g.inicio_em > privado.agora())
                    or exists (
                      select 1 from public.posicao po
                       join public.turno tu on tu.posicao_id = po.id
                      where po.vaga_id = g.id
                        and po.estado <> 'cancelada'
                        and tu.checkout_em is null
                        and po.fim_em + interval '7 days' >= privado.agora()
                    )
                  )
                  and (
                    g.responsavel_local <> '[removido por exclusão de conta]'
                    or g.traje is not null
                    or g.observacoes is not null
                  )
                )
                or (
                  g.local <> '[removido por exclusão de conta]'
                  and not (
                    (g.estado = 'publicada' and g.inicio_em > privado.agora())
                    or exists (
                      select 1 from public.posicao po
                       join public.turno tu on tu.posicao_id = po.id
                      where po.vaga_id = g.id
                        and (
                          (po.estado <> 'cancelada'
                           and tu.checkout_em is null
                           and po.fim_em + interval '7 days' >= privado.agora())
                          or tu.verificacao = 'verificado'
                        )
                    )
                  )
                )
              )
         )
       )
  loop
    perform set_config('privado.retencao', 'on', true);

    -- 1. Apaga disponibilidade semanal, funções e ponto base do profissional
    if v_candidato.profissional_id is not null then
      delete from public.disponibilidade where profissional_id = v_candidato.profissional_id;
      delete from public.profissional_funcao where profissional_id = v_candidato.profissional_id;
      update public.profissional
         set ponto_base = null,
             apresentacao = null,
             onde_trabalhei = null,
             experiencia_faixa = null,
             cursos = null,
             idiomas = null
       where id = v_candidato.profissional_id;
    end if;

    -- 2. Apaga aparelhos registrados
    delete from public.dispositivo where usuario_id = v_candidato.id;

    -- 3. Substitui o motivo das ocorrências de autoria dela pelo marcador neutro e apaga o relato
    update public.ocorrencia
       set motivo = '[removido por exclusão de conta]',
           relato = null
     where autor_id = v_candidato.id
       and (motivo <> '[removido por exclusão de conta]' or relato is not null);

    -- 4. Zera data de nascimento
    update public.usuario
       set nascimento = null
     where id = v_candidato.id;

    -- 5. Sanitiza recado de chamadas diretas (RN42, CD-C19)
    update public.chamada
       set recado = null
     where (criada_por = v_candidato.id or profissional_id = v_candidato.profissional_id)
       and recado is not null;

    -- B-069 (#565): as vagas que o update abaixo sanitiza são travadas antes, em ordem de id, a ordem do
    -- expirar_chamadas (20261117170000); o update, sem ordem própria, pegava várias vagas fora de ordem.
    -- O filtro é o do update, igual. O modo é o do update (FOR NO KEY UPDATE). O update segue com o
    -- filtro dele, inteiro, e sanitiza tudo o que sanitizava.
    perform 1
      from public.vaga g
     where g.publicado_por = v_candidato.id
       and (
         (
           not (
             (g.estado = 'publicada' and g.inicio_em > privado.agora())
             or exists (
               select 1 from public.posicao po
                join public.turno tu on tu.posicao_id = po.id
               where po.vaga_id = g.id
                 and po.estado <> 'cancelada'
                 and tu.checkout_em is null
                 and po.fim_em + interval '7 days' >= privado.agora()
             )
           )
           and (
             g.responsavel_local <> '[removido por exclusão de conta]'
             or g.traje is not null
             or g.observacoes is not null
           )
         )
         or (
           g.local <> '[removido por exclusão de conta]'
           and not (
             (g.estado = 'publicada' and g.inicio_em > privado.agora())
             or exists (
               select 1 from public.posicao po
                join public.turno tu on tu.posicao_id = po.id
               where po.vaga_id = g.id
                 and (
                   (po.estado <> 'cancelada'
                    and tu.checkout_em is null
                    and po.fim_em + interval '7 days' >= privado.agora())
                   or tu.verificacao = 'verificado'
                 )
             )
           )
         )
       )
     order by g.id
       for no key update of g;

    -- 6. Sanitiza texto livre das vagas publicadas pelo titular excluído
    update public.vaga g
       set responsavel_local = case
                                 when (g.estado = 'publicada' and g.inicio_em > privado.agora())
                                   or exists (
                                     select 1 from public.posicao po
                                      join public.turno tu on tu.posicao_id = po.id
                                     where po.vaga_id = g.id
                                       and po.estado <> 'cancelada'
                                       and tu.checkout_em is null
                                       and po.fim_em + interval '7 days' >= privado.agora()
                                   ) then g.responsavel_local
                                 else '[removido por exclusão de conta]'
                               end,
           traje             = case
                                 when (g.estado = 'publicada' and g.inicio_em > privado.agora())
                                   or exists (
                                     select 1 from public.posicao po
                                      join public.turno tu on tu.posicao_id = po.id
                                     where po.vaga_id = g.id
                                       and po.estado <> 'cancelada'
                                       and tu.checkout_em is null
                                       and po.fim_em + interval '7 days' >= privado.agora()
                                   ) then g.traje
                                 else null
                               end,
           observacoes       = case
                                 when (g.estado = 'publicada' and g.inicio_em > privado.agora())
                                   or exists (
                                     select 1 from public.posicao po
                                      join public.turno tu on tu.posicao_id = po.id
                                     where po.vaga_id = g.id
                                       and po.estado <> 'cancelada'
                                       and tu.checkout_em is null
                                       and po.fim_em + interval '7 days' >= privado.agora()
                                   ) then g.observacoes
                                 else null
                               end,
           local             = case
                                 when (g.estado = 'publicada' and g.inicio_em > privado.agora())
                                   or exists (
                                     select 1 from public.posicao po
                                      join public.turno tu on tu.posicao_id = po.id
                                     where po.vaga_id = g.id
                                       and (
                                         (po.estado <> 'cancelada'
                                          and tu.checkout_em is null
                                          and po.fim_em + interval '7 days' >= privado.agora())
                                         or tu.verificacao = 'verificado'
                                       )
                                   ) then g.local
                                 else '[removido por exclusão de conta]'
                               end
     where g.publicado_por = v_candidato.id
       and (
         (
           not (
             (g.estado = 'publicada' and g.inicio_em > privado.agora())
             or exists (
               select 1 from public.posicao po
                join public.turno tu on tu.posicao_id = po.id
               where po.vaga_id = g.id
                 and po.estado <> 'cancelada'
                 and tu.checkout_em is null
                 and po.fim_em + interval '7 days' >= privado.agora()
             )
           )
           and (
             g.responsavel_local <> '[removido por exclusão de conta]'
             or g.traje is not null
             or g.observacoes is not null
           )
         )
         or (
           g.local <> '[removido por exclusão de conta]'
           and not (
             (g.estado = 'publicada' and g.inicio_em > privado.agora())
             or exists (
               select 1 from public.posicao po
                join public.turno tu on tu.posicao_id = po.id
               where po.vaga_id = g.id
                 and (
                   (po.estado <> 'cancelada'
                    and tu.checkout_em is null
                    and po.fim_em + interval '7 days' >= privado.agora())
                   or tu.verificacao = 'verificado'
                 )
             )
           )
         )
       );

    perform set_config('privado.retencao', 'off', true);
    v_total := v_total + 1;
  end loop;

  return v_total;
end $$;

comment on function privado.limpar_contas_anonimizadas(integer) is
  'Limpa dados residuais de contas anonimizadas após o período de retenção (padrão 15 dias). Apaga disponibilidade, funções, aparelhos, zera nascimento, sanitiza recado de chamada direta e textos livres de vagas publicadas pelo titular excluído. As vagas que sanitiza são travadas antes, em ordem de id, a ordem do expirar_chamadas (B-069, #565).';

revoke execute on function privado.limpar_contas_anonimizadas(integer) from public, anon, authenticated;
grant  execute on function privado.limpar_contas_anonimizadas(integer) to service_role;
