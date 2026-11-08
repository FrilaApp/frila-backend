-- Migração: 20261108110000_lgpd_j6_coleta_registro_acesso.sql
-- Escopo: LGPD-J6 R11 (cartão HAWhzOJ4). O #429 criou privado.registro_acesso e a limpeza de 6 meses,
-- mas nada gravava nela. Esta migração liga a coleta: IP, data e hora de cada login e de cada renovação
-- de sessão, copiados de auth.sessions por um gatilho (Marco Civil, Lei 12.965/2014, art. 5º VIII e art. 15).
--
-- Por que um gatilho em auth.sessions (desenho medido em orquestracao/retornos/B-T2-registro-acessos-desenho.md):
--   · auth.audit_log_entries grava ip_address VAZIO no login e na renovação (medido; doc oficial confirma);
--   · auth.sessions.ip guarda só o ÚLTIMO IP da sessão, sobrescrito a cada renovação: um job que copia perde
--     o histórico, e só o gatilho vê cada valor;
--   · RPC de leitura e db_pre_request não gravam em GET nem em função stable (405/25006, medido).
--
-- Três travas, por ordem do Orquestrador e da Central (08/11/2026):
--   1. O gatilho NUNCA bloqueia login nem renovação. Ele roda dentro da transação do Auth: um erro aqui seria
--      HTTP 500 no /verify (medido com a FK antiga). Todo erro, inclusive o da contagem, é engolido e vira um
--      contador por hora, sem dado pessoal, que privado.verificar_saude lê e transforma em alerta.
--   2. A coleta nasce DESLIGADA (privado.registro_acesso_coleta). Só liga depois de o teste com
--      X-Forwarded-For forjado no Prod provar que auth.sessions.ip é o IP da borda, e não o 1º XFF que o
--      cliente controla (no local, o Auth grava o 1º XFF, medido). Se o Prod gravar o forjado, a fonte do IP
--      muda de desenho e esta chave fica desligada.
--   3. user_agent NÃO é guardado (jurídico, frila-docs #182, ROPA linha 24: o registro leva só conta, IP,
--      data e hora; Marco Civil art. 5º VIII; LGPD art. 6º III). A coluna fica, vazia e travada por CHECK, e
--      privado.registrar_acesso passa a ignorar p_user_agent (assinatura mantida: nenhum chamador muda).
--
-- A FK usuario_id → public.usuario sai: quem acabou de entrar ainda não tem public.usuario (criar_conta vem
-- depois do /verify), e o registro tem de durar 6 meses mesmo depois da exclusão da conta (LGPD art. 16, I;
-- jurídico, frila-docs #182). Precedente: privado.escrita_por_conta (20260929220000).
--
-- privado.executar_retencao_diaria NÃO muda aqui (o #436 a reescreve): o laço de lotes fica dentro de
-- privado.limpar_registros_acesso, com a mesma assinatura e a mesma chamada.

-- A migração trava auth.sessions (create trigger) e public.usuario (drop da FK). Sem teto, uma transação longa
-- nessas tabelas deixaria o login e toda RPC que lê usuario na fila atrás dela: com 2 s, a migração desiste e a
-- entrega se repete (Lince no #441, B2, medido em PG17).
select set_config('lock_timeout', '2s', true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. A tabela: sem FK, sem user_agent, com a base legal no comentário
-- ─────────────────────────────────────────────────────────────────────────────
alter table privado.registro_acesso drop constraint if exists registro_acesso_usuario_id_fkey;

update privado.registro_acesso set user_agent = null where user_agent is not null;
alter table privado.registro_acesso
  add constraint registro_acesso_sem_user_agent check (user_agent is null);

create or replace function privado.registrar_acesso(
  p_usuario_id uuid,
  p_ip inet,
  p_recurso text default null,
  p_user_agent text default null
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  if p_ip is null then
    return null;
  end if;

  -- p_user_agent é ignorado: o registro não guarda user_agent (frila-docs #182, ROPA linha 24).
  -- Quem ainda o manda é avisado, sem o valor no aviso (RN15).
  if p_user_agent is not null then
    raise notice 'privado.registrar_acesso: p_user_agent ignorado, o registro não guarda user_agent';
  end if;

  insert into privado.registro_acesso (usuario_id, ip, acessado_em, recurso)
  values (p_usuario_id, p_ip, privado.agora(), p_recurso)
  returning id into v_id;

  return v_id;
end $$;

comment on function privado.registrar_acesso(uuid, inet, text, text) is
  'Registra acesso a aplicação de internet com IP e data e hora (Marco Civil art. 15), para gravação manual pelo service_role. p_user_agent é ignorado: o registro não guarda user_agent (frila-docs #182). A coleta automática é o gatilho registrar_acesso em auth.sessions.';
revoke all on function privado.registrar_acesso(uuid, inet, text, text) from public, anon, authenticated;
grant execute on function privado.registrar_acesso(uuid, inet, text, text) to service_role;

comment on table privado.registro_acesso is
  'Registros de acesso a aplicação de internet (conta, IP, data e hora; sem user_agent; Marco Civil, Lei 12.965/2014, art. 5º VIII e art. 15), sob sigilo, por 6 meses contados do acesso, inclusive depois da exclusão da conta (privado.limpar_registros_acesso; LGPD art. 16, I). Base legal: LGPD art. 7º II (cumprimento do art. 15 do Marco Civil) e, enquanto o controlador constar como pessoa física no ROPA, também art. 7º IX (legítimo interesse: segurança da conta e apuração de fraude). Gravado pelo gatilho registrar_acesso em auth.sessions (login e renovação), só com privado.registro_acesso_coleta ligada. Acesso só do service_role; entrega a terceiro só por ordem judicial.';
comment on column privado.registro_acesso.usuario_id is
  'Conta (auth.users.id) dona da sessão. Sem chave estrangeira: o primeiro login vem antes de criar_conta, e o registro dura 6 meses mesmo depois da exclusão da conta (LGPD art. 16, I).';
comment on column privado.registro_acesso.ip is
  'IP da sessão como o Auth o gravou em auth.sessions.ip. Só vale como registro se for o IP da borda: a coleta só liga depois de o Prod provar isso com X-Forwarded-For forjado.';
comment on column privado.registro_acesso.recurso is
  'login (sessão criada) ou renovacao (refreshed_at ou ip mudou). Gravações manuais por privado.registrar_acesso podem usar outro rótulo.';
comment on column privado.registro_acesso.user_agent is
  'Sempre nulo (CHECK registro_acesso_sem_user_agent): o registro não guarda user_agent (jurídico, frila-docs #182; Marco Civil art. 5º VIII; LGPD art. 6º III).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. A chave da coleta (nasce desligada)
-- ─────────────────────────────────────────────────────────────────────────────
create table privado.registro_acesso_coleta (
  unica       boolean primary key default true check (unica),
  ligada      boolean not null default false,
  alterada_em timestamptz not null default privado.agora()
);
insert into privado.registro_acesso_coleta (unica, ligada) values (true, false);

alter table privado.registro_acesso_coleta enable row level security;
revoke all on table privado.registro_acesso_coleta from public, anon, authenticated;

comment on table privado.registro_acesso_coleta is
  'Chave da coleta de registros de acesso (uma linha só). Nasce desligada e só liga depois de o Prod provar que auth.sessions.ip é o IP da borda (Central, 08/11/2026). alterada_em é quando a chave mudou: o alerta registro_acesso_parado só olha renovações posteriores a ela. Não guarda dado pessoal.';

create or replace function privado.definir_coleta_registro_acesso(p_ligada boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_ligada is null then
    raise exception 'p_ligada não pode ser nulo' using errcode = '22004';
  end if;
  update privado.registro_acesso_coleta
     set ligada = p_ligada,
         alterada_em = privado.agora()
   where unica;
  return (select jsonb_build_object('ligada', c.ligada, 'alterada_em', c.alterada_em)
            from privado.registro_acesso_coleta c);
end $$;

comment on function privado.definir_coleta_registro_acesso(boolean) is
  'Liga ou desliga a coleta de registros de acesso e carimba alterada_em. Operação manual do Prod: só depois do teste de X-Forwarded-For forjado (Central, 08/11/2026).';
revoke all on function privado.definir_coleta_registro_acesso(boolean) from public, anon, authenticated;
grant execute on function privado.definir_coleta_registro_acesso(boolean) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. O contador de falhas (por hora, sem dado pessoal)
-- ─────────────────────────────────────────────────────────────────────────────
create table privado.registro_acesso_falha (
  hora            timestamptz primary key,
  falhas          integer not null,
  ultimo_sqlstate text not null
);

alter table privado.registro_acesso_falha enable row level security;
revoke all on table privado.registro_acesso_falha from public, anon, authenticated;

comment on table privado.registro_acesso_falha is
  'Falhas engolidas pelo gatilho registrar_acesso, por hora: quantas e o SQLSTATE da última. Nunca a mensagem, que pode trazer IP ou id (RN15). Lida por privado.verificar_saude (alerta registro_acesso_falhou); linhas com mais de 30 dias saem em privado.limpar_registros_acesso.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. O gatilho em auth.sessions
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.registrar_acesso_da_sessao()
returns trigger
language plpgsql
security definer
set search_path = ''
set lock_timeout = '200ms'
as $$
begin
  begin
    if new.ip is null
       or (tg_op = 'UPDATE'
           and new.refreshed_at is not distinct from old.refreshed_at
           and new.ip is not distinct from old.ip)
       or not coalesce((select c.ligada from privado.registro_acesso_coleta c where c.unica), false) then
      return null;
    end if;

    insert into privado.registro_acesso (usuario_id, ip, acessado_em, recurso)
    values (new.user_id, new.ip, privado.agora(),
            case when tg_op = 'INSERT' then 'login' else 'renovacao' end);
  exception when others or query_canceled then
    -- Nunca derruba o login: conta a falha e segue. A contagem também é engolida.
    begin
      insert into privado.registro_acesso_falha as f (hora, falhas, ultimo_sqlstate)
      values (date_trunc('hour', privado.agora()), 1, sqlstate)
      on conflict (hora) do update
        set falhas = f.falhas + 1,
            ultimo_sqlstate = excluded.ultimo_sqlstate;
    exception when others or query_canceled then
      null;
    end;
  end;
  return null;
end $$;

comment on function privado.registrar_acesso_da_sessao() is
  'Gatilho de auth.sessions (after insert or update, sem lista de colunas, para não prender o esquema do Auth): grava IP, data e hora do login (insert) e de cada renovação (refreshed_at ou ip mudou, comparando OLD e NEW) em privado.registro_acesso, sem user_agent, só com privado.registro_acesso_coleta ligada. Nunca bloqueia o Auth: qualquer erro, inclusive o da contagem, é engolido e contado em privado.registro_acesso_falha. lock_timeout de 200 ms para não segurar o login atrás de uma trava.';
revoke all on function privado.registrar_acesso_da_sessao() from public, anon, authenticated;

-- Sem lista de colunas, de propósito: "update of refreshed_at, ip" criaria dependência dessas colunas, e uma
-- migração futura do Auth que mude o tipo de refreshed_at ou remova ip falharia por causa deste gatilho (Lince
-- no #441, B1). A função já filtra pela comparação de OLD e NEW; se a coluna sumir, a leitura de NEW falha
-- dentro do bloco protegido e é contada.
drop trigger if exists registrar_acesso on auth.sessions;
create trigger registrar_acesso
  after insert or update on auth.sessions
  for each row execute function privado.registrar_acesso_da_sessao();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Limpeza de 6 meses em laço de lotes (mesma assinatura e mesma chamada)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.limpar_registros_acesso(
  p_meses integer default 6,
  p_limite integer default 1000
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite_data timestamptz;
  v_total integer := 0;
  v_lote integer;
  v_lotes integer := 0;
  -- Teto por execução: 100 lotes (100 mil linhas com o lote padrão). O que sobrar sai na rodada seguinte.
  c_teto_lotes constant integer := 100;
begin
  -- Salvaguarda: teto mínimo de 6 meses para impedir encurtamento indevido
  if p_meses is null or p_meses < 6 then
    p_meses := 6;
  end if;
  if p_limite is null or p_limite < 1 then
    p_limite := 1000;
  end if;

  -- Calendário real com base em meses (Marco Civil, art. 15)
  v_limite_data := privado.agora() - (p_meses || ' months')::interval;

  -- Lotes determinísticos com SKIP LOCKED, repetidos até esvaziar ou bater no teto
  loop
    with registros_a_remover as (
      select r.id
        from privado.registro_acesso r
       where r.acessado_em <= v_limite_data
       order by r.acessado_em asc
       limit p_limite
       for update skip locked
    )
    delete from privado.registro_acesso r
     using registros_a_remover rar
     where r.id = rar.id;

    get diagnostics v_lote = row_count;
    v_total := v_total + v_lote;
    v_lotes := v_lotes + 1;
    exit when v_lote < p_limite or v_lotes >= c_teto_lotes;
  end loop;

  -- Higiene do contador de falhas (sem dado pessoal): 30 dias bastam para o alerta de 24 h
  delete from privado.registro_acesso_falha f where f.hora < privado.agora() - interval '30 days';

  return v_total;
end $$;

comment on function privado.limpar_registros_acesso(integer, integer) is
  'Expurga registros de acesso com mais de 6 meses (Marco Civil art. 15) em lotes com SKIP LOCKED, repetidos até esvaziar, com teto de 100 lotes por execução; limpa também o contador de falhas com mais de 30 dias.';

revoke all on function privado.limpar_registros_acesso(integer, integer) from public, anon, authenticated;
grant execute on function privado.limpar_registros_acesso(integer, integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. privado.verificar_saude: dois alertas novos (item 11)
--    Corpo igual ao de 20261020100000 (conferido por md5 do prosrc no banco local), mais o item 11.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.verificar_saude()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_alertas               int := 0;
  v_idade_despacho        interval;
  v_idade_email           interval;
  v_falhas_cron           int;
  v_notif_falhas          int;
  v_fcm_config_falhas     int;
  v_despachos_travados    int;
  v_falhas_exec           int;
  v_moderacoes_vencidas   int;
  v_contestacoes_vencidas int;
  v_tentativas            int;
  v_pgnet_transporte_falhas int;
  v_pgnet_recusadas_falhas  int;
  v_agora                 timestamptz := privado.agora();
  v_teto_janela           interval;
  v_falhas_registro       int;
  v_coleta                privado.registro_acesso_coleta%rowtype;
  v_desde                 timestamptz;
  v_sessoes_sem_registro  int;
begin
  -- 1. Job de despacho ativo (RNF12)
  if not exists (
    select 1 from cron.job
     where jobname = 'reprocessar_despacho' and active = true
  ) then
    if privado.emitir_alerta('job_despacho_parado', 1) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 2. Idade da mensagem mais velha nas filas pgmq (teto de 15 minutos)
  if exists (select 1 from pg_tables where schemaname = 'pgmq' and tablename = 'q_despacho') then
    select v_agora - min(enqueued_at) into v_idade_despacho from pgmq.q_despacho;
    if v_idade_despacho is not null and v_idade_despacho > interval '15 minutes' then
      if privado.emitir_alerta('fila_despacho_antiga', extract(epoch from v_idade_despacho)::numeric) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  end if;

  if exists (select 1 from pg_tables where schemaname = 'pgmq' and tablename = 'q_email') then
    select v_agora - min(enqueued_at) into v_idade_email from pgmq.q_email;
    if v_idade_email is not null and v_idade_email > interval '15 minutes' then
      if privado.emitir_alerta('fila_email_antiga', extract(epoch from v_idade_email)::numeric) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  end if;

  -- 3. Falhas recentes em cron.job_run_details (últimos 15 minutos)
  if exists (select 1 from pg_tables where schemaname = 'cron' and tablename = 'job_run_details') then
    select count(*) into v_falhas_cron
      from cron.job_run_details
     where status = 'failed'
       and end_time > v_agora - interval '15 minutes';
    if v_falhas_cron > 0 then
      if privado.emitir_alerta('job_cron_falhou', v_falhas_cron) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  end if;

  -- 4. Notificações com estado 'falhou' na última hora
  select count(*) into v_notif_falhas
    from public.notificacao
   where estado_entrega = 'falhou'
     and enviada_em > v_agora - interval '1 hour';
  if v_notif_falhas > 0 then
    if privado.emitir_alerta('notificacao_push_falhou', v_notif_falhas) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 4b. Falha de configuração do FCM (projeto inexistente ou URL incorreta):
  -- Notificações que falharam com motivo 'NOT_FOUND' nos últimos 15 minutos (sugestão do Oráculo).
  select count(*) into v_fcm_config_falhas
    from public.notificacao
   where motivo_falha = 'NOT_FOUND'
     and estado_entrega = 'falhou'
     and enviada_em > v_agora - interval '15 minutes';
  if v_fcm_config_falhas > 0 then
    if privado.emitir_alerta('fcm_configuracao_suspeita', v_fcm_config_falhas) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 5. Despachos esperando além do teto de RN23
  v_teto_janela := coalesce(privado.parametro_de_notificacao('teto_janela'), interval '30 minutes');
  select count(*) into v_despachos_travados
    from public.despacho d
    join public.vaga v on v.id = d.vaga_id
   where d.notificacao_id is null
     and v.estado = 'publicada'
     and v.inicio_em > v_agora
     and d.criado_em < v_agora - (v_teto_janela + interval '15 minutes');
  if v_despachos_travados > 0 then
    if privado.emitir_alerta('despacho_esperando_alem_do_teto', v_despachos_travados) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 6. Falhas de execução registradas por Edge Functions nos últimos 15 minutos
  select count(*) into v_falhas_exec
    from privado.falha_execucao
   where criada_em > v_agora - interval '15 minutes';
  if v_falhas_exec > 0 then
    if privado.emitir_alerta('falha_execucao_edge_function', v_falhas_exec) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 7. Denúncias abertas há mais de 24h sem resolução (Diretriz 1.2 da App Store, Item 21)
  select count(*) into v_moderacoes_vencidas
    from public.ocorrencia
   where tipo = 'denuncia'
     and resolvido_em is null
     and criada_em < v_agora - interval '24 hours';
  if v_moderacoes_vencidas > 0 then
    if privado.emitir_alerta('moderacao_vencida', v_moderacoes_vencidas) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 8. Contestações de suspensão abertas há mais de 5 dias úteis sem resolução (RN13, Item 21b)
  select count(*) into v_contestacoes_vencidas
    from public.ocorrencia
   where tipo = 'contestacao'
     and resolvido_em is null
     and (v_agora at time zone 'America/Sao_Paulo')::date > privado.prazo_de_resposta(criada_em);
  if v_contestacoes_vencidas > 0 then
    if privado.emitir_alerta('contestacao_vencida', v_contestacoes_vencidas) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 9. Falhas assíncronas do pg_net em net._http_response nos últimos 15 min (Item 22)
  begin
    if (
      exists (select 1 from privado.ambiente where eh_teste)
      and coalesce(current_setting('frila.simular_sem_pgnet', true), 'off') = 'on'
    ) then
      if privado.emitir_alerta('pgnet_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
    elsif exists (select 1 from pg_tables where schemaname = 'net' and tablename = '_http_response')
       and has_table_privilege('postgres', 'net._http_response', 'select') then
      if (
        exists (select 1 from privado.ambiente where eh_teste)
        and coalesce(current_setting('frila.simular_excecao_pgnet', true), 'off') = 'on'
      ) then
        raise exception 'simulacao de erro pgnet em tempo de execucao';
      end if;

      execute $dyn$
        select count(*)
          from net._http_response
         where created > $1 - interval '15 minutes'
           and (
             timed_out = true
             or error_msg is not null
             or status_code >= 500
           )
      $dyn$ into v_pgnet_transporte_falhas using v_agora;

      if v_pgnet_transporte_falhas >= 3 then
        if privado.emitir_alerta('pgnet_falha_transporte', v_pgnet_transporte_falhas) then
          v_alertas := v_alertas + 1;
        end if;
      end if;

      execute $dyn$
        select count(*)
          from net._http_response
         where created > $1 - interval '15 minutes'
           and status_code in (401, 403, 404)
      $dyn$ into v_pgnet_recusadas_falhas using v_agora;

      if v_pgnet_recusadas_falhas > 0 then
        if privado.emitir_alerta('pgnet_resposta_recusada', v_pgnet_recusadas_falhas) then
          v_alertas := v_alertas + 1;
        end if;
      end if;
    else
      if privado.emitir_alerta('pgnet_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
    end if;
  exception
    when others then
      if privado.emitir_alerta('pgnet_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
  end;

  -- 10. Tentativas recusadas de demonstração nos últimos 15 min (demonstracao_sob_ataque)
  select count(*) into v_tentativas
    from public.entrada_demonstracao
   where aceita = false
     and em >= v_agora - interval '15 minutes';

  if v_tentativas >= 10 then
    if privado.emitir_alerta(
      'demonstracao_sob_ataque',
      jsonb_build_object(
        'tentativas_recusadas_15min', v_tentativas,
        'teto', 10
      )
    ) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  -- 11. Coleta de registros de acesso (LGPD-J6 R11, Marco Civil art. 15, 20261108110000)
  --  a) o gatilho de auth.sessions engoliu alguma falha nas últimas 24 h;
  --  b) coleta ligada, sessão criada ou renovada na última hora (depois de ligar) e nenhuma linha nova.
  -- O item b lê auth.sessions, esquema interno do Auth: isolado, para uma mudança lá não calar os outros alertas.
  select coalesce(sum(f.falhas), 0)::int into v_falhas_registro
    from privado.registro_acesso_falha f
   where f.hora > v_agora - interval '24 hours';
  if v_falhas_registro > 0 then
    if privado.emitir_alerta('registro_acesso_falhou', jsonb_build_object(
         'valor', v_falhas_registro,
         'janela_horas', 24,
         'ultimo_sqlstate', (select f.ultimo_sqlstate from privado.registro_acesso_falha f
                              where f.hora > v_agora - interval '24 hours'
                              order by f.hora desc limit 1))) then
      v_alertas := v_alertas + 1;
    end if;
  end if;

  begin
    select c.* into v_coleta from privado.registro_acesso_coleta c where c.unica;
    if coalesce(v_coleta.ligada, false) then
      v_desde := greatest(v_agora - interval '1 hour', v_coleta.alterada_em);
      select count(*)::int into v_sessoes_sem_registro
        from auth.sessions s
       where coalesce(s.refreshed_at at time zone 'UTC', s.created_at) > v_desde
         and coalesce(s.refreshed_at at time zone 'UTC', s.created_at) <= v_agora;
      if v_sessoes_sem_registro > 0 and not exists (
           select 1 from privado.registro_acesso r where r.acessado_em > v_desde) then
        if privado.emitir_alerta('registro_acesso_parado', jsonb_build_object(
             'valor', v_sessoes_sem_registro,
             'janela_minutos', 60)) then
          v_alertas := v_alertas + 1;
        end if;
      end if;
    end if;
  exception
    when others then
      if privado.emitir_alerta('registro_acesso_monitor_indisponivel', 1) then
        v_alertas := v_alertas + 1;
      end if;
  end;

  return v_alertas;
end $$;

comment on function privado.verificar_saude() is
  'Varre filas pgmq, falhas de cron, notificações com erro (incluindo NOT_FOUND do FCM), despachos retidos, falhas de execução, denúncias sem moderação após 24h (Diretriz 1.2), contestações vencidas (RN13), falhas assíncronas do pg_net, tentativas recusadas de demonstração (Item 19) e a coleta de registros de acesso (falha engolida em 24 h; sessão renovada sem registro com a coleta ligada). Emite alertas à equipe por e-mail com limite de 1/hora por tipo.';

revoke execute on function privado.verificar_saude() from public, anon, authenticated;
grant  execute on function privado.verificar_saude() to service_role;
