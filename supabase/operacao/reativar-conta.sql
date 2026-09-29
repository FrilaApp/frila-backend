-- supabase/operacao/reativar-conta.sql
--
-- Reativa uma conta suspensa via procedimento operacional da Equipe Frila.
-- Atualiza estado da conta para 'ativa' e grava ocorrência de suporte com a justificativa.
--
-- operador_id é a conta (public.usuario) do membro da Equipe Frila que executa: ele assina a
-- ocorrência, nunca o alvo.
--
-- Uso no psql:
--   psql -v usuario_id="<uuid>" -v justificativa="<justificativa>" -v operador_id="<uuid-do-operador>" -f supabase/operacao/reativar-conta.sql
--
-- Exemplo:
--   psql -v usuario_id="c7000000-0000-4000-8000-000000000001" -v justificativa="Contestação acolhida após envio de comprovante." -v operador_id="<uuid-do-operador>" -f supabase/operacao/reativar-conta.sql

\if :{?usuario_id}
\else
  \echo 'Erro: variável usuario_id ausente. Uso: -v usuario_id="<uuid>"'
  \q
\endif

\if :{?justificativa}
\else
  \echo 'Erro: variável justificativa ausente. Uso: -v justificativa="<justificativa>"'
  \q
\endif

\if :{?operador_id}
\else
  \echo 'Erro: variável operador_id ausente (uuid da conta do membro da Equipe Frila que executa). Uso: -v operador_id="<uuid>"'
  \q
\endif

begin;
select privado.operacao_reativar_conta(:'usuario_id'::uuid, :'justificativa', :'operador_id'::uuid);
commit;
