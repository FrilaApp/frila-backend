# Medir `painel_estabelecimento` com volume (cartão 1zojatYG)

Roteiro de quem executa a medição no banco local. A primeira execução (2026-11-18) está na seção **Resultados**. Onde a tabela diz `NAO MEDIDO`, a execução não produziu o dado; **nenhum número abaixo é dado de produto**.

## O que existe

| Arquivo | Papel |
|---|---|
| `supabase/tests/carga/gerar_casa_pesada.sql` | Gera **uma** casa com histórico: vagas, posições, turnos, candidaturas e ocorrências de cancelamento. Só roda dentro de uma transação. |
| `scripts/medir-painel.sql` | Mede um cenário: tempo de parede, `explain (analyze, buffers)` da chamada inteira e consultas internas via `auto_explain`. |
| `scripts/medir-painel.sh` | Orquestra: carrega cada casa numa transação, mede os cenários e termina em `rollback`. |
| `scripts/medir-painel-volume.sh` e `.sql` | Mede p50 e p95 com 5 casas de 200 vagas x 10 posições nas janelas de 7 e 31 dias. Seção **p50 e p95 com 5 casas** no fim deste documento. |
| `scripts/teste-medir-painel-volume.sh` | Autoteste do script acima, sem Docker nem Postgres. |

Os volumes dos cenários são **hipótese de volume, não dado de produto**. O Cauê ou o Jota confirmam o que é plausível para uma casa do DF.

| Cenário | Casa | Vagas x posições x candidaturas | Janela `de..ate` |
|---|---|---|---|
| S1 | A | 90 x 2 x 6, histórico de 30 dias | 1 dia |
| S2 | A | 90 x 2 x 6, histórico de 30 dias | 7 dias |
| S3 | B | 1.000 x 3 x 10 | 30 dias |
| S6 | B | 1.000 x 3 x 10 | 45 dias |
| S4 | B | 1.000 x 3 x 10 | 365 dias |
| S5 | B | 1.000 x 3 x 10 | 1.825 dias (5 anos) |
| S3_membro5 | B | igual a S3 | 30 dias, com o leitor membro de 5 casas em vez de 1 |

A casa B tem histórico de 365 dias, com as vagas espalhadas uniformemente, e a janela começa no primeiro dia. A casa A, que serve S1 e S2, tem histórico de 30 dias com 3 vagas por dia (o máximo que o gerador aceita, em faixas de 6 h): a janela de 1 dia (S1) contém 3 vagas e a de 7 dias (S2) contém 21 (DEDUZIDO da fórmula do gerador; confirmado na terceira execução, linha `VOLUME_JANELA`). Antes disso a casa A espalhava 200 vagas em 365 dias, e S1 e S2 tinham 1 e 4 vagas (primeira e segunda execuções abaixo); os números dessas duas execuções para S1 e S2 **não comparam** com os da terceira. O script recusa medir (`NAO MEDIDO`, saída 2) se a janela de S1 tiver menos de 2 vagas ou a de S2 menos de 5. A janela de 45 dias (S6) começa no início do histórico gerado (como as outras); mede o VOLUME da janela (≈ 123 vagas), não modela "hoje −30/+15". Os volumes de todos os cenários são **HIPÓTESE**: se uma casa real tem mais vagas por semana, ajuste `-v vagas` e `-v dias` no gerador antes de tirar conclusão de S1 e S2.

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
./scripts/medir-painel.sh --saida ~/medicao-painel-1zoj  # mede S1 a S6 e S3_membro5
```

Variações:

```bash
./scripts/medir-painel.sh --cenarios S1,S2 --saida DIR   # só a casa A
./scripts/medir-painel.sh --cenarios S3,S4,S5,S6 --saida DIR
PERMITIR_BASE_POVOADA=sim ./scripts/medir-painel.sh --saida DIR
AMOSTRAS=10 AQUECIMENTO=3 ./scripts/medir-painel.sh --saida DIR   # são os padrões
AUTO_EXPLAIN_MIN_MS=0 ./scripts/medir-painel.sh --cenarios S3 --saida DIR  # plano de todas as consultas internas (saída grande)
DB_CONTAINER=supabase_db_frila-backend ./scripts/medir-painel.sh --saida DIR
DB_USER=postgres ./scripts/medir-painel.sh --saida DIR   # papel antigo: auto_explain fica NAO MEDIDO
```

Saída do script: `0` mediu tudo o que foi pedido; `2` **NAO mediu** (ou mediu só parte). Não existe saída `1`: o script registra, não julga. Sem `--saida`, ele cria um diretório com `mktemp -d` e imprime o caminho.

## O que fica no diretório de saída

| Arquivo | Conteúdo |
|---|---|
| `relatorio.txt` | O resumo: volume da janela, tempo, buffers, resumo do plano, resíduo. É o que se cola no cartão. |
| `bruto-casa-A.txt`, `bruto-casa-B.txt` | stdout do psql (contagens da janela e `explain (analyze, buffers)`). |
| `bruto-casa-A.err.txt`, `bruto-casa-B.err.txt` | stderr: `NOTICE` com as medidas e o `LOG` do `auto_explain`. Erros também caem aqui. |
| `explain-<cenário>.txt`, `plano-<cenário>.txt` | Os trechos de cada cenário extraídos dos brutos. |

O resumo do plano é só contagem de `Seq Scan` executados (nós `never executed` não contam) em `posicao`, `ocorrencia` e `vaga` e o maior `loops=`; **a leitura do plano é humana, no arquivo `plano-<cenário>.txt`**.

## O que o relatório registra por cenário (P3.3 do plano)

- Tempo de parede: 3 chamadas aquecidas descartadas e 10 amostras, com mediana, mínimo e máximo. Com 10 amostras não se afirma p95.
- Tamanho da resposta (`octet_length(...::text)`).
- `explain (analyze, buffers)` da chamada inteira (linha `Buffers:` e `Execution Time`).
- Consultas internas via `auto_explain` numa chamada extra, **fora** das amostras de tempo: procure `Seq Scan` em `posicao`, `ocorrencia`, `vaga` e `loops=` alto.
- Linhas dentro da janela: vagas, posições, candidaturas e turnos.
- Estatística: o gerador roda `analyze` nas tabelas dentro da transação. A medição não usa `enable_seqscan = off`.

Se o `auto_explain` não puder ser ligado neste banco, o relatório diz `NAO MEDIDO` para as consultas internas e mantém tempo, tamanho e `explain` da chamada inteira.

O `auto_explain` só carrega para superusuário. No Supabase local o superusuário é `supabase_admin` (o `postgres` não é), e é o padrão de `DB_USER`, como em `scripts/ciclo-completo.sh` e `scripts/teste-operacao-sql.sh`. O papel muda só a conexão do `psql`: o contêiner continua sendo o de `DB_CONTAINER`, o gerador mantém as salvaguardas e a transação termina em `rollback`; a medição dos cenários roda como `authenticated`, então RLS vale igual. O cabeçalho do relatório imprime o papel e se ele é superusuário. Se a senha de `supabase_admin` não for a que o script usa, o script sai com 2 (`NAO MEDI`) na primeira consulta, sem tocar nada.

## Referência para decidir (sugestão do plano, quem decide é o Cauê ou o Jota)

Não há SLA do painel no repositório. O plano propõe reaproveitar a escala de `scripts/planos-com-carga.sh` (mediana até 100 ms) e uma resposta de até cerca de 200 KB, lendo S1 e S2:

| Resultado | Decisão sugerida |
|---|---|
| Mediana e tamanho dentro da referência, sem `Seq Scan` em tabela grande | Não paginar. Registrar os números e fechar. |
| `Seq Scan` em `posicao` ou `ocorrencia`, e S3 ou S4 com plano ruim | Só índice (migração nova, sem mudar contrato). |
| Mesmo com índice S3 ou S4 passam do teto, ou S5 é inaceitável | Limitar janela ou paginar. **Muda contrato: decisão do Cauê, com o ok do Fabrício (UI).** |

Migração, índice e paginação estão **fora** desta entrega.

## Resultados

Primeira execução: 2026-11-18 10:15 (-0300), por quem opera o banco local (Gaara), no commit `6ec4af1`, Postgres 17.6, 10 amostras e 3 aquecimentos por cenário, banco local sem carga concorrente. Os números vêm do `relatorio.txt` dessa execução, sem interpretação. **Os volumes são HIPÓTESE do plano, não dado de produto, e tempo local não transfere para o Prod.**

Antes da execução o banco local foi atualizado de 180 para 230 migrações (`supabase migration up --local`, sem reset), para bater com `origin/develop` `26c4a2b`. Depois do `rollback`: 0 estabelecimentos `Casa pesada`, 18 usuários antes e 18 depois.

| Cenário | Janela | Vagas / posições / candidaturas / turnos na janela | Mediana (ms) | Mín (ms) | Máx (ms) | Resposta (bytes) | `explain` Execution Time (ms) | `explain` Buffers (shared hit) | `Seq Scan` em posicao/ocorrencia/vaga |
|---|---|---|---|---|---|---|---|---|---|
| S1 | 1 dia | 1 / 2 / 12 / 2 | 6,77 | 2,15 | 8,83 | 1.772 | 4,818 | 483 | NAO MEDIDO |
| S2 | 7 dias | 4 / 8 / 48 / 7 | 12,69 | 6,36 | 21,31 | 6.758 | 27,048 | 1.693 | NAO MEDIDO |
| S3 | 30 dias | 83 / 249 / 2.490 / 199 | 608,85 | 412,27 | 808,11 | 181.438 | 634,044 | 107.475 | NAO MEDIDO |
| S3_membro5 | 30 dias, leitor em 5 casas | 83 / 249 / 2.490 / 199 | 368,36 | 268,27 | 610,21 | 181.438 | 360,878 | 110.163 | NAO MEDIDO |
| S4 | 365 dias | 1.000 / 3.000 / 30.000 / 2.400 | 6.371,06 | 5.888,65 | 8.111,98 | 2.186.748 | 5.592,107 | 1.287.511 | NAO MEDIDO |
| S5 | 1.825 dias | 1.000 / 3.000 / 30.000 / 2.400 | 5.743,69 | 3.806,23 | 7.595,94 | 2.186.748 | 5.524,309 | 1.287.511 | NAO MEDIDO |

`Seq Scan` continua **NAO MEDIDO** em todos os cenários. O `explain (analyze, buffers)` da chamada inteira mostra só um nó `Result`, sem os nós de dentro da função. As consultas internas dependem do `auto_explain`, que não pôde ser ligado nessa execução (o papel `postgres` não é superusuário: `access to library "auto_explain" is not allowed` e `permission denied to set parameter "auto_explain.log_nested_statements"`), e os arquivos `plano-<cenário>.txt` ficaram vazios. O script saiu com 0 mesmo assim, como este roteiro descreve.

Fatos da execução, sem interpretação: S4 e S5 têm a mesma contagem na janela, os mesmos bytes e os mesmos buffers; a mediana de S5 é menor que a de S4; a mediana de S2 é menor que o `Execution Time` do `explain` de S2; S1 e S2 têm só 1 e 4 vagas na janela.

Leitura contra a referência do plano (mediana até 100 ms e resposta até cerca de 200 KB, lendo S1 e S2): S1 e S2 ficam abaixo dos dois limites. Os ramos "`Seq Scan` em `posicao` ou `ocorrencia`" e "índice" da tabela de decisão **não podem ser avaliados** sem o plano interno. A decisão (índice, janela limitada ou paginação) é do Cauê ou do Jota; paginação muda contrato e exige o ok do Fabrício (UI).

Depende de humano ou de Prod (fora do alcance da medição local): confirmar volumes plausíveis por casa e o teto de latência aceitável do painel (Cauê ou Jota); medir o tamanho real de `posicao`, `ocorrencia` e `vaga` no Prod, somente leitura, antes de qualquer índice. Não medido nessa execução: autovacuum e versões mortas deixadas pelo `rollback`.

### Segunda execução (Forja, 20/11/2026)

Execução em 2026-11-20 06:22:28 (-0300), no commit `c1b74c1`, Postgres 17.6, papel `supabase_admin` (superusuário: `t`, com `auto_explain` carregado com sucesso), 10 amostras e 3 aquecimentos por cenário, banco local sem carga concorrente via `fila.sh`. Resíduo após rollback: 0 estabelecimentos `Casa pesada`, 18 usuários antes e 18 depois. Os números vêm do `relatorio.txt` e dos arquivos `plano-*.txt` e `explain-*.txt` copiados para `orquestracao/retornos/B-078-medicao/`.

| Cenário | Janela | Vagas / posições / candidaturas / turnos na janela | Mediana (ms) | Mín (ms) | Máx (ms) | Resposta (bytes) | `explain` Execution Time (ms) | `explain` Buffers (shared hit) | `Seq Scan` em posicao/ocorrencia/vaga |
|---|---|---|---|---|---|---|---|---|---|
| S1 | 1 dia | 1 / 2 / 12 / 2 | 1,41 | 1,38 | 1,82 | 1.774 | 1,743 | 474 | 13 / 1 / 1 (loops=20) |
| S2 | 7 dias | 4 / 8 / 48 / 7 | 5,20 | 5,16 | 5,35 | 6.740 | 5,213 | 1.669 | 43 / 1 / 1 (loops=20) |
| S3 | 30 dias | 83 / 249 / 2.490 / 199 | 177,39 | 173,57 | 199,66 | 181.433 | 188,572 | 106.885 | 2 / 0 / 0 (loops=249) |
| S6 | 45 dias | 124 / 372 / 3.720 / 298 | 267,27 | 257,91 | 314,18 | 271.185 | 261,212 | 159.970 | 2 / 0 / 0 (loops=372) |
| S4 | 365 dias | 1.000 / 3.000 / 30.000 / 2.400 | 2.136,32 | 2.125,20 | 2.333,19 | 2.187.017 | 2.405,209 | 1.281.026 | 9 / 0 / 0 (loops=3000) |
| S5 | 1.825 dias | 1.000 / 3.000 / 30.000 / 2.400 | 2.402,50 | 2.324,16 | 2.522,29 | 2.187.017 | 2.448,006 | 1.281.026 | 5 / 0 / 0 (loops=3000) |
| S3_membro5 | 30 dias, leitor em 5 casas | 83 / 249 / 2.490 / 199 | 182,81 | 177,81 | 188,06 | 181.433 | 180,165 | 109.573 | 2 / 0 / 0 (loops=249) |

#### Comparação com a referência do plano (mediana ≤ 100 ms e resposta ≤ ~200 KB)

- **S1 (1 dia):** Mediana de 1,41 ms (≤ 100 ms) e resposta de 1.774 bytes (≤ ~200 KB). Ambos dentro da referência.
- **S2 (7 dias):** Mediana de 5,20 ms (≤ 100 ms) e resposta de 6.740 bytes (≤ ~200 KB). Ambos dentro da referência.
- **S6 (45 dias):** Mediana de 267,27 ms (> 100 ms; excede em ~2,67x) e resposta de 271.185 bytes (~265 KB, > ~200 KB; excede em ~35%).

#### Linhas do plano de execução (`auto_explain`)

Em **S6** (`plano-S6.txt`):
- `Seq Scan` em `posicao`:
  - Linha 122: `->  Seq Scan on posicao pc  (cost=0.00..93.74 rows=3 width=16) (actual time=0.004..0.074 rows=3 loops=124)` com `Filter: (vaga_id = v.id)` e `Rows Removed by Filter: 3176` (Buffers: shared hit=6696).
  - Linha 139: `->  Seq Scan on posicao p  (cost=0.00..93.74 rows=3 width=53) (actual time=0.004..0.073 rows=3 loops=124)` com `Filter: (vaga_id = v.id)` e `Rows Removed by Filter: 3176` (Buffers: shared hit=6696).
- `Seq Scan` em `ocorrencia`: 0 ocorrências. Usa `Index Scan using ocorrencia_posicao_id on ocorrencia o` (linha 155).
- `Seq Scan` em `vaga`: 0 ocorrências. Usa `Bitmap Heap Scan on vaga v` com `Bitmap Index Scan on publicacao_unica` (linhas 92 e 98).
- Maior `loops=`: 372 (linhas 126 e 143, em `Index Scan using candidatura_pendente on candidatura c` e `Index Scan using turno_por_posicao on turno t`).

Em **S3** (`plano-S3.txt`):
- `Seq Scan` em `posicao`:
  - Linha 198: `->  Seq Scan on posicao pc  (cost=0.00..93.74 rows=3 width=16) (actual time=0.004..0.075 rows=3 loops=83)` com `Filter: (vaga_id = v.id)` e `Rows Removed by Filter: 3176` (Buffers: shared hit=4482).
  - Linha 215: `->  Seq Scan on posicao p  (cost=0.00..93.74 rows=3 width=53) (actual time=0.004..0.074 rows=3 loops=83)` com `Filter: (vaga_id = v.id)` e `Rows Removed by Filter: 3176` (Buffers: shared hit=4482).
- `Seq Scan` em `ocorrencia`: 0 ocorrências. Usa `Index Scan using ocorrencia_posicao_id on ocorrencia o` (linha 231).
- `Seq Scan` em `vaga`: 0 ocorrências. Usa `Bitmap Heap Scan on vaga v` (linha 168).
- Maior `loops=`: 249 (linhas 202 e 219).

#### Apontamento de índice no plano

O formato textual de saída do `auto_explain` do PostgreSQL não gera mensagens explícitas de "índice faltando". No entanto, o plano de execução de S6 e S3 evidencia a falta de índice cobrindo a condição `posicao.vaga_id = v.id`:
- Em S6, as linhas 122 e 139 do `plano-S6.txt` mostram `Seq Scan on posicao pc` e `Seq Scan on posicao p` com `Filter: (vaga_id = v.id)`, descartando 3.176 linhas por iteração (`Rows Removed by Filter: 3176`) ao longo de 124 iterações (`loops=124`).
- Em S3, as linhas 198 e 215 do `plano-S3.txt` mostram o mesmo `Seq Scan on posicao` com `Filter: (vaga_id = v.id)`, descartando 3.176 linhas por iteração em 83 iterações (`loops=83`).
- Apenas a consulta parcial `posicao_abertas` possui índice cobrindo `vaga_id` (onde `estado = 'aberta'`), que não foi executada no plano (linha 110 de `plano-S6.txt`: `never executed`); não existe índice em `posicao(vaga_id)` para as posições em geral.

#### Onde o tempo está em S6 (leitura da Forja; INFERÊNCIA marcada, números do `plano-S6.txt`)

- **Fato (plano):** o `SubPlan 6` (lista de posições de cada vaga, linhas 131 a 145) leva 2,337 ms por volta × 124 vagas ≈ 290 ms dos ~306 ms da chamada (≈ 95%) e 147.996 dos 159.970 buffers (≈ 92,5%). Os dois `Seq Scan` em `posicao` (linhas 122 e 139) custam ≈ 0,074 ms por volta × 124 × 2 ≈ 18 ms (≈ 6% do tempo) e 13.392 buffers (≈ 8,4%).
- **Fato (migrações):** o único índice por `vaga_id` em `posicao` é parcial, `posicao_abertas` (`20260922150600_avaliacao_rn07_e_indices.sql:67`, `where estado = 'aberta'`); não há índice geral.
- **Inferência:** um índice em `posicao(vaga_id)` tiraria no máximo esses ~6% a 8%; o grosso (≈ 2,2 ms por vaga) fica dentro do `SubPlan 6`, fora dos nós listados (o `auto_explain` aqui não loga as consultas internas das funções chamadas por posição, por exemplo `privado.perfil_publico_profissional`). Para confirmar, medir com `auto_explain.log_nested_statements = on`. Não foi feito.
- **Fato:** o tempo cresce com o volume da janela: S6 tem 1,49× as vagas de S3 e 1,51× a mediana (267,27 ms ÷ 177,39 ms). Pela tabela de decisão deste roteiro, "índice sem mudar contrato" só resolve se o tempo estiver nos `Seq Scan`; aqui não parece estar. Limitar a janela ou paginar muda o contrato e é decisão do Cauê, com o ok do Fabrício (UI).
- **Cuidado ao comparar com a 1ª execução:** os números das duas execuções diferem muito para o mesmo cenário (S3: 608,85 ms em 18/11 × 177,39 ms em 20/11; S4: 6.371 ms × 2.136 ms). Comparar cenários **dentro** de uma execução, não entre elas; a causa da diferença não foi investigada.

### Terceira execução (22/11/2026)

Motivo: a revisão do #570 pediu uma execução no head com `DB_USER=supabase_admin` e S1 e S2 com mais vagas. Comando (MEDIDO, da raiz do repositório, com 0 consultas ativas em `pg_stat_activity` imediatamente antes (só conexões ociosas dos serviços do Supabase)):

```bash
DB_USER=supabase_admin PGPASSWORD=postgres ./scripts/medir-painel.sh --saida DIR
```

O script fixa `PGPASSWORD=postgres` dentro do `docker exec` (DEDUZIDO do código); exportar a variável fora dele não muda a conexão.

Execução em 2026-11-22 23:32 (-0300), no commit `03f2384` (o restante da branch depois dele só altera este documento), Postgres 17.6, papel `supabase_admin` (superusuário: `t`, `auto_explain` carregado), 10 amostras e 3 aquecimentos por cenário. Resíduo após rollback: 0 estabelecimentos `Casa pesada`, 18 usuários antes e 18 depois. Saída: 0.

Estado do banco local (MEDIDO): 231 migrações aplicadas, a última `20261118100000`. O repositório tem 237 arquivos; as 6 versões ausentes no banco são `20261117100000`, `20261117190000`, `20261117200000`, `20261120100000`, `20261120200000` e `20261120300000`. Nenhuma delas cita `painel_estabelecimento` nem cria índice (MEDIDO por `grep`), e não foram aplicadas: o banco é compartilhado e não se mexe nele por causa de uma medição.

| Cenário | Janela | Vagas / posições / candidaturas / turnos na janela | Mediana (ms) | Mín (ms) | Máx (ms) | Resposta (bytes) | `explain` Execution Time (ms) | `explain` Buffers (shared hit) | `Seq Scan` executados em posicao/ocorrencia/vaga (planos registrados, maior loops) |
|---|---|---|---|---|---|---|---|---|---|
| S1 | 1 dia | 3 / 6 / 36 / 6 | 4,02 | 3,59 | 6,24 | 5.108 | 4,291 | 1.363 | 15 / 0 / 1 (91, loops=9) |
| S2 | 7 dias | 21 / 42 / 252 / 34 | 26,27 | 25,49 | 29,49 | 33.736 | 23,674 | 9.104 | 79 / 1 / 1 (597, loops=42) |
| S3 | 30 dias | 83 / 249 / 2.490 / 199 | 203,28 | 190,88 | 219,76 | 181.432 | 189,931 | 113.855 | 2 / 0 / 0 (2, loops=249) |
| S6 | 45 dias | 124 / 372 / 3.720 / 298 | 314,64 | 289,74 | 714,29 | 271.156 | 306,976 | 169.906 | 2 / 0 / 0 (11, loops=372) |
| S4 | 365 dias | 1.000 / 3.000 / 30.000 / 2.400 | 2.621,46 | 2.228,19 | 2.820,98 | 2.186.748 | 2.671,742 | 1.353.083 | 314 / 0 / 0 (3.087, loops=3000) |
| S5 | 1.825 dias | 1.000 / 3.000 / 30.000 / 2.400 | 2.822,68 | 2.535,99 | 3.343,10 | 2.186.748 | 2.910,561 | 1.353.083 | 699 / 0 / 0 (4.712, loops=3000) |
| S3_membro5 | 30 dias, leitor em 5 casas | 83 / 249 / 2.490 / 199 | 456,54 | 353,05 | 1.041,54 | 181.432 | 558,267 | 114.751 | 53 / 0 / 0 (381, loops=249) |

Todos os números da tabela são MEDIDOS nesta execução. O plano interno saiu preenchido em 7 de 7 cenários (na primeira execução, `NAO MEDIDO` em 6 de 6): o padrão `DB_USER=supabase_admin` conecta e o `auto_explain` carrega.

Limites de leitura, sem interpretação do desempenho:

- **A contagem de `Seq Scan` não compara entre cenários da casa B nem entre execuções.** O `auto_explain` da casa B registra só consultas internas com 1 ms ou mais (`AUTO_EXPLAIN_MIN_MS`, padrão 1; na casa A é 0). S4 e S5 têm o mesmo volume e a mesma resposta e registraram 3.087 e 4.712 planos; S3 registrou 2 planos nesta execução e 175 num ensaio feito minutos antes no commit `2c8ed18` (sem registro na tabela). Para comparar planos, rode com `AUTO_EXPLAIN_MIN_MS=0` (saída grande).
- **O tempo varia entre execuções.** Medianas de S3 observadas: 608,85 ms (18/11, `postgres`), 177,39 ms (20/11, segunda execução), 366,22 ms (22/11, ensaio no `2c8ed18`, sem registro de tabela) e 203,28 ms (22/11, esta). Em S3_membro5 a mediana desta execução (456,54 ms) ficou acima da de S3 (203,28 ms); na primeira execução foi abaixo (368,36 ms contra 608,85 ms) e na segunda ficou próxima (182,81 ms contra 177,39 ms). A causa da variação não foi investigada. Compare cenários dentro de uma execução e não use uma mediana isolada.
- Com 10 amostras não se afirma p95. O máximo de S6 (714,29 ms) e o de S3_membro5 (1.041,54 ms) são picos de uma amostra.
- Volume é **HIPÓTESE**: S1 e S2 agora têm 3 e 21 vagas, mas 3 por dia é o limite do gerador. Uma casa com mais de 3 vagas por dia não é representável sem mudar o gerador.

Não medido nesta execução: p95; autovacuum e versões mortas depois do `rollback`; consultas internas com menos de 1 ms na casa B; qualquer volume ou janela de produto (Cauê ou Jota); o tamanho real de `posicao`, `ocorrencia` e `vaga` no Prod. A decisão entre índice, janela limitada e paginação não está neste documento.

## p50 e p95 com 5 casas (`medir-painel-volume.sh`)

Pergunta do cartão: com 5 casas de 200 vagas x 10 posições, qual o p50 e o p95 do painel para períodos de 7 e 31 dias, contra a meta proposta de p95 <= 1000 ms? A meta é **proposta**, não SLA do repositório; o script a imprime ao lado do resultado e não reprova por ela.

### Como executar

```bash
supabase start && supabase db reset                       # banco local limpo
./scripts/medir-painel-volume.sh --saida ~/medicao-volume  # carrega, mede, relata
./scripts/teste-medir-painel-volume.sh                     # autoteste do script (sem banco)
```

Parâmetros por variável de ambiente (padrões = cenário do cartão): `CASAS=5 VAGAS=200 POSICOES=10 CANDIDATOS=6 DIAS_HISTORICO=67 JANELAS=7,31 AMOSTRAS=20 AQUECIMENTO=3 META_P95_MS=1000`. O cabeçalho do script lista todos. O banco local é compartilhado entre sessões: use `DB_CONTAINER` para apontar para um contêiner seu, se houver. Os mesmos cuidados de segurança de `medir-painel.sh` valem (transação com `rollback`, resíduo contado, só banco local).

Saída `0`: mediu, com amostras completas e volume conferido. Saída `2`: não mediu (nunca `0` por omissão); o relatório diz o motivo e nenhuma linha `RESULTADO` sai. Estourar a meta não muda a saída: aparece como `meta=NAO_ATENDE`.

### O que é medido

- 5 casas, cada uma com 200 vagas x 10 posições x 6 candidaturas por posição (HIPÓTESE do cartão; as 6 candidaturas são escolha de quem implementou), histórico de 67 dias. Cada casa é lida pelo seu próprio dono, membro só dela, como `authenticated`.
- Janelas de 7 e 31 dias a partir do primeiro dia do histórico.
- 20 chamadas por casa e janela depois de 3 rodadas de aquecimento descartadas: **100 amostras por janela**. As rodadas intercalam janelas e casas.
- p50 e p95 sobre as 100 amostras da janela (as 5 casas têm o mesmo formato; juntá-las é uma suposição, e o relatório traz a mediana e o máximo de cada casa). Método: interpolação linear, igual a `percentile_cont`; o script confere o seu cálculo contra o `percentile_cont` do Postgres e não mede se divergirem.
- O planejador roda **livre** (`enable_seqscan=on`, registrado na linha `CONFIG`). O portão `supabase/tests/310_consultas_quentes_df.sql` usa `enable_seqscan=off` e a carga nunca roda na CI, então este é o único lugar onde esse plano é observado.

**Limite do gerador (DEDUZIDO do código):** no máximo 3 vagas por dia. Com 200 vagas por casa o histórico tem 67 dias, e a janela de 7 dias contém 21 vagas, a de 31 dias, 93 (confirmado pelas linhas `VOLUME_JANELA`). **Não há como pôr as 200 vagas dentro de 7 ou 31 dias com este gerador.** Se o cartão queria 200 vagas dentro da janela, essa medição **não foi feita**.

### Resultado (MEDIDO, 25/11/2026, banco local, Postgres 17.6, papel `supabase_admin`)

Contexto de cada execução: o código do script já com o autoteste (commit "autoteste de medir-painel-volume.sh com saída real como fixture", execuções 2 e 3) ou o mesmo código antes do último ajuste do script (execução 1); banco recém-criado por `supabase db reset` nas execuções 2 e 3; 246 migrações aplicadas; 18 usuários antes e depois; resíduo 0. A execução 1 é a fixture `scripts/fixtures/medir-painel-volume-real.txt`.

| Execução | Janela | Vagas / posições / candidaturas na janela (por casa) | Amostras | p50 (ms) | p95 (ms) | máx (ms) |
|---|---|---|---|---|---|---|
| 1 | 7 dias | 21 / 210 / 1.260 | 100 | 154,47 | 161,67 | 177,18 |
| 1 | 31 dias | 93 / 930 / 5.580 | 100 | 681,50 | 707,03 | 721,29 |
| 2 | 7 dias | 21 / 210 / 1.260 | 100 | 152,86 | 165,31 | 174,85 |
| 2 | 31 dias | 93 / 930 / 5.580 | 100 | 677,58 | 724,08 | 774,42 |
| 3 | 7 dias | 21 / 210 / 1.260 | 100 | 166,61 | 179,78 | 193,91 |
| 3 | 31 dias | 93 / 930 / 5.580 | 100 | 741,87 | 783,15 | 813,09 |

Leitura (sem decisão):

- Nas cinco execuções, em duas máquinas, o p95 ficou abaixo de 1.000 ms (MEDIDO). Máquina do autor (3 execuções): 161,67 a 179,78 ms em 7 dias e 707,03 a 783,15 ms em 31 dias. Máquina da reverificação independente (2 execuções, banco próprio, load average de 5,95 a 6,02 em 10 CPUs com outras duas pilhas Supabase de pé): 193,83 a 201,01 ms em 7 dias e 822,47 a 873,71 ms em 31 dias. Na janela de 31 dias a margem para a meta foi de cerca de 13% (873,71 ms) a 29% (707,03 ms), conta a partir desses números. A margem depende da carga da máquina: não a trate como valor fixo.
- A variação entre execuções existe: o p50 de 31 dias foi de 677,58 a 741,87 ms. Use o intervalo, não uma execução só.
- O tempo cresce com a janela de forma próxima de linear com o número de vagas: 21 vagas custam cerca de 155 ms e 93 vagas cerca de 680 ms (MEDIDO); a razão dos tempos (4,4) é próxima da das vagas (4,4). Que o custo seja linear em vagas é DEDUZIDO desses dois pontos.
- Plano das consultas internas (casa 1, `auto_explain`, MEDIDO na execução 1): 2.625 planos registrados em 7 dias e 11.601 em 31 dias; Seq Scan **executado** em `posicao` 191 e 839 vezes, e nenhum em `vaga`, `ocorrencia`, `candidatura` nem `turno`. Um dos planos de `posicao` (filtro `falta AND profissional_id = p.id`) removeu 10.019 linhas por chamada, ou seja, varre a tabela inteira, que neste banco tem as 10.000 posições das 5 casas. Isso indica um custo que cresce com o tamanho de `posicao`, e não só com a janela (DEDUZIDO; não foi medido com outro tamanho de tabela).

### Recomendação (não implementada; fora do escopo do cartão)

1. Com o volume e a hipótese acima, a meta de p95 <= 1.000 ms é atendida localmente em 7 e em 31 dias. **Não é evidência para o Prod**: o tempo local não transfere (plano gratuito, CPU e disco compartilhados).
2. Antes de decidir paginação ou RPC agregada, vale medir o efeito do Seq Scan em `posicao` com a tabela maior (por exemplo, 50 casas), porque o custo desse nó depende do tamanho da tabela e não da janela. Um índice não muda o contrato; paginação ou limite de janela mudam e são decisão do Cauê, com o ok do Fabrício (UI).
3. A decisão sobre meta, índice, janela limitada ou paginação é do Cauê ou do Jota.

### Não medido

- Qualquer janela com 200 vagas dentro dela (limite do gerador, acima).
- Tabelas maiores que as 5 casas (o banco só tem esta carga e o seed de 18 usuários).
- Concorrência: as chamadas são sequenciais, de uma conexão.
- Prod ou frila-dev: nenhum banco remoto foi tocado.
- O efeito de autovacuum e de versões mortas depois do `rollback`.
- O número de candidaturas por posição (6) é escolha de quem implementou e não foi confirmado com o Cauê ou o Jota.
- A causa da variação entre execuções.
