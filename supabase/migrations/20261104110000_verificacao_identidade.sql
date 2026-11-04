-- Verificação progressiva de identidade: a tabela de controle e o estado (RN14, RN13).
-- Cartão aEqry9vB · requisitos: `frila-docs/requisitos/verificacao-progressiva-rn14.md`
-- (PR frila-docs#141) e `frila-docs/arquitetura/desenho-verificacao-progressiva-rn14.md`.
--
-- O que esta migração faz, e o que ela deliberadamente NÃO faz.
--
-- Faz: o enum de estado, a tabela do schema `privado`, a coluna do selo em
-- `public.profissional`, e nada mais. Sem RPC, sem política de upload, sem fluxo.
--
-- Não faz: não cria exigência para ninguém. Toda conta existente continua sem linha
-- nesta tabela, e a ausência de linha significa `nao_exigida`. Uma migração que
-- inserisse linha `pendente` para contas existentes criaria, por efeito colateral de
-- deploy, a barreira que a RN14 proíbe.
--
-- A RN14 diz que o cadastro mínimo não exige mais do que o necessário para receber a
-- primeira notificação, e que a verificação é progressiva. Em consequência, o Nível 2
-- (documento oficial) só nasce de denúncia grave apurada (RN13), e o Nível 3 (selo) só
-- nasce de pedido do profissional. Esta tabela registra os dois, e não dispara nenhum.

-- ── 1. O estado ───────────────────────────────────────────────────────────────

do $$
begin
  if not exists (select 1 from pg_type t
                   join pg_namespace n on n.oid = t.typnamespace
                  where n.nspname = 'public' and t.typname = 'status_verificacao') then
    create type public.status_verificacao as enum
      ('nao_exigida', 'pendente', 'em_analise', 'aprovada', 'rejeitada');
  end if;
end $$;

comment on type public.status_verificacao is
  'Estado da verificação de identidade de uma conta (RN14). Cinco estados e nenhum deles é "suspensa": suspender conta é assunto da RN13 e fica onde já está, para o estado da verificação não virar, por tabela, um mecanismo de punição.';

-- ── 2. A tabela ───────────────────────────────────────────────────────────────

create table if not exists privado.verificacao_identidade (
  id                   uuid primary key default gen_random_uuid(),
  usuario_id           uuid not null references public.usuario(id) on delete cascade,
  status               public.status_verificacao not null default 'pendente',
  nivel                smallint not null,
  motivo               text,
  ocorrencia_id        uuid references public.ocorrencia(id),
  documento_tipo       text,
  documento_hmac       bytea,
  storage_path_frente  text,
  storage_path_verso   text,
  storage_path_selfie  text,
  solicitado_em        timestamptz not null default privado.agora(),
  prazo_envio_ate      timestamptz,
  respondido_em        timestamptz,
  expurgo_midia_em     timestamptz,
  expurgo_pedido_em    timestamptz,
  expurgo_feito_em     timestamptz,
  expurgo_tentativas   smallint not null default 0,

  -- O nível 1 é o onboarding leve, que não produz registro aqui: quem não tem linha está
  -- no nível 1. O 4 é do contratante, que não é profissional e não entra nesta tabela.
  constraint verificacao_nivel_valido
    check (nivel in (2, 3)),

  -- Nível 2 é reativo: nasce de denúncia apurada, então exige o motivo escrito. Nível 3 é
  -- voluntário e não precisa de motivo nenhum.
  constraint verificacao_n2_tem_motivo
    check (nivel <> 2 or (motivo is not null and length(btrim(motivo)) > 0)),

  -- Catálogo fechado de documento, igual ao desenho: RG, CNH ou CIN.
  constraint verificacao_documento_tipo_valido
    check (documento_tipo is null or documento_tipo in ('rg', 'cnh', 'cin')),

  -- Desfecho e data de desfecho andam juntos: `aprovada` sem `respondido_em` deixaria o
  -- prazo de expurgo sem âncora, e é do desfecho que os 30 dias contam.
  constraint verificacao_desfecho_datado
    check ((status in ('aprovada', 'rejeitada')) = (respondido_em is not null)),

  -- Mídia guardada tem prazo gravado na própria linha. Sem isto, o expurgo dependeria de
  -- alguém lembrar, e o que depende de lembrar não acontece.
  constraint verificacao_midia_tem_prazo
    check (
      (storage_path_frente is null and storage_path_verso is null and storage_path_selfie is null)
      or expurgo_midia_em is not null
    ),

  constraint verificacao_expurgo_feito_depois_do_pedido
    check (expurgo_feito_em is null or expurgo_pedido_em is not null),

  constraint verificacao_prazo_depois_da_solicitacao
    check (prazo_envio_ate is null or prazo_envio_ate > solicitado_em)
);

comment on table privado.verificacao_identidade is
  'Registro de verificação de identidade do profissional (RN14). Ausência de linha significa nao_exigida: o nível 1 (onboarding leve) não produz registro. Nível 2 nasce de denúncia grave apurada (RN13); nível 3 nasce de pedido do profissional. Guarda caminho de mídia com prazo de expurgo, nunca o número do documento em claro.';

comment on column privado.verificacao_identidade.nivel is
  'Nível da RN14: 2 (integridade reativa por denúncia) ou 3 (selo voluntário). O nível 1 não registra e o 4 é do contratante.';
comment on column privado.verificacao_identidade.documento_hmac is
  'HMAC-SHA256 do número do documento, com pepper do Vault. O número em claro não é persistido em coluna, log ou backup. Serve para impedir que o mesmo documento aprove duas contas.';
comment on column privado.verificacao_identidade.expurgo_midia_em is
  'Quando a mídia vence: 30 dias do desfecho, ou 15 dias da solicitação quando a análise não conclui (teto preventivo). privado.expurgar_midias_verificacao_identidade() lê daqui.';
comment on column privado.verificacao_identidade.expurgo_feito_em is
  'Quando o arquivo deixou de existir no Storage, confirmado por quem apagou. Enquanto for nulo com expurgo_pedido_em preenchido, o arquivo pode ainda estar no bucket: apagar a linha do Postgres não apaga o byte no Storage.';
comment on column privado.verificacao_identidade.ocorrencia_id is
  'A denúncia apurada que motivou a exigência de nível 2 (public.ocorrencia, tipo = denuncia). Nulo no nível 3, que é voluntário.';

-- Uma exigência aberta por conta e por nível: duas linhas `pendente` para a mesma pessoa
-- no mesmo nível seriam duas contagens de prazo para o mesmo pedido.
create unique index if not exists verificacao_identidade_aberta_unica
  on privado.verificacao_identidade (usuario_id, nivel)
  where status in ('pendente', 'em_analise');

-- O mesmo documento não aprova duas contas (deduplicação do desenho, risco 1). A
-- restrição vale sobre o aprovado, e não sobre a tentativa: duas pessoas enviando o mesmo
-- documento podem ter as duas linhas em análise, e a moderação decide qual é a legítima.
-- Impedir no envio diria a um fraudador qual documento já está em uso.
create unique index if not exists verificacao_identidade_documento_aprovado_unico
  on privado.verificacao_identidade (documento_hmac)
  where status = 'aprovada' and documento_hmac is not null;

create index if not exists verificacao_identidade_por_usuario
  on privado.verificacao_identidade (usuario_id, solicitado_em desc);

-- A consulta do expurgo: quem venceu e ainda tem caminho de mídia.
create index if not exists verificacao_identidade_expurgo_devido
  on privado.verificacao_identidade (expurgo_midia_em)
  where expurgo_feito_em is null;

-- ── 3. RLS e permissão ────────────────────────────────────────────────────────
--
-- Mesmo desenho das outras tabelas de `privado` (`20261017190000_rls_tabelas_privado.sql`):
-- RLS ligado, nenhuma política, nenhum grant para `anon` e `authenticated`. Sem política,
-- um GRANT concedido por engano não devolve linha. `service_role` tem `rolbypassrls` e
-- enxerga a tabela pelo grant abaixo, que é o caminho da moderação.
--
-- Sem FORCE ROW LEVEL SECURITY: forçar tiraria o bypass do dono e quebraria as funções
-- SECURITY DEFINER que leem a tabela. Os testes 738 e 785 cobrem os dois invariantes.

revoke all on table privado.verificacao_identidade from public, anon, authenticated;
alter table privado.verificacao_identidade enable row level security;

grant select, insert, update on table privado.verificacao_identidade to service_role;

-- Sem `delete` para `service_role`, de propósito: a linha é registro de apuração
-- (RNF13). O que sai é a mídia, por expurgo datado, não o histórico do caso.

-- ── 4. O selo no perfil ───────────────────────────────────────────────────────

alter table public.profissional
  add column if not exists identidade_verificada boolean not null default false;

comment on column public.profissional.identidade_verificada is
  'Selo do nível 3 da RN14, voluntário. É informação de reputação, nunca ordenação nem filtro (RN06): quem não tem selo concorre igual. Revogado o consentimento, volta a false.';

-- ── 5. O número do documento, sem o número ────────────────────────────────────
--
-- CPF tem 11 dígitos e RG menos que isso: o espaço de busca é pequeno o bastante para
-- hash sem segredo ser invertido por força bruta num notebook. Daí HMAC-SHA256 com
-- *pepper* de servidor, guardado no Vault e nunca em migração, variável de cliente ou
-- arquivo versionado.
--
-- Segredo ausente levanta exceção, e não devolve nulo. O caminho silencioso aqui seria o
-- pior dos dois: gravar linha sem `documento_hmac` significa deduplicação que não
-- acontece, e ninguém descobre até o segundo cadastro com o mesmo RG ser aprovado.

create or replace function privado.documento_hmac(p_numero text)
returns bytea
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_pepper text;
  v_limpo  text;
begin
  -- Só dígito e letra: pontuação de CPF ("123.456.789-00" e "12345678900") não pode
  -- gerar dois hashes diferentes para o mesmo documento, ou a deduplicação não vale nada.
  v_limpo := upper(regexp_replace(coalesce(p_numero, ''), '[^0-9A-Za-z]', '', 'g'));
  if length(v_limpo) < 5 then
    raise exception 'documento_invalido' using errcode = '22023';
  end if;

  select decrypted_secret into v_pepper
    from vault.decrypted_secrets
   where name = 'documento_pepper'
   limit 1;

  if v_pepper is null or btrim(v_pepper) = '' then
    raise exception 'pepper_ausente' using errcode = 'P0002',
      detail = 'configure o segredo documento_pepper no Vault antes de verificar identidade';
  end if;

  return extensions.hmac(v_limpo, v_pepper, 'sha256');
end $$;

comment on function privado.documento_hmac(text) is
  'HMAC-SHA256 do número do documento com pepper do Vault (documento_pepper). Normaliza pontuação antes de somar, para o mesmo documento não gerar dois hashes. Pepper ausente é erro: hash sem segredo em espaço de 11 dígitos é reversível, e gravar sem hash seria deduplicação que não acontece.';

revoke execute on function privado.documento_hmac(text) from public, anon, authenticated;
grant  execute on function privado.documento_hmac(text) to service_role;

-- Trocar o `documento_pepper` invalida todos os hashes anteriores e, com eles, a
-- deduplicação. Rotação é migração de dados, não ajuste operacional: exige recalcular a
-- partir de números que o Frila deliberadamente não tem. Em outras palavras, o pepper é
-- de rotação única por vida do acervo, e isso é consequência aceita do desenho.

-- ── 6. O bucket ───────────────────────────────────────────────────────────────
--
-- Privado, com teto de 5 MB por arquivo, e sem política nenhuma: `storage.objects` já tem
-- RLS, e sem política `anon` e `authenticated` não leem nem escrevem. A política de
-- INSERT por `auth.uid()` nasce junto com a RPC de upload, em cartão próprio — criar aqui
-- uma permissão de escrita sem o fluxo que a usa seria abrir porta antes da porta existir.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos-identidade', 'documentos-identidade', false, 5242880,
        array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do nothing;

-- ── 7. Expurgo da mídia ───────────────────────────────────────────────────────
--
-- A ARMADILHA DESTE CARTÃO, e a razão deste trecho ser em duas fases.
--
-- Apagar a linha de `storage.objects` não apaga o byte no Storage: o arquivo vive no
-- backend de objetos, e quem o remove é a API do Storage. Uma função que fizesse
-- `delete from storage.objects` e devolvesse "expurgado: 12" entregaria exatamente o pior
-- resultado possível em LGPD — o registro de que a foto foi apagada, com a foto no bucket.
-- O índice perdido também tornaria o arquivo inalcançável, e portanto impossível de
-- apagar depois.
--
-- Então: a função do banco ENFILEIRA o pedido e marca `expurgo_pedido_em`. Quem apaga é a
-- Edge Function com `service_role`, que chama `privado.confirmar_expurgo_midia` ao
-- terminar; só então os caminhos viram nulos e `expurgo_feito_em` é gravado.
--
-- O silêncio que isso cria, e como ele é quebrado: se a Edge Function nunca confirmar, a
-- linha fica com caminho e sem `expurgo_feito_em` — ou seja, foto vencida no bucket, sem
-- ninguém sabendo. Por isso o pedido é reenfileirado a cada 24 h e, da quinta tentativa
-- em diante, cada rodada registra em `privado.falha_execucao`, que é o que o
-- monitoramento já lê.

-- Idempotente: `pgmq.create` numa fila que já existe levanta erro, e esta migração pode
-- ser reaplicada num banco que já a tenha (foi o caso do realinhamento do frila-prod em
-- 20261104100000).
do $$
begin
  if not exists (select 1 from pgmq.list_queues() where queue_name = 'expurgo_midia') then
    perform pgmq.create('expurgo_midia');
  end if;
end $$;

create or replace function privado.confirmar_expurgo_midia(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ok boolean;
begin
  update privado.verificacao_identidade v
     set storage_path_frente = null,
         storage_path_verso  = null,
         storage_path_selfie  = null,
         expurgo_feito_em    = coalesce(v.expurgo_feito_em, privado.agora())
   where v.id = p_id
     and v.expurgo_pedido_em is not null
  returning true into v_ok;

  -- Idempotente: confirmar duas vezes devolve `true` e não reescreve a data, porque a
  -- Edge Function pode repetir a entrega da mesma mensagem da fila.
  return coalesce(v_ok, false);
end $$;

comment on function privado.confirmar_expurgo_midia(uuid) is
  'Fecha o expurgo de mídia depois que o arquivo saiu do Storage: anula os caminhos e grava expurgo_feito_em. Chamada pela Edge Function que apagou o objeto, nunca antes, porque anular o caminho antes da remoção deixaria o arquivo órfão e inalcançável. Idempotente.';

revoke execute on function privado.confirmar_expurgo_midia(uuid) from public, anon, authenticated;
grant  execute on function privado.confirmar_expurgo_midia(uuid) to service_role;

create or replace function privado.expurgar_midias_verificacao_identidade(p_limite integer default 200)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_agora      timestamptz := privado.agora();
  v_pedidos    integer := 0;
  v_reenvios   integer := 0;
  v_registro   record;
  v_atrasados  integer := 0;
begin
  for v_registro in
    select v.id, v.usuario_id,
           v.storage_path_frente, v.storage_path_verso, v.storage_path_selfie,
           v.expurgo_pedido_em, v.expurgo_tentativas
      from privado.verificacao_identidade v
     where v.expurgo_feito_em is null
       and v.expurgo_midia_em is not null
       and v.expurgo_midia_em <= v_agora
       and (v.storage_path_frente is not null
            or v.storage_path_verso is not null
            or v.storage_path_selfie is not null)
       -- Reenfileira só depois de 24 h sem confirmação: a Edge Function tem a rodada
       -- inteira para responder, e a fila não vira repetição de si mesma.
       and (v.expurgo_pedido_em is null or v.expurgo_pedido_em <= v_agora - interval '24 hours')
     order by v.expurgo_midia_em
     limit greatest(p_limite, 1)
     for update
  loop
    perform pgmq.send('expurgo_midia', jsonb_build_object(
      'verificacao_id', v_registro.id,
      'bucket',         'documentos-identidade',
      -- Caminho de arquivo, nunca o conteúdo e nunca o número do documento: a mensagem da
      -- fila é lida por quem opera a fila.
      'caminhos',       array_remove(array[v_registro.storage_path_frente,
                                           v_registro.storage_path_verso,
                                           v_registro.storage_path_selfie], null),
      'tentativa',      v_registro.expurgo_tentativas + 1
    ));

    update privado.verificacao_identidade
       set expurgo_pedido_em  = v_agora,
           expurgo_tentativas = expurgo_tentativas + 1
     where id = v_registro.id;

    if v_registro.expurgo_pedido_em is null then
      v_pedidos := v_pedidos + 1;
    else
      v_reenvios := v_reenvios + 1;
    end if;

    -- Da quinta tentativa em diante, o atraso deixa de ser silêncio e vira falha
    -- registrada: mídia vencida que não sai do bucket é passivo de LGPD, não detalhe
    -- operacional.
    if v_registro.expurgo_tentativas + 1 >= 5 then
      v_atrasados := v_atrasados + 1;
      perform privado.registrar_falha_execucao(
        'expurgar_midias_verificacao_identidade',
        'expurgo_midia_nao_confirmado',
        jsonb_build_object('verificacao_id', v_registro.id,
                           'tentativas',     v_registro.expurgo_tentativas + 1)
      );
    end if;
  end loop;

  return jsonb_build_object(
    'executado_em',       v_agora,
    'pedidos_novos',      v_pedidos,
    'pedidos_reenviados', v_reenvios,
    'atrasados_5x',       v_atrasados
  );
end $$;

comment on function privado.expurgar_midias_verificacao_identidade(integer) is
  'Enfileira em pgmq (expurgo_midia) a remoção das mídias de verificação vencidas (expurgo_midia_em no passado) e marca expurgo_pedido_em. NÃO apaga arquivo: apagar a linha de storage.objects não apaga o byte no Storage, e quem remove é a Edge Function com service_role, que confirma por privado.confirmar_expurgo_midia. Reenfileira a cada 24 h sem confirmação e, da quinta tentativa em diante, registra em privado.falha_execucao.';

revoke execute on function privado.expurgar_midias_verificacao_identidade(integer) from public, anon, authenticated;
grant  execute on function privado.expurgar_midias_verificacao_identidade(integer) to service_role;

-- ── 8. O prazo entra na rotina diária que já existe ───────────────────────────
--
-- Não há cron novo: `privado.executar_retencao_diaria()` já roda às 06:30 UTC pelo job
-- `retencao_e_limpeza_diaria`, e é onde a retenção do produto mora. Um job próprio para
-- isto seria um segundo lugar para olhar quando a mídia não sai.
--
-- A função é reproduzida inteira porque é `create or replace`; o que muda é só a chamada
-- nova e a chave nova no jsonb de retorno.
--
-- A base desta cópia é `20260930180000_telemetria_evento_app.sql`, que é a definição mais
-- recente da função, e não a original de `20260927010000_retencao_e_limpeza.sql`. A
-- primeira versão desta migração copiou a original e, com isso, apagou
-- `privado.limpar_eventos_app(90)` e a chave `eventos_app_limpos` — a telemetria pararia
-- de ser purgada em silêncio, e quem reprovou foi o pgTAP 721. Copiar função de migração
-- antiga é como reverter a mais nova sem dizer.

create or replace function privado.executar_retencao_diaria()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anonimizadas integer;
  v_higiene      jsonb;
  v_eventos_app  integer;
  v_expurgo      jsonb;
begin
  v_anonimizadas := privado.limpar_contas_anonimizadas(15);
  v_higiene      := privado.higienizar_tabelas();
  v_eventos_app  := privado.limpar_eventos_app(90);
  v_expurgo      := privado.expurgar_midias_verificacao_identidade();

  return jsonb_build_object(
    'executado_em',               privado.agora(),
    'contas_anonimizadas_limpas', v_anonimizadas,
    'higiene',                    v_higiene,
    'eventos_app_limpos',         v_eventos_app,
    'expurgo_midia_identidade',   v_expurgo
  );
end $$;

comment on function privado.executar_retencao_diaria() is
  'Rotina consolidada de retenção: contas anonimizadas (15 dias), telemetria de app (90 dias), higienização de tabelas operacionais e enfileiramento do expurgo de mídia de verificação de identidade (RN14). Rodada diariamente pelo pg_cron às 06:30 UTC.';

revoke execute on function privado.executar_retencao_diaria() from public, anon, authenticated;
grant  execute on function privado.executar_retencao_diaria() to service_role;
