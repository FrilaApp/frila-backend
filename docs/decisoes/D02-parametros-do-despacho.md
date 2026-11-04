# D02 — Parâmetros do despacho: raio, teto e urgência

**Estado:** aceita a estrutura, **valores pendentes de dado do piloto** ·
**Cartão:** [`2RsO30sX`](https://trello.com/c/2RsO30sX) ·
**Requisitos:** RN05, RN23 · **Decisão técnica:** D2 ·
**Data:** 04/11/2026

## O problema

Três números decidem quem recebe aviso de vaga, e nenhum dos três nasceu de medição:

| Parâmetro | Valor hoje | Regra | Onde morava antes deste cartão |
|---|---:|---|---|
| Raio máximo do despacho | 15 km | RN05 | **Literal `15000`** dentro de `privado.elegiveis` (`20260929160100_elegiveis_ordem_de_filtro.sql`) |
| Teto entre notificações | 30 min | RN23 | `privado.parametro_notificacao` (`teto_janela`) |
| Antecedência da urgência | 2 h | RN23 | `privado.parametro_notificacao` (`urgente_antecedencia`) |

Os dois da RN23 já eram configuráveis desde o cartão `ee3MT3fH`: mudam com um `update` e
o despacho lê a cada decisão. O raio da RN05 **não era** — trocar 15 km por 12 km exigia
migração, revisão, merge e deploy, o que é lento demais para um ajuste de operação que o
piloto pode pedir numa segunda-feira. [MEDIDO: `grep -n 15000` nas migrações; o literal
aparece em `privado.elegiveis`]

Esta decisão trata **só da estrutura**: tirar o raio do código e colocá-lo onde os outros
dois já estavam. O valor novo de cada parâmetro é a segunda metade do cartão e depende de
dado que ainda não existe.

## O que foi medido, e o que não foi

**[MEDIDO] A estrutura.**

- `privado.parametro_notificacao` existe e tem as duas chaves da RN23, como `interval`:
  `teto_janela = 00:30:00` e `urgente_antecedencia = 02:00:00`. A leitura é
  `privado.parametro_de_notificacao(text)`, que levanta `parametro_ausente` (`P0002`)
  quando a chave não existe — de propósito: teto ausente não pode virar "sem teto".
- O raio era o literal `15000` em `extensions.ST_DWithin(p.ponto_base, v.ponto, 15000)`,
  dentro da CTE `candidatos as materialized` de `privado.elegiveis`.
- As views do painel do piloto existem e respondem: `metrica.funil_geral`,
  `metrica.funil_por_dia`, `metrica.funil_por_vaga`, `metrica.funil_por_estabelecimento`,
  `metrica.funil_confirmacoes`, `metrica.north_star_semanal`.
- Nenhuma view do painel traz **distância do confirmado**. A terceira pergunta do cartão
  não tem resposta pronta no painel; a consulta está na seção "Como medir", e se virar
  rotina merece uma view própria, em cartão próprio.

**[NÃO MEDIDO] Os valores do piloto.**

Não há dado de piloto em 04/11/2026. O cartão depende do GA de métricas da App Store
(27/11) e do relatório pós-lançamento (T-0020), e o banco local só tem dados de
demonstração — `metrica.funil_geral` responde `vagas_publicadas = 10`,
`notificacoes_enviadas = 1`, `candidaturas = 6`, `confirmacoes = 10`, números de cenário
sintético que não sustentam decisão nenhuma sobre raio ou teto.

**Portanto: nenhum dos três valores muda nesta decisão.** 15 km, 30 min e 2 h seguem como
estão. O que muda é que, quando o número do piloto chegar, o ajuste é um `update` e não um
PR de migração.

## A decisão

1. **O raio sai do código.** Nasce `privado.parametro_despacho`, irmã de
   `privado.parametro_notificacao`, com `valor_metros integer`. O raio da RN05 passa a ser
   a chave `raio_maximo_metros`, com `15000` de valor inicial — o mesmo número de antes,
   para a migração não mudar comportamento nenhum.
2. **Duas tabelas, não uma.** `parametro_notificacao` guarda `interval`;
   `parametro_despacho` guarda metro. Uma tabela só obrigaria uma coluna genérica
   (`valor_texto` com cast, ou `valor_numerico` com unidade declarada em outra coluna), e
   aí `30` em metros e `30` em minutos passariam a caber na mesma linha — o tipo de
   economia que custa um incidente. O tipo da coluna é a documentação que não envelhece.
3. **A leitura do raio tem fallback; a do teto não.** `privado.parametro_de_despacho_metros`
   devolve `NULL` quando a chave não existe, e `privado.elegiveis` aplica
   `coalesce(..., 15000)`. A assimetria é deliberada:
   - Teto ausente faria o despacho **notificar sem limite** — violação silenciosa da RN23,
     pior que parar. Daí a exceção.
   - Raio ausente faria o despacho **não achar ninguém** (`ST_DWithin` com `NULL` não
     seleciona nada), ou seja, vaga sem candidato em silêncio, que é o modo de falha mais
     caro do produto. O fallback devolve exatamente o padrão documentado da RN05.
4. **Uma leitura por chamada, não uma por linha.** O valor é lido para uma variável
   antes do `return query`. Ler dentro do predicado da CTE transformaria a leitura em
   chamada de função por linha e reintroduziria a regressão que
   `20260929160100_elegiveis_ordem_de_filtro.sql` mediu e corrigiu (p95 de 17,8 ms contra
   48,0 a 85,8 ms antes). [DEDUZIDO: o raciocínio é o mesmo que aquela migração registra
   para `privado.bloqueado_com_estabelecimento`; não refiz a medição de carga]
5. **O ajuste tem caminho de operação.** `scripts/ajustar-parametro-despacho.sh` lê e
   grava o parâmetro com confirmação, para o ajuste não exigir que alguém monte um
   `update` à mão em produção.

## Como medir, quando o piloto existir

As três perguntas do cartão, na ordem em que respondem:

**1. Sobram notificações? (candidaturas por notificação)**

```sql
select dia, notificacoes_enviadas, candidaturas,
       round(candidaturas::numeric / nullif(notificacoes_enviadas, 0), 3) as por_notificacao
  from metrica.funil_por_dia
 order by dia desc
 limit 28;
```

**2. Faltam candidatos? (vaga publicada sem nenhuma candidatura)**

```sql
select count(*) filter (where candidaturas = 0) as vagas_sem_candidato,
       count(*)                                  as vagas,
       round(100.0 * count(*) filter (where candidaturas = 0) / nullif(count(*), 0), 1) as pct
  from metrica.funil_por_vaga
 where dia >= current_date - 28;
```

**3. O raio está sobrando ou faltando? (distância de quem confirmou)**

Não há view: a consulta é sobre `public.posicao` e o ponto do profissional.

```sql
select percentile_disc(0.50) within group (order by d) as p50_metros,
       percentile_disc(0.90) within group (order by d) as p90_metros,
       percentile_disc(0.99) within group (order by d) as p99_metros,
       max(d)                                          as max_metros
  from (
    select extensions.ST_Distance(pr.ponto_base::extensions.geography,
                                  v.ponto::extensions.geography) as d
      from public.posicao po
      join public.vaga v          on v.id = po.vaga_id
      join public.profissional pr on pr.id = po.profissional_id
     where po.estado in ('confirmada', 'cumprida')
       and po.inicio_em >= privado.agora() - interval '28 days'
  ) q;
```

### Os gatilhos de mudança

Para a próxima pessoa não precisar reinterpretar os números:

| Sinal no piloto | Leitura | Ajuste candidato |
|---|---|---|
| `p99` da distância dos confirmados bem abaixo de 15 km (ex.: < 9 km) e vagas sem candidato perto de 0 | O raio notifica gente que nunca aceita | Reduzir `raio_maximo_metros` para perto do `p99` observado |
| Vagas sem candidato acima de ~15% com `p99` colado em 15 km | O raio está cortando quem aceitaria | Aumentar `raio_maximo_metros` |
| Candidaturas por notificação caindo com volume de notificação subindo | Ruído: avisa demais, converte menos | Aumentar `teto_janela` (menos avisos, mais agrupamento) |
| Vaga de urgência chegando com o turno já começado | A antecedência de 2 h é curta para o tempo real de deslocamento | Aumentar `urgente_antecedencia` |

Nenhum destes gatilhos foi observado: não há piloto. São os limiares acordados **antes** do
dado chegar, que é quando a régua ainda é honesta.

## Consequências

- **RN05 e RN23 no Requisitos não mudam agora**, porque nenhum valor mudou. O terceiro
  critério do cartão ("Requisitos atualizado se houver mudança") fica sem efeito até o
  ajuste real. Quando o valor mudar, o Requisitos muda **antes** do `update`: o documento
  ganha do código.
- Quem alterar `raio_maximo_metros` muda o conjunto de elegíveis da próxima rodada de
  despacho, não das notificações já enviadas. Não há reprocessamento.
- `privado.parametro_despacho` não é exposta a `anon` nem a `authenticated`, como a irmã:
  parâmetro de operação não é dado de API.
- O valor é `integer` em metros, não quilômetro fracionado: `ST_DWithin` sobre `geography`
  recebe metro, e converter na borda é onde erro de unidade nasce.

## Referências

- `supabase/migrations/20260928210000_teto_e_agrupamento_rn23.sql` — a estrutura que esta
  decisão copia (cartão `ee3MT3fH`)
- `supabase/migrations/20260929160100_elegiveis_ordem_de_filtro.sql` — a ordem dos filtros
  e a medição de p95 que o ponto 4 preserva
- `supabase/migrations/20260930150000_views_funil_piloto.sql` — as views do painel
- Documento de Requisitos v1.3.0, RN05 e RN23
