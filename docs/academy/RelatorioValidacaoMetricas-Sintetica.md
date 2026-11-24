# Relatório: validação sintética das métricas

Mede se o mecanismo de coleta registra e conta certo. **Não mede desempenho real:** a amostra é inventada e nenhum número do Prod entra aqui. O plano dos indicadores está em [`PlanoDeMetricas-Mentor.md`](PlanoDeMetricas-Mentor.md).

## Como foi medido

| Item | Valor |
|---|---|
| Data e hora | 24/11/2026, 15:28 (America/Sao_Paulo) |
| Script | `scripts/validar-metricas-sinteticas.sh` e `.sql`, no commit `1fd2b6c` |
| Banco | Postgres 17.6, local (`supabase_db_frila-backend`), 0 consultas ativas de outras sessões antes |
| Migrações no banco local | 231 aplicadas de 243 arquivos; nenhuma das 12 que faltam toca as tabelas ou as views usadas aqui (conferido por `grep`) |
| Comandos | `./scripts/validar-metricas-sinteticas.sh` (rollback) e `./scripts/validar-metricas-sinteticas.sh --commitar` (grava e o trap apaga) |
| Resultado | os dois com saída 0; 25 comparações OK, 0 FALHA |

Tudo abaixo é MEDIDO pela saída desse script.

## A amostra semeada

10 empregadores (um por casa), 50 trabalhadores, 10 estabelecimentos, **20 vagas** (1 posição cada), **80 candidaturas**, **15 posições com `confirmado_em`** (as contratações). As 5 vagas restantes nunca tiveram confirmação.

| Caso | Quantidade |
|---|---|
| Confirmada, turno ainda por vir (`vaga.estado = 'preenchida'`) | 9 |
| Cumprida, com check-in verificado | 3 |
| No-show (cancelada, com falta, fim passado, sem check-in) | 1 |
| Cancelamento tardio (cancelada com falta, a menos de 24 h do início, posição reaberta) | 1 |
| Desistência antecipada (cancelada sem falta, posição reaberta) | 1 |
| Sem escolha da casa (vaga cancelada, candidaturas expiradas) | 2 vagas, 9 candidaturas |
| Candidatos que retiraram (vaga encerrada) | 1 vaga, 5 candidaturas |
| Em aberto, candidaturas pendentes | 2 vagas, 5 candidaturas |
| Candidaturas por estado | 15 aceitas, 46 recusadas, 9 expiradas, 5 retiradas, 5 pendentes |

## Os 4 indicadores (medido contra o semeado)

Fórmulas e de onde saem: [`PlanoDeMetricas-Mentor.md`](PlanoDeMetricas-Mentor.md). **Bruta** conta toda posição com `confirmado_em`; **efetiva** conta só posição hoje `confirmada` ou `cumprida` (desconta no-show, cancelamento tardio e desistência).

| # | Indicador | Medido | Esperado pela semeadura | Resultado |
|---|---|---|---|---|
| 1 | Candidaturas por vaga | **4,00** (80 / 20) | 4,00 | OK |
| 2 | Taxa de preenchimento, bruta | **75,00%** (15 / 20) | 75,00% | OK |
| 2 | Taxa de preenchimento, efetiva | 60,00% (12 / 20) | 60,00% | OK |
| 3 | Vagas não preenchidas, bruto | **5 vagas, 25,00%** | 5 e 25,00% | OK |
| 3 | Vagas não preenchidas, efetivo | 8 vagas | 8 | OK |
| 4 | Conversão candidatura → contratação, bruta | **18,75%** (15 / 80) | 18,75% | OK |
| 4 | Conversão candidatura → contratação, efetiva | 15,00% (12 / 80) | 15,00% | OK |

Os valores brutos coincidem com os do exemplo do mentor (4; 75%; 25%; 18,75%) porque a amostra foi montada com os mesmos totais. A diferença entre bruta e efetiva é o que a amostra "não limpa" revela: 3 das 15 contratações não se cumpriram (1 no-show, 1 cancelamento tardio, 1 desistência antecipada).

## A prova de que o mecanismo funciona

1. **Contagem nas tabelas contra as views.** A semeadura conta direto em `public.*` (10, 50, 10, 20, 80, 15). As views dão os mesmos totais: `metrica.funil_por_vaga` filtrada pela amostra (20 vagas, 80 candidaturas, 15 confirmações) e a diferença de `metrica.funil_geral` antes e depois (20, 80, 15).
2. **Os esperados não vêm das tabelas.** São literais do plano da amostra, escritos no `.sql`. A comparação não é circular.
3. **O teste falha quando deve (mutação, medida).** Com uma vaga a menos de uma candidatura (79 em vez de 80), o script saiu com 1 e acusou FALHA em 6 linhas: candidaturas (79 contra 80), candidaturas por vaga (3,95 contra 4,00), as duas conversões e as recusadas. Marcando os 10 empregadores como `demonstracao = true`, saiu com 1, as contagens deram **0** e os percentuais ficaram vazios, isto é, a própria view descarta a amostra.
4. **As exclusões foram exercitadas.** Dentro da transação, a casa 1 virou demonstração e a casa 2 entrou em `privado.conta_equipe`: as vagas visíveis caíram de 20 para 16, e voltaram a 20 depois de desfeito.
5. **Limpeza.** No modo normal a transação termina em rollback e o trap confere: 0 linhas com o prefixo antes e depois. No modo `--commitar` o trap encontrou 404 linhas e apagou todas: 0 depois. Trava de `DATABASE_URL` remoto: saída 1 com a mensagem de recusa.

### Cuidado especial com as exclusões das views

Sim, precisou. As views de `metrica` descartam `public.usuario.demonstracao = true` e quem está em `privado.conta_equipe`. A amostra fica fora das duas listas por construção (`demonstracao` fica no default `false` e nada entra em `conta_equipe`); sem isso o resultado seria zero, como mostrou a mutação acima.

## O que não foi medido

- **Desempenho real:** nenhum número do Prod, nenhum usuário real. Um 75% aqui não diz nada sobre o Frila.
- **As RPCs.** A semeadura insere direto nas tabelas e escreve o estado que `public.candidatar`, `privado.cancelar_uma_posicao` e `privado.fechar_turnos_e_vagas` deixam (conferido lendo o corpo delas), mas **não executei essas RPCs**. O que está provado é que as views contam certo a partir dessas linhas; que as RPCs gravam essas linhas é coberto pelos testes pgTAP e por `scripts/ciclo-completo.sh`, que não rodei aqui.
- **Telemetria do app** (`metrica.eventos_app_por_dia`): é do cliente, fora do escopo.
- **Volume:** 20 vagas e 80 candidaturas não dizem nada sobre custo da consulta com milhares de linhas.
- As 12 migrações que faltam no banco local (231 de 243): não foram aplicadas, porque o banco é compartilhado e `supabase db reset` não entra aqui.
