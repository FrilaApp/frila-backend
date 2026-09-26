# Estado do backend — 25/09/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

**O ciclo do Sprint 1 fecha inteiro no `main`:** publicar → candidatar → acompanhar →
contato → check-in → check-out → cancelar → **avaliar**. Falta só o despacho, que é o
Sprint 2.

Vinte e duas RPCs, 36 migrações, e o contrato em **0.2.15**.

> ## ⛔ A CI não inicia, e é Billing da organização
>
> **Medido em 25/09, às 18:40**, e este é o diagnóstico que substitui o de 15:53. A
> anotação do GitHub é literal, nos três jobs de todos os PRs:
>
> > The job was not started because recent account payments have failed or your spending
> > limit needs to be increased. Please check the 'Billing & plans' section in your
> > settings
>
> Não é intermitência, não é o `ci.yml` e não é "cota esgotada" no sentido genérico: o
> GitHub está dizendo que o **limite de gasto** impede o job de começar. `gh api
> /orgs/FrilaApp` devolve `plan.name: free`, e no plano free o Actions só é ilimitado em
> repositório **público** — os quatro da organização são privados, então cada minuto sai
> de uma cota mensal, e com o limite de gasto padrão de US$ 0 os jobs param de iniciar
> exatamente assim.
>
> **Não medido:** a página de Billing exige escopo `admin:org`, que o token desta máquina
> não tem. A data da virada do ciclo de cobrança continua desconhecida.
>
> O conserto é da organização: subir o limite de gasto, ou esperar a virada. Depois disso,
> um `gh run rerun <id> --failed` em cada PR aberto.
>
> **Enquanto isso, o que entra no `main` entra com prova local.** Foi a decisão de 25/09:
> a bateria inteira do `ci.yml` rodada na máquina, com `db reset` antes, e o placar colado
> no PR e no cartão. Vale para os PRs de quem mediu; PR de outra pessoa continua com ela.

## Onde cada coisa parou em 25/09

Mergeado em 25/09 com prova local no lugar do portão remoto:

| PR | Cartão | Merge |
|---|---|---|
| **#30** `s3/trilha-de-auditoria` | `6mdX80SC` | `2947a5c8`, às 19:10Z. 12 portões verdes na máquina; cartão **Concluído** |
| **#36** `s1/janela-da-demonstracao` | `7gpPBgTH` | `ed0c6456`. A janela do registro não se aplica à conta de revisão, e as notas da revisão em português e inglês. 12 portões verdes |

Abertos, e nenhum é meu:

| PR | Cartão | De quem |
|---|---|---|
| **#27** `s0/despachar-porta` | `ZqmkOaHn` | Cauê |
| **#31** `s0/configuracao-do-app` | `CvopSHh6` | João Paulo |
| **#32** `s2/notificacoes` | `wM63y4qx` | João Paulo |
| **#34** `s0/corrigir-bancada-sync` | `nNUtbriv` | João Paulo |
| **#35** `ao/frila-8` | — | Cauê |

Mergeados antes em 25/09: **#23** (contas de demonstração), **#24** (`avaliar` e
`perfil_publico`), **#25** (testes do ciclo), **#26** (`republicar_vaga`), **#28**
(`meus_estabelecimentos`), **#29** (testes de contrato). No `frila-docs`: **0.2.12** a
**0.2.15**, e a **0.2.14** é do João Paulo.

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · **29** migrações no `main` (contadas em 24/09) |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` · **29** migrações, as mesmas do `main` (conferidas em 24/09) |
| `frila-prod` | `hbjkkcenbudiezmamiak` · `sa-east-1` · criado em 24/09, **vazio**: as migrações entram pelo cartão do ambiente de produção (29/10), com a entrega contínua por tag |

**O `frila-dev` está em dia com o `main`.** As 11 migrações que faltavam, de
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

**A lista Revisão foi varrida e esvaziada do que era fechável**, em 25/09. Ela tinha onze
cartões e ficou com nove; o gargalo não era o código, era checklist não marcada. Cada um
recebeu no cartão a evidência item a item — o arquivo de teste e o nome da asserção, mais a
medição por HTTP onde o critério pedia status.

Fecharam em 25/09: `6mdX80SC` (trilha de auditoria, #30), `AvockvHx`
(`meus_estabelecimentos`, #28) e `0uROtsRX` (testes de contrato, #29). O `yKUkCjSU` (testes
do ciclo) já estava Concluído com os quatro critérios marcados — as versões anteriores deste
arquivo o listavam como pendente, e estavam erradas.

**O que sobrou de Backend na Revisão, e por quê:**

| Cartão | O que falta, e de quem é |
|---|---|
| `7gpPBgTH` Contas de demonstração | Três dos quatro critérios medidos e as notas anexadas. O critério 1 diz "no `frila-dev`", e lá a porta ainda não existe. O caminho está pronto num comando — `./scripts/demonstracao-remoto.sh dev` faz os segredos, o deploy e a medição —, e falta só um `SUPABASE_ACCESS_TOKEN` que responda. **Bloqueio de credencial, e não de navegador** |
| `RTmRTHbo` Republicar vaga | Os três critérios de backend marcados, inclusive republicar a partir de vaga `encerrada`, medido por HTTP. O quarto é de ponta a ponta e depende da tela: a ação "Publicar de novo" em Minhas vagas. **É iOS** |
| `ggEzge6h` Filtro de texto | Os três critérios marcados, com a recusa e o falso positivo medidos por HTTP. **Acrescentei um quarto item à checklist**: a revisão da lista de termos pela Júlia, que estava em *O que fazer* e não era cobrada por critério nenhum — com três marcados o cartão fecharia com a lista nunca lida. **É da Júlia** |
| `CvopSHh6` Versão mínima do app | Do João Paulo, no #31 |
| `wM63y4qx` Notificações | Do João Paulo, no #32. É de onde descem quatorze dos dezenove cartões de Backend do Sprint 2 |

A frase "Cortável, não começado" que este arquivo trazia sobre o `RTmRTHbo` estava errada: o
#26 já estava mergeado.

`./scripts/trello.sh` faz tudo: `ver`, `lista`, `pegar`, `revisao`, `concluir`, `comentar`.

## O contrato mudou de endereço

`FrilaApp/frila-docs` reorganizou o repositório por assunto: **`Documentos/API/openapi.yaml`
virou `api/openapi.yaml`**. O redirect do GitHub cobre o nome antigo da organização, mas
não cobre caminho dentro do repositório — quem tiver script ou marcador apontando para o
caminho antigo precisa ajustar. No backend, o PR #15 ajustou.

Versão espelhada em `contrato/openapi.yaml`: **0.2.15**. Versão no `FrilaApp/frila-docs`:
**0.2.17**.

> ⚠️ **O espelho está atrasado em duas versões.** Medido em 25/09 às 17h32, com o
> `FRILA_DOCS_TOKEN` do `.env`, que responde 200: `./scripts/contrato-em-dia.sh` sai **1**
> com o diff das 0.2.16 (`configuracao_do_app`) e 0.2.17 (as notificações da 0.2.14 passando
> a existir no backend).
>
> As duas são do João Paulo, e os PRs **#31** e **#32** dele já trazem o espelho — então ele
> sobe com eles, e não deve ser espelhado por fora: seria conflito garantido. O que importa
> saber: **quando o Actions voltar, o job `Contrato em dia com o Frila` reprova em todo PR**
> até um dos dois entrar.
>
> Isso passou batido nas medições de 25/09 porque o portão lê `FRILA_DOCS_TOKEN` do
> ambiente, e nenhuma delas fez `source .env` antes. Sem o token ele sai **0** avisando que
> não conferiu o original — o buraco da pendência 2, que aqui deixou de ser teórico.

## O que existe no banco

19 tabelas em `public`, 30 restrições `CHECK`, 1 de exclusão (RN21), 19 políticas de
leitura, 39 auxiliares no schema `privado`, e nenhuma política de escrita em lugar
nenhum — toda escrita passa por função `security definer`.

**Vinte e duas RPCs expostas a `authenticated`**, que cobrem o ciclo inteiro. Contadas em
25/09 com `has_function_privilege`, e não pela lista escrita à mão — as duas versões
anteriores deste arquivo diziam vinte e já estavam atrasadas:

```
conta        criar_conta · minha_conta
perfil       criar_perfil_profissional · meu_perfil_profissional · atualizar_perfil_profissional
casa         cadastrar_estabelecimento · painel_estabelecimento · meus_estabelecimentos
vaga         publicar_vaga · republicar_vaga · vagas_abertas · detalhe_vaga · cancelar_vaga
turno        candidatar · meus_turnos · contato_do_turno · cancelar_posicao
presença     fazer_checkin · fazer_checkout · confirmar_checkin_manual
reputação    avaliar · perfil_publico
```

Falta do ciclo: nada. O despacho é o Sprint 2.

**A fila existe.** `pgmq.q_despacho` recebe `{vaga_id, publicada_em}` na publicação e
`{vaga_id, posicao_id, motivo: reabertura, excluir_conta}` no cancelamento — o
`excluir_conta` é quem **não** deve ser notificado de novo. RLS ligada e sem política.
`pg_cron` e `pg_net` continuam fora.

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

Medidos na máquina em 24/09 e 25/09, no branch das contas de demonstração já com a
`main` fundida, com `db reset` antes:

| Comando | O que garante | Medida |
|---|---|---|
| `supabase test db` | pgTAP | **671** asserções em 28 arquivos, em 1 a 3 s na máquina |
| `./scripts/mutacao.sh` | cada regra morre sem teste | **84** cobertas, 0 sem cobertura |
| `./scripts/ciclo-completo.sh` | o fluxo por HTTP, com status **e** código | 58 asserções, até o perfil público |
| `./scripts/demonstracao.sh` | a porta da revisão da App Store, por HTTP | **15** conferências: a porta, o que ela recusa, os dados semeados, **o ciclo da presença inteiro** e o teto de tentativas |
| `./scripts/corrida-candidatar.sh` | RN19 sob concorrência | 20 conexões, 2 posições, 2 confirmações |
| `./scripts/contrato-acompanha-o-codigo.sh` | PR que mexe em `public` leva o contrato | 0.2.14 → 0.2.15 |
| `./scripts/contrato-em-dia.sh` | o espelho não divergiu do original | 🔴 **vermelho**: espelho 0.2.15, original 0.2.17. O conserto vem nos PRs #31 e #32 do João Paulo, que já trazem o espelho. Desde 25/09 o script lê o `.env` e sai **2** quando não tem token, em vez de 0 |
| `./scripts/lint-conhecido.sh` | `plpgsql_check` | sem achado novo |
| `./scripts/relogio-do-produto.sh` | nenhuma função usa `now()` direto | só `privado.agora()` |
| `./scripts/contrato-responde.sh` | a resposta de cada RPC casa com o schema | 22 corpos e 7 envelopes, 18 operações ainda sem implementação |
| `./scripts/advisor-conhecido.sh` | advisor do Supabase | **não roda**: token vencido |
| `./scripts/migracoes-imutaveis.sh` | nenhuma migração aplicada foi editada | verde |
| `./scripts/migracoes-sem-colisao.sh` | duas migrações não têm a mesma versão | as 36 versões distintas · **novo em 25/09**, depois de a colisão matar um `db reset` de verdade |

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

Quatro colunas do esquema não estão na Modelagem de Banco. Todas nasceram de uma RPC, e
quem precisa reconciliar é o documento:

| Coluna | Por quê |
|---|---|
| `vaga.publicado_por` | um estabelecimento tem vários membros, e RF04 pergunta quem publicou |
| `usuario.demonstracao` | conta de revisão da App Store; as duas populações dividem o banco sem se enxergar |
| `turno.checkin_recebido_em` | `checkin_em` é a hora do **toque**; sem as duas, registro offline vira indistinguível |
| `turno.checkout_recebido_em` | o mesmo, do outro lado |

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
8. **Billing do Actions na organização `FrilaApp`.** É o que mantém a CI parada, e ninguém
   deste repositório resolve: precisa de quem tem acesso a *Billing & plans* da
   organização. Ver o bloco no topo deste arquivo.
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

1. **A Revisão já foi varrida** em 25/09, e o que sobrou de Backend está bloqueado por
   presença ou é de outra pessoa — ver a seção *O quadro*. O molde de fechamento está nos
   comentários que o `6mdX80SC`, o `AvockvHx`, o `0uROtsRX`, o `RTmRTHbo` e o `ggEzge6h`
   receberam: um item da checklist por asserção nomeada, com o arquivo; e medição por HTTP
   quando o critério fala em status, porque o pgTAP alcança `sqlstate` e `code` e não o
   status. Vale repetir o molde em cartão novo, e não reinventá-lo.
2. `7gpPBgTH` — contas de demonstração. O que falta é **fora do código**: o segredo
   `DEMONSTRACAO_EMAILS`/`DEMONSTRACAO_CODIGO` no `frila-dev` e no `frila-prod` e o
   `functions deploy`, os dois por `supabase secrets set`, que pedem `supabase login` — e o
   token do `.env` responde 401. O critério 1 da checklist diz "no frila-dev": até o segredo
   entrar lá, ele está medido só na máquina.
3. **Sprint 2, o despacho.** Mas não os cartões: varridos em 25/09, quatorze dos dezenove
   cartões de Backend do Sprint 2 descem de `wM63y4qx` (notificações), que está com o João
   Paulo no #32, e `7XS6MQGg` (motor de despacho) é do Cauê por escrito no corpo do #27.
   Livre e desbloqueado sobrou `NDx7TJ4d` (turnos não verificados e taxa de comparecimento),
   e dois dos cinco critérios dele dependem de uma decisão de produto que não existe
   (`8zLfn0mt`) e do `pg_cron`, que entra com o motor.
   A fila já recebe as duas mensagens que o motor vai consumir:
   `{vaga_id, publicada_em}` na publicação e `{vaga_id, posicao_id, motivo: reabertura,
   excluir_conta}` no cancelamento. `pg_cron` e `pg_net` entram com ele.
5. Toda RPC nova nasce com quatro coisas, e nenhuma é negociável: o filtro de texto nos
   campos livres, a recusa correspondente no `ciclo-completo.sh`, a linha no
   `openapi.yaml` com a versão subindo, e a asserção de mutação que morre quando a regra
   some. O portão do contrato cobra a terceira; as outras três dependem de quem escreve.
