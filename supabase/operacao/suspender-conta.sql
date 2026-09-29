-- supabase/operacao/suspender-conta.sql
--
-- Suspende uma conta com segurança via procedimento operacional da Equipe Frila (RN13).
-- Atualiza estado da conta para 'suspensa', cancela turnos futuros e grava ocorrência.
--
-- Uso no psql:
--   psql -v usuario_id="<uuid>" -v motivo="<motivo>" -f supabase/operacao/suspender-conta.sql
--
-- Exemplo:
--   psql -v usuario_id="c7000000-0000-4000-8000-000000000001" -v motivo="Denúncia grave confirmada de assédio no turno." -f supabase/operacao/suspender-conta.sql

\if :{?usuario_id}
\else
  \echo 'Erro: variável usuario_id ausente. Uso: -v usuario_id="<uuid>"'
  \q
\endif

\if :{?motivo}
\else
  \echo 'Erro: variável motivo ausente. Uso: -v motivo="<motivo>"'
  \q
\endif

begin;
select privado.operacao_suspender_conta(:'usuario_id'::uuid, :'motivo');
commit;
