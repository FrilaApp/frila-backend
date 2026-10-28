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

## 3. Teste Contra o Supabase Local (Execução 100% Verde)

> **Nota de Escopo**: O resultado verde desta suíte comprova **SONDAGEM, AUTENTICAÇÃO e RESPOSTAS CONTRATUAIS** das 6 funções e da probe de saúde (presença das rotas, autenticação estrita, tipagem e regras contratuais ativas), e **NÃO** o fluxo feliz completo (que requer a execução encadeada ponta a ponta com dados dinâmicos do ciclo de vida completo).

### 3.1 Preparação do Ambiente Local

1. Banco de dados reservado na fila compartilhada:
   ```bash
   /Users/cauecarneiro/Documents/Projetos/Frila/orquestracao/scripts/fila.sh pegar banco <dono>
   ```
2. Inicialização dos serviços Supabase locais:
   ```bash
   supabase start -x vector
   ```
3. Configuração dos segredos em `supabase/functions/.env.local` (ignorado pelo git):
   ```bash
   DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:54322/postgres
   DEMONSTRACAO_EMAILS=revisao-contratante@frila.app,revisao-profissional@frila.app
   DEMONSTRACAO_CODIGO=123456
   DEMONSTRACAO_ATIVA_ATE=2030-01-01T00:00:00Z
   ```
4. Execução do runtime de Edge Functions servindo as funções locais:
   ```bash
   supabase functions serve --env-file supabase/functions/.env.local --no-verify-jwt
   ```

---

### 3.2 Execução Reproduzível com Autenticação Real por Demonstração

Esta execução comprova a sondagem operacional, autenticação real e validação de respostas previstas em contrato (sem substituição do fluxo feliz completo).

**Comando:**
```bash
./scripts/fumaca-v1.sh http://127.0.0.1:54321
```

**Saída Exata (PASSOU integral, 0 falhas):**
```
=== Teste de Fumaça v1.0 ===
Alvo: http://127.0.0.1:54321

▸ Probe operacional de saúde:
  saude: PASSOU (HTTP 200)

▸ Autenticação com contas de demonstração (entrar-demonstracao):
  entrar-demonstracao: PASSOU (HTTP 200 contratante e profissional)
  turno descoberto dinamicamente: 8108b625-143e-44f7-bc19-9347025a0141

▸ Verificação das 6 funções da v1.0:
  escolher_candidato: PASSOU (HTTP 403 sem_permissao - resposta contratual de candidatura inexistente/bloqueada)
  incluir_na_equipe: PASSOU (HTTP 404)
  pedir_revisao_despacho: PASSOU (HTTP 409)
  abrir_suporte: PASSOU (HTTP 200)
  avisar_a_caminho: PASSOU (HTTP 422 a_caminho_fora_da_janela - turno vinculado validado fora da janela de 3h)
  exportar-turnos: PASSOU (HTTP 204)

=== Resultado ===
Status: PASSOU (respostas contratuais; não é prova do fluxo feliz)
```

---

### 3.3 Análise e Comprovação Contratual de Cada Resposta

A qualificação de "PASSOU" nas funções abaixo atesta a conformidade das respostas retornadas com as especificações contratuais (`contrato/openapi.yaml`) e de segurança do Frila:

1. **`saude` (HTTP 200)**: Conexão direta com o banco PostgreSQL via `DATABASE_URL` (`select 1 as ping`) validada com sucesso, retornando `{"ok":true,"status":"saudavel"}`.
2. **`entrar-demonstracao` (HTTP 200)**: As contas `revisao-contratante@frila.app` e `revisao-profissional@frila.app` autenticaram através do endpoint real da Edge Function, gerando tokens Bearer válidos emitidos pelo Supabase Auth.
3. **Descoberta Dinâmica de Turno**: O script consultou `meus_turnos` autenticado como o profissional da demonstração e descobriu dinamicamente o `turno_id` ativo (`8108b625-143e-44f7-bc19-9347025a0141`), sem recorrer a IDs literais estáticos (falhando explicitamente se nenhum turno for encontrado e nenhum `TURNO_ID` fornecido).
4. **`escolher_candidato` (HTTP 403 `sem_permissao` ou 409 `candidatura_indisponivel` / `posicao_ja_preenchida` / `vaga_encerrada`)**: Chamada autenticada com a conta contratante. O script valida estritamente os códigos contratuais permitidos pelo OpenAPI: 200 em caso de sucesso; 409 exclusivamente para os conflitos previstos (`candidatura_indisponivel`, `posicao_ja_preenchida` ou `vaga_encerrada`); e 403 `sem_permissao` para candidatura inexistente ou de outra casa (regra de privacidade RF26/RN10 que proíbe enumeração de existência de candidaturas por terceiros). Qualquer outro 409 não catalogado resulta em FALHOU.
5. **`incluir_na_equipe` (HTTP 404 `nao_encontrado` ou 403 `sem_turno_cumprido`)**: O contratante administra o estabelecimento da demonstração. O script valida que o retorno cumpre a regra de negócio do contrato (404 se profissional inexistente ou 403 com details `sem_turno_cumprido` per UC11 se o profissional não concluiu turno verificado no local).
6. **`pedir_revisao_despacho` (HTTP 409 `contestacao_ja_aberta`)**: O profissional da demonstração já possui contestação registrada nos dados semeados; o contrato (Opção B, migração `20261006160000`) proíbe abertura duplicada e responde estritamente `409 contestacao_ja_aberta`.
7. **`abrir_suporte` (HTTP 200)**: Chamado pelo profissional com o `turno_id` descoberto dinamicamente e chave idempotente única; cria o protocolo operacional e retorna `{"tipo":"suporte",...}` com HTTP 200.
8. **`avisar_a_caminho` (HTTP 422 `a_caminho_fora_da_janela`)**: Como o turno semeado está agendado para `agora + 2 dias`, a chamada com o turno vinculado do profissional valida corretamente o turno e retorna HTTP 422 `a_caminho_fora_da_janela` (a janela só abre 3h antes do início). Respostas 403 `sem_permissao` são estritamente rejeitadas pelo script por indicarem falta de vínculo.
9. **`exportar-turnos` (HTTP 204)**: A Edge Function autentica a sessão do profissional em `auth/v1/user` e consulta o banco; sem turnos no período solicitado, devolve HTTP 204 No Content sem corpo conforme especificado em UC13 1a.

---

### 3.4 Modo Offline (Tokens Injetados Manualmente)

Caso o operador forneça tokens pré-gerados via `TOKEN_CONTRATANTE` e `TOKEN_PROFISSIONAL` (por exemplo, em ambientes sem acesso aos segredos da porta de demonstração), o script detecta o bypass e registra explicitamente:
```
  entrar-demonstracao: NÃO EXECUTADO (tokens injetados via ambiente)
```
Garantindo que `entrar-demonstracao` nunca seja marcada falsamente como executada sem ter sido chamada.

---

## 4. Descrição dos Dados Semeados da Demonstração

Para execução contra ambientes reais ou locais, os seguintes dados são garantidos pelo catálogo de funções (`privado.renovar_dados_demonstracao()`):
- **Contratante:** `revisao-contratante@frila.app` (UUID canônico `de000000-0000-4000-8000-000000000001`), cadastrado como administrador do estabelecimento "Bar da Revisão" (`de000000-0000-4000-8000-000000000010`).
- **Profissional:** `revisao-profissional@frila.app` (UUID canônico `de000000-0000-4000-8000-000000000002`), com funções ativas de garçom e bartender e ponto base em Brasília.
- **Turno Confirmado:** Turno associado à posição confirmada `de000000-0000-4000-8000-000000000031` da vaga preenchida `de000000-0000-4000-8000-000000000021`, no estado `pendente`, com início agendado para `agora + 2 dias`.
- **Vaga Aberta:** Vaga `de000000-0000-4000-8000-000000000020`, modo urgência, com posição aberta `de000000-0000-4000-8000-000000000030`.
