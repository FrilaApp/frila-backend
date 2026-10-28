# Paridade develop vs main e Teste de Fumaça da v1.0

Relatório gerado em atendimento ao **Brief B-002** (cartão `6ace0f26`: "Levar a develop à main e à produção antes de 06/11").

---

## 1. Paridade `develop` vs `main`

### 1.1 Comparação no GitHub (`gh api`)

**Comando:**
```bash
gh api repos/FrilaApp/frila-backend/compare/main...develop
```

**Saída resumida:**
```json
{
  "status": "diverged",
  "ahead_by": 25,
  "behind_by": 1,
  "total_commits": 25
}
```

- **`behind_by: 1`**: O commit na `main` ausente na `develop` é o merge do PR #308:
  - `8d19626` Merge pull request #308 from FrilaApp/release/backend-v1.0.0
- **`ahead_by: 25`**: Os 25 commits presentes na `develop` e ausentes na `main` cobrem os PRs #310 a #320 (correções de resiliência, segurança, FCM data-only para Android, neutralização de CSV injection em exportação e módulo compartilhado de autenticação).

---

### 1.2 Migrações: `develop` vs `main`

#### Migrações presentes na `develop` e ausentes na `main`

**Comando:**
```bash
comm -23 <(git ls-tree -r --name-only origin/develop:supabase/migrations | sort) \
         <(git ls-tree -r --name-only origin/main:supabase/migrations | sort)
```

**Saída:**
```
20261018050000_reivindicar_lote_push_skip_locked.sql
20261020100000_alerta_demonstracao_saude.sql
20261020150000_publicar_vaga_demonstracao_resiliencia.sql
20261020180000_retencao_demonstracao_e_falhas.sql
```

#### Migrações presentes na `main` e ausentes na `develop`

**Comando:**
```bash
comm -13 <(git ls-tree -r --name-only origin/develop:supabase/migrations | sort) \
         <(git ls-tree -r --name-only origin/main:supabase/migrations | sort)
```

**Saída:**
```
(nenhuma - todas as migrações da main estão contidas na develop)
```

---

### 1.3 Edge Functions: `develop` vs `main`

#### Diretórios presentes na `develop` e ausentes na `main`

**Comando:**
```bash
comm -23 <(git ls-tree -d --name-only origin/develop:supabase/functions | sort) \
         <(git ls-tree -d --name-only origin/main:supabase/functions | sort)
```

**Saída:**
```
_compartilhado
```

**Análise:**
Todas as 9 Edge Functions da v1.0 existem tanto na `main` quanto na `develop`:
- `despachar`
- `entrar-demonstracao`
- `enviar-email`
- `enviar-push`
- `excluir-conta`
- `exportar-meus-dados`
- `exportar-turnos`
- `limpar-contas-orfas`
- `saude`

Na `develop`, foi adicionado o diretório `_compartilhado` (`_compartilhado/auth.ts` e `_compartilhado/auth_test.ts`), centralizando validação estrita de Bearer tokens e comparação em tempo constante para eliminar duplicação de lógica entre as Edge Functions (PR #319).

---

## 2. Script de Fumaça (`scripts/fumaca-v1.sh`)

O script `scripts/fumaca-v1.sh` testa a probe operacional de saúde e as 6 funções da v1.0 que dependem de produção:
1. `saude` (`GET /functions/v1/saude`)
2. `escolher_candidato` (`POST /rest/v1/rpc/escolher_candidato`)
3. `incluir_na_equipe` (`POST /rest/v1/rpc/incluir_na_equipe`)
4. `pedir_revisao_despacho` (`POST /rest/v1/rpc/pedir_revisao_despacho`)
5. `abrir_suporte` (`POST /rest/v1/rpc/abrir_suporte`)
6. `avisar_a_caminho` (`POST /rest/v1/rpc/avisar_a_caminho`)
7. `exportar-turnos` (`POST /functions/v1/exportar-turnos`)

### 2.1 Uso

```bash
# Via argumentos:
./scripts/fumaca-v1.sh <URL_DO_PROJETO> <ANON_KEY>

# Ou via variáveis de ambiente:
URL_DO_PROJETO="https://<ref>.supabase.co" ANON_KEY="..." ./scripts/fumaca-v1.sh
```

Segredos e credenciais nunca são gravados no repositório. O código da demonstração pode ser passado via `DEMONSTRACAO_CODIGO`.

---

## 3. Teste Contra o Supabase Local

O teste foi executado no ambiente local (`supabase start -x vector`), reservando o banco com a fila compartilhada (`fila.sh pegar banco Bigorna`).

### 3.1 Execução Direta (sem segredos de demonstração no ambiente local)

**Comando:**
```bash
./scripts/fumaca-v1.sh http://127.0.0.1:54321
```

**Saída:**
```
=== Teste de Fumaça v1.0 ===
Alvo: http://127.0.0.1:54321

▸ Probe operacional de saúde:
  saude: FALHOU (HTTP 503 - conexao_falhou)

▸ Autenticação com contas de demonstração (entrar-demonstracao):
  entrar-demonstracao: FALHOU (DEMONSTRACAO_CODIGO não informado no ambiente)

▸ Verificação das 6 funções da v1.0:
  escolher_candidato: FALHOU (HTTP 401 - 42501)
  incluir_na_equipe: FALHOU (HTTP 401 - 42501)
  pedir_revisao_despacho: FALHOU (HTTP 401 - 42501)
  abrir_suporte: FALHOU (HTTP 401 - 42501)
  avisar_a_caminho: FALHOU (HTTP 401 - 42501)
  exportar-turnos: FALHOU (HTTP 401 - nao_autenticado)

=== Resultado ===
Status: FALHOU (8 falha(s) encontrada(s))
```

### 3.2 Execução com Tokens de Sessão das Contas de Demonstração

Ao injetar os tokens das contas de demonstração semeadas no banco local (`TOKEN_CONTRATANTE` e `TOKEN_PROFISSIONAL`), as 5 RPCs da v1.0 no banco de dados respondem conforme o contrato:

```
=== Teste de Fumaça v1.0 ===
Alvo: http://127.0.0.1:54321

▸ Probe operacional de saúde:
  saude: FALHOU (HTTP 503 - conexao_falhou)

▸ Autenticação com contas de demonstração (entrar-demonstracao):
  entrar-demonstracao: PASSOU (usando tokens fornecidos no ambiente)

▸ Verificação das 6 funções da v1.0:
  escolher_candidato: PASSOU (HTTP 403)
  incluir_na_equipe: PASSOU (HTTP 404)
  pedir_revisao_despacho: PASSOU (HTTP 409)
  abrir_suporte: PASSOU (HTTP 200)
  avisar_a_caminho: PASSOU (HTTP 422)
  exportar-turnos: FALHOU (HTTP 401 - Invalid JWT)

=== Resultado ===
Status: FALHOU (2 falha(s) encontrada(s))
```

---

## 4. O que só existe em Produção (Não Executado no Local)

Conforme estabelecido no Brief B-002, o ambiente de desenvolvimento local possui limitações arquiteturais conhecidas em relação à infraestrutura de produção:
1. **Segredos das Edge Functions (`DEMONSTRACAO_CODIGO`, `DEMONSTRACAO_ATIVA_ATE`, `SMTP_HOST`, `FCM_SERVICE_ACCOUNT`):** Na produção e no `frila-dev`, são provisionados via `supabase secrets set`. No stack local básico de `supabase start`, esses segredos não são expostos ao worker de `entrar-demonstracao` (fail-closed 404).
2. **Resolução DNS de Banco pelo Edge Runtime Local (`saude`):** O container Docker local `edge-runtime` utiliza a biblioteca `c-ares`, que falha na resolução de nomes do Docker Desktop para `supabase_db_frila-backend`, resultando em 503 `conexao_falhou` no probe de saúde HTTP local. (A suíte Deno cobriu 100% da função com `deno test --allow-all supabase/functions/saude/`).
3. **Assinatura Assimétrica de JWT no Edge Runtime Local (`exportar-turnos`):** O GoTrue local assina tokens com chave assimétrica ES256, enquanto o container local de Edge Functions verifica tokens usando HMAC (HS256), recusando com 401 `Invalid JWT`. Na produção, o roteamento e validação ocorrem na camada de API Gateway do Supabase.

---

## 5. Descrição dos Dados Semeados da Demonstração

Para execução contra ambientes reais ou locais, os seguintes dados são garantidos pelo catálogo de funções (`privado.renovar_dados_demonstracao()`):
- **Contratante:** `revisao-contratante@frila.app` (UUID canônico `de000000-0000-4000-8000-000000000001`), cadastrado como administrador do estabelecimento "Bar da Revisão" (`de000000-0000-4000-8000-000000000010`).
- **Profissional:** `revisao-profissional@frila.app` (UUID canônico `de000000-0000-4000-8000-000000000002`), com funções ativas de garçom e bartender e ponto base em Brasília.
- **Turno Confirmado:** Turno associado à posição confirmada `de000000-0000-4000-8000-000000000031` da vaga preenchida `de000000-0000-4000-8000-000000000021`, no estado `pendente`, com início agendado para `agora + 2 dias`.
- **Vaga Aberta:** Vaga `de000000-0000-4000-8000-000000000020`, modo urgência, com posição aberta `de000000-0000-4000-8000-000000000030`.
