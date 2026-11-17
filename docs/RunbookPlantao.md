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
- **Avisos no Slack, no repositório, sem prova de que saem** (`731824c`, #512). LIDO: `.github/workflows/notifica-slack.yml` roda quando terminam os workflows `CI`, `Entrega`, `Backup diário do frila-prod` e `Mantém o Prod vivo`, e a cada hora checa se o backup está sem sucesso há mais de 30 h. Chama `scripts/notificar-slack.sh`. Mensagens previstas em `scripts/notificar_slack.py`: CI vermelha em `develop`, `main` e branches `test*`, `teste*` e `ci*`; falha de Entrega; tag `backend-v*` aplicada em Prod; falha **e** sucesso diário do backup; falha do `Mantém o Prod vivo`; backup ausente há mais de 30 h; e, no job `aviso-tag-prod` de `entrega.yml`, tag aguardando aprovação no Environment `frila-prod`. O webhook vem do segredo `SLACK_WEBHOOK_URL`; **sem o segredo o script avisa no log e sai 0, o workflow não falha** (`notificar-slack.sh`, cabeçalho). **MEDIDO em 16/11/2026 com `gh api`:** a listagem de secrets do repositório (`actions/secrets`) devolve só `FRILA_DOCS_TOKEN`; as 30 execuções do workflow `Avisos no Slack` terminaram em `success`. **DEDUZIDO:** sem o segredo, nenhuma mensagem sai hoje e o workflow segue verde. NAO MEDIDO: segredo de organização, e se algum canal Slack existe e quem o lê. O Slack **não** recebe alertas do banco (`notificar_slack.py` só trata os quatro workflows e o backup; a "Fase 2" de alertas de `pg_cron` é citada no cabeçalho do arquivo como extensão futura e não está implementada).
- **Probe de saúde com idade dos jobs** (`25f475a`, #514, migração `20261116130000_probe_saude_cron.sql`). LIDO: `GET /functions/v1/saude` devolve `200` com `status: "saudavel"` e as idades em segundos, ou `503` com `status: "atrasado"` quando `reprocessar_despacho` ou `verificar_saude` está inativo, sem sucesso registrado, ou com último sucesso mais velho que 300 s e 900 s (tolerâncias padrão de `privado.consultar_saude_cron`); `503` com `status: "indisponivel"` se o banco não responde. **NAO MEDIDO:** se a migração e a função nova já estão no `frila-prod` (a `develop` não vai para o Prod sozinha). Cobre só esses dois jobs: não cobre `processar_fila_push` nem os outros.
- Aprovação de Prod no GitHub por 4 revisores cadastrados no Environment `frila-prod`, sem auto-aprovação (`docs/RunbookHotfixERollback.md`, seção 1).

**Não existe (buscado em `docs/`, `supabase/operacao/`, `README.md`, `AGENTS.md`, `scripts/`):**

- Escala de plantão: quem está de plantão em cada dia e horário.
- Canal de acionamento fora do e-mail: telefone, mensageiro ou serviço de chamada. O relatório do mapa de 16/11/2026 também não achou (busca por produtos de chamada e de monitoramento no repositório veio vazia).
- Monitor externo que **chame** a `saude` em intervalo curto. A função `saude` foi escrita para isso e, desde `25f475a` (#514), também mede a idade dos jobs `reprocessar_despacho` e `verificar_saude` (seção "Existe" acima), mas **quem a chama é só `mantem-prod-vivo.yml`, uma vez por dia** (MEDIDO em 16/11/2026: as únicas referências a `FRILA_PROD_URL_SAUDE` e a `functions/v1/saude` fora de testes e docs são esse workflow e os scripts de fumaça manuais). O cron é `0 12 * * *`, mas os runs começam horas depois: o relatório do mapa mediu atrasos de cerca de 6 a 10 h em workflows agendados, e eu medi de 6,8 a 10,3 h no backup diário.
- Definição de severidade e de tempo de resposta por severidade para incidente de sistema (só existem os prazos de atendimento a usuário da seção acima).
- Registro do plantão ("log de plantão" é citado em `docs/ChecagemDiariaProd.md`, seção 4, mas não há arquivo nem local indicado).
- Definição do termo `[DONO]`, usado nos runbooks para "quem pode agir em Prod" (`docs/RunbookHotfixERollback.md`, seção 1, linha de "Aplicar patch à mão em Prod"). Neste documento, e nos outros runbooks novos, lê-se como Cauê ou quem ele delegar (DEDUZIDO).

**Consequência (DEDUZIDO):** o alerta técnico do banco chega só por e-mail, depende do próprio banco para sair (`docs/RunbookSupabaseIndisponivel.md`, seção 1) e não tem nome nem hora de resposta. O Slack e o probe novo melhoram a visibilidade de falha de workflow e de job atrasado **se** o segredo e a função nova estiverem no ar e **se** alguém ler o canal; hoje nenhuma das duas condições está provada. Um incidente à noite ou no fim de semana só é visto quando alguém abrir a caixa.

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
| Qual canal do Slack recebe os avisos de `notifica-slack.yml`, quem cria o segredo `SLACK_WEBHOOK_URL` e quem lê o canal | A DEFINIR (Caue) | em branco |
| Quando e por quem roda a checagem diária (`scripts/checagem-diaria.sh`) | A DEFINIR (Caue) | em branco |
| Onde se registra o plantão | A DEFINIR (Caue) | em branco |
| Plano do Supabase de cada projeto (muda o suporte e o risco de pausa) | A DEFINIR (Caue) | em branco |

Sugestão de formato para a decisão (proposta, a confirmar): uma linha por dia e faixa horária, com titular e reserva, guardada **fora do repositório público** se contiver telefone ou e-mail pessoal. O repositório é público: não coloque número de telefone nem e-mail pessoal em arquivo versionado (`AGENTS.md`).

---

## 3. Como o plantão age quando for definido

Esta é a sequência esperada. Cada passo aponta para o runbook certo.

1. **Receber o aviso.** E-mail de alerta (`privado.verificar_saude`), semáforo vermelho da checagem diária, relato de usuário em `suporte@frilabr.com`, workflow vermelho no GitHub (`Mantém o Prod vivo`, `Entrega`, `Backup diário`). O aviso por Slack só sai se o segredo `SLACK_WEBHOOK_URL` existir (MEDIDO: ausente da listagem de secrets do repositório em 16/11/2026); sem ele, a notificação depende da configuração de cada sócio no GitHub (NAO MEDIDA).
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
