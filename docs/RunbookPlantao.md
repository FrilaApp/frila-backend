# Runbook: quem é o plantão e como é acionado

O Frila tem quatro sócios (Cauê, Fabrício, Jota e Matheus; `AGENTS.md`, "Regras do time") e produção com usuários. Este documento diz o que **existe hoje** para alguém ser avisado e agir, o que **não existe**, e deixa a escala e os canais em branco, marcados **A DEFINIR (Caue)**, para o Cauê preencher. Nenhum nome, telefone ou horário foi inventado aqui.

Convenção (a mesma de `docs/RunbookRotacaoDeSegredos.md`): **LIDO** é texto do repositório com `arquivo:linha`; **MEDIDO** é o que foi lido de uma execução real; **DEDUZIDO** é raciocínio; **A DEFINIR (Caue)** é fato que só o Cauê sabe.

---

## 1. Situação hoje (o que está escrito e o que não está)

**Existe (LIDO):**

- Um operador nomeado para a checagem diária de Prod: "Cauê Carneiro / Equipe Operacional" (`docs/ChecagemDiariaProd.md`, seção 1). O script `scripts/checagem-diaria.sh` devolve um semáforo verde, amarelo ou vermelho e diz o que o plantonista faz em cada caso (`docs/ChecagemDiariaProd.md`, seção 4). O próprio documento avisa que o rótulo "plantão do piloto" no cabeçalho do script é antigo.
- A caixa de atendimento `suporte@frilabr.com`, com prazos de resposta (24 horas para denúncia de conteúdo; 5 dias úteis para as demais demandas e para pedido do titular) e acesso restrito a operadores com 2FA (`supabase/operacao/equipe-frila.md`, seções 1 e 6).
- Alertas técnicos do banco por e-mail: a função `privado.verificar_saude` enfileira o alerta, no máximo um por hora por tipo, e a Edge Function `enviar-email` o manda para a variável `EMAIL_EQUIPE`, ou para a caixa de suporte se ela estiver vazia (`supabase/functions/enviar-email/index.ts:102-104`; `20260930230000_monitoramento_e_alertas.sql:101-143`). **O valor de `EMAIL_EQUIPE` no Prod: NAO MEDIDO.**
- Um script de aviso por e-mail aos sócios, para automações e para quem opera: `scripts/notificar-equipe.sh` (`docs/NotificacaoDaEquipe.md`). Os destinatários padrão são **três** dos quatro sócios (Cauê, Jotapê e Fabrício, seção 1 do documento); a Júlia (PO) não entra por padrão. O quarto sócio, Matheus, não está na lista padrão (DEDUZIDO: está fora; confirmar se é intencional). **A DEFINIR (Caue)**.
- Aprovação de Prod no GitHub por 4 revisores cadastrados no Environment `frila-prod`, sem auto-aprovação (`docs/RunbookHotfixERollback.md`, seção 1).

**Não existe (buscado em `docs/`, `supabase/operacao/`, `README.md`, `AGENTS.md`, `scripts/`):**

- Escala de plantão: quem está de plantão em cada dia e horário.
- Canal de acionamento fora do e-mail: telefone, mensageiro ou serviço de chamada. O relatório do mapa de 16/11/2026 também não achou (busca por produtos de chamada e de monitoramento no repositório veio vazia).
- Monitor externo de disponibilidade. O único probe de fora é o GET diário em `mantem-prod-vivo.yml`, a cada 24 horas (cron `0 12 * * *`, mas MEDIDO que os runs começam horas depois do horário: o relatório do mapa mediu atrasos de cerca de 6 a 10 h em workflows agendados, e eu medi de 6,8 a 10,3 h no backup diário).
- Definição de severidade e de tempo de resposta por severidade para incidente de sistema (só existem os prazos de atendimento a usuário da seção acima).
- Registro do plantão ("log de plantão" é citado em `docs/ChecagemDiariaProd.md`, seção 4, mas não há arquivo nem local indicado).
- Definição do termo `[DONO]`, usado nos runbooks para "quem pode agir em Prod" (`docs/RunbookHotfixERollback.md`, seção 1, linha de "Aplicar patch à mão em Prod"). Neste documento, e nos outros runbooks novos, lê-se como Cauê ou quem ele delegar (DEDUZIDO).

**Consequência (DEDUZIDO):** o alerta técnico chega por e-mail, depende do próprio banco para sair (`docs/RunbookSupabaseIndisponivel.md`, seção 1) e não tem nome nem hora de resposta. Um incidente à noite ou no fim de semana só é visto quando alguém abrir a caixa.

---

## 2. O que preencher (A DEFINIR (Caue))

A tabela é o formulário. Enquanto estiver em branco, **este runbook não define plantão**; ele só aponta a lacuna.

| Item | Valor | Estado |
|---|---|---|
| Quem é o plantão em horário comercial | A DEFINIR (Caue) | em branco |
| Quem é o plantão à noite e no fim de semana, ou se não há | A DEFINIR (Caue) | em branco |
| Canal de acionamento (qual app, qual grupo, qual número) | A DEFINIR (Caue) | em branco |
| Quem é acionado se o plantão não responder, e em quanto tempo | A DEFINIR (Caue) | em branco |
| Quem é o encarregado de dados (para `docs/RunbookVazamentoDeDadosPessoais.md`) | A DEFINIR (Caue) | em branco |
| Quem é o advogado de referência e como acioná-lo | A DEFINIR (Caue) | em branco |
| Quem é Owner/Admin do projeto `frila-prod` no Supabase | A DEFINIR (Caue) | em branco |
| Quem tem acesso ao console do Firebase (push) | A DEFINIR (Caue) | em branco |
| Quem guarda a chave privada `age` do backup | A DEFINIR (Caue) | em branco |
| Valor de `EMAIL_EQUIPE` no Prod (quem recebe o alerta técnico) | A DEFINIR (Caue) | em branco |
| Quando e por quem roda a checagem diária (`scripts/checagem-diaria.sh`) | A DEFINIR (Caue) | em branco |
| Onde se registra o plantão | A DEFINIR (Caue) | em branco |
| Plano do Supabase de cada projeto (muda o suporte e o risco de pausa) | A DEFINIR (Caue) | em branco |

Sugestão de formato para a decisão (proposta, a confirmar): uma linha por dia e faixa horária, com titular e reserva, guardada **fora do repositório público** se contiver telefone ou e-mail pessoal. O repositório é público: não coloque número de telefone nem e-mail pessoal em arquivo versionado (`AGENTS.md`).

---

## 3. Como o plantão age quando for definido

Esta é a sequência esperada. Cada passo aponta para o runbook certo.

1. **Receber o aviso.** E-mail de alerta (`privado.verificar_saude`), semáforo vermelho da checagem diária, relato de usuário em `suporte@frilabr.com`, workflow vermelho no GitHub (`Mantém o Prod vivo`, `Entrega`, `Backup diário`; o repositório não manda aviso de workflow para ninguém, DEDUZIDO: a notificação depende da configuração de cada sócio no GitHub, NAO MEDIDA).
2. **Confirmar o que é.** Rodar `scripts/checagem-diaria.sh` contra o Prod (humano, `docs/ChecagemDiariaProd.md`). Sem resposta do projeto: `docs/RunbookSupabaseIndisponivel.md`.
3. **Escolher o runbook:**

   | Sinal | Runbook |
   |---|---|
   | Aviso de vaga não chega | `docs/RunbookPushParado.md` |
   | Função publicada que quebrou | `docs/RunbookRollbackEdgeFunction.md` |
   | Projeto não responde, pausado | `docs/RunbookSupabaseIndisponivel.md` |
   | Segredo exposto ou a trocar | `docs/RunbookRotacaoDeSegredos.md` |
   | Dado pessoal exposto | `docs/RunbookVazamentoDeDadosPessoais.md` |
   | Despacho sem segredo, e-mail parado, `pg_cron`, exclusão de conta, CI vermelha, migração | `docs/RUNBOOK-INCIDENTES.md` |
   | Hotfix, tag, janela de pico | `docs/RunbookHotfixERollback.md` |
   | Backup e restauração | `docs/BackupDoProd.md` |
   | Suporte, denúncia, contestação, pedido do titular | `supabase/operacao/equipe-frila.md` |

4. **Avisar os outros sócios** quando o incidente passar de uma pergunta rápida, pelo canal da seção 2. Sem dado pessoal no aviso (`docs/NotificacaoDaEquipe.md`, seção 4).
5. **Registrar** hora de início, hora de fim, causa, decisão e quem decidiu, no local da seção 2.
6. **Passar o bastão:** quem sai do plantão diz o que ficou aberto.

Mudança em Prod só a pedido do sócio dono (`AGENTS.md`). Agente de IA nunca conecta em Prod nem recebe segredo.

---

## 4. Quem age

- **O plantão** (A DEFINIR (Caue): pessoa) executa os passos da seção 3.
- **O sócio que fez a entrega** que causou o incidente ajuda a diagnosticar e abre o PR de correção (`docs/RunbookHotfixERollback.md`, seção 1).
- **Os revisores do Environment `frila-prod`** aprovam o job de Prod: Cauê, Fabrício, Jota e Matheus, com auto-aprovação proibida (`docs/RunbookHotfixERollback.md`, seção 1; medido via GitHub API em 30/10/2026, não reconferido hoje).
- **Agente de IA:** apoio de leitura e redação; nenhuma ação em Prod.

## 5. Quem decide

- **Quem é o plantão, o canal e o escalonamento:** Cauê. É o item 1 da seção 2.
- **Declarar incidente, voltar função, restaurar backup, comunicar usuário, ANPD ou titular:** Cauê, com os limites de cada runbook (**A DEFINIR (Caue)**: delegação quando ele estiver indisponível).
- **Aceitar o risco de ficar sem plantão noturno** (alternativa legítima, mas que precisa ser decisão escrita): Cauê.
