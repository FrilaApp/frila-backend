-- 20261031153000_sanitizar_texto_vaga_exclusao.sql
--
-- Higiene e conformidade LGPD (K-001, PR #614 do frila-frontend, E12):
-- Sanitização do texto livre da vaga (responsavel_local, observacoes, traje, local) na exclusão de conta.
--
-- 1. Contexto e Justificativa de Negócio / LGPD:
--    A tabela public.vaga possui quatro campos de texto livre (responsavel_local, observacoes,
--    traje, local) que podem conter dados pessoais (nomes, telefones, instruções privadas ou
--    endereços residenciais).
--    Ao excluir uma conta de contratante (privado.excluir_conta), as vagas abertas ou preenchidas
--    de estabelecimentos sem outros membros são canceladas, mas seus textos permaneciam íntegros.
--
-- 2. Menor Ajuste Seguro e Preservação de Auditoria Mútua:
--    - Na hora da exclusão (privado.excluir_conta):
--      * Vagas canceladas SEM turno em andamento têm texto livre sanitizado imediatamente:
--        responsavel_local = '[removido por exclusão de conta]', traje = null, observacoes = null,
--        e local = '[removido por exclusão de conta]'.
--      * Vagas que possuam turno em andamento (já iniciado e não concluído) preservam o texto
--        para que o profissional em serviço disponha das instruções e contato até o término do turno.
--    - Na rotina de retenção de 15 dias (privado.limpar_contas_anonimizadas):
--      * Após a janela de 15 dias (quando qualquer turno em andamento já foi finalizado),
--        responsavel_local, traje e observacoes de todas as vagas publicadas pelo titular excluído
--        são sanitizados.
--      * O campo 'local' é preservado exclusivamente nas vagas com turnos cumpridos/verificados,
--        assegurando o tratamento para exercício regular de direitos (LGPD art. 7º, VI) e
--        legítimo interesse/obrigação do controlador conforme o caso (com base jurídica exata
--        em avaliação pelo Jurídico), para que o histórico de trabalho da contraparte (profissional)
--        em meus_turnos() e a trilha probatória do serviço permaneçam íntegros. Nas vagas sem
--        turnos cumpridos, 'local' é também redigido.

-- 1. Atualiza privado.excluir_conta
create or replace function privado.excluir_conta(p_usuario_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_uid        uuid := coalesce(p_usuario_id, (select auth.uid()));
  v_agora      timestamptz := privado.agora();
  v_usuario    public.usuario%rowtype;
  v_pos        public.posicao%rowtype;
  v_cand       record;
  v_estab      uuid;
  v_cancelados integer := 0;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- ── Ordem de aquisição: a vaga antes do usuario ─────────────────────────────
  perform 1 from public.vaga g
   where g.estabelecimento_id in (
     select m.estabelecimento_id from public.membro_estabelecimento m
      where m.usuario_id = v_uid
        and not exists (
          select 1 from public.membro_estabelecimento x
           where x.estabelecimento_id = m.estabelecimento_id
             and x.usuario_id <> v_uid))
     and g.estado in ('publicada', 'preenchida')
   order by g.id
     for update;

  select * into v_usuario from public.usuario u where u.id = v_uid for update;

  -- Idempotência: se a conta nem chegou a ser criada em public.usuario
  if not found then
    return jsonb_build_object(
      'perfil_removido_em', v_agora,
      'dados_apagados_ate', (v_agora::date + 15),
      'turnos_cancelados', 0);
  end if;

  -- Idempotência: conta já anonimizada
  if v_usuario.estado = 'anonimizada' then
    return jsonb_build_object(
      'perfil_removido_em', coalesce(v_usuario.anonimizado_em, v_agora),
      'dados_apagados_ate', (coalesce(v_usuario.anonimizado_em, v_agora)::date + 15),
      'turnos_cancelados', 0);
  end if;

  -- Só há conflito quando a administração ficaria sem outro administrador (RF25).
  if exists (
    select 1
      from public.membro_estabelecimento m
     where m.usuario_id = v_uid
       and m.papel = 'administrador'
       and (select count(*) from public.membro_estabelecimento x
             where x.estabelecimento_id = m.estabelecimento_id) > 1
       and (select count(*) from public.membro_estabelecimento x
             where x.estabelecimento_id = m.estabelecimento_id
               and x.papel = 'administrador') = 1
  ) then
    perform public.erro(409, 'administrador_unico');
  end if;

  perform set_config('frila.exclusao_de_conta', 'on', true);
  perform set_config('frila.autor_da_exclusao', v_uid::text, true);

  -- 1. Se for profissional: reabre cada turno futuro através de privado.cancelar_uma_posicao
  if v_usuario.perfil = 'profissional' then
    for v_pos in
      select p.*
        from public.posicao p
       where p.estado = 'confirmada'
         and p.inicio_em > v_agora
         and p.profissional_id = (select x.id from public.profissional x where x.usuario_id = v_uid)
    loop
      perform privado.cancelar_uma_posicao(v_pos.id, v_uid, 'exclusão de conta', true);
      v_cancelados := v_cancelados + 1;
    end loop;
  end if;

  -- 2. Se for contratante: cancela turnos futuros confirmados de estabelecimentos onde for único membro
  if v_usuario.perfil = 'contratante' then
    for v_pos in
      select p.*
        from public.posicao p
        join public.vaga g on g.id = p.vaga_id
       where p.estado = 'confirmada'
         and p.inicio_em > v_agora
         and exists (
           select 1 from public.membro_estabelecimento m
            where m.estabelecimento_id = g.estabelecimento_id
              and m.usuario_id = v_uid
              and not exists (
                select 1 from public.membro_estabelecimento x
                 where x.estabelecimento_id = m.estabelecimento_id
                   and x.usuario_id <> v_uid))
    loop
      perform privado.cancelar_uma_posicao(v_pos.id, v_uid, 'exclusão de conta', false);
      v_cancelados := v_cancelados + 1;
    end loop;
  end if;

  -- Se for profissional: retirar candidaturas pendentes
  if v_usuario.perfil = 'profissional' then
    update public.candidatura
       set estado = 'retirada'
     where profissional_id = (select id from public.profissional where usuario_id = v_uid)
       and estado = 'pendente';
  end if;

  -- Se era o último membro, nenhuma vaga aberta pode continuar sem responsável.
  if v_usuario.perfil = 'contratante' then
    for v_estab in
      select m.estabelecimento_id
        from public.membro_estabelecimento m
       where m.usuario_id = v_uid
         and not exists (
           select 1 from public.membro_estabelecimento x
            where x.estabelecimento_id = m.estabelecimento_id
              and x.usuario_id <> v_uid)
    loop
      -- Retira candidaturas pendentes das vagas que serão canceladas e notifica os candidatos
      for v_cand in
        select c.id, c.profissional_id, p.vaga_id
          from public.candidatura c
          join public.posicao p on p.id = c.posicao_id
          join public.vaga g on g.id = p.vaga_id
         where g.estabelecimento_id = v_estab
           and c.estado = 'pendente'
      loop
        update public.candidatura set estado = 'retirada' where id = v_cand.id;
        perform privado.notificar(
          privado.usuario_do_profissional(v_cand.profissional_id),
          'cancelamento',
          v_cand.vaga_id,
          jsonb_build_object('vaga_id', v_cand.vaga_id, 'reaberta', false)
        );
      end loop;

      -- Ordem das travas (CPD2c74A): trava as vagas antes das posições.
      perform 1 from public.vaga g
       where g.estabelecimento_id = v_estab
         and g.estado in ('publicada', 'preenchida')
       order by g.id
         for update;

      update public.posicao p
         set estado = 'cancelada'
       where p.vaga_id in (
         select g.id from public.vaga g
          where g.estabelecimento_id = v_estab
            and g.estado in ('publicada', 'preenchida'))
         and p.estado = 'aberta';

      -- Cancela as vagas do estabelecimento solo e sanitiza o texto livre (K-001).
      -- Se a vaga preenchida tiver turno em andamento (já iniciado e não concluído),
      -- a vaga vai para cancelada mas o texto livre é preservado até o término do turno
      -- para auditoria mútua e apoio ao profissional em serviço. Vagas sem turno em andamento
      -- têm o texto livre redigido/anulado imediatamente.
      update public.vaga g
         set estado            = 'cancelada',
             responsavel_local = case
                                   when exists (
                                     select 1 from public.posicao po
                                      join public.turno tu on tu.posicao_id = po.id
                                     where po.vaga_id = g.id
                                       and po.estado <> 'cancelada'
                                       and tu.checkout_em is null
                                   ) then g.responsavel_local
                                   else '[removido por exclusão de conta]'
                                 end,
             traje             = case
                                   when exists (
                                     select 1 from public.posicao po
                                      join public.turno tu on tu.posicao_id = po.id
                                     where po.vaga_id = g.id
                                       and po.estado <> 'cancelada'
                                       and tu.checkout_em is null
                                   ) then g.traje
                                   else null
                                 end,
             observacoes       = case
                                   when exists (
                                     select 1 from public.posicao po
                                      join public.turno tu on tu.posicao_id = po.id
                                     where po.vaga_id = g.id
                                       and po.estado <> 'cancelada'
                                       and tu.checkout_em is null
                                   ) then g.observacoes
                                   else null
                                 end,
             local             = case
                                   when exists (
                                     select 1 from public.posicao po
                                      join public.turno tu on tu.posicao_id = po.id
                                     where po.vaga_id = g.id
                                       and po.estado <> 'cancelada'
                                       and tu.checkout_em is null
                                   ) then g.local
                                   else '[removido por exclusão de conta]'
                                 end
       where g.estabelecimento_id = v_estab
         and g.estado in ('publicada', 'preenchida');
    end loop;
    delete from public.membro_estabelecimento where usuario_id = v_uid;
  end if;

  perform set_config('frila.exclusao_de_conta', 'off', true);
  perform set_config('frila.autor_da_exclusao', '', true);

  -- Remove os aparelhos registrados
  delete from public.dispositivo where usuario_id = v_uid;

  -- Anonimiza usuario: nome 'Conta encerrada', telefone e e-mail nulos; nascimento e ponto base ficam para o job de retenção
  update public.usuario
     set nome = 'Conta encerrada',
         telefone = null,
         email = null,
         estado = 'anonimizada',
         anonimizado_em = v_agora
   where id = v_uid;

  return jsonb_build_object(
    'perfil_removido_em', v_agora,
    'dados_apagados_ate', (v_agora::date + 15),
    'turnos_cancelados', v_cancelados);
end $function$;

comment on function privado.excluir_conta(uuid) is
  'Exclui/anonimiza conta de usuário (RF25, direito de eliminação - LGPD art. 18). Se contratante único membro, cancela turnos futuros, retira candidaturas pendentes, cancela vagas e sanitiza texto livre preservando turnos em andamento para auditoria.';

revoke execute on function privado.excluir_conta(uuid) from public, anon, authenticated;
grant  execute on function privado.excluir_conta(uuid) to service_role;

-- 2. Atualiza privado.limpar_contas_anonimizadas
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
         or exists (select 1 from public.disponibilidade d where d.profissional_id = p.id)
         or exists (select 1 from public.profissional_funcao pf where pf.profissional_id = p.id)
         or exists (select 1 from public.dispositivo disp where disp.usuario_id = u.id)
         or exists (select 1 from public.ocorrencia o
                     where o.autor_id = u.id
                       and (o.motivo <> '[removido por exclusão de conta]' or o.relato is not null))
         or exists (
           select 1 from public.vaga g
            where g.publicado_por = u.id
              and (
                g.responsavel_local <> '[removido por exclusão de conta]'
                or g.traje is not null
                or g.observacoes is not null
                or (g.local <> '[removido por exclusão de conta]'
                    and not exists (
                      select 1 from public.posicao po
                       join public.turno tu on tu.posicao_id = po.id
                      where po.vaga_id = g.id
                        and tu.verificacao = 'verificado'
                    ))
              )
         )
       )
  loop
    -- Ativa sinal de sessão para permitir substituição de dados imutáveis sob retenção
    perform set_config('privado.retencao', 'on', true);

    -- 1. Apaga disponibilidade semanal, funções e ponto base do profissional
    if v_candidato.profissional_id is not null then
      delete from public.disponibilidade where profissional_id = v_candidato.profissional_id;
      delete from public.profissional_funcao where profissional_id = v_candidato.profissional_id;
      update public.profissional
         set ponto_base = null
       where id = v_candidato.profissional_id;
    end if;

    -- 2. Apaga aparelhos registrados
    delete from public.dispositivo where usuario_id = v_candidato.id;

    -- 3. Substitui o motivo das ocorrências de autoria dela pelo marcador neutro e
    --    apaga o relato da denúncia
    update public.ocorrencia
       set motivo = '[removido por exclusão de conta]',
           relato = null
     where autor_id = v_candidato.id
       and (motivo <> '[removido por exclusão de conta]' or relato is not null);

    -- 4. Zera data de nascimento
    update public.usuario
       set nascimento = null
     where id = v_candidato.id;

    -- 5. Sanitiza texto livre das vagas publicadas pelo titular excluído (K-001)
    -- Preserva 'local' nas vagas com turnos cumpridos/verificados para resguardo da auditoria
    -- mútua e histórico de trabalho da contraparte (exercício regular de direitos - LGPD art. 7º, VI,
    -- e legítimo interesse/obrigação do controlador conforme o caso, em avaliação pelo Jurídico).
    update public.vaga g
       set responsavel_local = '[removido por exclusão de conta]',
           traje             = null,
           observacoes       = null,
           local             = case
                                 when exists (
                                   select 1 from public.posicao po
                                    join public.turno tu on tu.posicao_id = po.id
                                   where po.vaga_id = g.id
                                     and tu.verificacao = 'verificado'
                                 ) then g.local
                                 else '[removido por exclusão de conta]'
                               end
     where g.publicado_por = v_candidato.id
       and (
         g.responsavel_local <> '[removido por exclusão de conta]'
         or g.traje is not null
         or g.observacoes is not null
         or (g.local <> '[removido por exclusão de conta]'
             and not exists (
               select 1 from public.posicao po
                join public.turno tu on tu.posicao_id = po.id
               where po.vaga_id = g.id
                 and tu.verificacao = 'verificado'
             ))
       );

    perform set_config('privado.retencao', 'off', true);
    v_total := v_total + 1;
  end loop;

  return v_total;
end $$;

comment on function privado.limpar_contas_anonimizadas(integer) is
  'Apaga disponibilidade, funções, aparelhos, zera nascimento e ponto base, substitui o motivo e apaga o relato das ocorrências e sanitiza texto livre de vagas após p_dias dias, preservando local de turnos verificados para auditoria (RF25, RN15, K-001).';

revoke execute on function privado.limpar_contas_anonimizadas(integer) from public, anon, authenticated;
grant  execute on function privado.limpar_contas_anonimizadas(integer) to service_role;
