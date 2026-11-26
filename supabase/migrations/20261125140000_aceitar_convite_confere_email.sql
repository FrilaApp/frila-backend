-- B-123 (ROPA, convites de membros, item 1): o aceite do convite confere o e-mail do convidado.
--
-- Até aqui `public.aceitar_convite_membro` só conferia o token (hash) e se a conta é de contratante
-- ativa: quem recebesse o link por encaminhamento entrava na casa. Passa a valer: depois de validar
-- o token, o e-mail da conta que aceita (auth.users.email do auth.uid()) tem de ser igual ao do
-- convite, em lower(btrim()) dos dois lados, e a conta tem de ter o e-mail CONFIRMADO
-- (email_confirmed_at preenchido). Conta sem e-mail ou com e-mail não confirmado cai na mesma recusa.
--
-- Recusa: 403 `convite_de_outro_email`, sem details e sem revelar o e-mail do convite nem o da conta.
-- A recusa NÃO consome o convite: public.erro() levanta exceção e desfaz o `update ... usado_em`
-- acima dela, então a conta certa ainda aceita depois (provado no pgTAP 902).
--
-- Ordem das recusas: 401 → conta ativa → 422 perfil_incompativel → 422 convite_invalido (token
-- vazio/errado/usado/vencido) → 403 convite_de_outro_email. Token inexistente continua
-- `convite_invalido` e não vaza nada. A ordem das travas (update do convite, depois o estabelecimento
-- FOR NO KEY UPDATE) e a troca de papel de quem já é membro (`ultimo_administrador`) não mudam.
--
-- Mesma assinatura (parâmetro `token`), mesmos grants: create or replace, sem drop. Sem coluna nova,
-- sem tabela nova e sem registro de e-mail (LGPD): o e-mail só é comparado, nunca gravado nem citado.

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
  v_email      text;
  v_confirmado timestamptz;
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

  -- O convite é do e-mail dele: só a conta com esse e-mail, já confirmado, aceita. O erro() abaixo
  -- levanta exceção e desfaz o update acima, então a recusa não gasta o convite. Mensagem única
  -- (sem details): não diz qual e-mail o convite tem nem qual a conta tem.
  select u.email, u.email_confirmed_at into v_email, v_confirmado
    from auth.users u
   where u.id = v_uid;

  if v_confirmado is null
     or v_email is null
     or lower(btrim(v_email)) <> lower(btrim(v_convite.email)) then
    perform public.erro(403, 'convite_de_outro_email');
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
  'Aceita convite de membro com token de uso único (RF21). Exige conta de contratante ativa e o e-mail da conta (confirmado) igual ao do convite, sem diferenciar maiúsculas e espaços; outro e-mail: 403 convite_de_outro_email, sem consumir o convite.';
revoke all on function public.aceitar_convite_membro(text) from public, anon;
grant execute on function public.aceitar_convite_membro(text) to authenticated;
