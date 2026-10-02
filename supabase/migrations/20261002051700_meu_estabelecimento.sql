-- `meu_estabelecimento`: o cadastro da casa, para quem é membro dela (contrato 0.2.29).
--
-- `publicar_vaga` exige `local`, `regiao_administrativa` e `ponto`, e o contrato diz que os
-- três vêm preenchidos com os do estabelecimento. Só `cadastrar_estabelecimento` devolvia
-- esses dados, uma vez, na resposta do cadastro. `meus_estabelecimentos` não os traz, de
-- propósito (é leitura de tela), e o painel traz o local de cada vaga, não o da casa. Quem
-- abria o app noutro dia não tinha de onde ler o endereço e o ponto da própria casa, e o
-- app só conseguia publicar logo depois do cadastro.
--
-- A resposta é o `Estabelecimento` do contrato, montado pela mesma
-- `privado.estabelecimento_em_json` de `cadastrar_estabelecimento`: nenhum campo além dos
-- que quem cadastrou já recebia. Só membro lê; quem não é membro recebe `403
-- sem_permissao`, que é também a resposta para um id que não existe, como no painel.

create or replace function public.meu_estabelecimento(estabelecimento_id uuid)
returns jsonb
language plpgsql
security definer set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_linha public.estabelecimento%rowtype;
  v_papel public.papel_membro;
begin
  if v_uid is null then
    perform public.erro(401, 'nao_autenticado');
  end if;

  -- O papel é o de quem chama, nesta casa. Sem linha em `membro_estabelecimento`, não é
  -- membro: administrador e operador leem, porque os dois publicam vaga (RF21).
  select m.papel into v_papel
    from public.membro_estabelecimento m
   where m.estabelecimento_id = meu_estabelecimento.estabelecimento_id
     and m.usuario_id = v_uid;
  if not found then
    perform public.erro(403, 'sem_permissao');
  end if;

  select e.* into v_linha
    from public.estabelecimento e
   where e.id = meu_estabelecimento.estabelecimento_id;

  return privado.estabelecimento_em_json(v_linha, v_papel);
end $$;

comment on function public.meu_estabelecimento(uuid) is
  'O cadastro de um estabelecimento de que a conta é membro, com o papel de quem chama (RF02, RF21; contrato 0.2.29). Endereço, região e ponto para preencher a publicação da vaga (RN02). Só membro: quem não é recebe 403 sem_permissao.';

revoke execute on function public.meu_estabelecimento(uuid) from public, anon;
grant  execute on function public.meu_estabelecimento(uuid) to authenticated;
