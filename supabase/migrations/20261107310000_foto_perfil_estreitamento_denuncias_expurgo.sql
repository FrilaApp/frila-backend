-- B4b: Estreitamento da foto de perfil, remoção de colunas mortas,
-- ocultação por 2 denúncias distintas e expurgo em 24 h (RN37, CA4).

-- 1. Estreitamento de midia_tipo para ('foto_perfil') e remoção de colunas mortas (PR #175 / contrato 0.2.61).
alter table privado.midia drop constraint if exists midia_tipo;
alter table privado.midia add constraint midia_tipo check (tipo in ('foto_perfil'));

alter table privado.midia drop column if exists legenda;
alter table privado.midia drop column if exists funcao_id;
alter table privado.midia drop column if exists ordem;

-- 2. Atualiza minhas_midias para ordenar por criado_em, id (sem ordem).
create or replace function public.minhas_midias() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := privado.usuario_midia();
begin
  return (select coalesce(jsonb_agg(privado.midia_em_json(m) order by m.criado_em, m.id), '[]'::jsonb)
    from privado.midia m where m.estado <> 'expurgada'
      and (m.estabelecimento_id is null and m.dono_usuario_id = v_uid or privado.eh_membro(m.estabelecimento_id)));
end $$;

-- 3. Confirmar expurgo físico de mídia de perfil (chamado pela Edge Function expurgar-midias).
create or replace function privado.confirmar_expurgo_midia_perfil(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ok boolean;
begin
  update privado.midia m
     set estado = 'expurgada',
         atualizado_em = privado.agora()
   where m.id = p_id
     and m.estado in ('recusada', 'removida', 'expurgada')
  returning true into v_ok;

  -- Idempotente: confirmar duas vezes devolve true sem reescrever data
  return coalesce(v_ok, false);
end $$;

comment on function privado.confirmar_expurgo_midia_perfil(uuid) is
  'Fecha o expurgo de mídia de perfil após remoção dos bytes no Storage. Chamada com service_role pela Edge Function expurgar-midias. Idempotente.';

revoke execute on function privado.confirmar_expurgo_midia_perfil(uuid) from public, anon, authenticated;
grant  execute on function privado.confirmar_expurgo_midia_perfil(uuid) to service_role;

-- 4. Expurgo em 24 h de mídias recusadas.
create or replace function privado.expurgar_midias_recusadas()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_qtd integer := 0;
  v_caminhos jsonb;
begin
  for r in
    select id, storage_path
      from privado.midia
     where estado = 'recusada'
       and atualizado_em < privado.agora() - interval '24 hours'
     for update skip locked
  loop
    v_caminhos := jsonb_build_array(r.storage_path, replace(r.storage_path, '.jpg', '_thumb.jpg'));

    perform pgmq.send(
      'expurgo_midia',
      jsonb_build_object(
        'verificacao_id', r.id::text,
        'bucket', 'midia-perfil',
        'caminhos', v_caminhos,
        'origem', 'foto_perfil'
      )
    );

    update privado.midia
       set estado = 'expurgada',
           atualizado_em = privado.agora()
     where id = r.id;

    v_qtd := v_qtd + 1;
  end loop;

  return v_qtd;
end $$;

comment on function privado.expurgar_midias_recusadas() is
  'Enfileira para expurgo físico no Storage as fotos recusadas há mais de 24 horas e marca estado=expurgada. Idempotente.';

revoke execute on function privado.expurgar_midias_recusadas() from public, anon, authenticated;
grant  execute on function privado.expurgar_midias_recusadas() to service_role;

-- 5. Atualiza remover_midia para enfileirar expurgo imediatamente.
create or replace function public.remover_midia(midia_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := privado.usuario_midia();
  v_m privado.midia;
begin
  select m.* into v_m from privado.midia m where m.id = midia_id
    and (m.estabelecimento_id is null and m.dono_usuario_id = v_uid or privado.eh_membro(m.estabelecimento_id)) for update;
  if not found then perform public.erro(404, 'nao_encontrado'); end if;

  if v_m.estado not in ('removida', 'expurgada') then
    update privado.midia set estado = 'removida', atualizado_em = privado.agora()
     where id = v_m.id returning * into v_m;

    perform pgmq.send(
      'expurgo_midia',
      jsonb_build_object(
        'verificacao_id', v_m.id::text,
        'bucket', 'midia-perfil',
        'caminhos', jsonb_build_array(v_m.storage_path, replace(v_m.storage_path, '.jpg', '_thumb.jpg')),
        'origem', 'foto_perfil'
      )
    );
  end if;

  return privado.midia_em_json(v_m);
end $$;

-- 6. Trigger de 2 denúncias distintas para ocultar foto de perfil aprovada (CD-M07 / CA4).
create or replace function privado.processar_denuncia_midia()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_midia_id uuid;
  v_distintas bigint;
begin
  if new.tipo <> 'denuncia' then
    return new;
  end if;

  -- Localiza a foto de perfil aprovada do denunciado
  if new.usuario_id is not null then
    select id into v_midia_id
      from privado.midia
     where dono_usuario_id = new.usuario_id
       and estabelecimento_id is null
       and tipo = 'foto_perfil'
       and estado = 'aprovada'
     for update;

    if v_midia_id is not null then
      select count(distinct autor_id) into v_distintas
        from public.ocorrencia
       where tipo = 'denuncia'
         and usuario_id = new.usuario_id;
    end if;
  elsif new.estabelecimento_id is not null then
    select id into v_midia_id
      from privado.midia
     where estabelecimento_id = new.estabelecimento_id
       and tipo = 'foto_perfil'
       and estado = 'aprovada'
     for update;

    if v_midia_id is not null then
      select count(distinct autor_id) into v_distintas
        from public.ocorrencia
       where tipo = 'denuncia'
         and estabelecimento_id = new.estabelecimento_id;
    end if;
  end if;

  if v_midia_id is not null and v_distintas is not null then
    update privado.midia
       set denuncias_distintas = v_distintas::smallint,
           estado = case when v_distintas >= 2 then 'ocultada' else estado end,
           atualizado_em = privado.agora()
     where id = v_midia_id;
  end if;

  return new;
end $$;

drop trigger if exists trg_denuncia_processar_midia on public.ocorrencia;
create trigger trg_denuncia_processar_midia
after insert on public.ocorrencia
for each row execute function privado.processar_denuncia_midia();

-- 7. Pluga expurgo de mídias recusadas na retenção diária existente.
create or replace function privado.executar_retencao_diaria()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_anonimizadas    integer;
  v_higiene         jsonb;
  v_eventos_app     integer;
  v_expurgo_ident   jsonb;
  v_expurgo_perfil  integer;
begin
  v_anonimizadas   := privado.limpar_contas_anonimizadas(15);
  v_higiene        := privado.higienizar_tabelas();
  v_eventos_app    := privado.limpar_eventos_app(90);
  v_expurgo_ident  := privado.expurgar_midias_verificacao_identidade();
  v_expurgo_perfil := privado.expurgar_midias_recusadas();

  return jsonb_build_object(
    'executado_em',               privado.agora(),
    'contas_anonimizadas_limpas', v_anonimizadas,
    'higiene',                    v_higiene,
    'eventos_app_limpos',         v_eventos_app,
    'expurgo_midia_identidade',   v_expurgo_ident,
    'expurgo_midia_perfil',       v_expurgo_perfil
  );
end $$;
