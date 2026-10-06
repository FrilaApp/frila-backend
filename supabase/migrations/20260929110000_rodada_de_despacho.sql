-- Rodada de despacho da posição reaberta por atraso (cartão 9DbPXis7).
--
-- US07, US15 (cenário 4), US16 · RN05, RN12, RN22, RN23 · UC05 · decisão 8zLfn0mt item 2.
--
-- `reabrir_por_atraso` (e8XpOZJN) volta a vaga a publicada e enfileira o despacho, mas
-- `despacho` era único por (vaga, profissional): quem recebeu a vaga na publicação não
-- recebia a posição reaberta — e é justamente quem está mais perto e disponível. A
-- decisão 8zLfn0mt, item 2, aprovou a unicidade por **rodada**:
--
--   · a vaga conta as rodadas (`vaga.rodada_despacho`, 1 na publicação); cada
--     reabertura por atraso abre a seguinte;
--   · `despacho` passa a ser único por (vaga, profissional, rodada), e a marca de envio
--     de `notificacao` também, para o push da rodada nova não ser engolido pelo da
--     primeira;
--   · a rodada nova vai a todo elegível, menos quem já faltou nesta vaga e quem já
--     trabalha nela (confirmado em outra posição da mesma vaga);
--   · o despacho continua passando pelo teto da RN23 (ee3MT3fH) — como o turno já
--     começou, a rodada de uma reabertura por atraso é sempre urgente: sai na hora e
--     conta no teto;
--   · o push é o de vaga reaberta (Push 04), pelo `reaberta` no payload.
--
-- A reabertura por cancelamento (`cancelar_posicao`) não abre rodada: continua
-- notificando só quem ainda não recebeu a vaga. A decisão foi sobre a falta.

-- ── 1. As rodadas ─────────────────────────────────────────────────────────────

alter table public.vaga
  add column rodada_despacho integer not null default 1,
  add constraint vaga_rodada_despacho_positiva check (rodada_despacho >= 1);

comment on column public.vaga.rodada_despacho is
  'Rodada de despacho corrente da vaga: 1 na publicação, mais um a cada reabertura por atraso (decisão 8zLfn0mt item 2). O despacho e a marca de envio da notificação de vaga são únicos por rodada.';

alter table public.despacho
  add column rodada integer not null default 1,
  add constraint despacho_rodada_positiva check (rodada >= 1);

comment on column public.despacho.rodada is
  'Rodada da vaga em que o despacho nasceu (vaga.rodada_despacho). O mesmo profissional recebe a mesma vaga uma vez por rodada.';

alter table public.despacho
  drop constraint despacho_vaga_id_profissional_id_key,
  add constraint despacho_vaga_profissional_rodada_key unique (vaga_id, profissional_id, rodada);

alter table public.notificacao
  add column rodada integer not null default 1,
  add constraint notificacao_rodada_positiva check (rodada >= 1);

comment on column public.notificacao.rodada is
  'Rodada da vaga a que a notificação de vaga se refere. Nos demais tipos é sempre 1. Faz parte da marca de envio: a vaga reaberta avisa de novo quem já tinha sido avisado.';

drop index public.notificacao_marca_de_envio;
create unique index notificacao_marca_de_envio
  on public.notificacao (tipo, referencia_id, usuario_id, rodada)
  where tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                 'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                 'vaga');

-- ── 2. privado.notificar: a marca de envio por rodada ─────────────────────────
--
-- A rodada da notificação de vaga é a rodada corrente da vaga, lida aqui, e não passada
-- por quem chama: o despacho urgente e o teto liberado (`liberar_teto_do_profissional`)
-- chegam pelo mesmo caminho sem precisar saber de rodada.
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
  v_prof   uuid;
  v_id     uuid;
  v_par    record;
  v_rodada integer := 1;
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

  if p_tipo = 'vaga' then
    select g.rodada_despacho into v_rodada from public.vaga g where g.id = p_referencia;
    v_rodada := coalesce(v_rodada, 1);
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
  'Enfileira um aviso para uma conta (estado pendente; o envio ao FCM é do agendador). A marca de envio evita duplicidade nos tipos agendados, em vaga_sem_elegiveis e em vaga — esta, por rodada da vaga. Payload estrito conforme RN15.';

revoke execute on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb)
  from public, anon, authenticated;
grant  execute on function privado.notificar(uuid, public.tipo_notificacao, uuid, jsonb)
  to service_role;

-- ── 3. privado.elegiveis: quem entra na rodada ────────────────────────────────
--
-- Duas exclusões novas, que só têm efeito da segunda rodada em diante — na publicação
-- ninguém ainda tem posição na vaga:
--
--   · quem faltou nesta vaga, em qualquer rodada. `excluir_conta` exclui só quem acabou
--     de faltar; sem esta linha, a terceira rodada chamaria de volta o autor da primeira
--     falta;
--   · quem está confirmado em outra posição da mesma vaga. O RN21 de baixo ignora a
--     própria vaga, e com a rodada nova ele seria convidado para o turno que já cumpre.
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
     -- 6. Nesta vaga, nem quem faltou (RN12, em qualquer rodada) nem quem já trabalha nela
     and not exists (
       select 1 from public.posicao x
        where x.vaga_id = v.id
          and x.profissional_id = p.id
          and (x.falta or x.estado in ('confirmada', 'cumprida'))
     )
     -- 7. Um despacho por rodada (8zLfn0mt item 2): não despacha de novo nesta rodada
     and not exists (
       select 1 from public.despacho x
        where x.vaga_id = v.id and x.profissional_id = p.id
          and x.rodada = v.rodada_despacho
     );
     -- RN06: Sem ORDER BY por reputação, sem prioridade paga, nada patrocinado.
end $$;

comment on function privado.elegiveis(uuid, uuid) is
  'Consulta os profissionais elegíveis para a rodada corrente de uma vaga conforme RN05, RF18, RF26, RN21 e RN06. Trata a janela de meia-noite, isola contas de demonstração e, na reabertura, deixa fora quem faltou na vaga e quem já está confirmado nela.';

revoke execute on function privado.elegiveis(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.elegiveis(uuid, uuid) to service_role;

-- ── 4. privado.despachar_vaga: o despacho da rodada corrente ──────────────────
--
-- O mesmo despacho da RN23 (ee3MT3fH), com a rodada gravada em cada linha. A partir da
-- rodada 2 o despacho é de vaga reaberta mesmo se a mensagem da fila tiver perdido o
-- motivo: é a rodada que diz que houve reabertura.
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
  v_agora             timestamptz := privado.agora();
  v_urgente           boolean;
  v_reaberta          boolean;
  v_elegiveis         uuid[];
  v_prof_id           uuid;
  v_usr_id            uuid;
  v_desp_id           uuid;
  v_notif_id          uuid;
  v_payload           jsonb;
  v_despachos_criados int := 0;
  v_ja_despachados    int;
begin
  select * into v from public.vaga where id = p_vaga_id;
  if not found or v.estado <> 'publicada' then
    return 0;
  end if;

  v_reaberta := coalesce(p_motivo = 'reabertura', false) or v.rodada_despacho > 1;

  -- A ordem por id é só a ordem de aquisição das travas do teto (ver liberar_teto), e
  -- não decide quem recebe: todo elegível recebe (RN06).
  select array_agg(e.profissional_id order by e.profissional_id) into v_elegiveis
    from privado.elegiveis(p_vaga_id, p_excluir) e;

  if v_elegiveis is null or cardinality(v_elegiveis) = 0 then
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

  -- RN23: a vaga que começa em menos de 2 h fura o agrupamento. Conta o tempo até o
  -- início, e não o modo: a vaga de seleção só chega a menos de 2 h por reabertura, e a
  -- reabertura em cima da hora é o caso que mais precisa sair na hora. A reabertura por
  -- atraso acontece depois do início, então a rodada dela é sempre urgente.
  v_urgente := v.inicio_em - v_agora < privado.parametro_de_notificacao('urgente_antecedencia');

  foreach v_prof_id in array v_elegiveis loop
    perform privado.travar_teto(v_prof_id);

    insert into public.despacho (vaga_id, profissional_id, notificacao_id, criado_em, reaberta, rodada)
    values (v.id, v_prof_id, null, v_agora, v_reaberta, v.rodada_despacho)
    on conflict (vaga_id, profissional_id, rodada) do nothing
    returning id into v_desp_id;

    if v_desp_id is null then
      continue;
    end if;
    v_despachos_criados := v_despachos_criados + 1;

    if v_urgente then
      select p.usuario_id into v_usr_id from public.profissional p where p.id = v_prof_id;

      v_payload := jsonb_build_object('vaga_id', v.id);
      if v_reaberta then
        v_payload := v_payload || jsonb_build_object('reaberta', true);
      end if;

      -- A marca de envio de `vaga` em (tipo, referencia_id, usuario_id, rodada) mantém a
      -- idempotência sob chamadas concorrentes.
      v_notif_id := privado.notificar(v_usr_id, 'vaga', v.id, v_payload);

      update public.notificacao n set urgente = true where n.id = v_notif_id;
      update public.despacho d set notificacao_id = v_notif_id where d.id = v_desp_id;
    else
      -- Janela fechada: sai agora, junto com o que ainda esperava. Janela aberta: fica
      -- esperando, com `notificacao_id` nulo, até o agendador liberar.
      perform privado.liberar_teto_do_profissional(v_prof_id);
    end if;
  end loop;

  return v_despachos_criados;
end $$;

comment on function privado.despachar_vaga(uuid, text, uuid) is
  'Cria o despacho de cada elegível da rodada corrente de uma vaga e passa pelo teto da RN23: sai na hora se a janela do profissional fechou ou se a vaga começa em menos de 2 h; senão espera o agendador (liberar_teto). Da rodada 2 em diante o push é o de vaga reaberta. Se não há elegível, envia vaga_sem_elegiveis.';

revoke execute on function privado.despachar_vaga(uuid, text, uuid) from public, anon, authenticated;
grant  execute on function privado.despachar_vaga(uuid, text, uuid) to service_role;

-- ── 5. A posição reaberta por atraso abre a rodada seguinte ───────────────────
--
-- Por gatilho, e não dentro de `reabrir_por_atraso`: a RPC continua como e8XpOZJN a
-- deixou, e a superfície do contrato não muda. A posição com `reaberta_por_atraso_de`
-- só nasce ali, uma vez por falta (`posicao_uma_reabertura_por_falta`), na mesma
-- transação que volta a vaga a publicada e enfileira o despacho; o reenvio da RPC sai
-- antes de criar posição e não abre outra rodada. Quando o despacho da fila roda, a
-- rodada nova já está gravada.
create or replace function privado.abrir_rodada_da_reabertura()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.vaga g
     set rodada_despacho = g.rodada_despacho + 1
   where g.id = new.vaga_id;
  return null;
end $$;

comment on function privado.abrir_rodada_da_reabertura() is
  'Gatilho AFTER INSERT de posicao reaberta por atraso: abre a rodada de despacho seguinte da vaga (decisão 8zLfn0mt item 2). O despacho que reabrir_por_atraso enfileira chega de novo a quem já tinha recebido a vaga.';

revoke execute on function privado.abrir_rodada_da_reabertura() from public, anon, authenticated;
grant  execute on function privado.abrir_rodada_da_reabertura() to service_role;

create trigger posicao_reaberta_abre_rodada
  after insert on public.posicao
  for each row
  when (new.reaberta_por_atraso_de is not null)
  execute function privado.abrir_rodada_da_reabertura();
