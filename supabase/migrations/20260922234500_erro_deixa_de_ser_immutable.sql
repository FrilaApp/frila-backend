-- `public.erro` não é imutável, e dizer que é mente para o planejador.
--
-- Achado pelo `plpgsql_check` na integração contínua, que roda uma versão da CLI mais
-- nova que a instalada aqui: *"routine is marked as IMMUTABLE, but expression is STABLE"*.
--
-- O rótulo estava errado por dois motivos. `json_build_object` sobre os argumentos é
-- `stable`, não `immutable` — e, mais importante, a razão de existir desta função é
-- **levantar exceção**, que é efeito colateral. Uma função imutável é uma promessa ao
-- planejador de que ele pode avaliá-la uma vez, ou nenhuma, ou trocá-la por uma
-- constante em tempo de planejamento. Nenhuma dessas liberdades combina com "esta
-- chamada é o que interrompe a transação e devolve 422 ao aplicativo".
--
-- Sem rótulo, o padrão é `volatile`, que é o que ela é.

create or replace function public.erro(status int, codigo text, motivo text default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise sqlstate 'PGRST' using
    message = json_build_object('code', codigo, 'message', codigo,
                                'details', motivo, 'hint', null)::text,
    detail  = json_build_object('status', status)::text;
end $$;

revoke execute on function public.erro(int, text, text) from public, anon, authenticated;
