-- supabase/operacao/reativar-conta.sql
--
-- Reativa uma conta suspensa via procedimento operacional da Equipe Frila.
-- Atualiza estado da conta para 'ativa' e grava ocorrência de suporte com a justificativa.
--
-- Uso no psql:
--   psql -v usuario_id="<uuid>" -v justificativa="<justificativa>" -f supabase/operacao/reativar-conta.sql
--
-- Exemplo:
--   psql -v usuario_id="c7000000-0000-4000-8000-000000000001" -v justificativa="Contestação acolhida após envio de comprovante." -f supabase/operacao/reativar-conta.sql

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

begin;
select privado.operacao_reativar_conta(:'usuario_id'::uuid, :'justificativa');
commit;
