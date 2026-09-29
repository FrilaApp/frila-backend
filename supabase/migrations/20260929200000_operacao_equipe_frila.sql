-- 20260929200000_operacao_equipe_frila.sql
--
-- Ferramentas e procedimentos operacionais da Equipe Frila (Cartão Oxh0AWE7, D01, D02, D03, RN13, UC14, UC15, UC17).
--
--   - privado.operacao_suspender_conta(usuario_id uuid, motivo text) -> jsonb
--   - privado.operacao_reativar_conta(usuario_id uuid, justificativa text) -> jsonb
--   - privado.operacao_moderar_conteudo(vaga_id uuid, acao text, motivo text) -> jsonb
--
-- Acesso estritamente restrito a service_role (fora do PostgREST / público).
-- Todas as ações são transacionais e registram ocorrência oficial.

-- ── 1. Suspender Conta ──────────────────────────────────────────────────────────

create or replace function privado.operacao_suspender_conta(
  usuario_id uuid,
  motivo     text
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
  v_usuario     public.usuario%rowtype;
  v_agora       timestamptz := privado.agora();
  v_pos         public.posicao%rowtype;
  v_vaga        public.vaga%rowtype;
  v_cancelados  integer := 0;
  v_oc_id       uuid;
begin
  if v_uid is null then
    perform public.erro(422, 'campo_obrigatorio', 'usuario_id');
  end if;

  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;

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

  -- 2. Se for contratante: para estabelecimentos onde for o único membro, cancela vagas futuras abertas
  if v_usuario.perfil = 'contratante' then
    for v_vaga in
      select g.*
        from public.vaga g
        join public.membro_estabelecimento m on m.estabelecimento_id = g.estabelecimento_id
       where m.usuario_id = v_uid
         and g.inicio_em > v_agora
         and g.estado = 'publicada'
         and (select count(*) from public.membro_estabelecimento x
               where x.estabelecimento_id = m.estabelecimento_id) = 1
    loop
      -- Marca vaga cancelada e recolhe posições abertas
      update public.vaga set estado = 'cancelada' where id = v_vaga.id;
      update public.posicao set estado = 'cancelada' where vaga_id = v_vaga.id and estado = 'aberta';
      v_cancelados := v_cancelados + 1;
    end loop;
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
    v_uid,
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

comment on function privado.operacao_suspender_conta(uuid, text) is
  'Suspende conta de usuário (RN13) com registro de ocorrência e cancelamento de turnos futuros. Restrito a service_role.';

revoke execute on function privado.operacao_suspender_conta(uuid, text) from public, anon, authenticated;
grant  execute on function privado.operacao_suspender_conta(uuid, text) to service_role;

-- ── 2. Reativar Conta ──────────────────────────────────────────────────────────

create or replace function privado.operacao_reativar_conta(
  usuario_id    uuid,
  justificativa text
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
    v_uid,
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

comment on function privado.operacao_reativar_conta(uuid, text) is
  'Reativa conta suspensa com registro de ocorrência. Restrito a service_role.';

revoke execute on function privado.operacao_reativar_conta(uuid, text) from public, anon, authenticated;
grant  execute on function privado.operacao_reativar_conta(uuid, text) to service_role;

-- ── 3. Moderação de Conteúdo (Diretriz 1.2 da App Store) ─────────────────────────

create or replace function privado.operacao_moderar_conteudo(
  vaga_id uuid,
  acao    text,
  motivo  text
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
      perform privado.cancelar_uma_posicao(v_pos.id, v_vaga.publicado_por, 'moderação: ' || v_motivo, false);
    end loop;

    -- Cancela posições abertas
    update public.posicao
       set estado = 'cancelada'
     where vaga_id = v_vaga_id
       and estado = 'aberta';

    -- Atualiza a vaga para cancelada
    update public.vaga
       set estado = 'cancelada'
     where id = v_vaga_id;

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
      'denuncia',
      null,
      v_vaga.publicado_por,
      v_vaga.estabelecimento_id,
      v_vaga.publicado_por,
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
      v_vaga.publicado_por,
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

comment on function privado.operacao_moderar_conteudo(uuid, text, text) is
  'Modera conteúdo denunciado em até 24h (Diretriz 1.2 da App Store) ocultando ou reexibindo vaga. Restrito a service_role.';

revoke execute on function privado.operacao_moderar_conteudo(uuid, text, text) from public, anon, authenticated;
grant  execute on function privado.operacao_moderar_conteudo(uuid, text, text) to service_role;
