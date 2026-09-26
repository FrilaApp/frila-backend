-- Motor de despacho: elegibilidade, fila, reprocessamento e agendador.
--
-- US07 · RF06 · RN05, RN06, RN21 · D2, D6 · RNF03.
--
-- Consulta os elegíveis (função, grade cobrindo o horário inclusive janela que
-- atravessa a meia-noite, até 15 km com índice GiST, conta ativa, sem bloqueio,
-- sem turno sobreposto, sem ordem por reputação e nada patrocinado — RN06).
-- Enfileira despacho e notificação, reprocessa falhas pelo pgmq com tentativas
-- limitadas, notifica vaga_sem_elegiveis uma vez, isola contas de demonstração
-- e dispara despacho imediato pós-commit via net.http_post.

-- ── 1. Marca de envio para vaga_sem_elegiveis ──────────────────────────────────
-- O índice único parcial já garante envio único dos tipos agendados.
-- Inclui vaga_sem_elegiveis para que a notificação ao contratante (UC02 1a)
-- não se repita caso o despacho seja reprocessado.
drop index if exists public.notificacao_marca_de_envio;
create unique index notificacao_marca_de_envio
  on public.notificacao (tipo, referencia_id, usuario_id)
  where tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                 'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis');

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
  v_prof  uuid;
  v_id    uuid;
  v_par   record;
begin
  -- RN15: o payload é estrutura, não texto livre.
  for v_par in select key, value from jsonb_each(coalesce(p_payload, '{}'::jsonb)) loop
    if not (
      (v_par.key = 'reaberta' and jsonb_typeof(v_par.value) = 'boolean')
      or (v_par.key in ('vaga_id', 'posicao_id', 'turno_id', 'estabelecimento_id')
          and jsonb_typeof(v_par.value) = 'string'
          and (v_par.value #>> '{}') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
    ) then
      raise exception 'payload_invalido' using errcode = '22023', detail = v_par.key;
    end if;
  end loop;

  if p_tipo in ('vaga', 'vagas_agrupadas') then
    select p.id into v_prof from public.profissional p where p.usuario_id = p_usuario;
  end if;

  insert into public.notificacao (usuario_id, profissional_id, tipo, referencia_id, payload, enviada_em)
  values (p_usuario, v_prof, p_tipo, p_referencia,
          coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('tipo', p_tipo),
          privado.agora())
  on conflict (tipo, referencia_id, usuario_id)
    where tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                   'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis')
    do nothing
  returning id into v_id;

  if v_id is null then
    select n.id into v_id from public.notificacao n
     where n.tipo = p_tipo and n.referencia_id = p_referencia and n.usuario_id = p_usuario;
  end if;

  return v_id;
end $$;

comment on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb) is
  'Enfileira um aviso para uma conta (estado pendente; o envio ao FCM é do agendador). Marca de envio evita duplicidade em tipos agendados e vaga_sem_elegiveis. Payload estrito conforme RN15.';

revoke execute on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb)
  from public, anon, authenticated;

-- ── 2. privado.elegiveis(vaga_id, excluir_conta) ──────────────────────────────
-- Consulta de elegibilidade de RN05 e Modelagem (O caminho quente).
create or replace function privado.elegiveis(
  vaga_id       uuid,
  excluir_conta uuid default null
)
returns table (profissional_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v           public.vaga%rowtype;
  v_demo      boolean;
  v_inicio_sp timestamp;
  v_dow       int;
  v_dow_ontem int;
begin
  select * into v from public.vaga g where g.id = elegiveis.vaga_id;
  if not found then
    return;
  end if;

  -- Só despacha vaga no estado 'publicada'
  if v.estado <> 'publicada' then
    return;
  end if;

  -- Isolamento de contas de demonstração (critério 6 do cartão):
  -- Vaga de conta de demonstração só notifica conta de demonstração,
  -- e vaga real só notifica conta real.
  select u.demonstracao into v_demo
    from public.usuario u
   where u.id = v.publicado_por;

  -- Horários no fuso America/Sao_Paulo (fuso canônico do DF para a grade semanal)
  v_inicio_sp := (v.inicio_em at time zone 'America/Sao_Paulo');
  v_dow       := extract(dow from v_inicio_sp)::int;
  v_dow_ontem := (v_dow + 6) % 7;

  return query
  select p.id
    from public.profissional p
    join public.usuario u on u.id = p.usuario_id and u.estado = 'ativa'
   where (v_demo is null or u.demonstracao = v_demo)
     -- Exclusão de conta (ex: quem cancelou na reabertura da posição)
     and (elegiveis.excluir_conta is null or p.usuario_id <> elegiveis.excluir_conta)
     -- 1. Função compatível (catálogo fechado)
     and exists (
       select 1 from public.profissional_funcao pf
        where pf.profissional_id = p.id and pf.funcao_id = v.funcao_id
     )
     -- 2. Até 15 km (usa índice GiST profissional_ponto), ou equipe de confiança (RF18)
     and (
       extensions.ST_DWithin(p.ponto_base, v.ponto, 15000)
       or exists (
         select 1 from public.equipe_confianca e
          where e.estabelecimento_id = v.estabelecimento_id
            and e.profissional_id = p.id
       )
     )
     -- 3. Grade cobrindo o horário integral, inclusive janela que atravessa a meia-noite
     and exists (
       select 1 from public.disponibilidade d
        where d.profissional_id = p.id
          and (
            -- Janela iniciada no mesmo dia da semana da vaga
            (
              d.dia_semana = v_dow
              and (
                -- Janela no mesmo dia (sem virar a noite)
                (d.hora_inicio < d.hora_fim
                 and tstzrange(
                       (date_trunc('day', v_inicio_sp) + d.hora_inicio) at time zone 'America/Sao_Paulo',
                       (date_trunc('day', v_inicio_sp) + d.hora_fim) at time zone 'America/Sao_Paulo'
                     ) @> tstzrange(v.inicio_em, v.fim_em))
                -- Janela que vira a noite iniciada no dia
                or (d.hora_inicio > d.hora_fim
                    and tstzrange(
                          (date_trunc('day', v_inicio_sp) + d.hora_inicio) at time zone 'America/Sao_Paulo',
                          (date_trunc('day', v_inicio_sp) + interval '1 day' + d.hora_fim) at time zone 'America/Sao_Paulo'
                        ) @> tstzrange(v.inicio_em, v.fim_em))
              )
            )
            -- Janela iniciada na véspera que vira a noite e cobre o turno na madrugada
            or (
              d.dia_semana = v_dow_ontem
              and d.hora_inicio > d.hora_fim
              and tstzrange(
                    (date_trunc('day', v_inicio_sp) - interval '1 day' + d.hora_inicio) at time zone 'America/Sao_Paulo',
                    (date_trunc('day', v_inicio_sp) + d.hora_fim) at time zone 'America/Sao_Paulo'
                  ) @> tstzrange(v.inicio_em, v.fim_em)
            )
          )
     )
     -- 4. Sem bloqueio mútuo com o estabelecimento (RF26)
     and not privado.bloqueado_com_estabelecimento(p.usuario_id, v.estabelecimento_id)
     -- 5. Sem turno sobreposto já confirmado (RN21)
     and not exists (
       select 1 from public.posicao x
        where x.profissional_id = p.id
          and x.estado in ('confirmada', 'cumprida')
          and x.vaga_id <> v.id
          and tstzrange(x.inicio_em, x.fim_em) && tstzrange(v.inicio_em, v.fim_em)
     )
     -- 6. UNIQUE de despacho: não despacha quem já foi despachado nesta vaga
     and not exists (
       select 1 from public.despacho x
        where x.vaga_id = v.id and x.profissional_id = p.id
     );
     -- RN06: Sem ORDER BY por reputação, sem prioridade paga, nada patrocinado.
end $$;

comment on function privado.elegiveis(uuid, uuid) is
  'Consulta os profissionais elegíveis para uma vaga conforme RN05, RF18, RF26, RN21 e RN06. Trata a janela de meia-noite e isola contas de demonstração.';

revoke execute on function privado.elegiveis(uuid, uuid) from public, anon, authenticated;

-- ── 3. privado.despachar_vaga ─────────────────────────────────────────────────
create or replace function privado.despachar_vaga(
  p_vaga_id     uuid,
  p_motivo      text default null,
  p_excluir     uuid default null
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v                   public.vaga%rowtype;
  v_elegiveis         uuid[];
  v_prof_id           uuid;
  v_usr_id            uuid;
  v_notif_id          uuid;
  v_payload           jsonb;
  v_despachos_criados int := 0;
  v_ja_despachados    int;
begin
  select * into v from public.vaga where id = p_vaga_id;
  if not found or v.estado <> 'publicada' then
    return 0;
  end if;

  select array_agg(e.profissional_id) into v_elegiveis
    from privado.elegiveis(p_vaga_id, p_excluir) e;

  -- Se não há nenhum elegível novo:
  if v_elegiveis is null or cardinality(v_elegiveis) = 0 then
    -- Confere se a vaga já teve despachos gerados anteriormente
    select count(*)::int into v_ja_despachados
      from public.despacho
     where vaga_id = p_vaga_id;

    -- Sem nenhum elegível no primeiro despacho: avisa o contratante uma vez (UC02 1a)
    if v_ja_despachados = 0 then
      perform privado.notificar_membros(
        v.estabelecimento_id,
        'vaga_sem_elegiveis',
        v.id,
        jsonb_build_object('vaga_id', v.id)
      );
    end if;

    return 0;
  end if;

  -- Gera despacho e notificação para cada elegível
  foreach v_prof_id in array v_elegiveis loop
    select p.usuario_id into v_usr_id
      from public.profissional p
     where p.id = v_prof_id;

    v_payload := jsonb_build_object('vaga_id', v.id);
    if p_motivo = 'reabertura' then
      v_payload := v_payload || jsonb_build_object('reaberta', true);
    end if;

    v_notif_id := privado.notificar(v_usr_id, 'vaga', v.id, v_payload);

    insert into public.despacho (vaga_id, profissional_id, notificacao_id, criado_em)
    values (v.id, v_prof_id, v_notif_id, privado.agora())
    on conflict (vaga_id, profissional_id) do nothing;

    if found then
      v_despachos_criados := v_despachos_criados + 1;
    end if;
  end loop;

  return v_despachos_criados;
end $$;

comment on function privado.despachar_vaga(uuid, text, uuid) is
  'Cria as linhas de despacho e notificacao para todos os elegíveis de uma vaga. Se vazia, envia vaga_sem_elegiveis.';

revoke execute on function privado.despachar_vaga(uuid, text, uuid) from public, anon, authenticated;

-- ── 4. Reprocessamento pela fila pgmq com tentativas limitadas ────────────────
create or replace function privado.processar_fila_despacho(
  p_qtd int default 10,
  p_vt  int default 30
)
returns table (
  msg_id     bigint,
  vaga_id    uuid,
  sucesso    boolean,
  despachos  int,
  erro       text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_msg            record;
  v_vaga_id        uuid;
  v_motivo         text;
  v_excluir        uuid;
  v_n              int;
  v_tentativas_max constant int := 5;
begin
  for v_msg in select * from pgmq.read('despacho', p_vt, p_qtd) loop
    v_vaga_id := (v_msg.message->>'vaga_id')::uuid;
    v_motivo  := v_msg.message->>'motivo';
    v_excluir := (v_msg.message->>'excluir_conta')::uuid;

    -- Tentativas limitadas: se falhou repetidas vezes, arquiva a mensagem
    if v_msg.read_ct > v_tentativas_max then
      perform pgmq.archive('despacho', v_msg.msg_id);
      msg_id    := v_msg.msg_id;
      vaga_id   := v_vaga_id;
      sucesso   := false;
      despachos := 0;
      erro      := 'teto_tentativas_excedido';
      return next;
      continue;
    end if;

    begin
      v_n := privado.despachar_vaga(v_vaga_id, v_motivo, v_excluir);
      -- Sucesso: arquiva a mensagem da fila
      perform pgmq.archive('despacho', v_msg.msg_id);

      msg_id    := v_msg.msg_id;
      vaga_id   := v_vaga_id;
      sucesso   := true;
      despachos := v_n;
      erro      := null;
      return next;
    exception when others then
      -- Falha: mensagem permanece com visibility timeout ativo para posterior reprocessamento
      msg_id    := v_msg.msg_id;
      vaga_id   := v_vaga_id;
      sucesso   := false;
      despachos := 0;
      erro      := SQLERRM;
      return next;
    end;
  end loop;
end $$;

comment on function privado.processar_fila_despacho(int, int) is
  'Consome mensagens de pgmq.q_despacho com limite de 5 tentativas. Arquiva mensagens bem-sucedidas ou esgotadas.';

revoke execute on function privado.processar_fila_despacho(int, int) from public, anon, authenticated;

-- ── 5. Chamada assíncrona pós-commit via net.http_post ────────────────────────
create or replace function privado.disparar_despacho(p_vaga_id uuid default null)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    current_setting('frila.edge_function_url', true),
    'http://127.0.0.1:54321/functions/v1/despachar'
  );
  v_secret text := coalesce(
    current_setting('frila.agendador_secret', true),
    current_setting('supabase.service_role_key', true),
    'frila-agendador-segredo-local'
  );
  v_req_id bigint;
begin
  -- Dispara o webhook assíncrono pós-commit via pg_net
  begin
    v_req_id := net.http_post(
      url => v_url,
      headers => jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_secret,
        'x-agendador-secret', v_secret
      ),
      body => jsonb_build_object(
        'vaga_id', p_vaga_id,
        'origem', 'pos_commit'
      ),
      timeout_milliseconds => 5000
    );
  exception when others then
    -- Falha de rede/pg_net não impede o commit; o pg_cron reprocessará da fila
    v_req_id := null;
  end;
  return v_req_id;
end $$;

comment on function privado.disparar_despacho(uuid) is
  'Dispara a Edge Function despachar na hora via net.http_post (sai pós-commit).';

revoke execute on function privado.disparar_despacho(uuid) from public, anon, authenticated;

-- Gatilho automático em pgmq.q_despacho:
-- Sempre que uma mensagem entra na fila (via publicar_vaga ou cancelar_posicao / reabrir),
-- o gatilho dispara o POST assíncrono pós-commit.
create or replace function privado.trg_disparar_despacho()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform privado.disparar_despacho((new.message->>'vaga_id')::uuid);
  return new;
end $$;

drop trigger if exists trg_despacho_enfileirado on pgmq.q_despacho;
create trigger trg_despacho_enfileirado
  after insert on pgmq.q_despacho
  for each row
  execute function privado.trg_disparar_despacho();

-- ── 6. O job do pg_cron para reprocessamento periódico ────────────────────────
-- O job roda a cada 1 minuto para drenar a fila pgmq e reprocessar o que
-- eventualmente falhou no envio imediato pós-commit (RNF03).
-- Fica escrito e ativado no banco local / documentado para o remoto.
create extension if not exists pg_cron;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('reprocessar_despacho')
      where exists (select 1 from cron.job where jobname = 'reprocessar_despacho');
    perform cron.schedule(
      'reprocessar_despacho',
      '* * * * *',
      'select privado.processar_fila_despacho()'
    );
  end if;
exception when others then
  null;
end $$;
