-- E-mails transacionais e a caixa da Equipe Frila (cartão 7yq1flLG · RF23, RF24, RF26,
-- D02, RN13, RN15).
--
-- O Postgres não manda e-mail. Quem manda é a Edge Function `enviar-email`, e este
-- arquivo é tudo de que ela precisa do lado do banco: o que ler da fila, o que dizer no
-- e-mail, onde registrar que saiu, e como voltar quando o provedor falhar.
--
-- ── Por que a fila continua levando só o id ───────────────────────────────────
--
-- A `denunciar` de 20260929100000 já enfileira `{tipo, ocorrencia_id}` e nada mais; o
-- teste 360 fixa esse formato letra por letra. Uma denúncia, porém, gera **dois**
-- e-mails: o da Equipe Frila e o protocolo para quem denunciou.
--
-- Os dois saem do mesmo pedido. A alternativa — enfileirar duas mensagens, uma por
-- destinatário — obrigaria a reescrever `public.denunciar`, e a `denunciar` não muda de
-- superfície nenhuma por causa disto: o corpo do e-mail, os destinatários e o texto são
-- decisão do consumidor, como o comentário daquela migração já dizia ("o consumidor monta
-- o e-mail no envio"). Uma mensagem, dois destinos, e o que já foi entregue fica marcado
-- na `ocorrencia` — de modo que a retentativa manda só o que faltou, e não o e-mail de
-- novo para quem já recebeu.
--
-- ── O que o e-mail da equipe não leva ─────────────────────────────────────────
--
-- Nem o relato, nem o nome, nem o e-mail de quem denunciou. Leva o protocolo, a
-- categoria do motivo e o prazo. A Equipe Frila abre a ocorrência pelo protocolo e lê o
-- relato no console, com a chave de serviço — que é onde ele já está e onde a retenção
-- alcança. Mandar o relato por e-mail o copiaria para os logs do provedor, fora do
-- alcance da RF25, e o cartão pede o mínimo possível de retenção lá (RN15).

-- ── 1. O registro do envio na `ocorrencia` ────────────────────────────────────
--
-- O protocolo é o `id` da ocorrência, como o contrato define em `Protocolo`; não há
-- coluna nova para ele. O que faltava era o registro de que o e-mail saiu, e o prazo
-- que de fato foi comunicado — congelado no envio, para que uma mudança futura em
-- `privado.prazo_de_resposta` não reescreva o que já foi prometido a alguém.
alter table public.ocorrencia
  add column email_equipe_em   timestamptz,
  add column email_autor_em    timestamptz,
  add column email_prazo_ate   date,
  add column email_tentativas  integer not null default 0,
  add column email_ultimo_erro text;

-- RN15 pela forma, e não pela boa vontade de quem escreve o consumidor: o campo do erro
-- só aceita código em `snake_case`. Um endereço de e-mail, uma mensagem do provedor com
-- o destinatário dentro ou um pedaço de corpo não cabem aqui — a linha é recusada.
alter table public.ocorrencia
  add constraint erro_de_email_e_codigo
    check (email_ultimo_erro is null or email_ultimo_erro ~ '^[a-z0-9_]{1,60}$');

comment on column public.ocorrencia.email_equipe_em is
  'Instante em que o e-mail da Equipe Frila saiu para esta ocorrência (7yq1flLG). Nulo enquanto não saiu. O corpo do e-mail não é guardado em lugar nenhum.';
comment on column public.ocorrencia.email_autor_em is
  'Instante em que o protocolo foi enviado a quem abriu a ocorrência (RF23, RF26). Nulo enquanto não saiu, e permanece nulo para conta anonimizada, que não tem mais endereço.';
comment on column public.ocorrencia.email_prazo_ate is
  'Data-limite de resposta efetivamente comunicada no e-mail, congelada no envio. Antes do envio o prazo é calculado por privado.prazo_de_resposta.';
comment on column public.ocorrencia.email_tentativas is
  'Quantas vezes o provedor de e-mail recusou esta ocorrência. Serve ao teto de retentativas do consumidor.';
comment on column public.ocorrencia.email_ultimo_erro is
  'Classe do último erro do provedor, em snake_case e nada mais (RN15). Nunca a mensagem do provedor, que pode trazer o endereço do destinatário.';

-- ── 2. A imutabilidade passa a conhecer as colunas do envio ───────────────────
--
-- `privado.registro_imutavel` compara a linha inteira menos as colunas declaradas no
-- gatilho, de propósito: coluna nova nasce imutável até alguém decidir o contrário. É
-- aqui que se decide. Sem isto, o primeiro `update` do consumidor levaria
-- `restrict_violation`, e o e-mail sairia sem nunca ficar registrado — que é o modo de
-- falha em que a retentativa reenvia para sempre.
drop trigger ocorrencia_imutavel on public.ocorrencia;
create trigger ocorrencia_imutavel before update or delete on public.ocorrencia
  for each row execute function privado.registro_imutavel(
    'resultado', 'resolvido_em',
    'email_equipe_em', 'email_autor_em', 'email_prazo_ate',
    'email_tentativas', 'email_ultimo_erro');

-- O arquivo da fila fica fechado pelo mesmo motivo que `pgmq.q_email`: o `ensure_rls` só
-- alcança `public`, e o schema `pgmq` não é exposto pelo PostgREST hoje — o que não é
-- garantia nenhuma para amanhã.
alter table pgmq.a_email enable row level security;

comment on table pgmq.a_email is
  'Arquivo dos pedidos de e-mail já atendidos ou esgotados (7yq1flLG). A higiene diária apaga o que tem mais de 30 dias. RLS ligada e sem política.';

-- ── 3. O que o consumidor lê ──────────────────────────────────────────────────
--
-- Uma chamada por ocorrência, com tudo que os dois e-mails precisam e nada além. O
-- `relato` não está aqui, e essa ausência é a regra: o que a função não devolve não tem
-- como ser enviado por engano.
create or replace function privado.dados_do_email(p_ocorrencia_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_o      public.ocorrencia%rowtype;
  v_email  text;
  v_estado public.estado_conta;
  v_prazo  date;
begin
  select * into v_o from public.ocorrencia o where o.id = p_ocorrencia_id;
  if not found then
    return null;
  end if;

  select u.email::text, u.estado into v_email, v_estado
    from public.usuario u where u.id = v_o.autor_id;

  v_prazo := coalesce(v_o.email_prazo_ate, privado.prazo_de_resposta(v_o.criada_em));

  return jsonb_build_object(
    'ocorrencia_id',      v_o.id,
    'tipo',               v_o.tipo::text,
    'motivo',             v_o.motivo,
    'criada_em',          v_o.criada_em,
    'prazo_resposta_ate', v_prazo,
    -- A casa ou a pessoa, sem dizer qual: o e-mail da equipe cita o protocolo, e quem
    -- abre o protocolo vê o resto.
    'alvo_tipo',          case
                            when v_o.estabelecimento_id is not null then 'estabelecimento'
                            when v_o.usuario_id is not null         then 'profissional'
                          end,
    'equipe_pendente',    v_o.email_equipe_em is null,
    -- Conta anonimizada perdeu o endereço (RF25): não há para onde mandar, e insistir
    -- seria retentativa infinita. `suspensa` continua recebendo — é justamente quem
    -- precisa do protocolo da contestação (RF24).
    'autor_pendente',     v_o.email_autor_em is null
                            and v_email is not null
                            and v_estado <> 'anonimizada',
    'autor_email',        case when v_estado <> 'anonimizada' then v_email end,
    'tentativas',         v_o.email_tentativas
  );
end $$;

comment on function privado.dados_do_email(uuid) is
  'Tudo de que a Edge Function enviar-email precisa para montar os dois e-mails de uma ocorrência (7yq1flLG): protocolo, tipo, categoria do motivo, prazo, o que ainda falta enviar e o endereço de quem abriu. Nunca o relato (RN15).';

revoke execute on function privado.dados_do_email(uuid) from public, anon, authenticated;
grant  execute on function privado.dados_do_email(uuid) to service_role;

-- ── 4. Ler a fila ─────────────────────────────────────────────────────────────
-- Devolve a mensagem inteira, e não campos escolhidos: o pedido de denúncia leva
-- `{tipo, ocorrencia_id}`, o do alerta do monitoramento leva `{tipo, codigo, valor}`, e
-- uma função que soubesse os campos de cada tipo teria de mudar a cada tipo novo. Quem
-- entende o formato é o consumidor, que é quem monta o e-mail.
create or replace function privado.ler_fila_email(p_qtd int default 10, p_vt int default 60)
returns table (msg_id bigint, read_ct int, mensagem jsonb)
language sql
security definer
set search_path = ''
as $$
  select m.msg_id, m.read_ct, m.message
    from pgmq.read('email', p_vt, p_qtd) m
$$;

comment on function privado.ler_fila_email(int, int) is
  'Retira da fila email, sob visibility timeout, até p_qtd pedidos, com a mensagem inteira. O read_ct é quantas vezes o pedido já foi lido, e é ele que sustenta o teto de retentativas do consumidor.';

revoke execute on function privado.ler_fila_email(int, int) from public, anon, authenticated;
grant  execute on function privado.ler_fila_email(int, int) to service_role;

-- ── 5. Registrar o que saiu ───────────────────────────────────────────────────
--
-- Idempotente por destino: o `coalesce` guarda o primeiro instante. Uma retentativa que
-- reenvia o que já tinha saído — porque a rede caiu entre o provedor e o `update` —
-- não reescreve a hora do envio original.
create or replace function privado.registrar_email_enviado(
  p_ocorrencia_id uuid,
  p_destino       text,
  p_prazo         date default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora timestamptz := privado.agora();
begin
  if p_destino is null or p_destino not in ('equipe', 'autor') then
    raise exception 'destino de e-mail desconhecido: %', coalesce(p_destino, '<nulo>')
      using errcode = 'invalid_parameter_value';
  end if;

  update public.ocorrencia o
     set email_equipe_em = case when p_destino = 'equipe'
                                then coalesce(o.email_equipe_em, v_agora)
                                else o.email_equipe_em end,
         email_autor_em  = case when p_destino = 'autor'
                                then coalesce(o.email_autor_em, v_agora)
                                else o.email_autor_em end,
         email_prazo_ate = coalesce(o.email_prazo_ate, p_prazo,
                                    privado.prazo_de_resposta(o.criada_em)),
         email_ultimo_erro = null
   where o.id = p_ocorrencia_id;
end $$;

comment on function privado.registrar_email_enviado(uuid, text, date) is
  'Marca na ocorrência que o e-mail de um dos dois destinos saiu, com o prazo comunicado (7yq1flLG). Não guarda assunto nem corpo. Idempotente por destino.';

revoke execute on function privado.registrar_email_enviado(uuid, text, date) from public, anon, authenticated;
grant  execute on function privado.registrar_email_enviado(uuid, text, date) to service_role;

-- ── 6. Registrar a recusa do provedor ─────────────────────────────────────────
--
-- O código chega classificado pelo consumidor. O que não vier em `snake_case` vira
-- `erro_nao_classificado` **antes** do `update`: normalizar a mensagem do provedor
-- — trocar o que não é letra por `_` — deixaria `ana@frila.test` virar `anafrilatest`,
-- que é o endereço de alguém escrito de outro jeito.
create or replace function privado.registrar_falha_email(p_ocorrencia_id uuid, p_codigo text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_codigo     text;
  v_tentativas integer;
begin
  v_codigo := case
                when p_codigo ~ '^[a-z0-9_]{1,60}$' then p_codigo
                else 'erro_nao_classificado'
              end;

  update public.ocorrencia o
     set email_tentativas  = o.email_tentativas + 1,
         email_ultimo_erro = v_codigo
   where o.id = p_ocorrencia_id
  returning o.email_tentativas into v_tentativas;

  return coalesce(v_tentativas, 0);
end $$;

comment on function privado.registrar_falha_email(uuid, text) is
  'Conta mais uma recusa do provedor para esta ocorrência e guarda a classe do erro em snake_case (RN15). Devolve o total de tentativas. Não arquiva o pedido: ele volta à fila quando o visibility timeout vence.';

revoke execute on function privado.registrar_falha_email(uuid, text) from public, anon, authenticated;
grant  execute on function privado.registrar_falha_email(uuid, text) to service_role;

-- ── 7. Fechar o pedido ────────────────────────────────────────────────────────
create or replace function privado.concluir_email(p_msg_id bigint)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select pgmq.archive('email', p_msg_id)
$$;

comment on function privado.concluir_email(bigint) is
  'Arquiva o pedido de e-mail: ou porque os dois e-mails saíram, ou porque o teto de tentativas foi atingido e insistir só enche a fila.';

revoke execute on function privado.concluir_email(bigint) from public, anon, authenticated;
grant  execute on function privado.concluir_email(bigint) to service_role;

-- ── 8. Acordar o consumidor ───────────────────────────────────────────────────
--
-- Mesmo desenho do despacho (20260926010000): `net.http_post` sai pós-commit, o gatilho
-- na fila acorda a função na hora, e o `pg_cron` de um minuto drena o que ficou. A
-- exigência do segredo aborta em voz alta, como lá: uma configuração ausente que só
-- aparecesse como e-mail que nunca chega é pior do que uma escrita que falha na cara de
-- quem chamou.
create or replace function privado.disparar_email()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    current_setting('frila.email_function_url', true),
    'http://127.0.0.1:54321/functions/v1/enviar-email'
  );
  v_secret text := current_setting('frila.agendador_secret', true);
  v_req_id bigint;
begin
  if v_secret is null or v_secret = '' then
    raise exception 'Configuração frila.agendador_secret ausente no banco de dados';
  end if;

  -- Fila vazia não acorda ninguém: o job de um minuto rodaria um POST por minuto para
  -- sempre, e o provedor de e-mail cobra por chamada em quase todo plano.
  if not exists (select 1 from pgmq.q_email limit 1) then
    return null;
  end if;

  begin
    v_req_id := net.http_post(
      url     => v_url,
      headers => jsonb_build_object(
        'Content-Type',       'application/json',
        'Authorization',      'Bearer ' || v_secret,
        'x-agendador-secret', v_secret
      ),
      body    => jsonb_build_object('origem', 'fila'),
      timeout_milliseconds => 5000
    );
  exception when others then
    -- Só falha de transporte cai aqui, e ela é recuperável por desenho: a mensagem
    -- continua na fila e o job do minuto seguinte tenta de novo. Nada é registrado,
    -- porque o texto do erro de rede pode trazer a URL com o segredo no cabeçalho.
    v_req_id := null;
  end;

  return v_req_id;
end $$;

comment on function privado.disparar_email() is
  'Acorda a Edge Function enviar-email por net.http_post quando há pedido na fila (7yq1flLG). Sai pós-commit; falha de transporte deixa o pedido na fila para o pg_cron.';

revoke execute on function privado.disparar_email() from public, anon, authenticated;
grant  execute on function privado.disparar_email() to service_role;

create or replace function privado.trg_disparar_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform privado.disparar_email();
  return new;
end $$;

drop trigger if exists trg_email_enfileirado on pgmq.q_email;
create trigger trg_email_enfileirado
  after insert on pgmq.q_email
  for each row
  execute function privado.trg_disparar_email();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('processar_fila_email')
      where exists (select 1 from cron.job where jobname = 'processar_fila_email');
    perform cron.schedule(
      'processar_fila_email',
      '* * * * *',
      'select privado.disparar_email()'
    );
  end if;
end $$;

-- ── 9. A higiene alcança o arquivo da fila de e-mail ──────────────────────────
--
-- Idêntica à de 20260927010000, mais `pgmq.a_email`. O cartão pede retenção mínima dos
-- registros do envio; trinta dias é o mesmo prazo que o arquivo do despacho já usa.
create or replace function privado.higienizar_tabelas()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cron_removidos  integer := 0;
  v_pgmq_removidos  integer := 0;
  v_email_removidos integer := 0;
begin
  -- 1. cron.job_run_details com mais de 7 dias
  if exists (
    select 1 from pg_catalog.pg_tables
     where schemaname = 'cron' and tablename = 'job_run_details'
  ) then
    delete from cron.job_run_details
     where start_time < privado.agora() - interval '7 days';
    get diagnostics v_cron_removidos = row_count;
  end if;

  -- 2. Arquivo do pgmq com mais de 30 dias (pgmq.a_despacho)
  if exists (
    select 1 from pg_catalog.pg_tables
     where schemaname = 'pgmq' and tablename = 'a_despacho'
  ) then
    delete from pgmq.a_despacho
     where archived_at < privado.agora() - interval '30 days';
    get diagnostics v_pgmq_removidos = row_count;
  end if;

  -- 3. Arquivo dos pedidos de e-mail com mais de 30 dias (pgmq.a_email)
  if exists (
    select 1 from pg_catalog.pg_tables
     where schemaname = 'pgmq' and tablename = 'a_email'
  ) then
    delete from pgmq.a_email
     where archived_at < privado.agora() - interval '30 days';
    get diagnostics v_email_removidos = row_count;
  end if;

  return jsonb_build_object(
    'cron_job_run_details', v_cron_removidos,
    'pgmq_arquivo',         v_pgmq_removidos,
    'pgmq_arquivo_email',   v_email_removidos
  );
end $$;

comment on function privado.higienizar_tabelas() is
  'Higiene operacional periódica: cron.job_run_details (> 7d) e os arquivos do pgmq, despacho e email (> 30d). Dispositivos inativos são higienizados às 06:17 por rotina dedicada (cartão wpNabtCO).';

revoke execute on function privado.higienizar_tabelas() from public, anon, authenticated;
grant  execute on function privado.higienizar_tabelas() to service_role;
