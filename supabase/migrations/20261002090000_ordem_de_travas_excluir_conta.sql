-- Ordem de aquisição de travas em privado.excluir_conta: a vaga antes do usuario
-- (cartão CPD2c74A, RNF14).
--
-- O impasse 40P01 entre privado.excluir_conta e public.candidatar era inversão de ordem de
-- aquisição, e o ciclo só ficou visível depois de scripts/corrida-ciclo.sh passar a gravar o
-- PG_EXCEPTION_CONTEXT do erro. Antes disso o placar guardava apenas "deadlock detected", que
-- diz que houve impasse e não entre o quê.
--
-- Medido, com o cenário 9 provocando a disputa em vez de esperar pelo sorteio dos tempos:
-- 19 de 20 rodadas terminavam em 40P01, e em 7 de 9 o lado abortado era o excluir_conta.
--
-- Esta migração move a trava das vagas para antes da trava de usuario. O corpo da função é o
-- que estava no banco, extraído com pg_get_functiondef para não haver deriva, com essa única
-- mudança de ordem e os comentários que a explicam.

CREATE OR REPLACE FUNCTION privado.excluir_conta(p_usuario_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  --
  -- Esta trava esta aqui, e nao dentro do ramo do contratante, porque a ORDEM importa e a
  -- inversao causava impasse. Medido no cenario 9 do scripts/corrida-ciclo.sh, com o ciclo
  -- lido do PG_EXCEPTION_CONTEXT:
  --
  --   excluir_conta: usuario FOR UPDATE -> vaga FOR UPDATE
  --   candidatar:    vaga FOR UPDATE -> insert em public.notificacao -> usuario FOR KEY SHARE
  --
  -- A ultima aresta e o ponto cego: ela nao e trava escrita no codigo. O FOR KEY SHARE sai
  -- da CHECAGEM DE CHAVE ESTRANGEIRA de notificacao.usuario_id -> usuario.id, que o Postgres
  -- toma por conta propria para a linha referenciada nao desaparecer no meio do insert. Quem
  -- procurar "for update" nos dois lados nao acha o ciclo, e foi o que aconteceu em tres
  -- revisoes deste cartao.
  --
  -- A correcao e a mesma regra que a 20260929153712 aplicou ao par candidatar x cancelar_vaga,
  -- alcancando um caminho que ela nao alcancou: a vaga primeiro, em todo caminho que mexe nas
  -- duas. La foi "a vaga antes da posicao"; aqui e "a vaga antes do usuario".
  --
  -- Correcao de registro: a 20260929153712 afirma que "excluir_conta da casa tem o mesmo
  -- desenho" do candidatar. Era falso. O candidatar comecava pela vaga; o excluir_conta
  -- comecava pelo usuario, e e justamente essa diferenca que fechava o ciclo.
  --
  -- Travar antes de ler o usuario e seguro: a lista de estabelecimentos sai de
  -- membro_estabelecimento por v_uid, e nao precisa do perfil. Para profissional o conjunto
  -- e vazio e o perform nao trava nada.
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

  -- Idempotência: se a conta nem chegou a ser criada em public.usuario, não há perfil nem turnos
  -- a cancelar. Devolve 202-compatível para a Edge Function completar a remoção em auth.users.
  if not found then
    return jsonb_build_object(
      'perfil_removido_em', v_agora,
      'dados_apagados_ate', (v_agora::date + 15),
      'turnos_cancelados', 0);
  end if;

  -- Idempotência: conta já anonimizada (ex.: retentativa pós-502 da Admin API). Devolve 202-compatível.
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

  -- Sinaliza para a transação que os cancelamentos decorrem de exclusão de conta (isenção de falta RN12)
  -- e registra o autor para os gatilhos disparados em caminho de serviço (CPD2c74A).
  perform set_config('frila.exclusao_de_conta', 'on', true);
  perform set_config('frila.autor_da_exclusao', v_uid::text, true);

  -- 1. Se for profissional: reabre cada turno futuro através de privado.cancelar_uma_posicao
  -- (reabrir = true). A vaga volta a 'publicada', uma nova posição aberta é criada, o despacho
  -- sai de novo (reaberta: true) e a outra parte é avisada, sem gerar falta.
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

  -- 2. Se for contratante: para cada estabelecimento onde for o único membro, cancela turnos futuros
  -- confirmados (reabrir = false, pois a casa ficará sem membros) avisando o profissional.
  if v_usuario.perfil = 'contratante' then
    -- A trava das vagas ja foi tomada no comeco da funcao, antes da de usuario: ver o
    -- cabecalho sobre a ordem de aquisicao. Repetir aqui seria no-op na mesma transacao.

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

      -- Decisão de produto: se a vaga preenchida tiver turno em andamento (já iniciado
      -- e não concluído), a vaga vai para cancelada mas o turno segue até o fim para auditoria.
      update public.vaga
         set estado = 'cancelada'
       where estabelecimento_id = v_estab
         and estado in ('publicada', 'preenchida');
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
end $function$


