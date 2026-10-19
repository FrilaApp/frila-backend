-- Índice do filtro de presença na vaga em privado.elegiveis (RNF11).
-- Cartão zptkprHt.
--
-- `20260929110000_rodada_de_despacho.sql` acrescentou a `privado.elegiveis` o filtro que
-- tira da rodada quem faltou nesta vaga (RN12) e quem já trabalha nela:
--
--   and not exists (
--     select 1 from public.posicao x
--      where x.vaga_id = v.id and x.profissional_id = c.id
--        and (x.falta or x.estado in ('confirmada', 'cumprida'))
--   )
--
-- Nenhum dos índices de `public.posicao` serve essa condição. `posicao_abertas` é parcial
-- em `estado = 'aberta'`, que é o estado errado; `posicao_do_profissional` não alcança
-- `falta`; e o `sem_turno_sobreposto` é GiST sobre o intervalo. Resultado, medido em 29/09
-- com a carga do DF (20.019 posições):
--
--   Seq Scan on posicao x  (actual rows=0 loops=1)
--     Rows Removed by Filter: 20019
--
-- A tabela inteira varrida, uma vez por vaga despachada, para descobrir que ninguém faltou.
--
-- O índice parcial resolve com `Index Only Scan` e custa quase nada, porque a condição só
-- alcança posição que chegou a `falta`, `confirmada` ou `cumprida`. Medido na mesma carga:
-- **10 linhas indexadas de 20.019**, 16 kB contra 1.824 kB da tabela. Escrita a mais só
-- quando uma posição entra ou sai desses três estados, e não a cada posição aberta.
--
-- A ordem das colunas é `(vaga_id, profissional_id)` porque a vaga é o lado fixo da
-- consulta e o profissional varia dentro dela.

create index if not exists posicao_presenca_na_vaga
  on public.posicao (vaga_id, profissional_id)
  where falta or estado in ('confirmada', 'cumprida');

comment on index public.posicao_presenca_na_vaga is
  'Serve o filtro de RN12 em privado.elegiveis: quem faltou nesta vaga, ou já trabalha nela, sai da rodada. Parcial de propósito — alcança só posição em falta, confirmada ou cumprida (RNF11).';
