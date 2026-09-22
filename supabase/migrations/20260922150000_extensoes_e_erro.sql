-- Extensões, o schema privado e o auxiliar de erro.
--
-- Fundação de tudo o que vem depois:
--   postgis     elegibilidade por distância (RN05) e o ponto base do profissional
--   btree_gist  igualdade de uuid dentro do índice GIST, para o EXCLUDE de RN21
--   citext      e-mail sem diferenciar maiúscula
--
-- pg_cron, pgmq e pg_net entram na migração do despacho (Sprint 2), quando houver
-- o que agendar. Ligar agora um agendador sem job é superfície sem uso.

create extension if not exists postgis     with schema extensions;
create extension if not exists btree_gist  with schema extensions;
create extension if not exists citext      with schema extensions;

-- ── O schema que a API não expõe ───────────────────────────────────────────────
--
-- O PostgREST só expõe `public`. Tudo o que é auxiliar de política ou de função
-- mora aqui e, por construção, ninguém chama por /rpc.

create schema if not exists privado;
comment on schema privado is
  'Auxiliares de RLS e de funções. Fora da API: o PostgREST só expõe public.';

revoke all on schema privado from public;
grant usage on schema privado to authenticated, service_role;

-- ── O erro que o cliente compara sem traduzir ──────────────────────────────────
--
-- O envelope é o do PostgREST: code, message, details, hint. Nas recusas de regra
-- de negócio, `code` é um código estável em snake_case — o app compara a string,
-- nunca traduz. `message` é texto para log e não vai para a tela.
--
-- O catálogo completo está na descrição de contrato/openapi.yaml. Toda função que
-- recusa alguma coisa levanta o erro por aqui, e não por RAISE solto: um erro cru
-- vaza texto de Postgres para dentro do app.

create or replace function public.erro(status int, codigo text, motivo text default null)
returns void
language plpgsql
immutable
as $$
begin
  raise sqlstate 'PGRST' using
    message = json_build_object('code', codigo, 'message', codigo,
                                'details', motivo, 'hint', null)::text,
    detail  = json_build_object('status', status)::text;
end $$;

comment on function public.erro(int, text, text) is
  'Levanta erro no envelope do PostgREST com código estável em snake_case (ver openapi.yaml).';

revoke execute on function public.erro(int, text, text) from public, anon;
grant  execute on function public.erro(int, text, text) to authenticated, service_role;
