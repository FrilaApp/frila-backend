-- Correção do contrato 0.2.38 (Achado 1 da Auditoria de Contrato):
--
-- Candidato.da_equipe está previsto no contrato (0.2.38, D7), mas não era devolvido
-- por nenhuma migração anterior de public.candidatos_da_vaga.
-- Passa a devolver 'da_equipe' como booleano derivado da relação de confiança
-- em public.equipe_confianca (estabelecimento_id da vaga x profissional_id).
-- Mantém estrita a ordem de chegada (RN06) e o filtro de bloqueio mútuo (RF26, RN10).

-- contrato: corpo-sem-mudanca-de-superficie public.candidatos_da_vaga 0.2.43

create or replace function public.candidatos_da_vaga(vaga_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  v_uid   uuid := (select auth.uid());
  v_estab uuid;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_perfil('contratante');

  if candidatos_da_vaga.vaga_id is null then
    perform public.erro(422, 'campo_obrigatorio', 'vaga_id');
  end if;

  select g.estabelecimento_id into v_estab
    from public.vaga g where g.id = candidatos_da_vaga.vaga_id;
  if v_estab is null then
    perform public.erro(404, 'nao_encontrado');
  end if;
  if not privado.eh_membro(v_estab) then
    perform public.erro(403, 'sem_permissao');
  end if;

  -- Ordem de chegada, e nenhuma outra: a reputação vai no card para a casa ler (RN08),
  -- não na ordem da lista (RN06). Candidatos com bloqueio mútuo com o estabelecimento
  -- são ocultados (achado 1 da auditoria de segurança, RF26, RN10).
  -- da_equipe (0.2.38 D7): booleano indicando se o profissional pertence à equipe de confiança
  -- do estabelecimento da vaga (public.equipe_confianca).
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'candidatura_id', c.id,
             'profissional',   privado.perfil_publico_profissional(c.profissional_id),
             'da_equipe',      exists(
                                 select 1
                                   from public.equipe_confianca ec
                                  where ec.estabelecimento_id = v_estab
                                    and ec.profissional_id = c.profissional_id
                               ),
             'criada_em',      c.criada_em)
           order by c.criada_em, c.id)
      from public.candidatura c
      join public.posicao x on x.id = c.posicao_id
     where x.vaga_id = candidatos_da_vaga.vaga_id
       and c.estado = 'pendente'
       and not privado.bloqueado_com_estabelecimento(
             privado.usuario_do_profissional(c.profissional_id),
             v_estab)), '[]'::jsonb);
end $$;

comment on function public.candidatos_da_vaga(uuid) is
  'Modo seleção: lista os candidatos pendentes na ordem de chegada (RN06) com flag da_equipe (0.2.38), ocultando profissionais com bloqueio mútuo com o estabelecimento.';

revoke execute on function public.candidatos_da_vaga(uuid) from public, anon;
grant  execute on function public.candidatos_da_vaga(uuid) to authenticated;
