# Desenho · Alerta de `pg_cron` parado que não depende do `pg_cron`

> **Só desenho. Nenhum código neste documento nem no PR que o traz.** O desenho foi **aceito** pelo Cauê em 08/11/2026, com as escolhas da seção 6. A implementação vira cartões próprios (seção 7).

## 1. O problema

Toda a vigilância do Prod roda dentro do próprio agendador:
- **`verificar_saude`**, a cada 5 min, é quem emite os alertas (`privado.emitir_alerta`).
- **`processar_fila_email`**, a cada minuto, entrega esses alertas por e-mail. O `emitir_alerta` põe o aviso na fila `pgmq` `email`, e é esse job que a esvazia.
- **`consumir_registro_acesso`**, a cada minuto, e a própria **`verificar_saude`** chamam a autoproteção do slot lógico (`docs/RunbookWalESlot.md`). Com o `pg_cron` inteiro parado, nenhuma das duas roda.

Se o `pg_cron` parar, nada avisa ninguém. Isso pode vir de um worker morto, da extensão fora depois de um restart ou de manutenção da plataforma, ou de jobs desativados por engano. Ao mesmo tempo:
- os turnos param de fechar e o despacho de reprocessar (`docs/RUNBOOK-INCIDENTES.md`, seção 3);
- o slot do registro de acessos cresce ~480 MB/h até o servidor o invalidar com 1 GB, em ~2 h. Isso deixa um buraco no registro do Marco Civil, e a pasta do WAL não volta a encolher.

Hoje, um `pg_cron` parado só aparece na checagem diária (`docs/ChecagemDiariaProd.md`, bloco 1), até 24 h depois.

## 2. Requisitos

1. **Independência:** o vigia não roda no `pg_cron`, no `pg_net` nem na fila de e-mail do banco. Ele vive fora do Supabase.
2. **Canal próprio:** o aviso chega à equipe por um caminho que não passa pelo Frila: o e-mail do próprio serviço de monitoramento, para o endereço da equipe. Pela decisão do Cauê de 08/11, alertas da equipe não vão para o Gmail pessoal dele.
3. **Sem superfície nova e sem dado pessoal:** reaproveitar a Edge Function pública `saude` (`verify_jwt = false`, que já responde 200 ou 503). A resposta pública não mostra números, nomes de job nem nada do registro de acessos.
4. **Custo zero no piloto** e alerta em até ~25 a 30 min depois de o `pg_cron` parar: 15 min de limiar da `verificar_saude`, mais até 5 min até a próxima checagem do monitor, mais os 10 min do "Alert only after" (pelo consumidor, ~20 a 25 min). Os limiares não mudaram: baixá-los é decisão do Cauê. O disco aguenta: sem o agendador, o slot leva ~2 h até 1 GB.

## 3. Desenho proposto

**(a) O sinal, dentro da `saude`.**
- Uma função `privado.idade_do_agendador()` (`security definer`, `search_path` vazio, só `service_role`) devolve os minutos desde a última rodada `succeeded` em `cron.job_run_details` destes jobs:
  - `verificar_saude`, que roda a cada 5 min: parado acima de 15 min;
  - `consumir_registro_acesso`, que roda a cada minuto: parado acima de 10 min, **só com a coleta ligada**;
  - `processar_fila_email`, que roda a cada minuto e entrega os alertas: parado acima de 10 min.
- A `saude`, que já conecta ao Postgres para o `select 1`, chama essa função. Se algum job passou do limiar, responde **503** com `status: "agendador_parado"`; o `HEAD` dá só o 503. O detalhe (qual job, há quanto tempo) vai só para o log da função, nunca para a resposta pública.
- Banco fora do ar continua dando 503 `indisponivel`, como hoje.

**(b) O vigia, fora do Supabase.**
- O monitor de uptime **HetrixTools** (plano grátis, seção 6) faz `HEAD /functions/v1/saude` a cada 5 min.
- Com "Alert only after 10 minutes", ele só avisa se o 503 durar 10 minutos. **Inferência:** isso equivale a 2 rodadas seguidas do `HEAD` a cada 5 min (`retornos/B-alerta-monitor-escolha.md:26`); pode exigir 3 falhas (aos 0, 5 e 10 min), conforme o HetrixTools conte o início da queda. Confirma-se no teste do cartão 2.
- O aviso vai por e-mail para a equipe, no `suporte@frilabr.com`.
- Não há segunda linha no GitHub Actions (decisão 6.4).

**(c) A ação continua humana.** O vigia avisa e não conserta. O plantonista segue a seção 3 do `docs/RUNBOOK-INCIDENTES.md`. Se o agendador não volta logo, desliga a coleta do registro de acessos (`docs/RunbookWalESlot.md`, seção 4).

## 4. Por que assim, e o que foi descartado

- **Alerta dentro do banco** (mais um item da `verificar_saude`): descartado, porque depende do próprio `pg_cron` que ele vigia.
- **Só o GitHub Actions:** descartado como primeira linha, pelo atraso do `schedule`.
- **Alertas e log drains da plataforma:** **não conferido** se o plano free oferece algum que veja o `pg_cron`. Se oferecer, fica como alternativa ao HetrixTools (6.1).
- **Vantagem da `saude`:** ela já é pública, já tem fumaça (`scripts/fumaca-prod-leitura.sh`) e não está no contrato (`contrato/openapi.yaml` não a cita; conferido em 08/11). Mudar o corpo dela é interno; a fumaça e quem espera "200 saudavel" mudam junto.

## 5. Riscos do desenho

- **Falso positivo depois de um restart planejado** (os jobs voltam com atraso): o monitor espera 2 falhas seguidas. Numa manutenção avisada, pausar o monitor.
- **A `saude` lendo `cron.job_run_details` em toda chamada:** a tabela cresce com um job a cada minuto. O custo da consulta, com a janela das últimas horas, não foi medido (não conferi os índices dela): medir no cartão de implementação, e limitar a consulta à última rodada de cada job.
- **O vigia externo é mais uma conta** (a `saude` não pede chave). Fica registrado em `docs/ESTADO.md` quando entrar.
- **A conta grátis do HetrixTools exige entrar no painel pelo menos uma vez a cada 90 dias.** Sem isso, o vigia some em silêncio. Isso vira um lembrete no plantão (cartão 2).

## 6. Decisões (do Cauê, 08/11/2026, pela Central e pela Forja)

**1. Serviço: HetrixTools, plano grátis.** O Opus Back pesquisou os termos, os preços e a documentação, lidos em 08/11/2026:
- os termos não proíbem uso comercial e preveem "one free HetrixTools account per person or organization" (https://hetrixtools.com/terms-of-service/). Ressalva: a cláusula de reembolso chama o grátis de "demo/trial";
- o monitor aceita GET ou HEAD e tem "Alert only after X minutes" (https://docs.hetrixtools.com/api-add-website-ping-service-smtp-uptime-monitor/), com "Every feature here comes with every plan, even Free" (https://hetrixtools.com/feature/website-monitor/);
- o grátis checa a cada minuto, mas pede entrar no painel a cada 90 dias e não manda aviso para outro destinatário ("Multiple email recipients": Free = "Not included", https://hetrixtools.com/pricing/uptime-monitor/).

**2. Conta e destino do aviso:**
- a conta fica na `frila.org@gmail.com`;
- o aviso chega ao `suporte@frilabr.com` por um filtro de encaminhamento do Gmail dessa conta, porque o grátis só avisa o e-mail da própria conta;
- se o encaminhamento não funcionar (a conferir no cartão 2), a decisão volta ao Cauê: criar a conta no próprio `suporte@frilabr.com`;
- nunca no Gmail pessoal do Cauê.

**3. Limiares:**
- 15 min para a `verificar_saude`;
- 10 min para o `consumir_registro_acesso` (só com a coleta ligada) e para a `processar_fila_email`;
- a carência é a checagem `HEAD` a cada 5 min com "Alert only after 10 minutes" (**Inferência:** equivale a 2 falhas seguidas; confirma-se no teste do cartão 2).

**4. Sem a segunda linha no GitHub Actions.**

## 7. Cartões que este desenho gera

1. `privado.idade_do_agendador()` mais o 503 `agendador_parado` na `saude`, com pgTAP da função, teste da Edge Function e fumaça atualizada. Vai ao Opus Back, depois do pacote 5.
2. Pelo portal:
   - criar a conta HetrixTools na `frila.org@gmail.com` e o monitor `HEAD` de 5 min com "Alert only after 10 minutes";
   - criar e testar o filtro de encaminhamento para o `suporte@frilabr.com`;
   - pôr o lembrete de login a cada 90 dias;
   - registrar tudo em `docs/ESTADO.md`.

   A Forja distribui depois do pacote 5. Só vale depois do cartão 1: antes dele, a `saude` não dá 503 com o agendador parado.
