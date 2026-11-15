-- supabase/operacao/anular-falta.sql
--
-- Anula uma falta registrada via procedimento operacional da Equipe Frila (RN12).
-- Atualiza posicao.falta para false, preenche auditoria em privado.anulacao_falta,
-- recalcula taxa de comparecimento do profissional e grava ocorrência de auditoria.
--
-- operador_id é a conta (public.usuario) do membro da Equipe Frila que executa: ele assina a
-- ocorrência, nunca o alvo.
--
-- Uso no psql:
--   psql -v posicao_id="<uuid>" -v motivo="<motivo>" -v operador_id="<uuid-do-operador>" [-v ocorrencia_origem_id="<uuid>"] -f supabase/operacao/anular-falta.sql
--
-- Exemplo:
--   psql -v posicao_id="c7000000-0000-4000-8000-000000000001" -v motivo="Contestação de atraso acolhida por comprovante médico." -v operador_id="<uuid-do-operador>" -f supabase/operacao/anular-falta.sql

\if :{?posicao_id}
\else
  \echo 'Erro: variável posicao_id ausente. Uso: -v posicao_id="<uuid>"'
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
\if :{?ocorrencia_origem_id}
  select privado.anular_falta(:'posicao_id'::uuid, :'motivo', :'operador_id'::uuid, :'ocorrencia_origem_id'::uuid);
\else
  select privado.anular_falta(:'posicao_id'::uuid, :'motivo', :'operador_id'::uuid);
\endif
commit;
