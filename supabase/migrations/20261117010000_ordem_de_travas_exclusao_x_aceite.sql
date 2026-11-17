-- Ordem de travas: excluir_conta × responder_chamada (issue #522, B-028).
--
-- O ciclo, lido em pg_locks no meio da espera (diagnóstico B-027):
--
--   responder_chamada: vaga FOR UPDATE -> chamada FOR UPDATE -> insert em public.notificacao
--                      -> usuario do profissional FOR KEY SHARE (checagem da FK usuario_id)
--   excluir_conta:     usuario FOR UPDATE -> ... -> update estado = 'anonimizada'
--                      -> gatilho trg_usuario_anonimizacao_chamada -> update da chamada aberta
--
-- O aceite segura a chamada e espera o usuario; a exclusão segura o usuario e espera a chamada.
-- É o ponto cego do CPD2c74A (20261002090000) de novo: a última aresta do aceite é a checagem
-- de chave estrangeira, que ninguém escreve como trava. O mesmo ciclo fecha quando outro
-- profissional aceita a mesma vaga (o aceite dele encerra a chamada deste e o avisa), quando a
-- casa cancela a chamada (cancelar_chamada: chamada -> aviso ao profissional) e quando o
-- lembrete da chamada sai (lembrar_chamadas: chamada -> aviso).
--
-- A regra passa a ser uma só, a do aceite: vaga -> chamada -> usuario. Antes do usuario, a
-- exclusão trava, por id, as vagas e depois as chamadas abertas que o gatilho vai cancelar
-- (o mesmo predicado de privado.processar_anonimizacao_chamada: a conta é a profissional
-- chamada ou quem chamou), e as vagas da casa de membro único continuam no mesmo comando,
-- antes do usuario, como desde o CPD2c74A. Um aceite em voo termina antes, e a exclusão, que só
-- lê as posições confirmadas depois dessa trava, reabre o turno dele; ou o aceite espera a
-- exclusão e recebe chamada_indisponivel. Prova: cenário 5 de scripts/corrida-chamada.sh, que
-- força as três ordens com uma terceira conexão e dava 40P01 em toda rodada antes desta
-- migração.
--
-- O que não muda, de propósito:
--   * responder_chamada. Travar o usuario no começo do aceite (a outra saída) mexe no caminho
--     quente e não cobre os outros três caminhos acima.
--   * O modo da trava do usuario, FOR UPDATE. FOR NO KEY UPDATE também desfaria o ciclo (o
--     update da exclusão não muda id nem perfil, e esse modo não conflita com a checagem de FK),
--     mas tiraria a barreira: um turno confirmado por outro caminho (a escolha da casa, por
--     exemplo), que hoje espera a exclusão ou cai em 40P01, passaria a confirmar depois de ela
--     ler as posições, e a conta excluída ficaria com turno confirmado.
--
-- Resíduo conhecido, fora deste conserto: três caminhos travam fora dessa ordem.
-- public.bloquear (a FK do bloqueio trava o usuario em FOR KEY SHARE antes de o gatilho dele
-- querer a chamada) e privado.operacao_suspender_conta (usuario FOR UPDATE, depois a chamada
-- pelo gatilho da suspensão) pegam o usuario antes da chamada; privado.expirar_chamadas pega a
-- chamada antes da vaga. Eles só cruzam com a exclusão quando a mesma conta é bloqueada,
-- suspensa ou tem a chamada expirada no mesmo instante em que é excluída; aí um dos dois volta
-- com 40P01 e nada fica pela metade (com expirar_chamadas o ciclo já existia, por outra
-- aresta). A suspensão tem também o ciclo original com o aceite.
--
-- Corpo copiado da versão vigente (20261031153000), com só a troca do bloco de travas do
-- começo. Nenhuma assinatura muda; a função é do esquema privado e não está no contrato.

select set_config('lock_timeout', '2s', true);

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

  -- ── Ordem de aquisição: vaga -> chamada -> usuario, a do aceite (#522) ────────
  --
  -- Antes do usuario, cada uma por id: as vagas e depois as chamadas abertas que o gatilho
  -- trg_usuario_anonimizacao_chamada vai cancelar (o predicado dele, copiado: a conta é quem
  -- chamou ou a profissional chamada). As vagas da casa de membro único entram no mesmo
  -- comando, para a ordem por id valer sobre todas elas (CPD2c74A: a vaga antes do usuario).
  --
  -- A trava da vaga é o que serializa com o aceite, que começa por ela. As posições
  -- confirmadas só são lidas depois daqui: o aceite que terminou antes tem o turno reaberto
  -- logo abaixo, e o que chega depois espera e encontra a chamada cancelada.
  perform 1 from public.vaga g
   where (g.estado in ('publicada', 'preenchida')
          and g.estabelecimento_id in (
            select m.estabelecimento_id from public.membro_estabelecimento m
             where m.usuario_id = v_uid
               and not exists (
                 select 1 from public.membro_estabelecimento x
                  where x.estabelecimento_id = m.estabelecimento_id
                    and x.usuario_id <> v_uid)))
      or g.id in (
           select c.vaga_id from public.chamada c
            where (c.criada_por = v_uid
                   or c.profissional_id = (select p.id from public.profissional p where p.usuario_id = v_uid))
              and c.estado = 'aberta')
   order by g.id
     for update;

  perform 1 from public.chamada c
   where (c.criada_por = v_uid
          or c.profissional_id = (select p.id from public.profissional p where p.usuario_id = v_uid))
     and c.estado = 'aberta'
   order by c.id
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

      -- Cancela as vagas do estabelecimento solo e sanitiza o texto livre (K-001, K-001h).
      -- Se a vaga preenchida tiver turno em andamento (checkout_em is null e fim_em + 7 dias >= agora),
      -- a vaga vai para cancelada mas o texto livre é preservado até o término do turno
      -- para execução de contrato (LGPD art. 7º, V) e apoio ao profissional em serviço. Vagas sem turno em andamento
      -- têm o texto livre redigido/anulado imediatamente (LGPD art. 6º, III e art. 18, IV),
      -- preservando local apenas se o turno for verificado (LGPD art. 7º, VI).
      update public.vaga g
         set estado            = 'cancelada',
             responsavel_local = case
                                   when exists (
                                     select 1 from public.posicao po
                                      join public.turno tu on tu.posicao_id = po.id
                                     where po.vaga_id = g.id
                                       and po.estado <> 'cancelada'
                                       and tu.checkout_em is null
                                       and po.fim_em + interval '7 days' >= v_agora
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
                                       and po.fim_em + interval '7 days' >= v_agora
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
                                       and po.fim_em + interval '7 days' >= v_agora
                                   ) then g.observacoes
                                   else null
                                 end,
             local             = case
                                   when exists (
                                     select 1 from public.posicao po
                                      join public.turno tu on tu.posicao_id = po.id
                                     where po.vaga_id = g.id
                                       and po.estado <> 'cancelada'
                                       and (
                                          (tu.checkout_em is null and po.fim_em + interval '7 days' >= v_agora)
                                          or tu.verificacao = 'verificado'
                                        )
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
  'Exclui/anonimiza conta de usuário (RF25, direito de eliminação - LGPD art. 18, IV). Se contratante único membro, cancela turnos futuros, retira candidaturas pendentes, cancela vagas e sanitiza texto livre preservando turnos em andamento (LGPD art. 7º, V) e local de turnos verificados (LGPD art. 7º, VI).';

revoke execute on function privado.excluir_conta(uuid) from public, anon, authenticated;
grant  execute on function privado.excluir_conta(uuid) to service_role;
