-- Fundação server-side de autenticação por senha + confiança de dispositivo (30 dias)
-- e trava server-authoritative `precisa_definir_senha`.
--
-- ATENÇÃO — ROLLOUT BLOQUEADO (MODO SOMBRA):
--   privado.config_auth.exigir_dispositivo_verificado nasce FALSE e o hook
--   privado.custom_access_token_hook NÃO é habilitado no projeto remoto nesta migração.
--   O cutover fica bloqueado até todos os clientes (iOS, Android já mesclado na main
--   com GoTrue direto e Web) migrarem para POST /functions/v1/autenticar-senha.

-- ── 1. Tabelas privadas (zero acesso direto por anon/authenticated) ────────────

create table if not exists privado.config_auth (
  unica                         boolean primary key default true check (unica),
  exigir_dispositivo_verificado boolean not null default false,
  corte_sessoes_anteriores_em   timestamptz null,
  atualizado_em                 timestamptz not null default now()
);

insert into privado.config_auth (unica, exigir_dispositivo_verificado, corte_sessoes_anteriores_em)
values (true, false, null)
on conflict (unica) do nothing;

create table if not exists privado.dispositivos_confiaveis (
  id            uuid primary key default gen_random_uuid(),
  usuario_id    uuid not null references auth.users(id) on delete cascade,
  token_hash    text not null unique,
  plataforma    text not null check (plataforma in ('ios', 'android', 'web')),
  criado_em     timestamptz not null default now(),
  expira_em     timestamptz not null,
  ultimo_uso_em timestamptz not null default now(),
  revogado_em   timestamptz null
);

create index if not exists dispositivos_confiaveis_usuario_ativo_idx
  on privado.dispositivos_confiaveis (usuario_id)
  where revogado_em is null;

create table if not exists privado.sessoes_verificadas (
  session_id     uuid primary key,
  usuario_id     uuid not null references auth.users(id) on delete cascade,
  dispositivo_id uuid null references privado.dispositivos_confiaveis(id) on delete set null,
  verificada_em  timestamptz not null default now()
);

create index if not exists sessoes_verificadas_usuario_idx
  on privado.sessoes_verificadas (usuario_id);

create table if not exists privado.desafios_dispositivo (
  id                uuid primary key default gen_random_uuid(),
  usuario_id        uuid not null references auth.users(id) on delete cascade,
  email_normalizado text not null,
  email_hash        text not null,
  plataforma        text not null check (plataforma in ('ios', 'android', 'web')),
  tentativas        integer not null default 0 check (tentativas >= 0 and tentativas <= 5),
  reenvios          integer not null default 0 check (reenvios >= 0 and reenvios <= 3),
  ultimo_reenvio_em timestamptz null,
  criado_em         timestamptz not null default now(),
  expira_em         timestamptz not null,
  usado_em          timestamptz null
);

create index if not exists desafios_dispositivo_usuario_idx
  on privado.desafios_dispositivo (usuario_id, criado_em desc);

create index if not exists desafios_dispositivo_expira_idx
  on privado.desafios_dispositivo (expira_em);

create table if not exists privado.contas_senha_pendente (
  usuario_id uuid primary key references auth.users(id) on delete cascade,
  motivo     text not null check (motivo in ('cadastro', 'recuperacao')),
  criado_em  timestamptz not null default now()
);

create table if not exists privado.rate_limit_auth (
  chave    text not null,
  janela   timestamptz not null,
  contagem integer not null default 1,
  primary key (chave, janela)
);

revoke all on table privado.config_auth from public, anon, authenticated;
revoke all on table privado.dispositivos_confiaveis from public, anon, authenticated;
revoke all on table privado.sessoes_verificadas from public, anon, authenticated;
revoke all on table privado.desafios_dispositivo from public, anon, authenticated;
revoke all on table privado.contas_senha_pendente from public, anon, authenticated;
revoke all on table privado.rate_limit_auth from public, anon, authenticated;

-- Invariante de segurança (738/785): toda tabela em privado tem RLS ativado sem políticas para clientes.
alter table privado.config_auth enable row level security;
alter table privado.dispositivos_confiaveis enable row level security;
alter table privado.sessoes_verificadas enable row level security;
alter table privado.desafios_dispositivo enable row level security;
alter table privado.contas_senha_pendente enable row level security;
alter table privado.rate_limit_auth enable row level security;

-- ── 2. Funções auxiliares de avaliação (relógio do banco + preservação de corte) ─

create or replace function privado.exigir_dispositivo_verificado_ativo()
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select coalesce(
    (select c.exigir_dispositivo_verificado from privado.config_auth c where c.unica),
    false
  )
$$;

revoke execute on function privado.exigir_dispositivo_verificado_ativo() from public, anon, authenticated;

create or replace function privado.sessao_eh_pre_corte(p_session_id uuid, p_usuario_id uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select p_session_id is not null and exists (
    select 1
      from auth.sessions s
      join privado.config_auth c on c.unica
     where s.id = p_session_id
       and s.user_id = p_usuario_id
       and c.corte_sessoes_anteriores_em is not null
       and s.created_at < c.corte_sessoes_anteriores_em
  )
$$;

revoke execute on function privado.sessao_eh_pre_corte(uuid, uuid) from public, anon, authenticated;

create or replace function privado.eh_conta_demonstracao_auth(p_usuario_id uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select exists (
    select 1
      from public.usuario u
     where u.id = p_usuario_id
       and u.email in (
         select d.email from public.entrada_demonstracao d
       )
  )
  or exists (
    select 1
      from auth.users au
     where au.id = p_usuario_id
       and lower(coalesce(au.email, '')) in (
         select lower(d.email) from public.entrada_demonstracao d
       )
  )
$$;

revoke execute on function privado.eh_conta_demonstracao_auth(uuid) from public, anon, authenticated;

create or replace function privado.sessao_tem_dispositivo_verificado(
  p_session_id uuid,
  p_usuario_id uuid
)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select
    privado.eh_conta_demonstracao_auth(p_usuario_id)
    or privado.sessao_eh_pre_corte(p_session_id, p_usuario_id)
    or (
      p_session_id is not null
      and exists (
        select 1
          from privado.sessoes_verificadas sv
          left join privado.dispositivos_confiaveis dc on dc.id = sv.dispositivo_id
         where sv.session_id = p_session_id
           and sv.usuario_id = p_usuario_id
           and (
             sv.dispositivo_id is null
             or (dc.revogado_em is null and dc.expira_em > privado.agora())
           )
      )
    )
$$;

revoke execute on function privado.sessao_tem_dispositivo_verificado(uuid, uuid) from public, anon, authenticated;

create or replace function privado.usuario_precisa_definir_senha(
  p_usuario_id uuid,
  p_session_id uuid default null
)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select case
    when privado.eh_conta_demonstracao_auth(p_usuario_id) then false
    when exists (
      select 1 from privado.contas_senha_pendente p where p.usuario_id = p_usuario_id
    ) then true
    when privado.sessao_eh_pre_corte(p_session_id, p_usuario_id) then false
    when not privado.exigir_dispositivo_verificado_ativo() then false
    else exists (
      select 1
        from auth.users au
       where au.id = p_usuario_id
         and coalesce(au.encrypted_password, '') = ''
    )
  end
$$;

revoke execute on function privado.usuario_precisa_definir_senha(uuid, uuid) from public, anon, authenticated;

-- ── 3. Custom Access Token Hook (GoTrue / supabase_auth_admin) ────────────────

create or replace function privado.custom_access_token_hook(event jsonb)
returns jsonb
language plpgsql
stable
security definer set search_path = ''
as $$
declare
  v_uid           uuid := nullif(event ->> 'user_id', '')::uuid;
  v_claims        jsonb := coalesce(event -> 'claims', '{}'::jsonb);
  v_sid           uuid := nullif(v_claims ->> 'session_id', '')::uuid;
  v_app_meta      jsonb := coalesce(v_claims -> 'app_metadata', '{}'::jsonb);
  v_verificado    boolean := false;
  v_precisa_senha boolean := false;
begin
  if v_uid is not null then
    v_verificado    := privado.sessao_tem_dispositivo_verificado(v_sid, v_uid);
    v_precisa_senha := privado.usuario_precisa_definir_senha(v_uid, v_sid);
  end if;

  v_app_meta := v_app_meta || jsonb_build_object(
    'dispositivo_verificado', v_verificado,
    'precisa_definir_senha',  v_precisa_senha
  );
  v_claims := jsonb_set(v_claims, '{app_metadata}', v_app_meta, true);

  return jsonb_set(event, '{claims}', v_claims, true);
end $$;

revoke execute on function privado.custom_access_token_hook(jsonb) from public, anon, authenticated;
grant usage on schema privado to supabase_auth_admin;
grant execute on function privado.custom_access_token_hook(jsonb) to supabase_auth_admin;

-- ── 4. Operações atômicas internas (chamadas pelas Edge Functions via SQL) ────

create or replace function privado.consumir_rate_limit_auth(
  p_chave            text,
  p_limite           integer,
  p_janela_segundos  integer default 600
)
returns boolean
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora    timestamptz := privado.agora();
  v_epoch    bigint := floor(extract(epoch from v_agora))::bigint;
  v_janela   timestamptz := to_timestamp((v_epoch / greatest(p_janela_segundos, 1)) * greatest(p_janela_segundos, 1));
  v_contagem integer;
begin
  delete from privado.rate_limit_auth
   where janela < v_agora - interval '1 hour';

  insert into privado.rate_limit_auth as r (chave, janela, contagem)
  values (p_chave, v_janela, 1)
  on conflict (chave, janela) do update
     set contagem = r.contagem + 1
  returning contagem into v_contagem;

  return v_contagem <= p_limite;
end $$;

revoke execute on function privado.consumir_rate_limit_auth(text, integer, integer) from public, anon, authenticated;

create or replace function privado.validar_e_marcar_dispositivo(
  p_usuario_id uuid,
  p_session_id uuid,
  p_token_hash text
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora      timestamptz := privado.agora();
  v_disp       privado.dispositivos_confiaveis%rowtype;
  v_precisa    boolean;
begin
  if p_token_hash is null or btrim(p_token_hash) = '' then
    return jsonb_build_object('valido', false);
  end if;

  select *
    into v_disp
    from privado.dispositivos_confiaveis d
   where d.token_hash = p_token_hash
     and d.usuario_id = p_usuario_id
     and d.revogado_em is null
     and d.expira_em > v_agora
   for update;

  if not found then
    return jsonb_build_object('valido', false);
  end if;

  update privado.dispositivos_confiaveis
     set ultimo_uso_em = v_agora
   where id = v_disp.id;

  if p_session_id is not null then
    insert into privado.sessoes_verificadas (session_id, usuario_id, dispositivo_id, verificada_em)
    values (p_session_id, p_usuario_id, v_disp.id, v_agora)
    on conflict (session_id) do update
       set dispositivo_id = excluded.dispositivo_id,
           verificada_em  = excluded.verificada_em;
  end if;

  v_precisa := privado.usuario_precisa_definir_senha(p_usuario_id, p_session_id);

  return jsonb_build_object(
    'valido',                true,
    'dispositivo_id',        v_disp.id,
    'expira_em',             v_disp.expira_em,
    'precisa_definir_senha', v_precisa
  );
end $$;

revoke execute on function privado.validar_e_marcar_dispositivo(uuid, uuid, text) from public, anon, authenticated;

create or replace function privado.criar_desafio_dispositivo(
  p_usuario_id uuid,
  p_email      text,
  p_email_hash text,
  p_plataforma text
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora  timestamptz := privado.agora();
  v_expira timestamptz := v_agora + interval '10 minutes';
  v_id     uuid;
begin
  insert into privado.desafios_dispositivo (
    usuario_id, email_normalizado, email_hash, plataforma, criado_em, expira_em
  )
  values (
    p_usuario_id, lower(btrim(p_email)), p_email_hash, p_plataforma, v_agora, v_expira
  )
  returning id into v_id;

  return jsonb_build_object(
    'desafio_id', v_id,
    'expira_em',  v_expira
  );
end $$;

revoke execute on function privado.criar_desafio_dispositivo(uuid, text, text, text) from public, anon, authenticated;

create or replace function privado.reservar_tentativa_desafio(
  p_desafio_id uuid
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora   timestamptz := privado.agora();
  v_row     privado.desafios_dispositivo%rowtype;
begin
  -- Atualização atômica protegida contra concorrência/replay.
  update privado.desafios_dispositivo
     set tentativas = tentativas + 1
   where id = p_desafio_id
     and usado_em is null
     and expira_em > v_agora
     and tentativas < 5
  returning * into v_row;

  if found then
    return jsonb_build_object(
      'status',            'ok',
      'usuario_id',        v_row.usuario_id,
      'email_normalizado', v_row.email_normalizado,
      'plataforma',        v_row.plataforma,
      'tentativas',        v_row.tentativas
    );
  end if;

  select * into v_row from privado.desafios_dispositivo where id = p_desafio_id;
  if not found or v_row.expira_em <= v_agora then
    return jsonb_build_object('status', 'desafio_expirado');
  end if;
  if v_row.usado_em is not null then
    return jsonb_build_object('status', 'desafio_ja_usado');
  end if;
  return jsonb_build_object('status', 'limite_excedido');
end $$;

revoke execute on function privado.reservar_tentativa_desafio(uuid) from public, anon, authenticated;

create or replace function privado.reservar_reenvio_desafio(
  p_desafio_id uuid
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora      timestamptz := privado.agora();
  v_nova_exp   timestamptz := v_agora + interval '10 minutes';
  v_row        privado.desafios_dispositivo%rowtype;
begin
  -- Mantém o mesmo desafio_id e NÃO incrementa tentativas de verificação OTP.
  -- Exige cooldown mínimo de 60s entre reenvios e teto de 3 reenvios por desafio.
  update privado.desafios_dispositivo
     set reenvios          = reenvios + 1,
         ultimo_reenvio_em = v_agora,
         expira_em         = v_nova_exp
   where id = p_desafio_id
     and usado_em is null
     and expira_em > v_agora
     and reenvios < 3
     and coalesce(ultimo_reenvio_em, criado_em) <= v_agora - interval '60 seconds'
  returning * into v_row;

  if found then
    return jsonb_build_object(
      'status',            'ok',
      'desafio_id',        v_row.id,
      'email_normalizado', v_row.email_normalizado,
      'email_hash',        v_row.email_hash,
      'expira_em',         v_row.expira_em
    );
  end if;

  select * into v_row from privado.desafios_dispositivo where id = p_desafio_id;
  if not found or v_row.expira_em <= v_agora then
    return jsonb_build_object('status', 'desafio_expirado');
  end if;
  if v_row.usado_em is not null then
    return jsonb_build_object('status', 'desafio_ja_usado');
  end if;
  return jsonb_build_object('status', 'limite_excedido');
end $$;

revoke execute on function privado.reservar_reenvio_desafio(uuid) from public, anon, authenticated;

create or replace function privado.concluir_desafio_e_registrar_sessao(
  p_desafio_id            uuid,
  p_usuario_id            uuid,
  p_session_id            uuid,
  p_plataforma            text,
  p_token_hash            text default null,
  p_marcar_senha_pendente text default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora      timestamptz := privado.agora();
  v_disp_id    uuid := null;
  v_expira     timestamptz := null;
  v_consumido  uuid;
  v_precisa    boolean;
begin
  if p_desafio_id is not null then
    update privado.desafios_dispositivo
       set usado_em = v_agora
     where id = p_desafio_id
       and usuario_id = p_usuario_id
       and usado_em is null
       and expira_em > v_agora
    returning id into v_consumido;

    if v_consumido is null then
      return jsonb_build_object('ok', false, 'motivo', 'desafio_ja_usado');
    end if;
  end if;

  if p_marcar_senha_pendente in ('cadastro', 'recuperacao') then
    insert into privado.contas_senha_pendente (usuario_id, motivo, criado_em)
    values (p_usuario_id, p_marcar_senha_pendente, v_agora)
    on conflict (usuario_id) do update
       set motivo    = excluded.motivo,
           criado_em = excluded.criado_em;
  end if;

  if p_token_hash is not null and btrim(p_token_hash) <> '' then
    v_expira := v_agora + interval '30 days';
    insert into privado.dispositivos_confiaveis (
      usuario_id, token_hash, plataforma, criado_em, expira_em, ultimo_uso_em
    )
    values (
      p_usuario_id, p_token_hash, p_plataforma, v_agora, v_expira, v_agora
    )
    returning id into v_disp_id;
  end if;

  if p_session_id is not null then
    insert into privado.sessoes_verificadas (session_id, usuario_id, dispositivo_id, verificada_em)
    values (p_session_id, p_usuario_id, v_disp_id, v_agora)
    on conflict (session_id) do update
       set dispositivo_id = excluded.dispositivo_id,
           verificada_em  = excluded.verificada_em;
  end if;

  v_precisa := privado.usuario_precisa_definir_senha(p_usuario_id, p_session_id);

  return jsonb_build_object(
    'ok',                    true,
    'dispositivo_id',        v_disp_id,
    'dispositivo_expira_em', v_expira,
    'precisa_definir_senha', v_precisa
  );
end $$;

revoke execute on function privado.concluir_desafio_e_registrar_sessao(uuid, uuid, uuid, text, text, text) from public, anon, authenticated;

create or replace function privado.concluir_definicao_senha(
  p_usuario_id        uuid,
  p_session_id        uuid,
  p_manter_token_hash text default null
)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora      timestamptz := privado.agora();
  v_revogados  integer := 0;
begin
  delete from privado.contas_senha_pendente
   where usuario_id = p_usuario_id;

  update privado.dispositivos_confiaveis
     set revogado_em = v_agora
   where usuario_id = p_usuario_id
     and revogado_em is null
     and (p_manter_token_hash is null or token_hash <> p_manter_token_hash);

  get diagnostics v_revogados = row_count;

  -- Remove sessões verificadas de outros aparelhos, preservando apenas a sessão corrente.
  delete from privado.sessoes_verificadas
   where usuario_id = p_usuario_id
     and (p_session_id is null or session_id <> p_session_id);

  -- Revoga sessões de outros aparelhos diretamente no Auth.
  delete from auth.sessions
   where user_id = p_usuario_id
     and (p_session_id is null or id <> p_session_id);

  return jsonb_build_object(
    'ok',                     true,
    'precisa_definir_senha',  false,
    'dispositivos_revogados', v_revogados
  );
end $$;

revoke execute on function privado.concluir_definicao_senha(uuid, uuid, text) from public, anon, authenticated;

create or replace function privado.revogar_todos_dispositivos(
  p_usuario_id uuid
)
returns integer
language plpgsql
security definer set search_path = ''
as $$
declare
  v_agora     timestamptz := privado.agora();
  v_revogados integer := 0;
begin
  update privado.dispositivos_confiaveis
     set revogado_em = v_agora
   where usuario_id = p_usuario_id
     and revogado_em is null;

  get diagnostics v_revogados = row_count;

  delete from privado.sessoes_verificadas
   where usuario_id = p_usuario_id;

  delete from auth.sessions
   where user_id = p_usuario_id;

  return v_revogados;
end $$;

revoke execute on function privado.revogar_todos_dispositivos(uuid) from public, anon, authenticated;

create or replace function privado.revogar_sessao_pontual(
  p_session_id uuid,
  p_usuario_id uuid
)
returns void
language plpgsql
security definer set search_path = ''
as $$
begin
  if p_session_id is null then
    return;
  end if;

  delete from privado.sessoes_verificadas
   where session_id = p_session_id
     and usuario_id = p_usuario_id;

  delete from auth.sessions
   where id = p_session_id
     and user_id = p_usuario_id;
end $$;

revoke execute on function privado.revogar_sessao_pontual(uuid, uuid) from public, anon, authenticated;

-- Guarda online para Edge Functions sensíveis (definir-senha, revogar-dispositivos, etc.):
-- quando exigir_dispositivo_verificado = true, exige sessão verificada ativa no banco
-- (com isenções explícitas para conta de demonstração e sessão pré-corte).
create or replace function privado.verificar_sessao_dispositivo_online(
  p_usuario_id uuid,
  p_session_id uuid
)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select
    not privado.exigir_dispositivo_verificado_ativo()
    or privado.sessao_tem_dispositivo_verificado(p_session_id, p_usuario_id)
$$;

revoke execute on function privado.verificar_sessao_dispositivo_online(uuid, uuid) from public, anon, authenticated;

-- Guarda interna de produto (usada em funções/políticas internas; não exposta como RPC em public).
create or replace function privado.sessao_autorizada_para_produto()
returns boolean
language plpgsql
stable
security definer set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_claims   jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_sid      uuid := nullif(v_claims ->> 'session_id', '')::uuid;
  v_app_meta jsonb := coalesce(v_claims -> 'app_metadata', '{}'::jsonb);
begin
  if v_uid is null then
    return false;
  end if;

  if privado.exigir_dispositivo_verificado_ativo()
     and (
       coalesce((v_app_meta ->> 'dispositivo_verificado')::boolean, false) is not true
       or not privado.sessao_tem_dispositivo_verificado(v_sid, v_uid)
     ) then
    return false;
  end if;

  if coalesce((v_app_meta ->> 'precisa_definir_senha')::boolean, false) is true then
    return false;
  end if;

  return true;
end $$;

revoke execute on function privado.sessao_autorizada_para_produto() from public, anon, authenticated;

create or replace function public.estado_autenticacao()
returns jsonb
language plpgsql
stable
security definer set search_path = ''
as $$
declare
  v_uid        uuid := (select auth.uid());
  v_claims     jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_sid        uuid := nullif(v_claims ->> 'session_id', '')::uuid;
  v_tem_conta  boolean;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'anonimizada') then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select exists (
    select 1 from public.usuario u where u.id = v_uid and u.estado <> 'anonimizada'
  ) into v_tem_conta;

  return jsonb_build_object(
    'autenticado',            true,
    'dispositivo_verificado', privado.sessao_tem_dispositivo_verificado(v_sid, v_uid),
    'precisa_definir_senha',  privado.usuario_precisa_definir_senha(v_uid, v_sid),
    'tem_conta',              v_tem_conta
  );
end $$;

revoke execute on function public.estado_autenticacao() from public, anon;
grant  execute on function public.estado_autenticacao() to authenticated;

-- Atualiza minha_conta() para incluir o sinal server-authoritative precisa_definir_senha.
create or replace function public.minha_conta()
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_sid    uuid := nullif(v_claims ->> 'session_id', '')::uuid;
  v_linha  public.usuario%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  select * into v_linha from public.usuario u where u.id = v_uid;
  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_linha.estado = 'anonimizada' then
    perform public.erro(401, 'nao_autenticado');
  end if;

  return public.conta_em_json(v_linha)
    || jsonb_build_object('precisa_definir_senha', privado.usuario_precisa_definir_senha(v_linha.id, v_sid));
end $$;

revoke execute on function public.minha_conta() from public, anon;
grant  execute on function public.minha_conta() to authenticated;

-- Atualiza o pre-request do PostgREST para impor a trava contra bypass direto ao GoTrue
-- (quando privado.config_auth.exigir_dispositivo_verificado = true) e bloquear acesso ao produto
-- quando app_metadata.precisa_definir_senha = true (preservando estado_autenticacao e minha_conta).
create or replace function requisicao.conferir_limite() returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid      uuid := (select auth.uid());
  v_claims   jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
  v_sid      uuid := nullif(v_claims ->> 'session_id', '')::uuid;
  v_papel    text := v_claims ->> 'role';
  v_app_meta jsonb := coalesce(v_claims -> 'app_metadata', '{}'::jsonb);
  v_path     text := coalesce(current_setting('request.path', true), '');
  v_metodo   text := coalesce(current_setting('request.method', true), '');
  v_cab      text;
  v_ip       text;
  v_em       timestamptz;
  v_janela   timestamptz;
  v_contagem int;
begin
  if v_uid is null or v_papel is distinct from 'authenticated' then
    return;
  end if;

  -- Guarda central contra bypass direto ao GoTrue + revogação imediata (1 PK lookup em sessoes_verificadas).
  -- Isenta automaticamente sessões pré-corte e contas de demonstração via sessao_tem_dispositivo_verificado().
  if privado.exigir_dispositivo_verificado_ativo()
     and v_path <> '/rpc/estado_autenticacao'
     and (
       coalesce((v_app_meta ->> 'dispositivo_verificado')::boolean, false) is not true
       or not privado.sessao_tem_dispositivo_verificado(v_sid, v_uid)
     ) then
    perform public.erro(401, 'dispositivo_nao_verificado');
  end if;

  -- Guarda central de definição obrigatória de senha (nunca dispara em sessões legadas pré-corte).
  if v_path not in ('/rpc/estado_autenticacao', '/rpc/minha_conta')
     and coalesce((v_app_meta ->> 'precisa_definir_senha')::boolean, false) is true then
    perform public.erro(403, 'senha_pendente');
  end if;

  -- Registro de acessos (Marco Civil art. 15), preservado integralmente.
  begin
    if exists (select 1 from privado.registro_acesso_coleta c where c.unica and c.ligada) then
      v_cab := nullif(current_setting('request.headers', true), '');
      v_ip := case when strpos(v_cab, 'x-frila-ip-') > 0 then privado.ip_do_acesso(v_cab::json, v_uid)
                   else v_cab::json ->> 'cf-connecting-ip' end;
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
