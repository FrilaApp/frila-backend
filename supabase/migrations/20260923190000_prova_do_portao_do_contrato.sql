-- Migração de prova, para o cartão oUwDEP8Q.
--
-- Existe só para demonstrar que a CI barra um PR que muda a superfície da API sem
-- levar o contrato junto. A RPC abaixo não faz nada e não deve ser mergeada: o PR que
-- a carrega é fechado assim que a CI reprovar.
--
-- O critério de aceite do cartão é literal — "PR de exemplo que muda uma RPC sem mexer
-- no contrato é barrado pela CI" —, e um script reprovando na minha máquina não é a CI
-- reprovando.
create or replace function public.rpc_de_prova_do_portao() returns void
language sql security definer set search_path = '' as $$ select 1 $$;

revoke execute on function public.rpc_de_prova_do_portao() from public, anon;
