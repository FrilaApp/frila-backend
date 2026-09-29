-- 20260929230000_operacao_equipe_frila.sql
--
-- Ferramentas e procedimentos operacionais da Equipe Frila (Cartão Oxh0AWE7, D01, D02, D03, RN13, UC14, UC15, UC17).
--
--   - privado.operacao_suspender_conta(usuario_id uuid, motivo text, operador_id uuid) -> jsonb
--   - privado.operacao_reativar_conta(usuario_id uuid, justificativa text, operador_id uuid) -> jsonb
--   - privado.operacao_moderar_conteudo(vaga_id uuid, acao text, motivo text, operador_id uuid) -> jsonb
--
-- Acesso estritamente restrito a service_role (fora do PostgREST / público).
-- Todas as ações são transacionais e registram ocorrência oficial.
--
-- O autor das ocorrências é `operador_id`, a conta do membro da Equipe Frila que agiu, e
-- nunca o alvo. Com o alvo como autor, `limpar_contas_anonimizadas` apagaria o motivo da
-- suspensão junto com a conta suspensa, e a exportação de dados atribuiria a ele o texto
-- interno da equipe.

-- ── 0. O operador ───────────────────────────────────────────────────────────────

create or replace function privado.operacao_exigir_operador(operador uuid, alvo uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if operador is null then
    perform public.erro(422, 'campo_obrigatorio', 'operador_id');
  end if;

  -- Conta ativa: a ocorrência aponta para ela (`autor_id not null references usuario`).
  if not exists (select 1 from public.usuario u
                  where u.id = operador and u.estado = 'ativa') then
    perform public.erro(422, 'campo_invalido', 'operador_id');
  end if;

  -- Quem age sobre a própria conta ou a própria vaga não é a Equipe Frila agindo.
  if operador = alvo then
    perform public.erro(422, 'campo_invalido', 'operador_id');
  end if;
end $$;

comment on function privado.operacao_exigir_operador(uuid, uuid) is
  'Confere o membro da Equipe Frila que assina uma ação operacional: obrigatório, conta ativa e diferente do alvo. Restrito a service_role.';

revoke execute on function privado.operacao_exigir_operador(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_exigir_operador(uuid, uuid) to service_role;

-- ── 1. Suspender Conta ──────────────────────────────────────────────────────────

create or replace function privado.operacao_suspender_conta(
  usuario_id  uuid,
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
  v_uid         uuid := operacao_suspender_conta.usuario_id;
  v_motivo      text := pg_catalog.btrim(operacao_suspender_conta.motivo);
  v_operador    uuid := operacao_suspender_conta.operador_id;
  v_usuario     public.usuario%rowtype;
  v_agora       timestamptz := privado.agora();
  v_pos         public.posicao%rowtype;
  v_cand        record;
  v_vagas       uuid[];
  v_cancelados  integer := 0;
  v_oc_id       uuid;
begin
  if v_uid is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_uid);

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_usuario.estado = 'anonimizada' then
    perform public.erro(409, 'conta_ja_anonimizada');
  end if;

  if v_usuario.estado = 'suspensa' then
    return jsonb_build_object(
      'usuario_id',         v_uid,
      'estado_anterior',    'suspensa',
      'estado_atual',       'suspensa',
      'ja_estava_suspensa', true,
      'turnos_cancelados',  0
    );
  end if;

  -- 1. Se for profissional: reabre cada turno futuro através de privado.cancelar_uma_posicao (RN13)
  if v_usuario.perfil = 'profissional' then
    for v_pos in
      select p.*
        from public.posicao p
       where p.estado = 'confirmada'
         and p.inicio_em > v_agora
         and p.profissional_id = (select x.id from public.profissional x where x.usuario_id = v_uid)
    loop
      perform privado.cancelar_uma_posicao(v_pos.id, v_uid, 'suspensão de conta: ' || v_motivo, true);
      v_cancelados := v_cancelados + 1;
    end loop;
  end if;

  -- 2. Se for contratante: nas casas onde for o único membro, ninguém responde pelas vagas
  -- futuras, publicadas ou preenchidas. Elas saem como em `excluir_conta`: as confirmadas
  -- são canceladas sem reabrir, com aviso ao profissional e sem falta (quem cancela é a
  -- Equipe Frila, não ele); as candidaturas pendentes são retiradas e avisadas; as abertas
  -- e a vaga vão para cancelada.
  if v_usuario.perfil = 'contratante' then
    -- O gatilho `vaga_cancelada_recolhe_confirmadas` sai sem recolher as confirmadas
    -- quando `auth.uid()` é nulo, que é o caso da chave de serviço. O autor sinalizado na
    -- transação (o mesmo mecanismo de `excluir_conta`) faz ele recolher, em nome do
    -- operador, a posição que confirmar entre o laço abaixo e o `update` da vaga.
    perform set_config('frila.autor_da_exclusao', v_operador::text, true);

    -- Ordem das travas (CPD2c74A): as vagas antes das posições.
    select coalesce(array_agg(x.id order by x.id), '{}') into v_vagas
      from (select g.id
              from public.vaga g
             where g.inicio_em > v_agora
               and g.estado in ('publicada', 'preenchida')
               and g.estabelecimento_id in (
                 select m.estabelecimento_id from public.membro_estabelecimento m
                  where m.usuario_id = v_uid
                    and not exists (
                      select 1 from public.membro_estabelecimento x
                       where x.estabelecimento_id = m.estabelecimento_id
                         and x.usuario_id <> v_uid))
             order by g.id
               for update) x;

    for v_pos in
      select p.*
        from public.posicao p
       where p.vaga_id = any (v_vagas)
         and p.estado = 'confirmada'
         and p.inicio_em > v_agora
       order by p.id
    loop
      perform privado.cancelar_uma_posicao(v_pos.id, v_operador, 'suspensão de conta: ' || v_motivo, false);
      v_cancelados := v_cancelados + 1;
    end loop;

    for v_cand in
      select c.id, c.profissional_id, p.vaga_id
        from public.candidatura c
        join public.posicao p on p.id = c.posicao_id
       where p.vaga_id = any (v_vagas)
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
     where p.vaga_id = any (v_vagas)
       and p.estado = 'aberta';

    update public.vaga g
       set estado = 'cancelada'
     where g.id = any (v_vagas);

    perform set_config('frila.autor_da_exclusao', '', true);
  end if;

  -- Atualiza o estado da conta para suspensa
  update public.usuario
     set estado = 'suspensa'
   where id = v_uid;

  -- Registra ocorrência de suspensão
  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    criada_em,
    resolvido_em,
    resultado
  ) values (
    'suspensao',
    v_uid,
    v_operador,
    v_motivo,
    v_agora,
    v_agora,
    'Conta suspensa pela Equipe Frila via procedimento operacional.'
  ) returning id into v_oc_id;

  return jsonb_build_object(
    'usuario_id',        v_uid,
    'estado_anterior',   'ativa',
    'estado_atual',      'suspensa',
    'ocorrencia_id',     v_oc_id,
    'turnos_cancelados', v_cancelados,
    'suspenso_em',       v_agora
  );
end $$;

comment on function privado.operacao_suspender_conta(uuid, text, uuid) is
  'Suspende conta de usuário (RN13) com registro de ocorrência assinada pelo operador da Equipe Frila e cancelamento de turnos futuros. Contratante único membro: cancela as vagas futuras publicadas e preenchidas, com as confirmadas, sem falta, e retira as candidaturas pendentes, com aviso. Restrito a service_role.';

revoke execute on function privado.operacao_suspender_conta(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_suspender_conta(uuid, text, uuid) to service_role;

-- ── 2. Reativar Conta ──────────────────────────────────────────────────────────

create or replace function privado.operacao_reativar_conta(
  usuario_id    uuid,
  justificativa text,
  operador_id   uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := operacao_reativar_conta.usuario_id;
  v_just    text := pg_catalog.btrim(operacao_reativar_conta.justificativa);
  v_operador uuid := operacao_reativar_conta.operador_id;
  v_usuario public.usuario%rowtype;
  v_agora   timestamptz := privado.agora();
  v_oc_id   uuid;
begin
  if v_uid is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if v_just is null or v_just = '' then
    perform public.erro(422, 'campo_obrigatorio', 'justificativa');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_uid);

  select * into v_usuario
    from public.usuario u
   where u.id = v_uid
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_usuario.estado = 'anonimizada' then
    perform public.erro(409, 'conta_ja_anonimizada');
  end if;

  if v_usuario.estado = 'ativa' then
    return jsonb_build_object(
      'usuario_id',      v_uid,
      'estado_anterior', 'ativa',
      'estado_atual',    'ativa',
      'ja_estava_ativa', true
    );
  end if;

  update public.usuario
     set estado = 'ativa'
   where id = v_uid;

  insert into public.ocorrencia (
    tipo,
    usuario_id,
    autor_id,
    motivo,
    criada_em,
    resolvido_em,
    resultado
  ) values (
    'suporte',
    v_uid,
    v_operador,
    'Reativação de conta: ' || v_just,
    v_agora,
    v_agora,
    'Conta reativada pela Equipe Frila via procedimento operacional.'
  ) returning id into v_oc_id;

  return jsonb_build_object(
    'usuario_id',      v_uid,
    'estado_anterior', 'suspensa',
    'estado_atual',    'ativa',
    'ocorrencia_id',   v_oc_id,
    'reativado_em',    v_agora
  );
end $$;

comment on function privado.operacao_reativar_conta(uuid, text, uuid) is
  'Reativa conta suspensa com registro de ocorrência assinada pelo operador da Equipe Frila. Restrito a service_role.';

revoke execute on function privado.operacao_reativar_conta(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_reativar_conta(uuid, text, uuid) to service_role;

-- ── 3. Moderação de Conteúdo (Diretriz 1.2 da App Store) ─────────────────────────

create or replace function privado.operacao_moderar_conteudo(
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
  v_vaga_id uuid := operacao_moderar_conteudo.vaga_id;
  v_acao    text := pg_catalog.btrim(operacao_moderar_conteudo.acao);
  v_motivo  text := pg_catalog.btrim(operacao_moderar_conteudo.motivo);
  v_operador uuid := operacao_moderar_conteudo.operador_id;
  v_vaga    public.vaga%rowtype;
  v_agora   timestamptz := privado.agora();
  v_pos     public.posicao%rowtype;
  v_oc_id   uuid;
begin
  if v_vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

  select * into v_vaga
    from public.vaga g
   where g.id = v_vaga_id
     for update;

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  perform privado.operacao_exigir_operador(v_operador, v_vaga.publicado_por);

  if v_acao not in ('ocultar', 'reexibir') then
    perform public.erro(422, 'campo_invalido', 'acao');
  end if;

  if v_acao = 'ocultar' then
    if v_vaga.estado = 'cancelada' then
      return jsonb_build_object(
        'vaga_id',             v_vaga_id,
        'estado_atual',        'cancelada',
        'ja_estava_cancelada', true
      );
    end if;

    -- Cancela as posições futuras confirmadas avisando os profissionais
    for v_pos in
      select p.*
        from public.posicao p
       where p.vaga_id = v_vaga_id
         and p.estado = 'confirmada'
         and p.inicio_em > v_agora
    loop
      perform privado.cancelar_uma_posicao(v_pos.id, v_operador, 'moderação: ' || v_motivo, false);
    end loop;

    -- Cancela posições abertas
    update public.posicao
       set estado = 'cancelada'
     where vaga_id = v_vaga_id
       and estado = 'aberta';

    -- Atualiza a vaga para cancelada. O gatilho recolhe em nome do operador a posição que
    -- tiver confirmado depois do laço (ver a suspensão de contratante).
    perform set_config('frila.autor_da_exclusao', v_operador::text, true);
    update public.vaga
       set estado = 'cancelada'
     where id = v_vaga_id;
    perform set_config('frila.autor_da_exclusao', '', true);

    -- Grava ocorrência de moderação
    insert into public.ocorrencia (
      tipo,
      posicao_id,
      usuario_id,
      estabelecimento_id,
      autor_id,
      motivo,
      criada_em,
      resolvido_em,
      resultado
    ) values (
      -- `suporte`, não `denuncia`: a denúncia é de quem a abriu (`denunciar`), e esta
      -- ocorrência é a ação da Equipe Frila sobre ela.
      'suporte',
      null,
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_operador,
      'Moderação Diretriz 1.2: ' || v_motivo,
      v_agora,
      v_agora,
      'Conteúdo ocultado em até 24h pela Equipe Frila.'
    ) returning id into v_oc_id;

    return jsonb_build_object(
      'vaga_id',       v_vaga_id,
      'estado_atual',  'cancelada',
      'ocorrencia_id', v_oc_id,
      'acao',          'ocultar',
      'moderado_em',   v_agora
    );

  else -- v_acao = 'reexibir'
    if v_vaga.inicio_em <= v_agora then
      perform public.erro(422, 'horario_invalido', 'vaga_ja_iniciada');
    end if;

    update public.vaga
       set estado = 'publicada'
     where id = v_vaga_id;

    -- Reabre posições abertas que foram canceladas pela moderação
    update public.posicao
       set estado = 'aberta'
     where vaga_id = v_vaga_id
       and estado = 'cancelada'
       and profissional_id is null;

    insert into public.ocorrencia (
      tipo,
      usuario_id,
      estabelecimento_id,
      autor_id,
      motivo,
      criada_em,
      resolvido_em,
      resultado
    ) values (
      'suporte',
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_operador,
      'Moderação Reexibir: ' || v_motivo,
      v_agora,
      v_agora,
      'Vaga reexibida pela Equipe Frila após análise da moderação.'
    ) returning id into v_oc_id;

    return jsonb_build_object(
      'vaga_id',       v_vaga_id,
      'estado_atual',  'publicada',
      'ocorrencia_id', v_oc_id,
      'acao',          'reexibir',
      'reexibido_em',  v_agora
    );
  end if;
end $$;

comment on function privado.operacao_moderar_conteudo(uuid, text, text, uuid) is
  'Modera conteúdo denunciado em até 24h (Diretriz 1.2 da App Store) ocultando ou reexibindo vaga, com ocorrência de suporte assinada pelo operador da Equipe Frila. Restrito a service_role.';

revoke execute on function privado.operacao_moderar_conteudo(uuid, text, text, uuid) from public, anon, authenticated;
grant  execute on function privado.operacao_moderar_conteudo(uuid, text, text, uuid) to service_role;
