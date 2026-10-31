-- 20261031150000_purga_notificacoes_60_dias.sql
--
-- Higiene e conformidade LGPD (K-001, PR #614 do frila-frontend, E11):
-- Purga periódica de notificações com mais de 60 dias (public.notificacao).
--
-- 1. Contexto e Justificativa de Negócio / LGPD:
--    A tabela public.notificacao armazena histórico de despachos, confirmações, lembretes
--    e avisos operacionais com metadados de entrega e identificadores de destinatário.
--    O Registro de Tratamento de Dados (ROPA / LGPD art. 37) prevê política de retenção
--    máxima de 60 dias para notificações da conta.
--
-- 2. Compatibilidade com Regras de Negócio e RN23:
--    - A cadência de notificações (RN23) estabelece intervalo de teto (teto_janela = 30 minutos)
--      e antecedência de urgência (urgente_antecedencia = 2 horas).
--    - A janela de retenção de 60 dias é ordens de grandeza superior a qualquer janela de teto
--      ou agrupamento da RN23, preservando a integridade das decisões de push e métricas.
--
-- 3. Integridade Referencial (public.despacho):
--    - A coluna public.despacho.notificacao_id referencia public.notificacao(id).
--    - A função ativa sessão com privado.retencao = 'on' (RF25) e anula notificacao_id
--      nos despachos correspondentes às notificações que cruzaram a borda de 60 dias,
--      permitindo a remoção em lote sem violar o gatilho privado.despacho_imutavel().
--    - A chave estrangeira despacho_notificacao_id_fkey é ajustada para ON DELETE SET NULL.
--
-- 4. Agendamento Automático:
--    - Agendado no pg_cron com o nome 'limpar_notificacoes_antigas' às 06:19 UTC ('19 6 * * *'),
--      fora da janela de tráfego quente (RNF12), no mesmo padrão de limpar_dispositivos_inativos.

-- Ajusta chave estrangeira para desvincular despachos automaticamente em remoções sob retenção
alter table public.despacho
  drop constraint if exists despacho_notificacao_id_fkey,
  add constraint despacho_notificacao_id_fkey
    foreign key (notificacao_id)
    references public.notificacao(id)
    on delete set null;

create or replace function privado.limpar_notificacoes_antigas(p_dias integer default 60)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_removidos integer := 0;
  v_limite timestamptz;
begin
  if p_dias is null or p_dias < 1 then
    p_dias := 60;
  end if;

  v_limite := privado.agora() - (p_dias || ' days')::interval;

  -- Sinaliza retenção autorizada para que desvinculação em despacho passe pelo gatilho despacho_imutavel (RF25)
  perform set_config('privado.retencao', 'on', true);

  -- 1. Desvincula despachos apontando para notificações com mais de p_dias
  update public.despacho
     set notificacao_id = null
   where notificacao_id in (
     select n.id
       from public.notificacao n
      where n.enviada_em < v_limite
   );

  -- 2. Purga notificações com mais de p_dias
  delete from public.notificacao n
   where n.enviada_em < v_limite;
  get diagnostics v_removidos = row_count;

  perform set_config('privado.retencao', 'off', true);

  return v_removidos;
end $$;

comment on function privado.limpar_notificacoes_antigas(integer) is
  'Purga notificações enviadas há mais de p_dias (padrão 60 dias, conforme ROPA da LGPD) e desvincula despachos associados sob sinal privado.retencao=on (RF25, RN23). Rodada diariamente pelo pg_cron.';

revoke execute on function privado.limpar_notificacoes_antigas(integer) from public, anon, authenticated;
grant  execute on function privado.limpar_notificacoes_antigas(integer) to service_role;

-- Agendamento diário às 06:19 UTC (03:19 BRT), fora da janela protegida por RNF12
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('limpar_notificacoes_antigas')
      where exists (select 1 from cron.job where jobname = 'limpar_notificacoes_antigas');
    perform cron.schedule(
      'limpar_notificacoes_antigas',
      '19 6 * * *',
      'select privado.limpar_notificacoes_antigas()'
    );
  end if;
end $$;
