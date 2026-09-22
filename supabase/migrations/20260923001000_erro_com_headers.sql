-- O envelope de erro precisa de `headers`, e o do contrato não tem.
--
-- O trecho de `public.erro` publicado na descrição de `contrato/openapi.yaml` monta o
-- `DETAIL` só com `status`. Esta versão do PostgREST recusa isso:
--
--   PGRST121 — "DETAIL must be a JSON object with obligatory keys: 'status', 'headers'
--               and optional key: 'status_text'."
--
-- O resultado era um 500 com `PGRST121` no lugar do 404 que a regra levantou: o
-- aplicativo receberia "erro interno" toda vez que uma regra de negócio recusasse
-- alguma coisa. Todas elas.
--
-- Nenhum teste pgTAP pegava isto, e não pegaria: dentro do banco a exceção sobe com o
-- `sqlstate` certo, e é o PostgREST que a traduz. Quem pegou foi o
-- `scripts/ciclo-completo.sh`, chamando a rota por HTTP como o aplicativo chama. É
-- exatamente a diferença que ele existe para medir.
--
-- Registrado no cartão do contrato 0.2.1: o trecho do documento precisa da mesma
-- correção, senão o iOS e o Android nascem com a mesma falha.

create or replace function public.erro(status int, codigo text, motivo text default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise sqlstate 'PGRST' using
    message = json_build_object('code', codigo, 'message', codigo,
                                'details', motivo, 'hint', null)::text,
    detail  = json_build_object('status', status, 'headers',
                                json_build_object())::text;
end $$;

revoke execute on function public.erro(int, text, text) from public, anon, authenticated;
