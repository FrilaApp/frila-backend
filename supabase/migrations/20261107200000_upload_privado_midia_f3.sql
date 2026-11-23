-- RN37/RN46, CD-M01/M04/M13: upload privado. B4c consome a fila e gera a miniatura.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('midia-perfil', 'midia-perfil', false, 5242880, array['image/jpeg']);
-- Só URLs assinadas pelos fluxos autorizados; nem o dono lê ou escreve diretamente.
create policy midia_perfil_sem_acesso_direto on storage.objects as restrictive
for all to anon, authenticated using (bucket_id <> 'midia-perfil') with check (bucket_id <> 'midia-perfil');

create table privado.midia (
  id uuid primary key default gen_random_uuid(),
  dono_usuario_id uuid not null references public.usuario(id) on delete cascade,
  estabelecimento_id uuid references public.estabelecimento(id) on delete cascade,
  dono_tipo text not null constraint midia_dono_tipo check (dono_tipo in ('profissional','estabelecimento')),
  tipo text not null constraint midia_tipo check (tipo in ('foto_perfil','foto_trabalho','foto_local','curriculo')),
  funcao_id uuid references public.funcao(id) on delete set null,
  legenda text constraint midia_legenda check (legenda is null or length(legenda) <= 120),
  ordem smallint not null default 0,
  storage_path text not null unique constraint midia_storage_path check (btrim(storage_path) <> ''),
  mime text not null constraint midia_mime check (mime = 'image/jpeg'),
  bytes bigint not null constraint midia_bytes check (bytes > 0 and bytes <= 5242880),
  estado text not null default 'enviando' constraint midia_estado check (estado in ('enviando','em_analise','aprovada','recusada','nao_publicada','ocultada','removida','expurgada')),
  motivo_recusa text,
  motivo_codigo text,
  denuncias_distintas smallint not null default 0,
  criado_em timestamptz not null default privado.agora(),
  atualizado_em timestamptz not null default privado.agora()
);
create unique index midia_foto_unica_por_estado on privado.midia
  (dono_tipo, coalesce(estabelecimento_id, dono_usuario_id), estado)
  where tipo = 'foto_perfil' and estado in ('aprovada','em_analise');
alter table privado.midia enable row level security;
revoke all on privado.midia from public, anon, authenticated;
grant all on privado.midia to service_role;
comment on table privado.midia is 'Fotos privadas de perfil e estado da análise; bytes no Storage, expurgo em duas fases no B4b. RN37 e RN15.';
comment on column privado.midia.dono_usuario_id is 'Titular que enviou a mídia; usado para autorização, nunca no caminho do objeto.';
comment on column privado.midia.estabelecimento_id is 'Casa titular da foto/logo; autorização pelos membros, limite por casa.';
comment on column privado.midia.storage_path is 'Referência privada ao original; nunca devolvida na projeção da mídia.';
comment on column privado.midia.motivo_codigo is 'Código interno da análise; nunca exposto ao cliente (RN15).';
comment on column privado.midia.motivo_recusa is 'Motivo genérico de recusa para orientar o titular.';
select pgmq.create('moderacao_midia');

-- Interruptor desligado em todos os ambientes; a liberação cabe ao dono após jurídico/ROPA.
alter table privado.configuracao_app add column foto_de_perfil boolean not null default false;
create or replace function public.configuracao_do_app(plataforma text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_config privado.configuracao_app;
begin
  if plataforma is null or btrim(plataforma) = '' then perform public.erro(422,'campo_obrigatorio','plataforma'); end if;
  if not plataforma = any(enum_range(null::public.plataforma)::text[]) then
    perform public.erro(422,'campo_invalido','plataforma');
  end if;
  select c.* into v_config from privado.configuracao_app c where c.plataforma::text = configuracao_do_app.plataforma;
  if not found then perform public.erro(404,'nao_encontrado','plataforma'); end if;
  return jsonb_build_object('plataforma',v_config.plataforma,'versao_minima',v_config.versao_minima,
    'versao_recomendada',v_config.versao_recomendada,'url_da_loja',v_config.url_da_loja,'mensagem',v_config.mensagem)
    || case when v_config.foto_de_perfil then jsonb_build_object('recursos',jsonb_build_object('foto_de_perfil',true)) else '{}'::jsonb end;
end $$;

create function privado.usuario_midia(exigir_recurso boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := (select auth.uid());
begin
  if v_uid is null then perform public.erro(401,'nao_autenticado'); end if;
  perform privado.exigir_conta_ativa();
  if exigir_recurso and not coalesce((select bool_or(c.foto_de_perfil) from privado.configuracao_app c), false) then
    perform public.erro(403,'sem_permissao','recurso_desligado');
  end if;
  return v_uid;
end $$;
create function privado.midia_em_json(m privado.midia) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id',m.id,'tipo',m.tipo,'estado',case when m.estado='expurgada' then 'removida' else m.estado end,
    'motivo_recusa',m.motivo_recusa,'pode_pedir_nova_analise',false,'estabelecimento_id',m.estabelecimento_id)
$$;
revoke all on function privado.usuario_midia(boolean), privado.midia_em_json(privado.midia) from public, anon, authenticated;
grant execute on function privado.usuario_midia(boolean), privado.midia_em_json(privado.midia) to service_role;

create function public.solicitar_upload_midia(tipo text, mime text, bytes bigint, estabelecimento_id uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := privado.usuario_midia(true);
  v_id uuid := gen_random_uuid();
  v_path text := 'perfil/' || v_id || '.jpg';
  v_url text;
begin
  if tipo is distinct from 'foto_perfil' then perform public.erro(422,'midia_invalida','tipo_indisponivel'); end if;
  if mime is distinct from 'image/jpeg' then perform public.erro(422,'midia_invalida','formato'); end if;
  if bytes is null or bytes <= 0 or bytes > 5242880 then perform public.erro(422,'midia_invalida','tamanho'); end if;
  if estabelecimento_id is not null then
    if not privado.eh_membro(estabelecimento_id) then perform public.erro(403,'sem_permissao'); end if;
  else
    perform privado.exigir_perfil('profissional');
  end if;
  insert into privado.midia(id,dono_usuario_id,estabelecimento_id,dono_tipo,tipo,storage_path,mime,bytes)
    values (v_id,v_uid,estabelecimento_id,case when estabelecimento_id is null then 'profissional' else 'estabelecimento' end,
      tipo,v_path,mime,bytes);
  v_url := coalesce((select decrypted_secret from vault.decrypted_secrets where name='storage_url' limit 1),
    nullif(current_setting('frila.storage_url',true),''),'http://127.0.0.1:54321/storage/v1');
  return jsonb_build_object('midia_id',v_id,'upload_url',rtrim(v_url,'/') || '/object/upload/sign/midia-perfil/' || v_path
    || '?token=' || privado.token_de_upload_storage('midia-perfil',v_path,7200),'expira_em',privado.agora() + interval '2 hours');
end $$;

create function public.confirmar_upload_midia(midia_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := privado.usuario_midia(true); v_m privado.midia;
begin
  select m.* into v_m from privado.midia m where m.id = midia_id
    and (m.estabelecimento_id is null and m.dono_usuario_id = v_uid or privado.eh_membro(m.estabelecimento_id)) for update;
  if not found then perform public.erro(404,'nao_encontrado'); end if;
  if v_m.estado <> 'enviando' then return privado.midia_em_json(v_m); end if;
  if not exists(select 1 from storage.objects o where o.bucket_id='midia-perfil' and o.name=v_m.storage_path) then
    perform public.erro(422,'evidencia_incompleta');
  end if;
  begin
    update privado.midia set estado='em_analise',atualizado_em=privado.agora() where id=v_m.id returning * into v_m;
  exception when unique_violation then perform public.erro(422,'midia_invalida','limite_atingido');
  end;
  -- B4c valida bytes/dimensões, recodifica sem EXIF e gera a miniatura. Falha não publica.
  perform pgmq.send('moderacao_midia',jsonb_build_object('midia_id',v_m.id));
  return privado.midia_em_json(v_m);
end $$;

create function public.remover_midia(midia_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := privado.usuario_midia(); v_m privado.midia;
begin
  select m.* into v_m from privado.midia m where m.id=midia_id
    and (m.estabelecimento_id is null and m.dono_usuario_id=v_uid or privado.eh_membro(m.estabelecimento_id)) for update;
  if not found then perform public.erro(404,'nao_encontrado'); end if;
  if v_m.estado not in ('removida','expurgada') then
    update privado.midia set estado='removida',atualizado_em=privado.agora() where id=v_m.id returning * into v_m;
  end if;
  return privado.midia_em_json(v_m);
end $$;

create function public.minhas_midias() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := privado.usuario_midia();
begin
  return (select coalesce(jsonb_agg(privado.midia_em_json(m) order by m.ordem,m.criado_em,m.id),'[]'::jsonb)
    from privado.midia m where m.estado <> 'expurgada'
      and (m.estabelecimento_id is null and m.dono_usuario_id=v_uid or privado.eh_membro(m.estabelecimento_id)));
end $$;
revoke all on function public.solicitar_upload_midia(text,text,bigint,uuid), public.confirmar_upload_midia(uuid),
  public.remover_midia(uuid), public.minhas_midias() from public, anon;
grant execute on function public.solicitar_upload_midia(text,text,bigint,uuid), public.confirmar_upload_midia(uuid),
  public.remover_midia(uuid), public.minhas_midias() to authenticated;
