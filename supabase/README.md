# O banco do Frila, no local

Como subir, o que aparece dentro depois do `db reset`, e para que serve cada cenário.

```bash
supabase start      # sobe Postgres 17, PostgREST, Auth e a caixa de e-mail
supabase db reset   # aplica as migrações, o catálogo e os cenários
supabase test db    # 232 asserções pgTAP
```

| | |
|---|---|
| Banco | `postgresql://postgres:postgres@127.0.0.1:54322/postgres` |
| API | http://127.0.0.1:54321 |
| Studio | http://127.0.0.1:54323 |
| Caixa de e-mail | http://127.0.0.1:54324 |

---

## Os dois arquivos de semente, e por que são dois

| Arquivo | Conteúdo | Vai para o remoto? |
|---|---|---|
| `seed.sql` | O catálogo de 32 funções | **Sim.** `scripts/aplicar-remoto.sh` o aplica |
| `cenarios.sql` | Contas, casas, vagas e turnos de teste | **Não.** Só `db reset`, no local e na CI |

O catálogo de funções é dado de produto: sem ele não há o que escolher na publicação, e
ele precisa existir em todo ambiente. Dado de teste não — um estabelecimento fantasma
no `frila-dev` é dívida que alguém descobre no pior momento.

Os dois entram no `db reset` por `config.toml → db.seed.sql_paths`. Só o primeiro é
lido por `aplicar-remoto.sh`.

**Nada aqui grava `privado.ambiente`.** É a linha que torna `privado.agora()`
sobreponível, e com ela todo prazo do produto vira decoração: os 7 dias do contato
(RN10), as 24 h do modo seleção (RN24), o fim previsto que libera a avaliação (RN07).
Quem a escreve é o teste, dentro da transação, e o `rollback` a leva junto.
`tests/090_cenarios.sql` confere que ela continua fora.

---

## Como entrar com uma conta de teste

Não há senha. O fluxo é o mesmo do aplicativo: pedir o código e lê-lo na caixa local.

```bash
curl -s -X POST 'http://127.0.0.1:54321/auth/v1/otp' \
  -H "apikey: $(supabase status -o env | sed -n 's/^ANON_KEY="\(.*\)"$/\1/p')" \
  -H 'Content-Type: application/json' \
  -d '{"email":"ana@frila.test"}'
```

O código de 6 dígitos chega em http://127.0.0.1:54324. Troque-o por sessão em
`POST /auth/v1/verify` com `{"email":…,"token":…,"type":"email"}`.

`scripts/ciclo-completo.sh` faz esse caminho inteiro por HTTP, com uma conta nova a
cada execução.

---

## As contas

Doze profissionais e quatro contratantes. Todos com credencial em `auth.users` e conta
em `public.usuario`: sem a primeira ninguém entra, sem a segunda o app manda para o
cadastro quem já se cadastrou.

### Profissionais

Os sete primeiros existem por causa da RN05, medida contra a **vaga de referência**
(`d…01`, garçom no Bar do Cerrado, próxima sexta 18:00–02:00). Cada um é barrado por
exatamente um critério — quem reprova em dois não documenta critério nenhum.

| E-mail | Nome | Onde mora | Na vaga de referência | Para que serve |
|---|---|---|---|---|
| `ana@frila.test` | Ana Ribeiro | Asa Norte | **elegível** | O controle positivo: passa nos seis critérios. Tem histórico (1 turno, 1 avaliação positiva) |
| `bruno@frila.test` | Bruno Sales | Asa Norte | barrado por **função** | Chapeiro e limpeza; nunca foi garçom |
| `carla@frila.test` | Carla Nunes | Asa Norte | barrado por **horário** | Tem a função. A grade é segunda de manhã e sábado cedo |
| `diego@frila.test` | Diego Matos | Águas Claras | barrado por **distância** | 17,4 km do bar. Medido, não estimado |
| `elisa@frila.test` | Elisa Prado | Asa Norte | barrado por **conta suspensa** | RN13: continua lendo o próprio histórico |
| `felipe@frila.test` | Felipe Rocha | Asa Norte | barrado por **bloqueio** | RF26: some da casa inteira, não só da Zélia |
| `gabi@frila.test` | Gabi Teles | Asa Norte | barrado por **turno sobreposto** | RN21: já confirmada na `d…06`, mesma janela |
| `heitor@frila.test` | Heitor Lima | Lago Sul | elegível | 8,6 km: o Lago Sul alcança a Asa Norte, Águas Claras não. Histórico com **avaliação negativa** |
| `iara@frila.test` | Iara Souza | Águas Claras | **elegível** | RF18: 16,9 km e passa assim mesmo, por ser da equipe de confiança do bar. É a única diferença entre ela e o Diego |
| `joao@frila.test` | João Vitor Sá | Asa Norte | barrado por função | Limpeza e carregador. Cumpriu turno com check-in geolocalizado |
| `karen@frila.test` | Karen Dias | Asa Norte | elegível | **Sem histórico**: `taxa_comparecimento` nula, e não 0.000 (RF16). Grade única de 12:00 a 02:00 |
| `leo@frila.test` | Léo Franco | Asa Norte | elegível | **Faltou** ao único turno que tinha: taxa 0.000. Faltar não torna ninguém inelegível |

### Contratantes

| E-mail | Nome | Casa | Papel |
|---|---|---|---|
| `zelia@frila.test` | Zélia Martins | Bar do Cerrado | administradora |
| `paulo@frila.test` | Paulo Freitas | Bar do Cerrado | **operador** — é com ele que se testa o papel sem poder de administração |
| `ricardo@frila.test` | Ricardo Aguiar | Buffet Águas Claras | administrador |
| `marta@frila.test` | Marta Bezerra | Empório Lago Sul | administradora |

---

## As casas

Três regiões escolhidas pela distância entre elas: Asa Norte e Lago Sul se alcançam
dentro dos 15 km da RN05, Águas Claras não alcança nenhuma das duas.

| Casa | Tipo | Documento | Região |
|---|---|---|---|
| Bar do Cerrado | `food_service` | CNPJ | Asa Norte |
| Buffet Águas Claras | `evento` | CNPJ | Águas Claras |
| Empório Lago Sul | `varejo` | **CPF** | Lago Sul |

O CPF é deliberado: serviço doméstico e MEI também contratam pelo Frila, e um cenário
só com CNPJ deixaria esse caminho sem cobertura.

---

## As vagas

Os horários pendem da **próxima sexta-feira às 18:00** em São Paulo, sempre entre 7 e
13 dias no futuro. É por dia da semana, e não por `now() + N dias`, porque a grade de
disponibilidade é semanal: com data relativa, o dia da semana da vaga mudaria conforme
o dia do `db reset` e metade dos cenários de elegibilidade viraria outra coisa às
segundas-feiras.

| Id | Estado | Casa | Função | Quando | Para que serve |
|---|---|---|---|---|---|
| `d…01` | publicada | Bar | garçom | sexta 18:00–02:00 | **A vaga de referência da RN05.** Duas posições abertas, três candidaturas pendentes |
| `d…02` | preenchida | Bar | bartender | sábado 18:00–02:00 | Posição confirmada com turno ainda não começado |
| `d…03` | encerrada | Buffet | limpeza pós-evento | sábado passado 06:00–14:00 | Os quatro desfechos do check-in, mais a falta. Cinco posições |
| `d…04` | cancelada | Empório | repositor de gôndola | domingo 10:00–16:00 | A casa cancelou antes de confirmar ninguém. Tem ocorrência com o motivo |
| `d…05` | publicada | Empório | vendedor extra | sexta seguinte 14:00–20:00 | **Modo seleção** (RN24): publicada com mais de 24 h de antecedência |
| `d…06` | preenchida | Buffet | garçom | sexta 18:00–02:00 | Cruza com a `d…01`. É o que torna a Gabi inelegível |
| `d…07` | encerrada | Bar | garçom | sexta passada 18:00–02:00 | O histórico da Ana e do bar: turno cumprido e avaliado dos dois lados |

As duas vagas do passado descontam **14** dias da âncora, não 7 — a âncora já está no
futuro, e `- 7 dias` cairia no futuro em metade das execuções. O trigger de RN07
recusaria as avaliações com `avaliacao_indisponivel / antes_do_fim`, que foi como isso
apareceu na primeira vez.

---

## Os turnos: os três desfechos de RN22

| Turno | Check-in | Verificação | Para que serve |
|---|---|---|---|
| Ana na `d…07` | geolocalizado, 45 m | `verificado` | O caminho feliz. Guarda a **distância**, nunca a coordenada |
| João na `d…03` | geolocalizado, 80 m | `verificado` | Check-out a 120 m: sai do local e encerra assim mesmo |
| Heitor na `d…03` | manual, confirmado pelo contratante | `verificado` | Sem GPS, com prova |
| Carla na `d…03` | manual, sem confirmação | `pendente` | O contratante não respondeu. Não vira presença por decurso de prazo |
| Bruno na `d…03` | nenhum | `nao_verificado` | **O turno que aconteceu e não tem prova.** É o que costuma faltar num cenário montado às pressas |
| Léo na `d…03` | — | — | Posição cancelada com `falta = true`. Sem turno |
| Ana na `d…02` e Gabi na `d…06` | — | `pendente` | Confirmados, ainda não começaram |

Avaliação só existe sobre turno verificado e depois do fim previsto — é o trigger
`avaliacao_rn07` que cobra, e o arquivo de cenários não tenta contorná-lo. São seis, e
**uma é negativa**: um cenário em que todo mundo responde "sim" não exercita a tela que
mostra o denominador, que é onde a RN08 vive.

---

## O que é medido e o que está escrito à mão

As contagens de comparecimento — `taxa_comparecimento`, `turnos_realizados` — estão
**escritas à mão** no arquivo, coerentes com os turnos. Quem as recalcula no produto é
`privado.recalcular_comparecimento`, chamada pelo check-in e pelo cancelamento; o
cenário escreve direto na tabela e não passa por ela. A aritmética usada é
`cumpridas / (cumpridas + faltas)`.

**Mexer num turno aqui obriga a mexer no número correspondente.**
`tests/090_cenarios.sql` cobre a forma do cenário, não essa aritmética.

`aval_positivas` e `aval_total` **não** são escritas à mão: o gatilho
`avaliacao_soma_na_reputacao` soma cada avaliação inserida. Escrevê-las aqui contaria
cada avaliação duas vezes, e `tests/180_avaliar_e_perfil_publico.sql` confere a
coerência dos contadores com as avaliações do banco inteiro.

## Uma lacuna do modelo, encontrada ao montar isto

A suspensão da Elisa **não tem ocorrência**, e não é esquecimento:
`ocorrencia.autor_id` é `not null` e referencia `usuario`, e não existe conta de
plataforma para assinar uma suspensão decidida pela Equipe Frila. Ou o modelo ganha
essa conta, ou `autor_id` passa a aceitar nulo para os tipos decididos pela plataforma.
Está comentado no cartão `Cc2XYCi0`.

---

## Se você mexer aqui

`tests/090_cenarios.sql` mede este arquivo e falha alto quando ele deixa de bater.
Rode `supabase db reset && supabase test db` antes de abrir o PR.

Os outros dez arquivos de teste criam os próprios dados e os desfazem no fim, mas
compartilham o banco com o cenário: consulta sem filtro em `public.turno` ou
`public.vaga` não significa mais "o que este teste criou". Três asserções já precisaram
de escopo por causa disso.
