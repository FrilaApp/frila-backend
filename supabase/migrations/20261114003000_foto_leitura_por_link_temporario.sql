-- A foto de perfil se lê por um link temporário da Edge Function `ler-midia` (B-020, contrato 0.2.82).
--
-- Antes, `privado.foto_de_perfil_projecao` assinava a URL do Storage no próprio banco, com o segredo
-- legado `storage_jwt_secret` do Vault (20261109150000:13-17). Esse segredo não existe no dev nem no
-- Prod, e copiá-lo foi vetado pelo Lince Codex (08/11): ele assina também JWT de autenticação. Sem
-- ele, a foto aprovada nunca aparecia, e `minhas_midias` nunca montava `url`.
--
-- Agora, no molde da `upload_url` (20261108080000):
--   1. a leitura (perfil_publico, candidatos_da_vaga, detalhe_chamada, minhas_midias) confere o
--      vínculo, cunha um token opaco aleatório de 32 bytes e devolve
--      `…/functions/v1/ler-midia?midia_id=<id>&token=<64 hex>`. O banco guarda só o SHA-256, preso
--      à mídia e ao leitor, por 1 h;
--   2. a `ler-midia` chama `privado.resolver_link_leitura_midia`, que RECONFERE tudo na hora (hash,
--      validade, foto aprovada, titular ativo, recurso ligado, vínculo e bloqueio) e devolve o
--      caminho da miniatura, ou nulo;
--   3. a função assina com createSignedUrl (60 s, service role só no ambiente dela) e responde 302.
-- Nenhum segredo no Postgres. O caminho do arquivo nunca sai (RN15). O app não muda: `foto_url` e
-- `Midia.url` continuam uma URL que o AsyncImage abre sem cabeçalho.
--
-- `foto_de_perfil_projecao` passa de STABLE para VOLATILE (grava o hash). As três RPCs que a chamam
-- já são voláteis e o app as chama por POST; nenhuma assinatura pública muda. O vínculo é o mesmo
-- de 20261109150000:115-153, agora numa função própria que a projeção e o resolvedor usam.

select set_config('lock_timeout', '2s', true);

-- ── 1. Os hashes dos links ────────────────────────────────────────────────────
create table privado.midia_link_leitura (
  token_hash text        primary key constraint midia_link_leitura_hash check (token_hash ~ '^[0-9a-f]{64}$'),
  midia_id   uuid        not null references privado.midia(id) on delete cascade,
  leitor_id  uuid        not null,
  expira_em  timestamptz not null
);
create index midia_link_leitura_por_expiracao on privado.midia_link_leitura (expira_em);
create index midia_link_leitura_por_midia on privado.midia_link_leitura (midia_id);
alter table privado.midia_link_leitura enable row level security;
revoke all on table privado.midia_link_leitura from public, anon, authenticated;
comment on table privado.midia_link_leitura is
  'SHA-256 dos tokens de leitura da foto (B-020, contrato 0.2.82): mídia, leitor e validade de 1 h. O token em claro só existe na resposta da leitura. Vencidos saem em lote a cada link novo.';

-- ── 2. O vínculo de leitura (o mesmo de 20261109150000:115-153) ────────────────
-- Exatamente um entre p_profissional e p_estabelecimento.
create function privado.vinculo_de_leitura_da_foto(
  p_profissional    uuid,
  p_estabelecimento uuid,
  p_leitor          uuid
) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when p_leitor is null or (p_profissional is null) = (p_estabelecimento is null) then false
    when p_profissional is not null then exists (
      select 1
        from public.membro_estabelecimento me
       where me.usuario_id = p_leitor
         and (
           exists (select 1 from public.equipe_confianca ec
                    where ec.estabelecimento_id = me.estabelecimento_id
                      and ec.profissional_id = p_profissional)
           or exists (select 1 from public.candidatura c
                        join public.posicao pos on pos.id = c.posicao_id
                        join public.vaga v on v.id = pos.vaga_id
                       where v.estabelecimento_id = me.estabelecimento_id
                         and c.profissional_id = p_profissional)
           or exists (select 1 from public.posicao pos
                        join public.vaga v on v.id = pos.vaga_id
                       where v.estabelecimento_id = me.estabelecimento_id
                         and pos.profissional_id = p_profissional)
         ))
    else exists (
      select 1
        from public.profissional pr
       where pr.usuario_id = p_leitor
         and (
           exists (select 1 from public.candidatura c
                     join public.posicao pos on pos.id = c.posicao_id
                     join public.vaga v on v.id = pos.vaga_id
                    where v.estabelecimento_id = p_estabelecimento
                      and c.profissional_id = pr.id)
           or exists (select 1 from public.chamada ch
                       where ch.estabelecimento_id = p_estabelecimento
                         and ch.profissional_id = pr.id)
           or exists (select 1 from public.posicao pos
                        join public.vaga v on v.id = pos.vaga_id
                       where v.estabelecimento_id = p_estabelecimento
                         and pos.profissional_id = pr.id)
         ))
  end
$$;
comment on function privado.vinculo_de_leitura_da_foto(uuid, uuid, uuid) is
  'Vínculo de leitura da foto (contrato 0.2.54): foto de profissional, contratante de casa com equipe, candidatura ou turno; foto de estabelecimento, profissional com candidatura, chamada ou turno (B-020).';
revoke execute on function privado.vinculo_de_leitura_da_foto(uuid, uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.vinculo_de_leitura_da_foto(uuid, uuid, uuid) to service_role;

-- ── 3. A foto pode ser lida? (recurso, estado e titular) ──────────────────────
create function privado.foto_legivel(m privado.midia) returns boolean
language sql stable security definer set search_path = '' as $$
  select m.tipo = 'foto_perfil'
     and m.estado = 'aprovada'
     and coalesce((select bool_or(c.foto_de_perfil) from privado.configuracao_app c), false)
     and exists (select 1 from public.usuario u where u.id = m.dono_usuario_id and u.estado = 'ativa')
$$;
comment on function privado.foto_legivel(privado.midia) is
  'Foto de perfil aprovada, recurso foto_de_perfil ligado e titular ativo (RN13, RF25). Base da projeção, de minhas_midias e do resolvedor do link (B-020).';
revoke execute on function privado.foto_legivel(privado.midia) from public, anon, authenticated;
grant  execute on function privado.foto_legivel(privado.midia) to service_role;

-- ── 4. A URL da ler-midia (mesmo caminho da upload_url) ────────────────────────
create function privado.url_ler_midia() returns text
language sql volatile security definer set search_path = '' as $$
  select coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'ler_midia_function_url' limit 1),
    nullif(current_setting('frila.ler_midia_function_url', true), ''),
    (select replace(decrypted_secret, '/despachar', '/ler-midia')
       from vault.decrypted_secrets where name = 'edge_function_url' limit 1),
    'http://127.0.0.1:54321/functions/v1/ler-midia')
$$;
revoke execute on function privado.url_ler_midia() from public, anon, authenticated;
grant  execute on function privado.url_ler_midia() to service_role;

-- ── 5. Cunhar o link (quem chama já conferiu que o leitor pode ver) ────────────
create function privado.cunhar_link_leitura_midia(p_midia_id uuid, p_leitor uuid)
returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_token text := encode(extensions.gen_random_bytes(32), 'hex');
begin
  if p_midia_id is null or p_leitor is null then return null; end if;

  -- Vencidos saem em lote curto, para a tabela não crescer sem a retenção diária.
  delete from privado.midia_link_leitura l
   where l.token_hash in (select v.token_hash from privado.midia_link_leitura v
                           where v.expira_em <= privado.agora() limit 500);

  insert into privado.midia_link_leitura (token_hash, midia_id, leitor_id, expira_em)
  values (encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), p_midia_id, p_leitor,
          privado.agora() + interval '1 hour');

  return privado.url_ler_midia() || '?midia_id=' || p_midia_id || '&token=' || v_token;
end $$;
comment on function privado.cunhar_link_leitura_midia(uuid, uuid) is
  'Cunha o link de leitura de 1 h da foto para um leitor: token opaco de 32 bytes, só o SHA-256 no banco. Não confere vínculo: quem chama confere antes (B-020).';
revoke execute on function privado.cunhar_link_leitura_midia(uuid, uuid) from public, anon, authenticated;
grant  execute on function privado.cunhar_link_leitura_midia(uuid, uuid) to service_role;

-- ── 6. A projeção do PerfilPublico ────────────────────────────────────────────
-- Mesmas condições de 20261109150000:86-154; o fim troca a assinatura legada pelo link.
create or replace function privado.foto_de_perfil_projecao(
  p_profissional    uuid,
  p_estabelecimento uuid,
  p_leitor          uuid
) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_m privado.midia;
begin
  if p_leitor is null or (p_profissional is null) = (p_estabelecimento is null) then
    return '{}'::jsonb;
  end if;

  if p_profissional is not null then
    select m.* into v_m
      from privado.midia m
      join public.profissional p on p.usuario_id = m.dono_usuario_id
     where p.id = p_profissional
       and m.dono_tipo = 'profissional' and m.tipo = 'foto_perfil' and m.estado = 'aprovada'
     limit 1;
  else
    select m.* into v_m
      from privado.midia m
     where m.estabelecimento_id = p_estabelecimento
       and m.dono_tipo = 'estabelecimento' and m.tipo = 'foto_perfil' and m.estado = 'aprovada'
     limit 1;
  end if;
  if not found then return '{}'::jsonb; end if;

  if not privado.foto_legivel(v_m) then return '{}'::jsonb; end if;
  if not privado.vinculo_de_leitura_da_foto(p_profissional, p_estabelecimento, p_leitor) then
    return '{}'::jsonb;
  end if;

  return jsonb_build_object(
    'foto_id',  v_m.id,
    'foto_url', privado.cunhar_link_leitura_midia(v_m.id, p_leitor));
end $$;
comment on function privado.foto_de_perfil_projecao(uuid, uuid, uuid) is
  'As chaves foto_id e foto_url do PerfilPublico (contrato 0.2.54; link da ler-midia desde a 0.2.82), ou {}: recurso ligado, foto aprovada, titular ativo (RN13, RF25) e vínculo de leitura. Grava o hash do link, por isso é volátil (B-020).';

-- ── 7. O resolvedor, chamado pela ler-midia ───────────────────────────────────
-- Devolve o caminho da miniatura ou nulo. Qualquer falha é o mesmo nulo: a função responde 404.
create function privado.resolver_link_leitura_midia(p_midia_id uuid, p_token text)
returns text
language plpgsql stable security definer set search_path = '' as $$
declare
  v_leitor   uuid;
  v_m        privado.midia;
  v_prof     uuid;
begin
  if p_midia_id is null or p_token is null or p_token !~ '^[0-9a-f]{64}$' then
    return null;
  end if;

  select l.leitor_id into v_leitor
    from privado.midia_link_leitura l
   where l.token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex')
     and l.midia_id = p_midia_id
     and l.expira_em > privado.agora();
  if not found then return null; end if;

  select m.* into v_m from privado.midia m where m.id = p_midia_id;
  if not found or not privado.foto_legivel(v_m) then return null; end if;

  -- O titular (ou um membro da casa dona) vê a própria foto.
  if (v_m.estabelecimento_id is null and v_m.dono_usuario_id = v_leitor)
     or (v_m.estabelecimento_id is not null and exists (
           select 1 from public.membro_estabelecimento me
            where me.estabelecimento_id = v_m.estabelecimento_id and me.usuario_id = v_leitor)) then
    return replace(v_m.storage_path, '.jpg', '_thumb.jpg');
  end if;

  if v_m.dono_tipo = 'profissional' then
    -- RF26, como em perfil_publico: bloqueio com o leitor ou com uma casa da qual ele é membro.
    if exists (select 1 from public.bloqueio b
                where (b.autor_id = v_leitor and b.bloqueado_id = v_m.dono_usuario_id)
                   or (b.autor_id = v_m.dono_usuario_id and b.bloqueado_id = v_leitor))
       or exists (select 1 from public.membro_estabelecimento me
                   where me.usuario_id = v_leitor
                     and privado.bloqueado_com_estabelecimento(v_m.dono_usuario_id, me.estabelecimento_id)) then
      return null;
    end if;
    select p.id into v_prof from public.profissional p where p.usuario_id = v_m.dono_usuario_id;
    if v_prof is null or not privado.vinculo_de_leitura_da_foto(v_prof, null, v_leitor) then
      return null;
    end if;
  else
    if v_m.estabelecimento_id is null
       or privado.bloqueado_com_estabelecimento(v_leitor, v_m.estabelecimento_id)
       or not privado.vinculo_de_leitura_da_foto(null, v_m.estabelecimento_id, v_leitor) then
      return null;
    end if;
  end if;

  return replace(v_m.storage_path, '.jpg', '_thumb.jpg');
end $$;
comment on function privado.resolver_link_leitura_midia(uuid, text) is
  'Chamada só pela Edge Function ler-midia. Confere o hash do token, a validade de 1 h, a foto legível e, para quem não é o titular, o bloqueio (RF26) e o vínculo de leitura; devolve o caminho da miniatura ou nulo (B-020).';
revoke execute on function privado.resolver_link_leitura_midia(uuid, text) from public, anon, authenticated;
grant  execute on function privado.resolver_link_leitura_midia(uuid, text) to service_role;

-- ── 8. minhas_midias ganha `url` (contrato 0.2.54: "só quando aprovada") ──────
-- contrato: corpo-sem-mudanca-de-superficie public.minhas_midias 0.2.78
create or replace function public.minhas_midias() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := privado.usuario_midia();
begin
  return (select coalesce(jsonb_agg(
             privado.midia_em_json(m)
             || case when privado.foto_legivel(m)
                     then jsonb_build_object('url', privado.cunhar_link_leitura_midia(m.id, v_uid))
                     else '{}'::jsonb end
           order by m.criado_em, m.id), '[]'::jsonb)
    from privado.midia m where m.estado <> 'expurgada'
      and (m.estabelecimento_id is null and m.dono_usuario_id = v_uid or privado.eh_membro(m.estabelecimento_id)));
end $$;

-- `token_de_leitura_storage` fica sem uso e não se apaga (nada se apaga; sai numa fase 2).
comment on function privado.token_de_leitura_storage(text, text, integer) is
  'SEM USO desde 20261114003000 (B-020): a leitura da foto passou ao link da ler-midia. Assinava com storage_jwt_secret do Vault, que não existe no dev nem no Prod.';
