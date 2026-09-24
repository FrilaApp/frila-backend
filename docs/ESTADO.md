# Estado do backend — 24/09/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

**O ciclo do Sprint 1 fecha inteiro no `main`:** publicar → candidatar → acompanhar →
contato → check-in → check-out → cancelar → **avaliar**. Falta só o despacho, que é o
Sprint 2.

Vinte RPCs, 30 migrações, e o contrato em **0.2.12**.

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

Todos os cartões de Backend do Sprint 0 e do Sprint 1 já mergeados estão **Concluídos** —
`wSoltQDy` (cancelamentos) fechou em 24/09 com o #22. Ficaram cinco:

| Cartão | Por quê |
|---|---|
| `ggEzge6h` Filtro de texto ofensivo | **Revisão** · o código está no `main`; falta a revisão da Júlia na lista de termos |
| `7gpPBgTH` Contas de demonstração | a marca no banco já existe; falta a Edge Function, o segredo e as notas da revisão |
| `RTmRTHbo` Republicar vaga | Cortável, não começado |
| `yKUkCjSU` Testes do ciclo (QA) | o que ele pede já existe em pgTAP e no ciclo por HTTP; vale reler antes de refazer |

`./scripts/trello.sh` faz tudo: `ver`, `lista`, `pegar`, `revisao`, `concluir`, `comentar`.

## O contrato mudou de endereço

`FrilaApp/frila-docs` reorganizou o repositório por assunto: **`Documentos/API/openapi.yaml`
virou `api/openapi.yaml`**. O redirect do GitHub cobre o nome antigo da organização, mas
não cobre caminho dentro do repositório — quem tiver script ou marcador apontando para o
caminho antigo precisa ajustar. No backend, o PR #15 ajustou.

Versão vigente: **0.2.12**, espelhada em `contrato/openapi.yaml` e conferida pelo portão
contra o original de verdade desde 24/09.

## O que existe no banco

19 tabelas em `public`, 30 restrições `CHECK`, 1 de exclusão (RN21), 19 políticas de
leitura, 39 auxiliares no schema `privado`, e nenhuma política de escrita em lugar
nenhum — toda escrita passa por função `security definer`.

**Vinte RPCs expostas**, que cobrem o ciclo inteiro:

```
conta        criar_conta · minha_conta
perfil       criar_perfil_profissional · meu_perfil_profissional · atualizar_perfil_profissional
casa         cadastrar_estabelecimento · painel_estabelecimento
vaga         publicar_vaga · vagas_abertas · detalhe_vaga · cancelar_vaga
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
| `supabase test db` | pgTAP | **612** asserções em 24 arquivos, em 5 a 7 s na CI |
| `./scripts/mutacao.sh` | cada regra morre sem teste | **75** cobertas, 0 sem cobertura |
| `./scripts/ciclo-completo.sh` | o fluxo por HTTP, com status **e** código | 58 asserções, até o perfil público |
| `./scripts/demonstracao.sh` | a porta da revisão da App Store, por HTTP | 10 conferências, com o teto de tentativas |
| `./scripts/corrida-candidatar.sh` | RN19 sob concorrência | 20 conexões, 2 posições, 2 confirmações |
| `./scripts/contrato-acompanha-o-codigo.sh` | PR que mexe em `public` leva o contrato | 0.2.11 → 0.2.12 |
| `./scripts/contrato-em-dia.sh` | o espelho não divergiu do original | espelho 0.2.12 idêntico ao original, conferido com o token |
| `./scripts/lint-conhecido.sh` | `plpgsql_check` | sem achado novo |
| `./scripts/relogio-do-produto.sh` | nenhuma função usa `now()` direto | só `privado.agora()` |
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
- **`vagas_abertas` e `meus_turnos` devolvem array, e não objeto com chave.** Custou duas
  rodadas vermelhas ao escrever o teste de ciclo. O contrato descreve as duas como lista;
  quem escrever teste novo não deve procurar `->'vagas'` nem `->'turnos'`.
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

1. **`supabase login`.** O `SUPABASE_ACCESS_TOKEN` do `.env` responde **401** na
   Management API. Sem ele o advisor de segurança do `frila-dev` não é verificado por
   ninguém. Depende de alguém presente: o comando abre o navegador. Em 24/09 o advisor
   rodou pelo MCP do Supabase, que tem acesso à organização, mas o script continua sem token.
2. ~~**PAT com leitura em `FrilaApp/frila-docs`.**~~ **Resolvido em 24/09.** O secret
   `FRILA_DOCS_TOKEN` existe no repositório e o portão passou a conferir o original de
   verdade: `./scripts/contrato-em-dia.sh` com o token respondeu *"Espelho em dia com
   FrilaApp/frila-docs"* sobre o contrato 0.2.11. Fine-grained, *Resource owner*
   `FrilaApp`, *Contents: Read-only*, validade até 23/09/2027.
   **O que continua aberto:** sem token, `contrato-em-dia.sh` sai com **0** (linha 58),
   e isso contraria a regra dos portões — caminho que não mediu tem de sair diferente de
   zero. Hoje o secret existe e o ponto é teórico; quando o PAT vencer, em 23/09/2027, o
   portão volta a ficar verde sem ter medido nada e ninguém vai saber. A correção é do
   tamanho de uma linha e não entrou junto porque pertence a outro cartão.
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

## Por onde continuar

1. `7gpPBgTH` — contas de demonstração. A marca `usuario.demonstracao` e o isolamento nas
   leituras já existem; falta a Edge Function `entrar-demonstracao` com o código fixo em
   segredo, o seed das duas contas e as notas da revisão. **É o próximo cartão de código
   livre**, já que o `zdCpLEVs` está com o João Paulo.
2. `zdCpLEVs` — `avaliar` e `perfil_publico` com reputação, que está com o João Paulo. É
   a última peça do ciclo antes do despacho.
3. **Sprint 2, o despacho.** A fila já recebe as duas mensagens que o motor vai consumir:
   `{vaga_id, publicada_em}` na publicação e `{vaga_id, posicao_id, motivo: reabertura,
   excluir_conta}` no cancelamento. `pg_cron` e `pg_net` entram com ele.
4. Toda RPC nova nasce com quatro coisas, e nenhuma é negociável: o filtro de texto nos
   campos livres, a recusa correspondente no `ciclo-completo.sh`, a linha no
   `openapi.yaml` com a versão subindo, e a asserção de mutação que morre quando a regra
   some. O portão do contrato cobra a terceira; as outras três dependem de quem escreve.
