-- Alerta de atraso aos 15 minutos e `reabrir_por_atraso` (cartão e8XpOZJN).
--
-- US15 (cenário 4), US16 · RF13, RF14 · RN12, RN22 · UC05 · D06.
--
-- No início do turno sem check-in, o profissional recebe `inicio_sem_checkin`. Aos 15
-- minutos, cada membro da casa recebe `atraso_15min` e decide esperar ou reabrir.
-- Reabrir é declarar o não comparecimento: a posição é cancelada **com falta** (RN12), a
-- vaga ganha posição nova e o despacho sai de novo.
--
-- Decisões de produto seguidas (cartão 8zLfn0mt, recomendações aprovadas em 28/09):
--
--   · item 5 — a posição reaberta por atraso aceita candidatura até 1 h antes do fim
--     previsto. Esta migração marca a posição (`reaberta_por_atraso_de`) e fecha a que
--     ninguém pegou nesse prazo. A liberação em `candidatar` depende do contrato 0.2.19
--     (hoje `vaga_encerrada` vale para toda vaga cujo início passou) e entra em PR
--     próprio, depois do espelho.
--   · item 2 — a unicidade do despacho por rodada **não** entra aqui: a reabertura usa a
--     fila como `cancelar_posicao` usa, e quem já recebeu a vaga não é notificado de
--     novo. Cartão próprio.

-- ── 1. A posição sabe que é reabertura de uma falta ───────────────────────────
--
-- Coluna, e não dedução por `ocorrencia`: a regra do prazo (fim − 1 h) vale só para esta
-- posição, e o reenvio de `reabrir_por_atraso` precisa achar a posição que já criou. O
-- `unique` é o que impede uma segunda posição nova para a mesma falta.
alter table public.posicao
  add column reaberta_por_atraso_de uuid references public.posicao(id);

create unique index posicao_uma_reabertura_por_falta
  on public.posicao (reaberta_por_atraso_de)
  where reaberta_por_atraso_de is not null;

comment on column public.posicao.reaberta_por_atraso_de is
  'A posição cancelada por atraso que esta substitui (reabrir_por_atraso, RN12). Nula nas demais. Marca a posição que aceita candidatura depois do início, até 1 h antes do fim (decisão 8zLfn0mt, item 5).';

-- ── 2. Check-in nunca em posição cancelada ──────────────────────────────────────
--
-- `reabrir_por_atraso` trava a posição e o turno. O check-in que chega junto espera a
-- trava no `update` do turno e, sem esta guarda, gravaria presença numa posição que a
-- casa acabou de cancelar. O gatilho lê a posição depois de ganhar a linha, com o
-- estado já decidido.
create or replace function privado.checkin_nunca_em_posicao_cancelada()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.checkin_em is not null and old.checkin_em is null
     and exists (select 1 from public.posicao p
                  where p.id = new.posicao_id and p.estado = 'cancelada') then
    perform public.erro(409, 'vaga_encerrada', 'posicao_cancelada');
  end if;
  return new;
end $$;

comment on function privado.checkin_nunca_em_posicao_cancelada() is
  'Recusa o check-in em turno cuja posição foi cancelada (reaberta por atraso ou cancelada por uma das partes). Fecha a corrida entre fazer_checkin e reabrir_por_atraso.';

revoke execute on function privado.checkin_nunca_em_posicao_cancelada()
  from public, anon, authenticated;
grant execute on function privado.checkin_nunca_em_posicao_cancelada() to service_role;

create trigger turno_checkin_nunca_em_posicao_cancelada
  before update of checkin_em on public.turno
  for each row execute function privado.checkin_nunca_em_posicao_cancelada();

-- ── 3. reabrir_por_atraso ─────────────────────────────────────────────────────

create or replace function public.reabrir_por_atraso(posicao_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid     uuid := (select auth.uid());
  v_agora   timestamptz;
  v_pos     public.posicao%rowtype;
  v_t       public.turno%rowtype;
  v_usr     uuid;
  v_nova    uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('contratante');

  if reabrir_por_atraso.posicao_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'posicao_id');
  end if;

  -- A trava vem antes de qualquer leitura de estado: posição e depois turno, a mesma
  -- ordem para toda chamada. O check-in simultâneo espera aqui ou é esperado.
  select * into v_pos from public.posicao p
   where p.id = reabrir_por_atraso.posicao_id
     for update;

  -- Posição que não existe e posição de outra casa respondem igual: um 404 diria a
  -- quem não é da casa que aquela posição existe.
  if not found or not privado.eh_membro(privado.estabelecimento_da_vaga(v_pos.vaga_id)) then
    perform public.erro(403, 'sem_permissao');
  end if;

  select * into v_t from public.turno t where t.posicao_id = v_pos.id for update;

  -- Reenvio: a rede caiu depois do commit. A falta já foi marcada; devolve o que a
  -- primeira chamada devolveu, sem segunda posição nem segundo aviso.
  if v_pos.estado = 'cancelada'
     and exists (select 1 from public.ocorrencia o
                  where o.posicao_id = v_pos.id and o.tipo = 'cancelamento'
                    and o.motivo = 'reabertura_por_atraso') then
    select p.id into v_nova from public.posicao p where p.reaberta_por_atraso_de = v_pos.id;
    return jsonb_build_object(
      'posicao_id',      v_pos.id,
      'falta',           v_pos.falta,
      'reaberta',        v_nova is not null,
      'nova_posicao_id', v_nova);
  end if;

  if v_pos.estado <> 'confirmada' then
    perform public.erro(409, 'posicao_nao_cancelavel');
  end if;

  if v_t.checkin_em is not null then
    perform public.erro(409, 'posicao_nao_cancelavel', 'checkin_registrado');
  end if;

  v_agora := privado.agora();

  -- D06: a tolerância é de 15 minutos a partir do início previsto.
  if v_agora < v_pos.inicio_em + interval '15 minutes' then
    perform public.erro(422, 'reabertura_antes_da_tolerancia');
  end if;

  v_usr := privado.usuario_do_profissional(v_pos.profissional_id);

  -- RN12: reabrir por atraso é declarar que o profissional não veio. Conta como falta,
  -- com a mesma posição guardando de quem ela era.
  update public.posicao p
     set estado = 'cancelada',
         falta  = true
   where p.id = v_pos.id;

  update public.turno t
     set verificacao = 'nao_verificado'
   where t.posicao_id = v_pos.id and t.verificacao = 'pendente';

  -- Motivo estável, e não texto da casa: é o que distingue esta falta das outras na
  -- auditoria e no texto do aviso ao profissional.
  insert into public.ocorrencia (tipo, posicao_id, turno_id, usuario_id, autor_id, motivo)
  values ('cancelamento', v_pos.id, v_t.id, v_usr, v_uid, 'reabertura_por_atraso');

  -- 8zLfn0mt item 5: a posição reaberta aceita candidato até 1 h antes do fim. Depois
  -- disso ninguém chega a tempo, e reabrir seria só um despacho inútil.
  if v_agora < v_pos.fim_em - interval '1 hour' then
    insert into public.posicao (vaga_id, inicio_em, fim_em, reaberta_por_atraso_de)
    values (v_pos.vaga_id, v_pos.inicio_em, v_pos.fim_em, v_pos.id)
    returning id into v_nova;

    update public.vaga g set estado = 'publicada'
     where g.id = v_pos.vaga_id and g.estado = 'preenchida';

    -- O mesmo despacho da reabertura por cancelamento. Quem faltou não é notificado da
    -- vaga que deixou de cumprir.
    perform pgmq.send('despacho', jsonb_build_object(
      'vaga_id',       v_pos.vaga_id,
      'posicao_id',    v_nova,
      'motivo',        'reabertura',
      'excluir_conta', v_usr));
  end if;

  perform privado.recalcular_comparecimento(v_pos.profissional_id);

  -- O profissional é avisado; a casa, que decidiu, não.
  perform privado.notificar(v_usr, 'cancelamento', v_pos.id,
    jsonb_build_object('posicao_id', v_pos.id, 'vaga_id', v_pos.vaga_id,
                       'reaberta', v_nova is not null));

  return jsonb_build_object(
    'posicao_id',      v_pos.id,
    'falta',           true,
    'reaberta',        v_nova is not null,
    'nova_posicao_id', v_nova);
end $$;

comment on function public.reabrir_por_atraso(uuid) is
  'Aos 15 minutos do início sem check-in, a casa declara o não comparecimento (D06, RN12): cancela a posição com falta, cria posição nova marcada como reaberta por atraso, volta a vaga a publicada e enfileira o despacho. A menos de 1 h do fim, marca a falta sem reabrir. Reenviar devolve o mesmo resultado.';

revoke execute on function public.reabrir_por_atraso(uuid) from public, anon;
grant execute on function public.reabrir_por_atraso(uuid) to authenticated;

-- ── 4. O agendador do atraso ──────────────────────────────────────────────────
--
-- Roda a cada minuto. Os três passos são idempotentes: os avisos pela marca de envio
-- (tipo, referência, conta), e o fechamento pelo estado.
create or replace function privado.alertar_atrasos()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora timestamptz := privado.agora();
  v_turno record;
  v_n     integer := 0;
begin
  for v_turno in
    select t.id as turno_id, p.id as posicao_id, p.inicio_em, p.profissional_id,
           g.estabelecimento_id
      from public.posicao p
      join public.turno t on t.posicao_id = p.id
      join public.vaga g on g.id = p.vaga_id
     where p.estado = 'confirmada'
       and t.checkin_em is null
       and p.inicio_em <= v_agora
       and p.fim_em > v_agora
  loop
    -- RF13: no início, o lembrete ao profissional.
    perform privado.notificar(
      privado.usuario_do_profissional(v_turno.profissional_id),
      'inicio_sem_checkin', v_turno.turno_id,
      jsonb_build_object('turno_id', v_turno.turno_id));

    -- D06: aos 15 minutos, cada membro da casa, com a posição que o botão de reabrir usa.
    if v_agora >= v_turno.inicio_em + interval '15 minutes' then
      perform privado.notificar_membros(
        v_turno.estabelecimento_id, 'atraso_15min', v_turno.turno_id,
        jsonb_build_object('turno_id', v_turno.turno_id, 'posicao_id', v_turno.posicao_id));
    end if;

    v_n := v_n + 1;
  end loop;

  -- 8zLfn0mt item 5: a posição reaberta por atraso que ninguém pegou até 1 h antes do
  -- fim fecha. Não há de quem ser falta: ela nunca teve profissional.
  update public.posicao p
     set estado = 'cancelada'
   where p.estado = 'aberta'
     and p.reaberta_por_atraso_de is not null
     and v_agora >= p.fim_em - interval '1 hour';

  return v_n;
end $$;

comment on function privado.alertar_atrasos() is
  'Agendador de minuto: inicio_sem_checkin ao profissional no início sem check-in (RF13), atraso_15min a cada membro da casa aos 15 minutos (D06), uma vez por turno pela marca de envio; fecha a posição reaberta por atraso não preenchida a 1 h do fim (8zLfn0mt item 5).';

revoke execute on function privado.alertar_atrasos() from public, anon, authenticated;
grant execute on function privado.alertar_atrasos() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('alertar_atrasos')
      where exists (select 1 from cron.job where jobname = 'alertar_atrasos');
    perform cron.schedule('alertar_atrasos', '* * * * *', 'select privado.alertar_atrasos()');
  end if;
end $$;

-- ── 5. Avisos que servem depois do início ─────────────────────────────────────
--
-- `notificacao_expirada` descartava todo aviso de turno cujo início passou. O lembrete
-- de início e o alerta de 15 minutos só existem depois do início, e o aviso de reabertura
-- também: com a regra antiga, nenhum dos três chegaria ao aparelho. Eles valem até o fim
-- do turno, e os dois alertas expiram antes se a posição deixou de esperar check-in.
-- A vaga reaberta por atraso vale até 1 h antes do fim, o prazo da candidatura.
create or replace function privado.notificacao_expirada(p_notificacao_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_notif  public.notificacao%rowtype;
  v_inicio timestamptz;
  v_limite timestamptz;
  v_agora  timestamptz := privado.agora();
begin
  select * into v_notif from public.notificacao where id = p_notificacao_id;
  if not found then
    return true;
  end if;

  if v_notif.tipo in ('inicio_sem_checkin', 'atraso_15min') then
    select p.fim_em into v_limite
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
     where t.id = v_notif.referencia_id
       and p.estado = 'confirmada'
       and t.checkin_em is null;
    return v_limite is null or v_limite <= v_agora;
  end if;

  if v_notif.tipo = 'cancelamento' then
    select p.inicio_em, p.fim_em into v_inicio, v_limite
      from public.posicao p
     where p.id = v_notif.referencia_id
       and exists (select 1 from public.ocorrencia o
                    where o.posicao_id = p.id and o.tipo = 'cancelamento'
                      and o.motivo = 'reabertura_por_atraso');
    if v_limite is not null then
      return v_limite <= v_agora;
    end if;
  end if;

  if v_notif.tipo in ('vaga', 'vagas_agrupadas', 'vaga_sem_elegiveis', 'vaga_vazia') then
    select max(p.fim_em) - interval '1 hour' into v_limite
      from public.posicao p
     where p.vaga_id = v_notif.referencia_id
       and p.estado = 'aberta'
       and p.reaberta_por_atraso_de is not null;
    if v_limite is not null then
      return v_limite <= v_agora;
    end if;
    select g.inicio_em into v_inicio from public.vaga g where g.id = v_notif.referencia_id;
  elsif v_notif.tipo in ('confirmacao', 'cancelamento') then
    select g.inicio_em into v_inicio
      from public.posicao p
      join public.vaga g on g.id = p.vaga_id
     where p.id = v_notif.referencia_id;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.turno t
        join public.posicao p on p.id = t.posicao_id
        join public.vaga g on g.id = p.vaga_id
       where t.id = v_notif.referencia_id;
    end if;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.vaga g
       where g.id = v_notif.referencia_id;
    end if;
  elsif v_notif.tipo in ('lembrete_24h', 'lembrete_3h', 'fim_sem_checkout', 'checkin',
                         'checkin_manual_pendente') then
    select g.inicio_em into v_inicio
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga g on g.id = p.vaga_id
     where t.id = v_notif.referencia_id;

    if v_inicio is null then
      select g.inicio_em into v_inicio
        from public.posicao p
        join public.vaga g on g.id = p.vaga_id
       where p.id = v_notif.referencia_id;
    end if;
  end if;

  if v_inicio is not null and v_inicio <= v_agora then
    return true;
  end if;

  return false;
end $$;

comment on function privado.notificacao_expirada(uuid) is
  'Verifica se o aviso ainda serve. Regra geral: expira no início do turno ou da vaga. inicio_sem_checkin e atraso_15min valem até o fim, enquanto a posição espera check-in; o aviso de reabertura por atraso vale até o fim; a vaga reaberta por atraso, até 1 h antes do fim (8zLfn0mt item 5).';

revoke execute on function privado.notificacao_expirada(uuid) from public, anon, authenticated;
grant  execute on function privado.notificacao_expirada(uuid) to service_role;
