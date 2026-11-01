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
5. **Permissões Granulares (Princípio do Menor Privilégio):**
   - Selecione permissões em **Read** (nunca Read-write).
   - Habilite estritamente o escopo que cobre a leitura de configurações de autenticação do projeto: **`auth_config_read`** (no painel: *Authentication: Read* ou *Project Settings: Read*).
   - NUNCA selecione escopos de escrita (`auth_config_write`, `database_write`, etc.).
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

---

### Validação de Menor Privilégio / Fail-Closed (Sem Tocar no Prod)

> [!CAUTION]
> **Proibição Absoluta de Requisições de Escrita em Produção:**
> **NUNCA** execute requisições com métodos de mutação (`PATCH`, `POST`, `PUT`, `DELETE`) contra o endpoint de produção (`hbjkkcenbudiezmamiak`). Se o token tiver sido gerado com permissão indevida por engano, um comando de teste alteraria a infraestrutura de autenticação do produto em produção (incidente P1-03).

Para comprovar formalmente que o token opera sob menor privilégio e que a rotina é fail-closed:

1. **Inspeção no Painel do Supabase (A via 100% segura e direta):**
   Inspecione os metadados do token emitido no painel de controle do Supabase (**Account > Access Tokens**), confirmando que a coluna de escopos restringe-se estritamente a **`auth_config_read`** sobre o projeto `frila-prod` (`hbjkkcenbudiezmamiak`).
   *(Nota de segurança: Não execute comandos de teste com métodos de mutação contra outros projetos Supabase como `REF_DESCARCAVEL`: o isolamento entre projetos (barreira de tenant) do Supabase rejeita com HTTP 401/403 qualquer requisição a outro projeto, gerando um falso positivo de fail-closed e podendo induzir à criação desnecessária de projetos auxiliares).*

2. **Validação da Lógica Fail-Closed Offline (com Mock/Fixtures Locais):**
   Para comprovar que a rotina de conferência rejeita configurações incorretas e falha fechada com `exit 1` sem tocar em rede nem criar projetos no Supabase, execute o autoteste offline do repositório:
   ```bash
   ./scripts/teste-conferir-auth-remoto.sh
   ```
   - O teste executa contra fixtures estáticas locais (`scripts/fixtures/auth_site_url_localhost.json`, `auth_modelo_com_link.json`, `auth_smtp_desligado.json` e `auth_bom.json`), garantindo cobertura completa e fail-closed com zero chamadas externas.

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
   - **Value:** Cole o **token de leitura** gerado no Passo 1 (escopo `auth_config_read`).
   - Clique em **Add secret**.

---

### Passo 4: Cancelar ou Aprovar o Run Legado
- Acesse a aba **Actions** e cancele o run pendente antigo (`41094976963`) ou aprove-o uma única vez.
- As próximas execuções do cron rodarão automaticamente no Environment `frila-prod-leitura` com zero intervenção manual e sob isolamento estrito de segurança.

---

## 3. Texto Sugerido para a Seção "Passos necessários do Dono" no Corpo do PR #354

Para sanar definitivamente a contradição apontada no item P1-02, sugere-se a redação abaixo para a seção correspondente no corpo do PR #354:

```markdown
## 🔒 Passos necessários do Dono (João Paulo / jotape12-Dev)

Para que o job de conferência diária execute sem revisor humano:

1. Acessar **Settings > Environments** no repositório `frila-backend`.
2. Criar o Environment **`frila-prod-leitura`**.
3. Em **Deployment protection rules**, deixar *Required reviewers* desmarcado.
4. Em **Deployment branches**, selecionar *Selected branches* e cadastrar `develop` (e `main` se aplicável).
5. Em **Environment secrets**, adicionar `SUPABASE_ACCESS_TOKEN` gerando um novo Scoped Personal Access Token no Supabase com escopo estrito **`auth_config_read`** restrito ao projeto `hbjkkcenbudiezmamiak` (conforme guia `docs/ambiente-frila-prod-leitura.md`), **NUNCA reutilizando nem copiando o token existente com poder de escrita de `frila-prod`**.
```
