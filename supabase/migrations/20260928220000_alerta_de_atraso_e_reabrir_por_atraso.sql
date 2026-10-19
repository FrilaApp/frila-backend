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
--     previsto (contrato 0.2.19). Esta migração marca a posição (`reaberta_por_atraso_de`),
--     libera `candidatar` nela, ajusta `vagas_abertas` e `detalhe_vaga` à mesma regra e
--     fecha a posição que ninguém pegou nesse prazo.
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

  -- D06: a tolerância é de 15 minutos a partir do início previsto. O substituto que
  -- confirmou uma posição reaberta com o turno já em andamento ganha os mesmos 15
  -- minutos, contados da confirmação: sem isso a casa poderia declarar falta de quem
  -- acabou de aceitar.
  if v_agora < greatest(v_pos.inicio_em, v_pos.confirmado_em) + interval '15 minutes' then
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
    select t.id as turno_id, p.id as posicao_id, p.inicio_em, p.confirmado_em,
           p.profissional_id, g.estabelecimento_id
      from public.posicao p
      join public.turno t on t.posicao_id = p.id
      join public.vaga g on g.id = p.vaga_id
     where p.estado = 'confirmada'
       and t.checkin_em is null
       and p.inicio_em <= v_agora
       and p.fim_em > v_agora
  loop
    -- RF13: no início, o lembrete ao profissional. O substituto que confirmou com o turno
    -- em andamento não recebe: para ele o início já tinha passado quando aceitou, e o aviso
    -- chegaria colado na própria confirmação.
    if v_turno.confirmado_em <= v_turno.inicio_em then
      perform privado.notificar(
        privado.usuario_do_profissional(v_turno.profissional_id),
        'inicio_sem_checkin', v_turno.turno_id,
        jsonb_build_object('turno_id', v_turno.turno_id));
    end if;

    -- D06: aos 15 minutos, cada membro da casa, com a posição que o botão de reabrir usa.
    -- Para o substituto, os 15 minutos contam da confirmação, como em reabrir_por_atraso.
    if v_agora >= greatest(v_turno.inicio_em, v_turno.confirmado_em) + interval '15 minutes' then
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

  if v_notif.tipo = 'vaga_vazia' then
    select g.inicio_em into v_inicio
      from public.posicao p
      join public.vaga g on g.id = p.vaga_id
     where p.id = v_notif.referencia_id;

    if exists (select 1 from public.posicao p
                where p.id = v_notif.referencia_id and p.estado <> 'aberta') then
      return true;
    end if;

    if v_inicio is null then
      select g.inicio_em into v_inicio from public.vaga g where g.id = v_notif.referencia_id;
    end if;

    return v_inicio is null or v_inicio <= v_agora;
  end if;

  if v_notif.tipo in ('vaga', 'vagas_agrupadas', 'vaga_sem_elegiveis') then
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

-- ── 6. Contrato 0.2.19: candidatura na posição reaberta por atraso ────────────
--
-- A exceção é da posição, e não da vaga. Antes do início, toda posição aberta serve,
-- como sempre. Depois, só a criada por `reabrir_por_atraso`, e só até `fim_em - 1 h`
-- (8zLfn0mt, item 5). Uma regra só, em uma função só: `candidatar` escolhe por ela,
-- `vagas_abertas` e `detalhe_vaga` contam por ela, e a vitrine não pode prometer o que a
-- candidatura recusa.
create or replace function privado.posicao_candidatavel(p public.posicao, agora timestamptz)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p.estado = 'aberta'
     and (p.inicio_em > agora
          or (p.reaberta_por_atraso_de is not null and agora < p.fim_em - interval '1 hour'))
$$;

comment on function privado.posicao_candidatavel(public.posicao, timestamptz) is
  'Posição que aceita candidatura agora: aberta e antes do início, ou reaberta por atraso e antes de fim − 1 h (contrato 0.2.19, 8zLfn0mt item 5).';

revoke execute on function privado.posicao_candidatavel(public.posicao, timestamptz)
  from public, anon, authenticated;
grant execute on function privado.posicao_candidatavel(public.posicao, timestamptz)
  to service_role;

create or replace function privado.posicoes_candidataveis(vaga uuid, agora timestamptz)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::int from public.posicao p
   where p.vaga_id = vaga and privado.posicao_candidatavel(p.*, agora)
$$;

comment on function privado.posicoes_candidataveis(uuid, timestamptz) is
  'Quantas posições da vaga aceitam candidatura agora. É o `posicoes_abertas` de vagas_abertas e detalhe_vaga (contrato 0.2.19).';

revoke execute on function privado.posicoes_candidataveis(uuid, timestamptz)
  from public, anon, authenticated;
grant execute on function privado.posicoes_candidataveis(uuid, timestamptz) to service_role;

create or replace function public.candidatar(vaga_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_prof  uuid;
  v_agora timestamptz;
  v       public.vaga%rowtype;
  v_pos   uuid;
  v_turno uuid;
  v_cand  uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if candidatar.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  -- RN13. A conta suspensa continua enxergando a lista, e é recusada aqui: a recusa
  -- tem motivo em `details` para a tela poder explicar em vez de só negar.
  if exists (select 1 from public.usuario u
              where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(422, 'inelegivel', 'perfil_suspenso');
  end if;

  select p.id into v_prof from public.profissional p where p.usuario_id = v_uid;
  if v_prof is null then
    -- Sem perfil não há função cadastrada, e sem função nenhuma vaga serve. O código é
    -- o mesmo da função incompatível de propósito: para o profissional, os dois casos
    -- terminam na mesma tela — a de completar o perfil.
    perform public.erro(422, 'inelegivel', 'funcao_incompativel');
  end if;

  perform privado.travar_candidatura(candidatar.vaga_id, v_prof);

  select * into v from public.vaga g where g.id = candidatar.vaga_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- O mesmo 404 das leituras, e pelo mesmo motivo: um 403 confirmaria que a vaga
  -- existe a quem bloqueou a casa ou a quem está do outro lado da demonstração.
  if privado.bloqueado_com_estabelecimento(v_uid, v.estabelecimento_id)
     or not exists (select 1 from public.usuario u
                     where u.id = v.publicado_por
                       and u.demonstracao = privado.conta_de_demonstracao()) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  -- Idempotência pela chave natural (vaga, profissional). A rede cai depois do commit
  -- e o app reenvia: a segunda chamada devolve o mesmo turno em vez de tomar uma
  -- segunda posição. Vem **antes** da conferência de estado da vaga, senão o reenvio
  -- que chega depois de a vaga encher receberia `vaga_encerrada` em vez do próprio
  -- resultado.
  select p.id into v_pos
    from public.posicao p
   where p.vaga_id = candidatar.vaga_id
     and p.profissional_id = v_prof
     and p.estado in ('confirmada', 'cumprida');
  if found then
    select t.id into v_turno from public.turno t where t.posicao_id = v_pos;
    select c.id into v_cand from public.candidatura c
     where c.posicao_id = v_pos and c.profissional_id = v_prof;
    return jsonb_build_object(
      'estado',         'confirmada',
      'candidatura_id', v_cand,
      'posicao_id',     v_pos,
      'turno_id',       v_turno,
      'contato',        privado.contato_do_estabelecimento(candidatar.vaga_id));
  end if;

  v_agora := privado.agora();

  -- Dois 409 diferentes, e a diferença importa para a tela. `vaga_encerrada` é "esta
  -- vaga não existe mais"; `posicao_ja_preenchida` é "alguém chegou antes", que o
  -- produto trata como funcionamento normal — "que pena, foi rápido". Vaga
  -- **preenchida** é o segundo caso, e não o primeiro: ela fechou porque encheu.
  if v.estado = 'preenchida' then
    perform public.erro(409, 'posicao_ja_preenchida');
  end if;

  if v.estado <> 'publicada' then
    perform public.erro(409, 'vaga_encerrada');
  end if;

  -- Início já passado conta como encerrada: candidatar-se a um turno que começou não é
  -- corrida perdida, é vaga que não existe mais. A exceção da 0.2.19 é da **posição**: a
  -- reaberta por atraso aceita candidato até 1 h antes do fim (8zLfn0mt, item 5). Sem
  -- nenhuma dessas dentro do prazo, a vaga está encerrada; havendo, perder a corrida por
  -- ela é `posicao_ja_preenchida`, lá embaixo, como antes do início.
  if v.inicio_em <= v_agora
     and not exists (select 1 from public.posicao x
                      where x.vaga_id = candidatar.vaga_id
                        and privado.posicao_candidatavel(x.*, v_agora)) then
    perform public.erro(409, 'vaga_encerrada');
  end if;

  -- RN05: a função é o primeiro critério de elegibilidade, e o único que o profissional
  -- controla. Distância e disponibilidade valem para a **notificação** (B07), não para
  -- a candidatura: quem viu a vaga e quer o turno pode aceitá-lo.
  if not exists (select 1 from public.profissional_funcao pf
                  where pf.profissional_id = v_prof and pf.funcao_id = v.funcao_id) then
    perform public.erro(422, 'inelegivel', 'funcao_incompativel');
  end if;

  -- ── RN19: a confirmação ─────────────────────────────────────────────────────
  --
  -- `SKIP LOCKED` é o que separa vinte candidatos disputando a mesma linha de vinte
  -- candidatos pegando linhas diferentes. Sem ele, dezenove esperariam o commit do
  -- primeiro para só então descobrir que perderam.
  begin
    update public.posicao p
       set estado = 'confirmada',
           profissional_id = v_prof,
           confirmado_em = v_agora
     where p.id = (select x.id from public.posicao x
                    where x.vaga_id = candidatar.vaga_id
                      and privado.posicao_candidatavel(x.*, v_agora)
                    order by x.id
                    for update skip locked
                    limit 1)
    returning p.id into v_pos;
  exception
    when exclusion_violation then
      -- RN21, pelo `EXCLUDE USING gist` de `posicao`. A recusa sai com o código do
      -- contrato em vez do 23P01 cru, que o app não sabe ler.
      perform public.erro(422, 'inelegivel', 'turno_sobreposto');
  end;

  if v_pos is null then
    perform public.erro(409, 'posicao_ja_preenchida');
  end if;

  insert into public.candidatura (posicao_id, profissional_id, estado)
  values (v_pos, v_prof, 'aceita')
  on conflict (posicao_id, profissional_id)
    do update set estado = 'aceita'
  returning id into v_cand;

  -- RN11: o valor viaja para o turno. Se a casa republicar com outro valor, o turno
  -- executado continua dizendo quanto foi combinado — registro que muda sozinho não
  -- vale nada.
  insert into public.turno (posicao_id, valor_acordado_centavos)
  values (v_pos, v.valor_centavos)
  returning id into v_turno;

  -- A vaga fecha quando não sobra posição aberta. O `for update` na linha da vaga não é
  -- zelo: sem ele, as duas últimas confirmações simultâneas contam as posições abertas
  -- cada uma no próprio snapshot, nenhuma enxerga a escrita da outra, e a vaga fica
  -- `publicada` com zero posições livres. Medido na CI em 24/09, com vinte conexões —
  -- a máquina de desenvolvimento não reproduzia, porque o intervalo entre os dois
  -- commits era grande demais.
  --
  -- A ordem de aquisição é sempre posição e depois vaga, em todas as transações, o que
  -- mantém o caminho livre de impasse. O `skip locked` continua fazendo o seu trabalho
  -- antes disto: a serialização é só do fechamento, não da disputa.
  perform 1 from public.vaga g where g.id = candidatar.vaga_id for update;

  if not exists (select 1 from public.posicao p
                  where p.vaga_id = candidatar.vaga_id and p.estado = 'aberta') then
    update public.vaga g set estado = 'preenchida'
     where g.id = candidatar.vaga_id and g.estado = 'publicada';
  end if;

  -- RF10: a confirmação avisa o profissional e cada membro da casa. Só chega aqui a
  -- candidatura que de fato confirmou: o reenvio devolveu o turno lá em cima, antes de
  -- qualquer escrita, e por isso não enfileira aviso de novo.
  perform privado.notificar(v_uid, 'confirmacao', v_turno,
    jsonb_build_object('turno_id', v_turno, 'vaga_id', candidatar.vaga_id));
  perform privado.notificar_membros(v.estabelecimento_id, 'confirmacao', v_turno,
    jsonb_build_object('turno_id', v_turno, 'vaga_id', candidatar.vaga_id));

  return jsonb_build_object(
    'estado',         'confirmada',
    'candidatura_id', v_cand,
    'posicao_id',     v_pos,
    'turno_id',       v_turno,
    'contato',        privado.contato_do_estabelecimento(candidatar.vaga_id));
end $$;


comment on function public.candidatar(uuid) is
  'Candidatura com confirmação sem duplicidade (RN19, RN21). Antes do início, qualquer posição aberta; depois, só a reaberta por atraso até fim − 1 h (contrato 0.2.19). Avisa o profissional e cada membro da casa (RF10).';

revoke execute on function public.candidatar(uuid) from public, anon;
grant execute on function public.candidatar(uuid) to authenticated;

create or replace function public.vagas_abertas(
  latitude         numeric default null,
  longitude        numeric default null,
  funcao_id        uuid    default null,
  data             date    default null,
  distancia_max_km numeric default null,
  limite           int     default 30,
  deslocamento     int     default 0
)
returns jsonb
language plpgsql
-- Não é `stable`: recusa por `public.erro`, que é volátil. O PostgREST a executa numa
-- transação só de leitura e responde ao GET do contrato assim mesmo — o mesmo caminho
-- que `painel_estabelecimento` já usa.
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_ref   extensions.geography;
  v_demo  boolean;
  v_raio  double precision;
  v_agora timestamptz := privado.agora();
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- A lista é a tela de quem procura turno. A política `vaga_leitura` já diz o mesmo em
  -- SQL; aqui a recusa sai com o código que o app compara, em vez de uma lista vazia
  -- que o contratante leria como "não há vagas".
  perform privado.exigir_perfil('profissional');

  if vagas_abertas.limite is null or vagas_abertas.limite < 1 or vagas_abertas.limite > 100 then
    perform public.erro(422, 'campo_invalido', 'limite');
  end if;
  if vagas_abertas.deslocamento is null or vagas_abertas.deslocamento < 0 then
    perform public.erro(422, 'campo_invalido', 'deslocamento');
  end if;

  -- O ponto de referência: a coordenada enviada manda mais que o ponto base, porque
  -- quem abre o app longe de casa quer ver o que há em volta de onde está.
  if vagas_abertas.latitude is not null or vagas_abertas.longitude is not null then
    v_ref := privado.ponto_do_json(
      jsonb_build_object('latitude', vagas_abertas.latitude, 'longitude', vagas_abertas.longitude),
      'latitude');
  else
    select p.ponto_base into v_ref
      from public.profissional p where p.usuario_id = v_uid;
    if v_ref is null then
      -- Sem perfil não há ponto base, e sem ponto de referência não há ordem. Recusar é
      -- melhor do que ordenar por um ponto inventado: a lista sairia plausível e errada.
      perform public.erro(422, 'campo_obrigatorio', 'latitude');
    end if;
  end if;

  v_demo := privado.conta_de_demonstracao();
  v_raio := case when vagas_abertas.distancia_max_km is null
                 then null else vagas_abertas.distancia_max_km * 1000 end;

  return coalesce((
    select jsonb_agg(item order by ordem)
      from (
        select jsonb_build_object(
                 'id',               v.id,
                 'funcao',           privado.funcao_em_json(f.*),
                 'estabelecimento',  privado.estabelecimento_publico(v.estabelecimento_id),
                 'inicio_em',        v.inicio_em,
                 'fim_em',           v.fim_em,
                 'local',            v.local,
                 'distancia_km',     round((extensions.st_distance(v.ponto, v_ref) / 1000)::numeric, 2),
                 'valor_centavos',   v.valor_centavos,
                 'posicoes_abertas', privado.posicoes_candidataveis(v.id, v_agora),
                 'inclusos',         privado.inclusos_em_json(v.*),
                 'modo',             v.modo) as item,
               row_number() over (order by v.ponto operator(extensions.<->) v_ref, v.id) as ordem
          from public.vaga v
          join public.funcao f  on f.id = v.funcao_id
          join public.usuario u on u.id = v.publicado_por
         where v.estado = 'publicada'
           -- 0.2.19: vaga que já começou sai da lista, salvo a que tem posição reaberta
           -- por atraso dentro do prazo — o mesmo instante em que `candidatar` recusa.
           and (v.inicio_em > v_agora or privado.posicoes_candidataveis(v.id, v_agora) > 0)
           -- Diretriz 2.1: as duas populações dividem o banco e não se enxergam.
           and u.demonstracao = v_demo
           -- RF26. O bloqueio é com a pessoa, e alcança todas as casas dela.
           and not privado.bloqueado_com_estabelecimento(v_uid, v.estabelecimento_id)
           and (vagas_abertas.funcao_id is null or v.funcao_id = vagas_abertas.funcao_id)
           -- O dia é o de São Paulo. Às 23:30 de uma sexta em Brasília já é sábado em
           -- UTC, e comparar em UTC esconderia o turno de sexta à noite de quem
           -- filtrasse por sexta — que é o turno mais comum do produto.
           and (vagas_abertas.data is null
                or (v.inicio_em at time zone 'America/Sao_Paulo')::date = vagas_abertas.data)
           -- A distância **ordena** sempre; ela só filtra quando o profissional pede
           -- (B07: o limite de 15 km é da notificação, não da busca).
           and (v_raio is null or extensions.st_dwithin(v.ponto, v_ref, v_raio))
         order by v.ponto operator(extensions.<->) v_ref, v.id
         limit vagas_abertas.limite offset vagas_abertas.deslocamento
      ) t
  ), '[]'::jsonb);
end $$;

comment on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int) is
  'Vagas abertas ordenadas por distância até o ponto informado, ou até o ponto base (RF07, RN05). A ordem não pode ser comprada (RN06); vaga de estabelecimento com bloqueio some (RF26). Vaga já começada some, salvo a com posição reaberta por atraso antes de fim − 1 h (contrato 0.2.19).';

revoke execute on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int)
  from public, anon;
grant execute on function public.vagas_abertas(numeric, numeric, uuid, date, numeric, int, int)
  to authenticated;

create or replace function public.detalhe_vaga(vaga_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid  uuid := (select auth.uid());
  v_ref  extensions.geography;
  v_demo boolean;
  v      public.vaga%rowtype;
  v_f    public.funcao%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('profissional');

  if detalhe_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  v_demo := privado.conta_de_demonstracao();

  select * into v from public.vaga g where g.id = detalhe_vaga.vaga_id;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if not exists (select 1 from public.usuario u
                  where u.id = v.publicado_por and u.demonstracao = v_demo) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if privado.bloqueado_com_estabelecimento(v_uid, v.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  select * into v_f from public.funcao f where f.id = v.funcao_id;

  select p.ponto_base into v_ref from public.profissional p where p.usuario_id = v_uid;

  return jsonb_build_object(
    'id',                v.id,
    'estabelecimento',   privado.estabelecimento_publico(v.estabelecimento_id),
    'funcao',            privado.funcao_em_json(v_f.*),
    'inicio_em',         v.inicio_em,
    'fim_em',            v.fim_em,
    'local',             v.local,
    'ponto',             privado.ponto_em_json(v.ponto),
    'distancia_km',      case when v_ref is null then null
                              else round((extensions.st_distance(v.ponto, v_ref) / 1000)::numeric, 2) end,
    'valor_centavos',    v.valor_centavos,
    'posicoes',          v.posicoes,
    'posicoes_abertas',  privado.posicoes_candidataveis(v.id, privado.agora()),
    'inclusos',          privado.inclusos_em_json(v.*),
    'responsavel_local', v.responsavel_local,
    'traje',             v.traje,
    'participa_rateio',  v.participa_rateio,
    'observacoes',       v.observacoes,
    'modo',              v.modo,
    'estado',            v.estado,
    'publicado_em',      v.publicado_em);
end $$;

comment on function public.detalhe_vaga(uuid) is
  'Detalhe da vaga para quem ainda não se candidatou (RF04, UC03). Sem documento e sem contato (RN10). Vaga escondida por bloqueio ou por demonstração responde 404, e não 403: o 403 confirmaria que ela existe. Depois do início, posicoes_abertas conta só as reabertas por atraso dentro do prazo (contrato 0.2.19).';

revoke execute on function public.detalhe_vaga(uuid) from public, anon;
grant execute on function public.detalhe_vaga(uuid) to authenticated;
