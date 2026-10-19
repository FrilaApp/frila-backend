-- Teto e agrupamento de notificações de vaga (RN23). Cartão ee3MT3fH.
--
-- US07 · RN23 · RF06 · RNF03.
--
-- No máximo uma notificação de vaga a cada 30 minutos por profissional. O despacho que
-- chega dentro da janela é gravado e **espera**: `despacho.notificacao_id` fica nulo,
-- como a Modelagem previu desde a primeira migração. No fim da janela, o que esperou vira
-- uma notificação só — `vaga`, se sobrou uma, ou `vagas_agrupadas`, se sobraram duas ou
-- mais ("3 vagas novas perto de você"). A vaga que começa em menos de 2 horas fura o
-- agrupamento: sai na hora, sozinha, e conta no teto, que recomeça a partir dela.
--
-- O teto é genérico por tipo: quem conta nele é a lista `privado.tipo_no_teto`, e não um
-- `if` espalhado pelo código. Lembrete, confirmação, aviso de turno e o que os próximos
-- cartões criarem por `privado.notificar` passam direto, porque não estão na lista.
--
-- A janela e a antecedência da urgência moram em `privado.parametro_notificacao`.

-- ── 1. A configuração ─────────────────────────────────────────────────────────

create table privado.parametro_notificacao (
  chave      text primary key,
  valor      interval not null,
  finalidade text not null,
  constraint parametro_positivo    check (valor > interval '0'),
  constraint finalidade_declarada  check (length(btrim(finalidade)) > 0)
);

comment on table privado.parametro_notificacao is
  'Parâmetros do teto de notificações (RN23). Mudam sem migração de código: o despacho e o agendador leem daqui a cada decisão.';

insert into privado.parametro_notificacao (chave, valor, finalidade) values
  ('teto_janela', interval '30 minutes',
   'RN23: intervalo mínimo entre duas notificações de vaga não urgentes para o mesmo profissional.'),
  ('urgente_antecedencia', interval '2 hours',
   'RN23: a vaga que começa em menos que isto fura o agrupamento e sai na hora (e conta no teto).');

create table privado.tipo_no_teto (
  tipo       public.tipo_notificacao primary key,
  finalidade text not null,
  constraint finalidade_declarada check (length(btrim(finalidade)) > 0)
);

comment on table privado.tipo_no_teto is
  'Os tipos de notificação que contam no teto da RN23. O que não está aqui (lembretes, avisos de turno, avisos à casa) nunca é segurado nem segura ninguém.';

insert into privado.tipo_no_teto (tipo, finalidade) values
  ('vaga',            'RN23: a notificação de uma vaga para o profissional.'),
  ('vagas_agrupadas', 'RN23: as vagas que esperaram a janela, numa notificação só.');

revoke all on table privado.parametro_notificacao, privado.tipo_no_teto
  from public, anon, authenticated;

create or replace function privado.parametro_de_notificacao(p_chave text)
returns interval
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v interval;
begin
  select p.valor into v from privado.parametro_notificacao p where p.chave = p_chave;
  if v is null then
    -- Sem o parâmetro, o teto não pode virar "sem teto" em silêncio.
    raise exception 'parametro_ausente' using errcode = 'P0002', detail = p_chave;
  end if;
  return v;
end $$;

comment on function privado.parametro_de_notificacao(text) is
  'Lê um parâmetro do teto de notificações (RN23). Parâmetro ausente é erro.';

revoke execute on function privado.parametro_de_notificacao(text) from public, anon, authenticated;
grant  execute on function privado.parametro_de_notificacao(text) to service_role;

-- ── 2. As colunas ─────────────────────────────────────────────────────────────

alter table public.notificacao
  add column esperou_teto boolean not null default false;

comment on column public.notificacao.esperou_teto is
  'A notificação saiu no fim da janela do teto (RN23), e não na hora. A RNF03 (30 s entre publicar e enviar) mede só as que não esperaram.';

alter table public.despacho
  add column reaberta boolean not null default false;

comment on column public.despacho.reaberta is
  'O despacho nasceu da reabertura de uma posição. Guardado para o push que sai depois do teto continuar dizendo que a vaga foi reaberta.';

-- `despacho` é registro (RNF13): não se reescreve nem se apaga. A única escrita depois do
-- nascimento é a que a Modelagem previu desde o início — o despacho que esperou o teto
-- ganha a notificação que o levou, uma vez só. Preenchido, o `notificacao_id` não muda
-- mais: repontar um despacho para outra notificação reescreveria quem foi avisado de quê.
create or replace function privado.despacho_imutavel()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if current_setting('privado.retencao', true) = 'on' then
    return case when TG_OP = 'DELETE' then OLD else NEW end;
  end if;

  if TG_OP = 'DELETE' then
    raise exception 'registro de despacho nao pode ser apagado'
      using errcode = 'restrict_violation';
  end if;

  if OLD.notificacao_id is not null
     and NEW.notificacao_id is distinct from OLD.notificacao_id then
    raise exception 'despacho ja tem notificacao'
      using errcode = 'restrict_violation';
  end if;

  if (to_jsonb(OLD) - 'notificacao_id') is distinct from (to_jsonb(NEW) - 'notificacao_id') then
    raise exception 'registro de despacho so muda em notificacao_id, uma vez'
      using errcode = 'restrict_violation';
  end if;

  return NEW;
end $$;

comment on function privado.despacho_imutavel() is
  'Gatilho BEFORE de despacho (RNF13, RN23): recusa DELETE e qualquer UPDATE, exceto preencher notificacao_id nulo — o despacho que esperou o teto recebe a notificação que o levou, uma vez. A sessão com privado.retencao = on passa (RF25).';

revoke all on function privado.despacho_imutavel() from public, anon, authenticated;

drop trigger despacho_imutavel on public.despacho;
create trigger despacho_imutavel before update or delete on public.despacho
  for each row execute function privado.despacho_imutavel();

-- O agendador procura, a cada minuto, quem tem despacho esperando o teto.
create index despacho_esperando_teto on public.despacho (profissional_id)
  where notificacao_id is null;

-- ── 3. A decisão do teto ──────────────────────────────────────────────────────

-- Quando saiu a última notificação que conta no teto para a conta. `enviada_em` nasce no
-- enfileiramento (`privado.agora()`) e é regravada com o instante real do envio.
create or replace function privado.ultima_no_teto(p_usuario uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select max(n.enviada_em)
    from public.notificacao n
   where n.usuario_id = p_usuario
     and n.tipo in (select t.tipo from privado.tipo_no_teto t);
$$;

comment on function privado.ultima_no_teto(uuid) is
  'Instante da última notificação da conta cujo tipo conta no teto da RN23 (privado.tipo_no_teto).';

revoke execute on function privado.ultima_no_teto(uuid) from public, anon, authenticated;
grant  execute on function privado.ultima_no_teto(uuid) to service_role;

-- A trava por profissional. Dois executores do despacho (o pós-commit e o pg_cron, ou
-- duas vagas publicadas juntas) decidindo o teto da mesma pessoa ao mesmo tempo mandariam
-- duas. A trava vale até o fim da transação.
create or replace function privado.travar_teto(p_profissional uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('rn23:' || p_profissional::text, 0));
$$;

comment on function privado.travar_teto(uuid) is
  'Trava transacional por profissional para a decisão do teto (RN23): dois executores do despacho não decidem o mesmo profissional ao mesmo tempo.';

revoke execute on function privado.travar_teto(uuid) from public, anon, authenticated;
grant  execute on function privado.travar_teto(uuid) to service_role;

-- Libera o que o profissional tem esperando, se a janela dele já fechou. Uma vaga vira
-- `vaga`; duas ou mais viram `vagas_agrupadas`. Vaga que deixou de estar publicada ou já
-- começou enquanto esperava não é notificada. Devolve a notificação criada, ou nulo.
create or replace function privado.liberar_teto_do_profissional(p_profissional uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_usuario uuid;
  v_ultima  timestamptz;
  v_ids     uuid[];
  v_vagas   uuid[];
  v_ref     uuid;
  v_reab    boolean;
  v_esperou boolean;
  v_payload jsonb;
  v_notif   uuid;
begin
  perform privado.travar_teto(p_profissional);

  select p.usuario_id into v_usuario from public.profissional p where p.id = p_profissional;
  if v_usuario is null then
    return null;
  end if;

  v_ultima := privado.ultima_no_teto(v_usuario);
  if v_ultima is not null
     and v_ultima > v_agora - privado.parametro_de_notificacao('teto_janela') then
    return null;
  end if;

  select array_agg(d.id order by d.criado_em, d.id),
         array_agg(d.vaga_id order by d.criado_em, d.id),
         bool_or(d.reaberta),
         bool_or(d.criado_em < v_agora)
    into v_ids, v_vagas, v_reab, v_esperou
    from public.despacho d
    join public.vaga v on v.id = d.vaga_id
   where d.profissional_id = p_profissional
     and d.notificacao_id is null
     and v.estado = 'publicada'
     and v.inicio_em > v_agora;

  if v_ids is null then
    return null;
  end if;

  if cardinality(v_ids) = 1 then
    v_payload := jsonb_build_object('vaga_id', v_vagas[1]);
    if v_reab then
      v_payload := v_payload || jsonb_build_object('reaberta', true);
    end if;
    v_notif := privado.notificar(v_usuario, 'vaga', v_vagas[1], v_payload);
  else
    -- A referência é a vaga que começa por último: a agrupada só expira (não é mais
    -- enviada) quando todas as vagas dela já começaram. O toque abre a aba de vagas, e o
    -- payload leva só o tipo.
    select v.id into v_ref from public.vaga v
     where v.id = any (v_vagas)
     order by v.inicio_em desc, v.id
     limit 1;
    v_notif := privado.notificar(v_usuario, 'vagas_agrupadas', v_ref, '{}'::jsonb);
  end if;

  update public.notificacao n
     set esperou_teto = v_esperou or cardinality(v_ids) > 1
   where n.id = v_notif;

  update public.despacho d
     set notificacao_id = v_notif
   where d.id = any (v_ids)
     and d.notificacao_id is null;

  return v_notif;
end $$;

comment on function privado.liberar_teto_do_profissional(uuid) is
  'RN23: se a janela do teto do profissional fechou, transforma os despachos que esperavam numa notificação (vaga, ou vagas_agrupadas com dois ou mais). Sob trava por profissional.';

revoke execute on function privado.liberar_teto_do_profissional(uuid) from public, anon, authenticated;
grant  execute on function privado.liberar_teto_do_profissional(uuid) to service_role;

-- O agendador: todo profissional com despacho esperando. A ordem por id é só a ordem de
-- aquisição das travas, a mesma do despacho, para as duas nunca se esperarem em ciclo —
-- não decide quem recebe (RN06).
create or replace function privado.liberar_teto(p_limite int default 1000)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora timestamptz := privado.agora();
  v_prof  uuid;
  v_n     int := 0;
begin
  for v_prof in
    select distinct d.profissional_id
      from public.despacho d
      join public.vaga v on v.id = d.vaga_id
     where d.notificacao_id is null
       and v.estado = 'publicada'
       and v.inicio_em > v_agora
     order by d.profissional_id
     limit p_limite
  loop
    if privado.liberar_teto_do_profissional(v_prof) is not null then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;

comment on function privado.liberar_teto(int) is
  'RN23: libera, no fim da janela, as notificações de quem tem despacho esperando o teto. Rodada pelo pg_cron a cada minuto. Devolve quantas notificações criou.';

revoke execute on function privado.liberar_teto(int) from public, anon, authenticated;
grant  execute on function privado.liberar_teto(int) to service_role;

-- ── 4. O despacho passa pelo teto ─────────────────────────────────────────────

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
  v_reaberta          boolean := coalesce(p_motivo = 'reabertura', false);
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
  -- reabertura em cima da hora é o caso que mais precisa sair na hora.
  v_urgente := v.inicio_em - v_agora < privado.parametro_de_notificacao('urgente_antecedencia');

  foreach v_prof_id in array v_elegiveis loop
    perform privado.travar_teto(v_prof_id);

    insert into public.despacho (vaga_id, profissional_id, notificacao_id, criado_em, reaberta)
    values (v.id, v_prof_id, null, v_agora, v_reaberta)
    on conflict (vaga_id, profissional_id) do nothing
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

      -- A marca de envio de `vaga` em (tipo, referencia_id, usuario_id) mantém a
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
  'Cria o despacho de cada elegível de uma vaga e passa pelo teto da RN23: sai na hora se a janela do profissional fechou ou se a vaga começa em menos de 2 h; senão espera o agendador (liberar_teto). Se não há elegível, envia vaga_sem_elegiveis.';

revoke execute on function privado.despachar_vaga(uuid, text, uuid) from public, anon, authenticated;

-- ── 5. O contexto do texto do push ────────────────────────────────────────────

-- O que a Edge Function `enviar-push` interpola no texto, lido no envio. Hoje, só a
-- contagem da agrupada. Nada de dado pessoal (RN15): a contagem é de vagas.
create or replace function privado.contexto_do_push(p_notificacao_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tipo public.tipo_notificacao;
  v_qtd  int;
begin
  select n.tipo into v_tipo from public.notificacao n where n.id = p_notificacao_id;

  if v_tipo = 'vagas_agrupadas' then
    select count(*)::int into v_qtd from public.despacho d
     where d.notificacao_id = p_notificacao_id;
    return jsonb_build_object('quantidade', v_qtd);
  end if;

  return '{}'::jsonb;
end $$;

comment on function privado.contexto_do_push(uuid) is
  'Variáveis do texto do push lidas no envio (interpolação pela Edge Function enviar-push). Em vagas_agrupadas, a quantidade de vagas. Sem dado pessoal (RN15).';

revoke execute on function privado.contexto_do_push(uuid) from public, anon, authenticated;
grant  execute on function privado.contexto_do_push(uuid) to service_role;

-- ── 6. O agendador ────────────────────────────────────────────────────────────

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('liberar_teto')
      where exists (select 1 from cron.job where jobname = 'liberar_teto');
    perform cron.schedule(
      'liberar_teto',
      '* * * * *',
      'select privado.liberar_teto()'
    );
  end if;
end $$;
