-- Migração: 20261108030000_lgpd_j6_retencao_e_registros_acesso.sql
-- Escopo: LGPD-J6 (Decisões finais de contratação direta, seção 6).
-- 1. Expurgo de turnos com mais de 5 anos (CF art. 7º XXIX; CC art. 206 § 3º V; LGPD art. 16).
-- 2. Registros de acesso a aplicações de internet (IP, data e hora) sob sigilo por 6 meses (MCI art. 15).
-- 3. Consolidação na rotina diária de retenção e limpeza (privado.executar_retencao_diaria).

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Tabela privado.registro_acesso (Marco Civil da Internet, art. 15)
-- ─────────────────────────────────────────────────────────────────────────────
create table if not exists privado.registro_acesso (
  id bigint generated always as identity primary key,
  usuario_id uuid references public.usuario(id) on delete set null,
  ip inet not null,
  acessado_em timestamptz not null default privado.agora(),
  recurso text,
  user_agent text
);

comment on table privado.registro_acesso is
  'Registros de acesso a aplicações de internet (IP, data e hora) mantidos sob sigilo por 6 meses (180 dias) conforme art. 15 da Lei nº 12.965/2014 (Marco Civil da Internet).';

create index if not exists registro_acesso_acessado_em_idx
  on privado.registro_acesso (acessado_em);

create index if not exists registro_acesso_usuario_idx
  on privado.registro_acesso (usuario_id)
  where usuario_id is not null;

alter table privado.registro_acesso enable row level security;
revoke all on table privado.registro_acesso from public, anon, authenticated;
grant select, insert, delete on table privado.registro_acesso to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Função privado.registrar_acesso
-- ─────────────────────────────────────────────────────────────────────────────
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

  insert into privado.registro_acesso (
    usuario_id,
    ip,
    acessado_em,
    recurso,
    user_agent
  ) values (
    p_usuario_id,
    p_ip,
    privado.agora(),
    p_recurso,
    p_user_agent
  )
  returning id into v_id;

  return v_id;
end $$;

comment on function privado.registrar_acesso(uuid, inet, text, text) is
  'Registra acesso a aplicação de internet com IP e timestamp conforme Marco Civil da Internet (art. 15).';

revoke all on function privado.registrar_acesso(uuid, inet, text, text) from public, anon, authenticated;
grant execute on function privado.registrar_acesso(uuid, inet, text, text) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Função privado.limpar_registros_acesso (6 meses / 180 dias)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.limpar_registros_acesso(p_dias integer default 180)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_total integer := 0;
begin
  if p_dias is null or p_dias < 1 then
    p_dias := 180;
  end if;

  delete from privado.registro_acesso
   where acessado_em < privado.agora() - (p_dias || ' days')::interval;

  get diagnostics v_total = row_count;
  return v_total;
end $$;

comment on function privado.limpar_registros_acesso(integer) is
  'Expurga registros de acesso a aplicações de internet com mais de 6 meses (180 dias por padrão) conforme art. 15 do Marco Civil da Internet.';

revoke all on function privado.limpar_registros_acesso(integer) from public, anon, authenticated;
grant execute on function privado.limpar_registros_acesso(integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Função privado.expurgar_turnos_antigos (5 anos / 1825 dias)
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.expurgar_turnos_antigos(p_dias integer default 1825)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limite_data timestamptz;
  v_turnos_ids uuid[];
  v_total integer := 0;
begin
  if p_dias is null or p_dias < 1 then
    p_dias := 1825;
  end if;

  v_limite_data := privado.agora() - (p_dias || ' days')::interval;

  -- Seleciona turnos cuja posição terminou há mais de p_dias
  select coalesce(array_agg(t.id), '{}')
    into v_turnos_ids
    from public.turno t
    join public.posicao pos on pos.id = t.posicao_id
   where pos.fim_em <= v_limite_data;

  if array_length(v_turnos_ids, 1) is null or array_length(v_turnos_ids, 1) = 0 then
    return 0;
  end if;

  -- Habilita o modo de retenção controlado (RF25, RNF13) para desvinculação e expurgo
  perform set_config('privado.retencao', 'on', true);

  -- Desvincula ocorrências antes de apagar o turno (FK sem cascade)
  update public.ocorrencia
     set turno_id = null
   where turno_id = any(v_turnos_ids);

  -- Apaga os turnos (avaliacao é removida via cascade; evento_app via set null)
  delete from public.turno
   where id = any(v_turnos_ids);

  get diagnostics v_total = row_count;

  perform set_config('privado.retencao', 'off', true);
  return v_total;
end $$;

comment on function privado.expurgar_turnos_antigos(integer) is
  'Expurga turnos concluídos há mais de 5 anos (1825 dias por padrão), removendo avaliações e desvinculando ocorrências conforme CF art. 7º XXIX, CC art. 206 § 3º V e LGPD art. 16.';

revoke all on function privado.expurgar_turnos_antigos(integer) from public, anon, authenticated;
grant execute on function privado.expurgar_turnos_antigos(integer) to service_role;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. Plug na rotina diária consolidada de retenção e limpeza
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function privado.executar_retencao_diaria()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anonimizadas      integer;
  v_higiene           jsonb;
  v_eventos_app       integer;
  v_expurgo_ident     jsonb;
  v_expurgo_perfil    integer;
  v_expurgo_chamada   integer;
  v_expurgo_turnos    integer;
  v_expurgo_acessos   integer;
begin
  v_anonimizadas    := privado.limpar_contas_anonimizadas(15);
  v_higiene         := privado.higienizar_tabelas();
  v_eventos_app     := privado.limpar_eventos_app(90);
  v_expurgo_ident   := privado.expurgar_midias_verificacao_identidade();
  v_expurgo_perfil  := privado.expurgar_midias_recusadas();
  v_expurgo_chamada := privado.limpar_chamadas_expurgadas(90);
  v_expurgo_turnos  := privado.expurgar_turnos_antigos(1825);
  v_expurgo_acessos := privado.limpar_registros_acesso(180);

  return jsonb_build_object(
    'executado_em',                 privado.agora(),
    'contas_anonimizadas_limpas',   v_anonimizadas,
    'higiene',                      v_higiene,
    'eventos_app_limpos',           v_eventos_app,
    'expurgo_midia_identidade',     v_expurgo_ident,
    'expurgo_midia_perfil',         v_expurgo_perfil,
    'expurgo_chamadas_nao_aceitas', v_expurgo_chamada,
    'expurgo_turnos_antigos',       v_expurgo_turnos,
    'expurgo_registros_acesso',     v_expurgo_acessos
  );
end $$;

comment on function privado.executar_retencao_diaria() is
  'Rotina diária consolidada de retenção e limpeza: contas anonimizadas (15 dias), higiene de tabelas, eventos do app (90 dias), expurgo de mídias de identidade e fotos recusadas (24 h), expurgo de chamadas não aceitas (90 dias), expurgo de turnos com mais de 5 anos (1825 dias) e registros de acesso à aplicação com mais de 6 meses (180 dias, Marco Civil art. 15).';

revoke execute on function privado.executar_retencao_diaria() from public, anon, authenticated;
grant  execute on function privado.executar_retencao_diaria() to service_role;
