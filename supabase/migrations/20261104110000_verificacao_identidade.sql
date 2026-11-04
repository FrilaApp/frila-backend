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
