-- Migração: 20261108110000_lgpd_registro_acessos_borda.sql
-- Escopo: LGPD-J6 R11 (cartão HAWhzOJ4). Registro de acessos a aplicação de internet (Marco Civil, Lei
-- 12.965/2014, art. 5º VIII e art. 15) com o IP da BORDA. Substitui o desenho do #441 (gatilho em auth.sessions),
-- porque o IP que o Auth grava em auth.sessions vem do 1º X-Forwarded-For, que o cliente escolhe (medido no Prod
-- em 08/11/2026, orquestracao/retornos/B-T2-g-select-prod-resultado.txt).
--
-- Desenho A3, aprovado pela Central em 08/11/2026 (orquestracao/retornos/B-T2-fonte-ip-desenho.md):
--   · a fonte é o cf-connecting-ip que chega ao PostgREST: a Cloudflare recusa o forjado com 403 (M1 no frila-dev,
--     orquestracao/retornos/B-T2-cabecalhos-prod.txt). Nada de X-Forwarded-For, x-real-ip nem true-client-ip;
--   · o db_pre_request (requisicao.conferir_limite) roda em toda chamada, inclusive no GET e na RPC stable, que o
--     PostgREST abre em transação SÓ LEITURA. Ali, INSERT não passa; pg_logical_emit_message(false, …) passa, porque
--     vai ao WAL fora da transação (medido). Por isso a 1ª requisição de cada (conta, IP, hora) emite uma mensagem
--     lógica, e um job do pg_cron a consome a cada minuto e grava. A mensagem sobrevive até a requisição que falha;
--   · o pre-request só lê: confere a chave da coleta e a tabela pequena registro_acesso_recente. Medido: +5 µs com a
--     coleta desligada; +20 a +33 µs ligada, com a hora já registrada (autor e Lince AG 2; 20 mil chamadas por
--     rodada, mediana), sem espera de trava. Erro no registro nunca derruba a requisição;
--   · a mensagem vai ao disco com o WAL, sem fsync próprio: o consumidor a vê depois do flush, em até ~1 s, e o
--     atraso de até 1 min do agendamento é aceito (Forja, 08/11).
--
-- Decisões da Bússola (08/11/2026): por HORA, nunca por dia; chave (conta, IP, hora), e troca de IP na mesma hora
-- gera linha nova; cada linha leva conta, IP e data e hora do PRIMEIRO uso no balde, com segundos, em UTC; sem
-- user_agent e sem porta: o PostgREST não recebe porta de origem confiável (M1), e o limite é o resíduo R9
-- (Decreto 8.771, art. 15-A); guarda de 6 meses a contar da linha, inclusive depois da exclusão da conta.
-- A hora do ÚLTIMO uso no balde não entra: o pre-request só emite na 1ª requisição do balde (é o que o deixa
-- barato), e saber a última exigiria emitir em toda requisição.
--
-- Guarda legal (Central, 08/11/2026; Marco Civil art. 15, § 2º): privado.registro_acesso_guarda lista contas cujos
-- registros uma autoridade pediu, cautelarmente, que fiquem além dos 6 meses. A limpeza pula essas contas enquanto
-- a guarda vale.
--
-- O slot lógico nunca pode encher o disco do plano grátis (Central): o consumidor e o verificar_saude derrubam o
-- slot quando o atraso passa do teto (registro_acesso_coleta.teto_wal_mb, 128 MB, configurável), registram o
-- buraco em privado.falha_execucao e recriam o slot. Com a coleta desligada, não há slot. A coleta nasce DESLIGADA:
-- o Opus Prod liga com privado.definir_coleta_registro_acesso(true) depois do deploy, e prova que um GET grava.
--
-- O layout enxuto (62 bytes por linha, medido com 1 milhão de linhas) tira de privado.registro_acesso o id, o
-- recurso, o user_agent, a FK e os dois índices btree, e põe uma BRIN em acessado_em. A tabela tem 0 linhas no
-- Prod (08/11/2026) e nenhum leitor além da limpeza; privado.registrar_acesso (gravação manual, sem chamador) sai.
-- privado.executar_retencao_diaria não muda: limpar_registros_acesso mantém a assinatura.

-- A migração troca o corpo de requisicao.conferir_limite, que roda em toda requisição, e mexe em
-- privado.registro_acesso. Com 2 s de lock_timeout, uma transação longa não deixa a API na fila atrás dela.
select set_config('lock_timeout', '2s', true);

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. privado.registro_acesso: layout enxuto
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists privado.registrar_acesso(uuid, inet, text, text);
alter table privado.registro_acesso drop constraint if exists registro_acesso_usuario_id_fkey;
drop index if exists privado.registro_acesso_acessado_em_idx;
drop index if exists privado.registro_acesso_usuario_idx;
alter table privado.registro_acesso
  drop column if exists id,
  drop column if exists recurso,
  drop column if exists user_agent;
alter table privado.registro_acesso alter column acessado_em drop default;
create index registro_acesso_acessado_em_brin on privado.registro_acesso using brin (acessado_em);

comment on table privado.registro_acesso is
  'Registros de acesso a aplicação de internet (Marco Civil, Lei 12.965/2014, art. 5º VIII e art. 15): conta, IP da borda (cf-connecting-ip) e data e hora do 1º uso em cada (conta, IP, hora). Sem user_agent e sem porta de origem (o PostgREST não recebe porta confiável; resíduo R9, Decreto 8.771 art. 15-A). Sob sigilo, por 6 meses contados da linha, inclusive depois da exclusão da conta (privado.limpar_registros_acesso; LGPD art. 16, I), salvo guarda legal (privado.registro_acesso_guarda, MCI art. 15, § 2º). Base legal: LGPD art. 7º, II (cumprimento do art. 15 do Marco Civil; controladora é a empresa) para a guarda, e art. 7º, IX (segurança da conta e apuração de fraude) para o uso interno. Gravado por privado.consumir_registro_acesso; acesso só do service_role; entrega a terceiro só por ordem judicial.';
comment on column privado.registro_acesso.usuario_id is
  'Conta (auth.users.id, o sub do JWT). Sem chave estrangeira: o registro dura 6 meses mesmo depois da exclusão da conta (LGPD art. 16, I).';
comment on column privado.registro_acesso.ip is
  'IP da borda: o cf-connecting-ip que a Cloudflare põe e não deixa forjar (M1, 08/11/2026). Nunca o X-Forwarded-For.';
comment on column privado.registro_acesso.acessado_em is
  'Data e hora (UTC, com microssegundos) do 1º uso da conta a partir deste IP nesta hora.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. A chave da coleta (nasce desligada), o teto de WAL e o último consumo
-- ─────────────────────────────────────────────────────────────────────────────
create table privado.registro_acesso_coleta (
  unica        boolean primary key default true check (unica),
  ligada       boolean not null default false,
  alterada_em  timestamptz not null default privado.agora(),
  consumido_em timestamptz,
  teto_wal_mb  integer not null default 128 check (teto_wal_mb between 16 and 192)
);
insert into privado.registro_acesso_coleta (unica, ligada) values (true, false);

alter table privado.registro_acesso_coleta enable row level security;
revoke all on table privado.registro_acesso_coleta from public, anon, authenticated;
grant select, update (teto_wal_mb) on table privado.registro_acesso_coleta to service_role;

comment on table privado.registro_acesso_coleta is
  'Chave da coleta de registros de acesso (uma linha só). Nasce desligada; liga e desliga só por privado.definir_coleta_registro_acesso, que cria ou derruba o slot lógico. consumido_em é o último consumo bem-sucedido (o alerta registro_acesso_parado e o início de um buraco). teto_wal_mb é o atraso máximo do slot antes de a autoproteção o derrubar (128 MB; o service_role ajusta entre 16 e 192). O máximo de 192 MB é 75% do max_slot_wal_keep_size de 256 MB do Prod: com o teto acima dele, o servidor invalidaria o slot primeiro, e a autoproteção ainda mediria "ok" pelo confirmed_flush_lsn. Subir o teto exige migração e, antes, subir o max_slot_wal_keep_size. Não guarda dado pessoal.';

-- O nome do slot e o balde moram em funções, para que a granularidade mude num lugar só.
create or replace function privado.slot_registro_acesso() returns text
language sql immutable set search_path = '' as $$
  select 'frila_registro_acesso'::text
$$;
comment on function privado.slot_registro_acesso() is
  'Nome do slot lógico (test_decoding) do registro de acessos.';

create or replace function privado.balde_registro_acesso(p_em timestamptz) returns timestamptz
language sql stable set search_path = '' as $$
  select date_trunc('hour', p_em, 'UTC')
$$;
comment on function privado.balde_registro_acesso(timestamptz) is
  'O balde do registro de acessos: a hora cheia em UTC (Bússola, 08/11/2026: por hora, nunca por dia). A chave é (conta, IP, balde).';

revoke all on function privado.slot_registro_acesso() from public, anon, authenticated;
revoke all on function privado.balde_registro_acesso(timestamptz) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. O que já foi registrado nas últimas horas (deduplicação, só leitura no pre-request)
-- ─────────────────────────────────────────────────────────────────────────────
create table privado.registro_acesso_recente (
  usuario_id uuid not null,
  ip         inet not null,
  balde      timestamptz not null,
  primary key (usuario_id, ip, balde)
);

alter table privado.registro_acesso_recente enable row level security;
revoke all on table privado.registro_acesso_recente from public, anon, authenticated;

comment on table privado.registro_acesso_recente is
  'Os (conta, IP, balde) já gravados nas últimas 3 horas, para o pre-request não emitir de novo. É estado de deduplicação, não registro: o consumidor apaga o que passa de 3 horas. Mesmos dados de privado.registro_acesso (conta e IP), sob o mesmo sigilo.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Guarda legal (Marco Civil, art. 15, § 2º)
-- ─────────────────────────────────────────────────────────────────────────────
create table privado.registro_acesso_guarda (
  id         bigint generated always as identity primary key,
  usuario_id uuid not null,
  desde      timestamptz not null,
  ate        timestamptz not null,
  referencia text not null check (char_length(btrim(referencia)) between 1 and 80),
  criada_em  timestamptz not null default privado.agora(),
  constraint registro_acesso_guarda_periodo check (ate > desde)
);
create index registro_acesso_guarda_conta on privado.registro_acesso_guarda (usuario_id);

alter table privado.registro_acesso_guarda enable row level security;
revoke all on table privado.registro_acesso_guarda from public, anon, authenticated;
grant select, insert, update, delete on table privado.registro_acesso_guarda to service_role;

comment on table privado.registro_acesso_guarda is
  'Guarda legal de registros de acesso (Marco Civil, Lei 12.965/2014, art. 15, § 2º): a autoridade policial, administrativa ou o Ministério Público pode requerer, cautelarmente, que os registros de uma conta sejam guardados além dos 6 meses. Entre desde e ate, privado.limpar_registros_acesso não apaga os registros da conta. Só o service_role escreve. NENHUM dado da ordem fica aqui: só a conta, o período e uma referência.';
comment on column privado.registro_acesso_guarda.usuario_id is
  'Conta cujos registros ficam em guarda. Sem chave estrangeira, como em privado.registro_acesso.';
comment on column privado.registro_acesso_guarda.desde is
  'Início da guarda (quando o requerimento chegou).';
comment on column privado.registro_acesso_guarda.ate is
  'Fim da guarda. Depois dele, a limpeza volta a valer para a conta.';
comment on column privado.registro_acesso_guarda.referencia is
  'Identificador da ordem ou do requerimento para localizá-lo fora do banco (ex.: número do ofício). Nunca o conteúdo da ordem, nome, fato ou dado de terceiro.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. O pre-request: registra e depois confere o limite de escrita (que não muda)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function requisicao.conferir_limite() returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_papel    text := nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role';
  v_metodo   text := coalesce(current_setting('request.method', true), '');
  v_ip       text;
  v_em       timestamptz;
  v_janela   timestamptz;
  v_contagem int;
begin
  if v_uid is null or v_papel is distinct from 'authenticated' then
    return;
  end if;

  -- Registro de acessos (Marco Civil art. 15), antes do retorno do GET para cobrir a leitura. Só lê tabelas: com a
  -- coleta ligada, na 1ª requisição de cada (conta, IP, hora) que ainda não está em registro_acesso_recente, emite
  -- uma mensagem lógica NÃO transacional, que vale no GET só leitura e sobrevive à requisição que falha (sem fsync
  -- próprio). Fica aqui, e não numa função à parte, para não somar uma chamada com troca de GUC a cada requisição.
  begin
    if exists (select 1 from privado.registro_acesso_coleta c where c.unica and c.ligada) then
      -- Só o cf-connecting-ip: a borda recusa o forjado. X-Forwarded-For, x-real-ip e true-client-ip, nunca (M1).
      v_ip := nullif(current_setting('request.headers', true), '')::json ->> 'cf-connecting-ip';
      if v_ip is not null and pg_input_is_valid(v_ip, 'inet') then
        v_em := privado.agora();
        if not exists (select 1 from privado.registro_acesso_recente r
                        where r.usuario_id = v_uid and r.ip = v_ip::inet
                          and r.balde = privado.balde_registro_acesso(v_em)) then
          perform pg_logical_emit_message(false, 'frila_registro_acesso',
            v_uid::text || ' ' || host(v_ip::inet) || ' ' || to_char(v_em at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'));
        end if;
      end if;
    end if;
  exception
    -- Nunca derruba a requisição. A falha vira outra mensagem, só com o SQLSTATE (RN15), que o consumidor conta.
    -- query_canceled não entra: um statement_timeout ou cancelamento da requisição segue o caminho normal.
    when others then
      begin
        perform pg_logical_emit_message(false, 'frila_registro_acesso_falha', sqlstate);
      exception when others then
        null;
      end;
  end;

  if v_metodo in ('', 'GET', 'HEAD')
     or current_setting('transaction_read_only') = 'on' then
    return;
  end if;

  v_janela := date_trunc('minute', privado.agora());

  insert into privado.escrita_por_conta as e (usuario_id, janela, contagem)
  values (v_uid, v_janela, 1)
  on conflict (usuario_id) do update
     set contagem = case when e.janela = excluded.janela then e.contagem + 1 else 1 end,
         janela   = excluded.janela
  returning e.contagem into v_contagem;

  if v_contagem > privado.limite_de_escrita_por_minuto() then
    perform public.erro(429, 'limite_excedido');
  end if;
end $$;

comment on function requisicao.conferir_limite() is
  'db_pre_request do PostgREST: registra o acesso da conta autenticada (Marco Civil art. 15), inclusive no GET: com privado.registro_acesso_coleta ligada, emite uma mensagem lógica não transacional (conta, cf-connecting-ip, data e hora em UTC) na 1ª requisição de cada (conta, IP, hora), que privado.consumir_registro_acesso grava; erro no registro nunca derruba a requisição. Depois conta as escritas da conta no minuto e recusa com 429 limite_excedido acima de privado.limite_de_escrita_por_minuto() (RNF07, cartão kT7NhMGV).';

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Autoproteção do slot: nunca enche o disco
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.proteger_slot_registro_acesso(p_origem text) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot      text := privado.slot_registro_acesso();
  v_coleta    privado.registro_acesso_coleta%rowtype;
  v_existe    boolean := false;
  v_atraso_mb numeric;
  v_motivo    text;
  v_recriado  boolean := false;
  v_sqlstate  text;
  v_invalido  boolean := false;
  v_lt        text;
begin
  select c.* into v_coleta from privado.registro_acesso_coleta c where c.unica;
  if not coalesce(v_coleta.ligada, false) then
    return jsonb_build_object('coleta', false);
  end if;

  -- O WAL retido é o que vem depois do restart_lsn, e não do confirmed_flush_lsn: com uma transação longa aberta, o
  -- confirmed_flush_lsn avança e o restart_lsn fica parado (Lince AG 2, E7b: 0,0 MB medidos contra 41,7 MB retidos).
  -- Slot invalidado pelo servidor (wal_status lost, restart_lsn nulo) não serve mais: derruba e recria.
  select true, s.wal_status = 'lost' or s.restart_lsn is null,
         round(pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) / 1048576.0, 1)
    into v_existe, v_invalido, v_atraso_mb
    from pg_catalog.pg_replication_slots s
   where s.slot_name = v_slot;

  if coalesce(v_existe, false) and not coalesce(v_invalido, false) and v_atraso_mb <= v_coleta.teto_wal_mb then
    return jsonb_build_object('coleta', true, 'slot', 'ok', 'atraso_mb', v_atraso_mb);
  end if;

  if coalesce(v_existe, false) then
    v_motivo := case when coalesce(v_invalido, false) then 'slot_invalidado' else 'slot_acima_do_teto' end;
    begin
      perform pg_drop_replication_slot(v_slot);
    exception when others then
      -- Em uso agora (o outro vigia está consumindo): fica para a próxima rodada, sem buraco.
      return jsonb_build_object('coleta', true, 'slot', 'em_uso', 'atraso_mb', v_atraso_mb, 'sqlstate', sqlstate);
    end;
  else
    v_motivo := 'slot_ausente';
  end if;

  -- O Postgres só cria slot em transação que ainda não escreveu (sem XID). Numa que já escreveu, a criação falha
  -- DEPOIS de reservar o slot, e o bloco de exceção deixaria um slot efêmero preso à sessão (medido): por isso nem
  -- tenta, e a rodada seguinte do pg_cron, que começa sem escrita, recria.
  if pg_current_xact_id_if_assigned() is null then
    -- A criação espera as transações abertas terminarem (Lince AG 2, E8). Com 5 s, desiste, o buraco fica registrado
    -- e a rodada seguinte tenta de novo; o job não cai. No erro, o Postgres desfaz o set_config junto com o bloco.
    v_lt := current_setting('lock_timeout');
    begin
      perform set_config('lock_timeout', '5s', true);
      perform pg_create_logical_replication_slot(v_slot, 'test_decoding');
      perform set_config('lock_timeout', v_lt, true);
      v_recriado := true;
    exception when others then
      v_sqlstate := sqlstate;
    end;
  else
    v_sqlstate := '25001';
  end if;

  -- O buraco: tudo o que foi emitido desde o último consumo até agora se perdeu. Sem dado pessoal (RN15).
  perform privado.registrar_falha_execucao(p_origem, 'registro_acesso_buraco', jsonb_build_object(
    'motivo', v_motivo,
    'atraso_mb', v_atraso_mb,
    'teto_mb', v_coleta.teto_wal_mb,
    'desde', coalesce(v_coleta.consumido_em, v_coleta.alterada_em),
    'ate', privado.agora(),
    'recriado', v_recriado,
    'sqlstate', v_sqlstate));
  return jsonb_build_object('coleta', true, 'slot', v_motivo, 'atraso_mb', v_atraso_mb, 'recriado', v_recriado);
end $$;

comment on function privado.proteger_slot_registro_acesso(text) is
  'Autoproteção do slot lógico do registro de acessos, chamada no começo de privado.consumir_registro_acesso e de privado.verificar_saude: com a coleta ligada, se o atraso do slot passa de registro_acesso_coleta.teto_wal_mb (ou se o slot sumiu), derruba, recria e registra o buraco em privado.falha_execucao (registro_acesso_buraco: motivo, período, se recriou). Assim o WAL retido nunca enche o disco do plano grátis.';
revoke all on function privado.proteger_slot_registro_acesso(text) from public, anon, authenticated;
grant execute on function privado.proteger_slot_registro_acesso(text) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. O consumidor (pg_cron, a cada minuto)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.consumir_registro_acesso(p_max integer default 50000) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot      text := privado.slot_registro_acesso();
  v_ligada    boolean;
  v_protecao  jsonb;
  v_acessos   text[];
  v_falhas    text[];
  v_ate       pg_lsn;
  v_linhas    integer := 0;
  v_novas     integer := 0;
  c_acesso    constant text := 'message: transactional: 0 prefix: frila_registro_acesso, sz: ';
  c_falha     constant text := 'message: transactional: 0 prefix: frila_registro_acesso_falha, sz: ';
begin
  if p_max is null or p_max < 1 then
    p_max := 50000;
  end if;
  select c.ligada into v_ligada from privado.registro_acesso_coleta c where c.unica;

  -- Coleta desligada: sem slot, para não reter WAL.
  if not coalesce(v_ligada, false) then
    if exists (select 1 from pg_catalog.pg_replication_slots s where s.slot_name = v_slot) then
      begin
        perform pg_drop_replication_slot(v_slot);
      exception when others then
        -- Em uso agora: a rodada seguinte derruba. O job não cai.
        return jsonb_build_object('coleta', false, 'slot_removido', false, 'sqlstate', sqlstate);
      end;
      return jsonb_build_object('coleta', false, 'slot_removido', true);
    end if;
    return jsonb_build_object('coleta', false);
  end if;

  v_protecao := privado.proteger_slot_registro_acesso('consumir_registro_acesso');
  -- Depois de um buraco (slot derrubado, recriado ou com a criação recusada) ou com o slot em uso, esta rodada não
  -- decodifica: a próxima começa do slot novo. Também não lê um slot efêmero de uma criação que estourou o prazo.
  if v_protecao ->> 'slot' is distinct from 'ok'
     or not exists (select 1 from pg_catalog.pg_replication_slots s where s.slot_name = v_slot) then
    return jsonb_build_object('coleta', true, 'protecao', v_protecao, 'consumidas', 0);
  end if;

  begin
    -- peek + avanço no fim: se a gravação falhar, nada é consumido e a rodada seguinte repete.
    select array_agg(substr(d.data, strpos(d.data, ' content:') + 9)) filter (where starts_with(d.data, c_acesso)),
           array_agg(substr(d.data, strpos(d.data, ' content:') + 9)) filter (where starts_with(d.data, c_falha)),
           max(d.lsn),
           count(*)
      into v_acessos, v_falhas, v_ate, v_linhas
      from pg_logical_slot_peek_changes(v_slot, null, p_max) d;

    with entrada as (
      select split_part(m, ' ', 1) as conta, split_part(m, ' ', 2) as ip, split_part(m, ' ', 3) as em
        from unnest(v_acessos) m
    ), valida as (
      select e.conta::uuid as usuario_id, e.ip::inet as ip, e.em::timestamptz as em
        from entrada e
       where pg_input_is_valid(e.conta, 'uuid') and pg_input_is_valid(e.ip, 'inet')
         and pg_input_is_valid(e.em, 'timestamptz')
    ), primeiro as (
      select distinct on (v.usuario_id, v.ip, privado.balde_registro_acesso(v.em))
             v.usuario_id, v.ip, v.em, privado.balde_registro_acesso(v.em) as balde
        from valida v
       order by v.usuario_id, v.ip, privado.balde_registro_acesso(v.em), v.em
    ), marcado as (
      insert into privado.registro_acesso_recente (usuario_id, ip, balde)
      select p.usuario_id, p.ip, p.balde from primeiro p
      on conflict do nothing
      returning usuario_id, ip, balde
    )
    insert into privado.registro_acesso (usuario_id, ip, acessado_em)
    select p.usuario_id, p.ip, p.em
      from primeiro p
      join marcado m on m.usuario_id = p.usuario_id and m.ip = p.ip and m.balde = p.balde;
    get diagnostics v_novas = row_count;

    if coalesce(array_length(v_falhas, 1), 0) > 0 then
      perform privado.registrar_falha_execucao('consumir_registro_acesso', 'registro_acesso_falhou',
        jsonb_build_object('valor', array_length(v_falhas, 1), 'ultimo_sqlstate', v_falhas[array_length(v_falhas, 1)]));
    end if;

    -- Só com a fila em dia: um lote cortado pelo teto ainda pode trazer baldes antigos.
    if v_linhas < p_max then
      delete from privado.registro_acesso_recente r where r.balde < privado.agora() - interval '3 hours';
    end if;
    update privado.registro_acesso_coleta set consumido_em = privado.agora() where unica;

    if v_ate is not null then
      perform pg_replication_slot_advance(v_slot, v_ate);
    end if;
  exception when others then
    -- Nada foi consumido: as mensagens ficam no slot para a próxima rodada. Não é buraco; é alerta.
    perform privado.registrar_falha_execucao('consumir_registro_acesso', 'registro_acesso_consumo_falhou',
      jsonb_build_object('sqlstate', sqlstate));
    return jsonb_build_object('coleta', true, 'protecao', v_protecao, 'consumidas', 0, 'sqlstate', sqlstate);
  end;

  return jsonb_build_object('coleta', true, 'protecao', v_protecao,
    'consumidas', coalesce(array_length(v_acessos, 1), 0), 'novas', v_novas,
    'falhas', coalesce(array_length(v_falhas, 1), 0), 'linhas_lidas', v_linhas);
end $$;

comment on function privado.consumir_registro_acesso(integer) is
  'Job do pg_cron (consumir_registro_acesso, a cada minuto): lê o slot lógico do registro de acessos (peek, até p_max linhas), grava a 1ª mensagem de cada (conta, IP, hora) que ainda não está em privado.registro_acesso_recente, conta as falhas do pre-request e só então avança o slot. Com a coleta desligada, derruba o slot. Começa pela autoproteção (privado.proteger_slot_registro_acesso). Erro na gravação não consome nada e vira registro_acesso_consumo_falhou em privado.falha_execucao. UMA chamada por sessão: com o plpgsql_check pré-carregado (padrão da imagem do Supabase), a 2ª chamada na mesma sessão cai com "cannot find parent statement on pldbgapi2 call stack" (medido em 08/11/2026); o pg_cron abre uma conexão por rodada.';
revoke all on function privado.consumir_registro_acesso(integer) from public, anon, authenticated;
grant execute on function privado.consumir_registro_acesso(integer) to service_role;

create or replace function privado.definir_coleta_registro_acesso(p_ligada boolean) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot text := privado.slot_registro_acesso();
begin
  if p_ligada is null then
    raise exception 'p_ligada não pode ser nulo' using errcode = '22004';
  end if;
  if p_ligada then
    -- O slot nasce antes da chave: nenhuma mensagem se perde entre ligar e o 1º consumo.
    -- E antes de qualquer escrita desta transação (o Postgres exige).
    if not exists (select 1 from pg_catalog.pg_replication_slots s where s.slot_name = v_slot) then
      perform pg_create_logical_replication_slot(v_slot, 'test_decoding');
    end if;
    update privado.registro_acesso_coleta
       set ligada = true, alterada_em = privado.agora(), consumido_em = privado.agora()
     where unica;
  else
    update privado.registro_acesso_coleta set ligada = false, alterada_em = privado.agora() where unica;
    if exists (select 1 from pg_catalog.pg_replication_slots s where s.slot_name = v_slot) then
      perform pg_drop_replication_slot(v_slot);
    end if;
  end if;
  return (select jsonb_build_object('ligada', c.ligada, 'alterada_em', c.alterada_em,
                                    'slot', exists (select 1 from pg_catalog.pg_replication_slots s where s.slot_name = v_slot))
            from privado.registro_acesso_coleta c);
end $$;

comment on function privado.definir_coleta_registro_acesso(boolean) is
  'Liga ou desliga a coleta de registros de acesso. Ligar cria o slot lógico antes de virar a chave; desligar vira a chave e derruba o slot (sem coleta, nada retém WAL). Operação manual do Prod: na segunda, depois do max_slot_wal_keep_size de 256 MB aplicado e lido de volta, e com a prova de que um GET grava o cf-connecting-ip.';
revoke all on function privado.definir_coleta_registro_acesso(boolean) from public, anon, authenticated;
grant execute on function privado.definir_coleta_registro_acesso(boolean) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 8. Limpeza de 6 meses em lotes, com a guarda legal (mesma assinatura e mesma chamada)
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
  v_agora       timestamptz := privado.agora();
  v_limite_data timestamptz;
  v_total       integer := 0;
  v_lote        integer;
  v_lotes       integer := 0;
  -- Teto por execução: 100 lotes (100 mil linhas com o lote padrão). O que sobrar sai na rodada seguinte.
  c_teto_lotes  constant integer := 100;
begin
  -- Piso de 6 meses (Marco Civil art. 15): nenhum parâmetro encurta.
  if p_meses is null or p_meses < 6 then
    p_meses := 6;
  end if;
  if p_limite is null or p_limite < 1 then
    p_limite := 1000;
  end if;
  v_limite_data := v_agora - make_interval(months => p_meses);

  loop
    delete from privado.registro_acesso r
     where r.ctid = any (array(
       select x.ctid
         from privado.registro_acesso x
        where x.acessado_em <= v_limite_data
          -- Guarda legal (MCI art. 15, § 2º): a conta em guarda vigente fica.
          and not exists (select 1 from privado.registro_acesso_guarda g
                           where g.usuario_id = x.usuario_id
                             and g.desde <= v_agora and v_agora < g.ate)
        limit p_limite
        for update skip locked));
    get diagnostics v_lote = row_count;
    v_total := v_total + v_lote;
    v_lotes := v_lotes + 1;
    exit when v_lote < p_limite or v_lotes >= c_teto_lotes;
  end loop;

  return v_total;
end $$;

comment on function privado.limpar_registros_acesso(integer, integer) is
  'Expurga registros de acesso com mais de 6 meses contados da linha (Marco Civil art. 15), inclusive de conta excluída, em lotes com SKIP LOCKED repetidos até esvaziar, com teto de 100 lotes por execução. Pula as contas em guarda legal vigente (privado.registro_acesso_guarda, MCI art. 15, § 2º). Piso de 6 meses que nenhum parâmetro encurta.';
revoke all on function privado.limpar_registros_acesso(integer, integer) from public, anon, authenticated;
grant execute on function privado.limpar_registros_acesso(integer, integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 9. privado.verificar_saude: autoproteção do slot (item 0) e dois alertas novos (item 11)
--    Corpo igual ao de 20261020100000 (a última definição na develop), mais os itens 0 e 11.
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
  v_coleta                privado.registro_acesso_coleta%rowtype;
  v_atraso_mb             numeric;
begin
  -- 0. Autoproteção do slot do registro de acessos (20261108110000). Vem antes de qualquer alerta, porque recriar
  --    o slot exige uma transação sem escrita. Se falhar aqui, o item 11 ainda alerta pelo atraso.
  begin
    perform privado.proteger_slot_registro_acesso('verificar_saude');
  exception when others then
    null;
  end;

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

  -- 11. Registro de acessos (Marco Civil art. 15, 20261108110000), só com a coleta ligada:
  --  a) o consumidor não consome há mais de 15 minutos;
  --  b) o atraso do slot passou da metade do teto (a autoproteção derruba no teto).
  -- Os buracos já entram em privado.falha_execucao e acendem o item 6.
  begin
    select c.* into v_coleta from privado.registro_acesso_coleta c where c.unica;
    if coalesce(v_coleta.ligada, false) then
      if coalesce(v_coleta.consumido_em, v_coleta.alterada_em) < v_agora - interval '15 minutes' then
        if privado.emitir_alerta('registro_acesso_parado', jsonb_build_object(
             'valor', round(extract(epoch from v_agora - coalesce(v_coleta.consumido_em, v_coleta.alterada_em)) / 60),
             'unidade', 'minutos')) then
          v_alertas := v_alertas + 1;
        end if;
      end if;
      -- Pelo restart_lsn, que é o que retém o WAL (Lince AG 2, E7b).
      select round(pg_wal_lsn_diff(pg_current_wal_lsn(), s.restart_lsn) / 1048576.0, 1)
        into v_atraso_mb
        from pg_catalog.pg_replication_slots s
       where s.slot_name = privado.slot_registro_acesso();
      if v_atraso_mb is not null and v_atraso_mb > v_coleta.teto_wal_mb / 2.0 then
        if privado.emitir_alerta('registro_acesso_wal_atrasado', jsonb_build_object(
             'valor', v_atraso_mb, 'teto_mb', v_coleta.teto_wal_mb)) then
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
  'Varre filas pgmq, falhas de cron, notificações com erro (incluindo NOT_FOUND do FCM), despachos retidos, falhas de execução, denúncias sem moderação após 24h (Diretriz 1.2), contestações vencidas (RN13), falhas assíncronas do pg_net, tentativas recusadas de demonstração (Item 19) e o registro de acessos (autoproteção do slot lógico no começo; consumidor parado há mais de 15 min; atraso do slot acima da metade do teto). Emite alertas à equipe por e-mail com limite de 1/hora por tipo.';

revoke execute on function privado.verificar_saude() from public, anon, authenticated;
grant  execute on function privado.verificar_saude() to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 10. O consumidor no pg_cron, a cada minuto (barato com a coleta desligada: lê a chave e volta)
-- ─────────────────────────────────────────────────────────────────────────────
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('consumir_registro_acesso')
      where exists (select 1 from cron.job where jobname = 'consumir_registro_acesso');
    perform cron.schedule(
      'consumir_registro_acesso',
      '* * * * *',
      'select privado.consumir_registro_acesso()'
    );
  end if;
end $$;
