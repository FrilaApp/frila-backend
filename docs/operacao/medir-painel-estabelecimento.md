# Medir `painel_estabelecimento` com volume (cartão 1zojatYG)

Roteiro de quem executa a medição no banco local. Este documento e os arquivos que ele cita só preparam a medição: **nenhum número de desempenho do painel foi medido ainda**. Onde a tabela abaixo diz `NAO MEDIDO`, é o que a execução vai preencher.

## O que existe

| Arquivo | Papel |
|---|---|
| `supabase/tests/carga/gerar_casa_pesada.sql` | Gera **uma** casa com histórico: vagas, posições, turnos, candidaturas e ocorrências de cancelamento. Só roda dentro de uma transação. |
| `scripts/medir-painel.sql` | Mede um cenário: tempo de parede, `explain (analyze, buffers)` da chamada inteira e consultas internas via `auto_explain`. |
| `scripts/medir-painel.sh` | Orquestra: carrega cada casa numa transação, mede os cenários e termina em `rollback`. |

Os volumes dos cenários são **hipótese de volume, não dado de produto**. O Cauê ou o Jota confirmam o que é plausível para uma casa do DF.

| Cenário | Casa | Vagas x posições x candidaturas | Janela `de..ate` |
|---|---|---|---|
| S1 | A | 200 x 2 x 6 | 1 dia |
| S2 | A | 200 x 2 x 6 | 7 dias |
| S3 | B | 1.000 x 3 x 10 | 30 dias |
| S4 | B | 1.000 x 3 x 10 | 365 dias |
| S5 | B | 1.000 x 3 x 10 | 1.825 dias (5 anos) |
| S3_membro5 | B | igual a S3 | 30 dias, com o leitor membro de 5 casas em vez de 1 |

O histórico de cada casa tem 365 dias, as vagas são espalhadas uniformemente e a janela começa no primeiro dia. Com esse espalhamento, a janela de 1 dia (S1) contém cerca de 1 vaga e a de 7 dias (S2) cerca de 4 (DEDUZIDO da fórmula do gerador; o relatório imprime o número real em `VOLUME_JANELA`). Se uma casa média real concentra mais vagas por semana, ajuste `-v vagas` no gerador antes de tirar conclusão de S1 e S2.

## Garantias de segurança

- **Não faz `db reset`, não depende de reset e não deixa dado.** A carga e a medição ficam na mesma transação, que termina em `rollback`. Ao final o script conta o resíduo e imprime o número (deve ser 0).
- O gerador recusa host que não seja 127/8, 172.16/12 ou 10/8, e recusa transação inexistente (`savepoint` falha fora de transação).
- O gerador recusa banco com mais de 200 usuários, para que os números não incluam outra massa. Se o banco compartilhado já estiver povoado, `PERMITIR_BASE_POVOADA=sim` aceita e o relatório registra quantos usuários havia. Mesmo assim a carga some no `rollback`.
- O script usa `lock_timeout` de 5 s: se outra sessão segurar lock numa tabela que o `analyze` precisa, ele falha em vez de esperar.
- **O banco local é compartilhado entre sessões** (`AGENTS.md`). Combine com quem o usa antes: durante a carga a transação grava dezenas de milhares de linhas (desfeitas no fim) e o autovacuum limpa as versões mortas depois.
- **Nunca em frila-dev nem em Prod.** O script só fala com o contêiner local por `docker exec`.

## Como executar

Da raiz do repositório, com o banco local de pé e o seed aplicado:

```bash
./scripts/medir-painel.sh --listar                       # só imprime os cenários; não toca o banco
./scripts/medir-painel.sh --saida ~/medicao-painel-1zoj  # mede S1 a S5 e S3_membro5
```

Variações:

```bash
./scripts/medir-painel.sh --cenarios S1,S2 --saida DIR   # só a casa A
./scripts/medir-painel.sh --cenarios S3,S4,S5 --saida DIR
PERMITIR_BASE_POVOADA=sim ./scripts/medir-painel.sh --saida DIR
AMOSTRAS=10 AQUECIMENTO=3 ./scripts/medir-painel.sh --saida DIR   # são os padrões
AUTO_EXPLAIN_MIN_MS=0 ./scripts/medir-painel.sh --cenarios S3 --saida DIR  # plano de todas as consultas internas (saída grande)
DB_CONTAINER=supabase_db_frila-backend ./scripts/medir-painel.sh --saida DIR
```

Saída do script: `0` mediu tudo o que foi pedido; `2` **NAO mediu** (ou mediu só parte). Não existe saída `1`: o script registra, não julga. Sem `--saida`, ele cria um diretório com `mktemp -d` e imprime o caminho.

## O que fica no diretório de saída

| Arquivo | Conteúdo |
|---|---|
| `relatorio.txt` | O resumo: volume da janela, tempo, buffers, resumo do plano, resíduo. É o que se cola no cartão. |
| `bruto-casa-A.txt`, `bruto-casa-B.txt` | stdout do psql (contagens da janela e `explain (analyze, buffers)`). |
| `bruto-casa-A.err.txt`, `bruto-casa-B.err.txt` | stderr: `NOTICE` com as medidas e o `LOG` do `auto_explain`. Erros também caem aqui. |
| `explain-<cenário>.txt`, `plano-<cenário>.txt` | Os trechos de cada cenário extraídos dos brutos. |

O resumo do plano é só contagem de `Seq Scan` em `posicao`, `ocorrencia` e `vaga` e o maior `loops=`; **a leitura do plano é humana, no arquivo `plano-<cenário>.txt`**.

## O que o relatório registra por cenário (P3.3 do plano)

- Tempo de parede: 3 chamadas aquecidas descartadas e 10 amostras, com mediana, mínimo e máximo. Com 10 amostras não se afirma p95.
- Tamanho da resposta (`octet_length(...::text)`).
- `explain (analyze, buffers)` da chamada inteira (linha `Buffers:` e `Execution Time`).
- Consultas internas via `auto_explain` numa chamada extra, **fora** das amostras de tempo: procure `Seq Scan` em `posicao`, `ocorrencia`, `vaga` e `loops=` alto.
- Linhas dentro da janela: vagas, posições, candidaturas e turnos.
- Estatística: o gerador roda `analyze` nas tabelas dentro da transação. A medição não usa `enable_seqscan = off`.

Se o `auto_explain` não puder ser ligado neste banco, o relatório diz `NAO MEDIDO` para as consultas internas e mantém tempo, tamanho e `explain` da chamada inteira.

## Referência para decidir (sugestão do plano, quem decide é o Cauê ou o Jota)

Não há SLA do painel no repositório. O plano propõe reaproveitar a escala de `scripts/planos-com-carga.sh` (mediana até 100 ms) e uma resposta de até cerca de 200 KB, lendo S1 e S2:

| Resultado | Decisão sugerida |
|---|---|
| Mediana e tamanho dentro da referência, sem `Seq Scan` em tabela grande | Não paginar. Registrar os números e fechar. |
| `Seq Scan` em `posicao` ou `ocorrencia`, e S3 ou S4 com plano ruim | Só índice (migração nova, sem mudar contrato). |
| Mesmo com índice S3 ou S4 passam do teto, ou S5 é inaceitável | Limitar janela ou paginar. **Muda contrato: decisão do Cauê, com o ok do Fabrício (UI).** |

Migração, índice e paginação estão **fora** desta entrega.

## Resultados

Nenhuma execução foi feita por quem escreveu estes arquivos.

| Cenário | Mediana (ms) | Máximo (ms) | Resposta (bytes) | `Seq Scan` em posicao/ocorrencia/vaga | Quem mediu e quando |
|---|---|---|---|---|---|
| S1 | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | |
| S2 | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | |
| S3 | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | |
| S3_membro5 | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | |
| S4 | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | |
| S5 | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | NAO MEDIDO | |

Depende de humano ou de Prod (fora do alcance da medição local): confirmar volumes plausíveis por casa e o teto de latência aceitável do painel (Cauê ou Jota); medir o tamanho real de `posicao`, `ocorrencia` e `vaga` no Prod, somente leitura, antes de qualquer índice.
