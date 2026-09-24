# Estado do backend — 24/09/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

O ciclo chega até a publicação da vaga: conta, estabelecimento, painel, perfil
profissional e `publicar_vaga` estão no `main`, com o despacho enfileirado esperando o
motor do Sprint 2.

**Os nove PRs que estavam parados foram mergeados em 24/09**, e com eles o Sprint 0 de
Backend fechou do lado de cá. Restou **um PR aberto**: o [#16](https://github.com/FrilaApp/frila-backend/pull/16),
do `publicar_vaga`.

**A CI voltou a rodar.** O `toomanyrequests` do `ghcr.io` que travou 23/09 passou; todos
os merges de hoje saíram com a suíte, a mutação e o lint verdes.

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · 21 migrações no `main` |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` |
| `frila-prod` | não existe. Sprint 3 |

**O `frila-dev` ficou para trás.** Ele tem as migrações até o branch `s0/criar-conta`,
aplicadas por `scripts/aplicar-remoto.sh` em 22/09; tudo o que entrou depois — filtro de
texto, perfil profissional, estabelecimento, painel e `publicar_vaga` — está só no
`main` e no ambiente local. Antes de aplicar lá, conferir
`supabase_migrations.schema_migrations` do projeto.

As credenciais estão no `.env` local (fora do git).

## O quadro

| Cartão | Estado |
|---|---|
| `JuD3ytg1` Migrações iniciais | **Concluído** · PR #1 |
| `v7b5sLYv` Políticas de acesso (RLS) | **Concluído** · PR #2 |
| `MPFZagWG` Entrada por código e `criar_conta` | **Concluído** · PR #3 |
| `Cc2XYCi0` Dados de teste e cenários | **Concluído** · PR #4 |
| `oUwDEP8Q` Contrato (saiu como 0.2.2 a 0.2.4) | **Concluído** · PR #7 e frila-docs #2, #3, #4 |
| `jSOAe6OL` Perfil profissional (S1) | **Concluído** · PR #9 |
| `4qwQF0w6` `cadastrar_estabelecimento` e painel (S1) | **Concluído** · PR #11 e #13 · do João Paulo |
| `ggEzge6h` Filtro de texto ofensivo | **Revisão** · código no `main` · *falta a revisão da Júlia na lista de termos* |
| `wtITHAPo` `publicar_vaga` (S1) | **Revisão** · PR #16 e frila-docs#5 |
| `CvopSHh6` Versão mínima do app | com o Cauê. `configuracao_do_app` está no contrato |
| `zdCpLEVs` `avaliar` e `perfil_publico` (S1) | em andamento com o João Paulo |

`./scripts/trello.sh` faz tudo: `ver`, `lista`, `pegar`, `revisao`, `concluir`, `comentar`.

## O contrato mudou de endereço

`FrilaApp/frila-docs` reorganizou o repositório por assunto: **`Documentos/API/openapi.yaml`
virou `api/openapi.yaml`**. O redirect do GitHub cobre o nome antigo da organização, mas
não cobre caminho dentro do repositório — quem tiver script ou marcador apontando para o
caminho antigo precisa ajustar. No backend, o PR #15 ajustou.

Versão vigente: **0.2.5**, espelhada em `contrato/openapi.yaml` e conferida pelo portão.

## O que existe no banco

19 tabelas em `public`, 30 restrições `CHECK`, 1 de exclusão (RN21), 19 políticas de
leitura, 26 auxiliares no schema `privado`, e nenhuma política de escrita em lugar
nenhum — toda escrita passa por função `security definer`.

RPCs prontas: `criar_conta`, `minha_conta`, `criar_perfil_profissional`,
`meu_perfil_profissional`, `atualizar_perfil_profissional`, `cadastrar_estabelecimento`,
`painel_estabelecimento`, `publicar_vaga`. Faltam do ciclo: `candidatar`, `vagas_abertas`,
`detalhe_vaga`, `meus_turnos`, `contato_do_turno`, check-in, check-out, `avaliar` e os
dois cancelamentos.

`privado` tem duas tabelas: `ambiente` (o marcador de teste do relógio) e
`termo_bloqueado` (a lista do filtro da diretriz 1.2, sem política de leitura por
decisão — publicar a lista é publicar o mapa de como contorná-la).

**A fila existe.** `pgmq` entrou com o `publicar_vaga`, e `pgmq.q_despacho` é onde a
publicação deixa `{vaga_id, publicada_em}`. RLS ligada e **sem política**: o event
trigger `ensure_rls` só alcança `public`, então ela foi ligada à mão na migração. `pg_cron`
e `pg_net` continuam fora — agendador sem job e chamada HTTP sem destino são superfície
sem uso, e `pg_net` numa transação de escrita falha em silêncio.

Depois do `db reset` o banco **não nasce vazio**: `cenarios.sql` põe 12 profissionais, 4
contratantes, 3 estabelecimentos, 7 vagas, 7 turnos, 6 avaliações, 1 bloqueio e 2
ocorrências. O mapa está em [`supabase/README.md`](../supabase/README.md).

**O molde das RPCs de escrita está fixado**, e vale copiar: `auth.uid()` na primeira
linha, `privado.exigir_perfil` na segunda — a recusa de perfil vem antes de qualquer
escrita —, a conferência de conta suspensa em seguida, validação devolvendo o código do
contrato com o campo em `details`, e a resposta moldada por uma função `…_em_json`
separada.

**`privado.agora()` é o relógio do produto.** Todo prazo passa por ele. Nenhuma RPC nova
deve usar `now()` direto.

## Os portões

Medidos na máquina em 24/09, no branch do `publicar_vaga`, com `db reset` antes:

| Comando | O que garante | Medida |
|---|---|---|
| `supabase test db` | pgTAP | **391** asserções em 16 arquivos |
| `./scripts/mutacao.sh` | cada regra morre sem teste | **74** cobertas, 0 sem cobertura |
| `./scripts/ciclo-completo.sh` | o fluxo por HTTP, com status **e** código | até a publicação da vaga |
| `./scripts/contrato-acompanha-o-codigo.sh` | PR que mexe em `public` leva o contrato | 0.2.4 → 0.2.5 |
| `./scripts/contrato-em-dia.sh` | o espelho não divergiu do original | espelho 0.2.5 idêntico |
| `./scripts/lint-conhecido.sh` | `plpgsql_check` | sem achado novo |
| `./scripts/advisor-conhecido.sh` | advisor do Supabase | **não roda**: token vencido |
| `./scripts/migracoes-imutaveis.sh` | nenhuma migração aplicada foi editada | verde |

Todos rodam na CI menos o advisor, que exige token de conta.

**A regra que vale para qualquer portão novo:** um caminho que não seja *"medi e o
resultado foi X"* tem que sair diferente de zero.

## O que foi aprendido, e custa caro reaprender

- **O banco não nasce vazio, e dois cartões podem escolher o mesmo dado.** Os cenários
  (PR #4) e o teste do estabelecimento (PR #11) escolheram o mesmo CPF válido. Cada um
  passava sozinho; juntos no `main`, o cadastro recebia 409 e o arquivo terminava com 20
  dos 27 testes planejados. Teste novo conta com os cenários — e conta **por id do
  cenário**, nunca pela tabela inteira.
- **A CI roda a suíte duas vezes, e a segunda é depois dos scripts HTTP.**
  `ciclo-completo.sh` e `corrida-cadastrar-estabelecimento.sh` gravam de verdade, sem
  rollback. Uma contagem absoluta sobre a tabela inteira passa na primeira execução e
  falha na segunda — e quem paga é o `mutacao.sh`, que exige linha de base verde e se
  recusa a rodar.
- **Suíte verde não diz o que ela protege.** Duas vezes os testes passaram inteiros sobre
  uma regra ausente: 11 de 31 restrições e 10 de 19 políticas. Quem achou foi a mutação.
- **Derrubar uma política de leitura *fecha* dado.** Cada política precisa das duas
  asserções, positiva e negativa.
- **Teste de banco não substitui chamada HTTP.** O envelope de erro sem a chave `headers`
  fazia o PostgREST devolver 500 em toda recusa. Só o `ciclo-completo.sh` pegou.
- **Uma recusa tem três eixos, e conferir dois não basta.** `sqlstate`, `code` e status.
  Os dois primeiros o pgTAP alcança; o status, só o `ciclo-completo.sh`.
- **Rótulo de volatilidade mentiroso passa despercebido.** Quem pega é o lint, e só com a
  CLI igual à da CI.
- **Mudança feita no painel do Supabase não existe para o próximo ambiente.**
- **Mergear pilha de PRs com `--delete-branch` fecha os filhos.** Aconteceu com o #8 e o
  #10 em 24/09: apagar o branch-base de um PR aberto o fecha, e PR fechado **não** pode
  ser reaberto nem ter a base trocada. O #8 não se perdeu porque o #9 descendia dele; o
  #10 teve de virar o #15. Numa pilha, deletar só o último — ou retargetar os filhos
  para `main` antes.

## Divergências registradas

- **`vaga.publicado_por` não está na Modelagem.** Nasceu com `publicar_vaga`: um
  estabelecimento tem vários membros e RF04 pergunta quem publicou. Quem precisa
  reconciliar é o documento.
- **`net.http_post` não entrou no `publicar_vaga`**, como o cartão `wtITHAPo` pedia. A
  Edge Function `despachar` é do Sprint 2 e não existe; a fila é durável e o motor
  consome o que estiver enfileirado. Comentado no cartão.
- **O modo seleção é recusado na v1.0** com `campo_invalido` e `details: modo`, e não com
  `selecao_sem_antecedencia` — este é a regra das 24 h e volta na v1.1. O contrato 0.2.5
  passou a dizer isso por escrito.
- **`turno.checkout_distancia_m` sem o teto de 200 m** que a Modelagem traz. Vai à
  decisão no cartão `S0 · Produto · Decisões de produto que travam o código`, prazo 02/10.
- **`vaga.posicoes` com teto de 200**, que vem do contrato e não da Modelagem.
- **`privado.bloqueado_com_estabelecimento` faltava `m.usuario_id <> conta`.** Corrigido
  aqui; a Modelagem tem a mesma expressão errada.
- **`usuario` ganhou `termos_versao` e `termos_aceite_em`**, que não estão na Modelagem.

## Pendências fora do código

1. **`supabase login`.** O `SUPABASE_ACCESS_TOKEN` do `.env` responde **401** na
   Management API. Sem ele o advisor de segurança do `frila-dev` não é verificado por
   ninguém. Depende de alguém presente: o comando abre o navegador.
2. **PAT com leitura em `FrilaApp/frila-docs`**, gravado como secret `FRILA_DOCS_TOKEN`.
   Na máquina o portão do contrato compara com o original de verdade (medido em 24/09);
   na CI, sem o secret, ele confere só a integridade do espelho e avisa em voz alta.
   Fine-grained, *Resource owner* `FrilaApp`, *Contents: Read-only*.
3. **`git push` no `FrilaApp/Bancada`**, que exige Touch ID. Sem ele as notas diárias não
   saem e o site `bancada-buu.pages.dev` não republica.
4. **Revisão da Júlia** na lista de termos bloqueados. Sem ela o `ggEzge6h` não fecha.
5. **Aplicar as migrações novas no `frila-dev`**, que está seis migrações atrás.
6. **Decidir as operações do contrato sem cartão no quadro** — `renovarSessao`,
   `criteriosDeNotificacao`, `pedirRevisaoDespacho`, `equipeDeConfianca`,
   `incluirNaEquipe`, `removerDaEquipe`, `listarFuncoes`, `candidatosDaVaga`,
   `escolherCandidato`, `exportarTurnos`. Contrato a mais ou cartão faltando.
7. **Avisar o Cauê** que o projeto Supabase que ele criou em 22/09 virou o `frila-dev`, e
   que a mensagem da fila de despacho traz `vaga_id` e `publicada_em` — é o que o motor
   do Sprint 2 vai consumir.

## Por onde continuar

1. **Revisar e mergear o PR #16** (`publicar_vaga`). É o único aberto.
2. `H6OOKVqK` — `vagas_abertas` e `detalhe_vaga`. Agora que existe vaga publicada, é a
   leitura que dá o que mostrar ao profissional, e ela precede o `candidatar`.
3. `6ITEQC9v` — `candidatar`. É o cartão onde o produto quebra se errar: `UPDATE`
   condicional com `FOR UPDATE SKIP LOCKED`, e teste de corrida com **pgbench**, porque o
   pgTAP roda numa sessão só e não testa concorrência. O molde da corrida já existe em
   `scripts/corrida-cadastrar-estabelecimento.sh`.
4. Toda RPC nova do Sprint 1 nasce com quatro coisas, e nenhuma é negociável: o filtro de
   texto nos campos livres, a recusa correspondente no `ciclo-completo.sh`, a linha no
   `openapi.yaml` com a versão subindo, e a asserção de mutação que morre quando a regra
   some. O portão do contrato cobra a terceira; as outras três dependem de quem escreve.
