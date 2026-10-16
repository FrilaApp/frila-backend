# Runbook de Operações e Resolução de Incidentes

Guia operacional técnico para diagnóstico, mitigação e resolução de incidentes no backend do Frila (`frila-backend`).

Todas as instruções e queries contidas neste documento foram rigorosamente validadas contra as migrações, scripts de automação e Edge Functions do repositório.

---

## 1. Despacho / Entrega Falhando por `frila.agendador_secret` Ausente

### Sintomas
- Chamadas a `public.publicar_vaga(...)` ou `public.cancelar_posicao(...)` falham imediatamente com status HTTP 500 ou erro de banco:
  ```text
  ERROR: Configuração frila.agendador_secret ausente no banco de dados
  CONTEXT: PL/pgSQL function privado.trg_disparar_despacho() line 15 at RAISE
  ```
- Publicação de novas vagas de urgência ou cancelamento de posições ficam bloqueados.
- Nenhuma mensagem nova de despacho é persistida em `pgmq.q_despacho`.

### Causa Raiz
O gatilho `trg_despacho_enfileirado` em `pgmq.q_despacho` executa `privado.trg_disparar_despacho()` a cada inserção na fila (`20260926010000_motor_despacho.sql`). A função exige que a configuração `frila.agendador_secret` esteja presente para autenticar a chamada HTTP via `pg_net` (`net.http_post`) para a Edge Function `despachar`. Se a variável estiver nula ou em branco, a função levanta exceção intencionalmente, abortando a transação mãe por design de segurança (comportamento cravado pelo teste pgTAP `supabase/tests/692_trg_disparar_despacho.sql`).

### Diagnóstico (Somente Leitura)
1. **Verificar se o parâmetro de banco está definido na sessão atual:**
   ```sql
   select current_setting('frila.agendador_secret', true) as agendador_secret_configurado;
   ```
   *Resultado esperado em ambiente operacional:* String não vazia (token opaco). Se retornar `NULL` ou `''`, o segredo está ausente.

2. **Verificar parâmetros persistidos no nível do banco (`pg_db_role_setting`):**
   ```sql
   select setdatabase::regdatabase as banco,
          setconfig as configuracoes
     from pg_db_role_setting;
   ```
   *Resultado esperado:* Uma das entradas em `setconfig` deve conter `frila.agendador_secret=<valor>`.

3. **Verificar mensagens retidas na fila de despacho:**
   ```sql
   select count(*) as total_na_fila,
          count(*) filter (where read_ct >= 5) as mensagens_com_teto_excedido
     from pgmq.q_despacho;
   ```

### Mitigação
1. **No ambiente local / CI:**
   Definir o segredo efêmero na sessão ou no banco de testes:
   ```sql
   alter database postgres set frila.agendador_secret = 'segredo-local-efemero';
   ```
2. **Em produção (`frila-prod`) ou homologação (`frila-dev`):**
   - Configurar o segredo persistente via painel do Supabase / Vault ou comando administrativo:
     ```sql
     alter database postgres set frila.agendador_secret = '<segredo_gerado_no_vault>';
     ```
   - Reiniciar as conexões ativas ou a instância para propagar a variável a todas as sessões do pooler.
   - Após a configuração, testar a publicação de uma vaga no painel administrativo.

### Quem Decide / Quem Age
- **Ambiente Local / CI:** Engenheiro responsável pelo teste.
- **Ambiente Remoto (`frila-dev` / `frila-prod`):** **`[DONO]`**. Exige credencial administrativa no painel do Supabase e acesso aos segredos do repositório/Vault.

---

## 2. Fila de E-mails Parada (`pgmq.q_email`, `processar_fila_email`, `enviar-email`)

### Sintomas
- Notificações por e-mail (denúncias da comunidade, contestações de turnos, comunicados à equipe) não chegam aos destinatários.
- A contagem de mensagens na fila `pgmq.q_email` cresce continuamente sem ser drenada.
- Coluna `concluido_em` da tabela `public.ocorrencia` não é preenchida ou e-mails de confirmação não são marcados.

### Causa Raiz
O fluxo de envio de e-mails depende de três elos (`20260929174512_emails_transacionais.sql` e `supabase/functions/enviar-email/index.ts`):
1. O trigger `trg_email_enfileirado` em `pgmq.q_email` chama `privado.trg_disparar_email()`.
2. O job periódico `processar_fila_email` (`* * * * *`) invoca `privado.disparar_email()` a cada minuto.
3. `privado.disparar_email()` dispara `net.http_post` para a Edge Function `enviar-email`, que consome a fila com visibilidade controlada (`VT_PADRAO_EMAIL = 60s`, teto de 5 leituras) e envia via SMTP.
Falhas no segredo do agendador, queda do servidor SMTP ou credenciais inválidas congelam o consumo. Se `frila.agendador_secret` estiver vazio, `privado.disparar_email()` emite um `WARNING` no log e retorna `NULL` sem abortar a transação.

### Diagnóstico (Somente Leitura)
1. **Verificar volumetria e estado da fila de e-mails:**
   ```sql
   select count(*) as total_mensagens,
          count(*) filter (where read_ct = 0) as pendentes,
          count(*) filter (where read_ct >= 5) as travadas_teto_leitura
     from pgmq.q_email;
   ```

2. **Inspecionar as mensagens mais antigas na fila:**
   ```sql
   select msg_id,
          read_ct,
          enqueued_at,
          vt,
          message->>'origem' as origem,
          message->>'ocorrencia_id' as ocorrencia_id
     from pgmq.q_email
    order by msg_id asc
    limit 10;
   ```

3. **Verificar se o job do pg_cron está ativo:**
   ```sql
   select jobid, jobname, schedule, active, command
     from cron.job
    where jobname = 'processar_fila_email';
   ```

4. **Verificar o histórico de execuções do job:**
   ```sql
   select runid, status, return_message, start_time, end_time
     from cron.job_run_details
    where jobid = (select jobid from cron.job where jobname = 'processar_fila_email')
    order by start_time desc
    limit 10;
   ```

5. **Verificar status das requisições disparadas pelo `pg_net`:**
   ```sql
   select id, status, error_msg, created
     from net._http_response
    order by id desc
    limit 10;
   ```

### Mitigação
1. Se o segredo `frila.agendador_secret` estiver ausente, configurá-lo conforme o Item 1.
2. Se o status no `pg_net` for `500` ou erro de conexão com a Edge Function:
   - Checar logs da Edge Function `enviar-email` no Supabase CLI:
     ```bash
     supabase functions logs enviar-email
     ```
   - Validar credenciais SMTP (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`) conforme `supabase/operacao/configurar-smtp-auth.md`.
3. Se mensagens estiverem travadas por `read_ct >= 5` devido a falha permanente no destinatário (erro 550 do servidor de correio), arquivar manualmente a mensagem no `pgmq` para desobstruir a fila:
   ```sql
   select pgmq.archive('email', <msg_id>);
   ```

### Quem Decide / Quem Age
- **Investigação de logs e fila:** Engenharia de Backend.
- **Configuração de SMTP e descarte manual de mensagens em produção:** **`[DONO]`**.

---

## 3. Jobs do `pg_cron` Falhando (`cron.job_run_details`)

### Sintomas
- Turnos expirados não transitam para `cumprida` às 5 em 5 minutos (`fechar_turnos_e_vagas`).
- Avaliações não são liberadas após o fim do turno (RN07).
- Reconciliação diária de comparecimento não roda às 06:00 UTC (`reconciliar_reputacao_diaria`).
- Limpeza de retenção LGPD não expurga eventos antigos às 06:30 UTC (`retencao_e_limpeza_diaria`).

### Causa Raiz
O banco possui 13 jobs ativos agendados no `pg_cron` (`390_agendamentos_do_pg_cron.sql`). Todos invocam funções no formato canônico `select privado.<funcao>()`. Se uma migração revogar privilégios, alterar a assinatura da função sem default para argumentos, fixar um `search_path` que oculte tipos de dados ou introduzir uma exceção não tratada, o job falha em silêncio no background sem notificar o app.

### Diagnóstico (Somente Leitura)
1. **Identificar jobs desativados no catálogo do cron:**
   ```sql
   select jobid, jobname, schedule, active, command
     from cron.job
    where not active;
   ```
   *Resultado esperado:* 0 linhas. Nenhum job pode estar com `active = false`.

2. **Consultar o log de falhas recentes de todos os jobs:**
   ```sql
   select j.jobname,
          d.runid,
          d.status,
          d.return_message,
          d.start_time,
          d.end_time
     from cron.job_run_details d
     join cron.job j on j.jobid = d.jobid
    where d.status = 'failed'
    order by d.start_time desc
    limit 20;
   ```

3. **Verificar integridade da assinatura de todas as 13 funções agendadas:**
   ```sql
   select j.jobname,
          j.command,
          p.proname,
          p.prosecdef,
          p.proconfig
     from cron.job j
     left join pg_proc p
       on p.proname = substring(j.command from '^select privado\.([a-z_]+)\(\)$')
      and p.pronamespace = 'privado'::regnamespace
    where p.proname is null
       or not (p.pronargs = p.pronargdefaults);
   ```
   *Resultado esperado:* 0 linhas. Se retornar alguma linha, a função foi renomeada ou passou a exigir argumento obrigatório.

4. **Verificar concessão de privilégios para execução dos jobs:**
   ```sql
   select j.jobname,
          has_function_privilege('postgres', 'privado.' || substring(j.command from '^select privado\.([a-z_]+)\(\)$') || '()', 'execute') as postgres_ok,
          has_function_privilege('service_role', 'privado.' || substring(j.command from '^select privado\.([a-z_]+)\(\)$') || '()', 'execute') as service_role_ok
     from cron.job j;
   ```

### Mitigação
1. Se um job estiver desativado por engano:
   ```sql
   update cron.job set active = true where jobname = '<nome_do_job>';
   ```
2. Se a falha for provocada por erro interno na procedure (ex: `fora_da_janela`, violação de FK, deadlock transitório), analisar o `return_message` e corrigir o registro inconsistente ou a procedure através de nova migração.
3. Para reexecutar imediatamente em homologação/produção e aferir o retorno:
   ```sql
   -- Exemplo de execução pontual controlada (somente via service_role/postgres):
   select privado.fechar_turnos_e_vagas();
   ```

### Quem Decide / Quem Age
- **Diagnóstico:** Engenharia de Backend.
- **Reativação de jobs ou aplicação de patches em produção:** **`[DONO]`**.

---

## 4. Exclusão de Conta que Falhou no Meio (Híbrida: Anonimizada no Banco, Credencial Viva no Auth)

### Sintomas
- Usuário clica em "Excluir conta" nas configurações do app (RF19, LGPD Art. 18 VI).
- O app exibe o alerta: *"Não foi possível concluir a exclusão da conta. Tente novamente."* (status HTTP 502 devolvido pela Edge Function `excluir-conta`).
- Se o usuário fecha o aplicativo, ao reabri-lo recebe erro `401 nao_autenticado` e não consegue mais acessar a tela de exclusão.
- Se tenta criar uma nova conta usando o mesmo e-mail, o cadastro falha porque a credencial no Supabase Auth (`auth.users`) continua ocupando o e-mail.

### Causa Raiz
A Edge Function `supabase/functions/excluir-conta/index.ts` executa em duas fases:
1. **Passo 3:** Invoca `privado.excluir_conta(userId)` no Postgres. A transação comita no banco, anonimizando dados cadastrais (nome para "Ex-profissional", e-mail para `excluido-<uuid>@anonimizado.frila.app`, telefone `+5500000000000`) e cancelando turnos futuros.
2. **Passo 4:** Chama `DELETE /auth/v1/admin/users/:id` na Admin API do Supabase Auth.
Se a chamada ao Passo 4 sofrer timeout de rede (`AbortSignal.timeout(10000)`) ou receber `503 Service Unavailable` da infraestrutura de Auth, a função devolve `502 erro_interno` estruturado (conforme coberto pelo PR #218). No entanto, o Passo 3 já foi comitado no Postgres, deixando a conta em estado híbrido.
*(Problema documentado no Item 11 do painel `PAINEL-DECISOES-DONO.md`)*.

### Diagnóstico (Somente Leitura)
1. **Identificar contas com pedido de exclusão comitado no Postgres:**
   ```sql
   select u.id as usuario_id,
          u.estado,
          u.email as email_anonimizado,
          p.id as pedido_id,
          p.criado_em as pedido_criado_em,
          p.concluido_em as banco_concluido_em
     from public.usuario u
     join privado.pedido_exclusao_conta p on p.usuario_id = u.id
    where u.estado = 'excluida'
      and p.concluido_em is not null
    order by p.concluido_em desc
    limit 10;
   ```

2. **Cruzar com a tabela de credenciais do Auth (`auth.users`) para confirmar o estado híbrido:**
   ```sql
   select a.id,
          a.email,
          a.created_at,
          u.estado as estado_usuario_banco
     from auth.users a
     join public.usuario u on u.id = a.id
    where u.estado = 'excluida';
   ```
   *Se retornar linhas:* A credencial continua existindo no Auth mesmo com os dados anonimizados no Postgres.

### Mitigação
1. **Retentativa Administrativa Idempotente:**
   A Edge Function `excluir-conta` e a procedure `privado.excluir_conta` foram projetadas para idempotência total (comprovado no teste unitário 6 do PR #218 e no teste pgTAP `supabase/tests/290_excluir_conta.sql`). Disparar novamente o comando de remoção para o ID afetado não gera erro de duplicação:
   ```bash
   # [DONO] Execução via curl com token administrativo service_role:
   curl -X POST "https://<projeto>.supabase.co/functions/v1/excluir-conta" \
     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
     -H "Content-Type: application/json" \
     -d '{"confirmar": true}'
   ```
2. **Exclusão direta na Admin API do Auth:**
   ```bash
   # [DONO] Remoção definitiva da credencial presa no Auth:
   curl -X DELETE "https://<projeto>.supabase.co/auth/v1/admin/users/<USUARIO_ID>" \
     -H "Authorization: Bearer <SERVICE_ROLE_KEY>" \
     -H "apikey: <SERVICE_ROLE_KEY>"
   ```
3. **Decisão estrutural pendente (Item 11 do `PAINEL-DECISOES-DONO.md`):**
   Aprovação do dono para incluir contas com `estado = 'excluida'` no job automático de varredura `privado.contas_auth_orfas` (`supabase/functions/limpar-contas-orfas`).

### Quem Decide / Quem Age
- **`[DONO]` exclusivamente.** Envolve exclusão de credenciais em produção e decisão sobre a política do job de purga automática de contas híbridas.

---

## 5. CI Vermelha por pgTAP / Plano de Consulta / Contrato

### Sintomas
- Pull Request aberto contra `develop` ou commit bloqueado com jobs reprovados no GitHub Actions.
- Portões automatizados do workflow `.github/workflows/ci.yml` falhando.

### Roteiro de Diagnóstico e Validação Local (Sem `supabase db reset`)

> [!WARNING]
> Nunca execute `supabase db reset` localmente sob restrição severa de espaço em disco no host de desenvolvimento (~850 MiB livres) e nunca ligue o daemon Docker local caso ele esteja parado. Utilize scripts focados e verifique os logs do GitHub Actions.

#### A. Falha em `Migrações sem colisão de versão`
- **Causa comum:** Duas branches criaram migrações com o mesmo carimbo de data/hora ou um teste novo usou `now()` sem congelar `frila.agora`.
- **Scripts de conferência no repositório:**
  ```bash
  # Verifica colisão de versão e nomeclatura:
  ./scripts/teste-migracoes-sem-colisao.sh
  ./scripts/migracoes-sem-colisao.sh

  # Verifica bombas-relógio de relógio estático em testes:
  ./scripts/teste-relogio-em-testes.sh
  ./scripts/relogio-em-testes.sh
  ```
- **Correção:** Renomear o timestamp da migração mais recente ou adicionar `set local frila.agora = '...'` no início do teste pgTAP.

#### B. Falha em `O contrato acompanhou o código` ou `Contrato em dia com o Frila`
- **Causa comum:** Mudança em colunas de tabelas `public` ou parâmetros de RPCs públicas sem atualização sincronizada no `openapi.yaml`.
- **Scripts de conferência no repositório:**
  ```bash
  # Verifica se alteração de código público exigiu contrato:
  ./scripts/teste-contrato-acompanha.sh
  ./scripts/contrato-acompanha-o-codigo.sh "origin/develop"

  # Verifica paridade do espelho local com o contrato canônico:
  ./scripts/contrato-em-dia.sh
  ```
- **Correção:** Atualizar `openapi.yaml` refletindo os novos parâmetros e schemas.

#### C. Falha em `Plano do caminho quente com o volume do DF`
- **Causa comum:** Introdução de `Seq Scan` em tabelas quentes (`usuario`, `posicao`, `vaga`, `disponibilidade`) sob volume de dados representativo (350 mil linhas sintéticas do DF).
- **Scripts de conferência no repositório:**
  ```bash
  ./scripts/teste-planos-com-carga.sh
  # A execução de planos-com-carga.sh exige container de banco dedicado com carga.
  ```
- **Correção:** Revisar joins e subqueries (evitar subqueries que sofrem pull-up para Hash Join sem índice adequado) e garantir que predicados casem com índices parciais existentes.

#### D. Falha em `Migrações e pgTAP` (`mutacao.sh` ou `contrato-responde.sh`)
- **Causa comum:** Um teste pgTAP foi alterado mas não derruba o teste quando a regra de negócio/constraint é removida (teste sobrevivente à mutação) ou o schema JSON retornado pela RPC não bate com o OpenAPI.
- **Scripts de conferência no repositório:**
  ```bash
  # Validação de lint plpgsql sem achados novos:
  ./scripts/lint-conhecido.sh

  # Autoteste da linha de base de mutação:
  ./scripts/teste-mutacao-linha-de-base.sh

  # Portões de contrato (corpo e promessas):
  ./scripts/teste-contrato-responde.sh
  ./scripts/teste-contrato-promete.sh
  ```
- **Correção:** Adicionar asserções determinísticas de mutação com rollback no teste pgTAP e adequar os JSONBs retornados pelas funções ao schema oficial.

### Quem Decide / Quem Age
- **Autor do PR / Engenharia de Backend.** Correção técnica de código e testes em branches de trabalho.

---

## 6. Rollback de Migração (Migrações são Imutáveis)

### Sintomas
- Uma migração recém-aplicada em homologação (`frila-dev`) ou produção (`frila-prod`) causou quebra de contrato, erro de execução ou incompatibilidade operacional.

### Princípio Fundamental de Engenharia
No Frila, as migrações são **estritamente lineares, imutáveis e forward-only**:
1. **É terminantemente proibido:**
   - Deletar arquivos de migração já aplicados em `origin/develop` ou ambientes remotos.
   - Editar retroativamente migrações antigas (`./scripts/migracoes-imutaveis.sh` bloqueia o CI se qualquer migração comitada for alterada).
   - Executar `supabase db reset` em ambientes de homologação ou produção.
2. A integridade do histórico do banco de dados depende de linearidade absoluta registrada no catálogo `supabase_migrations.schema_migrations`.

### Procedimento Canônico de Resolução (Forward Fix)
Para desverter uma migração problemática, o procedimento obrigatório consiste em criar uma **nova migração corretiva linear à frente**:

1. **Criar a migração corretiva:**
   ```bash
   supabase migration new desfazer_<nome_da_operacao>
   ```

2. **Escrever a instrução reversa explícita no novo arquivo:**
   - Se adicionou uma constraint incorreta:
     ```sql
     alter table public.<tabela> drop constraint <nome_da_constraint>;
     ```
   - Se adicionou uma coluna:
     ```sql
     alter table public.<tabela> drop column <nome_da_coluna>;
     ```
   - Se alterou o corpo de uma função:
     Reescrever a função para o corpo anterior conhecido com `create or replace function ...` garantindo `set search_path = ''` e privilégios intactos.

3. **Garantir os testes pgTAP correspondentes:**
   - Criar ou atualizar a suíte de teste garantindo que o estado anterior e as regras de negócio permanecem íntegros sob rollback.

4. **Aplicar em produção com segurança:**
   O script de implantação remota `./scripts/aplicar-remoto.sh` aplica estritamente as migrações que ainda não constam no banco remoto:
   ```bash
   # [DONO] Aplicação em homologação / produção:
   ./scripts/aplicar-remoto.sh frila-dev
   ./scripts/aplicar-remoto.sh frila-prod
   ```

### Quem Decide / Quem Age
- **Criação do PR corretivo:** Engenharia de Backend.
- **Aprovação do PR e execução do `aplicar-remoto.sh` em `frila-prod`:** **`[DONO]`**.
