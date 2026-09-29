-- Gatilho de vaga cancelada no caminho de serviço de excluir_conta (CPD2c74A, RNF14, RF25, RN12).
--
-- No caminho de serviço de `privado.excluir_conta(p_usuario_id)` (sem JWT), `auth.uid()`
-- é nulo. A migração 20260929153712 saía cedo quando `auth.uid()` era nulo. Se uma
-- candidatura confirmava uma posição no meio da exclusão de conta (após a varredura
-- inicial de confirmadas da casa, mas antes de `update vaga set estado = 'cancelada'`), a
-- posição sobrava confirmada numa vaga cancelada.
--
-- A correção (opção A):
--   · `privado.excluir_conta` sinaliza o autor da exclusão na transação
--     (`set_config('frila.autor_da_exclusao', v_uid::text, true)`), ao lado de
--     `frila.exclusao_de_conta`.
--   · O gatilho `privado.vaga_cancelada_recolhe_confirmadas` usa:
--     `coalesce((select auth.uid()), nullif(current_setting('frila.autor_da_exclusao', true), '')::uuid)`
--     e só sai cedo se ambos forem nulos.
--   · A posição confirmada é recolhida e cancelada sem falta para o profissional
--     (a flag de exclusão cobre, e o contratante é o autor do cancelamento).
--   · O autor da ocorrência passa a ser a própria conta excluída (`v_uid`).

-- ── 1. excluir_conta sinaliza autor_da_exclusao na transação ────────────────

create or replace function privado.excluir_conta(p_usuario_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
    -- Ordem das travas (CPD2c74A): trava as vagas antes de mexer nas posições.
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
end $$;

comment on function privado.excluir_conta(uuid) is
  'Anonimiza a conta, remove aparelhos, cancela turnos futuros e enfileira aviso à contraparte. A credencial auth.users é apagada pela Edge Function (RF25, RN15). Sinaliza frila.exclusao_de_conta e frila.autor_da_exclusao na transação.';

revoke execute on function privado.excluir_conta(uuid) from public, anon, authenticated;
grant execute on function privado.excluir_conta(uuid) to service_role;

-- ── 2. vaga_cancelada_recolhe_confirmadas usa autor_da_exclusao ─────────────

create or replace function privado.vaga_cancelada_recolhe_confirmadas()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := coalesce(
    (select auth.uid()),
    nullif(current_setting('frila.autor_da_exclusao', true), '')::uuid
  );
  v_agora timestamptz := privado.agora();
  v_pos   uuid;
begin
  -- A posição aberta que nasceu depois do update das abertas de `cancelar_vaga` (uma
  -- desistência que reabriu e comitou no meio). Não tem de quem ser ocorrência, e por
  -- isso vem antes da saída sem conta. A vaga já está travada (é este `update`), e as
  -- posições vêm por id.
  update public.posicao p
     set estado = 'cancelada'
   where p.id in (select x.id from public.posicao x
                   where x.vaga_id = new.id
                     and x.estado = 'aberta'
                   order by x.id
                     for no key update);

  -- Sem conta no JWT nem autor de exclusão sinalizado na transação, não há autor para
  -- a ocorrência (`autor_id not null`). O cancelamento fora de contexto (ex.: direto
  -- via serviço sem autor_da_exclusao) sai cedo aqui.
  if v_uid is null then
    return new;
  end if;

  -- Por id, esperando quem segura a linha: todo caminho que mexe numa posição de turno
  -- futuro trava a vaga antes (CPD2c74A), então quem a segura aqui não espera esta vaga.
  -- Se ele comitou o cancelamento, `cancelar_uma_posicao` relê e segue; se desfez, a
  -- posição volta confirmada e é recolhida aqui.
  for v_pos in
    select p.id from public.posicao p
     where p.vaga_id = new.id
       and p.estado = 'confirmada'
       and p.inicio_em > v_agora
     order by p.id
       for no key update
  loop
    -- Motivo estável, e não texto da casa: o texto dela não chega ao gatilho, e é este
    -- código que distingue na auditoria a posição recolhida depois da corrida.
    perform privado.cancelar_uma_posicao(v_pos, v_uid, 'vaga_cancelada', false);
  end loop;

  return new;
end $$;

comment on function privado.vaga_cancelada_recolhe_confirmadas() is
  'Gatilho BEFORE de vaga: ao ir para cancelada, cancela as posições ainda abertas e (sem reabrir, com ocorrência de motivo vaga_cancelada) as confirmadas cujo turno não começou. Recolhe o que confirmou ou reabriu durante cancelar_vaga ou excluir_conta via serviço (RNF14, CPD2c74A). Segura a vaga e trava as posições por id, na ordem vaga → posição de todos os caminhos de turno futuro. Turno em andamento segue, como em excluir_conta.';

revoke execute on function privado.vaga_cancelada_recolhe_confirmadas()
  from public, anon, authenticated;
grant execute on function privado.vaga_cancelada_recolhe_confirmadas() to service_role;
