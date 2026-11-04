# Auditoria de Segurança e Qualidade dos Scripts de Backend

Este documento formaliza a metodologia, os critérios de auditoria defensiva e os procedimentos automatizados de verificação para todos os scripts de infraestrutura, CI e concorrência do `frila-backend`.

---

## 1. Motivação e Objetivos

O diretório `scripts/` concentra 58 rotinas operacionais executadas em ambientes de integração contínua (CI), homologação e suporte. A ausência de regras estritas de segurança em scripts shell pode expor pipelines a riscos como:
- Execução em diretórios incorretos na falha de navegação (`cd`);
- Poluição ou colisão de arquivos temporários em `/tmp` compartilhados em runners ou máquinas locais;
- Falhas silenciosas decorrentes de variáveis não declaradas (`set -u`);
- Remoções acidentais recursivas (`rm -rf`);
- Vazamento acidental de tokens e credenciais em texto puro.

---

## 2. Critérios de Conformidade Auditados

O script [`scripts/auditar-scripts-backend.sh`](../scripts/auditar-scripts-backend.sh) executa 6 verificações estritas:

| Critério | O que valida | Justificativa de Segurança |
|---|---|---|
| **1. Permissão de Execução (+x)** | Todos os arquivos `.sh` possuem permissão executável (`100755`). | Garante invocação direta sem depender de subshell explícito `bash script.sh`. |
| **2. Variáveis Não Declaradas (`set -u`)** | Todos os scripts possuem `set -u` ou `set -euo pipefail`. | Previne expansões de variáveis vazias que podem quebrar lógica ou causar comportamento destrutivo. |
| **3. Arquivos Temporários Seguros** | Nenhum caminho fixo previsível em `/tmp` sem `mktemp`. | Evita ataques de symlink, condições de corrida entre agentes concorrentes e vazamento de dados. |
| **4. Zero Segredos Hardcoded** | Varredura de tokens Supabase (`sbp_`), JWTs reais e chaves privadas PEM. | Previne vazamento de credenciais em repositório público. |
| **5. Remoção Recursiva Segura** | Proibição de comandos `rm -rf` com alvos desprotegidos ou raiz (`/`). | Previne deleção acidental de diretórios do sistema ou workspace em caso de falha de variável. |
| **6. Conformidade ShellCheck** | Análise estática com severidade `warning` ou superior em 100% dos scripts. | Previne erros sintáticos, subshells desnecessárias e problemas de globbing. |

---

## 3. Autoteste Automatizado

A ferramenta possui autoteste com mutações controladas em [`scripts/teste-auditar-scripts-backend.sh`](../scripts/teste-auditar-scripts-backend.sh):
- Caso nominal no acervo real do repositório (100% aprovado).
- 5 casos negativos com fixtures sintéticas provando que qualquer regressão (falta de permissão, falta de `set -u`, caminhos fixos em `/tmp`, tokens hardcoded ou `rm -rf /`) reprova imediatamente com `exit 1`.

### Como Executar

```bash
# Execução da auditoria no repositório:
./scripts/auditar-scripts-backend.sh

# Execução do autoteste automatizado:
./scripts/teste-auditar-scripts-backend.sh
```
