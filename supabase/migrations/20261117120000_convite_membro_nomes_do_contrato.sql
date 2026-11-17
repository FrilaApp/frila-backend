-- convidar_membro, aceitar_convite_membro, remover_membro e transferir_administracao com os nomes
-- de parâmetro do CONTRATO (B-052).
--
-- A 20261109210000 criou as quatro com p_estabelecimento_id, p_email, p_papel, p_token, p_membro_id e
-- p_novo_admin_id. O contrato (contrato/openapi.yaml, /rpc/convidar_membro, /rpc/aceitar_convite_membro,
-- /rpc/remover_membro e /rpc/transferir_administracao) e a web mandam estabelecimento_id, email, papel,
-- token, membro_id e novo_admin_id: o PostgREST procura a função pelos NOMES do corpo e responde 404
-- PGRST202 (nenhum app chamava ainda). O código passa a obedecer ao contrato; o contrato não muda.
--
-- Trocar nome de parâmetro não cabe em create or replace: derruba as quatro assinaturas antigas e
-- recria com o MESMO corpo, os mesmos comentários e as mesmas permissões. Só as referências aos
-- parâmetros mudam, qualificadas pelo nome da função (convidar_membro.estabelecimento_id) para não
-- colidirem com colunas. Nenhuma outra função depende destas quatro (plpgsql liga o nome na chamada).
-- Os nomes antigos deixam de existir: ninguém chamava por eles.

select set_config('lock_timeout', '2s', true);

-- ── 1. Convidar membro ────────────────────────────────────────────────────────

drop function if exists public.convidar_membro(uuid, text, public.papel_membro);

create or replace function public.convidar_membro(
  estabelecimento_id uuid,
  email              text,
  papel              public.papel_membro
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid        uuid := (select auth.uid());
  v_email      text := lower(btrim(convidar_membro.email));
  v_token      text;
  v_token_hash text;
  v_expira     timestamptz;
  v_convite    privado.convite_membro%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();
  perform privado.exigir_perfil('contratante');

  if not privado.eh_administrador(convidar_membro.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  if not exists (select 1 from public.estabelecimento e where e.id = convidar_membro.estabelecimento_id) then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_email is null or v_email = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    perform public.erro(422, 'campo_invalido', 'email');
  end if;

  if convidar_membro.papel is null then
    perform public.erro(422, 'campo_obrigatorio', 'papel');
  end if;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_token_hash := encode(sha256(convert_to(v_token, 'UTF8')), 'hex');
  v_expira := privado.agora() + interval '7 days';

  insert into privado.convite_membro (
    estabelecimento_id, email, papel, convidado_por, token_hash, expira_em, criado_em
  ) values (
    convidar_membro.estabelecimento_id, v_email, convidar_membro.papel, v_uid, v_token_hash, v_expira, privado.agora()
  )
  returning * into v_convite;

  return jsonb_build_object(
    'convite_id',         v_convite.id,
    'estabelecimento_id', v_convite.estabelecimento_id,
    'email',              v_convite.email,
    'papel',              v_convite.papel,
    'token',              v_token,
    'expira_em',          v_convite.expira_em
  );
end $$;

comment on function public.convidar_membro(uuid, text, public.papel_membro) is
  'Gera convite para novo membro do estabelecimento com token de uso único (RF21). Exige administrador.';
revoke all on function public.convidar_membro(uuid, text, public.papel_membro) from public, anon;
grant execute on function public.convidar_membro(uuid, text, public.papel_membro) to authenticated;

-- ── 3. Aceitar convite ────────────────────────────────────────────────────────

drop function if exists public.aceitar_convite_membro(text);

create or replace function public.aceitar_convite_membro(
  token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid        uuid := (select auth.uid());
  v_perfil     public.perfil_conta;
  v_token_hash text;
  v_convite    privado.convite_membro%rowtype;
  v_membro     public.membro_estabelecimento%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  select u.perfil into v_perfil from public.usuario u where u.id = v_uid;
  if v_perfil = 'profissional' or v_perfil is distinct from 'contratante' then
    perform public.erro(422, 'perfil_incompativel');
  end if;

  if aceitar_convite_membro.token is null or btrim(aceitar_convite_membro.token) = '' then
    perform public.erro(422, 'convite_invalido');
  end if;

  v_token_hash := encode(sha256(convert_to(btrim(aceitar_convite_membro.token), 'UTF8')), 'hex');

  update privado.convite_membro
     set usado_em = privado.agora()
   where token_hash = v_token_hash
     and usado_em is null
     and expira_em > privado.agora()
  returning * into v_convite;

  if not found then
    perform public.erro(422, 'convite_invalido');
  end if;

  -- Serializa com remover_membro e com outro aceite no mesmo estabelecimento: a contagem de
  -- administradores abaixo só vale com a linha trancada. FOR NO KEY UPDATE não bloqueia as
  -- chaves estrangeiras que apontam para o estabelecimento (vaga, membro).
  perform 1 from public.estabelecimento e where e.id = v_convite.estabelecimento_id for no key update;

  -- Quem já é membro e aceita convite de outro papel troca de papel (ON CONFLICT abaixo). Se for
  -- o único administrador, o rebaixamento deixaria a casa sem administrador: mesma regra e mesmo
  -- código de remover_membro.
  select * into v_membro
    from public.membro_estabelecimento m
   where m.estabelecimento_id = v_convite.estabelecimento_id
     and m.usuario_id = v_uid;

  if found and v_membro.papel = 'administrador' and v_convite.papel <> 'administrador' then
    if not exists (select 1 from public.membro_estabelecimento m
                    where m.estabelecimento_id = v_convite.estabelecimento_id
                      and m.papel = 'administrador'
                      and m.usuario_id <> v_uid) then
      perform public.erro(422, 'ultimo_administrador');
    end if;
  end if;

  insert into public.membro_estabelecimento (
    usuario_id, perfil, estabelecimento_id, papel, criado_em
  ) values (
    v_uid, 'contratante', v_convite.estabelecimento_id, v_convite.papel, privado.agora()
  )
  on conflict (usuario_id, estabelecimento_id) do update
    set papel = excluded.papel
  returning * into v_membro;

  return jsonb_build_object(
    'membro_id',          v_membro.id,
    'estabelecimento_id', v_membro.estabelecimento_id,
    'usuario_id',         v_membro.usuario_id,
    'papel',              v_membro.papel
  );
end $$;

comment on function public.aceitar_convite_membro(text) is
  'Aceita convite de membro com token de uso único (RF21). Exige conta de contratante ativa.';
revoke all on function public.aceitar_convite_membro(text) from public, anon;
grant execute on function public.aceitar_convite_membro(text) to authenticated;

-- ── 3. Remover membro ─────────────────────────────────────────────────────────

drop function if exists public.remover_membro(uuid, uuid);

create or replace function public.remover_membro(
  estabelecimento_id uuid,
  membro_id          uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_membro public.membro_estabelecimento%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  if not privado.eh_administrador(remover_membro.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- Dois administradores removendo um ao outro ao mesmo tempo passariam os dois pela contagem
  -- abaixo e zerariam os administradores. A linha trancada serializa as chamadas; a contagem
  -- que vem depois lê o que a primeira já gravou (READ COMMITTED, uma foto por comando).
  perform 1 from public.estabelecimento e where e.id = remover_membro.estabelecimento_id for no key update;

  select * into v_membro
    from public.membro_estabelecimento m
   where m.estabelecimento_id = remover_membro.estabelecimento_id
     and (m.id = remover_membro.membro_id or m.usuario_id = remover_membro.membro_id);

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  if v_membro.papel = 'administrador' then
    if (select count(*) from public.membro_estabelecimento m
         where m.estabelecimento_id = remover_membro.estabelecimento_id
           and m.papel = 'administrador') <= 1 then
      perform public.erro(422, 'ultimo_administrador');
    end if;
  end if;

  delete from public.membro_estabelecimento where id = v_membro.id;

  return jsonb_build_object(
    'estabelecimento_id', remover_membro.estabelecimento_id,
    'membro_id',          v_membro.id,
    'usuario_id',         v_membro.usuario_id,
    'removido',           true
  );
end $$;

comment on function public.remover_membro(uuid, uuid) is
  'Remove membro do estabelecimento (RF21). Exige administrador. Impede remoção do último administrador.';
revoke all on function public.remover_membro(uuid, uuid) from public, anon;
grant execute on function public.remover_membro(uuid, uuid) to authenticated;

-- ── 5. Transferir administração ───────────────────────────────────────────────

-- ── 4. Transferir administração ───────────────────────────────────────────────

drop function if exists public.transferir_administracao(uuid, uuid);

create or replace function public.transferir_administracao(
  estabelecimento_id uuid,
  novo_admin_id      uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_novo public.membro_estabelecimento%rowtype;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  if not privado.eh_administrador(transferir_administracao.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  select * into v_novo
    from public.membro_estabelecimento m
   where m.estabelecimento_id = transferir_administracao.estabelecimento_id
     and (m.id = transferir_administracao.novo_admin_id or m.usuario_id = transferir_administracao.novo_admin_id);

  if not found then
    perform public.erro(404, 'nao_encontrado');
  end if;

  update public.membro_estabelecimento
     set papel = 'administrador'
   where id = v_novo.id
  returning * into v_novo;

  return jsonb_build_object(
    'estabelecimento_id',    transferir_administracao.estabelecimento_id,
    'novo_admin_id',         v_novo.id,
    'novo_admin_usuario_id', v_novo.usuario_id,
    'papel',                 v_novo.papel
  );
end $$;

comment on function public.transferir_administracao(uuid, uuid) is
  'Promove membro do estabelecimento a administrador (RF21). Exige ser administrador atual.';
revoke all on function public.transferir_administracao(uuid, uuid) from public, anon;
grant execute on function public.transferir_administracao(uuid, uuid) to authenticated;
