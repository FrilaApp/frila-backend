# frila-backend

Backend do **Frila**, a plataforma de contratação por turno avulso que nasce no Distrito
Federal. Supabase: Postgres com PostGIS, autenticação por código no e-mail, as regras do
ciclo em funções RPC, e o despacho fora da requisição com `pg_cron`, `pgmq` e Edge
Functions.

O ciclo que este repositório fecha:

```
publicar → notificar → candidatar → confirmar → executar → avaliar
```

Loja em 13/11/2026. O que entra em cada versão está em
[`05-ESCOPO-DO-MVP.md`](https://github.com/FrilaApp/frila-docs/blob/main/Documentos/MD/05-ESCOPO-DO-MVP.md);
o plano de trabalho, no [quadro do Trello](https://trello.com/b/0eyqvbRJ/frila).

## Rodar

```bash
cp .env.example .env      # e preencha
supabase start            # sobe Postgres, Auth, PostgREST e a caixa de e-mail local
supabase db reset         # aplica as migrações e o seed do zero
supabase test db          # pgTAP
```

O `supabase start` imprime a URL, a chave anônima e o endereço do **Inbucket**, onde o
código de entrada por e-mail chega sem envio real. Precisa do Docker aberto.

### Sem Docker Desktop: Colima

Funciona com o [Colima](https://github.com/abiosoft/colima) no lugar do Docker Desktop
(medido com Colima 0.10.3 e Docker 29, em Apple Silicon):

```bash
brew install colima docker
colima start --cpu 4 --memory 8 --vm-type vz --vz-rosetta
supabase start -x vector,logflare
```

- **`-x vector,logflare` é obrigatório.** O container `vector` monta o socket do Docker,
  e no Colima isso falha com `error while creating mount source path
  '.../.colima/default/docker.sock': operation not supported`. O pgTAP e o ciclo não usam
  nenhum dos dois. A CI já sobe sem eles.
- **O repositório precisa estar dentro do `$HOME`.** O Colima só compartilha o home com a
  VM. Fora dele, o `supabase test db` responde `Files=0, Tests=0, Result: NOTESTS`, sem
  erro, porque o container do `pg_prove` enxerga a pasta de testes vazia.
- O Colima não volta sozinho depois de reiniciar o Mac: `colima start` de novo, ou
  `brew services start colima`.
- O aviso `docker-credential-desktop not found` é inofensivo.

| Comando | O que faz |
|---|---|
| `supabase start` / `stop` | Ambiente local |
| `supabase db reset` | Recria o banco aplicando todas as migrações e o seed |
| `supabase migration new <nome>` | Cria uma migração datada |
| `supabase test db` | Roda o pgTAP de `supabase/tests/` |
| `supabase db push` | Aplica as migrações no projeto remoto |
| `./scripts/ciclo-completo.sh` | Smoke test: `criar_conta` → `publicar_vaga` → `candidatar` → check-in → `avaliar` |
| `./scripts/bancada-sync.sh` | Leva o trabalho do dia para o vault da Bancada |

## Estrutura

```
supabase/
├── migrations/    DDL datado e imutável. Correção é migração nova, nunca edição
├── functions/     Edge Functions (Deno): despacho, push, excluir-conta, exportação
├── seed.sql       Só o catálogo de funções. Dado de teste fica em tests/
└── tests/         pgTAP — um teste por CHECK e por política, com o nome da regra

contrato/openapi.yaml   Espelho do contrato do Frila. Divergência quebra a CI
agents/                 Os cinco agentes do pipeline, versionados
scripts/                bancada-sync, ciclo-completo
```

## Ambientes

| Ambiente | Para quê |
|---|---|
| local | Cada dev, com `supabase start`. Migração destrutiva e teste de corrida moram aqui |
| `frila-dev` | Compartilhado: integração com o iOS e o TestFlight |
| `frila-prod` | Só a partir do Sprint 3 |

A chave de serviço fica fora do app e fora do git: só o agendador e a CI a usam.

### Limites do plano gratuito do Supabase

Os dois projetos remotos rodam no plano gratuito, e o plano cobra o preço assim:

- **Dois projetos ativos por organização.** `frila-dev` e `frila-prod` ocupam os dois.
  Um terceiro projeto, mesmo de teste, obriga a pausar um deles.
- **Pausa depois de 1 semana sem uso.** Um projeto parado volta pelo painel, mas enquanto
  isso o app que aponta para ele não funciona. Vale para o `frila-dev` em semana sem
  TestFlight.
- **Nenhum backup automático.** O backup do `frila-prod` é nosso (cartão `S3 · Infra ·
  Backup lógico diário do frila-prod e ensaio de restauração`).
- **Cotas mensais somadas na organização.** Invocações de Edge Function e tráfego de
  saída são contados para os dois projetos juntos. Um laço no despacho do `frila-dev`
  consome a cota do `frila-prod`.

Os números exatos de cada cota mudam; a fonte é a
[página de preços do Supabase](https://supabase.com/pricing).

## Onde está o resto

| O quê | Onde |
|---|---|
| Documentos de produto, contrato da API, requisitos | [`FrilaApp/frila-docs`](https://github.com/FrilaApp/frila-docs) |
| Modelagem de banco, diagramas, decisões técnicas | [`FrilaApp/Bancada`](https://github.com/FrilaApp/Bancada) · `doc-harness/07 - Arquitetura/` |
| Registro do processo, para os mentores | https://bancada-buu.pages.dev |
| App iOS | `FrilaApp/frila-docs` · `ios/` |

> O cartão `S0 · Infra · Criar o projeto no Supabase` diz que o backend fica em
> `Frila/supabase/`. Mudou em 22/09: o código do backend vive aqui. O contrato continua
> nascendo no repositório do Frila e é espelhado em `contrato/`.

## Como se trabalha

Um cartão do Trello por vez, do quadro ao merge. O pipeline, os agentes e as regras que
o código segue estão em [`CLAUDE.md`](CLAUDE.md).

## Time

Cauê Carneiro · Fabrício Tosta · João Paulo Albuquerque · Júlia Clovandi · Matheus Silva
— FrilaApp (antes BlendOps), Challenge 18 do Apple Developer Academy.
