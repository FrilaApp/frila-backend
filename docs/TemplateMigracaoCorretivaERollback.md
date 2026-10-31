# Guia e Template de Migração Corretiva e Rollback "Para a Frente"

Este documento estabelece o padrão canônico para reversão de migrações e correções emergenciais de banco de dados no Frila Backend, em conformidade com o princípio de **migrações estritamente lineares, imutáveis e forward-only** (instituído em [`docs/RUNBOOK-INCIDENTES.md`](RUNBOOK-INCIDENTES.md#L365-L413) §6 e [`docs/RunbookHotfixERollback.md`](RunbookHotfixERollback.md#L140-L151) §4).

---

## 1. Por que Rollback "Para a Frente"?

No ecossistema PostgreSQL gerenciado via Supabase:
1. **Migrações são imutáveis e versionadas:** Toda migração comitada e aplicada em homologação (`frila-dev`) ou produção (`frila-prod`) fica permanentemente gravada na tabela de controle `supabase_migrations.schema_migrations`.
2. **A esteira bloqueia retrocessos:** O script [`scripts/migracoes-imutaveis.sh`](../scripts/migracoes-imutaveis.sh) reprova qualquer commit ou PR que altere ou exclua retroativamente arquivos de migração já existentes.
3. **`aplicar-remoto.sh` é sequencial:** O script lê as versões do repositório em ordem cronológica por timestamp, compara com `schema_migrations`, pula as já registradas e aplica as novas. Não existe comando de `down` ou `rollback` nativo nos ambientes remotos.
4. **Armadilha de tentar reverter alterando o passado:** Se a migração `N` causou problema em produção, criar uma branch sem a migração `N` ou tentar editar o arquivo `N` não reverte o banco remoto (que já executou o DDL de `N`) e quebrará a esteira de CI.

> [!IMPORTANT]
> **A única maneira segura e suportada de reverter alterações em produção é avançando:** cria-se uma **nova migração corretiva `N+1`** que aplica as instruções SQL compensatórias (desfazer DDL, restaurar corpo de função, revogar/recriar políticas ou sanear dados), restaurando o estado íntegro do sistema.

---

## 2. Anatomia de uma Migração Corretiva

Toda migração corretiva deve seguir a estrutura padrão abaixo:

### 2.1 Nome do Arquivo
O arquivo deve ser criado pelo comando padrão da CLI ou com timestamp UTC atualizado:
```bash
supabase migration new desfazer_<operacao>_<objeto>
# ou:
supabase migration new correcao_<motivo>_<objeto>
```
*Exemplo:* `supabase/migrations/20261031120000_desfazer_constraint_limite_candidatura.sql`

### 2.2 Cabeçalho Obrigatório
O topo do arquivo SQL **deve** conter um cabeçalho explicativo documentando a rastreabilidade:
- **Timestamp e identificador da migração original que introduziu o problema.**
- **Sintoma / Incidente observado** (código de erro, PR, issue ou chamado de suporte).
- **Ação corretiva executada** (o que foi revertido ou ajustado).
- **Garantias de compatibilidade** (efeito colateral em dados existentes, RLS e índices).

```sql
-- ============================================================================
-- MIGRAÇÃO CORRETIVA (ROLLBACK FORWARD-ONLY)
-- Versão original afetada: 20261015140000_...sql (PR #XYZ)
-- Motivo / Incidente: Chamado #ABC / Erro 403 ao executar <funcao>
-- Ação: Restaura corpo anterior da função privado.<funcao>, garantindo
--       search_path imutável e privilégios mínimos.
-- ============================================================================
```

---

## 3. Padrões por Tipo de Objeto

### 3.1 Funções e Triggers (RPC / Segurança)
Para reverter uma função com regressão:
- Use `create or replace function ...` restaurando a versão conhecida e estável.
- Garanta explicitamente:
  1. `security definer` (se aplicável);
  2. `set search_path = ''` (imprescindível para prevenir ataques de caminho de busca);
  3. `comment on function ... is '...'`;
  4. Revogação de privilégios públicos e concessão estrita (`revoke execute on function ... from public, anon, authenticated;` ou concessão apenas para roles permitidas).

```sql
create or replace function privado.minha_funcao(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Corpo anterior estável
  update public.minha_tabela
     set atualizado_em = privado.agora()
   where id = p_id;
end $$;

comment on function privado.minha_funcao(uuid) is
  'Restaura implementação estável sem regressão de concorrência (Rollback forward-only incidente #123).';

revoke execute on function privado.minha_funcao(uuid) from public, anon, authenticated;
```

### 3.2 Constraints e Índices
- Reverter constraint restritiva ou com erro de validação:
```sql
-- 1. Remove a constraint problemática de forma segura
alter table public.candidatura
  drop constraint if exists check_candidatura_status_valido;

-- 2. (Opcional) Restaura a constraint anterior tolerante
alter table public.candidatura
  add constraint check_candidatura_status_valido
  check (status in ('pendente', 'aceita', 'recusada', 'cancelada'));
```
- Reverter índice que causou lock ou degradação:
```sql
-- Remove o índice problemático
drop index if exists public.idx_candidatura_busca_composta;

-- Restaura o índice anterior (se necessário)
create index if not exists idx_candidatura_vaga_id
  on public.candidatura (vaga_id);
```

### 3.3 Colunas e Tipos de Dados
- Evite `drop column` destrutivo sem confirmação do dono (dados não podem ser recuperados sem backup).
- Se a coluna for recém-adicionada e não possuir dados úteis:
```sql
alter table public.perfil
  drop column if exists coluna_problematica;
```
- Se a coluna causou quebra por `not null` inesperado:
```sql
-- Remove obrigatoriedade imediatamente para destravar o fluxo operacional
alter table public.perfil
  alter column campo_adicional drop not null;
```

### 3.4 Políticas de RLS (Row Level Security)
Ao reverter políticas de acesso:
```sql
-- 1. Drop da política com regressão
drop policy if exists "perfil_politica_restritiva" on public.perfil;

-- 2. Recriação da política estável anterior
create policy "perfil_leitura_proprio_ou_publico"
  on public.perfil
  for select
  to authenticated
  using (
    id = (select auth.uid())
    or visibilidade = 'publica'
  );
```

### 3.5 Saneamento de Dados (Correção Idempotente)
Se a migração problemática gravou dados corrompidos ou inconsistentes:
- A correção de dados deve ser **idempotente** e executada em bloco seguro.
- Use `where` restrito para não afetar linhas saudáveis.
```sql
-- Corrige estados inconsistentes gerados pela falha
update public.posicao
   set estado = 'cancelada'
 where estado = 'invalido'
   and criado_em >= '2026-10-30 00:00:00+00';
```

---

## 4. Exemplos Reais da Base do Frila

### Exemplo 1: Correção de Tratamento de Exceção em Função de Infraestrutura
Arquivo real: [`supabase/migrations/20261017200000_despacho_falha_transporte_em_falha_execucao.sql`](../supabase/migrations/20261017200000_despacho_falha_transporte_em_falha_execucao.sql)
- **Problema:** A migração anterior imputava ocorrência ao usuário contratante quando uma requisição HTTP via `net.http_post` falhava.
- **Rollback forward:** Reescreveu `privado.disparar_despacho` com `create or replace function`, redirecionando o erro de transporte para `privado.falha_execucao` e preservando a mensagem na fila pgmq sem penalizar o usuário.

### Exemplo 2: Otimização de Varredura O(N) e Filtro de Notificações
Arquivo real: [`supabase/migrations/20261015140000_correcao_ciclo_de_vida_achados_2_e_3.sql`](../supabase/migrations/20261015140000_correcao_ciclo_de_vida_achados_2_e_3.sql)
- **Problema:** O laço de notificação de `fechar_turnos_e_vagas` varria todo o histórico do banco a cada 5 minutos.
- **Rollback forward:** Substituiu a função ajustando a cláusula `where` com janela de 7 dias e `not exists`, preservando idempotência.

---

## 5. Checklist Operacional de Rollback Forward

Antes de submeter o PR e aplicar a migração corretiva, siga rigorosamente este checklist:

### Fase 1: Diagnóstico e Validação Local
- [ ] O problema foi isolado e identificado o timestamp da migração causadora.
- [ ] A migração corretiva foi gerada com novo timestamp cronológico (`supabase migration new ...`).
- [ ] O arquivo contém o cabeçalho descritivo com a rastreabilidade do incidente.
- [ ] Todas as instruções são idempotentes (`if exists`, `if not exists`, `create or replace`).
- [ ] Funções utilizam `set search_path = ''` e privilégios explicitamente revogados/concedidos.
- [ ] Teste unitário pgTAP criado ou ajustado em `supabase/tests/database/` reproduzindo a correção.
- [ ] Banco local resetado e verificado: `supabase db reset` roda do zero sem falhas.

### Fase 2: Validação da Esteira Local (Scripts de Segurança)
- [ ] `scripts/migracoes-sem-colisao.sh` executado com sucesso (sem colisão de timestamp).
- [ ] `scripts/migracoes-imutaveis.sh origin/develop` executado com sucesso (nenhuma migração histórica alterada).
- [ ] `./scripts/desvio.sh` executado localmente para garantir ausência de desvio indesejado.

### Fase 3: PR e Aprovação
- [ ] PR aberto apontando para `develop` com prefixo `fix:` ou `hotfix:`.
- [ ] Descrição do PR detalha o incidente, a reversão aplicada e as provas de teste.
- [ ] Todos os jobs da CI no GitHub Actions estão verdes.
- [ ] PR revisado e aprovado por sócio (conforme `AGENTS.md`).

### Fase 4: Execução em Homologação / Produção
- [ ] Horário verificado com `./scripts/janela-de-manutencao.sh` (respeito à janela RNF12).
- [ ] Simulação prévia executada: `./scripts/aplicar-remoto.sh <project_ref> --seco`.
- [ ] Aplicação efetiva executada pelo `[DONO]`: `./scripts/aplicar-remoto.sh <project_ref>`.
- [ ] Confirmação de registro: `select version from supabase_migrations.schema_migrations order by version desc limit 3;`.
- [ ] Monitoramento ativo dos logs de Edge Functions e banco pós-aplicação.
