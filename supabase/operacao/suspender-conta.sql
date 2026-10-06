-- supabase/operacao/suspender-conta.sql
--
-- Suspende uma conta com segurança via procedimento operacional da Equipe Frila (RN13).
-- Atualiza estado da conta para 'suspensa', cancela turnos futuros e grava ocorrência.
--
-- operador_id é a conta (public.usuario) do membro da Equipe Frila que executa: ele assina a
-- ocorrência, nunca o alvo.
--
-- Uso no psql:
--   psql -v usuario_id="<uuid>" -v motivo="<motivo>" -v operador_id="<uuid-do-operador>" -f supabase/operacao/suspender-conta.sql
--
-- Exemplo:
--   psql -v usuario_id="c7000000-0000-4000-8000-000000000001" -v motivo="Denúncia grave confirmada de assédio no turno." -v operador_id="<uuid-do-operador>" -f supabase/operacao/suspender-conta.sql

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

\if :{?operador_id}
\else
  \echo 'Erro: variável operador_id ausente (uuid da conta do membro da Equipe Frila que executa). Uso: -v operador_id="<uuid>"'
  \q
\endif

begin;
select privado.suspender(:'usuario_id'::uuid, :'motivo', :'operador_id'::uuid);
commit;
