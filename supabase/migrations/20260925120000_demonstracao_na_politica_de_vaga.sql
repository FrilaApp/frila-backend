-- A marca de demonstração passa a valer na política de leitura de `vaga`.
--
-- O isolamento das diretrizes 2.1 e 4.2 nasceu dentro de `vagas_abertas` e
-- `detalhe_vaga`, que são a porta da frente do app. Mas `public.vaga` tem política de
-- leitura, e o PostgREST expõe a tabela em `rest/v1/vaga`: quem chamasse a tabela
-- direto passava ao lado do filtro.
--
-- Medido em 25/09, antes desta migração, com uma conta real lendo `public.vaga` sob a
-- role `authenticated`: a vaga de uma conta de demonstração aparecia. `posicao` já
-- estava fechada por outro caminho — `posicao_leitura` exige ser o profissional da
-- posição ou membro da casa —, então o vazamento era da vaga, e só dela.
--
-- A regra vale nos dois sentidos: a conta de demonstração também não alcança a vaga
-- real. Uma vaga publicada pelo revisor da Apple que aparecesse para profissional de
-- verdade seria pior do que o inverso.

-- A marca é da conta, e a vaga herda pela conta que publicou — a mesma decisão que
-- `vagas_abertas` tomou. Conta sem linha em `usuario`, ou vaga sem `publicado_por`,
-- conta como real: o padrão seguro é a população de verdade, que é a que tem gente.
create or replace function privado.mesma_populacao(conta uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select coalesce((select u.demonstracao from public.usuario u where u.id = conta), false)
       = privado.conta_de_demonstracao();
$$;

comment on function privado.mesma_populacao(uuid) is
  'Verdadeiro quando a conta indicada e quem está chamando pertencem à mesma população — as duas reais, ou as duas de demonstração (diretrizes 2.1 e 4.2).';

-- Esta é chamada de dentro de uma política de RLS, e política roda com os privilégios
-- de quem consulta: sem o `grant` para `authenticated`, toda leitura de `vaga` morre
-- com "permission denied for function". Medido — foi exatamente o que aconteceu na
-- primeira versão desta migração. `anon` continua de fora.
revoke all on function privado.mesma_populacao(uuid) from public, anon;
grant execute on function privado.mesma_populacao(uuid) to authenticated;

-- `privado.conta_de_demonstracao` nasceu sem o revoke que as irmãs dela têm. Não é
-- vazamento de dado — ela devolve um booleano sobre quem chama —, mas o schema
-- `privado` não é superfície de API, e uma função alcançável por `anon` é uma porta
-- que ninguém decidiu abrir.
revoke all on function privado.conta_de_demonstracao() from public, anon, authenticated;

drop policy vaga_leitura on public.vaga;

create policy vaga_leitura on public.vaga for select to authenticated
  using (
    privado.mesma_populacao(publicado_por)
    and (
          privado.eh_membro(estabelecimento_id)
       or ((select privado.perfil_da_conta()) = 'profissional'
           and (   privado.ocupa_posicao_na_vaga(id)
                or (not privado.bloqueado_com_estabelecimento(
                          (select auth.uid()), estabelecimento_id)
                    and (estado = 'publicada' or privado.candidatou_na_vaga(id)))))));
