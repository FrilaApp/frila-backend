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
[`05-ESCOPO-DO-MVP.md`](https://github.com/BlendOps/Frila/blob/main/Documentos/MD/05-ESCOPO-DO-MVP.md);
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

## Onde está o resto

| O quê | Onde |
|---|---|
| Documentos de produto, contrato da API, requisitos | [`BlendOps/Frila`](https://github.com/BlendOps/Frila) |
| Modelagem de banco, diagramas, decisões técnicas | [`BlendOps/Bancada`](https://github.com/BlendOps/Bancada) · `doc-harness/07 - Arquitetura/` |
| Registro do processo, para os mentores | https://bancada-buu.pages.dev |
| App iOS | `BlendOps/Frila` · `ios/` |

> O cartão `S0 · Infra · Criar o projeto no Supabase` diz que o backend fica em
> `Frila/supabase/`. Mudou em 22/09: o código do backend vive aqui. O contrato continua
> nascendo no repositório do Frila e é espelhado em `contrato/`.

## Como se trabalha

Um cartão do Trello por vez, do quadro ao merge. O pipeline, os agentes e as regras que
o código segue estão em [`CLAUDE.md`](CLAUDE.md).

## Time

Cauê Carneiro · Fabrício Tosta · João Paulo Albuquerque · Júlia Clovandi · Matheus Silva
— BlendOps, Challenge 18 do Apple Developer Academy.
