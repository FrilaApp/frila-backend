-- membros_do_estabelecimento(estabelecimento_id): a lista de membros da casa, para a tela da equipe
-- (contrato 0.2.103, frila-docs #278; web 3.16). É daqui que sai o membro_id que remover_membro e
-- transferir_administracao já pediam.
--
-- Só o administrador daquela casa. Operador, membro de outra casa, quem não é membro e casa que não
-- existe recebem o MESMO 403 sem_permissao, sem details: a resposta não diz se a casa existe nem quem
-- é membro dela (mesma regra de remover_membro, com privado.eh_administrador). Conta suspensa de quem
-- chama: 403 sem_permissao com details conta_suspensa (privado.exigir_conta_ativa). Sem sessão: 401.
--
-- Minimização (LGPD, art. 6º, III): cada membro traz só membro_id, nome, papel, desde e e_voce.
-- Nunca e-mail, telefone, documento, nascimento nem usuario_id. Quem exclui a conta deixa de ser
-- membro (excluir_conta apaga o vínculo), então não há membro sem nome; o join com usuario ainda
-- deixa de fora vínculo de conta anonimizada, por garantia. Conta suspensa continua na lista, para o
-- administrador poder removê-la.
-- Ordem: administradores primeiro, depois operadores; em cada papel, entrada mais antiga primeiro.
-- A lista é curta e vem inteira.

create or replace function public.membros_do_estabelecimento(estabelecimento_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_res jsonb;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;
  perform privado.exigir_conta_ativa();

  if not privado.eh_administrador(membros_do_estabelecimento.estabelecimento_id) then
    perform public.erro(403, 'sem_permissao');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'membro_id', m.id,
           'nome',      u.nome,
           'papel',     m.papel,
           'desde',     m.criado_em,
           'e_voce',    m.usuario_id = v_uid
         ) order by (m.papel <> 'administrador'), m.criado_em, m.id), '[]'::jsonb)
    into v_res
    from public.membro_estabelecimento m
    join public.usuario u on u.id = m.usuario_id and u.estado <> 'anonimizada'
   where m.estabelecimento_id = membros_do_estabelecimento.estabelecimento_id;

  return v_res;
end $$;

comment on function public.membros_do_estabelecimento(uuid) is
  'Lista os membros da casa (RF21, US24): membro_id, nome, papel, desde e e_voce. Só o administrador da casa; todo o resto recebe o mesmo 403 sem_permissao. Sem e-mail, telefone, documento nem usuario_id (contrato 0.2.103).';

revoke all on function public.membros_do_estabelecimento(uuid) from public, anon;
grant execute on function public.membros_do_estabelecimento(uuid) to authenticated;
