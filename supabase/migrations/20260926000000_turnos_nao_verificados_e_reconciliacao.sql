-- S2 · Backend · Turnos não verificados, faltas e reconciliação da taxa de comparecimento (A11, RN12, RN22)
--
-- Cartão: https://trello.com/c/NDx7TJ4d
--
-- 1. Tabela privado.divergencia_reputacao para registro de divergências entre cache e histórico.
-- 2. Job pós-fim de turno privado.fechar_turnos_passados: check-in manual sem confirmação vira nao_verificado.
-- 3. Job diário de reconciliação privado.reconciliar_comparecimento: definição canônica da Modelagem (A11).
-- 4. Triggers transacionais mantendo taxa_comparecimento e turnos_realizados em profissional:
--    - após alteração de verificação em public.turno
--    - após cancelamento / alteração de falta em public.posicao
-- 5. Perfil público lê contadores sem agregação na leitura.

-- ── 1. Tabela de divergências da reputação ──────────────────────────────────────────

create table privado.divergencia_reputacao (
  id                  bigint generated always as identity primary key,
  profissional_id     uuid not null references public.profissional(id) on delete cascade,
  taxa_anterior       numeric(4,3),
  taxa_corrigida      numeric(4,3),
  turnos_anterior     integer,
  turnos_corrigido    integer,
  aval_pos_anterior   integer,
  aval_pos_corrigido  integer,
  aval_tot_anterior   integer,
  aval_tot_corrigido  integer,
  registrado_em       timestamptz not null default privado.agora()
);

comment on table privado.divergencia_reputacao is
  'Registro de divergências encontradas pelo job diário de reconciliação de reputação (A11). O histórico é a fonte da verdade e corrige o cache em profissional.';

comment on column privado.divergencia_reputacao.registrado_em is
  'Relógio do produto (privado.agora()), mantendo consistência com o restante do banco em testes com relógio controlado.';

create index divergencia_reputacao_prof on privado.divergencia_reputacao (profissional_id, registrado_em desc);

revoke all on table privado.divergencia_reputacao from public, anon, authenticated;
grant all on table privado.divergencia_reputacao to service_role;

-- ── 2. Fechamento de turnos passados (pós-fim do turno) ──────────────────────────

create or replace function privado.fechar_turnos_passados()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_afetados integer := 0;
  v_agora    timestamptz := privado.agora();
  v_profs    uuid[] := '{}'::uuid[];
  v_novos    uuid[];
  v_prof     uuid;
begin
  -- Marca execução em lote na sessão para os triggers não recalcularem repetidamente por linha O(n²)
  perform set_config('frila.em_lote', 'true', true);

  -- 1. Check-in manual não confirmado até o fim do turno vira nao_verificado (Critério 1).
  with turnos_a_fechar as (
    select t.id, p.profissional_id
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
     where p.fim_em <= v_agora
       and t.verificacao = 'pendente'
       and t.checkin_tipo = 'manual'
  ),
  atualizados as (
    update public.turno t
       set verificacao = 'nao_verificado'
      from turnos_a_fechar taf
     where t.id = taf.id
    returning taf.profissional_id
  )
  select coalesce(
     array_agg(distinct profissional_id) filter (where profissional_id is not null),
     '{}'::uuid[]
  )
     into v_novos
     from atualizados;
  v_profs := v_profs || v_novos;
  v_afetados := cardinality(v_novos);

  -- 2. Transição de posição: confirmada -> cumprida quando o turno terminou e teve check-in registrado
  with posicoes_a_fechar as (
    select p.id, p.profissional_id
      from public.posicao p
      join public.turno t on t.posicao_id = p.id
     where p.estado = 'confirmada'
       and p.fim_em <= v_agora
       and t.checkin_em is not null
  ),
  pos_atualizadas as (
    update public.posicao p
       set estado = 'cumprida'
      from posicoes_a_fechar paf
     where p.id = paf.id
    returning paf.profissional_id
  )
  select coalesce(
     array_agg(distinct profissional_id) filter (where profissional_id is not null),
     '{}'::uuid[]
  )
     into v_novos
     from pos_atualizadas;
  v_profs := v_profs || v_novos;

  -- 3. Recalcula o histórico canônico UMA VEZ por profissional afetado no lote
  for v_prof in select distinct unnest(v_profs)
  loop
     perform privado.recalcular_comparecimento(v_prof);
  end loop;

  perform set_config('frila.em_lote', '', true);

  -- NOTA: O Critério (2) "turno confirmado sem check-in" depende da decisão de produto 8zLfn0mt,
  -- em aberto com Júlia, e permanece bloqueado sem modificações até o alinhamento de produto.

  return v_afetados;
end $$;

comment on function privado.fechar_turnos_passados() is
  'Job pós-fim de turno: transforma check-ins manuais não confirmados em nao_verificado e conclui posições cumpridas. Recalcula reputação uma vez por profissional afetado. Turno sem check-in aguarda decisão 8zLfn0mt.';

revoke execute on function privado.fechar_turnos_passados() from public, anon, authenticated;
grant execute on function privado.fechar_turnos_passados() to service_role;

create or replace function privado.fechar_turnos()
returns integer
language sql
security definer
set search_path = ''
as $$
  select privado.fechar_turnos_passados();
$$;

revoke execute on function privado.fechar_turnos() from public, anon, authenticated;
grant execute on function privado.fechar_turnos() to service_role;

-- ── 3. Triggers transacionais de reputação ───────────────────────────────────────

create or replace function privado.gatilho_turno_recalcular_comparecimento()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prof uuid;
begin
  if current_setting('frila.em_lote', true) = 'true' then
    return new;
  end if;

  if TG_OP = 'INSERT' or (TG_OP = 'UPDATE' and old.verificacao is distinct from new.verificacao) then
    select p.profissional_id into v_prof
      from public.posicao p
     where p.id = new.posicao_id;

    if v_prof is not null then
      perform privado.recalcular_comparecimento(v_prof);
    end if;
  end if;
  return new;
end $$;

revoke execute on function privado.gatilho_turno_recalcular_comparecimento() from public, anon, authenticated;
grant execute on function privado.gatilho_turno_recalcular_comparecimento() to service_role;

drop trigger if exists turno_recalcula_comparecimento on public.turno;
create trigger turno_recalcula_comparecimento
  after insert or update of verificacao on public.turno
  for each row execute function privado.gatilho_turno_recalcular_comparecimento();

create or replace function privado.gatilho_posicao_recalcular_comparecimento()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if current_setting('frila.em_lote', true) = 'true' then
    return new;
  end if;

  if TG_OP = 'UPDATE' then
    if old.profissional_id is not null and old.profissional_id is distinct from new.profissional_id then
      perform privado.recalcular_comparecimento(old.profissional_id);
    end if;

    if new.profissional_id is not null and (
      old.falta is distinct from new.falta
      or old.estado is distinct from new.estado
      or old.profissional_id is distinct from new.profissional_id
    ) then
      perform privado.recalcular_comparecimento(new.profissional_id);
    end if;
  elsif TG_OP = 'INSERT' then
    if new.profissional_id is not null and new.falta then
      perform privado.recalcular_comparecimento(new.profissional_id);
    end if;
  end if;
  return new;
end $$;

revoke execute on function privado.gatilho_posicao_recalcular_comparecimento() from public, anon, authenticated;
grant execute on function privado.gatilho_posicao_recalcular_comparecimento() to service_role;

drop trigger if exists posicao_recalcula_comparecimento on public.posicao;
create trigger posicao_recalcula_comparecimento
  after insert or update of falta, estado, profissional_id on public.posicao
  for each row execute function privado.gatilho_posicao_recalcular_comparecimento();

-- ── 4. Job de reconciliação canônica (A11) ───────────────────────────────────────

create or replace function privado.reconciliar_comparecimento()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_divergencias integer := 0;
  v_taxa_canonico numeric(4,3);
  v_turnos_canonico integer;
  v_faltas_canonico integer;
  v_aval_pos_canonico integer;
  v_aval_tot_canonico integer;
  v_agora timestamptz := privado.agora();
begin
  for r in
    select p.id,
           p.taxa_comparecimento,
           p.turnos_realizados,
           p.aval_positivas,
           p.aval_total
      from public.profissional p
  loop
    -- Definição canônica (A11 da Modelagem de Banco de Dados):
    -- Presença = check-in geolocalizado ou manual confirmado (RN22) -> t.verificacao = 'verificado'
    -- Falta = não aparecer ou cancelar com menos de 24 h -> pos.falta = true
    -- Numerador = turnos com presença
    -- Denominador = turnos com presença + faltas
    select
      coalesce(count(*) filter (where t.verificacao = 'verificado'), 0),
      coalesce(count(*) filter (where pos.falta), 0)
      into v_turnos_canonico, v_faltas_canonico
      from public.posicao pos
      left join public.turno t on t.posicao_id = pos.id
     where pos.profissional_id = r.id;

    if v_turnos_canonico + v_faltas_canonico = 0 then
      v_taxa_canonico := null;
    else
      v_taxa_canonico := round(v_turnos_canonico::numeric / (v_turnos_canonico + v_faltas_canonico), 3);
    end if;

    -- Avaliações canônicas calculadas sobre o histórico de avaliacao
    select
      coalesce(count(*) filter (where a.resposta), 0),
      coalesce(count(*), 0)
      into v_aval_pos_canonico, v_aval_tot_canonico
      from public.avaliacao a
     where a.alvo_tipo = 'profissional'
       and a.alvo_id = r.id;

    -- Compara cache desnormalizado com a fonte da verdade
    if r.taxa_comparecimento is distinct from v_taxa_canonico
       or r.turnos_realizados is distinct from v_turnos_canonico
       or r.aval_positivas is distinct from v_aval_pos_canonico
       or r.aval_total is distinct from v_aval_tot_canonico
    then
      -- 1. Registra a divergência encontrada
      insert into privado.divergencia_reputacao (
        profissional_id,
        taxa_anterior, taxa_corrigida,
        turnos_anterior, turnos_corrigido,
        aval_pos_anterior, aval_pos_corrigido,
        aval_tot_anterior, aval_tot_corrigido,
        registrado_em
      ) values (
        r.id,
        r.taxa_comparecimento, v_taxa_canonico,
        r.turnos_realizados, v_turnos_canonico,
        r.aval_positivas, v_aval_pos_canonico,
        r.aval_total, v_aval_tot_canonico,
        v_agora
      );

      -- 2. Atualiza o cache em profissional: o histórico canônico ganha
      update public.profissional
         set taxa_comparecimento = v_taxa_canonico,
             turnos_realizados   = v_turnos_canonico,
             aval_positivas      = v_aval_pos_canonico,
             aval_total          = v_aval_tot_canonico
       where id = r.id;

      v_divergencias := v_divergencias + 1;
    end if;
  end loop;

  return v_divergencias;
end $$;

comment on function privado.reconciliar_comparecimento() is
  'Job diário de reconciliação com a definição canônica da Modelagem (A11). Compara o cache em profissional com o histórico e registra divergências.';

revoke execute on function privado.reconciliar_comparecimento() from public, anon, authenticated;
grant execute on function privado.reconciliar_comparecimento() to service_role;

create or replace function privado.reconciliar_reputacao()
returns integer
language sql
security definer
set search_path = ''
as $$
  select privado.reconciliar_comparecimento();
$$;

revoke execute on function privado.reconciliar_reputacao() from public, anon, authenticated;
grant execute on function privado.reconciliar_reputacao() to service_role;

-- ── 5. Agendamento com pg_cron (documentado, sem ativação) ───────────────────────
--
-- pg_cron ainda não está ativo no ambiente frila-dev.
-- Quando a extensão for habilitada em produção/dev, o agendamento deve ser registrado:
--
-- 1. Fechamento de turnos passados (a cada 15 minutos):
--    select cron.schedule(
--      'fechar_turnos_passados',
--      '*/15 * * * *',
--      'select privado.fechar_turnos_passados();'
--    );
--
-- 2. Reconciliação diária da reputação (às 04:00 da manhã):
--    select cron.schedule(
--      'reconciliar_reputacao_diaria',
--      '0 4 * * *',
--      'select privado.reconciliar_comparecimento();'
--    );
