-- `perfil_publico`: o bloqueio passa a esconder o perfil público (cartão 1aGJPQK2, US26, RF26, UC17, contrato 0.2.28).
--
-- Conforme a decisão de produto de 30/09/2026 registrada no contrato 0.2.27 e formalizada
-- na 0.2.28:
--   * devolve `404 nao_encontrado` quando há bloqueio entre quem chama e o perfil consultado,
--     nos dois sentidos (quem bloqueou não vê quem foi bloqueado, e quem foi bloqueado não vê quem bloqueou);
--   * vale também quando a outra parte é membro do estabelecimento consultado, como já vale
--     para vagas e candidaturas;
--   * a resposta é a mesma de um id que não existe (404 nao_encontrado): o cliente mostra
--     "perfil indisponível" sem revelar que houve bloqueio.

create or replace function public.perfil_publico(id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid       uuid := (select auth.uid());
  v_prof_user uuid;
  v_perfil    jsonb;
begin
  if v_uid is null then
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

    v_perfil := privado.perfil_publico_profissional(perfil_publico.id);

  -- 2. Perfil de estabelecimento
  elsif exists (select 1 from public.estabelecimento e where e.id = perfil_publico.id) then
    -- RF26: bloqueio com qualquer membro do estabelecimento nos dois sentidos.
    if privado.bloqueado_com_estabelecimento(v_uid, perfil_publico.id) then
      perform public.erro(404, 'nao_encontrado');
    end if;

    v_perfil := privado.estabelecimento_publico(perfil_publico.id);
  end if;

  -- 3. Id que não é profissional nem estabelecimento (ou não encontrado)
  if v_perfil is null then
    perform public.erro(404, 'nao_encontrado');
  end if;

  return v_perfil;
end $$;

comment on function public.perfil_publico(uuid) is
  'Perfil público de profissional ou estabelecimento: nome, funções, positivas e total, taxa de comparecimento, turnos realizados e considerados (RF16, RN08). Nunca telefone, e-mail, nascimento, documento ou ponto base (RN10). Conta anonimizada aparece como "Conta encerrada" (RF25). Bloqueio entre as partes (nos dois sentidos ou com membro do estabelecimento) responde 404 (RF26, contrato 0.2.28).';

revoke execute on function public.perfil_publico(uuid) from public, anon;
grant  execute on function public.perfil_publico(uuid) to authenticated;
