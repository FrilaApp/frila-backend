# Plano de métricas para a Academy

Atende ao pedido do mentor da Apple Developer Academy (24/11/2026) sobre as métricas do Frila: definir o que se mede, por quê e como; ter a coleta preparada para quando houver usuários reais; e validar a coleta com dados simulados. Dado simulado valida o **mecanismo**, não o desempenho real.

A instrumentação **já existe** no backend e está documentada em [`docs/PainelDoPiloto.md`](../PainelDoPiloto.md) (schema `metrica`, `scripts/funil.sh`, `scripts/gerar-painel.sh`). Este documento não repete o que está lá: liga essa instrumentação aos 4 indicadores que o mentor nomeou e mostra a conta de cada um. A validação com dados sintéticos está em [`scripts/validar-metricas-sinteticas.sh`](../../scripts/validar-metricas-sinteticas.sh), e o resultado medido em [`RelatorioValidacaoMetricas-Sintetica.md`](RelatorioValidacaoMetricas-Sintetica.md).

Nenhuma tabela, view, função ou migração foi criada para isto. As consultas abaixo só leem `metrica.*` e `public.*`.

## Por quê, em uma frase

Os 4 indicadores dizem se o ciclo publicar → candidatar → contratar funciona de ponta a ponta (oferta, interesse e fechamento), e o exercício do Challenge é mostrar que a coleta registra isso certo **antes** de haver usuários reais, para que o primeiro número real já seja confiável. Nenhum número daqui é meta nem resultado de produto. (Inferência: o vínculo com o aprendizado do Challenge é a leitura do pedido do mentor, não uma decisão registrada de produto.)

## Os 4 indicadores

Todas as contas valem para um período. `metrica.funil_por_vaga` tem `dia` (data de publicação em America/Sao_Paulo) e `publicado_em`: para um período, filtre `where dia between …`. `metrica.funil_geral` e `metrica.funil_por_dia` já agregam sobre essa view.

| # | Indicador | O que mede | Fórmula | De onde sai |
|---|---|---|---|---|
| 1 | Candidaturas por vaga | Interesse que cada vaga atrai | `sum(candidaturas) / count(vaga_id)` | `metrica.funil_por_vaga` (ou `funil_geral.candidaturas / funil_geral.vagas_publicadas`) |
| 2 | Taxa de preenchimento | Quantas vagas fecharam com gente | `count(vaga com confirmacoes >= posicoes_ofertadas) / count(vaga)` | `metrica.funil_por_vaga`; versão efetiva em `public.posicao` (abaixo) |
| 3 | Vagas não preenchidas | O que ficou sem ninguém | `count(vaga) - count(vaga preenchida)`, na mesma base do 2; em % é `1 - taxa de preenchimento` | idem |
| 4 | Conversão candidatura → contratação | Quantas candidaturas viram contratação | `sum(confirmacoes) / sum(candidaturas)` | `metrica.funil_geral` (colunas `confirmacoes` e `candidaturas`) |

Consulta de referência (período = a view inteira; ponha o `where dia …` no `f`):

```sql
with f as (select * from metrica.funil_por_vaga)
select count(*)                                                        as vagas,
       round(sum(candidaturas)::numeric / count(*), 2)                 as candidaturas_por_vaga,
       round(100.0 * count(*) filter (where confirmacoes >= posicoes_ofertadas) / count(*), 2) as preenchimento_pct,
       count(*) filter (where confirmacoes < posicoes_ofertadas)       as nao_preenchidas,
       round(100.0 * sum(confirmacoes) / nullif(sum(candidaturas), 0), 2) as conversao_pct
  from f;
```

### Quatro cuidados que a medição mostrou

Estes pontos saíram da leitura das funções e das views; os números foram medidos na amostra sintética e no banco local (veja o relatório). Eles mudam a leitura dos números.

1. **`vaga.estado = 'preenchida'` é um retrato de agora, não um histórico.** Quando o turno acaba, `privado.fechar_turnos_e_vagas` passa a vaga para `encerrada` (se não restar posição aberta ou confirmada); e se o profissional desiste antes do início, `privado.cancelar_uma_posicao` devolve a vaga a `publicada`. Por isso `count(estado = 'preenchida') / count(vaga)` só vale para turnos que ainda não terminaram. Para um período passado, use a base por posição (`confirmacoes`), como na fórmula acima. Na amostra: 9 vagas `preenchida`, 12 preenchidas de fato, 15 com alguma confirmação.
2. **`confirmacoes` conta toda posição com `confirmado_em` preenchido, inclusive a que depois foi cancelada.** A desistência e o no-show não limpam `confirmado_em`. A conta acima (bruta) mostra o funil de entrada; para o que de fato se cumpriu, conte `public.posicao.estado in ('confirmada', 'cumprida')`. É a versão **efetiva**, e a diferença entre as duas é o tamanho do abandono e da desistência. Na amostra: 75,00% bruta contra 60,00% efetiva.
3. **Na urgência, só a candidatura vencedora tem linha.** `public.candidatar` devolve `409 posicao_ja_preenchida` a quem chega depois, sem gravar candidatura. A procura que perdeu a corrida não aparece em `candidaturas`, então o indicador 1 subestima o interesse das vagas em urgência. A seleção grava cada candidatura (`pendente` até a casa escolher), e os estados `aceita`, `recusada`, `retirada` e `expirada` existem no enum `estado_candidatura`. DEDUZIDO da leitura de `public.candidatar`; não executei a RPC.
4. **A conversão pode passar de 100% se houver confirmação sem linha de candidatura.** A conta divide `confirmacoes` por `candidaturas`, e as duas vêm de tabelas diferentes. MEDIDO no banco local de desenvolvimento, fora da amostra sintética: 10 posições confirmadas sem candidatura (9 delas dos cenários de `supabase/cenarios.sql`, inseridos direto), e a conta deu 180,00% ali. Em produção, o caminho a conferir é a confirmação por chamada direta (`responder_chamada`); não verifiquei se ele grava candidatura. Antes de ler o indicador 4 como porcentagem, confira `count(confirmações sem candidatura)`.

O que as views **não** medem hoje: o abandono dentro do app (telemetria de cliente, `metrica.eventos_app_por_dia`, fora deste trabalho) e qualquer recorte por motivo de recusa. O no-show e a desistência saem de `public.posicao` e `public.turno`, não de uma view de `metrica`.

## Exclusões das views

Toda view de `metrica` deixa de fora quem tem `public.usuario.demonstracao = true` e quem está em `privado.conta_equipe`. Dados sintéticos precisam ficar fora das duas listas, senão a própria view os descarta e o resultado dá zero. O `scripts/validar-metricas-sinteticas.sh` mostra os dois lados: a amostra fica fora das exclusões (os `INSERT` usam o default `demonstracao = false` e nada entra em `conta_equipe`), e uma contra-prova marca uma casa como demonstração e outra como equipe para ver as vagas delas sumirem.

## Validação com dados sintéticos

```bash
./scripts/validar-metricas-sinteticas.sh              # semeia, mede, compara e desfaz (rollback)
./scripts/validar-metricas-sinteticas.sh --commitar   # grava de verdade e deixa o trap EXIT apagar
```

Prefixo de ids `fb000000-0000-4000-`, nenhum `supabase db reset`, trava contra `DATABASE_URL` remoto (como em `scripts/medir-rnf.sh`). A amostra tem 10 empregadores, 50 trabalhadores, 20 vagas de 1 posição, 80 candidaturas e 15 contratações, com no-show, cancelamento tardio, desistência antecipada, candidaturas recusadas, expiradas, retiradas e pendentes. Os valores esperados são literais do plano da amostra, nunca lidos das tabelas. O mapa completo da amostra está no cabeçalho de `scripts/validar-metricas-sinteticas.sql`.

## O que este plano não decide

Meta de qualquer indicador (por exemplo, "taxa de preenchimento deve ser X%") é decisão de produto, não deste documento. A amostra é inventada: um 75% aqui não diz nada sobre o Frila real.
