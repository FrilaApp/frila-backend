-- 20261117100000_saude_operacional.sql
-- Fase 2 da sonda operacional (Cartão bB0tV5R8): entrega de e-mail, registro de acessos,
-- filas, pg_net e SMTP.
--
-- A Fase 1 (20261116130000, privado.consultar_saude_cron) vigia reprocessar_despacho e
-- verificar_saude. Falta o que entrega o aviso: se o job de e-mail morrer, se a fila de
-- e-mail parar, se o pg_net falhar ou se o SMTP recusar, o `verificar_saude` até alerta,
-- mas o alerta sai pela mesma fila que está parada. Esta função fica fora desse caminho:
-- é lida pela Edge Function `saude`, que um monitor externo consulta sem usar pg_cron,
-- pgmq nem e-mail.
--
-- Não altera 20261116130000 (imutável), privado.verificar_saude() nem privado.emitir_alerta().
--
-- RN15: o retorno só tem nomes genéricos (entrega, registro, fila, transporte). Nome de
-- job, fila ou tabela não aparece em coluna; e a Edge Function só leva `status` à resposta
-- pública.

select set_config('lock_timeout', '2s', true);

create or replace function privado.consultar_saude_operacional(
  p_tol_entrega_s        numeric default 600,
  p_tol_registro_s       numeric default 600,
  p_tol_fila_email_s     numeric default 900,
  p_tol_fila_despacho_s  numeric default 900,
  p_janela_pgnet_s       integer default 900,
  p_teto_pgnet           integer default 3,
  p_janela_smtp_s        integer default 1800,
  p_teto_smtp            integer default 1
)
returns table (
  saudavel                 boolean,
  status                   text,
  entrega_idade_segundos   numeric,
  entrega_ativo            boolean,
  registro_idade_segundos  numeric,
  registro_ativo           boolean,
  fila_idade_segundos      numeric,
  transporte_falhas        integer,
  transporte_legivel       boolean,
  entrega_falhas           integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_agora            timestamptz := privado.agora();
  v_e_idade          numeric;
  v_e_ativo          boolean;
  v_r_ligada         boolean := false;
  v_r_idade          numeric;
  v_r_ativo          boolean := true;
  v_fila_email       numeric;
  v_fila_despacho    numeric;
  v_fila             numeric;
  v_net_falhas       integer := 0;
  v_net_legivel      boolean := false;
  v_smtp_falhas      integer;
  v_parado           boolean := false;
  v_degradado        boolean := false;
begin
  -- 1. Job que entrega o e-mail (a cada minuto). Mesma leitura da Fase 1.
  select
    round(extract(epoch from (v_agora - max(d.end_time) filter (where d.status = 'succeeded' and d.end_time <= v_agora)))::numeric, 2),
    coalesce(bool_or(j.active), false)
  into v_e_idade, v_e_ativo
  from cron.job j
  left join cron.job_run_details d on d.jobid = j.jobid
  where j.jobname = 'processar_fila_email';

  if not v_e_ativo or v_e_idade is null or v_e_idade > p_tol_entrega_s then
    v_parado := true;
  end if;

  -- 2. Job do registro de acessos, só com a coleta ligada. A leitura da coleta nunca
  --    derruba a sonda: se falhar, o item fica de fora (o verificar_saude tem o seu).
  begin
    select coalesce(c.ligada, false) into v_r_ligada
      from privado.registro_acesso_coleta c
     where c.unica;
  exception
    when others then
      v_r_ligada := false;
  end;

  if coalesce(v_r_ligada, false) then
    select
      round(extract(epoch from (v_agora - max(d.end_time) filter (where d.status = 'succeeded' and d.end_time <= v_agora)))::numeric, 2),
      coalesce(bool_or(j.active), false)
    into v_r_idade, v_r_ativo
    from cron.job j
    left join cron.job_run_details d on d.jobid = j.jobid
    where j.jobname = 'consumir_registro_acesso';

    if not v_r_ativo or v_r_idade is null or v_r_idade > p_tol_registro_s then
      v_parado := true;
    end if;
  end if;

  -- 3. Idade da mensagem mais velha em cada fila. A tabela só é lida se existir; um erro
  --    de leitura de tabela que existe NÃO é engolido: a Edge Function responde 503
  --    `indisponivel`, que é o lado barulhento da falha.
  if exists (select 1 from pg_catalog.pg_tables where schemaname = 'pgmq' and tablename = 'q_email') then
    execute 'select extract(epoch from ($1 - min(enqueued_at)))::numeric from pgmq.q_email'
      into v_fila_email using v_agora;
  end if;
  if exists (select 1 from pg_catalog.pg_tables where schemaname = 'pgmq' and tablename = 'q_despacho') then
    execute 'select extract(epoch from ($1 - min(enqueued_at)))::numeric from pgmq.q_despacho'
      into v_fila_despacho using v_agora;
  end if;

  v_fila := greatest(v_fila_email, v_fila_despacho);

  if coalesce(v_fila_email, 0) > p_tol_fila_email_s
     or coalesce(v_fila_despacho, 0) > p_tol_fila_despacho_s then
    v_degradado := true;
  end if;

  -- 4. Falha de transporte do pg_net (mesmo predicado do item 9 do verificar_saude). Se a
  --    tabela não for legível, `transporte_legivel = false` e a sonda NÃO adoece: senão o
  --    ambiente ficaria vermelho para sempre por falta de privilégio, e o verificar_saude
  --    já tem o seu alerta `pgnet_monitor_indisponivel` para isso.
  begin
    if (
      exists (select 1 from privado.ambiente where eh_teste)
      and coalesce(current_setting('frila.simular_sem_pgnet', true), 'off') = 'on'
    ) then
      v_net_legivel := false;
    elsif exists (select 1 from pg_catalog.pg_tables where schemaname = 'net' and tablename = '_http_response')
       and has_table_privilege('postgres', 'net._http_response', 'select') then
      if (
        exists (select 1 from privado.ambiente where eh_teste)
        and coalesce(current_setting('frila.simular_excecao_pgnet', true), 'off') = 'on'
      ) then
        raise exception 'simulacao de erro pgnet em tempo de execucao';
      end if;

      execute $dyn$
        select count(*)::integer
          from net._http_response
         where created > $1 - make_interval(secs => $2)
           and (
             timed_out = true
             or error_msg is not null
             or status_code >= 500
           )
      $dyn$ into v_net_falhas using v_agora, p_janela_pgnet_s;
      v_net_legivel := true;
    end if;
  exception
    when others then
      v_net_falhas := 0;
      v_net_legivel := false;
  end;

  if v_net_legivel and v_net_falhas >= p_teto_pgnet then
    v_degradado := true;
  end if;

  -- 5. Falha de envio por SMTP, gravada pela Edge Function `enviar-email` quando arquiva
  --    um pedido que não saiu. A janela é maior que a da fila: o monitor externo só avisa
  --    depois de ~10 minutos de 503, e a falha some da fila no mesmo instante em que o
  --    pedido é arquivado.
  select count(*)::integer into v_smtp_falhas
    from privado.falha_execucao f
   where f.origem = 'enviar_email'
     and f.criada_em > v_agora - make_interval(secs => p_janela_smtp_s);

  if v_smtp_falhas >= p_teto_smtp then
    v_degradado := true;
  end if;

  return query select
    not (v_parado or v_degradado),
    case when v_parado then 'atrasado' when v_degradado then 'degradado' else 'saudavel' end,
    v_e_idade,
    v_e_ativo,
    v_r_idade,
    v_r_ativo,
    round(v_fila, 2),
    v_net_falhas,
    v_net_legivel,
    v_smtp_falhas;
end;
$$;

comment on function privado.consultar_saude_operacional(numeric, numeric, numeric, numeric, integer, integer, integer, integer) is
  'Sonda operacional da Edge Function saude (cartão bB0tV5R8, fase 2): idade do job de entrega de e-mail e do registro de acessos (este só com a coleta ligada), idade das filas, falha de transporte do pg_net e falha de SMTP recente. Sem dado pessoal, sem nome de job, fila ou tabela no retorno (RN15). pg_net ilegível devolve transporte_legivel = false e não adoece. Só service_role.';

revoke execute on function privado.consultar_saude_operacional(numeric, numeric, numeric, numeric, integer, integer, integer, integer) from public, anon, authenticated;
grant  execute on function privado.consultar_saude_operacional(numeric, numeric, numeric, numeric, integer, integer, integer, integer) to service_role;
