# Configuração do Environment GitHub: `frila-prod-leitura`

Este documento registra a separação operacional de ambientes de CI/CD para leitura da infraestrutura de produção, permitindo execuções de monitoramento e auditoria automatizada (como a conferência diária de Auth via cron) sem exigir aprovação manual e **sem expor credenciais com poder de escrita**.

---

## 1. Motivação e Isolamento de Segurança (Privilégios Mínimos)

- **O Problema da Fila:** O workflow `.github/workflows/confere-auth-remoto.yml` é executado diariamente via cron (`17 11 * * *`). Quando o job de validação de produção utilizava o Environment `frila-prod`, cada execução ficava travada no status `waiting`, exigindo aprovação manual de um revisor diariamente (exemplo: run `41094976963`).
- **Natureza do Job:** O script [`scripts/conferir-auth-remoto.sh`](../scripts/conferir-auth-remoto.sh) realiza **estritamente leitura** (chamada HTTP `GET` na Management API do Supabase na rota `/v1/projects/{ref}/config/auth`), sem qualquer instrução de escrita, mutação de dados, alteração de regras ou deploy de código.
- **Risco de Segurança (Bypass de Portão):**
  - O Environment `frila-prod` protege o token com permissão administrativa exigindo `Required reviewers`.
  - Se criássemos um Environment `frila-prod-leitura` sem revisor copiando a mesma credencial com poder de escrita de `frila-prod`, qualquer workflow ou PR integrado na branch `develop` ganharia acesso irrestrito de escrita no banco e no deploy de produção sem revisão humana.
- **Solução com Privilégios Mínimos:** Criação do Environment **`frila-prod-leitura`** sem revisores obrigatórios na branch `develop`, provisionado exclusivamente com um **Personal Access Token de Escopo Reduzido (Scoped Token)** do Supabase, com permissão estrita de **leitura** (Read-only) sobre o projeto de produção.

---

## 2. Passo a Passo para o Dono do Repositório (João Paulo / `jotape12-Dev`)

> [!CAUTION]
> **NUNCA COPIE O TOKEN DO `frila-prod`:**
> O token existente no Environment `frila-prod` possui poder total de escrita (migrações DDL e deploy). Para o ambiente sem revisores `frila-prod-leitura`, você DEVE gerar um novo token exclusivo de leitura no Supabase seguindo os passos abaixo.

### Passo 1: Gerar o Token de Escopo Reduzido no Supabase
1. Acesse o painel do Supabase: **Account > Access Tokens** (ou acesse diretamente [supabase.com/dashboard/account/tokens](https://supabase.com/dashboard/account/tokens)).
2. Clique em **Generate new token**.
3. **Nome sugerido:** `ci-confere-auth-prod-leitura`
4. **Escopo do Token:**
   - Selecione exclusivamente a organização da Frila.
   - Restrinja **SÓ ao projeto `frila-prod`** (`hbjkkcenbudiezmamiak`).
5. **Permissões Granulares:**
   - Selecione permissões em **Read** (nunca Read-write).
   - Habilite a permissão que cobre a leitura de configurações de autenticação do projeto (`Project Settings: Read` ou escopo equivalente de configuração).
6. Copie o token gerado (prefixo `sbp_`).

---

### Passo 2: Validar o Token Localmente (Estritamente Somente-Leitura)
No seu terminal local, valide que o token autoriza a leitura da configuração de Auth em produção, sem executar qualquer operação de mutação (regra fundamental: nenhuma escrita no Prod):

1. Carregue o token em memória de forma oculta (sem salvar em histórico):
   ```bash
   read -s TOKEN   # cole o token e pressione Enter
   ```

2. **Teste de Leitura na Management API (deve retornar HTTP 200):**
   ```bash
   curl -s -o /dev/null -w 'HTTP %{http_code}\n' \
     -H "Authorization: Bearer $TOKEN" \
     https://api.supabase.com/v1/projects/hbjkkcenbudiezmamiak/config/auth
   ```
   - Confirmação esperada: `HTTP 200`

3. **Conferência Completa via Script Oficial (Somente-Leitura):**
   Execute o script do repositório utilizando o token em memória:
   ```bash
   SUPABASE_ACCESS_TOKEN="$TOKEN" ./scripts/conferir-auth-remoto.sh hbjkkcenbudiezmamiak
   ```
   - Confirmação esperada: Execução verde com todos os critérios avaliados e saída com `exit 0`.

4. Limpe a variável do terminal:
   ```bash
   unset TOKEN
   ```

> [!IMPORTANT]
> **Proibição de Comandos de Escrita em Produção:**
> NUNCA execute requisições com métodos de mutação (`PATCH`, `POST`, `PUT`, `DELETE`) contra o endpoint de produção (`hbjkkcenbudiezmamiak`). A recusa de escrita é assegurada na criação do token no painel do Supabase pela seleção estrita de permissões `Read-only` (`Project Settings: Read`). Caso deseje validar o bloqueio de escrita em testes de fail-closed, execute-os exclusivamente contra um projeto descartável de desenvolvimento ou laboratório.

---

### Passo 3: Configurar o Environment no GitHub
1. Acesse `https://github.com/FrilaApp/frila-backend/settings/environments`.
2. Clique em **New environment** e defina o nome exato:
   ```text
   frila-prod-leitura
   ```
3. Em **Deployment protection rules**:
   - Deixe **Required reviewers desmarcado** (sem revisores manuais).
   - Deixe **Wait timer** zerado.
4. Em **Deployment branches and tags**:
   - Selecione **Selected branches**.
   - Adicione a regra para a branch `develop` (e `main` se aplicável).
5. Em **Environment secrets**:
   - Clique em **Add secret**.
   - **Name:** `SUPABASE_ACCESS_TOKEN`
   - **Value:** Cole o **token de leitura** gerado no Passo 1.
   - Clique em **Add secret**.

---

### Passo 4: Cancelar ou Aprovar o Run Legado
- Acesse a aba **Actions** e cancele o run pendente antigo (`41094976963`) ou aprove-o uma única vez.
- As próximas execuções do cron rodarão automaticamente no Environment `frila-prod-leitura` com zero intervenção manual e sob isolamento estrito de segurança.
