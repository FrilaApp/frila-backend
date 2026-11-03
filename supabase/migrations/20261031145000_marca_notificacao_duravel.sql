-- 20261031145000_marca_notificacao_duravel.sql
--
-- Higiene e conformidade LGPD (K-001, K-001d, K-001g, K-001l / D1, N1):
-- Tabela de marca durável e gatilho de inserção (privado.marca_notificacao).
--
-- Separação da DDL e lock (D1):
-- Esta migração cria a tabela de marcas e o gatilho, e realiza o backfill das marcas
-- preexistentes de public.notificacao em transação dedicada.
-- A tabela public.despacho NÃO é tocada nesta migração, garantindo que nenhum
-- lock exclusivo (AccessExclusiveLock) seja mantido em public.despacho durante a varredura
-- e backfill histórico de notificações.
--
-- Garantia contra perda de marcas em paralelo:
-- O gatilho trg_notificacao_marca é instalado ANTES do preenchimento histórico (backfill).
-- Qualquer notificação inserida concorrentemente durante o processo já é capturada pelo gatilho,
-- e o comando INSERT ... SELECT subsequente usa ON CONFLICT DO NOTHING, assegurando completude
-- sem duplicidade nem lacunas.

-- 1. Tabela durável de marca de envio que sobrevive ao expurgo de 60 dias de public.notificacao (K-001d)
create table if not exists privado.marca_notificacao (
  tipo           public.tipo_notificacao not null,
  referencia_id  uuid not null,
  usuario_id     uuid not null,
  rodada         integer not null default 1,
  criada_em      timestamptz not null default now(),
  primary key (tipo, referencia_id, usuario_id, rodada)
);

comment on table privado.marca_notificacao is
  'Registro durável de deduplicação de avisos (RN23, K-001d, K-001l). Não contém dados de payload ou mensagens e sobrevive à purga de 60 dias.';

-- Defesa em profundidade RLS e privilégios mínimos (auditoria-rls achado 1)
alter table privado.marca_notificacao enable row level security;
revoke all on table privado.marca_notificacao from public, anon, authenticated;
grant select, insert, update, delete on table privado.marca_notificacao to service_role;

-- 2. Trigger para gravar automaticamente a marca durável em qualquer inserção de notificacao
create or replace function privado.gravar_marca_notificacao()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if NEW.tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                  'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                  'vaga') then
    insert into privado.marca_notificacao (tipo, referencia_id, usuario_id, rodada, criada_em)
    values (NEW.tipo, NEW.referencia_id, NEW.usuario_id, coalesce(NEW.rodada, 1), coalesce(NEW.enviada_em, privado.agora()))
    on conflict (tipo, referencia_id, usuario_id, rodada) do nothing;
  end if;
  return NEW;
end $$;

drop trigger if exists trg_notificacao_marca on public.notificacao;
create trigger trg_notificacao_marca
  after insert on public.notificacao
  for each row
  execute function privado.gravar_marca_notificacao();

-- 3. Popula marcas preexistentes (backfill executado com gatilho ativo para capturar paralelas)
insert into privado.marca_notificacao (tipo, referencia_id, usuario_id, rodada, criada_em)
select n.tipo, n.referencia_id, n.usuario_id, n.rodada, n.enviada_em
  from public.notificacao n
 where n.tipo in ('lembrete_24h', 'lembrete_3h', 'inicio_sem_checkin', 'atraso_15min',
                  'fim_sem_checkout', 'vaga_vazia', 'avaliacao_disponivel', 'vaga_sem_elegiveis',
                  'vaga')
on conflict (tipo, referencia_id, usuario_id, rodada) do nothing;
