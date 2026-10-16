# Padrões, Boas Práticas e Armadilhas de Testes pgTAP e Banco de Dados

Guia prático para escrita de testes de banco de dados (`supabase/tests/*.sql`) e testes de integração com o PostgreSQL no Frila (`frila-backend`).

Este documento sintetiza os padrões estabelecidos, as lições aprendidas e as armadilhas de falso-verde identificadas em produção e na suíte de testes.

---

## 1. Isolamento de Ambiente e Execução Local / CI

### Container Compartilhado Local vs CI
- **Não rode `supabase db reset` no container local COMPARTILHADO:** na máquina de desenvolvimento/pareamento dos agentes, o banco é compartilhado entre terminais e workers; executar reset destrói o estado concorrente e aborta tarefas em paralelo.
- **A CI usa banco efêmero:** nos runners isolados do GitHub Actions, a esteira inicia intencionalmente com `supabase db reset` seguido de `supabase test db` (`.github/workflows/ci.yml:65`, `ensaio-backup.yml:52`).

### Transações e `plan(N)` Obrigatório
- Todos os arquivos pgTAP devem executar dentro de uma transação com contagem explícita de plano e rollback garantido:
  ```sql
  BEGIN;

  -- Sempre declarar plan(N) com o número exato de asserções (0 de 121 arquivos do repo usam no_plan()).
  -- Não usar no_plan(), pois plan(N) detecta abortos silenciosos de blocos de teste ou violações de restrição.
  SELECT * FROM plan(27);

  -- Execução dos testes...

  SELECT * FROM finish();

  ROLLBACK;
  ```
- O `ROLLBACK;` no encerramento assegura que dados de teste, inserções em tabelas e alterações de contexto nunca vazem para outros testes ou corrompam a suíte.

---

## 2. Simulação de Papéis, RLS e Contexto JWT

### Papéis Disponíveis no Supabase
- `anon`: requisições não autenticadas (acesso público via PostgREST).
- `authenticated`: usuários com sessão válida (JWT assinado).
- `service_role`: bypass de RLS, reservado para rotinas de backend e Edge Functions autorizadas.

### Padrão Canônico de JWT no Repositório
Na suíte de testes do `frila-backend`, utiliza-se predominantemente o formato JSON de claims (176 ocorrências em 82 arquivos de teste em `supabase/tests/`), lido por funções de migração como `limite_de_escrita` (`20260929220000_limite_de_escrita.sql:91`):

```sql
-- 1. Definir papel da sessão
SET LOCAL ROLE authenticated;

-- 2. Configurar o JSON de claims canônico (padrão em 82 arquivos de teste do repositório)
SET LOCAL "request.jwt.claims" = '{"sub": "00000000-0000-4000-8000-000000000001", "role": "authenticated"}';

-- 3. Configurar claim.sub legada quando testar rotinas que leem o formato antigo:
-- Algumas migrações ainda leem o formato escalar legado request.jwt.claim.sub, como
-- supabase/migrations/20261001100000_suspensao_da_conta.sql (linhas 365 e 404).
SET LOCAL "request.jwt.claim.sub" = '00000000-0000-4000-8000-000000000001';
```

### Armadilhas de Papéis e Permissões
1. **Configurar apenas `claim.sub` escalar ou omitir o JSON de claims:**
   - Funções que inspecionam `request.jwt.claims ->> 'role'` receberão `NULL`, tratando o usuário erroneamente como anônimo ou causando falhas inesperadas de autorização.
   - Sempre configure `request.jwt.claims` em JSON, complementando com `request.jwt.claim.sub` quando a rotina sob teste assim exigir.
2. **Afirmação de Permissões Negativas (Princípio do Menor Privilégio):**
   - Para provar que papéis restritos (`authenticated`, `anon`, `public`) não têm acesso a schemas internos (como `privado`), use funções nativas do catálogo pgTAP:
     ```sql
     SELECT is(
       has_table_privilege('authenticated', 'privado.parametro_notificacao', 'select'),
       false,
       'authenticated nao possui SELECT em privado.parametro_notificacao'
     );
     ```
   - Evite testar privilégios apenas tentando executar `SELECT` direto e capturando exceção genérica: se o schema não estiver no `search_path`, o teste falha com `relation does not exist` em vez de `permission denied`, mascarando um `GRANT` indevido.

---

## 3. Manipulação de Tempo e Janelas Temporais

### Pré-requisito Obrigatório: `privado.ambiente (eh_teste)`
A função canônica de relógio do banco, `privado.agora()` (`20260922200000_auxiliares_e_relogio.sql`, linhas 49-55), **só obedece à configuração `frila.agora` se existir linha em `privado.ambiente` com `eh_teste = true`**.
- Sem essa linha na tabela `privado.ambiente`, `privado.agora()` ignora `frila.agora` e retorna silenciosamente `now()`, invalidando testes temporais determinísticos.
- **Padrão obrigatório no setup:**
  ```sql
  -- Garantir ambiente de teste ativo na transação
  insert into privado.ambiente (eh_teste) values (true)
  on conflict do nothing;

  -- Regra mandatória: fixar o relógio ANTES de inserir os dados de teste
  select set_config('frila.agora', '2026-10-20 12:00:00+00', true);
  ```

### Ordem de Operações: Fixar o Relógio ANTES dos Dados
- Um erro recorrente nos testes pgTAP 700-702 foi inserir registros no banco com datas relativas antes de fixar `frila.agora`, ou fixar o relógio após chamar rotinas de expiração.
- Fixe `frila.agora` logo no início da transação de teste, garantindo que todos os cálculos de timestamp e inserções estejam estritamente ancorados.

### Borda Estrita em Testes de Retenção (Boundary Testing)
- Testar intervalos amplos (como `59d 23h` preservado vs `60d 01h` purgado) **não comprova a borda exata**, pois há folga de uma hora em ambos os lados.
- **Aferição estrita exige corte no segundo:**
  1. **60 dias exatos (`60d 00h 00s`):** PRESERVADO (pois a cláusula `<` exige ser estritamente anterior).
  2. **60 dias + 1 segundo (`60d 00h 01s`):** PURGADO.
  3. **Dentro da janela (`59d 23h 59s`):** PRESERVADO.

---

## 4. Testes de Jobs do pg_cron

### Não Dependa do Daemon Assíncrono
- O daemon do `pg_cron` opera em background de forma assíncrona. Esperar o daemon disparar gera flakiness, lentidão excessiva e falhas espúrias na CI.

### Padrão de Teste para o Cron:
1. **Verificação de Catálogo (`cron.job`):**
   - Provar que o job está registrado com o nome correto.
   - Provar que a expressão cron (ex.: `'17 6 * * *'`) e o comando SQL exato (`command`) correspondem exatamente ao declarado na migração.
2. **Execução Direta da Função do Job:**
   - Invocar diretamente a função SQL referenciada no comando do job (ex.: `select privado.limpar_dispositivos_inativos()`).
   - Provar seus efeitos de negócio, retorno contábil de linhas afetadas, e idempotência em execuções repetidas.

---

## 5. Armadilhas de Setup e Catálogo no PostgreSQL

### Validação Canônica de `search_path=""` em Funções `SECURITY DEFINER`
No catálogo do PostgreSQL (`pg_proc.proconfig`), a configuração de `search_path` seguro é armazenada como array de texto. A forma correta de validar no pgTAP sem falso-positivo de formatação e evitando colisões de nome entre schemas é:
```sql
SELECT is(
  (SELECT proconfig FROM pg_proc WHERE proname = 'nome_da_funcao' AND pronamespace = 'privado'::regnamespace) @> array['search_path=""'],
  true,
  'funcao define search_path="" vazio contra sequestro de schema'
);
```

### Inserção em `public.usuario`: `termos_versao` e `termos_aceite_em` NOT NULL sem DEFAULT
Ao criar contas fictícias de usuário nos testes de integração:
- As colunas `termos_versao` (text) e `termos_aceite_em` (timestamptz) foram declaradas `NOT NULL` sem valor padrão (`DEFAULT`) desde a migração inicial `20260923000000_criar_conta.sql`.
- Omissão dessas colunas em `INSERT INTO public.usuario (...)` causa aborto imediato da transação por violação de NOT NULL (foi o bloqueio identificado no pgTAP 702).
- **Sempre fornecer valores explícitos:**
  ```sql
  insert into public.usuario (
    id, perfil, nome, telefone, email, nascimento, estado, termos_versao, termos_aceite_em
  ) values (
    '70200000-0000-4000-8000-000000000001', 'profissional', 'Conta Teste',
    '+5561970200001', 'teste@frila.app', '1990-01-01', 'ativa',
    '2026-09-22', '2026-09-22 12:00:00+00'
  );
  ```

---

## 6. Prevenção de Falso-Verde e Testes de Mutação

### O Que É um Teste Falso-Verde?
Um teste falso-verde passa com sucesso mesmo quando o comportamento sob teste está quebrado, ausente ou foi alterado.

### Armadilhas Reais Identificadas:
1. **Mocks que Recriam a Lógica em Vez de Testar o Código Real:**
   - *Cenário:* Um teste mockou a função `registrarFalha` criando um objeto falso com `try/catch` interno.
   - *Problema:* A implementação real de `criarSqlProbe` nunca foi chamada. Uma mutação que removia o `try/catch` defensivo do código de produção continuava passando com 100% dos testes verdes.
   - *Solução:* Exercitar a implementação real com dependências ou endpoints reais/controlados (ex.: `criarSqlProbe('postgres://u:p@127.0.0.1:1/db')` com porta inacessível), provando que o código real resiste à falha.
2. **Afirmações de Título Descoladas do Comportamento Real:**
   - *Cenário:* Titular um teste como "timeout de statement no banco" quando o handler apenas captura um erro genérico e o `index.ts` não possui `statement_timeout` configurado.
   - *Solução:* Títulos e asserções devem refletir com exatidão cirúrgica o que o teste realmente exercita.

---

## 7. Processo Operacional e Gestão de Conflitos

### Política de `CHANGELOG.md`: Proposta Operacional
- A retenção ou não edição de `CHANGELOG.md` em PRs concorrentes de testes ou correções menores é uma **proposta operacional** da equipe para evitar sucessivas rodadas de rebase e conflitos em série (`CONFLICTING`), e não uma regra vigente formal da esteira de CI.
- A decisão final sobre consolidar notas de versão em lote em PR único vs adotar fragmentos de changelog é uma decisão técnica de arquitetura de processo reservada ao dono do projeto (`[DONO]`).
