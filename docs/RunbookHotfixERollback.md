# Runbook de hotfix e rollback no pico do piloto

Como publicar uma correção no `frila-prod` e como desfazer uma migração enquanto o piloto
roda, sem cair na janela proibida da RNF12 (quinta a domingo, das 16h às 2h, horário de São
Paulo). Escrito em 28/10/2026 a partir do que existe em `.github/workflows/entrega.yml` e em
`scripts/`; o que mede o estado real do repositório no GitHub vem marcado com a data.

Convenção: tudo que não tem `arquivo:linha` nem medição é **"proposta, a confirmar"**.
O que o repositório não prova está na seção 7.

Este documento não repete o diagnóstico de incidente nem o rollback de migração em geral:
`docs/RUNBOOK-INCIDENTES.md` (seção 6) é o procedimento canônico de migração corretiva.
Aqui entra o que falta em torno dele: a janela, a tag e o pico.

---

## 1. Quem decide

| Decisão | Quem | Fonte |
|---|---|---|
| Declarar hotfix e publicar em Prod | Os sócios têm comando total; quem leva o hotfix até a tag responde por ele | `AGENTS.md`, "Quem é quem" |
| Aprovar o PR do hotfix | Qualquer um dos quatro sócios, menos quem abriu o PR, lendo o diff inteiro (migração e push são faixa vermelha) | `AGENTS.md`, "Aprovar e mesclar" |
| Mesclar com a CI ainda rodando ou vermelha | Só em emergência, registrada no PR | `AGENTS.md`, "Aprovar e mesclar" |
| Aprovar o job de Prod no Environment | Revisor do Environment `frila-prod`. **Hoje não existe revisor** (seção 7) | `entrega.yml:126-127`; medido em 28/10 |
| Aplicar patch à mão em Prod | `[DONO]`, termo de `docs/RUNBOOK-INCIDENTES.md` (por exemplo, linha 224) que o documento não define | `RUNBOOK-INCIDENTES.md` |
| Exceção à janela proibida | Proposta, a confirmar: `[DONO]`, com motivo e hora registrados no PR ou no cartão | não existe regra escrita |

O agente de IA prepara, testa e abre o PR. Ele nunca aprova nem mescla, e não empurra a tag
de Prod (`AGENTS.md`, "Limites").

---

## 2. Como a entrega funciona (o que o `entrega.yml` faz)

- `develop` com mudança em `supabase/migrations/**`, `supabase/functions/**`, `seed.sql`,
  `config.toml` ou nos scripts de entrega publica no `frila-dev` sem passo manual
  (`entrega.yml:17-30`, job `frila-dev` em `:53-82`).
- A tag `backend-v*` leva ao `frila-prod` (`entrega.yml:20`, job `frila-prod` em `:121-181`).
  O job só existe para tag (`:124`). Tag não passa por filtro de caminho (`:21`).
- Dentro do job de Prod, na ordem:
  1. Environment `frila-prod` (`:126-127`), que pode exigir aprovação.
  2. **Janela da RNF12** (`:139-140`).
  3. A tag precisa apontar para um commit da `develop` (`:143-148`). Não há atalho: hotfix
     também passa por PR na `develop`.
  4. O token existe (`:155-160`).
  5. `scripts/aplicar-remoto.sh` aplica migrações e semente (`:162-163`).
  6. `supabase functions deploy` (`:165-166`).
  7. `scripts/desvio.sh` compara o Prod com o que o repositório constrói (`:177-181`).
- Duas entregas no mesmo ambiente não correm juntas, e nenhuma é cancelada no meio
  (`:41-43`). Cada job tem 15 minutos (`:128`).
- Nada neste workflow desfaz sozinho uma publicação que deu errado. Se o `desvio.sh` reprova
  no passo `:180-181`, o Prod já foi alterado.

### Como a janela é aplicada

O passo `Fora da janela proibida (RNF12)` (`entrega.yml:139-140`) roda
`./scripts/janela-de-manutencao.sh`. A conta está em `scripts/janela-de-manutencao.sh:34-35`:

- bloqueado: quinta a domingo a partir das 16h, e sexta a segunda antes das 2h (a madrugada
  ainda é a noite anterior);
- horário de São Paulo (`:21`), lido do relógio do runner;
- saída `0` fora da janela, `1` dentro dela, `2` se não leu a hora (`:13`).

Dentro da janela o passo termina em `1` (`:38-41`) e o job falha. Os passos de migração e de
Edge Function (`entrega.yml:162-166`) vêm depois, então não rodam (inferência: o GitHub
interrompe o job no primeiro passo vermelho).

Quando conferir: o comentário em `entrega.yml:137-138` explica que a aprovação pode chegar
horas depois da tag, então a janela é medida quando o job **começa**, e não quando a tag é
criada. Os casos de borda estão em `scripts/teste-entrega.sh:36-46` (por exemplo, quinta
15h59 passa, quinta 16h não, sexta 1h59 não, sexta 2h passa).

Para saber agora: `./scripts/janela-de-manutencao.sh` (a variável `FRILA_AGORA`, linha 11, é
só de autoteste; o workflow não a define, e defini-la seria uma mudança em `entrega.yml`
visível em PR).

---

## 3. Hotfix, passo a passo

1. **Classificar.** É incidente em produção? Comece por `docs/RUNBOOK-INCIDENTES.md`.
   Meça a janela agora: `./scripts/janela-de-manutencao.sh`. Dentro dela, siga a seção 5
   antes de planejar o prazo.
2. **Decidir** (seção 1): quem leva o hotfix e quem aprova o PR.
3. **Reproduzir e escrever o teste que falha.** pgTAP vermelho primeiro (`AGENTS.md`,
   "Testes"). Sem teste que reproduza, o hotfix é palpite.
4. **Branch a partir da `develop`:**
   `git fetch origin develop && git switch -c sX/<assunto> origin/develop`.
   Não existe branch de hotfix saindo da `main`: o job de Prod recusa tag fora da
   `develop` (`entrega.yml:143-148`).
5. **Gate local** (`AGENTS.md`, "Comandos e gate local"): `supabase db reset`,
   `supabase test db`, `./scripts/ciclo-completo.sh`, `./scripts/mutacao.sh`,
   `./scripts/lint-conhecido.sh`, `./scripts/advisor-conhecido.sh`. Se tocou Edge Function,
   `deno test --allow-all --no-check`.
6. **PR para `develop`** (`gh pr create --base develop`), com o que foi e o que não foi
   executado. A CI leva ~50 min (`AGENTS.md`); um hotfix real mede o prazo contando com isso,
   ou com a exceção de emergência registrada no PR.
7. **Aprovação e merge** por outro sócio (seção 1).
8. **Acompanhar o `frila-dev`.** O merge dispara a entrega para o `frila-dev`
   (`entrega.yml:56`) e depois o `desvio-dev` (`:84-119`). Confira o efeito do hotfix lá
   antes de seguir para Prod.
9. **Checar a janela de novo** e só então criar a tag no commit já mesclado na `develop`:
   `git tag backend-vX.Y.Z <sha> && git push origin backend-vX.Y.Z`. O padrão do nome é
   `backend-v*` (`entrega.yml:20`). Nenhuma tag existe ainda (medido em 28/10), e o esquema
   de numeração é proposta, a confirmar.
10. **Aprovar o job de Prod** se o Environment tiver revisor (`entrega.yml:126-127`).
    Acompanhe os passos da seção 2 até o `desvio.sh` terminar verde.
11. **Registrar** no PR e no cartão: SHA, tag, hora, resultado do `desvio.sh`. No fim do dia,
    `scripts/bancada-sync.sh` leva o dia ao vault.

Smoke depois da publicação: `GET` na função `saude` do Prod só lê no caminho de sucesso
(`select 1`, `supabase/functions/saude/index.ts`); no de falha, grava uma linha em
`registrar_falha_execucao` (`mantem-prod-vivo.yml:9`). Não rode `ciclo-completo.sh` nem `demonstracao.sh`
contra o Prod, porque gravam dados; a decisão de gravar em produção é do `[DONO]`.

---

## 4. Rollback de migração sem editar migração antiga

Migração aplicada é imutável. Quem edita ou apaga arquivo em `supabase/migrations/` reprova
na CI: `scripts/migracoes-imutaveis.sh:12` lista os arquivos modificados ou removidos
(`--diff-filter=MD`) em relação à base e sai com erro (`:14-20`). O desfazer é uma
**migração nova, à frente**, que reverte o efeito.

1. **Se a tag ainda não foi empurrada**, o Prod não recebeu a migração: corrija à frente na
   `develop` e não crie a tag. Nada mais a fazer em Prod.
2. **Se já foi aplicada**, crie `supabase migration new desfazer_<assunto>`. Reserve o
   carimbo antes: dois arquivos com a mesma versão quebram o `db reset`
   (`scripts/migracoes-sem-colisao.sh`).
3. **Escreva a reversão** como a seção 6 do `docs/RUNBOOK-INCIDENTES.md` descreve:
   `drop constraint`, `drop column`, ou `create or replace function` com o corpo anterior
   (recuperável com `git show <commit-anterior>:supabase/migrations/<arquivo>.sql`),
   mantendo `set search_path = ''` e os `grant`/`revoke`.
4. **Dado não volta.** `drop column` apaga o conteúdo. Mudança destrutiva em duas fases
   (acrescenta e escreve nos dois; só depois remove), por `AGENTS.md`, "Migrações". Backup
   do Prod: ver seção 7, ainda não configurado.
5. **pgTAP** que prova o estado revertido e as regras de negócio intactas;
   `supabase db reset` e `supabase test db` verdes.
6. **PR → `develop` → `frila-dev` → tag → `frila-prod`**, o mesmo caminho da seção 3, sob a
   mesma janela.
7. **Simulação prévia** em ambiente remoto: `./scripts/aplicar-remoto.sh <project_ref> --seco`
   lista o que seria aplicado, sem aplicar (`aplicar-remoto.sh:74-77`).

Como a aplicação se comporta (`scripts/aplicar-remoto.sh:65-88`): aplica em ordem, cada
arquivo numa chamada à API, registra a versão só depois de o arquivo passar (`:83-85`) e
aborta no primeiro erro (`:79-82`). Reexecutar pula o que já está registrado (`:70-72`).

**Armadilha, por inferência dessas linhas:** se a migração N falhar em Prod, a N+1 de
reversão não é aplicada antes da N, porque a N é tentada primeiro de novo. A CI impede
corrigir a N editando o arquivo. O repositório não resolve esse caso; ver seção 7.
Para o procedimento e padrões de reversão de migrações que já foram aplicadas, consulte
[`docs/TemplateMigracaoCorretivaERollback.md`](TemplateMigracaoCorretivaERollback.md).

---

## 5. Tag em horário proibido

O que acontece (fatos da seção 2): a tag dispara o workflow; o job de Prod espera o
Environment; quando começa, o passo da janela mede o relógio de São Paulo e, dentro da
janela, reprova antes de qualquer migração ou deploy.

1. **Não aprove nem reexecute dentro da janela.** Meça com `./scripts/janela-de-manutencao.sh`.
2. **Confirme que nada foi aplicado.** Abra a execução na aba Actions: o passo
   `Fora da janela proibida (RNF12)` vermelho e os passos `Migrações e semente` e
   `Edge Functions` sem execução.
3. **Espere abrir.** Fora da janela: de sexta 2h às 16h; sábado e domingo das 2h às 16h;
   segunda das 2h até quinta às 16h (derivado de `janela-de-manutencao.sh:34-35`).
4. **Reexecute o job** na aba Actions depois das 2h. Ele usa o mesmo commit da tag. Se o
   hotfix mudou, é tag nova, em commit da `develop`. Não mova nem apague tag.
5. **Se o dano de esperar for maior que o de publicar** (proposta, a confirmar): o `[DONO]`
   decide a exceção e registra no PR ou no cartão o motivo, a hora e o que será aplicado.
   O workflow não tem exceção. O caminho que existe é à mão, com
   `./scripts/aplicar-remoto.sh <ref-prod>` e `supabase functions deploy --project-ref <ref>`,
   que não passam pela janela nem pela checagem da tag na `develop`. Depois rode
   `./scripts/desvio.sh <ref-prod>` (precisa de um banco local de pé com as migrações) e
   deixe o PR com o resultado.

---

## 6. Rotinas que acompanham este runbook

- `.github/workflows/mantem-prod-vivo.yml`: `GET` diário na `saude` do Prod, para o projeto
  gratuito não pausar por inatividade. Precisa da variável de repositório
  `FRILA_PROD_URL_SAUDE`.
- `.github/workflows/renova-contas-de-revisao.yml`: renovação, sob confirmação, das contas e
  dos dados que a Apple usa na revisão do app. Por `workflow_dispatch`, escolhendo `dev` ou
  `prod`.

---

## 7. O que NÃO foi comprovado

Medido em 28/10/2026 com `gh` e `git ls-remote` (só leitura), salvo indicação.

- **Nenhuma tag `backend-v*` existe** (`git ls-remote --tags origin` vazio). O job `frila-prod`
  nunca rodou a partir de tag; nenhuma execução real prova a seção 2 em Prod.
- **O Environment `frila-prod` não tem regra de proteção**: sem Required reviewers e sem
  restrição de branch ou tag (`protection_rules: []`, `deployment_branch_policy: null`). O
  texto "exige a aprovação de um revisor" em `entrega.yml:3-4` e `:126` descreve o que se
  pretende, não o que está ligado. Hoje quem empurra a tag põe em Prod. Ligar o revisor é de
  quem administra o repositório e está fora do escopo deste runbook.
- **A janela só foi testada em unidade** (`scripts/teste-entrega.sh:36-46`); nunca vimos o
  passo barrando um job real.
- **A janela é medida só no começo do job** (`entrega.yml:137-140`). Inferência: um job que
  começa às 15h55 pode aplicar migração depois das 16h; o limite é o `timeout-minutes: 15`
  (`:128`).
- **Migração que falha no meio:** não se provou se a Management API roda o arquivo numa
  transação única (`aplicar-remoto.sh:79`). O estado parcial é desconhecido.
- **Fila bloqueada por migração falha** (seção 4): inferência, nunca exercida. Sair dela
  (editar a migração com exceção na CI, ou preparar o Prod à mão) é decisão do `[DONO]`.
- **Reexecutar o job** depois da janela: não se provou se pede nova aprovação do Environment.
- **Rollback de Edge Function:** o repositório não tem procedimento. `supabase functions
  deploy` (`entrega.yml:165-166`) publica o código da tag. Proposta, a confirmar: PR de revert
  na `develop` e tag nova. Se o Supabase guarda versões anteriores para voltar: não
  encontrado (buscado em: `entrega.yml`, `scripts/`, `docs/`).
- **Backup do Prod não está configurado.** `docs/BackupDoProd.md:282-296`: "Não foi criado/
  carregado plist nem configurado serviço ou segredo do prod". Sem backup, `drop column`
  em Prod não tem volta.
- **Nunca se executou um rollback real em Prod**, nem um hotfix de ponta a ponta.
- **`mantem-prod-vivo.yml`:** a variável `FRILA_PROD_URL_SAUDE` não existe (nenhuma variável
  de repositório, medido em 28/10), então o job falha até alguém criá-la. Que a chamada
  diária impeça a pausa do projeto só se comprova esperando mais de sete dias; que o
  Supabase conte uma chamada à função como "uso": não encontrado.
- **`renova-contas-de-revisao.yml`:** o script chamado, `scripts/renovar-demonstracao.sh`,
  usa `curl -s` sem `-f` e joga a resposta fora (linhas 61-65 e 79-83), então o código de saída
  dele não prova a renovação. O workflow lê as datas de volta; essa leitura foi testada com
  `curl` simulado e com o banco local, nunca contra `dev` ou `prod`.
