# Estado do backend — 03/10/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

**A `develop` é o tronco e está 302 commits à frente do `main`, que não se move desde
28/09.** O `main` continua inteiramente contido na `develop` (`git log
origin/develop..origin/main` sai vazio) e parado em `c190836`. A `develop` possui **92 migrações**
e **82 arquivos de pgTAP** (com **2351 asserções** verdes).

Os números abaixo foram remedidos em 03/10, com a `develop` em `4f1a6c5` — conferidos
diretamente com a execução das ferramentas do repositório.

| | | Comando |
|---|---|---|
| Commits à frente do `main` | **302** | `git rev-list --count origin/main..origin/develop` |
| Migrações na `develop` | **92** | `git ls-tree -r --name-only origin/develop -- supabase/migrations \| grep -c '\.sql$'` |
| pgTAP | **82 arquivos, 2351 asserções**, verde | `Files=82, Tests=2351 … Result: PASS`, medido com `supabase test db` |
| Testes em Deno das Edge Functions | **171**, verde | `ok \| 171 passed \| 0 failed`, medido com `deno test --allow-all --no-check` |
| Edge Functions | **9** | `git ls-tree -d --name-only origin/develop:supabase/functions \| wc -l` |
| Scripts em `scripts/` | **32** arquivos `.sh` | `git ls-tree -r --name-only origin/develop -- scripts \| grep -c '\.sh$'` — 34 entradas no total, incluindo um `.py` e um `.sql` |
| Contrato espelhado | **0.2.33** | `sed -n 's/^  version: *//p' contrato/openapi.yaml` |

Um aviso sobre a contagem de pgTAP, porque ela já apareceu de três jeitos neste documento:
`supabase/tests/*.sql` tem **81** arquivos, e o `prove` conta **82** porque alcança também
`supabase/tests/carga/gerar_df.sql`, que é gerador de carga e não teste de regra. O número
da CI, e o da tabela, é 82.

> ## 🟢 O espelho do contrato está em dia (0.2.33) e alinhado ao original
>
> A divergência que travava o job "Contrato em dia com o Frila" na CI foi **completamente superada**.
> O contrato **0.2.33** foi publicado e mergeado na `main` do `FrilaApp/frila-docs` (`d398310`),
> incorporando a leitura de `meu_estabelecimento` (0.2.29), `vinculo_id` no push (0.2.30),
> dados de turno no painel (0.2.31), cancelamento no turno e `turno_id` na candidatura (0.2.32) e as
> sete coleções de `MeusDados` (0.2.33).
>
> A `develop` recebeu o espelho idêntico (`ba3665c0e23b4fbecab8ccea38c3221a10e7fe50baa5b8b956ecd4a28edba466`)
> e todas as implementações e portões correspondentes (#99, #100, #125, #129, #130, #131, #135 e #136).
> O portão `./scripts/contrato-em-dia.sh` passa 100% verde com `FRILA_DOCS_TOKEN`.
>
> | | Versão | sha256 | bytes |
> |---|---|---|---|
> | espelho, `contrato/openapi.yaml` na `develop` | **0.2.33** | `ba3665c0e23b4fbecab8ccea38c3221a10e7fe50baa5b8b956ecd4a28edba466` | 212 438 |
> | original, `FrilaApp/frila-docs · api/openapi.yaml` | **0.2.33** | `ba3665c0e23b4fbecab8ccea38c3221a10e7fe50baa5b8b956ecd4a28edba466` | 212 438 |

> ## 🟢 Instabilidades de concorrência em `Corridas do ciclo` sanadas na raiz
>
> As falhas registradas na CI em rodadas de concorrência foram investigadas e resolvidas:
>
> 1. **Cenário 9 (`excluir_conta` x `candidatar` deadlock `40P01`):** Resolvido no PR **#101**
>    (cartão `CPD2c74A`, merge em 03/10). A causa era inversão de ordem de travas trancando o
>    usuário antes da vaga; a correção tranca a vaga antes do usuário, zerando os impasses (0 de 50).
> 2. **Cenário 3 (agendador do teto e despachos concorrentes):** Resolvido no PR **#134**
>    (`test(corrida): robustece temporização e transações do cenário 3 do teto`, merge em 03/10).
>    Ampliadas as margens de temporização para absorver o jitter de vCPU nos runners do GitHub Actions
>    e isoladas as transações do agendador por profissional livre.
> 3. **Bloqueio em `perfil_publico` (cartão `1aGJPQK2`):** Implementado no PR **#104** com
>    a migração `20261001140000_perfil_publico_bloqueio.sql` e teste `550_perfil_publico_bloqueio.sql`. A premissa de que a
>    `develop` estava vermelha por essa pendência está totalmente superada.

**Quatro portões nasceram entre 30/09 e 03/10, e pegam coisas que antes passavam caladas:**
o plano do caminho quente com o volume do DF (#67), os testes em Deno das Edge Functions (#78),
o corpo das Edge Functions contra o contrato (#100) e a verificação de superfície sem quebra de contrato (#136).
Estão descritos em *Os portões*.

## Onde cada coisa parou

### O que entrou desde 30/09: cinquenta e seis PRs

Contados, não lembrados: `gh pr list --state merged` filtrado por `mergedAt >= 2026-09-30`
devolve **56** em 03/10. Eram 22 em 01/10 e 44 em 02/10. Em quatro grupos:

**Produto e backend do Sprint 2 e 3** — #70 (fila `email` com consumidor), #77 (exportar
meus dados), #79 (aviso de fim sem check-out), #80 (rastro do pedido de exclusão), #82
(modo seleção), #83 (exportar turnos em CSV e PDF), #84 (views do funil e `funil.sh`), #85
(`avisar_a_caminho`), #91 (moderação do texto denunciado), #93 (telemetria,
`registrar_evento`), #94 (monitoramento e alertas), #95 (suspensão, `situacao_da_conta` e
`contestar_suspensao`), #104 (o bloqueio esconde o perfil público com o teste 550), #125 (`meu_estabelecimento` para membro da casa, contrato 0.2.29), #129 (`vinculo_id` do dispositivo no push, contrato 0.2.30), #130 (cancelamento no turno e `turno_id` na candidatura, contrato 0.2.32), #131 (turno cancelado, avaliação dada e cancelamento no painel, contrato 0.2.31), #99 (`privado.meus_dados` com as sete coleções) e #135 (alinhamento de `privado.meus_dados` com o schema do contrato 0.2.33).

**Portões, estabilidade e concorrência** — #67 (plano do caminho quente com carga), #78 (Deno na CI), #86
(privilégios em `privado` e confirmação em posição cancelada), #87 (auditoria dos códigos
prometidos pelo contrato), #90 (classifica `pedido_de_exclusao` no catálogo), #96, #97 e
#98 (caminhos de recusa das RPCs), #100 (corpo das Edge Functions vigiado no `contrato-responde`), #101 (inversão de travas do `40P01` em `excluir_conta` corrigida), #105 (medição contrato-à-frente), #116 (regra de base develop no README e CI), #132 (reconciliação do teste 250 independente do relógio real), #133 (uso de `privado.agora()` em `cancelamento_da_posicao`), #134 (robustecimento de temporização e isolamento do cenário 3 de corridas do teto), e #136 (marcação de corpo sem mudança de superfície no portão de contrato).

**Espelho do contrato** — #88 (0.2.26), #92 (0.2.27) e #103 (0.2.28). O contrato 0.2.33 está espelhado e em dia com o `frila-docs` na raiz de `develop`.

**Segurança, infra e backup** — #117 (índice cobrindo a FK de `despacho_notificacao`), #118 e #121 (hardening e revogação de privilégios de authenticated em public), #119 (ensaio de restauração local) e #120 (workflow agendado do ensaio).

### A fila de PRs aberta em 03/10, e o que cada um espera

Medida com `gh pr list --state open` em 03/10, campo `mergeable` do próprio GitHub. Todos
têm `develop` como base.

| PR | Estado | O que falta, e de quem é |
|---|---|---|
| **#138** | aberto, sem conflito | `fix(suspensao)`: permite reenvio de contestação após resolução da anterior (cartão `pVvubZJy`). Aberto para revisão |
| **#137** | aberto, sem conflito | `feat(contato)`: fecha `contato_do_turno` contra conta anonimizada (B10, cartão `kT7NhMGV`). Aberto pela Brasa Quente, aguarda revisão da Faísca |
| **#128** | aberto, sem conflito | `feat(mutacao)`: varre restrições de unicidade e índices únicos (`1DLcZWsf`). Aberto por Matheus Silva (`silvaaszx`) |
| **#127** | aberto, **conflitando** | `chore(contrato)`: espelha contrato 0.2.32 do frila-docs. Obsoleto e conflitante, pois a `develop` já avançou para a 0.2.33 |
| **#102** | aberto, sem conflito | Este documento (`docs/ESTADO.md`), atualizado com as medições reais de 03/10 após merge da `develop` |
| **#89** | aberto, sem conflito | Entrega contínua: `develop` no `frila-dev`, tag no `frila-prod`. Depende de credencial de conta |
| **#81** | aberto, sem conflito | Registra o SMTP próprio do `frila-dev`. Já aponta para `develop` |

> **Histórico do #100, #101 e #99:** Os três foram mergeados na `develop` em 03/10. O #100 passou a vigiar o corpo das Edge Functions contra o contrato; o #101 extinguiu o deadlock `40P01` entre `excluir_conta` e `candidatar`; e o #99 trouxe as sete coleções para `privado.meus_dados`, com o #135 alinhando os campos ao contrato 0.2.33.


### Histórico dos primeiros PRs da develop (28 e 29/09)

Na `main`, antes da regra de base: **#37** (portão de colisão de versão, `RNOfNVVU`, Matheus, 28/09
às 16h15) e **#48** (falta por no-show depois do fim do turno, `NDx7TJ4d`/`8zLfn0mt`, 28/09
às 17h14). As 47 migrações da `main` são as 46 de 28/09 mais `20260928160000_fechar_turnos_noshow`.

Para registro histórico do início da `develop`, estes foram os primeiros 11 PRs integrados na criação do tronco (todos concluídos, testados e com seus cartões fechados):

| PR | Cartão | O que trouxe | Migração | Estado atual |
|---|---|---|---|---|
| **#51** | `vUR0Ltkb` | alerta de vaga vazia na janela crítica | `20260928200000_alerta_vaga_vazia` | Concluído / mergeado |
| **#31** | `CvopSHh6` | `configuracao_do_app`: a versão mínima do app | `20260928193700_configuracao_do_app` | Concluído / mergeado |
| **#34** | `nNUtbriv` | `bancada-sync` pela data do autor | — | Concluído / mergeado |
| **#49** | `e8XpOZJN` | alerta de atraso aos 15 min e `reabrir_por_atraso`; candidatura na reaberta (0.2.19) | `20260928220000_alerta_de_atraso_e_reabrir_por_atraso` | Concluído / mergeado |
| **#53** | `IoQPWtWs` | `enviar-push` fala com o Postgres direto para chamar `privado.*` | — | Concluído / mergeado |
| **#50** | `k5R4tzjC` | lembretes 24 h e 3 h antes do turno | `20260928180000_lembretes_24h_e_3h` | Concluído / mergeado |
| **#54** | `x0jkygj0` | `regiao_administrativa` em estabelecimento e vaga, e interpolada nos pushes (0.2.20) | `20260928230000_regiao_administrativa` | Concluído / mergeado |
| **#52** | `ee3MT3fH` | teto e agrupamento de notificações de vaga (RN23), e `scripts/corrida-teto.sh` | `20260928210000_teto_e_agrupamento_rn23` | Concluído / mergeado |
| **#55** | — | teste Deno da falha fechada sem `AGENDADOR_SECRET` deixa de depender do diretório | — | Concluído / mergeado |
| **#57** | `JWJOPAOL` | RPCs `denunciar` e `bloquear`; o bloqueio filtra o teto e o push | `20260929100000_denunciar_e_bloquear` | Concluído / mergeado |
| **#58** | `9DbPXis7` | rodada de despacho para posição reaberta por atraso | `20260929110000_rodada_de_despacho` | Concluído / mergeado |

Os testes adicionados por esses primeiros PRs levaram a suíte inicial a 45 arquivos. Desde então, com os 56 PRs integrados até 03/10, a suíte expandiu para **82 arquivos de teste** (2351 asserções pgTAP) e **171 testes em Deno**, todos verdes.

Fechados sem merge na ocasião: **#38**, **#39** e **#40** (turnos não verificados, motor de despacho e push FCM), incorporados no resgate #41.

### Pendências no `frila-dev`, cartão a cartão

O `frila-dev` não recebe nada da `develop` sozinho, e o MCP do Supabase desta máquina responde sem permissão para o projeto `jcobftbhbqdikratzizz`. O que foi preparado no código para conferir **depois do deploy**:

| Cartão | O que conferir no `frila-dev` |
|---|---|
| `e8XpOZJN` atraso | o job `alertar_atrasos` (`* * * * *`) existe em `cron.job` e roda sem erro |
| `vUR0Ltkb` vaga vazia | o job `alertar_vagas_vazias` (`*/5 * * * *`) em `cron.job`, e push real |
| `k5R4tzjC` lembretes | o job `enviar_lembretes_turno` (`*/5 * * * *`) em `cron.job` |
| `ee3MT3fH` teto RN23 | o job `liberar_teto` (`* * * * *`) em `cron.job` |
| `JWJOPAOL` denunciar | a fila `pgmq` `email` existe; processamento depende de SMTP configurado |
| `IoQPWtWs` `enviar-push` | `functions deploy enviar-push` com a conexão direta ao Postgres |
| `x0jkygj0` região | `functions deploy enviar-push`, que interpola a região nos pushes 09 e 11 |
| `NDx7TJ4d` no-show | o agendamento `fechar_turnos_e_vagas` (`*/5 * * * *`) |
| `qcVimM84` fim sem checkout | o job `alertar_fim_sem_checkout` (`*/5 * * * *`) |
| `5bPJvMIo` monitoramento | o job `verificar_saude` (`*/5 * * * *`) |

No Postgres local da `develop`, com as 92 migrações aplicadas em 03/10, estão ativos **treze jobs** em `cron.job`.

### Cartões bloqueados, e por quê — revisto em 03/10

Com o avanço dos sprints e as entregas integradas na `develop` até 03/10, diversos cartões anteriormente bloqueados foram concluídos e mergeados no backend:

- **`7yq1flLG` E-mails transacionais (backend)** — entregue e mergeado (#70): a fila `email` tem consumidor, o job `processar_fila_email` roda e os modelos saem de um arquivo só. A entrega final depende de provedor SMTP e domínio próprio (ver PR #81).
- **`qcVimM84` Aviso de hora excedida (backend)** — entregue e mergeado (#79): `privado.alertar_fim_sem_checkout` roda a cada cinco minutos. Falta a tela no iOS.
- **`nUpPFCpM` Exportar meus dados (backend)** — entregue e mergeado (#77, #99, #135). Falta a tela em Meu perfil no iOS.
- **`5bPJvMIo` Monitoramento e alertas** — entregue e mergeado (#94).
- **`kT7NhMGV` Endurecimento para produção** — entregue e mergeado (#86, #117, #118, #121, #122); o B10 (`contato_do_turno` contra conta anonimizada) está no PR #137 em revisão.
- **`BsXIZHOw` Suspensão da conta** — entregue e mergeado (#95); reenvio de contestação tratado no PR #138.
- **`zptkprHt` Índice de elegíveis** — entregue e mergeado (#67).
- **`nspP9YDU` Concorrência além da RN19** — resolvido com a eliminação do impasse `40P01` (#101) e isolamento do agendador do teto (#134).
- **`oCv0WPNY` Portão do corpo das Edge Functions** — entregue e mergeado (#100).

O que **continua dependente de bloqueios externos** (fora do código do backend):

| Cartão | O que trava |
|---|---|
| `7yq1flLG` E-mails transacionais (caixa da Equipe Frila) | **SMTP e provedor de e-mail.** Depende de domínio e provedor SMTP (ver PR #81) para consumo e entrega da fila `email` |
| `qcVimM84` Aviso de hora excedida | **Design / iOS**: a tela no iOS que abre o turno com check-out em destaque |
| `nUpPFCpM` Exportar meus dados | **Design / iOS**: opção e tela no app iOS |
| `3zsjXW60` Telemetria do piloto | **Produto / iOS**: instrumentação e disparo dos eventos definidos em T-0017 no app iOS |
| `RTmRTHbo` Republicar vaga | **iOS**: ação "Publicar de novo" na tela de Minhas vagas |
| `ggEzge6h` Filtro de texto | **Produto**: revisão final da lista de termos pela **Júlia** |
| `7gpPBgTH` Contas de demonstração | **Infra/credencial**: execução remota depende de `SUPABASE_ACCESS_TOKEN` válido |

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · **92** migrações na `develop`, **47** no `main` (contadas em 03/10) |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` · **29** migrações, conferidas em 24/09 — e a `develop` tem 92 |
| `frila-prod` | `hbjkkcenbudiezmamiak` · `sa-east-1` · criado em 24/09, **vazio**: as migrações entram pelo cartão do ambiente de produção (29/10), com a entrega contínua por tag |

> 🔴 **O `frila-dev` está atrás, e não sei quanto.** Ele tinha as mesmas 29 do `main` em
> 24/09; a `develop` chegou a 92 em 03/10 e **nada foi aplicado lá** que alguém tenha
> registrado. Sessenta e três migrações de diferença é a conta pelos arquivos, não uma medição
> do remoto: conferir o `supabase_migrations.schema_migrations` do projeto exige o token de
> conta, que responde 401, e o MCP do Supabase desta máquina responde sem permissão (medido
> em 29/09). `./scripts/aplicar-remoto.sh jcobftbhbqdikratzizz` é o caminho, e ele é
> idempotente — pula o que já está registrado. Antes de aplicar qualquer coisa, conferir a
> tabela de controle, **e aplicar a partir da `develop`**, que é onde as 92 estão.

O parágrafo abaixo descreve como as 29 entraram, e continua valendo como procedimento:

**Em 24/09 o `frila-dev` ficou em dia com o `main`.** As 11 migrações que faltavam, de
`20260923200000_filtro_de_texto_ofensivo` a `20260925020000_cancelamentos`, entraram em
24/09 às 15h pelo MCP do Supabase, porque o token do `.env` não responde. Cada uma rodou
numa transação só, e o md5 do texto foi conferido contra o arquivo **antes** de executar:
texto divergente aborta sem gravar nada. O registro em `supabase_migrations.schema_migrations`
usa a versão e o nome do arquivo, como faz o `scripts/aplicar-remoto.sh`, então o
`db push` da CLI enxerga tudo como aplicado. A diferença para o script é que `statements`
guarda o texto inteiro da migração, e não um array vazio. O `seed.sql` também foi
reaplicado.

Conferido depois: 29 migrações com o md5 igual ao dos arquivos, 19 tabelas com RLS, `anon`
sem escrita e sem `usage` em `privado`, `privado.ambiente` sem marcador de teste, 32
funções e 33 termos, `pgmq` 1.5.1 com a fila `despacho` vazia. As 18 RPCs respondem
**401** `42501` sem sessão. O advisor de segurança só traz o aviso 0029, que é o desenho:
as 18 RPCs `security definer` abertas a `authenticated`. Antes de aplicar a próxima,
conferir `supabase_migrations.schema_migrations` do projeto.

As credenciais estão no `.env` local (fora do git).

## O quadro

Em 03/10, o quadro do projeto reflete a integração de 56 PRs na `develop`: a lista Revisão antiga foi amplamente saneada, com a conclusão de todos os cartões do Sprint 2.

**Situação dos PRs e cartões em 03/10:**

- **Em revisão:**
  - **PR #137** (`kT7NhMGV` / B10): `contato_do_turno` contra conta anonimizada, em revisão pela Faísca.
  - **PR #138** (`pVvubZJy`): reenvio de contestação de suspensão após resolução da anterior.
  - **PR #128** (`1DLcZWsf`): varredura de restrições de unicidade no mutador, aberto por Matheus Silva (`silvaaszx`).
  - **PR #102**: documentação do estado em 03/10, em revisão pela Bigorna.
- **Aguardando credenciais de ambiente:**
  - **PR #89**: entrega contínua `develop` -> `frila-dev`.
  - **PR #81**: SMTP próprio do `frila-dev`.
- **Obsoleto / a fechar:**
  - **PR #127**: espelho 0.2.32 (superado pela 0.2.33 diretamente integrada na `develop`).

Os quatro cartões de Matheus do início do projeto (`RNOfNVVU`, `7gpPBgTH`, `RTmRTHbo`, `ggEzge6h`) têm todo o backend entregue e testado; apenas as pontas remotas ou externas (credencial de demonstração, telas no app iOS e aprovação de lista de termos) aguardam desfecho externo.

`./scripts/trello.sh` faz tudo: `ver`, `lista`, `pegar`, `revisao`, `concluir`, `comentar`.

## O contrato mudou de endereço

> **Remedido em 03/10.** O contrato vigente espelhado em `contrato/openapi.yaml` é o **0.2.33**,
> com sha256 `ba3665c0e23b4fbecab8ccea38c3221a10e7fe50baa5b8b956ecd4a28edba466` e **em dia com o original**
> em `FrilaApp/frila-docs · api/openapi.yaml` (conferido com `contrato-em-dia.sh`).

`FrilaApp/frila-docs` reorganizou o repositório por assunto: **`Documentos/API/openapi.yaml`
virou `api/openapi.yaml`**. O redirect do GitHub cobre o nome antigo da organização, mas
não cobre caminho dentro do repositório — quem tiver script ou marcador apontando para o
caminho antigo precisa ajustar. No backend, o PR #15 ajustou.

Versão vigente: **0.2.33**, espelhada em `contrato/openapi.yaml` e **em dia com o original**,
conferido em 03/10 com o portão: *"Espelho em dia com FrilaApp/frila-docs"*. As versões
de 0.2.21 a 0.2.33 foram todas incorporadas:

| Versão | O que trouxe | Backend |
|---|---|---|
| **0.2.21** | validação e respostas de erro de `denunciar` e `bloquear` | #57 |
| **0.2.22 a 0.2.27** | alinhamento de erros, `avisar_a_caminho`, e ajustes de perfil | #88, #92 |
| **0.2.28** | bloqueio esconde perfil público com 404 | #103, #104 |
| **0.2.29** | `meu_estabelecimento` para membros do estabelecimento | #125 |
| **0.2.30** | `vinculo_id` do aparelho no push e registro de dispositivo | #129 |
| **0.2.31** | turno cancelado, avaliação dada e cancelamento no painel | #131 |
| **0.2.32** | cancelamento no turno e `turno_id` na candidatura | #130 |
| **0.2.33** | as sete coleções de `MeusDados` com campos conformes | #99, #135 |

**Atenção a quem roda o portão à mão:** o `.env` desta máquina não tem `FRILA_DOCS_TOKEN`, e
sem ele o `contrato-em-dia.sh` sai **2**. `FRILA_DOCS_TOKEN=$(gh auth token)`
basta quando o `gh` tem acesso ao `frila-docs`.

> **O que aconteceu entre 25 e 28/09, e vale como lição.** Em 25/09 o espelho estava na 0.2.15
> e o original já na 0.2.17, e **nenhuma medição viu** — porque o `contrato-em-dia.sh` lia
> `FRILA_DOCS_TOKEN` só do ambiente, e as baterias não faziam `source .env`. Sem o token ele
> saía **0** avisando em voz alta que não conferiu o original: o único portão capaz de pegar
> "o contrato mudou lá e ninguém trouxe" era justamente o que estava passando. Consertado no
> PR #37: lê o `.env`, e sai **2** quando não há token. As 0.2.16 a 0.2.18 subiram com os PRs
> do João Paulo, como devia ser.

## O que existe no banco

> **Remedido em 03/10.** Os números desta seção foram extraídos diretamente do banco de desenvolvimento com a `develop` em `4f1a6c5`:

Recontado em 03/10: **22 tabelas** em `public` (adicionadas `entrada_demonstracao`, `evento_app` e `pedido_de_exclusao`), **107** restrições
`CHECK`, 1 de exclusão (RN21), **21** políticas de leitura/RLS, **127** auxiliares no schema
`privado`, e nenhuma política de escrita em lugar nenhum — toda escrita passa por função
`security definer`.

```
avaliacao · bloqueio · candidatura · despacho · disponibilidade · dispositivo
entrada_demonstracao · equipe_confianca · estabelecimento · evento · evento_app
funcao · membro_estabelecimento · notificacao · ocorrencia · pedido_de_exclusao
posicao · profissional · profissional_funcao · turno · usuario · vaga
```

**Quarenta e duas RPCs expostas a `authenticated`**, contadas com `has_function_privilege`:

```
conta        criar_conta · minha_conta · situacao_da_conta · contestar_suspensao
perfil       criar_perfil_profissional · meu_perfil_profissional · atualizar_perfil_profissional
casa         cadastrar_estabelecimento · painel_estabelecimento · meus_estabelecimentos · meu_estabelecimento
equipe       equipe_de_confianca · incluir_na_equipe · remover_da_equipe
vaga         publicar_vaga · republicar_vaga · vagas_abertas · detalhe_vaga · cancelar_vaga
seleção      candidatos_da_vaga · escolher_candidato · retirar_candidatura
turno        candidatar · minhas_candidaturas · meus_turnos · contato_do_turno · cancelar_posicao · avisar_a_caminho
presença     fazer_checkin · fazer_checkout · confirmar_checkin_manual
reputação    avaliar · perfil_publico
push/disp    registrar_dispositivo · remover_dispositivo · criterios_de_notificacao
moderação    denunciar · bloquear
telemetria   registrar_evento
despacho     pedir_revisao_despacho · reabrir_por_atraso
app          configuracao_do_app   (sem sessão: a única que o anon executa)
```

**`configuracao_do_app` é a exceção à regra de que `anon` não lê nada** (cartão #201): o
app abaixo da versão mínima precisa descobrir isso antes de conseguir entrar. Lê
`privado.configuracao_app`, que o PostgREST não expõe. Subir a versão mínima é migração
nova, pelo roteiro em [`supabase/operacao/subir-versao-minima.md`](../supabase/operacao/subir-versao-minima.md).
A Modelagem no vault ainda não registra a exceção.

**O despacho e as rotinas agendadas:** **Treze jobs** ativos em `pg_cron`, medidos no banco
local com as migrações da `develop` em 03/10:

| Job | Quando | Origem |
|---|---|---|
| `alertar_atrasos` | `* * * * *` | #49 |
| `alertar_fim_sem_checkout` | `*/5 * * * *` | #79 |
| `alertar_vagas_vazias` | `*/5 * * * *` | #51 |
| `enviar_lembretes_turno` | `*/5 * * * *` | #50 |
| `fechar_selecoes` | `* * * * *` | #82 |
| `fechar_turnos_e_vagas` | `*/5 * * * *` | rotina de fechamento periódico |
| `liberar_teto` | `* * * * *` | #52 |
| `limpar_dispositivos_inativos` | `17 6 * * *` | limpeza de tokens |
| `processar_fila_email` | `* * * * *` | #70 |
| `reconciliar_reputacao_diaria` | `0 6 * * *` | reconciliação diária da taxa |
| `reprocessar_despacho` | `* * * * *` | a cada minuto |
| `retencao_e_limpeza_diaria` | `30 6 * * *` | limpeza e expurgo |
| `verificar_saude` | `*/5 * * * *` | #94 |

> Os agendamentos que antes apareciam apenas em comentários (`fechar_turnos_e_vagas` e `reconciliar_reputacao_diaria`) já foram incorporados e encontram-se ativos em `cron.job`.

A fila continua: `pgmq.q_despacho` recebe `{vaga_id, publicada_em}` na publicação e
`{vaga_id, posicao_id, motivo: reabertura, excluir_conta}` no cancelamento — o
`excluir_conta` é quem **não** deve ser notificado de novo. RLS ligada e sem política.

> ### ⚠️ A armadilha nova: `frila.agendador_secret`
>
> Desde o motor de despacho (26/09), o gatilho de `pgmq.q_despacho` exige
> `frila.agendador_secret` no banco **antes de qualquer RPC que enfileire uma vaga**. Sem
> ela, `publicar_vaga` responde:
>
> ```
> {"code":"P0001","message":"Configuração frila.agendador_secret ausente no banco de dados"}
> ```
>
> O `ci.yml` ganhou o passo *"Configurar segredo efêmero do agendador"*, que gera o valor com
> `openssl rand -hex 32` e o grava com `alter database` e `alter role authenticator`, logo
> depois do `supabase start` e **antes** do `db reset`.
>
> **Quem reproduz a CI à mão tem de reproduzir esse passo.** Medido em 28/09: sem ele,
> `ciclo-completo.sh` e `contrato-responde.sh` saem vermelhos — e o vermelho é do script de
> reprodução, não do código. Custou uma bateria inteira até eu olhar o `ci.yml` em vez de
> acreditar no meu próprio placar.

Depois do `db reset` o banco **não nasce vazio**: `cenarios.sql` põe 12 profissionais, 4
contratantes, 3 estabelecimentos, 7 vagas, 7 turnos, 6 avaliações, 1 bloqueio e 2
ocorrências. O mapa está em [`supabase/README.md`](../supabase/README.md).

**O molde das RPCs de escrita está fixado**, e vale copiar: `auth.uid()` na primeira
linha, `privado.exigir_perfil` na segunda, a conferência de conta suspensa em seguida,
validação devolvendo o código do contrato com o campo em `details`, e a resposta moldada
por uma função `…_em_json` separada.

**`privado.agora()` é o relógio do produto**, e desde 24/09 não há mais exceção: o
gatilho de RN07 usava `now()` direto e foi corrigido. Nenhuma RPC nova deve usar `now()`.

## Os portões

### Quatro portões nasceram entre 30/09 e 03/10

**Plano do caminho quente com o volume do DF** (`scripts/planos-com-carga.sh`, PR #67,
cartão `IYAb8v1i`). Job próprio na CI, fora do job do banco — a carga se recusa a rodar
sobre base povoada, então um passo no fim daquele job nunca mediria nada. Gera 30 mil
contratantes, 100 mil profissionais, 20 mil vagas e as ~200 mil janelas de
disponibilidade, e reprova em `Seq Scan` acima de mil linhas no caminho quente. Medido no
run `36853028970`: *"nenhuma varredura sequencial acima de 1000 linhas"*, `elegiveis` com
p95 de 27,1 ms (teto 400) e `vagas_abertas` com p95 de 28,6 ms (teto 600). Desfaz a carga
com `rollback`, então não apaga o `frila.agendador_secret`.

**Testes em Deno das Edge Functions** (PR #78, cartão `6mkytkpb`). Job próprio, com
`denoland/setup-deno@v2`. Até 29/09 `grep -rin deno .github/` devolvia zero linhas: os
testes existiam e **nunca tinham rodado**. São **171** hoje (andou 64 → 105 → 136 → 169 → 171)
porque testes dedicados de resiliência, caminhos de erro e contratos foram adicionados.

**O corpo das Edge Functions contra o contrato** (`scripts/contrato-responde.sh` estendido
+ `scripts/teste-contrato-responde.sh`, PR #100, cartão `oCv0WPNY`). Três portões
defendiam o contrato e nenhum olhava o corpo de uma Edge Function: o `contrato-em-dia.sh`
compara espelho com original, o `contrato-acompanha-o-codigo.sh` só dispara em função de
`public`, e o `contrato-responde.sh` só varria `/rpc/`. Agora varre todos os caminhos e
qualquer **2xx** em vez de só o 200 — a `excluirConta` responde 202, e exigir 200 deixaria
de fora justamente a operação que anonimiza conta. **48 operações indexadas** com resposta 200,
**44 validadas com corpo real** e **11 envelopes de recusa conferidos** em 03/10.

O que ele não alcança sai nomeado, com o motivo, em **seção separada** de "ainda sem
implementação" (4 operações): `confirmarCodigo`, `entrarDemonstracao` e `renovarSessao` (a
`Sessao` é emitida pelo Supabase Auth), e `listarFuncoes` (leitura de tabela direta pelo PostgREST).
A separação é deliberada — sem ela, a lista de sem-cobertura encolhe sozinha com o tempo e o
portão passa a parecer completo.

**Marca de corpo sem mudança de superfície no portão de contrato** (`scripts/contrato-acompanha-o-codigo.sh`, PR #136).
Permite alterar o corpo de uma RPC existente sem exigir bump de versão de contrato quando não há alteração de superfície,
mediante marca explícita `-- contrato: corpo-sem-mudanca-de-superficie <rpc> <versao>` conferida contra a versão da base.


> **Medição consolidada da bateria em 03/10.** Na `develop` em `4f1a6c5`, todos os portões
> locais e os **seis jobs da CI** (`banco`, `contrato-acompanha`, `migracoes`, `planos`, `deno`, `contrato`)
> rodam verdes:

| Comando | O que garante | Medida em 03/10 |
|---|---|---|
| `supabase test db` | pgTAP | **82** arquivos, **2351** asserções verdes (em ~4 s na máquina) |
| `./scripts/mutacao.sh` | cada regra morre sem teste | **90** regras cobertas na `develop` · 0 sem cobertura |
| `deno test --allow-all --no-check` | Edge Functions em Deno | **171** testes verdes, 0 falhas |
| `./scripts/ciclo-completo.sh` | o fluxo por HTTP, com status **e** código | verde até as recusas da presença e o perfil público |
| `./scripts/demonstracao.sh` | a porta da revisão da App Store, por HTTP | 14 conferências: porta, recusas, dados semeados e ciclo |
| `./scripts/corrida-candidatar.sh` | RN19 sob concorrência | 20 conexões, 2 posições, 2 confirmações |
| `./scripts/corrida-cadastrar-estabelecimento.sh` | o mesmo dono com dois cadastros no ar | verde |
| `./scripts/corrida-ciclo.sh` | 10 cenários de concorrência com temporização robustecida e travas resolvidas (#101, #134) | 50 de 50 rodadas verdes em todos os 10 cenários |
| `./scripts/contrato-acompanha-o-codigo.sh origin/develop` | PR que mexe em `public` leva o contrato | isenta RPC declarada ou marcada com corpo sem mudança de superfície (#136) |
| `./scripts/contrato-em-dia.sh` | o espelho não divergiu do original | **verde**: contrato 0.2.33 idêntico nos dois lados (`ba3665c0…`) |
| `./scripts/lint-conhecido.sh` | `plpgsql_check` | sem achado novo |
| `./scripts/relogio-do-produto.sh` | nenhuma função usa `now()` direto | só `privado.agora()` |
| `./scripts/contrato-responde.sh` | a resposta de cada RPC casa com o schema | **48** operações 200 indexadas, **44** validadas com corpo real, 11 envelopes |
| `./scripts/advisor-conhecido.sh` | advisor do Supabase | exige token de conta |
| `./scripts/migracoes-imutaveis.sh` | nenhuma migração aplicada foi editada | verde |
| `./scripts/migracoes-sem-colisao.sh` | duas migrações não têm a mesma versão | as **92** versões distintas na `develop` em 03/10 |
| `./scripts/planos-com-carga.sh` | caminho quente sob volume sintético do DF | verde na CI (p95 elegíveis 27 ms, vagas 28 ms) |

Todos rodam na CI nos seis jobs dedicados, exceto o advisor (que exige token de conta). O #52 acrescentou
`./scripts/corrida-teto.sh`, para o teto da RN23 sob concorrência.

**Antes de rodar a bateria à mão, o segredo do agendador**, ou dois destes saem vermelhos por
motivo que não é código. Ver a armadilha na seção *O que existe no banco*.

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
  CLI igual à da CI. Aconteceu de novo em 25/09, com `meus_estabelecimentos` nascendo
  `stable` e chamando `exigir_perfil` e `erro`, que são VOLATILE.
- **O portão que lê a saída de uma ferramenta quebra quando a ferramenta fala demais.** A
  CLI passou a imprimir o aviso de versão nova depois do JSON, e o `lint-conhecido.sh`
  reprovou com `JSONDecodeError` sobre um lint limpo. Recorte de saída de ferramenta
  precisa dizer onde termina, e não só onde começa.
- **Mudança feita no painel do Supabase não existe para o próximo ambiente.**
- **Mergear pilha de PRs com `--delete-branch` fecha os filhos.** Aconteceu com o #8 e o
  #10 em 24/09: apagar o branch-base de um PR aberto o fecha, e PR fechado **não** pode
  ser reaberto nem ter a base trocada. O #8 não se perdeu porque o #9 descendia dele; o
  #10 teve de virar o #15. Numa pilha, deletar só o último — ou retargetar os filhos
  para `main` antes.
- **Dois branches podem escolher a mesma hora redonda, e a colisão mata o `db reset`.**
  Medido em 25/09: `20260925230000_janela_da_demonstracao` entrou no `main` pelo #36, e o
  #31 do João Paulo trazia `20260925230000_configuracao_do_app`. Fundidos, o reset aplica
  os dois e registra um — `duplicate key value violates unique constraint
  "schema_migrations_pkey"`, com o banco meio migrado. `supabase migration new` usa o
  segundo corrente e nunca colide; quem nomeia à mão, e aqui é o comum porque o nome conta
  o que a migração faz, escolhe hora redonda — e hora redonda é o que duas pessoas
  escolhem igual. Portão novo: `./scripts/migracoes-sem-colisao.sh`.

## Divergências registradas

> ⚠️ **Esta seção é de 25/09 e não foi reconferida em 28/09 nem em 29/09.** O `main` ganhou
> oito PRs entre 25 e 28/09 — motor de despacho, push, `excluir_conta`, retenção, índices — e
> a `develop` mais onze numa noite; cada um pode ter fechado, criado ou mudado uma divergência
> daqui. As quatro últimas linhas da tabela abaixo entraram com o #49 e o #58, e
> `regiao_administrativa` (#54) ainda não foi conferida contra a Modelagem. O resto era
> verdade quando foi medido e não foi remedido. Antes de citar qualquer linha como fato
> atual, meça.

Nove colunas do esquema não estão na Modelagem de Banco. Todas nasceram de uma RPC, e
quem precisa reconciliar é o documento:

| Coluna | Por quê |
|---|---|
| `vaga.publicado_por` | um estabelecimento tem vários membros, e RF04 pergunta quem publicou |
| `usuario.demonstracao` | conta de revisão da App Store; as duas populações dividem o banco sem se enxergar |
| `turno.checkin_recebido_em` | `checkin_em` é a hora do **toque**; sem as duas, registro offline vira indistinguível |
| `turno.checkout_recebido_em` | o mesmo, do outro lado |
| `posicao.reaberta_por_atraso_de` | `reabrir_por_atraso` (e8XpOZJN, 28/09): a posição nova sabe de qual falta nasceu; é ela que aceita candidato depois do início, até 1 h antes do fim (8zLfn0mt item 5) |
| `vaga.rodada_despacho` | rodada de despacho (9DbPXis7, 29/09): 1 na publicação, mais um a cada `reabrir_por_atraso`; a vaga reaberta volta a chegar a quem já a tinha recebido (8zLfn0mt item 2) |
| `despacho.rodada` | o mesmo cartão: a unicidade do despacho passou de `(vaga_id, profissional_id)` para `(vaga_id, profissional_id, rodada)` |
| `notificacao.rodada` | o mesmo cartão: a marca de envio de `vaga` é por rodada, senão o push da rodada nova seria engolido pelo da primeira |
| `turno.a_caminho_em` | "estou a caminho" (h53CJVP7, 30/09, contrato 0.2.25): instante do aviso do profissional, visto pela casa no painel; não é presença, não entra na taxa e não guarda localização |

E mais estas:

- **A porta de demonstração aceita uma lista de e-mails, e o contrato fala em um só.**
  `openapi.yaml:2138` diz *"Aceita **um** e-mail... A conta é de profissional"*; o cartão
  `7gpPBgTH` pede **duas** contas, contratante e profissional, porque RN25 dá um perfil
  por conta — e o critério de aceite diz "com **cada** e-mail de revisão". O segredo
  `DEMONSTRACAO_EMAILS` é uma lista: com um endereço só, o comportamento é letra por letra
  o que o contrato descreve, então é superconjunto e não quebra cliente nenhum. **Quem
  precisa mudar é o contrato**, num PR do `FrilaApp/frila-docs` — e o espelho daqui só
  pode acompanhar depois, porque desde 24/09 o portão compara com o original de verdade.
- **`public.entrada_demonstracao` (junto com `evento_app` e `pedido_de_exclusao`) não está na
  Modelagem.** Não é tabela do produto: guarda as tentativas contra o código fixo da
  revisão. RLS ligada e nenhuma política, como `pgmq.q_despacho`; quem escreve é a Edge
  Function pela `service_role`.
- **`cenarios.sql` deixa as colunas de token do GoTrue em NULL**, e com NULL o
  `POST /auth/v1/admin/generate_link` responde `500 Database error finding user`. Medido
  em 25/09. Não quebra a entrada por código do e-mail, que é a que os cenários usam, mas
  fecha qualquer fluxo administrativo do Auth para essas contas. As contas de revisão do
  `seed.sql` vão com string vazia por isso.
- **A avaliação é um voto por LADO do turno, e não por autor.** `public.avaliacao` ganhou
  `unique (turno_id, alvo_tipo)` ao lado do `unique (turno_id, autor_id)` que já existia.
  O contrato afirmava as duas coisas: a tabela de erros dizia "avaliação deste autor" e
  `Turno.pode_avaliar` dizia "sem avaliação deste lado ainda". Venceu o lado, e a 0.2.12
  corrigiu a tabela de erros. **Consequência para a tela:** o operador que reenvia a
  resposta que o administrador já gravou recebe `200` com a avaliação do lado dele; com
  resposta diferente, `409 avaliacao_ja_registrada`. O `CLAUDE.md` foi atualizado junto.
- ~~**`perfil_publico` não filtra bloqueio (RF26)**~~ **Resolvido em 01/10 (PR #104, cartão `1aGJPQK2`).**
  A migração `20261001140000_perfil_publico_bloqueio.sql` implementou o filtro bidirecional de bloqueio
  entre visitante e titular do perfil, retornando `404 nao_encontrado` conforme o catálogo de erros,
  completamente coberto pelo teste `550_perfil_publico_bloqueio.sql`.
- **`unique` não é mutada pelo `mutacao.sh` da `develop`.** O script da `develop` varre `contype in ('c','x')`
  e os gatilhos; `contype = 'u'` fica de fora. O PR **#128** (cartão `1DLcZWsf`) está aberto para estender
  a cobertura do mutador para restrições e índices de unicidade.
- **O check-out é recusado depois do fim previsto.** `privado.exigir_janela` recusa
  `registrado_em > fim` com `fora_da_janela`: bater o ponto às 04:05 num turno que termina
  às 04:00 não entra. Não é bug — o aviso de hora excedida (cartão `qcVimM84`, PR #79)
  roda via cron a cada 5 minutos alertando profissional e contratante sobre turnos encerrados sem check-out.
- **A janela não se aplica à conta de revisão da App Store**, desde a migração
  `20260925230000_janela_da_demonstracao`. O turno semeado para a revisão começa dois dias
  depois de o seed rodar, e a janela abre 60 minutos antes do início: sete horas que abrem
  47 horas depois do seed e depois fecham para sempre. Em produção o seed entra uma vez, e
  a revisão não tem data marcada — medido em 25/09, a sessão de
  `revisao-profissional@frila.app` recebia `422 fora_da_janela`, o que deixaria check-in,
  confirmação manual e check-out inalcançáveis, contra a diretriz 2.1. A isenção é **só**
  da janela: registro no futuro continua `registro_no_futuro`, e o check-in sem distância
  continua nascendo `manual` e `pendente`. O par de controle está no
  `230_janela_da_demonstracao.sql`, com a conta real recebendo 422 no mesmo relógio.
- **`vagas_abertas` não filtra por data futura.** O filtro é `estado = 'publicada'` e nada
  mais: o encerramento de vagas e turnos vencidos é realizado periodicamente pelo agendador
  (`fechar_turnos_e_vagas`, a cada 5 minutos).
- **`vagas_abertas` e `meus_turnos` devolvem array, e não objeto com chave.** Custou duas
  rodadas vermelhas ao escrever o teste de ciclo. O contrato descreve as duas como lista;
  quem escrever teste novo não deve procurar `->'vagas'` nem `->'turnos'`.
- **`republicar_vaga` não copia `evento_id`.** `publicar_vaga` não recebe esse campo, e
  nenhuma vaga publicada pelo app tem evento hoje. Quando o evento existir, ele entra nas
  duas de uma vez. Registrado na 0.2.13.
- **Apenas quatro operações do contrato não têm RPC dedicada no backend**, e o
  `contrato-responde.sh` as lista em seção separada: três de autenticação (`confirmarCodigo`,
  `entrarDemonstracao` e `renovarSessao`, emitidas pelo Supabase Auth) e uma de leitura direta de tabela (`listarFuncoes`, servida pelo PostgREST). Todas as demais 44 operações com corpo 200 estão implementadas no backend e validadas contra o schema do contrato.
- **A retenção não pode esvaziar `ocorrencia.motivo`.** `ocorrencia_motivo_check` exige
  `length(btrim(motivo)) > 0`, então o job do `yClUqOpU` tem de **substituir** o relato por
  um marcador, e não apagá-lo. Medido em 25/09: um `update … set motivo = ''` passa pela
  exceção controlada da retenção e morre logo depois, com `23514`.
- **`ocorrencia.criada_em` e as outras colunas `criado_em` usam `now()`, e não
  `privado.agora()`.** São `default` de coluna, fora do alcance do
  `relogio-do-produto.sh`, que pergunta ao corpo das funções. Não quebra regra de prazo
  nenhuma hoje, mas significa que dentro de um teste com relógio deslocado a ocorrência
  nasce com a data de verdade enquanto o resto da transação vive no futuro.
- **`net.http_post` não entrou no `publicar_vaga`**, como o cartão pedia: a Edge Function
  `despachar` é do Sprint 2 e não existe. A fila é durável.
- **O modo seleção é recusado na v1.0** com `campo_invalido` e `details: modo`, e não com
  `selecao_sem_antecedencia`. Contrato 0.2.5.
- **Vaga `preenchida` recusa com `posicao_ja_preenchida`**, e não `vaga_encerrada`.
  Contrato 0.2.7.
- **A posição cancelada não volta para `aberta`**: a vaga ganha posição nova. Contrato
  0.2.11.
- **`turno.checkout_distancia_m` sem o teto de 200 m** que a Modelagem trazia, ratificado
  pela decisão de produto no cartão `8zLfn0mt` (a conferência de proximidade física restringe o check-in; o check-out registra a distância para telemetria sem teto impeditivo de 200 m).
- **`vaga.posicoes` com teto de 200**, que vem do contrato e não da Modelagem.
- **`privado.bloqueado_com_estabelecimento` faltava `m.usuario_id <> conta`.** Corrigido
  aqui; a Modelagem tem a mesma expressão errada.
- **`usuario` ganhou `termos_versao` e `termos_aceite_em`**, que não estão na Modelagem.

## Pendências fora do código

1. **Um `SUPABASE_ACCESS_TOKEN` que responda.** O do `.env` (`sbp_8f8e…`) responde **401**
   na Management API, remedido em 25/09 às 17h30. Sem ele: o advisor de segurança do
   `frila-dev` não é verificado por ninguém, o `aplicar-remoto.sh` não roda, e a porta da
   demonstração não sobe no `frila-dev` nem no `frila-prod`.

   **E não precisa de `supabase login` interativo**, ao contrário do que as versões
   anteriores deste arquivo diziam: a CLI aceita `SUPABASE_ACCESS_TOKEN` do ambiente, e o
   `.env` já tem a variável. O que falta é o valor. Token novo em
   https://supabase.com/dashboard/account/tokens, colado no `.env`, e daí
   `./scripts/demonstracao-remoto.sh dev` faz os três passos e mede o resultado. Medido em
   25/09: a CLI responde 401 e não "faça login", nos três casos — token do `.env`, token
   falso e nenhum token —, o que é consistente com ela usar a variável; o que **não** foi
   medido, por falta de token válido, é o caminho verde.

   Em 24/09 o advisor rodou pelo MCP do Supabase, que tem acesso à organização. O MCP não
   está na sessão de 25/09, e em 29/09 o desta máquina responde *"You do not have
   permission to perform this action"* ao listar as migrações do `frila-dev`.
2. ~~**PAT com leitura em `FrilaApp/frila-docs`.**~~ **Resolvido em 24/09.** O secret
   `FRILA_DOCS_TOKEN` existe no repositório e o portão passou a conferir o original de
   verdade: `./scripts/contrato-em-dia.sh` com o token respondeu *"Espelho em dia com
   FrilaApp/frila-docs"* sobre o contrato 0.2.11. Fine-grained, *Resource owner*
   `FrilaApp`, *Contents: Read-only*, validade até 23/09/2027.
   ~~**O que continua aberto:** sem token, `contrato-em-dia.sh` sai com **0**.~~
   **Resolvido em 25/09, e deixou de ser teórico no caminho.** O script passou a ler o
   `.env` e a sair **2** quando não há token em lugar nenhum. Custou o seguinte: em 25/09 o
   portão saiu 0 em quatro baterias seguidas, avisando que não conferiu o original, **e o
   token estava no `.env` todo esse tempo** — os outros scripts do repositório leem o
   `.env`; este não lia. Enquanto isso o espelho envelhecia atrás de uma 0.2.17 que já
   existia no `frila-docs`, e o único portão que pega isso era justamente o que estava
   passando. O ponto que era "quando o PAT vencer em 2027 ninguém vai saber" já tinha
   acontecido, por outro caminho.
3. **`git push` no `FrilaApp/Bancada`**, que exige Touch ID. Sem ele as notas diárias não
   saem e o site `bancada-buu.pages.dev` não republica.
4. **Revisão da Júlia** na lista de termos bloqueados. Sem ela o `ggEzge6h` não fecha.
5. **Aplicar as migrações novas no `frila-dev`, de novo.** Resolvido em 24/09 com as 29;
   **reaberto**: a `develop` tem 92 migrações em 03/10 (63 a mais que as 29 do `frila-dev`),
   e os critérios de conferência pós-deploy estão descritos em *Pendências no `frila-dev`*.
   Depende da pendência 1, e mais o `functions deploy` de `enviar-push`.
6. ~~**Decidir as operações do contrato sem cartão no quadro.**~~ **Resolvido:** as operações
   de negócio (`criteriosDeNotificacao`, `pedirRevisaoDespacho`, `equipeDeConfianca`,
   `incluirNaEquipe`, `removerDaEquipe`, `candidatosDaVaga`, `escolherCandidato`, `exportarTurnos`)
   foram todas implementadas na `develop`. Restam apenas `renovarSessao` (tratada pelo Supabase Auth)
   e `listarFuncoes` (exposta diretamente pelo PostgREST).
7. ~~**Avisar o Cauê sobre o projeto `frila-dev`.**~~ Alinhado no início da Sprint 2 com a fila de despacho (`vaga_id` e `publicada_em`).
8. ~~**Billing do Actions na organização `FrilaApp`.**~~ **Resolvido** entre 25/09 e 27/09:
   as execuções de 27/09 saem `success`. Não medi o que foi feito. Ver o bloco no topo.
9. **O segredo da demonstração no `frila-dev` e no `frila-prod`**, e o `functions deploy` da
   `entrar-demonstracao`. É o que falta para o critério 1 do `7gpPBgTH` valer *no
   `frila-dev`*, como o cartão pede, e não só na máquina. **O trabalho já está escrito:**
   `./scripts/demonstracao-remoto.sh dev` faz os segredos, o deploy e a medição por HTTP, e
   recusa antes de escrever se o token não responde, se o código é o de exemplo, se ele tem
   menos de 8 caracteres, ou se o alvo é produção sem `EU_SEI_QUE_E_PRODUCAO=1`. Depende só
   da pendência 1.

   O `--seco` foi medido em 25/09 e para no primeiro passo com a mensagem certa. O caminho
   verde nunca rodou, por falta de token.

## Por onde continuar

**O passo imediato é a revisão dos PRs abertos contra a `develop`**, garantindo que nada
avance sem bateria verde e total aderência ao contrato 0.2.33:

1. **Revisar e mergear o PR #137 (B10)**: `feat(contato): fecha contato_do_turno contra conta anonimizada (cartão kT7NhMGV)`,
   aberto contra a `develop`, cobrindo a recusa de conta anonimizada conforme o contrato 0.2.33. Revisor: Faísca.
2. **Revisar o PR #138**: `fix(suspensao): permite reenvio de contestacao apos resolucao da anterior (cartão pVvubZJy)`.
3. **Revisar o PR #128 (`mutacao-varre-unique`)**: estende o mutador para restrições e índices únicos (cartão `1DLcZWsf`), aberto por Matheus Silva (`silvaaszx`).
4. **Decidir o encerramento do PR #127**: o espelho 0.2.32 tornou-se obsoleto com a entrada da 0.2.33 diretamente na `develop`.
5. **Entrega contínua e SMTP no `frila-dev`**: avançar nos PRs #89 e #81 assim que as credenciais estiverem disponíveis.
6. **O `frila-dev`**, quando houver token que responda: aplicar as 92 migrações, `functions deploy enviar-push`,
   e conferir os treze jobs em `cron.job` — é o que falta para os critérios remotos da tabela *Pendências no `frila-dev`*.
7. **Os bloqueados continuam dependentes de fatores externos** — `7yq1flLG` (SMTP),
   `qcVimM84` e `nUpPFCpM` (design e telas iOS), `3zsjXW60` (instrumentação telemetria no iOS),
   `RTmRTHbo` (ação de republicar no iOS), `ggEzge6h` (revisão de termos pela Júlia), `7gpPBgTH` (token Supabase remoto).
8. **O molde de fechamento de cartão**, que vale repetir e não reinventar: um item da
   checklist por asserção nomeada, com o arquivo; e medição por HTTP quando o critério fala em
   status, porque o pgTAP alcança `sqlstate` e `code` e não o status. Está nos comentários do
   `6mdX80SC`, `AvockvHx`, `0uROtsRX`, `RTmRTHbo`, `ggEzge6h` e `RNOfNVVU`.
9. Toda RPC nova nasce com quatro coisas, e nenhuma é negociável: o filtro de texto nos
   campos livres, a recusa correspondente no `ciclo-completo.sh`, a linha no
   `openapi.yaml` com a versão subindo (ou marcação explícita de corpo sem mudança de superfície,
   conforme portão do PR #136), e a asserção de mutação que morre quando a regra some.
10. **E antes de rodar a bateria à mão: o segredo do agendador.** Ver a armadilha na seção *O
    que existe no banco*. Sem ele, dois portões saem vermelhos por motivo que não é código.
