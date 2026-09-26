-- Exclusão de conta (RF25, RN15).
--
-- A transação prepara o histórico, cancela o futuro e remove os aparelhos. A
-- credencial do Supabase Auth é apagada pela Edge Function, que é a única camada
-- autorizada a usar a service role.

create or replace function privado.exigir_conta_ativa()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_estado public.estado_conta;
begin
  if v_uid is null then
    return;
  end if;

  select u.estado into v_estado
    from public.usuario u
   where u.id = v_uid;

  if v_estado is null or v_estado = 'anonimizada' then
    perform public.erro(403, 'sem_permissao', 'conta_encerrada');
  end if;
end $$;

comment on function privado.exigir_conta_ativa() is
  'Ponto único de extensão para impedir escrita com token de conta anonimizada ou inexistente (RF25). As exceções de conta suspensa pertencem ao cartão de suspensão.';

revoke execute on function privado.exigir_conta_ativa() from public, anon, authenticated;
grant execute on function privado.exigir_conta_ativa() to service_role;

-- Toda RPC que já exige um perfil passa também a exigir conta ativa. As exceções
-- (contestar, exportar, excluir e gestão de aparelhos) ficam para o cartão de
-- suspensão e chamam o ponto de extensão explicitamente quando aplicável.
create or replace function privado.exigir_perfil(esperado public.perfil_conta)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform privado.exigir_conta_ativa();
  if privado.perfil_da_conta() is distinct from esperado then
    perform public.erro(422, 'perfil_incompativel');
  end if;
end $$;

comment on function privado.exigir_perfil(public.perfil_conta) is
  'Exige conta ativa e o perfil declarado. Recusa token de conta anonimizada ou suspensa (RF25) e perfil incompatível (RN25).';

revoke execute on function privado.exigir_perfil(public.perfil_conta)
  from public, anon, authenticated;
grant execute on function privado.exigir_perfil(public.perfil_conta)
  to authenticated, service_role;

-- Cancelamento de posição com verificação de conta ativa e suporte a reabertura.
create or replace function privado.cancelar_uma_posicao(
  posicao uuid,
  autor   uuid,
  motivo  text,
  reabrir boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_pos   public.posicao%rowtype;
  v_agora timestamptz := privado.agora();
  v_falta boolean := false;
  v_nova  uuid;
  v_eh_prof boolean;
begin
  perform privado.exigir_conta_ativa();

  select * into v_pos from public.posicao p where p.id = posicao;

  v_eh_prof := v_pos.profissional_id is not null
               and privado.usuario_do_profissional(v_pos.profissional_id) = autor;

  -- RN12. A falta é do profissional que desiste em cima da hora, e só dele: o
  -- contratante que cancela não gera falta para ninguém, e a posição que nunca foi
  -- confirmada não tem de quem ser falta. Na exclusão de conta, não há falta.
  if v_eh_prof and v_pos.estado = 'confirmada'
     and v_pos.inicio_em - v_agora < interval '24 hours'
     and motivo <> 'exclusão de conta' then
    v_falta := true;
  end if;

  update public.posicao p
     set estado = 'cancelada',
         falta  = v_falta
   where p.id = posicao;

  -- O turno cancelado sai junto. Ele não é apagado: o registro do que foi combinado
  -- sobrevive ao cancelamento, e é o que a auditoria lê.
  update public.turno t
     set verificacao = 'nao_verificado'
   where t.posicao_id = posicao and t.verificacao = 'pendente';

  insert into public.ocorrencia (tipo, posicao_id, usuario_id, autor_id, motivo)
  values ('cancelamento', posicao,
          privado.usuario_do_profissional(v_pos.profissional_id), autor, motivo);

  -- Antes do início, a vaga ganha uma posição nova e o despacho sai de novo. Depois do
  -- início não há o que reabrir: o turno ficou descoberto, e quem precisa saber disso é
  -- o contratante.
  if reabrir and v_pos.inicio_em > v_agora then
    insert into public.posicao (vaga_id, inicio_em, fim_em)
    values (v_pos.vaga_id, v_pos.inicio_em, v_pos.fim_em)
    returning id into v_nova;

    -- A vaga estava preenchida e volta a ter posição aberta.
    update public.vaga g set estado = 'publicada'
     where g.id = v_pos.vaga_id and g.estado = 'preenchida';

    perform pgmq.send('despacho', jsonb_build_object(
      'vaga_id',        v_pos.vaga_id,
      'posicao_id',     v_nova,
      'motivo',         'reabertura',
      -- Quem cancelou não é notificado de novo da própria vaga. Receber a notificação
      -- da vaga que se acabou de largar é o tipo de detalhe que faz desinstalar o app.
      'excluir_conta',  autor));
  end if;

  if v_falta then
    perform privado.recalcular_comparecimento(v_pos.profissional_id);
  end if;

  -- Avisa a **outra parte**, e só ela: quem cancelou sabe. O profissional cancelou, a
  -- casa toda é avisada; a casa cancelou, o profissional é. `reaberta = false` é o turno
  -- descoberto — vaga inteira cancelada, ou início já passado —, que a casa precisa
  -- distinguir da posição que voltou para a fila.
  if v_eh_prof then
    perform privado.notificar_membros(
      privado.estabelecimento_da_vaga(v_pos.vaga_id), 'cancelamento', posicao,
      jsonb_build_object('posicao_id', posicao, 'vaga_id', v_pos.vaga_id,
                         'reaberta', v_nova is not null));
  elsif v_pos.profissional_id is not null then
    perform privado.notificar(privado.usuario_do_profissional(v_pos.profissional_id),
      'cancelamento', posicao,
      jsonb_build_object('posicao_id', posicao, 'vaga_id', v_pos.vaga_id,
                         'reaberta', v_nova is not null));
  end if;

  return jsonb_build_object(
    'posicao_id',      posicao,
    'falta',           v_falta,
    'reaberta',        v_nova is not null,
    'nova_posicao_id', v_nova);
end $$;

comment on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean) is
  'Desiste de uma posição com motivo (RF14, RN12). Quando é do profissional e a menos de 24 h do início, marca falta e recalcula a taxa. Se pedido e antes do início, reabre a posição criando outra e redisparando o despacho. Notifica a outra parte. Exige conta ativa.';

revoke execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function privado.cancelar_uma_posicao(uuid, uuid, text, boolean)
  to service_role;

-- Impede que conta anonimizada continue associada a perfil profissional ativo.
create or replace function privado.meu_profissional_id() returns uuid
language sql stable security definer set search_path = '' as $$
  select p.id
    from public.profissional p
    join public.usuario u on u.id = p.usuario_id
   where p.usuario_id = (select auth.uid())
     and u.estado <> 'anonimizada';
$$;

comment on function privado.meu_profissional_id() is
  'Identificador do profissional da conta ativa chamadora. Retorna nulo para conta anonimizada.';

revoke execute on function privado.meu_profissional_id() from public, anon;
grant execute on function privado.meu_profissional_id() to authenticated, service_role;

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

      update public.posicao p
         set estado = 'cancelada'
       where p.vaga_id in (
         select g.id from public.vaga g
          where g.estabelecimento_id = v_estab
            and g.estado in ('publicada', 'preenchida'))
         and p.estado = 'aberta';

      update public.vaga
         set estado = 'cancelada'
       where estabelecimento_id = v_estab
         and estado in ('publicada', 'preenchida');
    end loop;
    delete from public.membro_estabelecimento where usuario_id = v_uid;
  end if;

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
  'Anonimiza a conta, remove aparelhos, cancela turnos futuros e enfileira aviso à contraparte. A credencial auth.users é apagada pela Edge Function (RF25, RN15).';

revoke execute on function privado.excluir_conta(uuid) from public, anon, authenticated;
grant execute on function privado.excluir_conta(uuid) to service_role;
