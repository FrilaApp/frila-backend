# Estado do backend — 22/09/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

O esquema do Frila está de pé e fechado, no local e no `frila-dev`, com a entrada por
código no e-mail funcionando de ponta a ponta. **Três cartões de Backend do Sprint 0
fechados**; faltam três, e o próximo livre é o de cenários de desenvolvimento.

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · 20 migrações |
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
| `Cc2XYCi0` Dados de teste e cenários | **Em andamento** · não começado |
| `ggEzge6h` Filtro de texto ofensivo | a fazer · depende do contrato 0.2.1 |
| `oUwDEP8Q` Contrato 0.2.1 | a fazer · depende de `MwtmdDQ9`, do Cauê |
| `CvopSHh6` Versão mínima do app | a fazer · do João Paulo |

`./scripts/trello.sh` faz tudo: `ver`, `lista`, `pegar`, `revisao`, `concluir`, `comentar`.

**Caminho crítico**, apontado pela auditoria do quadro: `oUwDEP8Q` (contrato 0.2.1) é o
único cartão de Backend cuja dependência está com outra pessoa, e ele trava também o
`bP2WKgG0` do iOS. Vence 02/10. A parte de `supabase/` da CI que o `MwtmdDQ9` pediria já
está construída — está comentado no cartão, para o Cauê não recomeçar.

## O que existe no banco

19 tabelas, 31 restrições `CHECK`, 1 de exclusão (RN21), 3 triggers, 19 políticas de
leitura, 12 auxiliares no schema `privado`, e nenhuma política de escrita em lugar
nenhum — toda escrita passa por função `security definer`.

RPCs prontas: `criar_conta`, `minha_conta`. As treze do ciclo (publicar, candidatar,
check-in, avaliar…) são o Sprint 1 e não existem ainda.

**`privado.agora()` é o relógio do produto.** Todo prazo passa por ele: os 7 dias do
contato (RN10), o fim previsto que libera a avaliação (RN07), as 24 h do modo seleção
(RN24). Sobreponível por `frila.agora` **apenas** quando `privado.ambiente` tem a linha
de teste — e essa linha não é gravada por arquivo nenhum do repositório: quem a escreve é
o teste, dentro da transação. Nenhuma RPC nova deve usar `now()` direto.

## Os portões

| Comando | O que garante |
|---|---|
| `supabase test db` | 196 asserções pgTAP |
| `./scripts/mutacao.sh` | 71 regras derrubadas uma a uma, todas matam um teste |
| `./scripts/ciclo-completo.sh` | o fluxo por HTTP, com status **e** código de erro |
| `./scripts/lint-conhecido.sh` | `plpgsql_check` sem achado novo |
| `./scripts/advisor-conhecido.sh` | advisor do Supabase sem alerta além dos declarados |
| `./scripts/contrato-em-dia.sh` | o espelho do `openapi.yaml` não divergiu do original |
| `./scripts/migracoes-imutaveis.sh` | nenhuma migração aplicada foi editada |

Os quatro primeiros e os dois últimos rodam na CI. O advisor não, porque exige o token de
conta, que não vai para segredo de repositório.

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

1. **PAT com leitura em `BlendOps/Frila`**, gravado como secret `FRILA_DOCS_TOKEN`. Sem
   ele, o job do contrato confere só a integridade do espelho e avisa em voz alta que não
   conferiu o original. Fine-grained, *Resource owner* `BlendOps`, *Contents: Read-only*.
2. **`git push` no `monorepo`**, que exige Touch ID. A T-0025 e o diário de 22/09 estão
   commitados esperando.
3. **Os hooks do vault estão desligados no monorepo.** `core.hooksPath` vazio: o
   `bootstrap.sh` do doc-harness aponta para `scripts/git-hooks` relativo à raiz, e na
   raiz do monorepo esse caminho não existe. Na prática o Touch ID no push e o registro
   automático de fato não rodam. É do Cauê, que fez a migração para monorepo.
4. **Avisar o Cauê** que o projeto Supabase que ele criou em 22/09 virou o `frila-dev` e
   tem esquema dentro.

## Por onde continuar

1. `Cc2XYCi0` — cenários de desenvolvimento. **Atenção:** a descrição manda pôr os dados
   em `supabase/seed.sql`, e isso contraria a convenção do repositório e o próprio
   critério de aceite do cartão (*"o pipeline do frila-prod nunca aplica o seed.sql"*).
   `seed.sql` é o único arquivo que `aplicar-remoto.sh` executa contra o `frila-dev`. O
   conflito está comentado no cartão; os cenários vão num arquivo à parte, carregado só
   pelo `db reset`.
2. Sprint 1: `publicar_vaga` primeiro, porque `candidatar` depende dela. `candidatar` é
   o cartão onde o produto quebra se errar — `UPDATE` condicional com
   `FOR UPDATE SKIP LOCKED`, e teste de corrida com **pgbench**, porque o pgTAP roda numa
   sessão só e não testa concorrência.
