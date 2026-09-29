# Estado do backend — 28/09/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

**O ciclo do Sprint 1 fecha inteiro no `main`, e o Sprint 2 andou muito em 26 e 27/09**,
pelas mãos do João Paulo e do Cauê: notificações, motor de despacho, push pelo FCM,
`excluir_conta`, retenção de 15 dias e as consultas quentes do DF entraram ou estão em PR.

**46 migrações** no `main` e o contrato em **0.2.18**, espelho em dia com o original.

> ## ✅ A CI voltou
>
> **Medido em 28/09:** as execuções de 27/09 saem `success` — `main` às 03:38 e 04:19,
> `s3/retencao-15-dias`, `s0/configuracao-do-app`. A única anotação que sobra é o aviso de
> que `actions/checkout@v4` roda em Node 24 porque o Node 20 foi depreciado.
>
> O bloqueio de Billing que parou tudo entre 25/09 às 14h e algum momento de 26 ou 27/09
> **acabou**; não medi o que exatamente foi feito, e a página de Billing continua exigindo
> escopo `admin:org`, que o token desta máquina não tem.
>
> **Consequência para quem chega agora:** a decisão de 25/09 — "o que entra no `main` entra
> com prova local, com o placar colado no PR" — **não vale mais**. Voltou a valer o portão
> remoto. Um PR cuja última execução é de 25/09 está vermelho por um motivo que não existe
> mais: confira a data do run antes de acreditar no ✗.
>
> Foi o caso do **#37**, o único PR meu aberto: os quatro jobs falhavam com a anotação de
> Billing, num run de 25/09 às 20:59Z. Medido em 28/09, com o `main` fundido no branch.

## Onde cada coisa parou

### O único PR meu aberto: #37

`s0/migracoes-sem-colisao`, cartão `RNOfNVVU`. Dois portões e dois scripts, e o que segurava
o merge **deixou de existir**:

- Quando abri, em 25/09, o `contrato-em-dia` reprovava porque o espelho estava na 0.2.15 e o
  original na 0.2.17. Em 28/09 os dois estão na **0.2.18**, e o portão responde *"Espelho em
  dia com FrilaApp/frila-docs"*.
- O `main` foi fundido no branch em 28/09, sem conflito, e o portão de colisão passa com as
  46 migrações.

**Falta um `git push` e o re-run da CI**, que agora roda. A última execução dele é de 25/09
e não vale nada.

### O que entrou no `main` em 26 e 27/09, e não é meu

Oito PRs, quase todos do João Paulo e do Cauê. O Sprint 2 andou muito:

| PR | O que trouxe | De quem |
|---|---|---|
| **#32** | Notificação para qualquer conta, marcas de envio e payload só com ids | João Paulo |
| **#41** | Resgate dos PRs #1 a #6 do `frila-backend` temporário | Cauê |
| **#42** | Resgate do #7: Edge Function `excluir-conta` | Cauê |
| **#43** | Resgate do #8: ciclo de vida do token de push | Cauê |
| **#44** | Portão do contrato passa a isentar RPC já declarada, e enxerga função com comentário entre `function` e o nome | João Paulo |
| **#45** | Segunda rodada de correções do `excluir-conta`, e o espelho 0.2.18: **401 para conta encerrada** em RPCs de escrita | João Paulo |
| **#46** | Índices para as consultas quentes e script de carga do DF | João Paulo |
| **#47** | Retenção de 15 dias, higiene de tabelas e limpeza de contas sem cadastro | João Paulo |

Dez arquivos de teste novos entraram com eles: `240_notificacoes` a `320_retencao_e_limpeza`,
mais `tests/carga/gerar_df.sql`.

### Abertos em 28/09, e nenhum além do #37 é meu

| PR | Cartão | De quem | Estado |
|---|---|---|---|
| **#40** `s2/push-fcm` | `36fU0CEO` | João Paulo | conflito com o `main` |
| **#39** `s2/motor-despacho` | `7XS6MQGg` | João Paulo | conflito com o `main` |
| **#38** `s2/turnos-nao-verificados` | `NDx7TJ4d` | João Paulo | conflito com o `main` |
| **#37** `s0/migracoes-sem-colisao` | `RNOfNVVU` | **meu** | resolvido na máquina, falta push e re-run |
| **#35** `ao/frila-8` | — | Cauê | run velho |
| **#34** `s0/corrigir-bancada-sync` | `nNUtbriv` | João Paulo | run velho |
| **#31** `s0/configuracao-do-app` | `CvopSHh6` | João Paulo | **limpo e verde** na CI de 27/09 |
| **#27** `s0/despachar-porta` | `ZqmkOaHn` | Cauê | conflito com o `main` |

**O aviso da colisão funcionou:** o #31 trazia `20260925230000_configuracao_do_app.sql`, que
colidia com a migração do #36. Hoje ele traz `20260928193700_configuracao_do_app.sql` (renomeada em 28/09 para vir depois da última do `main`), e não
há versão repetida no `main`.

Mergeados em 25/09: **#23** (contas de demonstração), **#24** (`avaliar` e `perfil_publico`),
**#25** (testes do ciclo), **#26** (`republicar_vaga`), **#28** (`meus_estabelecimentos`),
**#29** (testes de contrato), **#30** (trilha de auditoria, `2947a5c8`) e **#36** (a janela da
demonstração e as notas da revisão, `ed0c6456`).

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · **46** migrações no `main` (contadas em 28/09) |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` · **29** migrações, conferidas em 24/09 — e o `main` tem 46 |
| `frila-prod` | `hbjkkcenbudiezmamiak` · `sa-east-1` · criado em 24/09, **vazio**: as migrações entram pelo cartão do ambiente de produção (29/10), com a entrega contínua por tag |

> 🔴 **O `frila-dev` está atrás, e não sei quanto.** Ele tinha as mesmas 29 do `main` em
> 24/09; o `main` chegou a 46 em 28/09 e **nada foi aplicado lá** por mim. Dezessete
> migrações de diferença é a conta pelos arquivos, não uma medição do remoto: conferir o
> `supabase_migrations.schema_migrations` do projeto exige o token de conta, que responde 401.
> `./scripts/aplicar-remoto.sh jcobftbhbqdikratzizz` é o caminho, e ele é idempotente — pula
> o que já está registrado. Antes de aplicar qualquer coisa, conferir a tabela de controle.

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

A lista Revisão foi varrida em 25/09 e ficou com nove cartões. **Em 28/09 ela tem quinze**,
e o que voltou a enchê-la não é meu: são os seis cartões de Sprint 2 e 3 que o João Paulo e o
Cauê entregaram em 26 e 27/09 — `36fU0CEO` (push FCM), `7XS6MQGg` (motor de despacho),
`wpNabtCO` (ciclo do token de push), `yClUqOpU` (retenção de 15 dias), `IYAb8v1i` (consultas
quentes) e `OrS9gEfU` (`excluir-conta`).

Fecharam em 25/09: `6mdX80SC` (trilha de auditoria, #30), `AvockvHx`
(`meus_estabelecimentos`, #28) e `0uROtsRX` (testes de contrato, #29). O `yKUkCjSU` (testes
do ciclo) já estava Concluído com os quatro critérios marcados — as versões anteriores deste
arquivo o listavam como pendente, e estavam erradas.

**Os quatro cartões meus que continuam em Revisão, e por quê:**

| Cartão | O que falta, e de quem é |
|---|---|
| `RNOfNVVU` Portão de colisão de versão | Seis dos oito critérios marcados. Falta o push do #37 e o re-run da CI, que agora roda. O oitavo critério é o caminho verde do `demonstracao-remoto.sh`, que depende do token de conta |
| `7gpPBgTH` Contas de demonstração | Três dos quatro critérios medidos e as notas anexadas. O critério 1 diz "no `frila-dev`", e lá a porta ainda não existe. O caminho está pronto num comando — `./scripts/demonstracao-remoto.sh dev` faz os segredos, o deploy e a medição —, e falta só um `SUPABASE_ACCESS_TOKEN` que responda. **Bloqueio de credencial, e não de navegador** |
| `RTmRTHbo` Republicar vaga | Os três critérios de backend marcados, inclusive republicar a partir de vaga `encerrada`, medido por HTTP. O quarto é de ponta a ponta e depende da tela: a ação "Publicar de novo" em Minhas vagas. **É iOS** |
| `ggEzge6h` Filtro de texto | Os três critérios marcados, com a recusa e o falso positivo medidos por HTTP. **Um quarto item foi acrescentado à checklist**: a revisão da lista de termos pela Júlia, que estava em *O que fazer* e não era cobrada por critério nenhum — com três marcados o cartão fecharia com a lista nunca lida. **É da Júlia** |

A frase "Cortável, não começado" que este arquivo trazia sobre o `RTmRTHbo` estava errada: o
#26 já estava mergeado.

**Não há cartão de Backend livre e desbloqueado em 28/09.** O `NDx7TJ4d` (turnos não
verificados), que em 25/09 era o único, está **Em andamento com o João Paulo** e tem o PR #38.
O que a lista Em andamento tem de Backend é só ele; o resto é iOS e Infra de outras pessoas.
Antes de escolher trabalho novo, vale varrer o quadro de novo: ele mudou muito em três dias.

`./scripts/trello.sh` faz tudo: `ver`, `lista`, `pegar`, `revisao`, `concluir`, `comentar`.

## O contrato mudou de endereço

`FrilaApp/frila-docs` reorganizou o repositório por assunto: **`Documentos/API/openapi.yaml`
virou `api/openapi.yaml`**. O redirect do GitHub cobre o nome antigo da organização, mas
não cobre caminho dentro do repositório — quem tiver script ou marcador apontando para o
caminho antigo precisa ajustar. No backend, o PR #15 ajustou.

Versão vigente: **0.2.18**, espelhada em `contrato/openapi.yaml` e **em dia com o original**,
conferido em 28/09 com o `FRILA_DOCS_TOKEN`. A 0.2.18 veio no #45 do João Paulo e traz **401
para conta encerrada** nas RPCs de escrita.

> **O que aconteceu entre 25 e 28/09, e vale como lição.** Em 25/09 o espelho estava na 0.2.15
> e o original já na 0.2.17, e **nenhuma medição viu** — porque o `contrato-em-dia.sh` lia
> `FRILA_DOCS_TOKEN` só do ambiente, e as baterias não faziam `source .env`. Sem o token ele
> saía **0** avisando em voz alta que não conferiu o original: o único portão capaz de pegar
> "o contrato mudou lá e ninguém trouxe" era justamente o que estava passando. Consertado no
> PR #37: lê o `.env`, e sai **2** quando não há token. As 0.2.16 a 0.2.18 subiram com os PRs
> do João Paulo, como devia ser.

## O que existe no banco

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
fora", que este arquivo repetiu por dias, está morta. Três jobs ativos, medidos em 28/09:

| Job | Quando |
|---|---|
| `reprocessar_despacho` | `* * * * *` — a cada minuto |
| `limpar_dispositivos_inativos` | `17 6 * * *` |
| `retencao_e_limpeza_diaria` | `30 6 * * *` |

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
| `./scripts/migracoes-sem-colisao.sh` | duas migrações não têm a mesma versão | as **46** versões distintas · **novo, no PR #37 aberto** — nasceu depois de a colisão matar um `db reset` de verdade |

Todos rodam na CI menos o advisor, que exige token de conta. O `migracoes-sem-colisao.sh` só
existe no branch do #37 até ele entrar.

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

> ⚠️ **Esta seção é de 25/09 e não foi reconferida em 28/09.** O `main` ganhou oito PRs nesses
> três dias — motor de despacho, push, `excluir_conta`, retenção, índices — e cada um pode ter
> fechado, criado ou mudado uma divergência daqui. O que está abaixo era verdade quando foi
> medido; nenhuma linha foi remedida depois. Antes de citar qualquer uma como fato atual,
> meça.

Cinco colunas do esquema não estão na Modelagem de Banco. Todas nasceram de uma RPC, e
quem precisa reconciliar é o documento:

| Coluna | Por quê |
|---|---|
| `vaga.publicado_por` | um estabelecimento tem vários membros, e RF04 pergunta quem publicou |
| `usuario.demonstracao` | conta de revisão da App Store; as duas populações dividem o banco sem se enxergar |
| `turno.checkin_recebido_em` | `checkin_em` é a hora do **toque**; sem as duas, registro offline vira indistinguível |
| `turno.checkout_recebido_em` | o mesmo, do outro lado |
| `posicao.reaberta_por_atraso_de` | `reabrir_por_atraso` (e8XpOZJN, 28/09): a posição nova sabe de qual falta nasceu; é ela que aceita candidato depois do início, até 1 h antes do fim (8zLfn0mt item 5) |

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
   está na sessão de 25/09.
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
5. ~~**Aplicar as migrações novas no `frila-dev`.**~~ **Resolvido em 24/09**: as 29 estão lá (ver Ambientes).
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

**O passo imediato, e é de dois minutos:** `git push` do branch `s0/migracoes-sem-colisao` e
o re-run da CI no **#37**. O `main` já está fundido no branch, sem conflito, e a bateria foi
medida em 28/09. O que segurava o merge — o espelho atrasado — não existe mais.

Depois disso, em ordem:

1. **Varrer o quadro antes de escolher trabalho.** Ele mudou muito em três dias: seis cartões
   de Sprint 2 e 3 entraram em Revisão, e o `NDx7TJ4d`, que era o único livre de Backend,
   está com o João Paulo. Qualquer lista deste arquivo sobre "o que está livre" envelhece em
   um dia — `./scripts/trello.sh lista revisao` e `lista andamento` são a fonte.
2. `7gpPBgTH` — contas de demonstração. O que falta é **fora do código**: o segredo
   `DEMONSTRACAO_EMAILS`/`DEMONSTRACAO_CODIGO` no `frila-dev` e no `frila-prod`, e o
   `functions deploy`. **Não precisa de `supabase login` interativo** — a CLI aceita
   `SUPABASE_ACCESS_TOKEN` do ambiente e o `.env` já tem a variável; falta o valor, porque o
   atual responde 401. Com um token novo colado no `.env`,
   `./scripts/demonstracao-remoto.sh dev` faz os três passos e mede o resultado por HTTP.
3. **Os três cartões meus travados por outra pessoa** — `RTmRTHbo` (a tela do iOS), `ggEzge6h`
   (a revisão da lista pela Júlia) e o quarto critério do `7gpPBgTH`. Nenhum deles avança
   aqui; todos têm o motivo escrito no cartão.
4. **O molde de fechamento de cartão**, que vale repetir e não reinventar: um item da
   checklist por asserção nomeada, com o arquivo; e medição por HTTP quando o critério fala em
   status, porque o pgTAP alcança `sqlstate` e `code` e não o status. Está nos comentários do
   `6mdX80SC`, `AvockvHx`, `0uROtsRX`, `RTmRTHbo`, `ggEzge6h` e `RNOfNVVU`.
5. Toda RPC nova nasce com quatro coisas, e nenhuma é negociável: o filtro de texto nos
   campos livres, a recusa correspondente no `ciclo-completo.sh`, a linha no
   `openapi.yaml` com a versão subindo, e a asserção de mutação que morre quando a regra
   some. O portão do contrato cobra a terceira; as outras três dependem de quem escreve.
6. **E antes de rodar a bateria à mão: o segredo do agendador.** Ver a armadilha na seção *O
   que existe no banco*. Sem ele, dois portões saem vermelhos por motivo que não é código.
