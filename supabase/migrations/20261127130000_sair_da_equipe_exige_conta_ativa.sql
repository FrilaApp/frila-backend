-- DlXntCMo: `public.sair_da_equipe` passa a recusar o token de conta encerrada ou anonimizada com 401 `nao_autenticado` (RF25).
--
-- O contrato promete o 401 para "token ... de conta já encerrada/anonimizada" (tabela de erros, RF25) e, nas operações de escrita, "token de conta encerrada
-- recebe 401 nao_autenticado". A definição de 20261109200000 não chamava `privado.exigir_conta_ativa()`. Aqui a chamada vem logo depois da conferência de
-- `auth.uid()`; o 403 `conta_suspensa` existente fica como está (`exigir_conta_ativa` dá o mesmo 403 à conta suspensa).
--
-- Corpo de 20261109200000 com um `perform` a mais. Assinatura, grants e comentário não mudam.

-- contrato: corpo-sem-mudanca-de-superficie public.sair_da_equipe 0.2.118
create or replace function public.sair_da_equipe(
  estabelecimento_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid             uuid := (select auth.uid());
  v_profissional_id uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- RF25: token de conta encerrada ou anonimizada é 401 nao_autenticado (contrato, tabela de erros e 0.2.x "Token de conta encerrada").
  -- A conta suspensa segue com o 403 conta_suspensa logo abaixo.
  perform privado.exigir_conta_ativa();

  if exists (select 1 from public.usuario u where u.id = v_uid and u.estado = 'suspensa') then
    perform public.erro(403, 'sem_permissao', 'conta_suspensa');
  end if;

  -- RN25: apenas o próprio profissional pode pedir sua autoexclusão da equipe
  v_profissional_id := privado.meu_profissional_id();
  if v_profissional_id is null then
    perform public.erro(403, 'sem_permissao');
  end if;

  if sair_da_equipe.estabelecimento_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'estabelecimento_id');
  end if;

  if not exists (
    select 1
      from public.equipe_confianca ec
     where ec.estabelecimento_id = sair_da_equipe.estabelecimento_id
       and ec.profissional_id = v_profissional_id
  ) then
    perform public.erro(422, 'campo_invalido', 'estabelecimento_id');
  end if;

  -- Remove a ligação sem penalidade nem aviso à casa (RN16, LGPD art. 18)
  delete from public.equipe_confianca ec
   where ec.estabelecimento_id = sair_da_equipe.estabelecimento_id
     and ec.profissional_id = v_profissional_id;

  return jsonb_build_object();
end $$;
