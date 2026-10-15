# Proposta: Leitura de `agendador_secret` via Supabase Vault

**Data:** 15/10/2026  
**Autor:** Faísca (Backend)  
**Status:** Proposta técnica (aguarda aprovação do dono do produto)

---

## 1. Contexto e Diagnóstico

### 1.1 Como funciona hoje (GUC de Banco)
O motor de despacho assíncrono e o serviço de e-mails transacionais dependem de um segredo compartilhado (`agendador_secret`) para autenticar chamadas HTTP via `pg_net` para as Edge Functions (`despachar` e `enviar-email`).

Atualmente, ambas as funções no banco:
- `privado.disparar_despacho()` (definida em `20260926010000_motor_despacho.sql`)
- `privado.disparar_email()` (definida em `20260929174512_emails_transacionais.sql`)

obtêm esse segredo lendo o parâmetro de configuração do Postgres (GUC):
```sql
v_secret text := current_setting('frila.agendador_secret', true);
```

### 1.2 O Problema no Supabase Hospedado (`frila-dev` e `frila-prod`)
No ambiente local Docker, o usuário `postgres` opera como superusuário e permite executar:
```sql
ALTER DATABASE postgres SET frila.agendador_secret = '...';
```
No entanto, no Supabase hospedado (projetos gerenciados na AWS), o usuário `postgres` **não possui privilégios de superusuário** (`superuser`). Quando se tenta definir uma variável GUC personalizada em nível de banco de dados, o Postgres rejeita com o erro:
```
ERROR: 42501: permission denied to set parameter "frila.agendador_secret"
```

### 1.3 Bloqueio da Entrega Contínua
O script de validação e entrega remota `scripts/aplicar-remoto.sh` inspeciona a tabela de sistema `pg_db_role_setting`:
```bash
if rodar "select count(*) as n from pg_db_role_setting s
            cross join unnest(s.setconfig) c
           where c like 'frila.agendador_secret=_%'" | grep -q '"n":0'; then
  echo "  ✗ frila.agendador_secret não está configurado neste banco"
  exit 1
fi
```
Como o parâmetro não pode ser gravado em `pg_db_role_setting` pelo usuário `postgres`, a entrega de migrações no projeto `frila-dev` (`jcobftbhbqdikratzizz`) está **bloqueada**.

---

## 2. Solução Proposta: Supabase Vault

A recomendação técnica oficial da plataforma Supabase para armazenamento de credenciais, chaves de API e segredos acessíveis por SQL/triggers é a extensão nativa **Supabase Vault** (`supabase_vault`), que reside no esquema `vault`.

### 2.1 Como o Supabase Vault funciona
1. **Segurança e Criptografia:** Os segredos são criptografados em repouso com `pgsodium` / KMS gerenciado.
2. **Acesso por SQL:** O usuário `postgres` possui permissão nativa de leitura na view `vault.decrypted_secrets`:
   ```sql
   select decrypted_secret
     from vault.decrypted_secrets
    where name = 'agendador_secret'
    limit 1;
   ```
3. **Gestão Operacional:** O segredo pode ser inserido/atualizado por SQL (sem exigir privilégio de superusuário):
   ```sql
   select vault.create_secret('VALOR_DO_SEGREDO', 'agendador_secret', 'Segredo do agendador e despacho');
   ```
   ou visualmente no Dashboard do Supabase em **Project Settings → Vault**.

### 2.2 Estratégia de Fallback (Compatibilidade Retroativa)
Para garantir que a mudança não quebre ambientes locais nem exija reescrever os testes unitários existentes, a leitura do segredo no banco adotará uma estratégia de fallback:
```sql
v_secret text := coalesce(
  (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
  nullif(current_setting('frila.agendador_secret', true), '')
);
```
Dessa forma:
- No `frila-dev` e `frila-prod`: lê com prioridade do **Vault**.
- Na suíte de testes `pgTAP` e desenvolvimento local: pode ler do **Vault** ou de `set local frila.agendador_secret = ...`.

---

## 3. Análise de Impacto

### 3.1 Impacto no `motor_despacho` (`privado.disparar_despacho`)
- **Arquivo / Migração:** Requer uma nova migração (ex: `202610..._ler_agendador_secret_do_vault.sql`) atualizando `privado.disparar_despacho(p_vaga_id uuid)`.
- **Alteração:**
  Substituir a atribuição de `v_secret` pela consulta à view `vault.decrypted_secrets` com fallback para `current_setting`.
- **Performance:**
  A descriptografia de um único registro na view `vault.decrypted_secrets` via `pgsodium` leva menos de 0.2 ms, mantendo íntegro o caminho crítico pós-commit de publicação de vaga.
- **Segurança:**
  A função `privado.disparar_despacho` já é `security definer` pertencente a `postgres`, que já possui `SELECT` na view `vault.decrypted_secrets`. Nenhuma concessão excessiva a `anon` ou `authenticated` é criada.

### 3.2 Impacto no `emails_transacionais` (`privado.disparar_email`)
- **Arquivo / Migração:** Atualização de `privado.disparar_email()` na mesma nova migração.
- **Alteração:**
  Mesma resolução de `v_secret` via `vault.decrypted_secrets`.
- **Resiliência:**
  Se o segredo não for encontrado no Vault nem no GUC, a função mantém o comportamento projetado: emite um `raise warning` e retorna `null`, garantindo que os pedidos de e-mail permaneçam seguros na fila `pgmq.q_email` sem interromper o job `pg_cron`.

### 3.3 Impacto na Edge Function `despachar`
- **Arquivo:** `supabase/functions/despachar/index.ts`.
- **Alteração de Código:** **NENHUMA**.
  A Edge Function recebe o segredo via cabeçalho HTTP (`x-agendador-secret` ou `Authorization: Bearer <secret>`) e o valida em tempo constante contra `Deno.env.get("AGENDADOR_SECRET")`:
  ```typescript
  const secretHeader = req.headers.get("x-agendador-secret");
  igualEmTempoConstante(secretHeader, segredoEsperado);
  ```
  Como o banco continua enviando o mesmo cabeçalho HTTP com o valor descriptografado, a Edge Function não sofre nenhuma modificação de código.
- **Requisito Operacional:** O valor registrado em `vault.create_secret(..., 'agendador_secret')` deve ser rigorosamente idêntico ao configurado nas Edge Functions via `supabase secrets set AGENDADOR_SECRET=...`.

### 3.4 Impacto em `scripts/aplicar-remoto.sh`
- **Arquivo:** `scripts/aplicar-remoto.sh`.
- **Alteração:**
  Atualizar a verificação prévia do segredo (linhas 121-131). Substituir a inspeção de `pg_db_role_setting` por consulta ao Vault:
  ```bash
  echo "▸ O segredo do agendador está no banco"
  if rodar "select count(*) as n from vault.decrypted_secrets where name = 'agendador_secret'" | grep -q '"n":0'; then
    echo "  ✗ agendador_secret não está configurado no Supabase Vault deste banco"
    echo
    echo "  Cadastre o segredo no Vault (Dashboard ou vault.create_secret) e em"
    echo "  AGENDADOR_SECRET das Edge Functions antes de prosseguir."
    exit 1
  fi
  echo "  ✓"
  ```
  Isso valida a presença do segredo sem jamais vazar seu valor textual nos logs.

### 3.5 Impacto nas Suítes de Teste (`pgTAP`, CI e Scripts de Concorrência)
- **101 Arquivos de Teste pgTAP (`supabase/tests/*.sql`):**
  Graças ao `coalesce` com `current_setting('frila.agendador_secret', true)`, todos os testes unitários que executam `set local frila.agendador_secret = 'segredo-de-teste'` continuam passando **sem necessidade de alteração**.
- **Testes de Integração e Ciclo (`scripts/ciclo-completo.sh`, `scripts/corrida-ciclo.sh`):**
  Podem ser mantidos como estão ou receber suporte para semear o Vault nos contêineres locais efêmeros.
- **Ambiente Local Docker:**
  A imagem oficial de Postgres do Supabase já vem com `vault` pré-instalado e ativado.

---

## 4. Alternativas Consideradas

| Alternativa | Prós | Contras | Veredito |
|---|---|---|---|
| **A. Supabase Vault (Proposta)** | Nativo da plataforma, criptografado em repouso por `pgsodium`, UI pronta no Dashboard, não requer superuser. | Requer esquema `vault` ativo. | **Recomendada** |
| **B. Tabela própria `privado.configuracao`** | Simples de implementar sem dependência externa. | Segredo armazenado em texto puro no banco; maior risco de vazamento em dumps. | Descartada |
| **C. Carregar GUC via `custom_variable_classes`** | Mantém código SQL 100% inalterado. | Impossível no Supabase hospedado (parâmetro de servidor inacessível). | Inviável |

---

## 5. Próximos Passos (Aguardando Aprovação do Dono)

1. **Aprovação:** O dono valida a migração de estratégia (GUC → Vault).
2. **Definição Operacional:**
   - Inserir o segredo no Vault do `frila-dev` via Dashboard ou SQL.
   - Garantir paridade com `AGENDADOR_SECRET` das Edge Functions.
3. **Implementação (Faísca):**
   - Criar migração atualizando `privado.disparar_despacho()` e `privado.disparar_email()`.
   - Adicionar teste pgTAP específico validando a leitura via Vault e o fallback via GUC.
   - Atualizar `scripts/aplicar-remoto.sh` e documentação.
   - Submeter PR para revisão da Bigorna e validação na CI.
