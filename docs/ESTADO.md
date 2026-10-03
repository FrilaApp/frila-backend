# Estado do backend — 29/09/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

**O trabalho agora vive na `develop`, e a `main` está congelada desde 28/09 às 19h13.**
Em pouco mais de sete horas, de 28/09 às 19h14 a 29/09 às 02h37 (horário de Brasília), a
`develop` recebeu onze PRs por cima do `main` — quase todo o Sprint 2 de turno e despacho:
atraso e reabertura, lembretes, vaga vazia, teto da RN23, região administrativa, denunciar
e bloquear, e a rodada de despacho.

**55 migrações** na `develop` (47 no `main`) e o contrato em **0.2.20**, espelho em dia com o
original. A **0.2.21** (frila-docs #26) está aprovada na revisão e espera merge.

> ## 🚦 A regra nova: PR e merge só na `develop`
>
> Desde o `898fa8a` (28/09, 19h13, `docs(pipeline)`), o [`CLAUDE.md`](../CLAUDE.md) manda:
> branch nasce de `origin/develop`, PR abre com `--base develop`, merge entra só na
> `develop`. **A `main` é para release estável de produção** e ninguém mergeia nela.
>
> Conferido em 29/09: a `main` para em `c190836` (#48) e está **inteira contida** na
> `develop` — `git log origin/develop..origin/main` sai vazio. Nada entrou na `main` depois
> da regra.
>
> **Três PRs ainda apontam para a `main`, e nenhum deve entrar lá como está:**
>
> | PR | De quem | Estado em 29/09 |
> |---|---|---|
> | **#56** `ao/blendops-2-autoteste-colisao` | Matheus | aberto 29/09 às 04:35Z contra a `main`, **depois** da regra; sem conflito, última CI `failure` (04:39Z). Precisa trocar a base para `develop` |
> | **#35** `ao/frila-8` | Cauê | **conflito**; parado desde 25/09 |
> | **#27** `s0/despachar-porta` | Cauê | **conflito**; parado desde 25/09 |
>
> Os dois do Cauê precisam ser rebaseados sobre a `develop` e retargetados — decisão dele.
>
> **A CI não roda em push na `develop`.** O `ci.yml` dispara em `push: [main]` e em
> `pull_request`. Todo merge na `develop` foi medido no PR, e ninguém mede a `develop`
> depois de dois PRs se cruzarem. Conferido em 29/09: `gh run list --branch develop` vem
> vazio.

## Onde cada coisa parou

### O que entrou desde 28/09

Na `main`, antes da regra: **#37** (portão de colisão de versão, `RNOfNVVU`, Matheus, 28/09
às 16h15) e **#48** (falta por no-show depois do fim do turno, `NDx7TJ4d`/`8zLfn0mt`, 28/09
às 17h14). As 47 migrações do `main` são as 46 de 28/09 mais
`20260928160000_fechar_turnos_noshow`.

Na `develop`, em ordem de merge:

| PR | Cartão | O que trouxe | Migração | Cartão está em |
|---|---|---|---|---|
| **#51** | `vUR0Ltkb` | alerta de vaga vazia na janela crítica | `20260928200000_alerta_vaga_vazia` | Revisão, 0/4 |
| **#31** | `CvopSHh6` | `configuracao_do_app`: a versão mínima do app | `20260928193700_configuracao_do_app` | Concluído |
| **#34** | `nNUtbriv` | `bancada-sync` pela data do autor | — | Concluído |
| **#49** | `e8XpOZJN` | alerta de atraso aos 15 min e `reabrir_por_atraso`; candidatura na reaberta (0.2.19) | `20260928220000_alerta_de_atraso_e_reabrir_por_atraso` | Revisão, 0/5 |
| **#53** | `IoQPWtWs` | `enviar-push` fala com o Postgres direto para chamar `privado.*` (o PostgREST devolvia 404 calado) | — | Concluído |
| **#50** | `k5R4tzjC` | lembretes 24 h e 3 h antes do turno | `20260928180000_lembretes_24h_e_3h` | Revisão, 0/4 |
| **#54** | `x0jkygj0` | `regiao_administrativa` em estabelecimento e vaga, e interpolada nos pushes (0.2.20) | `20260928230000_regiao_administrativa` | Revisão, 0/6 |
| **#52** | `ee3MT3fH` | teto e agrupamento de notificações de vaga (RN23), e `scripts/corrida-teto.sh` | `20260928210000_teto_e_agrupamento_rn23` | Revisão, 0/5 |
| **#55** | — | teste Deno da falha fechada sem `AGENDADOR_SECRET` deixa de depender do diretório | — | — |
| **#57** | `JWJOPAOL` | RPCs `denunciar` e `bloquear`; o bloqueio filtra o teto e o push | `20260929100000_denunciar_e_bloquear` | Revisão, 0/4 |
| **#58** | `9DbPXis7` | rodada de despacho para posição reaberta por atraso | `20260929110000_rodada_de_despacho` | Revisão, 0/7 |

Todos são do João Paulo, pelos workers do AO. Oito arquivos de teste novos vieram junto, de
`330_alerta_de_atraso_e_reabrir` a `370_rodada_despacho_posicao_reaberta`, e são **45** no
total.

**Duas numerações colidem, sem quebrar nada:** há quatro arquivos `330_…` em
`supabase/tests/`. O pgTAP roda em ordem alfabética e nenhum depende de outro, mas quem
criar o próximo deve seguir de `380`.

**O #58 reprovou antes de entrar**, e a revisão pegou: a CI de 04:42Z caiu no portão *"O
contrato acompanhou o código"* porque a migração redeclarava `public.reabrir_por_atraso` sem
mexer no contrato. Corrigido, a CI de 05:10Z saiu verde e o merge foi às 05:37Z (02h37 em Brasília).

**Os cartões em Revisão estão com a checklist em zero** — nenhum critério marcado, embora os
comentários digam que os testes provam cada um. Pela regra do quadro quem marca é quem
revisa, e ninguém revisou pelo quadro ainda. Os comentários de merge estão em cada cartão.

Fechados sem merge: **#38**, **#39** e **#40** (turnos não verificados, motor de despacho e
push FCM), que tinham entrado por outro caminho no resgate #41.

### Pendências no `frila-dev`, cartão a cartão

Nenhum destes foi medido no remoto: o `frila-dev` não recebe nada da `develop` sozinho, e
em 29/09 o MCP do Supabase desta máquina responde *"You do not have permission"* para o
projeto `jcobftbhbqdikratzizz`. O que cada cartão deixou para conferir **depois do deploy**:

| Cartão | O que conferir no `frila-dev` |
|---|---|
| `e8XpOZJN` atraso | o job `alertar_atrasos` (`* * * * *`) existe em `cron.job` e roda sem erro |
| `vUR0Ltkb` vaga vazia | o job `alertar_vagas_vazias` (`*/5 * * * *`) em `cron.job`, e um push real a 3 h do início |
| `k5R4tzjC` lembretes | o job `enviar_lembretes_turno` (`*/5 * * * *`) em `cron.job` |
| `ee3MT3fH` teto RN23 | o job `liberar_teto` (`* * * * *`) em `cron.job` |
| `JWJOPAOL` denunciar | a fila `pgmq` `email` existe; o e-mail em si depende do `7yq1flLG` (abaixo) |
| `IoQPWtWs` `enviar-push` | `functions deploy enviar-push` com a conexão direta ao Postgres |
| `x0jkygj0` região | `functions deploy enviar-push`, que interpola a região nos pushes 09 e 11 |
| `NDx7TJ4d` no-show | os agendamentos de fechamento (ver a armadilha em *O que existe no banco*) |

Os quatro jobs novos são criados pelas próprias migrações, em bloco que faz `unschedule`
antes de `schedule`, como os três de 28/09. Com eles, **sete jobs** — medidos no banco local
em 29/09: `alertar_atrasos`, `alertar_vagas_vazias`, `enviar_lembretes_turno`,
`liberar_teto`, `limpar_dispositivos_inativos`, `reprocessar_despacho` e
`retencao_e_limpeza_diaria`.

### Cartões bloqueados, e por quê

| Cartão | O que trava |
|---|---|
| `7yq1flLG` E-mails transacionais e caixa da Equipe Frila | **SMTP e provedor de e-mail.** Depende de *S1 · Infra · SMTP próprio no Supabase Auth* e de *S1 · Design + Produto · Modelos de e-mail*. Trava também o critério 3 do `JWJOPAOL` (a denúncia chega à caixa da equipe): a denúncia já enfileira `{tipo, ocorrencia_id}` na fila `email`, e ninguém consome |
| `5bPJvMIo` Monitoramento e alertas | **Infra**: depende de `ZqmkOaHn` (ambientes e segredos), Em andamento com o Cauê |
| `kT7NhMGV` Endurecimento para produção | **Infra**: depende do ambiente de produção (`frila-prod`, segredos e monitoramento) |
| `qcVimM84` Aviso de hora excedida | **Design**: os textos saem da planilha de notificações e do cartão de permissões e notificações; a metade iOS abre o turno com o check-out em destaque |
| `nUpPFCpM` Exportar meus dados | **Design**: alta fidelidade de denúncia, bloqueio, conta suspensa, exportar e excluir conta; a metade da tela é **iOS** |
| `3zsjXW60` Telemetria do piloto | **Produto**: o plano de métricas e o dicionário de eventos (T-0017); a coleta é **iOS** |
| `RTmRTHbo` Republicar vaga | o quarto critério é a ação "Publicar de novo" na tela: **iOS** |
| `ggEzge6h` Filtro de texto | a revisão da lista de termos pela **Júlia** |
| `7gpPBgTH` Contas de demonstração | o critério 1 é no `frila-dev`, e falta um `SUPABASE_ACCESS_TOKEN` que responda: **infra/credencial** |

Em andamento em 29/09, de Backend: `BsXIZHOw` (suspensão e `contestar_suspensao`) e
`nspP9YDU` (concorrência além da RN19), com o João Paulo; `zptkprHt` (índice de
`elegiveis`), com o Matheus, 9/10 critérios e commit local `a656c49` feito **sobre o `main`**
— vai precisar de rebase na `develop` antes do PR.

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · **55** migrações na `develop`, **47** no `main` (contadas em 29/09) |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` · **29** migrações, conferidas em 24/09 — e a `develop` tem 55 |
| `frila-prod` | `hbjkkcenbudiezmamiak` · `sa-east-1` · criado em 24/09, **vazio**: as migrações entram pelo cartão do ambiente de produção (29/10), com a entrega contínua por tag |

> 🔴 **O `frila-dev` está atrás, e não sei quanto.** Ele tinha as mesmas 29 do `main` em
> 24/09; a `develop` chegou a 55 em 29/09 e **nada foi aplicado lá** que alguém tenha
> registrado. Vinte e seis migrações de diferença é a conta pelos arquivos, não uma medição
> do remoto: conferir o `supabase_migrations.schema_migrations` do projeto exige o token de
> conta, que responde 401, e o MCP do Supabase desta máquina responde sem permissão (medido
> em 29/09). `./scripts/aplicar-remoto.sh jcobftbhbqdikratzizz` é o caminho, e ele é
> idempotente — pula o que já está registrado. Antes de aplicar qualquer coisa, conferir a
> tabela de controle, **e aplicar a partir da `develop`**, que é onde as 55 estão.

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

**Desde 29/09 o `frila-dev` manda e-mail por SMTP próprio**, e o código de entrada voltou a
ser código. O envio embutido do Supabase entregava cerca de 2 por hora e só para endereços
do time, o que travava a validação de entrada do cartão `9FRaLndF` e travaria o TestFlight
de 20/10.

| | Antes | Agora |
|---|---|---|
| Envio | embutido do Supabase | `smtp.gmail.com:465`, conta `frilaverificacao@gmail.com`, remetente "Frila" |
| Limite | ~2 por hora, só para o time | ~500 por dia, para qualquer endereço |
| Conteúdo | link (`{{ .ConfirmationURL }}`) | código de seis dígitos (`{{ .Token }}`) |
| Validade | 1 hora | 15 minutos |

**O que custou a descobrir:** no plano gratuito, o Supabase **recusa** alterar o modelo de
e-mail enquanto não houver SMTP próprio — *"Email template modification is not available for
free tier projects using the default email provider"*. Não era configuração esquecida: sem
SMTP era impossível mandar o código em vez do link, e foi isso que levou o iOS a ganhar
entrada por link mágico. A ordem importa: **SMTP primeiro, modelo depois.**

Gmail foi escolhido no cartão `heg4ujOr` porque o time ainda não tem domínio. Um provedor
transacional (Resend, Postmark, Brevo, SES) mandaria com remetente `@gmail.com`, domínio que
o time não controla: SPF e DKIM não alinham e o código tende ao spam. Com o SMTP do Gmail,
quem assina é o Google. Quando o domínio existir (`FI406hMv`), a migração é trocar os campos
de SMTP: nada de app, contrato ou banco muda.

Medido em 29/09 às 17:56 (BRT): código enviado a um Gmail real, chegou na caixa de entrada,
com o código no assunto. A senha de app não está neste repositório nem em nenhum outro.

O `frila-prod` continua **sem SMTP**: ele entra pelo cartão do ambiente de produção.

**A Management API responde**, ao contrário do que a pendência 1 diz. O token do `.env` é
que está vencido; um token pessoal de conta, criado no painel, funciona e foi o que aplicou
esta configuração.

## O quadro

**A lista Revisão tem vinte e dois cartões em 29/09** (eram quinze em 28/09). Entraram os sete do
Sprint 2 que a `develop` recebeu — `e8XpOZJN`, `k5R4tzjC`, `vUR0Ltkb`, `ee3MT3fH`,
`x0jkygj0`, `JWJOPAOL` e `9DbPXis7` —, todos com a checklist em zero, esperando quem
revise. Continuam lá cinco dos seis de 26 e 27/09 (`36fU0CEO`, `7XS6MQGg`, `wpNabtCO`, `IYAb8v1i`
e `OrS9gEfU`), os quatro do Matheus de antes e seis de Infra e iOS.

Fecharam desde 28/09: `yClUqOpU` (retenção de 15 dias, 3/3), `NDx7TJ4d` (turnos não verificados, 5/5, com o #48), `CvopSHh6`
(`configuracao_do_app`, com o #31), `nNUtbriv` (`bancada-sync`, com o #34) e `IoQPWtWs`
(`enviar-push`, com o #53).

**O `8zLfn0mt` (decisões de produto) tem as decisões registradas em comentário de 28/09**,
aprovadas pelo João Paulo item a item — no-show vira falta automática, despacho único por
rodada, suspensão cancela em cascata, checkout sem teto de 200 m, reaberta aceita candidato
até 1 h antes do fim —, mas a checklist continua 0/9. A Modelagem e o Backlog v1.2.1 ainda
não foram atualizados com elas.

**Os quatro cartões do Matheus que continuam em Revisão, e por quê:**

| Cartão | O que falta, e de quem é |
|---|---|
| `RNOfNVVU` Portão de colisão de versão | O #37 **entrou na `main`** em 28/09 às 16h15 e o portão roda: *"As 55 migrações têm versões distintas"* (29/09). O critério que sobra é o caminho verde do `demonstracao-remoto.sh`, que depende do token de conta. O autoteste do portão está no #56, aberto contra a `main` |
| `7gpPBgTH` Contas de demonstração | Três dos quatro critérios medidos e as notas anexadas. O critério 1 diz "no `frila-dev`", e lá a porta ainda não existe. O caminho está pronto num comando — `./scripts/demonstracao-remoto.sh dev` faz os segredos, o deploy e a medição —, e falta só um `SUPABASE_ACCESS_TOKEN` que responda. **Bloqueio de credencial, e não de navegador** |
| `RTmRTHbo` Republicar vaga | Os três critérios de backend marcados, inclusive republicar a partir de vaga `encerrada`, medido por HTTP. O quarto é de ponta a ponta e depende da tela: a ação "Publicar de novo" em Minhas vagas. **É iOS** |
| `ggEzge6h` Filtro de texto | Os três critérios marcados, com a recusa e o falso positivo medidos por HTTP. O quarto item é a revisão da lista de termos pela Júlia. **É da Júlia** |

**Não há cartão de Backend livre e desbloqueado em 29/09** que não dependa de SMTP, infra,
iOS ou design — ver *Cartões bloqueados*. Antes de escolher trabalho novo, varrer o quadro
de novo: ele mudou em uma noite mais do que em três dias.

`./scripts/trello.sh` faz tudo: `ver`, `lista`, `pegar`, `revisao`, `concluir`, `comentar`.

## O contrato mudou de endereço

`FrilaApp/frila-docs` reorganizou o repositório por assunto: **`Documentos/API/openapi.yaml`
virou `api/openapi.yaml`**. O redirect do GitHub cobre o nome antigo da organização, mas
não cobre caminho dentro do repositório — quem tiver script ou marcador apontando para o
caminho antigo precisa ajustar. No backend, o PR #15 ajustou.

Versão vigente: **0.2.20**, espelhada em `contrato/openapi.yaml` e **em dia com o original**,
conferido em 29/09 com o portão: *"Espelho em dia com FrilaApp/frila-docs"*. Desde 28/09
entraram no `frila-docs`:

| Versão | PR no `frila-docs` | O que trouxe | Backend |
|---|---|---|---|
| **0.2.19** | #23, 28/09 | posição reaberta por atraso aceita candidatura depois do início | #49 |
| **0.2.20** | #24, 29/09 | `regiao_administrativa` do estabelecimento e do local da vaga | #54 |
| **0.2.21** | **#26, aberto** | validação e respostas de erro de `denunciar` e `bloquear` | #57 |

**A 0.2.21 está aprovada e espera merge.** A revisão (comentário de 29/09 às 04:30Z) dá
*"VEREDITO: aprovaria"*, sem bloqueio, e o PR está sem conflito. Não há review formal no
GitHub, só o comentário. Enquanto ela não entra, o `422` de `denunciar` do #57 está no código
e não no contrato; quando entrar, o espelho daqui precisa subir para 0.2.21 num PR contra a
`develop`, senão o `contrato-em-dia` reprova.

**Atenção a quem roda o portão à mão:** o `.env` desta máquina não tem `FRILA_DOCS_TOKEN`, e
sem ele o `contrato-em-dia.sh` sai **2** (medido em 29/09). `FRILA_DOCS_TOKEN=$(gh auth token)`
basta quando o `gh` tem acesso ao `frila-docs`.

> **O que aconteceu entre 25 e 28/09, e vale como lição.** Em 25/09 o espelho estava na 0.2.15
> e o original já na 0.2.17, e **nenhuma medição viu** — porque o `contrato-em-dia.sh` lia
> `FRILA_DOCS_TOKEN` só do ambiente, e as baterias não faziam `source .env`. Sem o token ele
> saía **0** avisando em voz alta que não conferiu o original: o único portão capaz de pegar
> "o contrato mudou lá e ninguém trouxe" era justamente o que estava passando. Consertado no
> PR #37: lê o `.env`, e sai **2** quando não há token. As 0.2.16 a 0.2.18 subiram com os PRs
> do João Paulo, como devia ser.

## O que existe no banco

> **Não recontado em 29/09.** Os números desta seção são do `main` de 28/09. A `develop`
> acrescentou, pela conta dos arquivos: as RPCs `reabrir_por_atraso`, `denunciar` e
> `bloquear`; as tabelas `privado.configuracao_app`, `privado.parametro_notificacao` e
> `privado.tipo_no_teto`; a fila `pgmq` `email`; as colunas `regiao_administrativa` e as
> de rodada (ver *Divergências*). Recontar com `has_function_privilege` antes de citar.

Recontado em 28/09, com o `main` de hoje: **20 tabelas** em `public`, **33** restrições
`CHECK`, 1 de exclusão (RN21), **19** políticas de leitura, **71** auxiliares no schema
`privado`, e nenhuma política de escrita em lugar nenhum — toda escrita passa por função
`security definer`.

```
avaliacao · bloqueio · candidatura · despacho · disponibilidade · dispositivo
entrada_demonstracao · equipe_confianca · estabelecimento · evento · funcao
membro_estabelecimento · notificacao · ocorrencia · posicao · profissional
profissional_funcao · turno · usuario · vaga
```

**Vinte e quatro RPCs expostas a `authenticated`**, contadas com `has_function_privilege` e
não pela lista escrita à mão:

```
conta        criar_conta · minha_conta
perfil       criar_perfil_profissional · meu_perfil_profissional · atualizar_perfil_profissional
casa         cadastrar_estabelecimento · painel_estabelecimento · meus_estabelecimentos
vaga         publicar_vaga · republicar_vaga · vagas_abertas · detalhe_vaga · cancelar_vaga
turno        candidatar · meus_turnos · contato_do_turno · cancelar_posicao
presença     fazer_checkin · fazer_checkout · confirmar_checkin_manual
reputação    avaliar · perfil_publico
push         registrar_dispositivo · remover_dispositivo
app          configuracao_do_app   (sem sessão: a única que o anon executa)
```

**`configuracao_do_app` é a exceção à regra de que `anon` não lê nada** (cartão #201): o
app abaixo da versão mínima precisa descobrir isso antes de conseguir entrar. Lê
`privado.configuracao_app`, que o PostgREST não expõe. Subir a versão mínima é migração
nova, pelo roteiro em [`supabase/operacao/subir-versao-minima.md`](../supabase/operacao/subir-versao-minima.md).
A Modelagem no vault ainda não registra a exceção.

**O despacho deixou de ser promessa.** `pg_cron` e `pg_net` **entraram** — a frase "continuam
fora", que este arquivo repetiu por dias, está morta. **Sete jobs** ativos, medidos no banco
local com as migrações da `develop` em 29/09:

| Job | Quando |
|---|---|
| `reprocessar_despacho` | `* * * * *` — a cada minuto |
| `limpar_dispositivos_inativos` | `17 6 * * *` |
| `retencao_e_limpeza_diaria` | `30 6 * * *` |
| `alertar_atrasos` | `* * * * *` — #49 |
| `liberar_teto` | `* * * * *` — #52 |
| `enviar_lembretes_turno` | `*/5 * * * *` — #50 |
| `alertar_vagas_vazias` | `*/5 * * * *` — #51 |

> ⚠️ **Três agendamentos estão só em comentário.** `fechar_turnos_passados` (`*/15`),
> `reconciliar_reputacao_diaria` (`0 4 * * *`) e `fechar-turnos-e-vagas` (`*/5`) aparecem em
> `20260926000000_turnos_nao_verificados_e_reconciliacao` e
> `20260926040000_fechamento_turno_vaga` como `-- select cron.schedule(…)`, "configuração de
> produção documentada sem ser aplicada". Nenhum está em `cron.job`. As funções existem e os
> testes as chamam direto, mas **no `frila-dev` ninguém fecha turno passado nem reconcilia
> a taxa** até alguém agendar — e o no-show do #48 depende do fechamento. Decidir se entra
> como migração nova ou no procedimento do deploy.

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

> **A bateria inteira não foi remedida em 29/09.** Cada PR da `develop` passou nos quatro jobs
> da CI no próprio PR, mas a CI não roda em push na `develop` (ver o topo), e ninguém mediu a
> soma. Em 29/09, sobre a `develop` em `35728b3`, rodaram só dois portões que não mexem no
> banco: `migracoes-sem-colisao.sh` (*"As 55 migrações têm versões distintas"*) e
> `contrato-em-dia.sh` (*"Espelho em dia"*, 0.2.20). A tabela abaixo é de 28/09.

**Medidos em 28/09**, no branch `s0/migracoes-sem-colisao` já com o `main` fundido, com o
segredo do agendador e `db reset` antes: **treze portões, treze verdes.**

| Comando | O que garante | Medida |
|---|---|---|
| `supabase test db` | pgTAP | **1010** asserções em **38** arquivos, em 2 a 3 s na máquina |
| `./scripts/mutacao.sh` | cada regra morre sem teste | **90** cobertas, 0 sem cobertura, 0 não medidas · 294 s |
| `./scripts/ciclo-completo.sh` | o fluxo por HTTP, com status **e** código | verde até as recusas da presença e o perfil público |
| `./scripts/demonstracao.sh` | a porta da revisão da App Store, por HTTP | **14** conferências: a porta, o que ela recusa, os dados semeados, **o ciclo da presença inteiro** e o teto de tentativas |
| `./scripts/corrida-candidatar.sh` | RN19 sob concorrência | 20 conexões, 2 posições, 2 confirmações |
| `./scripts/corrida-cadastrar-estabelecimento.sh` | o mesmo dono com dois cadastros no ar | verde |
| `./scripts/contrato-acompanha-o-codigo.sh` | PR que mexe em `public` leva o contrato | desde o #44 isenta RPC já declarada, e enxerga função com comentário entre `function` e o nome |
| `./scripts/contrato-em-dia.sh` | o espelho não divergiu do original | **verde**: *"Espelho em dia com FrilaApp/frila-docs"*, 0.2.18 nos dois lados. Desde 25/09 lê o `.env` e sai **2** quando não tem token, em vez de 0 |
| `./scripts/lint-conhecido.sh` | `plpgsql_check` | sem achado novo |
| `./scripts/relogio-do-produto.sh` | nenhuma função usa `now()` direto | só `privado.agora()` |
| `./scripts/contrato-responde.sh` | a resposta de cada RPC casa com o schema | **24** corpos e 7 envelopes |
| `./scripts/advisor-conhecido.sh` | advisor do Supabase | **não roda**: token de conta responde 401 |
| `./scripts/migracoes-imutaveis.sh` | nenhuma migração aplicada foi editada | verde |
| `./scripts/migracoes-sem-colisao.sh` | duas migrações não têm a mesma versão | as **55** versões distintas em 29/09 · entrou com o #37 — nasceu depois de a colisão matar um `db reset` de verdade |

Todos rodam na CI menos o advisor, que exige token de conta. O #52 acrescentou
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
- **`public.entrada_demonstracao` é a vigésima tabela de `public`**, e não está na
  Modelagem. Não é tabela do produto: guarda as tentativas contra o código fixo da
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
- **`perfil_publico` não filtra bloqueio (RF26)**, embora o catálogo de erros diga que o
  `404 nao_encontrado` "inclui bloqueio". O cartão `zdCpLEVs` não pedia, e a decisão é de
  produto. Está escrito na 0.2.12 como divergência aberta, e é pergunta para a Júlia.
- **`unique` não é mutada por nenhum portão.** O `mutacao.sh` varre `contype in ('c','x')`
  e os gatilhos; `contype = 'u'` fica de fora. Na prática isso significa que
  `um_voto_por_lado` — a regra mais discutível do cartão — é a única sem asserção de
  mutação. Cartão próprio, não conserto de última hora.
- **O check-out é recusado depois do fim previsto.** `privado.exigir_janela` recusa
  `registrado_em > fim` com `fora_da_janela`: bater o ponto às 04:05 num turno que termina
  às 04:00 não entra. Medido em 25/09 ao escrever o `190_ciclo_no_banco.sql`. Não é bug
  hoje — o aviso de hora excedida é cartão do Sprint 2 —, mas quando ele existir, é esta
  janela que precisa mudar.
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
  mais: vaga cujo início já passou continua na lista de todo mundo. Medido em 25/09. Para
  a revisão isso é bom — a vaga semeada não desaparece e a tela nunca nasce vazia (4.2) —,
  mas é uma vaga vencida visível para o produto, e nada hoje muda o estado dela: quem
  encerra vaga vencida é o motor do Sprint 2. Não tem cartão próprio.
- **`vagas_abertas` e `meus_turnos` devolvem array, e não objeto com chave.** Custou duas
  rodadas vermelhas ao escrever o teste de ciclo. O contrato descreve as duas como lista;
  quem escrever teste novo não deve procurar `->'vagas'` nem `->'turnos'`.
- **`republicar_vaga` não copia `evento_id`.** `publicar_vaga` não recebe esse campo, e
  nenhuma vaga publicada pelo app tem evento hoje. Quando o evento existir, ele entra nas
  duas de uma vez. Registrado na 0.2.13.
- **Dezoito operações do contrato ainda não têm implementação**, e o
  `contrato-responde.sh` as lista a cada execução. Não é dívida escondida: é o Sprint 2 em
  diante. O número é o que impede alguém de ler "portão verde" como "o contrato inteiro
  está no ar".
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
- **`turno.checkout_distancia_m` sem o teto de 200 m** que a Modelagem traz. Vai à decisão
  no cartão `S0 · Produto · Decisões de produto que travam o código`, prazo 02/10.
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
   **reaberto em 29/09**: a `develop` tem 55, e cada cartão de Sprint 2 em Revisão deixou
   um critério para conferir lá depois do deploy (ver *Pendências no `frila-dev`*). Depende
   da pendência 1, e mais o `functions deploy` de `enviar-push`.
6. **Decidir as operações do contrato sem cartão no quadro** — `renovarSessao`,
   `criteriosDeNotificacao`, `pedirRevisaoDespacho`, `equipeDeConfianca`,
   `incluirNaEquipe`, `removerDaEquipe`, `listarFuncoes`, `candidatosDaVaga`,
   `escolherCandidato`, `exportarTurnos`. Contrato a mais ou cartão faltando.
7. **Avisar o Cauê** que o projeto Supabase que ele criou em 22/09 virou o `frila-dev`, e
   que a mensagem da fila de despacho traz `vaga_id` e `publicada_em` — é o que o motor
   do Sprint 2 vai consumir.
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

**O passo imediato é de revisão, não de código:** sete cartões de Sprint 2 estão em Revisão
com a checklist em zero (`e8XpOZJN`, `k5R4tzjC`, `vUR0Ltkb`, `ee3MT3fH`, `x0jkygj0`,
`JWJOPAOL`, `9DbPXis7`). Quem revisa marca item por item, com o arquivo pgTAP que prova cada
um; o que é do `frila-dev` fica desmarcado com o motivo no cartão.

Depois disso, em ordem:

1. **Mergear o frila-docs #26 (0.2.21)** e subir o espelho para 0.2.21 num PR contra a
   `develop`. Até lá o `422` de `denunciar` está no código e fora do contrato.
2. **Trazer para a `develop` o que ainda aponta para a `main`:** o #56 do Matheus (trocar a
   base), e o #27 e o #35 do Cauê, em conflito desde 25/09 — rebase é decisão dele. O
   `a656c49` do `zptkprHt` também foi feito sobre o `main`.
3. **Decidir os três agendamentos comentados** (`fechar_turnos_passados`,
   `reconciliar_reputacao_diaria`, `fechar-turnos-e-vagas`): sem eles o `frila-dev` não fecha
   turno nem aplica o no-show do #48. Ver a armadilha em *O que existe no banco*.
4. **Medir a `develop` inteira de uma vez**: `db reset`, `test db`, a bateria dos portões
   com o segredo do agendador. Onze PRs verdes um a um não provam a soma, e a CI não roda em
   push na `develop`.
5. **O `frila-dev`**, quando houver token que responda: aplicar as 55, `functions deploy
   enviar-push`, e conferir os sete jobs em `cron.job` — é o que falta para os critérios
   remotos da tabela *Pendências no `frila-dev`*.
6. **Os bloqueados continuam bloqueados** — `7yq1flLG` (SMTP), `5bPJvMIo` e `kT7NhMGV`
   (infra), `qcVimM84` e `nUpPFCpM` (design e iOS), `3zsjXW60` (plano de métricas),
   `RTmRTHbo` (iOS), `ggEzge6h` (Júlia), `7gpPBgTH` (token). Nenhum avança aqui.
7. **O molde de fechamento de cartão**, que vale repetir e não reinventar: um item da
   checklist por asserção nomeada, com o arquivo; e medição por HTTP quando o critério fala em
   status, porque o pgTAP alcança `sqlstate` e `code` e não o status. Está nos comentários do
   `6mdX80SC`, `AvockvHx`, `0uROtsRX`, `RTmRTHbo`, `ggEzge6h` e `RNOfNVVU`.
8. Toda RPC nova nasce com quatro coisas, e nenhuma é negociável: o filtro de texto nos
   campos livres, a recusa correspondente no `ciclo-completo.sh`, a linha no
   `openapi.yaml` com a versão subindo, e a asserção de mutação que morre quando a regra
   some. O portão do contrato cobra a terceira; as outras três dependem de quem escreve.
9. **E antes de rodar a bateria à mão: o segredo do agendador.** Ver a armadilha na seção *O
   que existe no banco*. Sem ele, dois portões saem vermelhos por motivo que não é código.
