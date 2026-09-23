# Estado do backend — 23/09/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

O esquema está de pé e fechado, a entrada por código funciona de ponta a ponta, o banco
nasce povoado com cenários que cobrem a RN05, o contrato fechou as divergências com o
quadro e o primeiro cartão do Sprint 1 está feito.

**O Sprint 0 de Backend está fechado do lado de cá:** cinco cartões em Revisão, e o
sexto (`CvopSHh6`, versão mínima do app) é do João Paulo — `configuracao_do_app` já está
no contrato esperando por ele. No Sprint 1, `jSOAe6OL` (perfil profissional) também está
em Revisão.

**Nove PRs abertos, nenhum mergeado.** Seis no backend e três no `frila-docs`, quase
todos empilhados — ver *Os PRs*.

**A organização mudou de nome:** `BlendOps` virou `FrilaApp`, e `Frila` virou
`frila-docs`. O GitHub redireciona, então nada quebrou; as referências deste repositório
foram atualizadas no PR #10.

**A CI não rodou um teste sequer em 23/09.** Cinco execuções em três branches caíram em
`toomanyrequests` do `ghcr.io` antes de subir o ambiente. Tudo o que está afirmado aqui
foi medido na máquina, com a saída olhada.

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · 19 migrações no `main`, 20 com o filtro |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` · org `Frila'orgs` |
| `frila-prod` | não existe. Sprint 3 |

**O `frila-dev` está adiantado em relação ao `main`**: ele já tem as migrações do branch
`s0/criar-conta`, aplicadas por `scripts/aplicar-remoto.sh`. Se uma revisão mudar um
arquivo de migração já aplicado lá, vai precisar de conserto manual — a tabela
`supabase_migrations.schema_migrations` do projeto tem o registro.

As credenciais estão no `.env` local (fora do git). O `SUPABASE_ACCESS_TOKEN` é de conta
inteira: serve para a Management API e para o advisor, e não precisa no dia a dia.

## O quadro

| Cartão | Estado |
|---|---|
| `JuD3ytg1` Migrações iniciais | **Concluído** · PR #1 |
| `v7b5sLYv` Políticas de acesso (RLS) | **Concluído** · PR #2 |
| `MPFZagWG` Entrada por código e `criar_conta` | **Concluído** · PR #3 |
| `Cc2XYCi0` Dados de teste e cenários | **Revisão** · PR #4 |
| `jSOAe6OL` Perfil profissional (S1) | **Revisão** · PR #9 e frila-docs#4 |
| `oUwDEP8Q` Contrato (saiu como 0.2.2) | **Revisão** · PR #7 e frila-docs#2 |
| `ggEzge6h` Filtro de texto ofensivo | **Revisão** · PR #8 e Frila#3 · *falta a revisão da Júlia na lista* |
| `CvopSHh6` Versão mínima do app | do João Paulo · em andamento com ele. `configuracao_do_app` já está no contrato |

Onze cartões de iOS entraram em "Em andamento" na madrugada de 23/09. Dois deles
consomem o contrato: `bP2WKgG0` (dublês da API) e `9FRaLndF` (cliente da API). Os dois
foram avisados por comentário da troca de `alvo_usuario_id` por `alvo_tipo` + `alvo_id`.

## Os PRs

Três pilhas. A ordem de merge importa: mergear o espelho antes do contrato deixa o
espelho à frente do original.

```
frila-docs#2      contrato 0.2.2           ← mergear primeiro
  └ #3            contrato 0.2.3
    └ #4          contrato 0.2.4

frila-backend#4   cenários                  ← independente, pode ir a qualquer hora
frila-backend#5   ponte com a Bancada       ← independente
frila-backend#7   espelho 0.2.2 + portão    ← só depois de frila-docs#2
  └ #8            filtro de texto           ← só depois de frila-docs#3
    └ #9          perfil profissional       ← só depois de frila-docs#4
      └ #10       referências da org        ← por último
```

Mergear um espelho antes do contrato correspondente deixa o espelho à frente do
original, e é o estado que `contrato-em-dia.sh` existe para pegar — só que ele não
consegue, porque o `FRILA_DOCS_TOKEN` não existe.

**A ponte (#5) depende de um push no `FrilaApp/Bancada`**, que exige Touch ID: a forma
`externo` do `registrar-fato.sh` mora lá.

`./scripts/trello.sh` faz tudo: `ver`, `lista`, `pegar`, `revisao`, `concluir`, `comentar`.

**Caminho crítico**, apontado pela auditoria do quadro: `oUwDEP8Q` (contrato 0.2.1) é o
único cartão de Backend cuja dependência está com outra pessoa, e ele trava também o
`bP2WKgG0` do iOS. Vence 02/10. A parte de `supabase/` da CI que o `MwtmdDQ9` pediria já
está construída — está comentado no cartão, para o Cauê não recomeçar.

## O que existe no banco

19 tabelas em `public`, 31 restrições `CHECK`, 1 de exclusão (RN21), 3 triggers, 19
políticas de leitura, 14 auxiliares no schema `privado`, e nenhuma política de escrita em
lugar nenhum — toda escrita passa por função `security definer`.

`privado` ganhou a primeira tabela: `termo_bloqueado`, a lista do filtro da diretriz 1.2.
Ela não tem política de leitura, por decisão — publicar a lista é publicar o mapa de como
contorná-la.

Depois do `db reset` o banco **não nasce vazio**: `cenarios.sql` põe 12 profissionais, 4
contratantes, 3 estabelecimentos, 7 vagas, 7 turnos, 6 avaliações, 1 bloqueio e 2
ocorrências. Teste novo que consulte `public.vaga` ou `public.turno` sem filtro está
medindo o cenário junto — três asserções já precisaram de escopo por isso. O mapa está em
[`supabase/README.md`](../supabase/README.md).

RPCs prontas: `criar_conta`, `minha_conta`, `criar_perfil_profissional`,
`meu_perfil_profissional`, `atualizar_perfil_profissional`. As do ciclo (publicar,
candidatar, check-in, avaliar…) ainda não existem.

**O molde das RPCs de escrita já está fixado** pelas três do perfil, e vale copiar:
`auth.uid()` na primeira linha, `privado.exigir_perfil` na segunda — a recusa de perfil
vem antes de qualquer escrita, senão sobra linha órfã quando a validação seguinte
falhar —, validação devolvendo o código do contrato com o campo em `details`, e a
resposta moldada por uma função `…_em_json` separada, porque três cópias divergem na
primeira mudança de campo.

Os auxiliares de conversão também já existem: `privado.ponto_do_json` e
`privado.ponto_em_json` traduzem entre a `Coordenada` do contrato e `geography`, e
`privado.gravar_funcoes` e `privado.gravar_disponibilidade` substituem lista inteira.

**O filtro de texto já existe e o primeiro ponto de uso é `criar_conta`.** Toda RPC nova
que aceite texto livre — `publicar_vaga`, `republicar_vaga`, `cadastrar_estabelecimento`
— tem de chamar `privado.texto_aceitavel` e recusar com `422 campo_invalido`, com o campo
no `details`. Não é opcional: é a diretriz 1.2 da App Store, e a recusa de cada RPC entra
no `ciclo-completo.sh`, porque o pgTAP vê o código e não vê o status.

**`privado.agora()` é o relógio do produto.** Todo prazo passa por ele: os 7 dias do
contato (RN10), o fim previsto que libera a avaliação (RN07), as 24 h do modo seleção
(RN24). Sobreponível por `frila.agora` **apenas** quando `privado.ambiente` tem a linha
de teste — e essa linha não é gravada por arquivo nenhum do repositório: quem a escreve é
o teste, dentro da transação. Nenhuma RPC nova deve usar `now()` direto.

## Os portões

| Comando | O que garante |
|---|---|
| `supabase test db` | **223** asserções no filtro, 232 nos cenários (as duas branches ainda não se encontraram) |
| `./scripts/mutacao.sh` | **74** regras derrubadas uma a uma, todas matam um teste. Varre `public` **e** `privado` desde 23/09 |
| `./scripts/contrato-acompanha-o-codigo.sh` | recusa PR que muda função de `public` sem levar o contrato e sem subir a versão |
| `./scripts/ciclo-completo.sh` | o fluxo por HTTP, com status **e** código de erro |
| `./scripts/lint-conhecido.sh` | `plpgsql_check` sem achado novo |
| `./scripts/advisor-conhecido.sh` | advisor do Supabase sem alerta além dos declarados |
| `./scripts/contrato-em-dia.sh` | o espelho do `openapi.yaml` não divergiu do original |
| `./scripts/migracoes-imutaveis.sh` | nenhuma migração aplicada foi editada |

Todos rodam na CI menos o advisor, que exige o token de conta e não vai para segredo de
repositório. O portão do contrato fica em **job próprio**, e não atrás do `supabase
start`: ele é `git` e `sed`, e amarrá-lo ao job do banco fez com que, por duas
execuções, ele nem chegasse a rodar — a CI ficava vermelha pelo motivo errado.

**A regra que vale para qualquer portão novo:** um caminho que não seja *"medi e o
resultado foi X"* tem que sair diferente de zero. Ela existe porque a mesma falha
apareceu quatro vezes num dia — mutação pulando alvo em silêncio, lint passando quando a
ferramenta quebrava, lint tratando saída limpa como formato inválido, e um portão que
tratava suíte já vermelha como detecção.

## O que foi aprendido, e custa caro reaprender

- **Suíte verde não diz o que ela protege.** Duas vezes os testes passaram inteiros sobre
  uma regra ausente: 11 de 31 restrições e 10 de 19 políticas. Quem achou foi a mutação.
- **Derrubar uma política de leitura *fecha* dado.** Por isso a mutação por ausência não
  pega política frouxa demais: um `using (true)` posto por engano abre a tabela e toda
  asserção de "fulano lê o próprio" continua verdadeira. Cada política precisa das duas
  asserções, positiva e negativa. O `mutacao.sh` ataca pelos dois lados.
- **Teste de banco não substitui chamada HTTP.** O envelope de erro do contrato não tinha
  a chave `headers`, e o PostgREST devolvia 500 em toda recusa de regra. Dentro do
  Postgres a exceção estava certa. Só o `ciclo-completo.sh` pegou.
- **Uma recusa tem três eixos, e conferir dois não basta.** Só o `sqlstate`: trocar
  `erro(422,'menor_de_idade')` por `erro(500,'qualquer_coisa')` deixava tudo verde. Só o
  código: um `raise exception 'menor_de_idade'` cru também — a mensagem casava, o
  `sqlstate` virava `P0001` e o app recebia 400 em vez de 422. Os testes de RPC usam
  `throws_ok(sql, 'PGRST', '<envelope inteiro>', …)`, que fixa `sqlstate`, `code` e
  `details`; o **status** só o `ciclo-completo.sh` alcança, e toda recusa nova precisa de
  uma linha lá.
- **Rótulo de volatilidade mentiroso passa despercebido.** `IMMUTABLE` numa função que
  levanta exceção, `STABLE` chamando `VOLATILE`. Quem pegou foi o lint, e só porque a CI
  rodava uma CLI mais nova que a da máquina. Mantenha a CLI local igual à da CI.
- **Mudança feita no painel do Supabase não existe para o próximo ambiente.** O event
  trigger `ensure_rls` existia só no `frila-dev`. Foi trazido para migração.

## Divergências registradas

- **O backend não está em `Frila/supabase/`**, como as Pendências Técnicas de 22/09
  registraram. Está neste repositório. Comentado nos cartões afetados.
- **`turno.checkout_distancia_m` sem o teto de 200 m** que a Modelagem traz. Com o teto,
  quem se afasta não consegue encerrar o turno. Vai à decisão no cartão
  `S0 · Produto · Decisões de produto que travam o código`, prazo 02/10.
- **`vaga.posicoes` com teto de 200**, que vem do contrato e não da Modelagem. Quem
  precisa reconciliar é o documento.
- **`privado.bloqueado_com_estabelecimento` faltava `m.usuario_id <> conta`.** Corrigido
  aqui; a Modelagem tem a mesma expressão errada. Sem isso, o membro que bloqueou alguém
  ficava bloqueado com o próprio estabelecimento, e `vagas_abertas`,
  `candidatos_da_vaga` e `contato_do_turno` devolveriam lista vazia para ele.
- **`usuario` ganhou `termos_versao` e `termos_aceite_em`**, que não estão na Modelagem.
  Vieram do cartão da entrada por código.

## Pendências fora do código

1. **`supabase login`.** O `SUPABASE_ACCESS_TOKEN` do `.env` responde **401** na
   Management API — medido em 23/09. O advisor de segurança do `frila-dev` não é
   verificado por ninguém desde que ele venceu, e isso não aparecia porque o portão lia
   o corpo de erro como "nenhum achado". O portão foi corrigido para reprovar; o token
   depende de alguém presente.
2. **PAT com leitura em `FrilaApp/frila-docs`**, gravado como secret `FRILA_DOCS_TOKEN`. Sem
   ele, o job do contrato confere só a integridade do espelho e avisa em voz alta que não
   conferiu o original. Fine-grained, *Resource owner* `FrilaApp`, *Contents: Read-only*.
3. **`git push` no `FrilaApp/Bancada`**, que exige Touch ID. Esperando: a forma `externo`
   do `registrar-fato.sh`, o conserto dos hooks, as notas de 22 e 23/09 e a T-0025
   atualizada. Sem esse push, o PR #5 do backend não tem como funcionar na máquina de
   ninguém, e o site da Bancada não republica.
4. **Revisão da Júlia** na lista de termos bloqueados do filtro da diretriz 1.2. É
   decisão de produto e de jurídico. Sem ela, o `ggEzge6h` não fecha.
5. **Reexecutar a CI** quando o `ghcr.io` estabilizar. Nenhum dos seis PRs teve teste
   rodado lá.
6. **Decidir as 11 operações do contrato sem cartão no quadro** — `renovarSessao`,
   `minhaConta`, `criteriosDeNotificacao`, `pedirRevisaoDespacho`, `equipeDeConfianca`,
   `incluirNaEquipe`, `removerDaEquipe`, `listarFuncoes`, `candidatosDaVaga`,
   `escolherCandidato`, `exportarTurnos`. Contrato a mais ou cartão faltando.
7. **Avisar o Cauê** que o projeto Supabase que ele criou em 22/09 virou o `frila-dev` e
   tem esquema dentro.

> **Corrigido de 22/09:** os hooks do vault estavam desligados por um motivo que a
> entrada anterior atribuía ao monorepo em geral. A causa era precisa: `bootstrap.sh`
> fixava `core.hooksPath` em `scripts/git-hooks`, caminho que não existe na raiz do
> monorepo — e o git não reclama de `hooksPath` inexistente, simplesmente não roda hook.
> Os hooks e o `lib.sh` passaram a resolver o vault como subdiretório. Também estava
> errado que "a T-0025 e o diário de 22/09 estão commitados esperando": a T-0025 existia,
> o diário de 22/09 existia, e o que faltava era o push.

## Por onde continuar

1. **Fazer os nove PRs andarem**, na ordem da seção *Os PRs*. Só o #4 tem CI verde; o
   motivo dos outros é o `ghcr.io`, não o código. Reexecutar antes de mergear.
2. `4qwQF0w6` — `cadastrar_estabelecimento` e `meus_estabelecimentos`. É o que falta
   para `publicar_vaga` ter onde publicar, e `meus_estabelecimentos` já está no contrato
   desde a 0.2.2.
3. Sprint 1: `publicar_vaga` depois, porque `candidatar` depende dela. `candidatar` é
   o cartão onde o produto quebra se errar — `UPDATE` condicional com
   `FOR UPDATE SKIP LOCKED`, e teste de corrida com **pgbench**, porque o pgTAP roda numa
   sessão só e não testa concorrência.
3. Toda RPC nova do Sprint 1 nasce com quatro coisas, e nenhuma delas é negociável:
   o filtro de texto nos campos livres, a recusa correspondente no `ciclo-completo.sh`,
   a linha no `openapi.yaml` com a versão subindo, e a asserção de mutação que morre
   quando a regra some. O portão do contrato cobra a terceira; as outras três dependem
   de quem escreve.
