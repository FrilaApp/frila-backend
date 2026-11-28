# Runbook de Incidentes — Pagamentos V1 (Rascunho)

Guia operacional de diagnóstico, contenção e conciliação para incidentes de **Pagamentos V1 (Modo Seleção — Pix + Split + Escrow via Asaas)** no `frila-backend`.

Escrito em 23/11/2026 em **estado de rascunho**, antes da execução do sandbox real do Asaas (protocolo `2074170` pendente) e antes da primeira migração financeira na `develop` (`20c5fe9`).

> **Convenções obrigatórias (Parceiro Crítico — padrão `docs/RunbookHotfixERollback.md:11-12`):**
> - **Fato:** acompanhado de `arquivo:linha` verificado em `frila-backend` (`origin/develop` @ `20c5fe9`) ou referência explícita ao rascunho de contrato (`FrilaApp/frila-documentacao#306` @ `70d3c624`).
> - **Hipótese / Proposta:** marcada explicitamente como **`[HIPÓTESE]`** ou **`proposta, a confirmar`**.
> - **Lacuna em aberto:** marcada explicitamente como **`[depende do sandbox/B1-B2]`** ou **`[decisão do JP]`** — este runbook **não** inventa comportamento do PSP nem política financeira/jurídica não chancelada.
> - **Privacidade (LGPD):** seguindo `docs/NotificacaoDaEquipe.md:98-100`, nenhum alerta em Slack, e-mail de operação ou comentário de PR pode conter CPF, telefone, e-mail de usuário, chave Pix pessoal ou payload bruto com dados pessoais; usar apenas IDs internos (`cobranca_id`, `vaga_id`, `posicao_id`, `turno_id`, `payment_id` do PSP).

Este documento complementa — e não substitui — `docs/RUNBOOK-INCIDENTES.md` (infraestrutura, filas `pgmq`, `pg_cron` e migrações corretivas), `docs/RunbookHotfixERollback.md` (hotfix e rollback em `frila-prod`) e `docs/OrdemCanonicaDeTravas.md` (hierarquia de travas no PostgreSQL, `BE-07`).

---

## 1. Matriz de Alçada (Quem Decide)

> **Fato de governança vigente:**
> - No repositório e em `frila-prod`, os quatro sócios têm comando de operação e o Environment `frila-prod` exige aprovação de outro revisor com `prevent_self_review: true` (`docs/RunbookHotfixERollback.md:24-27, 201-206`). Agente de IA nunca aprova, nunca mescla e nunca executa ação financeira em Prod (`docs/RunbookHotfixERollback.md:31-32`).
> - No contrato de Pagamentos V1 (`FrilaApp/frila-documentacao#306` @ `70d3c624`, rascunho `0.2.109`, matriz B5-1 — **`[decisão do JP]`** para chancela final), a Casa distingue **operador** e **administrador** (`papel_membro` já existe no banco).

| Papel | O que pode fazer | O que NÃO pode fazer |
|---|---|---|
| **Operador da Casa** | Emitir cobrança Pix de vaga/posição da própria casa e acompanhar status/QR (`FrilaApp/frila-documentacao#306`, rascunho — `[decisão do JP]`). | Solicitar estorno, abrir ajuste manual, acessar conta-mãe/painel Asaas ou alterar dados bancários da casa. |
| **Administrador da Casa** | Tudo que o Operador faz + solicitar estorno dentro das regras de janela do contrato (`FrilaApp/frila-documentacao#306`, rascunho — `[decisão do JP]`) e contestar disputa com evidências do turno. | Forçar transição de estado no banco, cancelar cobrança duplicada direto no PSP, liberar Escrow fora do contrato ou compensar saldo negativo. |
| **Sócio do Frila (`[DONO]`)** | Contenção técnica, diagnóstico somente leitura em Prod, acionamento de suporte Asaas, comunicação formal com Casa/Profissional e **1ª ou 2ª assinatura** na conciliação manual com dupla alçada (seção 3). | Executar ajuste financeiro manual, estorno fora do fluxo ou compensação contábil **sozinho** (exige dupla alçada de 2 sócios distintos — seção 3). |

---

## 2. Catálogo de Incidentes Prováveis

> **Nota sobre consultas SQL nesta seção:** na `develop` atual (`20c5fe9`), ainda **não existem** tabelas financeiras nem Edge Functions de pagamento (`supabase/migrations/` não contém migração de Pagamentos V1). Por isso, consultas que referenciam tabelas financeiras futuras estão marcadas como **`[HIPÓTESE — nomes de tabela/coluna a confirmar na 1ª migração V1]`** e consultas de infraestrutura existente citam `arquivo:linha` real.

---

### 2.1 Pix Duplicado

- **Cenários cobertos:** (a) timeout na chamada `POST /v3/payments` seguido de nova tentativa gerando `totalCount >= 2` para o mesmo `externalReference`; (b) Casa paga um QR Code antigo/substituído após cancelamento ou reemissão.
- **Sintoma:**
  - Duas cobranças com o mesmo `externalReference` no Asaas (`totalCount >= 2`), ou dois eventos `PAYMENT_RECEIVED` / `PAYMENT_CONFIRMED` associados à mesma `posicao_id` / `vaga_id`.
  - Casa relata débito duplo no extrato bancário.
- **Como detectar:**
  - Sondagem `GET /v3/payments?externalReference=<ref>` retornando `totalCount >= 2` (cenário `S-B3.1c` do plano de provas).
  - Alerta automático de `conciliacao_estado = 'divergente_estado'` / `revisao_manual = true` `[HIPÓTESE — tabela financeira V1]`.
  - Conferência somente leitura de webhooks recebidos e de requisições `pg_net` (`net._http_response`, padrão de `docs/RUNBOOK-INCIDENTES.md:122-127`).
- **Quem decide:**
  - **Operador / Administrador da Casa:** apenas reporta e fornece comprovante (EndToEndId) pelo suporte.
  - **Sócio (`[DONO]` — dupla alçada):** decide qual cobrança permanece vinculada à posição e autoriza o estorno da cobrança excedente.
- **Passo a passo seguro:**
  1. **Congelar automaticamente (ou confirmar congelamento):** manter o registro local em `revisao_manual = true`, preservando **todos** os `payment_id` observados no PSP.
  2. **Consultar o PSP (somente leitura):** rodar `GET /v3/payments?externalReference=<ref>` e `GET /v3/payments/{id}` para cada ID encontrado, registrando `status`, `value`, `netValue` e `escrow.status`.
  3. **Classificar o caso:**
     - *Caso A (apenas 1 cobrança `RECEIVED`/`CONFIRMED` e a outra `PENDING` não paga):* expirar/cancelar a cobrança `PENDING` excedente após confirmar que não houve liquidação em andamento e vincular a cobrança paga via conciliação com dupla alçada (seção 3).
     - *Caso B (ambas liquidadas):* manter 1 cobrança vinculada à posição e iniciar estorno integral da cobrança excedente via dupla alçada, verificando antes se há colchão de liquidez na conta-mãe para a tarifa não reembolsável (`[depende do sandbox/B1-B2]` — cenários `S-B2.1a`/`S-B2.1b`).
  4. **Registrar protocolo** com os dois `payment_id`, decisão e quem assinou as duas alçadas.
- **O que NUNCA fazer:**
  - **NUNCA** cancelar (`DELETE`) cobrança duplicada nem reemitir automaticamente ao detectar `totalCount >= 2` (regra explícita de `S-B3.1c`: falha fechada em `revisao_manual`).
  - **NUNCA** disparar 2º `POST /v3/payments` após timeout sem antes concluir a janela de sondagem `GET` (`+15s / +45s / +120s`, cenário `S-B3.1b`).
  - **NUNCA** apagar a linha duplicada no banco para "limpar o erro" — destrói a trilha contábil.

---

### 2.2 Webhook Fora de Ordem, Atrasado ou Duplicado

- **Sintoma:**
  - Casa pagou o Pix, mas o app continua mostrando cobrança `pendente` após minutos.
  - Evento `PAYMENT_SPLIT_DONE` ou `PAYMENT_REFUNDED` chega antes de `PAYMENT_RECEIVED` / `PAYMENT_CONFIRMED`.
  - Mesmo `event.id` reenviado múltiplas vezes pelo Asaas, ou fila de webhooks pausada/suspensa no painel Asaas por sequência de respostas não-`200`.
  - Tentativa de entrega rejeitada com `401` por divergência de `asaas-access-token`.
- **Como detectar:**
  - Logs da Edge Function receptora de webhook (`supabase functions logs <funcao-webhook>`, padrão de `docs/RUNBOOK-INCIDENTES.md:134`) com aumento de `401`, `500` ou timeouts.
  - Cobranças locais em `pendente` com idade acima do limiar enquanto `GET /v3/payments/{id}` já retorna `RECEIVED`/`CONFIRMED`.
  - Verificação da saúde geral do banco/Edge Functions (`GET /functions/v1/saude`, `.github/workflows/vigia-saude.yml:4-6`) e filas/crons (`cron.job_run_details`, `docs/RUNBOOK-INCIDENTES.md:169-181`).
- **Quem decide:**
  - **Operador / Administrador:** não atua; apenas aguarda convergência ou aciona suporte se o prazo do turno estiver próximo.
  - **Sócio (`[DONO]`):** diagnostica causa (token, queda de Edge Function, suspensão de fila no Asaas) e dispara reconciliação controlada por leitura (`GET`) se necessário.
- **Passo a passo seguro:**
  1. **Checar integridade da borda:** confirmar que `saude` responde `200 {"ok":true}` e inspecionar logs da Edge Function de webhook (sem imprimir o valor de `asaas-access-token`).
  2. **Checar duplicata / fora de ordem:** confirmar que o manipulador de webhook é idempotente por `event.id` e aplica transição monotônica (não regride estado se `PAYMENT_SPLIT_DONE` chegar antes de `PAYMENT_RECEIVED` — cenário `S-B3.3`).
  3. **Se `401` em massa:** verificar se houve rotação de `ASAAS_WEBHOOK_ACCESS_TOKEN` desalinhada entre painel Asaas e segredo da Edge Function; corrigir o segredo e reativar a fila no painel Asaas.
  4. **Se houve atraso ou perda:** rodar rotina de reconciliação passiva (sondagem `GET /v3/payments/{id}` e `GET /v3/payments/{id}/escrow`) para convergir o estado local com o estado real no PSP antes de qualquer ação manual.
- **O que NUNCA fazer:**
  - **NUNCA** desabilitar a validação de `asaas-access-token` nem aceitar webhook sem autenticação em tempo constante (padrão já aplicado em `supabase/functions/_compartilhado/auth.ts:47, 65`).
  - **NUNCA** retornar `200 OK` descartando o evento antes de persistir/enfileirar com durabilidade, nem retornar `500` para evento já processado (duplicata deve responder `200 OK` com efeito único).
  - **NUNCA** reverter estado local de `pago`/`estornado` de volta para `pendente` ao receber evento antigo fora de ordem.

---

### 2.3 Disputa Perto da Expiração do Escrow

- **Contexto técnico:** `[HIPÓTESE baseada na doc pública Asaas — confirmação final depende do sandbox/B1-B2]` a Conta Escrow do Asaas **não possui pausa**; ao atingir `expirationDate`, o valor do split é liberado automaticamente para a subconta PF do profissional (`escrow.status = DONE`).
- **Sintoma:**
  - Cobrança em estado `disputa` (ou contestação/ocorrência aberta no turno) com `expirationDate - now() <= 72h` (margem fixa do watchdog definida no plano de provas, independente do tempo medido no sandbox).
  - Risco iminente de liberação automática ao profissional antes da decisão da disputa.
- **Como detectar:**
  - Alerta do watchdog de Escrow (seção 4) disparando em `T - 72h` e escalando em `T - 24h` para qualquer cobrança em `disputa` com `escrow.status = ACTIVE` `[HIPÓTESE — tabela financeira V1]`.
  - Consulta somente leitura em `GET /v3/payments/{id}/escrow` confirmando `status = ACTIVE` e `expirationDate`.
- **Quem decide:**
  - **Operador da Casa:** não decide disputa.
  - **Administrador da Casa:** pode enviar evidências do turno (check-in/check-out, ocorrência) dentro do prazo.
  - **Sócio (`[DONO]` — dupla alçada):** decide o desfecho da disputa (estorno à Casa vs. liberação ao Profissional) **antes** de `T - 24h`, respeitando as regras contratuais e jurídicas (`[decisão do JP]`).
- **Passo a passo seguro:**
  1. **Consultar evidências do turno (somente leitura):** estado de `public.posicao`, `public.turno` (check-in/check-out/verificação) e `public.ocorrencia`.
  2. **Confirmar estado no PSP:** `GET /v3/payments/{id}` e `GET /v3/payments/{id}/escrow` (verificar se não há MED ou estorno já em curso).
  3. **Decidir em dupla alçada antes de `T - 24h`:**
     - *Desfecho favorável à Casa (estorno):* executar estorno conforme arranjo validado no sandbox (`[depende do sandbox/B1-B2]` — `S-B2.1b` / `S-B2.2` / `S-B2.2b`) e acompanhar até `refund.status = DONE`.
     - *Desfecho favorável ao Profissional (liberação):* encerrar disputa no banco e aguardar expiração natural ou executar `finish` se autorizado (`[depende do sandbox/B1-B2]` — `S-B2.3a`/`S-B2.3b`).
  4. **Atenção a `privado.anular_falta`:** **fato** (`supabase/migrations/20261115060000_anulacao_falta_por_admin.sql:149-195`): `privado.anular_falta` altera **apenas** reputação (`posicao.falta = false`, `recalcular_comparecimento`, auditoria) e **não** movimenta dinheiro nem Escrow (`BE-05`, `[decisão do JP]` sobre Alternativa B1). Se houver ajuste financeiro, ele é uma operação separada em dupla alçada.
- **O que NUNCA fazer:**
  - **NUNCA** desabilitar a configuração global de Escrow no painel/API do Asaas para "segurar" uma disputa — a documentação oficial do Asaas alerta que desabilitar o Escrow encaminha as garantias existentes para encerramento, **liberando os valores**!
  - **NUNCA** deixar disputa sem decisão ultrapassar `T - 24h` contando com "estornar depois que liberar" (após `DONE`, o profissional pode sacar o saldo).
  - **NUNCA** rodar `privado.anular_falta` presumindo que isso pausará Escrow, pagará o profissional ou estornará a Casa.

---

### 2.4 Estorno com Saldo Retido / Falha de Estorno no PSP

- **Sintoma:**
  - Tentativa de estorno (`POST /v3/payments/{id}/refund`) retorna `HTTP 400` (ex.: saldo insuficiente na conta-mãe para cobrir a tarifa não reembolsável do Pix — cenário `S-B2.1a`), ou falha por timeout deixando incerteza se o estorno foi criado (`S-B3.2b`), ou falha porque o Escrow exige tratamento específico (`[depende do sandbox/B1-B2]` — `S-B2.1b`).
- **Como detectar:**
  - Log da Edge Function de estorno com `status = 400` ou timeout.
  - `GET /v3/payments/{id}` mostrando `refunds[]` vazio (recusa limpa) ou `refunds[0].status = PENDING` (em curso).
  - `GET /v3/finance/balance` da conta-mãe abaixo do colchão mínimo configurado (`[decisão do JP]` sobre valor do colchão).
- **Quem decide:**
  - **Administrador da Casa:** solicita o estorno no fluxo normal do app; se falhar, recebe aviso de processamento em análise (sem expor erro interno do PSP).
  - **Sócio (`[DONO]` — dupla alçada):** recompõe colchão da conta-mãe, verifica `refunds[]` no PSP e autoriza nova tentativa controlada somente após prova de ausência de estorno pendente.
- **Passo a passo seguro:**
  1. **Em caso de timeout:** **NÃO** reenviar `POST .../refund`. Sondar `GET /v3/payments/{id}` (campo `refunds[]`) na janela de convergência (`S-B3.2b`). Se houver estorno `PENDING` ou `DONE`, apenas adotar o estado local.
  2. **Em caso de `HTTP 400` com `refunds[] = []`:**
     - Conferir `GET /v3/finance/balance` da conta-mãe e `GET /v3/payments/{id}/escrow`.
     - Se a causa for falta de colchão na conta-mãe: recompor o colchão operacional (dupla alçada financeira) e só então reexecutar o estorno sob a mesma chave de idempotência / novo protocolo registrado.
     - Se o PSP recusar estorno sobre Escrow ativo exigindo `finish` prévio: **interromper estornos automáticos** (condição do Kill Switch `C-SB5` — `[depende do sandbox/B1-B2]`) e escalar para os sócios.
  3. **Confirmar convergência:** validar `refund.status = DONE` e `saldo_disponivel_pf == 0` para a cobrança estornada.
- **O que NUNCA fazer:**
  - **NUNCA** reenviar `POST /v3/payments/{id}/refund` cegamente após timeout (risco de estorno duplicado ou saldo negativo).
  - **NUNCA** executar `POST .../escrow/finish` na subconta PF antes de estornar sem prova de bloqueio de saque — libera o saldo para o profissional sacar antes do estorno (`C-SB5`).
  - **NUNCA** marcar a cobrança como `estornado` no banco local antes de `refund.status = DONE` (ou `PENDING` formalmente modelado) confirmado pelo PSP.

---

### 2.5 Saldo Negativo (Conta-Mãe ou Subconta PF)

- **Sintoma:**
  - `GET /v3/finance/balance` da conta-mãe ou de uma subconta PF retorna valor `< 0`.
  - Novas operações de estorno ou transferência começam a falhar por insuficiência de saldo.
  - Pode ocorrer após estorno pós-saque, tarifa não coberta pelo colchão ou devolução forçada (MED).
- **Como detectar:**
  - Alerta diário/contínuo de saldo abaixo do piso (seção 4) na conta-mãe ou `< 0` em qualquer subconta PF monitorada `[proposta, a confirmar — depende de acesso à API de saldo por subconta, S-B2.3a/S-B2.3b]`.
- **Quem decide:**
  - **Operador / Administrador da Casa:** não tem visibilidade nem alçada.
  - **Sócio (`[DONO]` — dupla alçada):** decide contenção (pausar novas emissões se conta-mãe comprometida), aporte de recomposição e eventual cobrança/bloqueio administrativo da conta que originou o débito (`[decisão do JP]` sobre política de perda/recuperação).
- **Passo a passo seguro:**
  1. **Extrair extrato no PSP (somente leitura):** identificar a transação exata (`payment_id`, `refund_id`, tarifa ou MED) que levou o saldo a `< 0`.
  2. **Cruzar com o banco do Frila:** verificar `vaga_id`, `posicao_id`, `turno_id` e histórico de ocorrências/disputas.
  3. **Conter sangria:** se for saldo negativo na conta-mãe por falha sistêmica (ex.: loop de estorno ou tarifa incorreta), suspender novas emissões/estornos pela feature flag interna do Frila (nunca pela chave global de Escrow do Asaas!).
  4. **Recompor e registrar:** aporte/ajuste na conta-mãe com dupla alçada e registro contábil; se for subconta PF por fraude/MED, seguir seção 2.8 e política jurídica (`[decisão do JP]`).
- **O que NUNCA fazer:**
  - **NUNCA** "compensar" saldo negativo debitando silenciosamente saldo de outro turno/profissional não relacionado.
  - **NUNCA** desligar o Escrow global do Asaas como medida de contenção.

---

### 2.6 Subconta Recusada ou Suspensa no KYC

- **Sintoma:**
  - Profissional (PF sem MEI) tem abertura de subconta recusada, pendente de documentação adicional ou conta suspensa pelo antifraude/KYC do Asaas.
  - Caso crítico: KYC é suspenso **enquanto já existe cobrança paga com saldo retido em Escrow** para aquele profissional.
- **Como detectar:**
  - Webhook ou consulta de status cadastral da subconta no Asaas indicando `REJECTED` / `AWAITING_ACTION_FROM_USER` / conta bloqueada `[depende do sandbox/B1-B2 e confirmação escrita do Asaas]`.
  - Tentativa de emitir cobrança com split para `walletId` inativo/recusado retornando erro `400`/`403` do PSP.
- **Quem decide:**
  - **Operador / Administrador da Casa:** não vê dados de KYC do profissional (privacidade/LGPD); recebe apenas status operacional de que o profissional não está apto a receber ou que a cobrança precisa de outro candidato.
  - **Sócio (`[DONO]`):** acompanha pendência documental via suporte, decide liberação de vaga/estorno se o turno não puder ocorrer e escala ao Asaas se houver saldo preso em Escrow.
- **Passo a passo seguro:**
  1. **Antes do pagamento (pré-emissão):** bloquear emissão de cobrança Pix com split para profissional cujo KYC não esteja aprovado (`[proposta, a confirmar]` — gate pré-emissão no backend). Orientar o profissional a regularizar os documentos no fluxo oficial.
  2. **Após pagamento (KYC suspenso com saldo em Escrow):**
     - Consultar `GET /v3/payments/{id}/escrow` e status da subconta no Asaas.
     - **Se o turno ainda não ocorreu e foi cancelado:** estornar a Casa seguindo a seção 2.4.
     - **Se o turno já foi cumprido e verificado:** abrir protocolo formal com o Asaas para orientação sobre regularização do titular e liberação do repasse — **não** criar segunda subconta para o mesmo CPF.
  3. **Registrar protocolo** sem armazenar fotos de documentos/selfies em logs ou Slack (alinhado à remoção de upload de identidade no `#595`, `supabase/migrations/20261123150000_remover_upload_verificacao_identidade.sql:19-20`).
- **O que NUNCA fazer:**
  - **NUNCA** criar uma segunda subconta no Asaas para o mesmo profissional para "contornar" reprovação de KYC.
  - **NUNCA** pagar o profissional "por fora" via Pix manual da conta-mãe enquanto o valor original continua em Escrow ou pendente na subconta bloqueada (risco de pagamento em dobro).
  - **NUNCA** expor o motivo detalhado de KYC/antifraude do profissional para a Casa (violação de privacidade/LGPD).

---

### 2.7 Conta Demo Tentando Cobrar ou Liquidar

- **Fatos verificados na `develop` (`20c5fe9`):**
  - Contas de revisão da App Store entram por `supabase/functions/entrar-demonstracao/index.ts:1-8, 88-93` e recebem sessão idêntica à de um usuário real.
  - `privado.conta_de_demonstracao()` (`supabase/migrations/20260924180000_vagas_abertas_e_detalhe.sql:36-44`) lê `auth.uid()` da sessão; em jobs `pg_cron`, triggers ou Edge Functions sob `service_role` (`auth.uid() IS NULL`), ela retorna **`false`** (tratando a conta demo como real!).
  - Contas demo têm isenção de janela de check-in/check-out (`supabase/migrations/20261114020000_checkin_recusa_depois_do_fim.sql:65` e `20261114030000_checkout_recusa_depois_do_limite.sql:55`).
  - O achado **`BE-05`** ainda está **ABERTO** na `develop` (`20c5fe9`) aguardando decisão do JP (Alternativa A1: `privado.exigir_conta_real(usuario_id)` + trigger na tabela financeira) — **portão obrigatório antes de ativar Pagamentos V1 em Prod**.
- **Sintoma:**
  - Tentativa de emissão de cobrança Pix, criação de `customer`/subconta no Asaas ou seleção em cron de liquidação envolvendo `usuario.demonstracao = true` (seja contratante, membro da casa ou profissional).
  - Em operação com `BE-05` implementado: erro `403 sem_permissao (conta_demonstracao)` bloqueando a operação antes de qualquer chamada HTTP ao PSP.
- **Como detectar:**
  - Alerta imediato (Severidade P0) se qualquer requisição ao Asaas ou linha financeira referenciar um `usuario_id` com `demonstracao = true`.
  - Consulta somente leitura em `public.usuario` (`where demonstracao = true`) cruzada com a tabela financeira futura `[HIPÓTESE]`.
- **Quem decide:**
  - **Operador / Administrador:** não aplicável (conta demo é uso exclusivo de revisão da App Store / demonstração controlada).
  - **Sócio (`[DONO]`):** contém imediatamente (desliga feature flag de pagamentos ou expira `DEMONSTRACAO_ATIVA_ATE` se houver vazamento para o PSP) e cancela cobrança indevida no Asaas.
- **Passo a passo seguro:**
  1. **Se bloqueado na barreira (`403 conta_demonstracao`):** confirmar nos logs da Edge Function que **zero** chamadas HTTP saíram para `api.asaas.com`. Avaliar se a revisão da Apple precisa de ajuste de UX (ex.: ocultar tela de cobrança para conta demo — `[decisão do JP]`).
  2. **Se vazou para o Asaas (incidente P0):**
     - Desativar imediatamente a janela `DEMONSTRACAO_ATIVA_ATE` (ou feature flag de pagamentos) para cessar novas emissões.
     - Consultar no Asaas se houve cobrança criada/paga; se `PENDING`, cancelar no PSP; se paga (não deveria ocorrer em demo), estornar em dupla alçada e abrir incidente P0 + migração corretiva seguindo `docs/RunbookHotfixERollback.md`.
- **O que NUNCA fazer:**
  - **NUNCA** usar `privado.conta_de_demonstracao()` (sem parâmetro `usuario_id`) dentro de crons, webhooks ou funções `service_role`.
  - **NUNCA** liberar Pagamentos V1 em `frila-prod` com o achado `BE-05` aberto.
  - **NUNCA** rodar scripts de teste/demonstração (`scripts/ciclo-completo.sh`, `scripts/demonstracao.sh`) contra `frila-prod` (`docs/RunbookHotfixERollback.md:115-116`).

---

### 2.8 MED (Mecanismo Especial de Devolução) / Devolução Abusiva

- **Contexto regulatório:** segundo o guia público do Banco Central do Brasil, o MED aplica-se a fundada suspeita de fraude/golpe ou falha operacional de participante (não a desacordo comercial simples), envolve bloqueio cautelar de recursos e análise pelo PSP/instituições participantes; o enquadramento contratual concreto do Frila é **`[decisão do JP / parecer jurídico B6]`**.
- **Sintoma:**
  - Notificação do Asaas (webhook, e-mail operacional ou painel) informando abertura de MED / bloqueio cautelar sobre um Pix já recebido (com ou sem disputa aberta no app).
  - Risco crítico: Casa abre MED no banco dela **e** pede estorno no Frila ao mesmo tempo (risco de **devolução em dobro**).
- **Como detectar:**
  - Alerta de evento de devolução/contestação/bloqueio vindo do Asaas (payload exato de webhook de MED **`[depende do sandbox/B1-B2 e confirmação escrita do Asaas]`**).
  - Divergência entre saldo bloqueado e saldo livre no Asaas (`GET /v3/finance/balance` / painel Asaas).
- **Quem decide:**
  - **Operador / Administrador da Casa:** não tem alçada para resolver MED no sistema; se for abuso comprovado, pode sofrer suspensão de conta pelo Frila.
  - **Sócio (`[DONO]` — dupla alçada) + jurídico (`[decisão do JP]`):** reúne dossiê probatório, responde ao Asaas dentro do prazo regulamentar e decide bloqueio preventivo da conta da Casa se houver indício de abuso.
- **Passo a passo seguro:**
  1. **Travar qualquer estorno interno imediatamente:** antes de aprovar ou executar qualquer `POST .../refund` em cobrança sob disputa, verificar no PSP se há MED/bloqueio cautelar em andamento. Se houver, **congelar** a cobrança em `revisao_manual = true` para impedir devolução duplicada.
  2. **Montar dossiê probatório (somente leitura no Postgres):**
     - `vaga_id`, `posicao_id`, `turno_id`, horários de publicação, aceite, check-in, check-out, verificação de presença e ocorrências registradas (`public.vaga`, `public.posicao`, `public.turno`, `public.ocorrencia`).
     - Log de auditoria da emissão do Pix e da confirmação de pagamento.
  3. **Responder ao Asaas no prazo regulamentar:** enviar as evidências pelo canal oficial do PSP (nunca por canal informal) demonstrando prestação legítima do turno (se MED abusivo) ou concordando com a devolução (se fraude confirmada).
  4. **Aguardar encerramento do MED no PSP** antes de qualquer lançamento compensatório ou estorno adicional.
  5. **Se confirmado abuso (turno cumprido e verificado com MED indevido):** avaliar suspensão preventiva da conta contratante e medidas contratuais (`[decisão do JP / parecer jurídico B6]`).
- **O que NUNCA fazer:**
  - **NUNCA** executar estorno voluntário (`POST .../refund`) enquanto houver MED/bloqueio cautelar aberto sobre o mesmo Pix (risco direto de devolução dupla e saldo negativo).
  - **NUNCA** ignorar prazo de defesa do MED no Asaas — a ausência de resposta tende a consolidar a devolução contra o recebedor.
  - **NUNCA** compartilhar dados pessoais desnecessários de terceiros fora do canal seguro exigido pelo PSP/autoridade.

---

## 3. Conciliação Manual com Dupla Alçada

> **Por que existe:** a vistoria de segurança e o plano de provas (`S-B3.1b`, `S-B3.1c`, `S-B3.2a`, `S-B3.2b`) adotam **falha fechada**: diante de duplicidade, timeout inconclusivo ou divergência entre Postgres e Asaas, o sistema **congela** em `revisao_manual = true` (`conciliacao_estado = 'divergente_estado'`) e **nunca** "adivinha" o estado financeiro.
>
> **Alinhamento com governança existente:** o Environment `frila-prod` já opera com 4 sócios revisores e `prevent_self_review: true` (`docs/RunbookHotfixERollback.md:201-206`). A conciliação financeira manual segue o mesmo princípio: **quem propõe e executa o diagnóstico NÃO pode ser a única pessoa a aprovar a ação financeira**.

### 3.1 Quando a dupla alçada é obrigatória
1. Resolução de qualquer cobrança em `revisao_manual = true` / `divergente_estado` (Pix duplicado, timeout inconclusivo de emissão, `finish` ou `refund`).
2. Estorno manual fora do fluxo automático do app (ex.: disputa perto da expiração do Escrow, estorno parcial excepcional ou cobrança duplicada).
3. Qualquer lançamento compensatório no ledger após `privado.anular_falta` (se Alternativa B1 de `BE-05` for aprovada — `[decisão do JP]`).
4. Recomposição/ajuste por saldo negativo ou desfecho de MED.

### 3.2 Procedimento passo a passo (4 etapas)

| Etapa | Responsável | Ação obrigatória | Evidência registrada |
|---|---|---|---|
| **1. Congelamento e leitura** | Sócio 1 (Preparador) | Confirmar `revisao_manual = true`; ler estado no Postgres (somente leitura) e no Asaas (`GET /v3/payments/{id}`, `GET .../escrow`, `GET /v3/finance/balance`); verificar ausência de MED aberto. | Snapshot com carimbo UTC, `cobranca_id`, `payment_id`(s), `status` local vs. PSP, `value`/`netValue`. **Zero PII.** |
| **2. Proposta escrita** | Sócio 1 (Preparador) | Escrever proposta objetiva (qual ação será executada, em qual `payment_id`, valor exato em centavos, impacto no saldo da mãe e da PF, e por que não gera duplicidade). | Registro em issue/ticket operacional ou tabela de auditoria de conciliação (`[decisão do JP]` sobre ferramenta). |
| **3. Revisão e 2ª assinatura** | Sócio 2 (Aprovador — **pessoa distinta do Sócio 1**) | Conferir independentemente o estado no PSP e no banco contra a proposta; confirmar que o valor respeita os limites vigentes (`privado.limites_valor_diaria_centavos()`, R$ 50..R$ 2.000 em `supabase/migrations/20261123100000_limites_valor_diaria_be02.sql:23-33`) e que não há devolução concorrente. | Aprovação nominal com data/hora UTC (`aprovador_id != preparador_id`). |
| **4. Execução e fechamento** | Sócio 1 (ou Sócio 2) | Executar a ação única aprovada (no PSP e/ou RPC administrativa auditada, respeitando `docs/OrdemCanonicaDeTravas.md:48-50` — nenhuma chamada externa dentro de trava `FOR UPDATE`). Reconsultar `GET` no PSP e no Postgres para provar convergência. | ID da operação no PSP (`refund_id` / `payment_id`), estado final convergente e encerramento do protocolo. |

### 3.3 Regras invioláveis da conciliação manual
- **Sem autoaprovação:** `preparador_id <> aprovador_id` (mesma regra do `frila-prod`).
- **Trilha imutável:** nunca editar ou apagar registros históricos; correções são sempre lançamentos novos com referência ao registro original (mesma filosofia de `scripts/migracoes-imutaveis.sh` e do ledger contábil).
- **Ordem de travas (`BE-07`):** nenhuma RPC administrativa de conciliação pode inverter `vaga -> posicao -> entidades_financeiras` nem segurar trava de linha durante chamada HTTP ao Asaas (`docs/OrdemCanonicaDeTravas.md:48-50`).

---

## 4. Alertas Mínimos e Quem Recebe

> **Infraestrutura de alerta já existente na `develop` (`20c5fe9`):**
> - **Slack (`#alertas-prod`):** via `SLACK_WEBHOOK_URL` e `scripts/notificar-slack.sh` / `.github/workflows/vigia-saude.yml:4, 18` (hoje usado pelo vigia de saúde a cada 10 min).
> - **E-mail da equipe (sócios):** via `scripts/notificar-equipe.sh` (`docs/NotificacaoDaEquipe.md:44-46`), destinatários padrão Cauê, Jotapê e Fabrício — **proibido incluir PII no corpo** (`docs/NotificacaoDaEquipe.md:98-100`).
> - **E-mail de produto (usuário final):** Edge Function `enviar-email` (`docs/NotificacaoDaEquipe.md:10-12`).
>
> *Nota:* os limiares numéricos e SLAs abaixo são **`proposta, a confirmar`** (`[decisão do JP]`) até a calibragem pós-sandbox e piloto.

| # | Sinal / Condição de Alerta | Severidade | Canal | Quem recebe | Ação esperada |
|---|---|---|---|---|---|
| **A1** | Qualquer cobrança/operação financeira envolvendo `usuario.demonstracao = true` | **P0 (Crítico)** | Slack `#alertas-prod` + e-mail sócios | Sócios (`[DONO]`) | Contenção imediata (seção 2.7); verificar se houve chamada ao PSP. |
| **A2** | `revisao_manual = true` ou `totalCount >= 2` no mesmo `externalReference` (Pix duplicado / timeout inconclusivo) | **P1 (Alto)** | Slack `#alertas-prod` + e-mail sócios | Sócios (`[DONO]`) | Iniciar conciliação manual com dupla alçada (seção 3) antes do turno/estorno. |
| **A3** | Cobrança em `disputa` com `expirationDate - now() <= 72h` (escalar novamente em `<= 24h`) | **P1 (Alto)** | Slack `#alertas-prod` + e-mail sócios | Sócios (`[DONO]`) | Decidir disputa em dupla alçada antes de `T - 24h` (seção 2.3). |
| **A4** | Saldo da conta-mãe abaixo do colchão mínimo (`[decisão do JP]`) ou qualquer saldo `< 0` | **P1 (Alto)** | Slack `#alertas-prod` + e-mail sócios | Sócios (`[DONO]`) | Investigar causa e recompor colchão antes de novos estornos (seções 2.4 e 2.5). |
| **A5** | Abertura de MED / bloqueio cautelar reportado pelo Asaas | **P1 (Alto)** | Slack `#alertas-prod` + e-mail sócios | Sócios (`[DONO]`) | Congelar estorno interno, montar dossiê e responder no prazo regulamentar (seção 2.8). |
| **A6** | Webhook Asaas com `>= 3` falhas `5xx`/`401` em 15 min ou fila de webhooks suspensa | **P1 (Alto)** | Slack `#alertas-prod` | Sócios (`[DONO]`) | Checar logs da Edge Function, token `asaas-access-token` e status da fila (seção 2.2). |
| **A7** | `GET /functions/v1/saude` fora do ar (já implementado em `.github/workflows/vigia-saude.yml`) | **P1 (Alto)** | Slack `#alertas-prod` | Sócios (`[DONO]`) | Seguir `docs/RUNBOOK-INCIDENTES.md`; validar impacto em webhooks e crons. |
| **A8** | Subconta PF recusada/suspensa no KYC com turno confirmado ou Escrow ativo | **P2 (Médio)** | Slack `#alertas-prod` (+ aviso no app ao profissional, sem expor motivo à Casa) | Sócios (`[DONO]`) + Profissional (via app) | Tratar conforme seção 2.6; nunca criar 2ª subconta. |
| **A9** | Estorno recusado (`HTTP 400`) ou `PENDING` acima do tempo esperado | **P2 (Médio)** | Slack `#alertas-prod` | Sócios (`[DONO]`) | Sondar `GET /v3/payments/{id}` (`refunds[]`) e seguir seção 2.4. |

---

## 5. Pendências Explícitas (`[depende do sandbox/B1-B2]` e `[decisão do JP]`)

Este runbook **não** fecha os itens abaixo; eles precisam ser atualizados neste documento assim que resolvidos:

### 5.1 Itens que dependem do Sandbox real do Asaas / Bloqueios `B1`–`B2` (`[depende do sandbox/B1-B2]`)
1. **Estorno total sobre Escrow ativo sem `finish` prévio (`S-B2.1b`, Kill Switch `C-SB5`):** confirmar se o Asaas aceita `POST /v3/payments/{id}/refund` com `escrow.status = ACTIVE` mantendo `saldo_disponivel_pf == 0`. Se falhar, os procedimentos da seção 2.4 e da seção 2.3 precisam ser redesenhados.
2. **Credencial para `POST .../escrow/finish` (`S-B2.3a` vs `S-B2.3b`, Kill Switch `C-SB4`):** confirmar se a API Key da conta-mãe pode encerrar o Escrow da subconta PF ou se exige chave individual da subconta (impacta quem pode operar liberação manual e consulta de saldo PF).
3. **Tarifa real do Pix (`value - netValue`) e comportamento de estorno parcial/líquido (`S-B1.1–1.3`, `S-B2.2`, `S-B2.2b`):** definem o valor exato do colchão mínimo da conta-mãe (alerta A4).
4. **Payloads exatos de webhooks de KYC e MED no Asaas:** confirmar nomes de eventos e campos recebidos no endpoint de webhook para automatizar alertas A5 e A8.
5. **Tempo real de liquidação SPI e KYC de subconta PF sem MEI:** mesmo após o sandbox, dependem de confirmação comercial escrita do Asaas (`B6`) e validação em piloto controlado (sandbox não simula SPI nem antifraude real).

### 5.2 Itens que dependem de Decisão do JP / Sócios (`[decisão do JP]`)
1. **Chancela da matriz de papéis B5-1 (`FrilaApp/frila-documentacao#306`):** confirmar se Operador emite Pix e apenas Administrador estorna.
2. **Política de tarifa no estorno (`B2-A` estorno integral absorvido pelo colchão da mãe vs. `B2-B` estorno líquido descontando tarifa, sujeito a parecer jurídico/contábil `B6`)** e **valor do colchão mínimo** na conta-mãe (alerta A4).
3. **Resolução do achado `BE-05`:** confirmar Alternativa A1 (barreira `privado.exigir_conta_real(usuario_id)` + trigger na tabela financeira) e Alternativa B1 (`privado.anular_falta` estritamente reputacional, ajuste financeiro separado em dupla alçada), além do comportamento de UX da conta demo na revisão da Apple.
4. **Canal e ferramenta oficial de registro da dupla alçada** (seção 3.2: tabela de auditoria no banco + issue privada no GitHub ou painel administrativo dedicado) e SLAs exatos dos alertas A1–A9.
5. **Política jurídica/financeira de perda e recuperação** em caso de saldo negativo na subconta PF ou MED abusivo (seções 2.5 e 2.8).
6. **Escopo de Urgência e Lote na V1:** marcados pendentes no rascunho de contrato (`FrilaApp/frila-documentacao#306`).

---

## 6. O que NÃO foi comprovado

1. **Nenhuma tabela financeira, RPC de pagamento ou Edge Function do Asaas existe na `develop` (`20c5fe9`)** — este runbook foi redigido a partir do contrato em rascunho (`frila-documentacao#306` @ `70d3c624`), do plano de provas (`v4`) e dos mecanismos de operação existentes no `frila-backend`.
2. **0 de 13 cenários foram executados no sandbox real do Asaas** (protocolo `2074170` pendente); até lá, o comportamento do PSP citado nas seções 2.1–2.8 é baseado na documentação pública do Asaas e no harness mock local.
3. **Nenhum alerta financeiro (A1–A6, A8–A9) está implementado ou testado**; apenas A7 (`vigia-saude.yml`) existe na `develop` (`20c5fe9`).
4. **Nenhuma conciliação manual com dupla alçada foi ensaiada de ponta a ponta** em `frila-dev` ou `frila-prod`.
5. **Este PR é estritamente de documentação em rascunho** — não altera migrações, funções SQL, Edge Functions nem workflows de CI.
