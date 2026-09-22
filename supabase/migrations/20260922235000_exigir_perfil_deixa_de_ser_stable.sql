-- `privado.exigir_perfil` não é estável, porque `public.erro` não é.
--
-- Segundo achado do `plpgsql_check` na mesma rodada, e consequência do primeiro:
-- *"routine is marked as STABLE, but expression is VOLATILE"*.
--
-- `stable` promete ao planejador que a função devolve o mesmo resultado dentro de uma
-- varredura, o que o autoriza a chamá-la menos vezes do que o texto sugere. Essa
-- promessa nunca combinou com uma função cujo trabalho é interromper a transação — e
-- passou a ser mentira explícita quando `erro` voltou a ser `volatile`.
--
-- Não se perde nada: `exigir_perfil` é chamada uma vez, imperativamente, na primeira
-- linha de cada RPC de um perfil só (RN25). Não há varredura para o planejador otimizar.

create or replace function privado.exigir_perfil(esperado public.perfil_conta) returns void
language plpgsql
security definer set search_path = ''
as $$
begin
  if privado.perfil_da_conta() is distinct from esperado then
    perform public.erro(422, 'perfil_incompativel');
  end if;
end $$;

revoke execute on function privado.exigir_perfil(public.perfil_conta) from public, anon;
grant  execute on function privado.exigir_perfil(public.perfil_conta) to authenticated, service_role;
