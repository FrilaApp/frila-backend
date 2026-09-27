-- Retenção e limpeza dos dados pessoais em 15 dias e contas sem cadastro (RF25, RNF08, RN15, UC09 2a).
-- Cartão yClUqOpU.
--
-- 1. nascimento e ponto_base anuláveis apenas para conta anonimizada (CHECK e gatilho).
-- 2. Rotinas em privado para identificação de contas de autenticação sem cadastro há mais de 24 h.
-- 3. Limpeza transacional pós-15 dias da exclusão: disponibilidade, funções, aparelhos,
--    relato de ocorrências (substituição por marcador neutro), nascimento e ponto_base nulos.
-- 4. Higiene operacional periódica: cron.job_run_details (> 7d) e arquivo pgmq (> 30d).
-- 5. Registro na política de retenção dos logs do provedor de e-mail.

-- ── 1. Esquema: nascimento e ponto_base anuláveis sob anonimização ─────────────

-- Em usuario: nascimento passa a ser anulável, mas exigido para qualquer conta ativa/suspensa.
alter table public.usuario alter column nascimento drop not null;

alter table public.usuario
  add constraint nascimento_ate_anonimizar
  check (estado = 'anonimizada' or nascimento is not null);

comment on column public.usuario.nascimento is
  'Data de nascimento para conferência de maioridade (RN20). Nulo apenas para conta no estado anonimizada após o prazo de retenção de 15 dias (RF25, RN15).';

-- Em profissional: ponto_base passa a ser anulável, validado por gatilho exclusivo.
alter table public.profissional alter column ponto_base drop not null;

create or replace function privado.validar_ponto_base_profissional()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_estado public.estado_conta;
begin
  if new.ponto_base is null then
    select u.estado into v_estado
      from public.usuario u
     where u.id = new.usuario_id;
    if v_estado is distinct from 'anonimizada' then
      raise exception 'ponto_base só pode ser nulo para conta anonimizada (RF25, RN15)'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end $$;

comment on function privado.validar_ponto_base_profissional() is
  'Garante que ponto_base só pode ser nulo para conta no estado anonimizada (RF25, RN15).';

revoke execute on function privado.validar_ponto_base_profissional() from public, anon, authenticated;
grant  execute on function privado.validar_ponto_base_profissional() to service_role;

create trigger profissional_ponto_base_anulavel
  before insert or update of ponto_base, usuario_id on public.profissional
  for each row
  execute function privado.validar_ponto_base_profissional();

-- Ajusta ponto_em_json para aceitar geography nulo sem erro de ponto flutuante.
create or replace function privado.ponto_em_json(g extensions.geography) returns jsonb
language sql
immutable
set search_path = ''
as $$
  select case
    when g is null then null
    else jsonb_build_object(
      'latitude',  round(extensions.ST_Y(g::extensions.geometry)::numeric, 6),
      'longitude', round(extensions.ST_X(g::extensions.geometry)::numeric, 6))
  end;
$$;

comment on function privado.ponto_em_json(extensions.geography) is
  'geography para a Coordenada do contrato, com seis casas. Devolve null se a coordenada de entrada for nula.';

revoke execute on function privado.ponto_em_json(extensions.geography) from public, anon;
grant  execute on function privado.ponto_em_json(extensions.geography) to authenticated, service_role;

-- ── 2. Contas de autenticação sem cadastro (UC09 2a / 24h) ───────────────────

create or replace function privado.contas_auth_orfas(p_horas integer default 24)
returns table (id uuid, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select a.id, a.created_at
    from auth.users a
   where not exists (select 1 from public.usuario u where u.id = a.id)
     and a.created_at < privado.agora() - (p_horas || ' hours')::interval;
$$;

comment on function privado.contas_auth_orfas(integer) is
  'Lista contas de auth.users sem cadastro em public.usuario criadas há mais de p_horas horas (UC09 2a, RF25). Privada para service_role.';

revoke execute on function privado.contas_auth_orfas(integer) from public, anon, authenticated;
grant  execute on function privado.contas_auth_orfas(integer) to service_role;


-- ── 3. Retenção de 15 dias para contas anonimizadas ───────────────────────────

create or replace function privado.limpar_contas_anonimizadas(p_dias integer default 15)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_candidato record;
  v_total     integer := 0;
begin
  for v_candidato in
    select u.id, p.id as profissional_id
      from public.usuario u
      left join public.profissional p on p.usuario_id = u.id
     where u.estado = 'anonimizada'
       and u.anonimizado_em <= privado.agora() - (p_dias || ' days')::interval
       and (
         u.nascimento is not null
         or p.ponto_base is not null
         or exists (select 1 from public.disponibilidade d where d.profissional_id = p.id)
         or exists (select 1 from public.profissional_funcao pf where pf.profissional_id = p.id)
         or exists (select 1 from public.dispositivo disp where disp.usuario_id = u.id)
         or exists (select 1 from public.ocorrencia o where o.autor_id = u.id and o.motivo <> '[removido por exclusão de conta]')
       )
  loop
    -- Ativa sinal de sessão para permitir substituição do relato na ocorrência imutável
    perform set_config('privado.retencao', 'on', true);

    -- 1. Apaga disponibilidade semanal, funções e ponto base do profissional
    if v_candidato.profissional_id is not null then
      delete from public.disponibilidade where profissional_id = v_candidato.profissional_id;
      delete from public.profissional_funcao where profissional_id = v_candidato.profissional_id;
      update public.profissional
         set ponto_base = null
       where id = v_candidato.profissional_id;
    end if;

    -- 2. Apaga aparelhos registrados
    delete from public.dispositivo where usuario_id = v_candidato.id;

    -- 3. Substitui relato das ocorrências de autoria dela pelo marcador neutro
    update public.ocorrencia
       set motivo = '[removido por exclusão de conta]'
     where autor_id = v_candidato.id
       and motivo <> '[removido por exclusão de conta]';

    -- 4. Zera data de nascimento
    update public.usuario
       set nascimento = null
     where id = v_candidato.id;

    perform set_config('privado.retencao', 'off', true);
    v_total := v_total + 1;
  end loop;

  return v_total;
end $$;

comment on function privado.limpar_contas_anonimizadas(integer) is
  'Apaga disponibilidade, funções, aparelhos, zera nascimento e ponto base, e substitui relato de ocorrências para contas anonimizadas após p_dias dias (RF25, RN15).';

revoke execute on function privado.limpar_contas_anonimizadas(integer) from public, anon, authenticated;
grant  execute on function privado.limpar_contas_anonimizadas(integer) to service_role;

-- ── 4. Higiene operacional das tabelas ────────────────────────────────────────

create or replace function privado.higienizar_tabelas()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cron_removidos integer := 0;
  v_pgmq_removidos integer := 0;
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

  return jsonb_build_object(
    'cron_job_run_details', v_cron_removidos,
    'pgmq_arquivo',         v_pgmq_removidos
  );
end $$;

comment on function privado.higienizar_tabelas() is
  'Higiene operacional periódica: cron.job_run_details (> 7d) e arquivo pgmq (> 30d). Dispositivos inativos são higienizados às 06:17 por rotina dedicada (cartão wpNabtCO).';

revoke execute on function privado.higienizar_tabelas() from public, anon, authenticated;
grant  execute on function privado.higienizar_tabelas() to service_role;

-- ── 5. Execução diária consolidada e agendamento pg_cron ───────────────────────

create or replace function privado.executar_retencao_diaria()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anonimizadas integer;
  v_higiene      jsonb;
begin
  v_anonimizadas := privado.limpar_contas_anonimizadas(15);
  v_higiene      := privado.higienizar_tabelas();

  return jsonb_build_object(
    'executado_em',               privado.agora(),
    'contas_anonimizadas_limpas', v_anonimizadas,
    'higiene',                    v_higiene
  );
end $$;

comment on function privado.executar_retencao_diaria() is
  'Rotina consolidada de retenção de 15 dias e higienização de tabelas operacionais. Rodada diariamente pelo pg_cron.';

revoke execute on function privado.executar_retencao_diaria() from public, anon, authenticated;
grant  execute on function privado.executar_retencao_diaria() to service_role;

-- Agendamento diário às 06:30 UTC (03:30 em Brasília), fora do horário de pico de RNF12
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('retencao_e_limpeza_diaria')
      where exists (select 1 from cron.job where jobname = 'retencao_e_limpeza_diaria');
    perform cron.schedule(
      'retencao_e_limpeza_diaria',
      '30 6 * * *',
      'select privado.executar_retencao_diaria()'
    );
  end if;
end $$;

-- ── 6. Comentários LGPD e política de retenção de logs de e-mail ──────────────

comment on table public.usuario is
  'Conta de acesso. Um perfil por conta, fixo no cadastro (RN25). A exclusão anonimiza em vez de apagar (RF25), porque turno e avaliação pertencem também à contraparte. Em até 15 dias, nascimento, ponto base, disponibilidade, funções e aparelhos são removidos. Logs de envio de e-mail no provedor SMTP possuem política de retenção máxima de 30 dias para fins de entrega e depuração técnica, expirando automaticamente sem cruzamento com dados cadastrais.';
