# D03 — Plano do Supabase: grátis por ora, sem PITR

**Estado:** aceita · **Cartão:** [`SwnVKGRO`](https://trello.com/c/SwnVKGRO) ·
**Decisão:** do Cauê, pedidos 16-26 e 16-28 · **Data:** 16/11/2026

## A decisão

- **Plano Pro só quando a necessidade aparecer ou quando houver recurso definido pelo Cauê.** Até lá, o
  `frila-prod` e o `frila-dev` ficam no plano grátis.
- **PITR (recuperação a um instante): não, por ora.**
- **RPO (quanto dado se pode perder):** até **24 horas**. A cópia que vale é o backup diário próprio
  (`.github/workflows/backup-prod.yml`, `cron: '0 7 * * *'`, 07:00 UTC = 04:00 em Brasília).
  Um problema às 03:59 perde o dia anterior inteiro desde 04:00.
- O RTO (quanto tempo para voltar) é medido na restauração real do cartão `U3RlsJF7` e registrado em
  `docs/BackupDoProd.md`.

## O que foi medido

**Organização do Frila (vale para o `frila-dev` e o `frila-prod`):** plano **Free**; **Spend cap ligado**
(não cobra excedente: passando da cota, o projeto pode ficar sem resposta ou só leitura); nenhuma fatura;
nenhum meio de pagamento. Fonte: painel do Supabase, página Billing da organização, lida pelo Orquestrador 2
em 16/11/2026 às 23h3x (Brasília).

| Projeto | Disco | Fonte |
|---|---|---|
| `frila-dev` | 2 GB, gp3, sem add-on | Management API, 16/11/2026 22:3x: `GET /v1/projects/<ref>/config/disk` → `size_gb: 2`; `GET …/billing/addons` → `selected_addons: []` |
| `frila-prod` | 2 GB | Management API, 13/11/2026: `config/disk` e `config/disk/util` |

## Riscos do plano grátis e como estão cobertos

| Risco | Cobertura |
|---|---|
| O projeto grátis pausa depois de 7 dias sem uso, e só Owner ou Admin reativa | `.github/workflows/mantem-prod-vivo.yml`: um GET por dia (12:00 UTC) na função `saude`, que faz `select 1`. Job vermelho = o Prod não respondeu 200 |
| Sem backup gerenciado com volta a um instante (PITR) | Backup lógico próprio, diário, cifrado (age) e guardado fora do Supabase por 14 dias (`docs/BackupDoProd.md`) |
| Disco de 2 GB: o WAL ou um slot parado enchem o disco | Runbook do WAL e do slot (PR #462) e o alerta de cron parado (`probe_saude_cron`, #514) |
| Logs curtos (1 dia para API e banco, 1 hora para o Auth) | Falhas de execução gravadas no banco (`registrar_falha_execucao`) e o vigia de saúde |
| Limite de 30 e-mails por hora no Auth, para o projeto inteiro | Cartão `ohSt4dg2` (alerta de uso da cota e decisão do captcha) |
| Spend cap: passar da cota do plano deixa o projeto sem resposta ou só leitura, em vez de cobrar | Sem cobertura automática hoje; o gatilho "disco acima de 70%" abaixo reabre esta decisão |

## Quando rever

Qualquer um destes reabre a decisão: o disco passa de 70%, o projeto pausa mesmo com o workflow, a perda de
um dia de dados deixa de ser aceitável (por exemplo, com pagamento ou volume alto de turnos), ou o Cauê
define recurso para o plano.
