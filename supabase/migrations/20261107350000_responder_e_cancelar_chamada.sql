-- F4, parte B (contrato 0.2.55, RN32, RN33, RN36, RN42, RN46, RN12, RN16, RN19, RN21, RF26, CD-C08 a CD-C12, CD-C18, CD-C19):
-- Aceitar, recusar e cancelar chamadas diretas com controle estrito de concorrência,
-- garantia de 1 turno por posição, anti-sobreposição RN21, desfechos atômicos, notificações
-- e retenção (limpeza aos 90 dias e recado aos 15 dias de exclusão).

-- ── 1. Tipos de notificação da contratação direta ─────────────────────────────
alter type public.tipo_notificacao add value if not exists 'chamada_recebida';
alter type public.tipo_notificacao add value if not exists 'chamada_lembrete';
alter type public.tipo_notificacao add value if not exists 'chamada_aceita';
alter type public.tipo_notificacao add value if not exists 'chamada_recusada';
alter type public.tipo_notificacao add value if not exists 'chamada_expirada';
alter type public.tipo_notificacao add value if not exists 'chamada_cancelada';
alter type public.tipo_notificacao add value if not exists 'chamada_encerrada';

comment on type public.tipo_notificacao is
  'Tipos de notificações do sistema (0.2.55). Inclui eventos do ciclo de chamadas diretas (chamada_recebida, chamada_lembrete, chamada_aceita, chamada_recusada, chamada_expirada, chamada_cancelada, chamada_encerrada).';

-- ── 1.1 Atualiza privado.notificar para aceitar chamada_id e midia_id no payload (RN15, 0.2.55) ──
create or replace function privado.notificar(
  p_usuario    uuid,
  p_tipo       public.tipo_notificacao,
  p_referencia uuid,
  p_payload    jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prof          uuid;
  v_id            uuid;
  v_par           record;
  v_rodada        integer := 1;
  v_marca_criada  integer;
begin
  -- RN15: o payload é estrutura, não texto livre.
  for v_par in select key, value from jsonb_each(coalesce(p_payload, '{}'::jsonb)) loop
    if not (
      (v_par.key = 'reaberta' and jsonb_typeof(v_par.value) = 'boolean')
      or (v_par.key in ('vaga_id', 'posicao_id', 'turno_id', 'estabelecimento_id', 'chamada_id', 'midia_id')
          and jsonb_typeof(v_par.value) = 'string'
          and (v_par.value #>> '{}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    ) then
      raise exception 'payload_invalido' using errcode = '22023', detail = v_par.key;
    end if;
  end loop;

  if p_tipo in ('vaga', 'vagas_agrupadas') then
    select p.id into v_prof from public.profissional p where p.usuario_id = p_usuario;
  end if;

  if p_tipo = 'vaga' then
    select g.rodada_despacho into v_rodada from public.vaga g where g.id = p_referencia;
    v_rodada := coalesce(v_rodada, 1);
  end if;

  if p_tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                'vaga') then
    insert into privado.marca_notificacao (tipo, referencia_id, usuario_id, rodada, criada_em)
    values (p_tipo, p_referencia, p_usuario, v_rodada, privado.agora())
    on conflict (tipo, referencia_id, usuario_id, rodada) do nothing
    returning 1 into v_marca_criada;

    if v_marca_criada is null then
      select n.id into v_id
        from public.notificacao n
       where n.tipo = p_tipo
         and n.referencia_id = p_referencia
         and n.usuario_id = p_usuario
         and n.rodada = v_rodada;

      return v_id;
    end if;
  end if;

  insert into public.notificacao (usuario_id, profissional_id, tipo, referencia_id, payload,
                                  enviada_em, rodada)
  values (p_usuario, v_prof, p_tipo, p_referencia,
          coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('tipo', p_tipo),
          privado.agora(), v_rodada)
  on conflict (tipo, referencia_id, usuario_id, rodada)
    where tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                   'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                   'vaga')
    do nothing
  returning id into v_id;

  if v_id is null then
    select n.id into v_id from public.notificacao n
     where n.tipo = p_tipo and n.referencia_id = p_referencia and n.usuario_id = p_usuario
       and n.rodada = v_rodada;
  end if;

  return v_id;
end $$;

comment on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb) is
  'Envia ou atualiza uma notificação ao usuário com payload estruturado (RN15). Aceita vaga_id, posicao_id, turno_id, estabelecimento_id, chamada_id, midia_id e reaberta.';

revoke execute on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb) from public, anon, authenticated;
grant  execute on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb) to service_role;

-- ── 2. Responder chamada (aceitar ou recusar) ───────────────────────────────────
create or replace function public.responder_chamada(
  chamada_id uuid default null,
  resposta text default null,
  motivo_recusa text default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid       uuid := (select auth.uid());
  v_agora     timestamptz;
  v_prof      uuid;
  v_c         public.chamada%rowtype;
  v_vaga      public.vaga%rowtype;
  v_pos_id    uuid;
  v_turno_id  uuid;
  v_outra     record;
  v_local     text;
  v_ponto     extensions.geography;
  v_resp      text;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;

  if not coalesce((select r.ligado from privado.recurso r where r.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;

  perform privado.exigir_perfil('profissional');

  if responder_chamada.chamada_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'chamada_id');
  end if;

  if responder_chamada.resposta is null then
    perform public.erro(422, 'campo_obrigatorio', 'resposta');
  end if;

  if responder_chamada.resposta not in ('aceitar', 'recusar') then
    perform public.erro(422, 'campo_invalido', 'resposta');
  end if;

  if responder_chamada.resposta = 'recusar' and responder_chamada.motivo_recusa is not null
     and responder_chamada.motivo_recusa not in ('agenda', 'distancia', 'valor', 'tipo_de_servico', 'outro') then
    perform public.erro(422, 'campo_invalido', 'motivo_recusa');
  end if;

  select p.id into v_prof from public.profissional p where p.usuario_id = v_uid;
  if v_prof is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  select * into v_c from public.chamada c
   where c.id = responder_chamada.chamada_id and c.profissional_id = v_prof;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  v_agora := privado.agora();

  -- ── Conferências em ordem fixa (contrato 0.2.55, linhas 3460-3468) ─────────────

  -- (1) Bloqueio mútuo: 404 e a chamada aberta vira encerrada (RF26)
  if privado.bloqueado_com_estabelecimento(v_uid, v_c.estabelecimento_id) then
    if v_c.estado = 'aberta' then
      update public.chamada
         set estado = 'encerrada',
             respondida_em = coalesce(respondida_em, v_agora)
       where id = v_c.id;
    end if;
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- (2) Suspensão do profissional: 403 conta_suspensa e chamada aberta vira cancelada (CD-C18)
  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    if v_c.estado = 'aberta' then
      update public.chamada
         set estado = 'cancelada',
             respondida_em = coalesce(respondida_em, v_agora)
       where id = v_c.id;
    end if;
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  -- (3) Prazo pelo relógio do servidor: agora >= expira_em → 409 expirada (CD-C08, CA8)
  if v_agora >= v_c.expira_em then
    if v_c.estado = 'aberta' then
      update public.chamada
         set estado = 'expirada',
             respondida_em = coalesce(respondida_em, v_agora)
       where id = v_c.id;
    end if;
    perform public.erro(409, 'chamada_indisponivel', 'expirada');
  end if;

  -- Idempotência e respostas repetidas
  if v_c.estado = 'aceita' and responder_chamada.resposta = 'aceitar' then
    select pos.id, t.id, g.local, g.ponto, g.responsavel_local
      into v_pos_id, v_turno_id, v_local, v_ponto, v_resp
      from public.posicao pos
      join public.turno t on t.posicao_id = pos.id
      join public.vaga g on g.id = pos.vaga_id
     where pos.vaga_id = v_c.vaga_id and pos.profissional_id = v_prof
     limit 1;
    return jsonb_build_object(
      'chamada', to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em'],
      'turno_id', v_turno_id,
      'local', v_local,
      'ponto', privado.ponto_em_json(v_ponto),
      'responsavel_local', v_resp
    );
  end if;

  if v_c.estado = 'recusada' and responder_chamada.resposta = 'recusar' then
    return jsonb_build_object(
      'chamada', to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em']
    );
  end if;

  -- Qualquer estado que não seja aberta resulta em chamada_indisponivel
  if v_c.estado <> 'aberta' then
    perform public.erro(409, 'chamada_indisponivel', v_c.estado);
  end if;

  -- ── Ramo: Recusar ────────────────────────────────────────────────────────────
  if responder_chamada.resposta = 'recusar' then
    select * into v_c from public.chamada where id = v_c.id for update;
    if v_c.estado <> 'aberta' then
      if v_c.estado = 'recusada' then
        return jsonb_build_object('chamada', to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em']);
      end if;
      perform public.erro(409, 'chamada_indisponivel', v_c.estado);
    end if;

    update public.chamada
       set estado = 'recusada',
           motivo_recusa = responder_chamada.motivo_recusa,
           respondida_em = v_agora
     where id = v_c.id
    returning * into v_c;

    perform privado.notificar_membros(v_c.estabelecimento_id, 'chamada_recusada', v_c.id,
      jsonb_build_object('chamada_id', v_c.id, 'vaga_id', v_c.vaga_id));

    return jsonb_build_object(
      'chamada', to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em']
    );
  end if;

  -- ── Ramo: Aceitar ────────────────────────────────────────────────────────────
  select * into v_vaga from public.vaga where id = v_c.vaga_id;

  -- (4) Função ainda marcada no perfil profissional (CD-C08)
  if not exists (select 1 from public.profissional_funcao pf
                  where pf.profissional_id = v_prof and pf.funcao_id = v_vaga.funcao_id) then
    perform public.erro(422, 'inelegivel', 'funcao_incompativel');
  end if;

  -- Serialização e trava atômica: vaga primeiro, depois chamada
  perform 1 from public.vaga where id = v_c.vaga_id for update;
  select * into v_c from public.chamada where id = v_c.id for update;

  if v_c.estado <> 'aberta' then
    if v_c.estado = 'aceita' then
      select pos.id, t.id, g.local, g.ponto, g.responsavel_local
        into v_pos_id, v_turno_id, v_local, v_ponto, v_resp
        from public.posicao pos
        join public.turno t on t.posicao_id = pos.id
        join public.vaga g on g.id = pos.vaga_id
       where pos.vaga_id = v_c.vaga_id and pos.profissional_id = v_prof
       limit 1;
      return jsonb_build_object(
        'chamada', to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em'],
        'turno_id', v_turno_id,
        'local', v_local,
        'ponto', privado.ponto_em_json(v_ponto),
        'responsavel_local', v_resp
      );
    end if;
    perform public.erro(409, 'chamada_indisponivel', v_c.estado);
  end if;

  -- Se a vaga não tem posição aberta (outro aceite ganhou a corrida antes)
  if not exists (select 1 from public.posicao p where p.vaga_id = v_c.vaga_id and p.estado = 'aberta') then
    update public.chamada
       set estado = 'encerrada',
           respondida_em = coalesce(respondida_em, v_agora)
     where id = v_c.id
    returning * into v_c;
    perform public.erro(409, 'chamada_indisponivel', 'encerrada');
  end if;

  -- (5) Confirmação da posição e anti-sobreposição de agenda RN21
  begin
    update public.posicao p
       set estado = 'confirmada',
           profissional_id = v_prof,
           confirmado_em = v_agora
     where p.id = (select x.id from public.posicao x
                    where x.vaga_id = v_c.vaga_id
                      and x.estado = 'aberta'
                    order by x.id
                    limit 1)
    returning p.id into v_pos_id;
  exception when exclusion_violation then
    -- RN21: recusa com 422 inelegivel:turno_sobreposto e chamada permanece aberta até o prazo
    perform public.erro(422, 'inelegivel', 'turno_sobreposto');
  end;

  if v_pos_id is null then
    update public.chamada
       set estado = 'encerrada',
           respondida_em = coalesce(respondida_em, v_agora)
     where id = v_c.id;
    perform public.erro(409, 'chamada_indisponivel', 'encerrada');
  end if;

  -- Cria candidatura confirmada
  insert into public.candidatura (posicao_id, profissional_id, estado)
  values (v_pos_id, v_prof, 'aceita')
  on conflict (posicao_id, profissional_id) do update set estado = 'aceita';

  -- Cria o turno (RN11)
  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos_id, v_vaga.valor_centavos)
  returning id into v_turno_id;

  -- Atualiza vaga para preenchida
  update public.vaga set estado = 'preenchida' where id = v_c.vaga_id;

  -- Atualiza a chamada para aceita
  update public.chamada
     set estado = 'aceita',
         respondida_em = v_agora
   where id = v_c.id
  returning * into v_c;

  -- Encerra as outras chamadas abertas da mesma vaga (CA1 / CD-C08)
  for v_outra in (
    select c.id, p.usuario_id as prof_uid
      from public.chamada c
      join public.profissional p on p.id = c.profissional_id
     where c.vaga_id = v_c.vaga_id
       and c.id <> v_c.id
       and c.estado = 'aberta'
  ) loop
    update public.chamada
       set estado = 'encerrada',
           respondida_em = coalesce(respondida_em, v_agora)
     where id = v_outra.id;
    perform privado.notificar(v_outra.prof_uid, 'chamada_encerrada', v_outra.id,
      jsonb_build_object('chamada_id', v_outra.id, 'vaga_id', v_c.vaga_id));
  end loop;

  -- Notificações de confirmação
  perform privado.notificar(v_uid, 'confirmacao', v_turno_id,
    jsonb_build_object('turno_id', v_turno_id, 'vaga_id', v_c.vaga_id));
  perform privado.notificar_membros(v_c.estabelecimento_id, 'chamada_aceita', v_c.id,
    jsonb_build_object('chamada_id', v_c.id, 'vaga_id', v_c.vaga_id, 'turno_id', v_turno_id));

  return jsonb_build_object(
    'chamada', to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em'],
    'turno_id', v_turno_id,
    'local', v_vaga.local,
    'ponto', privado.ponto_em_json(v_vaga.ponto),
    'responsavel_local', v_vaga.responsavel_local
  );
end $$;

comment on function public.responder_chamada(uuid, text, text) is
  'Aceitar ou recusar uma chamada direta (contrato 0.2.55, RN32, RN33, RN36, RN42, RN46). Confirmação atômica de turno sem sobreposição RN21. No aceite libera endereço, ponto e responsável local; recusa encerra sem penalidade de comparecimento ou reputação.';

revoke execute on function public.responder_chamada(uuid, text, text) from public, anon;
grant  execute on function public.responder_chamada(uuid, text, text) to authenticated;

-- ── 3. Cancelar chamada ────────────────────────────────────────────────────────
create or replace function public.cancelar_chamada(
  chamada_id uuid default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid      uuid := (select auth.uid());
  v_c        public.chamada%rowtype;
  v_prof_uid uuid;
  v_agora    timestamptz;
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;

  if not coalesce((select r.ligado from privado.recurso r where r.chave = 'chamada_direta'), false) then
    perform public.erro(403, 'sem_permissao', 'recurso_desligado');
  end if;

  perform privado.exigir_perfil('contratante');

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  if cancelar_chamada.chamada_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'chamada_id');
  end if;

  select * into v_c from public.chamada where id = cancelar_chamada.chamada_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not privado.eh_membro(v_c.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- Trava a linha da chamada para evitar concorrência com aceite
  select * into v_c from public.chamada where id = cancelar_chamada.chamada_id for update;

  -- Idempotência: já cancelada pelo mesmo estabelecimento devolve o mesmo registro
  if v_c.estado = 'cancelada' then
    return to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em'];
  end if;

  if v_c.estado <> 'aberta' then
    perform public.erro(409, 'chamada_indisponivel', v_c.estado);
  end if;

  v_agora := privado.agora();

  update public.chamada
     set estado = 'cancelada',
         respondida_em = coalesce(respondida_em, v_agora)
   where id = v_c.id
  returning * into v_c;

  select p.usuario_id into v_prof_uid from public.profissional p where p.id = v_c.profissional_id;
  if v_prof_uid is not null then
    perform privado.notificar(v_prof_uid, 'chamada_cancelada', v_c.id,
      jsonb_build_object('chamada_id', v_c.id, 'vaga_id', v_c.vaga_id));
  end if;

  return to_jsonb(v_c) - array['criada_por', 'chave', 'lembrete_em'];
end $$;

comment on function public.cancelar_chamada(uuid) is
  'Cancelar chamada direta ainda aberta por membro do estabelecimento (contrato 0.2.55, RN35, RN46). Idempotente. Chamada em outro estado recusa com 409 chamada_indisponivel.';

revoke execute on function public.cancelar_chamada(uuid) from public, anon;
grant  execute on function public.cancelar_chamada(uuid) to authenticated;

-- ── 4. Gatilhos de suspensão e exclusão (RN42, CD-C18, CD-C19) ──────────────────

-- Função de gatilho para bloqueio mútuo (RF26, RN42, CD-C08)
create or replace function privado.processar_bloqueio_chamada()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora timestamptz := privado.agora();
begin
  update public.chamada c
     set estado = 'encerrada',
         respondida_em = coalesce(c.respondida_em, v_agora)
   where c.estado = 'aberta'
     and (
       (c.estabelecimento_id in (select m.estabelecimento_id from public.membro_estabelecimento m where m.usuario_id = new.autor_id)
        and c.profissional_id in (select p.id from public.profissional p where p.usuario_id = new.bloqueado_id))
       or
       (c.estabelecimento_id in (select m.estabelecimento_id from public.membro_estabelecimento m where m.usuario_id = new.bloqueado_id)
        and c.profissional_id in (select p.id from public.profissional p where p.usuario_id = new.autor_id))
     );
  return new;
end;
$$;

drop trigger if exists trg_bloqueio_encerrar_chamada on public.bloqueio;
create trigger trg_bloqueio_encerrar_chamada
after insert on public.bloqueio
for each row execute function privado.processar_bloqueio_chamada();

-- Função de gatilho para suspensão de conta
create or replace function privado.processar_suspensao_chamada()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  v_r record;
  v_agora timestamptz := privado.agora();
begin
  if new.perfil = 'profissional' then
    -- Profissional suspenso tem chamadas abertas canceladas
    update public.chamada c
       set estado = 'cancelada',
           respondida_em = coalesce(c.respondida_em, v_agora)
     where c.profissional_id = (select p.id from public.profissional p where p.usuario_id = new.id)
       and c.estado = 'aberta';
  elsif new.perfil = 'contratante' then
    -- Membro contratante suspenso tem chamadas abertas dele encerradas, com aviso ao profissional
    for v_r in (
      select c.id, c.vaga_id, p.usuario_id as prof_uid
        from public.chamada c
        join public.profissional p on p.id = c.profissional_id
       where c.criada_por = new.id
         and c.estado = 'aberta'
    ) loop
      update public.chamada
         set estado = 'encerrada',
             respondida_em = coalesce(respondida_em, v_agora)
       where id = v_r.id;
      perform privado.notificar(v_r.prof_uid, 'chamada_encerrada', v_r.id,
        jsonb_build_object('chamada_id', v_r.id, 'vaga_id', v_r.vaga_id));
    end loop;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_usuario_suspensao_chamada on public.usuario;
create trigger trg_usuario_suspensao_chamada
after update of estado on public.usuario
for each row
when (new.estado = 'suspensa' and old.estado <> 'suspensa')
execute function privado.processar_suspensao_chamada();

-- Função de gatilho para anonimização / exclusão de conta
create or replace function privado.processar_anonimizacao_chamada()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora timestamptz := privado.agora();
begin
  -- Na exclusão da conta, as chamadas abertas são canceladas na hora (RN42)
  update public.chamada c
     set estado = 'cancelada',
         respondida_em = coalesce(c.respondida_em, v_agora)
   where (
     c.criada_por = new.id
     or c.profissional_id = (select p.id from public.profissional p where p.usuario_id = new.id)
   )
   and c.estado = 'aberta';

  return new;
end;
$$;

drop trigger if exists trg_usuario_anonimizacao_chamada on public.usuario;
create trigger trg_usuario_anonimizacao_chamada
after update of estado on public.usuario
for each row
when (new.estado = 'anonimizada' and old.estado <> 'anonimizada')
execute function privado.processar_anonimizacao_chamada();

-- ── 5. Atualização de limpar_contas_anonimizadas (recado aos 15 dias, RN42) ─────
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
         set ponto_base = null
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
  'Limpa dados residuais de contas anonimizadas após o período de retenção (padrão 15 dias). Apaga disponibilidade, funções, aparelhos, zera nascimento, sanitiza recado de chamada direta e textos livres de vagas publicadas pelo titular excluído.';

revoke execute on function privado.limpar_contas_anonimizadas(integer) from public, anon, authenticated;
grant  execute on function privado.limpar_contas_anonimizadas(integer) to service_role;

-- ── 6. Limpeza de chamadas não aceitas após 90 dias (RN42, CD-C19) ──────────────
create or replace function privado.limpar_chamadas_expurgadas(p_dias integer default 90)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limpos integer := 0;
begin
  perform set_config('privado.retencao', 'on', true);

  with apagadas as (
    delete from public.chamada
     where estado in ('recusada', 'expirada', 'cancelada', 'encerrada')
       and coalesce(respondida_em, criada_em) <= privado.agora() - (p_dias || ' days')::interval
    returning id
  )
  select count(*) into v_limpos from apagadas;

  perform set_config('privado.retencao', 'off', true);
  return v_limpos;
end $$;

comment on function privado.limpar_chamadas_expurgadas(integer) is
  'Apaga chamadas não aceitas após 90 dias do desfecho (RN42, CD-C19). A chamada aceita vira turno e segue a retenção do turno.';

revoke execute on function privado.limpar_chamadas_expurgadas(integer) from public, anon, authenticated;
grant  execute on function privado.limpar_chamadas_expurgadas(integer) to service_role;

-- Plug da limpeza de chamadas na retenção diária existente
create or replace function privado.executar_retencao_diaria()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anonimizadas    integer;
  v_higiene         jsonb;
  v_eventos_app     integer;
  v_expurgo_ident   jsonb;
  v_expurgo_perfil  integer;
  v_expurgo_chamada integer;
begin
  v_anonimizadas    := privado.limpar_contas_anonimizadas(15);
  v_higiene         := privado.higienizar_tabelas();
  v_eventos_app     := privado.limpar_eventos_app(90);
  v_expurgo_ident   := privado.expurgar_midias_verificacao_identidade();
  v_expurgo_perfil  := privado.expurgar_midias_recusadas();
  v_expurgo_chamada := privado.limpar_chamadas_expurgadas(90);

  return jsonb_build_object(
    'executado_em',               privado.agora(),
    'contas_anonimizadas_limpas', v_anonimizadas,
    'higiene',                    v_higiene,
    'eventos_app_limpos',         v_eventos_app,
    'expurgo_midia_identidade',   v_expurgo_ident,
    'expurgo_midia_perfil',       v_expurgo_perfil,
    'expurgo_chamadas_nao_aceitas', v_expurgo_chamada
  );
end $$;

comment on function privado.executar_retencao_diaria() is
  'Rotina diária consolidada de retenção e limpeza: contas anonimizadas (15 dias), higiene de tabelas, eventos do app (90 dias), expurgo de mídias de identidade e fotos recusadas (24 h) e expurgo de chamadas não aceitas (90 dias).';

revoke execute on function privado.executar_retencao_diaria() from public, anon, authenticated;
grant  execute on function privado.executar_retencao_diaria() to service_role;
