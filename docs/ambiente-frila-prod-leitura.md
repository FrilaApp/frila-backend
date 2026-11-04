# Conferência de Auth em Produção: Alternativa B (Disparo Manual sob `frila-prod`)

Este documento registra a estratégia operacional (Alternativa B) para a conferência remota de configurações de autenticação no Supabase (`scripts/conferir-auth-remoto.sh`), eliminando travamentos de esteira na CI e preservando o isolamento de segurança sem prometer tokens de escopo reduzido inexistentes.

---

## 1. Motivação e Inviabilidade de Tokens de Escopo Reduzido

- **O Problema da Fila no Cron:** O workflow `.github/workflows/confere-auth-remoto.yml` é disparado diariamente às 11:17 UTC via cron (`17 11 * * *`). Quando o job de conferência do `frila-prod` executava automaticamente todos os dias sob o Environment protegido `frila-prod`, a execução entrava no estado `waiting`, exigindo aprovação manual de um revisor diariamente (exemplo: run legado `41094976963`).
- **A Tentativa de Solução da Alternativa A:** A Alternativa A propunha criar um Environment `frila-prod-leitura` sem revisores obrigatórios para o cron, abastecido por um Personal Access Token (PAT) granular estritamente de leitura (`auth_config_read`).
- **A Restrição Técnica Real no Supabase:**
  - O painel do Supabase Management API **não oferece tokens granulares somente-leitura**. Os tokens disponíveis para projetos são PATs com escopo pleno ou experimental que concedem poder de escrita sobre a infraestrutura.
  - Alocar um token com poder de escrita em um Environment sem revisores (`frila-prod-leitura`) violaria gravemente as proteções do time, criando um vetor de contorno (*bypass*) das regras de proteção do `frila-prod`.

---

## 2. A Solução: Alternativa B (Disparo Manual com Proteção de Revisor)

Em vez de criar um ambiente sem revisores com credenciais perigosas, a **Alternativa B** adota o modelo canônico de menor privilégio e segregação temporal:

1. **`frila-dev` no Cron Diário:** O ambiente de desenvolvimento (`frila-dev`) continua sendo auditado diariamente via cron (`17 11 * * *`) sem necessidade de aprovação humana, garantindo a detecção preventiva de desvios de configuração de SMTP, OTP e templates.
2. **`frila-prod` Exclusivamente sob Demanda (`workflow_dispatch`):**
   - No workflow `.github/workflows/confere-auth-remoto.yml`, o job `prod` possui a guarda:
     ```yaml
     if: github.event_name == 'workflow_dispatch'
     ```
   - No cron diário, o job `prod` é ignorado (*skipped*), permitindo que a esteira conclua com sucesso sem reter o executor aguardando aprovação humana.
   - O job `prod` permanece vinculado ao Environment existente **`frila-prod`**, utilizando a credencial `SUPABASE_ACCESS_TOKEN` já protegida pelos 4 revisores cadastrados no repositório.
   - Nenhuma nova credencial ou token precisa ser gerado no Supabase.

---

## 3. Roteiro Operacional de Execução

Quando a equipe desejar auditar a integridade de Auth em produção (por exemplo, após deploys da tag `backend-v*`, incidentes ou alterações administrativas no painel do Supabase):

1. Acesse **Actions** no repositório `frila-backend`.
2. Selecione o workflow **Conferência de Auth remoto** na barra lateral.
3. Clique em **Run workflow** (selecionando a branch desejada, ex.: `main` ou `develop`).
4. Um dos quatro revisores do Environment `frila-prod` (`cauecarneiro`, `fbtostadev`, `jotape12-Dev` ou `silvaaszx`) aprova a execução na interface do GitHub.
5. O job executa [`scripts/conferir-auth-remoto.sh`](../scripts/conferir-auth-remoto.sh) com leitura estrita (`GET /v1/projects/{ref}/config/auth`), atestando conformidade com código de saída `exit 0` sem nenhuma mutação no banco ou nos serviços.

---

## 4. Validação Offline Local

Para comprovar que o script de conferência funciona e falha fechado (*fail-closed*) sem necessidade de conexão externa ou tokens, execute o autoteste local:

```bash
./scripts/teste-conferir-auth-remoto.sh
```

Todos os 5 casos de teste (cenário válido, localhost, template com link, SMTP desligado e apontamento de runbook) executam em modo offline contra fixtures estáticas com `exit 0`.
