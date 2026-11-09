# Desenho · Alerta de `pg_cron` parado que não depende do `pg_cron`

> **Só desenho. Nenhum código neste documento nem no PR que o traz.** As decisões em aberto estão na seção 6; a implementação vira cartões próprios (seção 7).

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
4. **Custo zero no piloto** e alerta em até ~15 min.

## 3. Desenho proposto

**(a) O sinal, dentro da `saude`.**
- Uma função `privado.idade_do_agendador()` (`security definer`, `search_path` vazio, só `service_role`) devolve os minutos desde a última rodada `succeeded` em `cron.job_run_details` destes jobs:
  - `verificar_saude`, que roda a cada 5 min: parado acima de 15 min;
  - `consumir_registro_acesso`, que roda a cada minuto: parado acima de 10 min, **só com a coleta ligada**;
  - `processar_fila_email`, que roda a cada minuto e entrega os alertas: parado acima de 10 min.
- A `saude`, que já conecta ao Postgres para o `select 1`, chama essa função. Se algum job passou do limiar, responde **503** com `status: "agendador_parado"`; o `HEAD` dá só o 503. O detalhe (qual job, há quanto tempo) vai só para o log da função, nunca para a resposta pública.
- Banco fora do ar continua dando 503 `indisponivel`, como hoje.

**(b) O vigia, fora do Supabase.**
- Um monitor de disponibilidade externo faz `HEAD /functions/v1/saude` a cada 5 min. Com 2 falhas seguidas, ele manda e-mail para o endereço da equipe.
- Qualquer serviço de uptime com plano gratuito e alerta por e-mail serve. A escolha é a decisão 6.1.
- **Segunda linha, opcional:** um workflow agendado do GitHub Actions (`schedule`, a cada 15 min) faz o mesmo `HEAD` e abre uma issue na falha. O `schedule` do GitHub pode atrasar ou pular rodadas sob carga, por isso ele não é a primeira linha.

**(c) A ação continua humana.** O vigia avisa e não conserta. O plantonista segue a seção 3 do `docs/RUNBOOK-INCIDENTES.md`. Se o agendador não volta logo, desliga a coleta do registro de acessos (`docs/RunbookWalESlot.md`, seção 4).

## 4. Por que assim, e o que foi descartado

- **Alerta dentro do banco** (mais um item da `verificar_saude`): descartado, porque depende do próprio `pg_cron` que ele vigia.
- **Só o GitHub Actions:** descartado como primeira linha, pelo atraso do `schedule`.
- **Alertas e log drains da plataforma:** **não conferido** se o plano free oferece algum que veja o `pg_cron`. Se oferecer, entra como alternativa na decisão 6.1.
- **Vantagem da `saude`:** ela já é pública, já tem fumaça (`scripts/fumaca-prod-leitura.sh`) e não está no contrato (`contrato/openapi.yaml` não a cita; conferido em 08/11). Mudar o corpo dela é interno; a fumaça e quem espera "200 saudavel" mudam junto.

## 5. Riscos do desenho

- **Falso positivo depois de um restart planejado** (os jobs voltam com atraso): o monitor espera 2 falhas seguidas. Numa manutenção avisada, pausar o monitor.
- **A `saude` lendo `cron.job_run_details` em toda chamada:** a tabela cresce com um job a cada minuto. O custo da consulta, com a janela das últimas horas, não foi medido (não conferi os índices dela): medir no cartão de implementação, e limitar a consulta à última rodada de cada job.
- **O vigia externo é mais uma conta e mais um segredo** (no máximo, o endereço de e-mail da equipe; a `saude` não pede chave). Fica registrado em `docs/ESTADO.md` quando entrar.

## 6. Decisões em aberto (do Cauê e da PO)

1. Qual serviço de monitoramento externo e em que conta.
2. O endereço que recebe o aviso.
3. Os limiares (15 min para a `verificar_saude`, 10 min para o consumidor e para a fila de e-mail) e a carência de 2 falhas.
4. Se a segunda linha do GitHub Actions entra.

## 7. Cartões que este desenho gera

1. `privado.idade_do_agendador()` mais o 503 `agendador_parado` na `saude`, com pgTAP da função, teste da Edge Function e fumaça atualizada.
2. Configurar o monitor externo (decisões 6.1 e 6.2) e registrar em `docs/ESTADO.md`.
3. (Opcional) O workflow agendado de segunda linha.
