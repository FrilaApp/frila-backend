-- supabase/operacao/moderar-conteudo.sql
--
-- Moderação de conteúdo em até 24 h (Diretriz 1.2 da App Store).
-- Oculta ou reexibe vagas denunciadas com registro de ocorrência.
--
-- operador_id é a conta (public.usuario) do membro da Equipe Frila que executa: ele assina a
-- ocorrência, nunca o alvo.
--
-- Uso no psql:
--   psql -v vaga_id="<uuid>" -v acao="ocultar" -v motivo="Termo ofensivo em observações" -v operador_id="<uuid-do-operador>" -f supabase/operacao/moderar-conteudo.sql
--   psql -v vaga_id="<uuid>" -v acao="reexibir" -v motivo="Denúncia improcedente após análise" -v operador_id="<uuid-do-operador>" -f supabase/operacao/moderar-conteudo.sql

\if :{?vaga_id}
\else
  \echo 'Erro: variável vaga_id ausente. Uso: -v vaga_id="<uuid>"'
  \q
\endif

\if :{?acao}
\else
  \set acao 'ocultar'
\endif

\if :{?motivo}
\else
  \echo 'Erro: variável motivo ausente. Uso: -v motivo="\'<motivo>\'"'
  \q
\endif

\if :{?operador_id}
\else
  \echo 'Erro: variável operador_id ausente (uuid da conta do membro da Equipe Frila que executa). Uso: -v operador_id="<uuid>"'
  \q
\endif

begin;
select privado.operacao_moderar_conteudo(:'vaga_id'::uuid, :'acao', :'motivo', :'operador_id'::uuid);
commit;
