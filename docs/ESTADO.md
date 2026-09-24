# Estado do backend — 24/09/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

**O ciclo principal do Sprint 1 fecha de ponta a ponta no `main`:** publicar → candidatar
→ acompanhar → contato → check-in → check-out → cancelar. Falta `avaliar`, que está com o
João Paulo, e o despacho, que é o Sprint 2.

Dezoito RPCs no ar, 29 migrações, e o contrato em **0.2.11**. **Dezenove PRs mergeados e
nenhum aberto** — o #22, dos cancelamentos, entrou às 12:13 de 24/09.

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · **29** migrações no `main` (contadas em 24/09) |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` |
| `frila-prod` | não existe. Sprint 3 |

**O `frila-dev` ficou para trás.** Ele tem as migrações até o branch `s0/criar-conta`,
aplicadas por `scripts/aplicar-remoto.sh` em 22/09; tudo o que entrou depois — filtro de
texto, perfil profissional, estabelecimento, painel e `publicar_vaga` — está só no
`main` e no ambiente local. Antes de aplicar lá, conferir
`supabase_migrations.schema_migrations` do projeto.

As credenciais estão no `.env` local (fora do git).

## O quadro

Todos os cartões de Backend do Sprint 0 e do Sprint 1 já mergeados estão **Concluídos** —
`wSoltQDy` (cancelamentos) fechou em 24/09 com o #22. Ficaram cinco:

| Cartão | Por quê |
|---|---|
| `ggEzge6h` Filtro de texto ofensivo | **Revisão** · o código está no `main`; falta a revisão da Júlia na lista de termos |
| `7gpPBgTH` Contas de demonstração | a marca no banco já existe; falta a Edge Function, o segredo e as notas da revisão |
| `zdCpLEVs` `avaliar` e `perfil_publico` | em andamento com o João Paulo |
| `RTmRTHbo` Republicar vaga | Cortável, não começado |
| `yKUkCjSU` Testes do ciclo (QA) | o que ele pede já existe em pgTAP e no ciclo por HTTP; vale reler antes de refazer |

`./scripts/trello.sh` faz tudo: `ver`, `lista`, `pegar`, `revisao`, `concluir`, `comentar`.

## O contrato mudou de endereço

`FrilaApp/frila-docs` reorganizou o repositório por assunto: **`Documentos/API/openapi.yaml`
virou `api/openapi.yaml`**. O redirect do GitHub cobre o nome antigo da organização, mas
não cobre caminho dentro do repositório — quem tiver script ou marcador apontando para o
caminho antigo precisa ajustar. No backend, o PR #15 ajustou.

Versão vigente: **0.2.5**, espelhada em `contrato/openapi.yaml` e conferida pelo portão.

## O que existe no banco

19 tabelas em `public`, 30 restrições `CHECK`, 1 de exclusão (RN21), 19 políticas de
leitura, 39 auxiliares no schema `privado`, e nenhuma política de escrita em lugar
nenhum — toda escrita passa por função `security definer`.

**Dezoito RPCs expostas**, que cobrem o ciclo inteiro menos a avaliação:

```
conta        criar_conta · minha_conta
perfil       criar_perfil_profissional · meu_perfil_profissional · atualizar_perfil_profissional
casa         cadastrar_estabelecimento · painel_estabelecimento
vaga         publicar_vaga · vagas_abertas · detalhe_vaga · cancelar_vaga
turno        candidatar · meus_turnos · contato_do_turno · cancelar_posicao
presença     fazer_checkin · fazer_checkout · confirmar_checkin_manual
```

Falta do ciclo: `avaliar` (com o João Paulo) e tudo do despacho, que é o Sprint 2.

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

Medidos na máquina em 24/09, no branch dos cancelamentos, com `db reset` antes:

| Comando | O que garante | Medida |
|---|---|---|
| `supabase test db` | pgTAP | **540** asserções em 22 arquivos |
| `./scripts/mutacao.sh` | cada regra morre sem teste | **74** cobertas, 0 sem cobertura |
| `./scripts/ciclo-completo.sh` | o fluxo por HTTP, com status **e** código | 52 asserções, até as recusas da presença |
| `./scripts/corrida-candidatar.sh` | RN19 sob concorrência | 20 conexões, 2 posições, 2 confirmações |
| `./scripts/contrato-acompanha-o-codigo.sh` | PR que mexe em `public` leva o contrato | 0.2.10 → 0.2.11 |
| `./scripts/contrato-em-dia.sh` | o espelho não divergiu do original | espelho 0.2.11 idêntico |
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

Quatro colunas do esquema não estão na Modelagem de Banco. Todas nasceram de uma RPC, e
quem precisa reconciliar é o documento:

| Coluna | Por quê |
|---|---|
| `vaga.publicado_por` | um estabelecimento tem vários membros, e RF04 pergunta quem publicou |
| `usuario.demonstracao` | conta de revisão da App Store; as duas populações dividem o banco sem se enxergar |
| `turno.checkin_recebido_em` | `checkin_em` é a hora do **toque**; sem as duas, registro offline vira indistinguível |
| `turno.checkout_recebido_em` | o mesmo, do outro lado |

E mais estas:

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
   ninguém. Depende de alguém presente: o comando abre o navegador.
2. **PAT com leitura em `FrilaApp/frila-docs`**, gravado como secret `FRILA_DOCS_TOKEN`.
   Na máquina o portão do contrato compara com o original de verdade (medido em 24/09);
   na CI, sem o secret, ele confere só a integridade do espelho e avisa em voz alta.
   Fine-grained, *Resource owner* `FrilaApp`, *Only select repositories* → `frila-docs`,
   *Contents: Read-only*. Medido em 24/09: `gh secret list` do repositório está **vazio**,
   `FrilaApp/frila-docs` é **privado**, e a única org da conta `silvaaszx` é `FrilaApp` —
   tela de criação de token que ainda mostre `BlendOps` como *Resource owner* é anterior
   à renomeação de 23/09 e produz um token que não lê nada.
   **Ressalva:** sem token, `contrato-em-dia.sh` sai com **0** (linha 58), e isso
   contraria a regra dos portões — caminho que não mediu tem de sair diferente de zero.
   Enquanto o secret não existir, o portão avisa mas não reprova.
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
