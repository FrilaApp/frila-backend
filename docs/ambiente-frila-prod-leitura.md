# Configuração do Environment GitHub: `frila-prod-leitura`

Este documento registra a separação operacional de ambientes de CI/CD para leitura da infraestrutura de produção, permitindo execuções de monitoramento e auditoria automatizada (como a conferência diária de Auth via cron) sem exigir aprovação manual a cada execução.

---

## 1. Motivação e Isolamento de Segurança

- **Problema:** O workflow `.github/workflows/confere-auth-remoto.yml` é executado diariamente via cron (`17 11 * * *`). Quando o job de validação de produção estava configurado no Environment `frila-prod`, cada execução ficava travada no status `waiting`, exigindo que um revisor aprovasse o disparo manual diariamente (exemplo: run `41094976963`).
- **Natureza do Job:** O script [`scripts/conferir-auth-remoto.sh`](../scripts/conferir-auth-remoto.sh) realiza **estritamente leitura** (chamada HTTP `GET` na Management API do Supabase na rota `/v1/projects/{ref}/config/auth`), sem qualquer instrução de escrita, mutação de dados, alteração de regras ou deploy de código.
- **Solução:** Criação de um Environment específico no GitHub: **`frila-prod-leitura`**, sem revisores obrigatórios e com restrição de branch para a `develop`.

---

## 2. Passo a Passo para o Dono do Repositório (João Paulo / `jotape12-Dev`)

> 🔒 **Ação Manual Obrigatória do Dono:** A criação do Environment e o provisionamento do segredo devem ser realizados no painel web do GitHub pelo mantenedor. Nenhum agente automatizado tem permissão para ler segredos ou criar environments.

1. **Acessar as Configurações do Repositório:**
   - Navegue até `https://github.com/FrilaApp/frila-backend/settings/environments`.

2. **Criar o Novo Environment:**
   - Clique no botão **New environment**.
   - No campo **Name**, digite exatamente:
     ```text
     frila-prod-leitura
     ```
   - Clique em **Configure environment**.

3. **Configurar Regras de Proteção de Implantação (Deployment branches):**
   - Na seção **Deployment protection rules**:
     - **Required reviewers:** Deixe **desmarcado** (sem revisores), permitindo que jobs agendados por cron rodem autonomamente.
     - **Wait timer:** Deixe em 0.
   - Na seção **Deployment branches and tags**:
     - Selecione **Selected branches**.
     - Clique em **Add deployment branch or tag rule**.
     - Digite `develop` e confirme.
     - *(Opcional)* Se workflows de conferência forem rodar a partir da `main`, adicione também `main`.

4. **Copiar o Segredo do Supabase:**
   - Na seção **Environment secrets** do `frila-prod-leitura`:
     - Clique em **Add secret**.
     - **Name:** `SUPABASE_ACCESS_TOKEN`
     - **Value:** Cole o mesmo token de acesso da Management API do Supabase já configurado no Environment `frila-prod`.
     - Clique em **Add secret**.

5. **Aprovação do Run Pendente:**
   - Se houver run pendente no Environment legado (como o run `41094976963`), cancele-o ou aprove-o uma única vez, já que os novos runs passarão a utilizar `frila-prod-leitura`.
