-- B4b: Estreitamento da foto de perfil, remoção de colunas mortas,
-- ocultação por 2 denúncias distintas e expurgo em 24 h (RN37, CA4).

set lock_timeout = '2s';

-- 1. Preflights de segurança antes das alterações estruturais DDL (achado 3 do Lince Codex).
-- Aborta a migração de forma segura caso existam dados em produção fora do esperado.
do $$
declare
  v_invalidas bigint;
  v_com_dados bigint;
begin
  select count(*) into v_invalidas
    from privado.midia
   where tipo not in ('foto_perfil');
  if v_invalidas > 0 then
    raise exception 'Abortando migracao: existem % midias com tipo diferente de foto_perfil', v_invalidas;
  end if;

  select count(*) into v_com_dados
    from privado.midia
   where legenda is not null or funcao_id is not null or ordem is not null;
  if v_com_dados > 0 then
    raise exception 'Abortando migracao: existem % midias com metadados preenchidos (legenda/funcao_id/ordem)', v_com_dados;
  end if;
end $$;

-- Estreitamento de midia_tipo para ('foto_perfil') com lock curto (ADD NOT VALID).
-- A validação da constraint (VALIDATE) ocorre na migração subsequente 20261107310001
-- em transação separada para liberar leituras e escritas concorrentes na tabela.
alter table privado.midia drop constraint if exists midia_tipo;
alter table privado.midia add constraint midia_tipo check (tipo in ('foto_perfil')) not valid;

alter table privado.midia drop column if exists legenda;
alter table privado.midia drop column if exists funcao_id;
alter table privado.midia drop column if exists ordem;

-- Coluna midia_id em ocorrencia para denúncias de fotos específicas (contrato 0.2.54)
alter table public.ocorrencia
  add column if not exists midia_id uuid references privado.midia(id) on delete set null;

create index if not exists idx_ocorrencia_midia_id on public.ocorrencia(midia_id) where midia_id is not null;

-- 2. Atualiza minhas_midias para ordenar por criado_em, id (sem ordem).
-- contrato: corpo-sem-mudanca-de-superficie public.minhas_midias 0.2.57
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
  -- Idempotente: se já estiver expurgada, retorna true imediatamente sem reescrever data
  if exists (select 1 from privado.midia where id = p_id and estado = 'expurgada') then
    return true;
  end if;

  update privado.midia m
     set estado = 'expurgada',
         atualizado_em = privado.agora()
   where m.id = p_id
     and m.estado in ('recusada', 'nao_publicada', 'removida')
  returning true into v_ok;

  return coalesce(v_ok, false);
end $$;

comment on function privado.confirmar_expurgo_midia_perfil(uuid) is
  'Fecha o expurgo de mídia de perfil após remoção dos bytes no Storage. Chamada com service_role pela Edge Function expurgar-midias. Idempotente.';

revoke execute on function privado.confirmar_expurgo_midia_perfil(uuid) from public, anon, authenticated;
grant  execute on function privado.confirmar_expurgo_midia_perfil(uuid) to service_role;

-- 4. Expurgo em 24 h de mídias recusadas ou não publicadas (RN37, CA4).
-- Elegibilidade: recusada ou não publicada há 24 h ou mais (<= agora - 24 hours).
-- A agenda periódica horária no pg_cron garante que nenhuma foto espere mais que 24h + 1h.
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
     where estado in ('recusada', 'nao_publicada')
       and atualizado_em <= privado.agora() - interval '24 hours'
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
  'Enfileira para expurgo físico no Storage as fotos recusadas ou não publicadas há mais de 24 horas e marca estado=expurgada. Idempotente.';

revoke execute on function privado.expurgar_midias_recusadas() from public, anon, authenticated;
grant  execute on function privado.expurgar_midias_recusadas() to service_role;

-- 4b. Validação prévia de elegibilidade de expurgo de foto de perfil (achado 4 do Lince Codex).
create or replace function privado.validar_expurgo_midia_perfil(
  p_id uuid,
  p_bucket text,
  p_caminhos jsonb default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_m record;
  v_elem text;
begin
  if p_bucket is not null and p_bucket <> 'midia-perfil' then
    return false;
  end if;

  select id, estado, storage_path into v_m
    from privado.midia
   where id = p_id;

  if not found then
    return false;
  end if;

  if v_m.estado not in ('recusada', 'nao_publicada', 'removida', 'expurgada') then
    return false;
  end if;

  if p_caminhos is not null and jsonb_typeof(p_caminhos) = 'array' and jsonb_array_length(p_caminhos) > 0 then
    for v_elem in select jsonb_array_elements_text(p_caminhos) loop
      if v_elem <> v_m.storage_path and v_elem <> replace(v_m.storage_path, '.jpg', '_thumb.jpg') then
        return false;
      end if;
    end loop;
  end if;

  return true;
end $$;

comment on function privado.validar_expurgo_midia_perfil(uuid, text, jsonb) is
  'Valida antes da exclusão física que a mídia existe, está em estado elegível e pertence ao bucket/caminhos corretos (achado 4 Lince Codex).';

revoke execute on function privado.validar_expurgo_midia_perfil(uuid, text, jsonb) from public, anon, authenticated;
grant  execute on function privado.validar_expurgo_midia_perfil(uuid, text, jsonb) to service_role;

-- 5. Atualiza remover_midia para enfileirar expurgo imediatamente.
-- contrato: corpo-sem-mudanca-de-superficie public.remover_midia 0.2.57
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

-- 6. Atualiza public.denunciar para aceitar midia_id opcional (contrato 0.2.54).
-- contrato: corpo-sem-mudanca-de-superficie public.denunciar 0.2.57
drop function if exists public.denunciar(text, uuid, text, text, uuid, uuid);
create or replace function public.denunciar(
  alvo_tipo text,
  alvo_id   uuid,
  motivo    text,
  relato    text,
  chave     uuid,
  turno_id  uuid default null,
  midia_id  uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid     uuid := (select auth.uid());
  v_tipo    text := denunciar.alvo_tipo;
  v_alvo    uuid := denunciar.alvo_id;
  v_motivo  text := btrim(denunciar.motivo);
  v_relato  text := btrim(denunciar.relato);
  v_chave   uuid := denunciar.chave;
  v_turno   uuid := denunciar.turno_id;
  v_midia   uuid := denunciar.midia_id;
  v_usuario uuid;
  v_estab   uuid;
  v_t_prof  uuid;
  v_t_estab uuid;
  v_oc      public.ocorrencia%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  if v_chave is null then
    perform public.erro(422, 'campo_obrigatorio', 'chave');
  end if;

  select * into v_oc from public.ocorrencia o
   where o.autor_id = v_uid and o.chave_cliente = v_chave and o.tipo = 'denuncia';
  if found then
    return jsonb_build_object('ocorrencia_id', v_oc.id, 'tipo', 'denuncia',
                              'criada_em', v_oc.criada_em,
                              'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em));
  end if;

  if v_tipo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_tipo');
  end if;
  if v_alvo is null then
    perform public.erro(422, 'campo_obrigatorio', 'alvo_id');
  end if;
  if v_motivo is null or v_motivo = '' then
    perform public.erro(422, 'campo_obrigatorio', 'motivo');
  end if;
  if v_relato is null or v_relato = '' then
    perform public.erro(422, 'campo_obrigatorio', 'relato');
  end if;
  if v_tipo not in ('profissional', 'estabelecimento') then
    perform public.erro(422, 'campo_invalido', 'alvo_tipo');
  end if;
  if not (v_motivo = any (enum_range(null::public.motivo_denuncia)::text[])) then
    perform public.erro(422, 'campo_invalido', 'motivo');
  end if;
  if char_length(v_relato) < 10 then
    perform public.erro(422, 'campo_invalido', 'relato');
  end if;

  if v_tipo = 'estabelecimento' then
    select e.id into v_estab from public.estabelecimento e where e.id = v_alvo;
    if v_estab is null then
      perform public.erro(404, 'nao_encontrado');
    end if;
    if exists (select 1 from public.membro_estabelecimento m
                where m.estabelecimento_id = v_estab and m.usuario_id = v_uid) then
      perform public.erro(422, 'campo_invalido', 'alvo_id');
    end if;
  else
    select p.usuario_id into v_usuario from public.profissional p where p.id = v_alvo;
    if v_usuario is null then
      perform public.erro(404, 'nao_encontrado');
    end if;
    if v_usuario = v_uid then
      perform public.erro(422, 'campo_invalido', 'alvo_id');
    end if;
  end if;

  -- Validação de mídia quando informada (contrato 0.2.54)
  if v_midia is not null then
    if v_tipo = 'estabelecimento' then
      if not exists (
        select 1 from privado.midia m
         where m.id = v_midia
           and m.estabelecimento_id = v_estab
           and m.tipo = 'foto_perfil'
      ) then
        perform public.erro(422, 'campo_invalido', 'midia_id');
      end if;
    else
      if not exists (
        select 1 from privado.midia m
         where m.id = v_midia
           and m.dono_usuario_id = v_usuario
           and m.estabelecimento_id is null
           and m.tipo = 'foto_perfil'
      ) then
        perform public.erro(422, 'campo_invalido', 'midia_id');
      end if;
    end if;
  end if;

  if v_turno is not null then
    select p.profissional_id, v.estabelecimento_id into v_t_prof, v_t_estab
      from public.turno t
      join public.posicao p on p.id = t.posicao_id
      join public.vaga v    on v.id = p.vaga_id
     where t.id = v_turno;

    if not found
       or not (
         (v_estab is not null
            and v_t_estab = v_estab
            and exists (select 1 from public.profissional p
                         where p.id = v_t_prof and p.usuario_id = v_uid))
         or
         (v_usuario is not null
            and exists (select 1 from public.profissional p
                         where p.id = v_t_prof and p.usuario_id = v_usuario)
            and exists (select 1 from public.membro_estabelecimento m
                         where m.estabelecimento_id = v_t_estab and m.usuario_id = v_uid))
       ) then
      perform public.erro(404, 'nao_encontrado');
    end if;
  end if;

  insert into public.ocorrencia (
    tipo, turno_id, usuario_id, estabelecimento_id, autor_id,
    motivo, relato, chave_cliente, criada_em, midia_id
  ) values (
    'denuncia', v_turno, v_usuario, v_estab, v_uid,
    v_motivo::public.motivo_denuncia, v_relato, v_chave, privado.agora(), v_midia
  )
  on conflict (autor_id, chave_cliente) do nothing
  returning * into v_oc;

  if v_oc.id is null then
    select * into v_oc from public.ocorrencia o
     where o.autor_id = v_uid and o.chave_cliente = v_chave and o.tipo = 'denuncia';
  else
    perform pgmq.send('email', jsonb_build_object('tipo', 'denuncia', 'ocorrencia_id', v_oc.id));
  end if;

  return jsonb_build_object(
    'ocorrencia_id', v_oc.id,
    'tipo', 'denuncia',
    'criada_em', v_oc.criada_em,
    'prazo_resposta_ate', privado.prazo_de_resposta(v_oc.criada_em)
  );
end $$;

comment on function public.denunciar(text, uuid, text, text, uuid, uuid, uuid) is
  'Registra denúncia contra a outra parte (RF26, RN13, RN15, UC17, CD-M07), opcionalmente vinculada a midia_id, e enfileira o e-mail à Equipe Frila na fila email, só com o id (RN15). Idempotente pela chave do app. Devolve o Protocolo com prazo de 5 dias úteis.';

revoke execute on function public.denunciar(text, uuid, text, text, uuid, uuid, uuid) from public, anon;
grant  execute on function public.denunciar(text, uuid, text, text, uuid, uuid, uuid) to authenticated;

-- 7. Trigger de 2 denúncias distintas para ocultar foto de perfil aprovada (CD-M07 / CA4).
create or replace function privado.processar_denuncia_midia()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_distintas bigint;
begin
  -- Só denúncia com midia_id vinculada pode afetar a foto de perfil (CD-M07 / CA4).
  -- Denúncia genérica sobre o perfil não toca na foto.
  if new.tipo <> 'denuncia' or new.midia_id is null then
    return new;
  end if;

  -- Serializa a contagem por foto para evitar corrida em denúncias simultâneas (achado 2 Lince Codex R2)
  perform 1 from privado.midia where id = new.midia_id for no key update;

  -- Conta denunciantes distintos elegíveis desta foto:
  -- 1) Autor com conta ativa (u.estado = 'ativa')
  -- 2) Sem bloqueio recíproco entre autor e o alvo
  if new.usuario_id is not null then
    select count(distinct o.autor_id) into v_distintas
      from public.ocorrencia o
      join public.usuario u on u.id = o.autor_id
     where o.midia_id = new.midia_id
       and o.tipo = 'denuncia'
       and u.estado = 'ativa'
       and not exists (
         select 1 from public.bloqueio b
          where (b.autor_id = o.autor_id and b.bloqueado_id = new.usuario_id)
             or (b.autor_id = new.usuario_id and b.bloqueado_id = o.autor_id)
       );
  elsif new.estabelecimento_id is not null then
    select count(distinct o.autor_id) into v_distintas
      from public.ocorrencia o
      join public.usuario u on u.id = o.autor_id
     where o.midia_id = new.midia_id
       and o.tipo = 'denuncia'
       and u.estado = 'ativa'
       and not exists (
         select 1 from public.membro_estabelecimento m
         join public.bloqueio b on (b.autor_id = o.autor_id and b.bloqueado_id = m.usuario_id)
                                or (b.autor_id = m.usuario_id and b.bloqueado_id = o.autor_id)
          where m.estabelecimento_id = new.estabelecimento_id
       );
  end if;

  update privado.midia
     set denuncias_distintas = coalesce(v_distintas, 0)::smallint,
         estado = case when coalesce(v_distintas, 0) >= 2 and estado = 'aprovada' then 'ocultada' else estado end,
         atualizado_em = privado.agora()
   where id = new.midia_id;

  -- Se ocultada por atingir o limiar de 2 denúncias, dispara reanálise automática
  if coalesce(v_distintas, 0) >= 2 then
    perform pgmq.send(
      'moderacao_midia',
      jsonb_build_object(
        'midia_id', new.midia_id,
        'reanalise', true,
        'origem', 'denuncia'
      )
    );
  end if;

  return new;
end $$;

drop trigger if exists trg_denuncia_processar_midia on public.ocorrencia;
create trigger trg_denuncia_processar_midia
after insert on public.ocorrencia
for each row execute function privado.processar_denuncia_midia();

-- 8. Pluga expurgo de mídias recusadas na retenção diária existente.
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

-- 9. Compatibilidade de exportação de dados com PerfilProfissionalDetalhado (contrato 0.2.58+).
create or replace function privado.meus_dados(p_usuario uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with conta as (
    select * from public.usuario u where u.id = p_usuario
  ),
  prof as (
    select p.* from public.profissional p where p.usuario_id = p_usuario
  ),
  casas as (
    select m.estabelecimento_id, m.papel, e.nome, e.tipo
      from public.membro_estabelecimento m
      join public.estabelecimento e on e.id = m.estabelecimento_id
     where m.usuario_id = p_usuario
  )
  select jsonb_build_object(
    'gerado_em', privado.agora(),

    'conta', jsonb_build_object(
      'id',         c.id,
      'perfil',     c.perfil,
      'nome',       c.nome,
      'telefone',   c.telefone,
      'email',      c.email,
      'nascimento', c.nascimento,
      'estado',     c.estado),

    'perfil_profissional',
      (select public.perfil_profissional_em_json(p) || jsonb_build_object(
         'apresentacao', null,
         'onde_trabalhei', null,
         'experiencia_faixa', null,
         'cursos', '[]'::jsonb,
         'idiomas', '[]'::jsonb,
         'servicos', '[]'::jsonb,
         'regioes', '[]'::jsonb,
         'atende_todo_df', false
       ) from prof p),

    'estabelecimentos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',        k.estabelecimento_id,
               'nome',      k.nome,
               'tipo',      k.tipo,
               'papel',     k.papel,
               'reputacao', privado.estabelecimento_publico(k.estabelecimento_id)->'reputacao')
             order by k.nome)
        from casas k), '[]'::jsonb),

    'disponibilidade', coalesce((
      select jsonb_agg(jsonb_build_object(
               'dia_semana',  d.dia_semana,
               'hora_inicio', to_char(d.hora_inicio, 'HH24:MI'),
               'hora_fim',    to_char(d.hora_fim,    'HH24:MI'))
             order by d.dia_semana, d.hora_inicio)
        from public.disponibilidade d
        join prof p on p.id = d.profissional_id), '[]'::jsonb),

    'turnos', coalesce((
      select jsonb_agg(privado.turno_em_json(t.id, p_usuario) order by po.inicio_em desc)
        from public.turno t
        join public.posicao po on po.id = t.posicao_id
        join public.vaga v     on v.id = po.vaga_id
       where po.profissional_id in (select p.id from prof p)
          or v.estabelecimento_id in (select k.estabelecimento_id from casas k)),
      '[]'::jsonb),

    'avaliacoes_dadas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'turno_id',  a.turno_id,
               'resposta',  a.resposta,
               'criada_em', a.criada_em)
             order by a.criada_em desc)
        from public.avaliacao a
       where a.autor_id = p_usuario), '[]'::jsonb),

    'avaliacoes_recebidas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'turno_id',  a.turno_id,
               'resposta',  a.resposta,
               'criada_em', a.criada_em)
             order by a.criada_em desc)
        from public.avaliacao a
       where (a.alvo_tipo = 'profissional'
                and a.alvo_id in (select p.id from prof p))
          or (a.alvo_tipo = 'estabelecimento'
                and a.alvo_id in (select k.estabelecimento_id from casas k))),
      '[]'::jsonb),

    'dispositivos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'plataforma',    di.plataforma,
               'atualizado_em', di.atualizado_em)
             order by di.atualizado_em desc)
        from public.dispositivo di
       where di.usuario_id = p_usuario), '[]'::jsonb),

    'candidaturas', coalesce((
      select jsonb_agg(privado.candidatura_em_json(cd.id) order by cd.criada_em desc, cd.id)
        from public.candidatura cd
       where cd.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    'ocorrencias', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',        o.id,
               'tipo',      o.tipo,
               'papel',     case when o.autor_id = p_usuario then 'autor' else 'alvo' end,
               'criada_em',    o.criada_em,
               'resolvido_em', o.resolvido_em,
               'motivo',    case
                              when o.autor_id = p_usuario or o.tipo = 'suspensao'
                                then o.motivo
                              else null
                            end)
             order by o.criada_em desc)
        from public.ocorrencia o
       where o.autor_id = p_usuario or o.usuario_id = p_usuario), '[]'::jsonb),

    'bloqueios', coalesce((
      select jsonb_agg(x.o order by x.criado_em desc)
        from (
          select distinct jsonb_build_object(
                   'alvo_tipo', 'profissional',
                   'alvo_id',   pb.id,
                   'criado_em', b.criado_em) as o,
                 b.criado_em
            from public.bloqueio b
            join public.profissional pb on pb.usuario_id = b.bloqueado_id
           where b.autor_id = p_usuario
          union
          select distinct jsonb_build_object(
                   'alvo_tipo', 'estabelecimento',
                   'alvo_id',   mb.estabelecimento_id,
                   'criado_em', b.criado_em) as o,
                 b.criado_em
            from public.bloqueio b
            join public.usuario ub on ub.id = b.bloqueado_id and ub.perfil = 'contratante'
            join public.membro_estabelecimento mb on mb.usuario_id = b.bloqueado_id
           where b.autor_id = p_usuario
        ) x), '[]'::jsonb),

    'notificacoes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'tipo',          n.tipo,
               'referencia_id', n.referencia_id,
               'payload',       n.payload,
               'enviada_em',    n.enviada_em,
               'entregue_em',   n.entregue_em)
             order by n.enviada_em desc nulls last)
        from public.notificacao n
       where n.usuario_id = p_usuario), '[]'::jsonb),

    'despachos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'vaga_id',   ds.vaga_id,
               'criado_em', ds.criado_em,
               'reaberta',  ds.reaberta)
             order by ds.criado_em desc)
        from public.despacho ds
       where ds.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    'equipe_confianca', coalesce((
      select jsonb_agg(jsonb_build_object(
               'estabelecimento_id', ec.estabelecimento_id,
               'nome',               es.nome,
               'adicionado_em',      ec.adicionado_em)
             order by ec.adicionado_em desc)
        from public.equipe_confianca ec
        join public.estabelecimento es on es.id = ec.estabelecimento_id
       where ec.profissional_id in (select p.id from prof p)), '[]'::jsonb),

    'pedido_de_exclusao', (
      select jsonb_build_object(
               'pedido_em',    pe.pedido_em,
               'estado',       pe.estado,
               'tentativas',   pe.tentativas,
               'concluido_em', pe.concluido_em)
        from public.pedido_de_exclusao pe
       where pe.usuario_id = p_usuario
       order by pe.pedido_em desc
       limit 1),

    'eventos_app', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',          ea.id,
               'evento',      ea.evento,
               'vaga_id',     ea.vaga_id,
               'turno_id',    ea.turno_id,
               'ocorrido_em', ea.ocorrido_em,
               'criado_em',   ea.criado_em)
             order by ea.ocorrido_em desc, ea.criado_em desc, ea.id desc)
        from public.evento_app ea
       where ea.usuario_id = p_usuario), '[]'::jsonb)
  )
  from conta c
$$;

revoke execute on function privado.meus_dados(uuid) from public, anon, authenticated;
grant  execute on function privado.meus_dados(uuid) to service_role;

-- 10. Disparo de expurgo de mídias e agendamento horário no pg_cron (RN37, CA4 / achado 1 do Lince Codex).
create or replace function privado.disparar_expurgo_midias()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'expurgar_midias_function_url' limit 1),
    nullif(current_setting('frila.expurgar_midias_function_url', true), ''),
    (select replace(decrypted_secret, '/despachar', '/expurgar-midias')
       from vault.decrypted_secrets where name = 'edge_function_url' limit 1),
    'http://127.0.0.1:54321/functions/v1/expurgar-midias'
  );
  v_secret text := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.agendador_secret', true), '')
  );
  v_req_id bigint;
begin
  -- Enfileira mídias elegíveis antes de disparar o expurgo físico no Storage (achados 1 e 3 do Lince Codex)
  perform privado.expurgar_midias_recusadas();

  if v_secret is null or v_secret = '' then
    raise warning 'frila.agendador_secret ausente: o expurgo de mídias não foi disparado';
    return null;
  end if;

  begin
    v_req_id := net.http_post(
      url     => v_url,
      headers => jsonb_build_object(
        'Content-Type',       'application/json',
        'Authorization',      'Bearer ' || v_secret,
        'x-agendador-secret', v_secret
      ),
      body    => jsonb_build_object('origem', 'cron'),
      timeout_milliseconds => 5000
    );
  exception when others then
    v_req_id := null;
  end;

  return v_req_id;
end $$;

comment on function privado.disparar_expurgo_midias() is
  'Enfileira mídias elegíveis (expurgar_midias_recusadas) e dispara a Edge Function expurgar-midias via pg_net. Lê expurgar_midias_function_url (ou deriva de edge_function_url) e agendador_secret do Vault, com fallback ao GUC. Nunca aborta quem chamou (bebr4VIE).';

revoke execute on function privado.disparar_expurgo_midias() from public, anon, authenticated;
grant  execute on function privado.disparar_expurgo_midias() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule('expurgar_midias_horario')
      where exists (select 1 from cron.job where jobname = 'expurgar_midias_horario');
    perform cron.schedule(
      'expurgar_midias_horario',
      '0 * * * *',
      'select privado.disparar_expurgo_midias()'
    );
  end if;
end $$;

