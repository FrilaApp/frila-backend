-- Migração: 20261109185000_perfil_publico_volta_a_foto.sql
-- Escopo: devolve foto_url e foto_id a public.perfil_publico (contrato 0.2.54), corrigindo a 20261109180000.
--
-- A 20261109150000 (#453) fez perfil_publico projetar a foto com
-- `|| privado.foto_de_perfil_projecao(...)`. A 20261109180000 (R9, #469) recriou a função
-- partindo do corpo anterior à 150000 e apagou essas duas linhas, tirando a foto do perfil.
-- Como a 180000 já está aplicada, ela não é editada: esta migração recria perfil_publico com
-- o corpo exato da 150000. Só o corpo volta; a superfície (assinatura, retorno, privilégios) é a mesma.

-- contrato: corpo-sem-mudanca-de-superficie public.perfil_publico 0.2.68
create or replace function public.perfil_publico(id uuid)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid       uuid := (select auth.uid());
  v_prof_user uuid;
  v_perfil    jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'anonimizada') then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- 1. Perfil profissional
  v_prof_user := privado.usuario_do_profissional(perfil_publico.id);
  if v_prof_user is not null then
    -- RF26: bloqueio nos dois sentidos entre quem chama e o profissional,
    -- ou entre o profissional e qualquer estabelecimento do qual quem chama é membro.
    if exists (
      select 1 from public.bloqueio b
       where (b.autor_id = v_uid and b.bloqueado_id = v_prof_user)
          or (b.autor_id = v_prof_user and b.bloqueado_id = v_uid)
    ) or exists (
      select 1 from public.membro_estabelecimento m
       where m.usuario_id = v_uid
         and privado.bloqueado_com_estabelecimento(v_prof_user, m.estabelecimento_id)
    ) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.perfil_publico_profissional(perfil_publico.id)
                || privado.foto_de_perfil_projecao(perfil_publico.id, null, v_uid);

  -- 2. Perfil de estabelecimento
  elsif exists (select 1 from public.estabelecimento e where e.id = perfil_publico.id) then
    -- RF26: bloqueio com qualquer membro do estabelecimento nos dois sentidos.
    if privado.bloqueado_com_estabelecimento(v_uid, perfil_publico.id) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.estabelecimento_publico(perfil_publico.id)
                || privado.foto_de_perfil_projecao(null, perfil_publico.id, v_uid);
  end if;

  -- 3. Id que não é profissional nem estabelecimento (ou não encontrado)
  if v_perfil is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return v_perfil;
end $$;

comment on function public.perfil_publico(uuid) is
  'Perfil público de profissional ou estabelecimento por id. Profissional ganha campos ricos da F2 se quem lê tem vínculo legítimo. A reputação do profissional reflete o histórico vivo e a base histórica expurgada (R9). foto_url e foto_id (0.2.54) só com vínculo de leitura, recurso ligado, foto aprovada e titular ativo. Devolve 404 para id inexistente e para bloqueio mútuo.';

revoke execute on function public.perfil_publico(uuid) from public, anon;
grant  execute on function public.perfil_publico(uuid) to authenticated;
