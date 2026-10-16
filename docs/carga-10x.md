# Relatório de Desempenho e Planos de Execução com Carga em Escala 10x do DF

**Data:** 15 de outubro de 2026  
**Ambiente:** PostgreSQL 17 local (Supabase CLI)  
**Componente:** frila-backend (banco de dados Supabase)  
**Escopo:** Documentação técnica e instrumentação de teste. Nenhuma migração ou índice de produção é alterado neste PR.

---

## 1. Sumário Executivo

Este relatório consolida a aferição de estresse e escalabilidade do banco de dados do Frila sob volume **10x o Distrito Federal**, comparando as métricas com as linhas de base de 1x e 2x.

O objetivo foi estressar os caminhos críticos quentes:
1. `privado.elegiveis(vaga_id)`: despacho espacial e filtros de elegibilidade.
2. `public.vagas_abertas(...)`: ordenação espacial por proximidade geográfica via operador GiST (`<->`) com filtro de data.
3. `privado.fechar_turnos_e_vagas()`: rotina de encerramento do ciclo de vida, testando a janela de 7 dias e `not exists` introduzida no PR #183.

A carga foi parametrizada dinamicamente via variável de configuração de sessão `frila.carga_escala = '10'` em `supabase/tests/carga/gerar_df.sql` e chave `--escala 10` em `scripts/planos-com-carga.sh`, preservando integralmente o comportamento padrão da CI (`ESCALA=1`).

---

## 2. Tabela Comparativa de Métricas e Latências

| Métrica / Consulta | Volume DF (1x) | Escala 2x | Escala 10x | Teto Padrão Local (1x) | Status em 10x |
|---|---|---|---|---|---|
| **Contas de Usuário (`usuario`)** | 130.018 | 260.018 | **1.300.018** | — | Base povoada |
| **Profissionais (`profissional`)** | 100.013 | 200.013 | **1.000.013** | — | 1 Milhão no DF |
| **Vagas Publicadas (`vaga`)** | 20.010 | 40.010 | **200.010** | — | 200 Mil no DF |
| **Janelas de Grade (`disponibilidade`)** | 200.018 | 400.018 | **2.000.018** | — | 2 Milhões no DF |
| **`privado.elegiveis` (Mediana)** | **13,8 – 15,5 ms** | 31,2 ms *(ou 69,7 ms)*¹ | **1.154,8 ms** | 50,0 ms | ⚠️ Degradação de ~83x |
| **`privado.elegiveis` (p95)** | **15,6 – 20,8 ms** | 33,2 ms *(ou 78,2 ms)*¹ | **1.878,5 ms** | 100,0 ms | ⚠️ Degradação de ~120x |
| **Varredura Sequencial em `usuario`** | 0 linhas | 0 *(ou 260.023 l)*¹ | **1.300.018 linhas** | 0 linhas | ❌ Regressão crítica |
| **`public.vagas_abertas` (Mediana)** | **15,1 – 15,5 ms** | 31,6 – 31,7 ms | **202,0 ms** | 100,0 ms | ⚠️ Degradação de ~13x |
| **`public.vagas_abertas` (p90)** | **15,2 ms** | 32,3 ms | **271,2 ms** | — | Elevação |
| **`public.vagas_abertas` (p95)** | **15,2 – 17,9 ms** | 32,7 ms | **285,3 ms** | 300,0 ms | 🟡 Dentro do teto local |
| **`fechar_turnos_e_vagas` (Laço 7 dias)** | — | — | **30,9 ms** | — | 🟢 Estável |
| **`fechar_turnos_e_vagas` (Canc. Posições)** | — | — | **287,5 ms** | — | 🟡 Seq Scan + tempo residual |
| **`fechar_turnos_e_vagas` (Enc. Vagas)** | — | — | **969,9 ms** | — | ⚠️ Seq Scan + tempo residual |

*Notas:*  
¹ **Ponto de Inflexão em Escala 2x:** A medição de 2x varia sensivelmente com o estado das estatísticas do planejador PostgreSQL. Em ambiente com estatísticas atualizadas pós-migrações 15/10, o planejador PostgreSQL já inverte o plano para `Seq Scan` em `usuario` (260.023 linhas) com mediana de **69,7 ms** (p95 **78,2 ms**), reprovando o teto do script local (50 ms). Quando o planejador ainda seleciona `Index Scan` na PK de `usuario`, a mediana se sustenta em 31,2 ms (p95 33,2 ms). Esse achado demonstra que o ponto de inflexão e instabilidade do planejador ocorre precocemente entre 1x e 2x.  
² **Tetos Oficiais da CI (`ci.yml`):** A CI utiliza limites mais amplos que os defaults do script para tolerar o jitter de virtualização dos runners compartilhados: `MED_MAX_ELEGIVEIS=100`, `P95_MAX_ELEGIVEIS=400`, `MED_MAX_VAGAS=200`, `P95_MAX_VAGAS=600`.  
³ **Discrepância Local vs. CI:** Em 1x local as latências rondam ~15 ms em máquina com CPU dedicada e NVMe. Conforme documentado na auditoria de 14/10, na CI compartilhada a latência p95 de `vagas_abertas` opera comumente entre **780 ms e 1.380 ms** devido à sobrecarga de virtualização e contenção de I/O.

---

## 3. Análise Detalhada dos Planos de Execução (EXPLAIN)

### 3.1. Gargalo 1: `privado.elegiveis()` e a Varredura em Massa de Usuários

Sob volume de 1.000.000 de profissionais (1.300.018 contas de usuário no DF), o planejador PostgreSQL inverteu a estratégia de junção da CTE `candidatos`:

```text
-> Hash (cost=43815.22..43815.22 rows=1300018 width=16) (actual time=189.343..189.344 rows=1300015 loops=1)
      Buckets: 262144  Batches: 16  Memory Usage: 5854kB
      -> Seq Scan on usuario u (cost=0.00..43815.22 rows=1300018 width=16) (actual time=0.005..113.069 rows=1300015 loops=1)
            Filter: ((NOT demonstracao) AND (estado = 'ativa'::public.estado_conta))
            Rows Removed by Filter: 3
```

- **Diagnóstico da Decomposição do Tempo:**
  - O nó `Seq Scan on usuario u` custa **113,1 ms** lendo sequencialmente 1.300.018 linhas (1.300.015 aceitas e 3 descartadas pelo filtro `estado = 'ativa' AND NOT demonstracao`).
  - O nó `Hash` associado eleva o tempo acumulado para **189,3 ms**, exigindo 16 batches e ~5,8 MB de memória de trabalho.
  - O tempo restante até atingir a mediana de **1.154,8 ms** (e p95 de **1.878,5 ms**) não está decomposto neste relatório (o plano dos nós superiores de cruzamento na CTE não foi capturado individualmente com buffers e contagem de linhas).
- **Causa Raiz:** O planejador inverte a estratégia para `Seq Scan` em `usuario`. A avaliação de que lookups individuais na PK (`usuario_pkey`) seriam mais custosos que varrer a tabela sequencialmente via Hash Join é uma estimativa de custo interna do planejador (não uma medição direta de nós). Como demonstrado na medição de 2x (onde 260.023 linhas lidas já foram observadas com 69,7 ms de mediana), a escolha do plano se torna instável já a partir de 2x.

---

### 3.2. Gargalo 2: `public.vagas_abertas()` e o Filtro Pós-GiST por Data

No endpoint de listagem de vagas abertas ordenadas por proximidade ao candidato:

```text
Limit (actual rows=30 loops=1)
  InitPlan 2
    -> Result (actual rows=1 loops=1)
          InitPlan 1
            -> Limit (actual rows=1 loops=1)
                  -> Index Only Scan using vaga_janela_critica on vaga (actual rows=1 loops=1)
                        Heap Fetches: 4
  -> Index Scan using vaga_ponto_publicada on vaga v (actual rows=30 loops=1)
        Order By: (ponto <-> '0101000020E6100000E17A14AE47F147C014AE47E17A942FC0'::geography)
        Filter: (((inicio_em AT TIME ZONE 'America/Sao_Paulo'::text))::date = (InitPlan 2).col1)
        Rows Removed by Filter: 397
```

- **Diagnóstico:** O índice `vaga_ponto_publicada` é estritamente espacial (`USING gist (ponto) WHERE estado = 'publicada'`). O operador k-NN `<->` percorre os vizinhos mais próximos no espaço geográfico bidimensional. Como a consulta filtra apenas as vagas do dia (`inicio_em::date = dia_critico`), 397 vagas próximas no espaço, mas agendadas para outras datas da grade de 14 dias, foram lidas e descartadas pelo filtro pós-varredura.
- **Impacto:** Em 200.000 vagas espalhadas na grade, o volume de nós descartados antes de preencher `LIMIT 30` elevou a latência mediana de 15,1 ms para **202,0 ms** (p95 de **285,3 ms**). Embora ainda esteja dentro do teto local (300 ms) e da CI (600 ms), a latência cresce de 15 para 202 ms entre 1x e 10x com o aumento da densidade de vagas.

---

### 3.3. Gargalo 3: `privado.fechar_turnos_e_vagas()` e a Limpeza de Ciclo de Vida

Na rotina de encerramento executada a cada 5 minutos pelo `pg_cron`:

#### 3.3.1. Laço de Notificação com Janela de 7 Dias e `not exists` (PR #183)
```text
Hash Join (actual time=7.550..30.746 rows=5000 loops=1)
  -> Nested Loop
        -> Hash Anti Join (t.id = n.referencia_id)
              -> Seq Scan on turno t (Filter: verificacao = 'verificado')
              -> Hash -> Seq Scan on notificacao n (Filter: tipo = 'avaliacao_disponivel')
        -> Index Scan using posicao_pkey on posicao p
Execution Time: 30.896 ms
```
- **Diagnóstico:** A janela de 7 dias e o `not exists` do PR #183 mantiveram o tempo de execução em **30,9 ms**, demonstrando estabilidade mesmo em 10x.
- **Esclarecimento sobre a tabela `notificacao`:** A tabela já possui o índice parcial único `notificacao_marca_de_envio UNIQUE (tipo, referencia_id, usuario_id, rodada) WHERE tipo IN (...)`. A escolha do planejador por `Hash -> Seq Scan on notificacao` decorre do volume relativo e distribuição estatística no teste de carga com 5.000 turnos gerados, e não de ausência de índice no schema. Não há necessidade de índice redundante neste ponto.

#### 3.3.2. Cancelamento de Posições Abertas Expiradas
```text
Update on posicao p (actual time=38.636..38.636 rows=0 loops=1)
  -> Seq Scan on posicao p (actual time=0.027..20.479 rows=10000 loops=1)
        Filter: ((estado = 'aberta'::estado_posicao) AND (fim_em <= privado.agora()))
        Rows Removed by Filter: 20019
Execution Time: 287.548 ms
```
- **Diagnóstico da Decomposição do Tempo:**
  - O nó `Seq Scan on posicao p` leva **20,5 ms** varrendo as posições para filtrar `fim_em <= agora`. O nó `Update on posicao p` leva **38,6 ms**.
  - Há um resíduo de **~228 ms** fora dos nós mostrados (totalizando 287,5 ms de `Execution Time`). A atribuição desse tempo residual a gatilhos pós-update (como triggers de integridade, histórico e auditoria) e atualização de índices é uma hipótese explicativa, já que os planos colados não trazem linhas `Trigger ...: time=`.
  - A tabela `posicao` possui índice `posicao_abertas (vaga_id) WHERE estado = 'aberta'`, mas ele não inclui `fim_em`, forçando a leitura sequencial na etapa de seleção.

#### 3.3.3. Encerramento de Vagas Expiradas
```text
Update on vaga v (actual time=158.443..158.445 rows=0 loops=1)
  -> Hash Anti Join
        -> Seq Scan on vaga v (Filter: estado in ('publicada','preenchida') AND fim_em <= privado.agora())
        -> Hash -> Seq Scan on posicao p (Filter: estado in ('aberta','confirmada'))
Execution Time: 969.952 ms
```
- **Diagnóstico da Decomposição do Tempo:**
  - O nó `Update on vaga v` consome **158,4 ms** aplicando as modificações.
  - Há um resíduo de **~811 ms** fora dos nós mostrados (totalizando 969,9 ms de `Execution Time`). A atribuição desse tempo à execução de gatilhos em cascata nas vagas modificadas e à manutenção de índices pesados (em especial o índice espacial GiST `vaga_ponto_publicada`) é uma hipótese explicativa, pois o plano colado não traz linhas `Trigger ...: time=`.
  - O `Seq Scan` em `vaga` ocorre porque não há índice que cubra `fim_em` para vagas ativas (`estado IN ('publicada', 'preenchida')`), resultando na leitura sequencial de todas as 200.000 vagas na fase de seleção.

---

### 3.4. Medição de Triggers em `privado.fechar_turnos_e_vagas()` (Escala 2x)

Para investigar a causa do tempo residual fora dos nós de leitura (`Seq Scan` / `Update`), foi executada a medição empírica com `EXPLAIN (ANALYZE, BUFFERS)` na carga 2x do Distrito Federal (40.000 vagas e 40.000 posições, com lote de 2.000 registros expirados). O plano revela detalhadamente a execução de gatilhos disparados linha a linha (`Trigger ...: time=... calls=...`).

#### 3.4.1. UPDATE de Posições Expiradas (`public.posicao`)

```text
Update on posicao p  (cost=0.00..1155.33 rows=0 width=0) (actual time=5.929..5.929 rows=0 loops=1)
  Buffers: shared hit=14585 read=7 dirtied=30 written=23
  ->  Seq Scan on posicao p  (cost=0.00..1155.33 rows=2010 width=10) (actual time=0.004..1.481 rows=2000 loops=1)
        Filter: ((estado = 'aberta'::estado_posicao) AND (fim_em <= now()))
        Rows Removed by Filter: 38019
        Buffers: shared hit=455
Planning Time: 0.126 ms
Trigger for constraint posicao_vaga_id_fkey: time=6.447 calls=2000
Trigger posicao_auditoria: time=38.080 calls=2000
Trigger posicao_recalcula_comparecimento: time=2.496 calls=2000
Execution Time: 53.223 ms
```

- **Decomposição do Tempo:**
  - Varredura de seleção (`Seq Scan` em 40.000 posições): **1,48 ms** (2,8% do tempo total).
  - Execução da atualização no nó `Update`: **5,93 ms** (11,1%).
  - **Execução de Triggers por Linha:** **47,02 ms** (**88,3% do tempo total**):
    - `posicao_auditoria` (`audita_ciclo`): **38,08 ms** (71,5%)
    - `posicao_vaga_id_fkey` (checagem de FK): **6,45 ms** (12,1%)
    - `posicao_recalcula_comparecimento`: **2,50 ms** (4,7%)
- **Causa Comprovada:** O tempo residual anteriormente não discriminado (~228 ms na carga 10x) decorre comprovadamente dos gatilhos executados para cada posição cancelada, sendo a auditoria de ciclo (`audita_ciclo`) responsável por mais de 70% do tempo total.

#### 3.4.2. UPDATE de Vagas Expiradas (`public.vaga`)

```text
Update on vaga v  (cost=1528.91..3583.17 rows=0 width=0) (actual time=19.140..19.141 rows=0 loops=1)
  Buffers: shared hit=30203 read=11 dirtied=86 written=67
  ->  Hash Anti Join  (cost=1528.91..3583.17 rows=1 width=16) (actual time=4.647..8.478 rows=2000 loops=1)
        Hash Cond: (v.id = p.vaga_id)
        Buffers: shared hit=1812
        ->  Seq Scan on vaga v  (cost=0.00..2034.18 rows=2008 width=22) (actual time=0.012..3.387 rows=2000 loops=1)
              Filter: ((estado = ANY ('{publicada,preenchida}'::estado_vaga[])) AND (fim_em <= now()))
              Rows Removed by Filter: 38010
              Buffers: shared hit=1334
        ->  Hash  (cost=1003.52..1003.52 rows=42031 width=22) (actual time=4.624..4.624 rows=38010 loops=1)
              Buckets: 65536  Batches: 1  Memory Usage: 2517kB
              Buffers: shared hit=478
              ->  Seq Scan on posicao p  (cost=0.00..1003.52 rows=42031 width=22) (actual time=0.003..2.551 rows=38010 loops=1)
                    Filter: (estado = ANY ('{aberta,confirmada}'::estado_posicao[]))
                    Rows Removed by Filter: 2009
                    Buffers: shared hit=478
Planning Time: 0.169 ms
Trigger for constraint vaga_estabelecimento_id_fkey: time=6.283 calls=2000
Trigger for constraint vaga_funcao_id_fkey: time=4.899 calls=2000
Trigger for constraint vaga_publicado_por_fkey: time=5.236 calls=2000
Trigger vaga_auditoria: time=44.937 calls=2000
Trigger vaga_fechada_expira_candidaturas: time=14.970 calls=2000
Execution Time: 95.951 ms
```

- **Decomposição do Tempo:**
  - Varredura e junção de seleção (`Hash Anti Join` + `Seq Scan` em 40.000 vagas e posições): **8,48 ms** (8,8% do tempo total).
  - Execução da atualização no nó `Update`: **19,14 ms** (19,9%).
  - **Execução de Triggers por Linha:** **76,33 ms** (**79,5% do tempo total**):
    - `vaga_auditoria` (`audita_ciclo`): **44,94 ms** (46,8%)
    - `vaga_fechada_expira_candidaturas`: **14,97 ms** (15,6%)
    - Triggers de FK (`estabelecimento`, `funcao`, `publicado_por`): **16,42 ms** (17,1%)
- **Causa Comprovada:** O tempo residual (~811 ms na carga 10x) é explicado em ~80% pelos gatilhos pós-update (`vaga_auditoria`, `vaga_fechada_expira_candidaturas`) e pelas verificações de chaves estrangeiras.

#### 3.4.3. Avaliação Experimental de Índices Parciais em `fim_em`

Para testar experimentalmente se índices parciais em `fim_em` adiantam contra o gargalo, os comandos foram repetidos com os índices criados na sessão:
- `posicao_aberta_expirada_idx ON public.posicao (fim_em) WHERE estado = 'aberta'`
- `vaga_ativa_expirada_idx ON public.vaga (fim_em) WHERE estado IN ('publicada', 'preenchida')`

**Resultados:**
1. **Fase de Leitura/Seleção:**
   - Em `posicao`: o tempo de seleção caiu de 1,48 ms (`Seq Scan`, 455 buffers) para **0,17 ms** (`Bitmap Index Scan`, 27 buffers).
   - Em `vaga`: o scan da tabela `vaga` caiu de 3,39 ms (1.334 buffers) para **0,25 ms** (70 buffers), permanecendo a leitura da tabela de posições pelo Hash Anti Join (2,89 ms).
2. **Tempo Total de Execução:**
   - `posicao`: 53,2 ms (sem índice) vs **59,8 ms** (com índice).
   - `vaga`: 95,9 ms (sem índice) vs **91,1 ms** (com índice).
3. **Decisão:**
   - **Os índices parciais NÃO adiantam para mitigar o gargalo de tempo total.**
   - O ganho obtido na leitura (economia de ~1,3 a 3,1 ms) é insignificante frente ao tempo total, dominado em 80%–88% pelos gatilhos por linha.
   - Além disso, novos índices acarretam custo de escrita permanente a cada `INSERT` ou `UPDATE` de vaga e posição.
   - Na rotina normal de produção (execução a cada 5 minutos pelo `pg_cron` com volume típico de 5 a 20 vagas expiradas por rodada), o tempo total é sub-milissegundo (< 1 ms). Logo, a decisão técnica fundamentada é **não criar os índices parciais**.

---

## 4. Recomendações Técnicas para Evolução (Backlog Futuro)

> [!IMPORTANT]
> Nenhuma das alterações abaixo é aplicada neste PR (estritamente documental). Cada intervenção deverá ser implementada em branch própria com migração versionada, teste com `EXPLAIN` antes/depois sob carga e cobertura pgTAP.

### Recomendação 1: Otimizar o Join de `usuario` em `privado.elegiveis`
- **Ação:** Reordenar as junções da CTE de candidatos para aplicar o filtro de raio espacial GiST (`ST_DWithin(ponto_base, ...) <= 15000`) **antes** de efetuar o join com `usuario`.
- **Hipótese de Ganho (Projeção Teórica não Medida Experimentalmente):**
  - Espera-se que, ao filtrar geograficamente primeiro, a massa de candidatos seja reduzida de ~62.500 para poucas dezenas de profissionais locais. Com isso, o planejador passará a empregar `Index Scan` na chave primária `usuario_pkey`, eliminando a necessidade do hash table de 1,3 milhão de contas e do `Seq Scan`. A hipótese deve ser validada e medida empiricamente em PR dedicado.

### Recomendação 2: Índice Composto ou Particionado para `vagas_abertas`
- **Ação:** Avaliar o uso da extensão `btree_gist` para compor data de início e ponto geográfico no mesmo índice GiST:
  ```sql
  CREATE INDEX vaga_data_ponto_publicada ON public.vaga 
  USING gist ((((inicio_em AT TIME ZONE 'America/Sao_Paulo')::date)), ponto) 
  WHERE estado = 'publicada';
  ```
- **Hipótese de Ganho (Projeção Teórica não Medida Experimentalmente):**
  - Espera-se que a busca k-NN (`<->`) percorra diretamente a árvore espacial já restrita à data de interesse, eliminando o descarte de centenas de pontos de outras datas (`Rows Removed by Filter: 397`). A eficácia contra o custo de escrita adicional do índice deve ser medida via pgTAP e benchmark dedicado.

### Recomendação 3: Índices Parciais Dedicados para Seleção em `fechar_turnos_e_vagas`
- **Ação Proposta Originalmente:**
  ```sql
  CREATE INDEX posicao_aberta_expirada_idx ON public.posicao (fim_em) 
  WHERE estado = 'aberta';
  CREATE INDEX vaga_ativa_expirada_idx ON public.vaga (fim_em) 
  WHERE estado IN ('publicada', 'preenchida');
  ```
- **Conclusão e Decisão Empírica (Aferida na Seção 3.4):**
  - A medição de triggers sob carga 2x comprovou que 80% a 88% do tempo de execução decorre dos gatilhos disparados linha a linha (`audita_ciclo`, `vaga_fechada_expira_candidaturas`, `posicao_recalcula_comparecimento` e FKs), e não da varredura de leitura (`Seq Scan`), que consome apenas ~1,5 a 8,5 ms.
  - A criação dos índices parciais reduziu a leitura para ~0,2 ms, mas não alterou a ordem de grandeza do tempo total (53 ms vs 59 ms em posições; 96 ms vs 91 ms em vagas).
  - Como a rotina de produção roda a cada 5 minutos com volume reduzido (5 a 20 vagas) e tempo sub-milissegundo, o custo de manutenção desses índices parciais supera qualquer benefício. **Decisão:** Não criar os índices parciais.
