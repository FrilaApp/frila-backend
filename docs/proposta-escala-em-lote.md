# Proposta Arquitetural: Escala de Evento em Lote (v1.2)

**Cartão Trello:** `6mi66YDp` (v1.2 · Backend + Web · Escala de evento em lote)  
**História / Requisitos:** US06 (8 pt) · RF19 · RN02, RN18, RN19, RN23, RN24  
**Data:** 15/10/2026  
**Autor:** Faísca (Backend / Antigravity)  
**Status:** Proposta técnica preliminar (aguarda deliberação do dono do produto)

---

## 1. Contexto e Motivação

### 1.1 O Cenário de Negócio (US06 / RF19)
Atualmente, no app móvel (iOS/Android), a publicação de vagas é desenhada para contratações pontuais ou de curto prazo (uma função por vez, mesmo que com múltiplas posições).

Produtoras de eventos, buffets e casas noturnas organizam escalas complexas para eventos de grande porte (formaturas, casamentos, festivais corporativos, feiras de negócios), frequentemente com semanas de antecedência. Uma escala típica mobiliza **entre 20 e 60 profissionais** divididos em **3 a 8 funções distintas** (por exemplo: 15 garçons, 8 barmans, 4 cozinheiros, 4 auxiliares de cozinha, 4 recepcionistas, 6 seguranças).

Cadastrar cada vaga individualmente no smartphone:
1. Gera atrito operacional inaceitável para o contratante;
2. Fragmenta a visão de preenchimento do evento;
3. Gera uma cascata de notificações desordenadas aos profissionais;
4. Não oferece garantias atômicas (se o contratante desistir ou errar no meio do processo, a escala fica incompleta).

### 1.2 Objetivo
Projetar o suporte completo de backend e contrato de API para publicação e gestão atômica de escalas em lote vinculadas a um `evento`, com transacionalidade rígida, idempotência ponta a ponta e gestão de carga no motor de despacho.

---

## 2. Modelo de Dados

### 2.1 Estrutura Existente
O banco de dados já possui a tabela `public.evento` e a chave estrangeira em `public.vaga` desde a migração inicial `20260922150400_vaga_e_posicao.sql`:

```sql
create table public.evento (
  id                 uuid primary key default gen_random_uuid(),
  estabelecimento_id uuid not null references public.estabelecimento(id),
  nome               text not null,
  data               date not null,
  local              text not null
);

create table public.vaga (
  ...
  evento_id          uuid references public.evento(id),
  ...
);
```

### 2.2 Evolução Necessária do Modelo (DDL Proposto)
Para viabilizar a escala em lote completa, a tabela `public.evento` precisa ser enriquecida com:
1. `chave_cliente uuid not null`: chave de idempotência da escala (gerada pelo cliente web/app);
2. `criado_por uuid not null references public.usuario(id)`: auditoria de autoria do membro do estabelecimento;
3. `criado_em timestamptz not null default privado.agora()`: timestamp no relógio do produto;
4. `estado text not null default 'ativo'`: ciclo de vida do evento (`ativo`, `cancelado`, `concluido`);
5. `observacoes text`: observações gerais do evento;
6. `regiao_administrativa text`: região administrativa para auditoria geográfica;
7. Restrição de unicidade: `unique (estabelecimento_id, chave_cliente)` para garantia de idempotência.

```sql
-- DDL incremental proposto para public.evento
alter table public.evento
  add column if not exists chave_cliente uuid not null,
  add column if not exists criado_por uuid not null references public.usuario(id),
  add column if not exists criado_em timestamptz not null default privado.agora(),
  add column if not exists estado text not null default 'ativo' check (estado in ('ativo', 'cancelado', 'concluido')),
  add column if not exists regiao_administrativa text,
  add column if not exists observacoes text,
  add constraint evento_chave_cliente_uk unique (estabelecimento_id, chave_cliente);

create index if not exists evento_estabelecimento_data_idx
  on public.evento (estabelecimento_id, data desc);
```

---

## 3. RPCs Propostas

### 3.1 `public.publicar_escala(payload jsonb) returns jsonb`
Executa em **uma única transação atômica** a criação do `evento` e de todas as `vagas` e `posicoes` da escala.

#### Assinatura e Parâmetros
```sql
public.publicar_escala(
  estabelecimento_id uuid,
  evento             jsonb,    -- { nome, data, local, ponto, regiao_administrativa, observacoes }
  vagas              jsonb[],  -- Array de especificações de vaga por função
  chave              uuid      -- Chave de idempotência da escala inteira
) returns jsonb;
```

#### Regras de Validação Atômica
1. **Autenticação e Perfil:**
   - Exige conta ativa com perfil `contratante` (RN25).
   - Exige que o autor seja membro do estabelecimento (`privado.eh_membro(estabelecimento_id)`).
2. **Idempotência (RF04 / RF19):**
   - Se já existir evento com `(estabelecimento_id, chave)`, retorna o resumo da escala já gravada sem reinserir nada.
3. **Limites de Proteção contra Sobrecarga (Circuit Breaker):**
   - Mínimo de 1 vaga e máximo de **10 vagas** por escala.
   - Máximo de **100 posições consolidadas** no total do evento (limite prudencial para não exceder limites de transação do Postgres e cotas de notificação).
4. **Validação Rigorosa das Vagas (RN02, RN18, RN19, RN24):**
   - Cada item do array `vagas` é validado individualmente:
     - `funcao_id` existente e ativa;
     - `inicio_em > privado.agora()` e `fim_em > inicio_em`;
     - Se `modo = 'selecao'`, `inicio_em > privado.agora() + interval '24 hours'` (RN24);
     - `posicoes` entre 1 e 50 por vaga;
     - `valor_centavos > 0` (RN18);
     - Campos obrigatórios da RN02 (`inclui_refeicao`, `inclui_transporte`, `exige_material_proprio`, `responsavel_local`);
     - Validação de texto limpo sem dados de contato nem termos proibidos (RN10 / Diretriz 1.2).
5. **Garantia Tudo-ou-Nada:**
   - Se qualquer vaga falhar em qualquer validação, **toda a escala é rejeitada com rollback**. Nenhuma vaga ou evento órfão permanece gravado.
6. **Despacho Coordenado:**
   - Cada vaga gerada recebe um registro na fila `pgmq.q_despacho`.

### 3.2 `public.painel_escala(evento_id uuid) returns jsonb`
Visão consolidada da escala para a interface web/mobile da produtora:
- Metadados do evento (nome, data, local, status);
- Totais agregados: `total_posicoes`, `confirmadas`, `pendentes_selecao`, `abertas`, `canceladas`;
- Lista de vagas com progresso de preenchimento por função, valor unitário e total contratado.

### 3.3 `public.cancelar_escala(evento_id uuid, motivo text) returns jsonb`
Permite o cancelamento coordenado de uma escala futura:
- Transita o `evento.estado` para `'cancelado'`.
- Cancela em lote todas as vagas ativas do evento (`estado = 'cancelada'`).
- Cancela todas as posições abertas (`estado = 'cancelada'`).
- Para posições já confirmadas: aplica a regra contratual de cancelamento da casa (RF12 / RN12) e emite os avisos devidos aos profissionais já contratados.

---

## 4. Análise de Riscos: Carga, Concorrência e Regra do Teto (RN23)

A publicação em lote de uma escala de 40 a 60 posições impõe desafios específicos à infraestrutura do Supabase:

### 4.1 Tempestade de Despacho (Dispatch Storm)
- **Problema:** A inserção de 5 vagas na mesma transação gera 5 inserções em `pgmq.q_despacho`. O gatilho `trg_disparar_despacho` tenta invocar a Edge Function `despachar` via `net.http_post` no pós-commit.
- **Risco:** Disparo simultâneo de 5 instâncias Deno concorrentes, competindo pelos mesmos locks de conexão no pooler e varrendo tabelas de elegíveis em paralelo.
- **Mitigação Recomendada:**
  - Enfileirar as mensagens do pgmq com ligeiro escalonamento temporal ou agrupar a solicitação de processamento em um único sinal HTTP, deixando o processador de fila consumir as mensagens em sequência ordenada.

### 4.2 Impacto na Regra do Teto (RN23) e Notificações Push
- **Problema:** Na RN23, um profissional apto a mais de uma função da escala (por exemplo, garçom e barman) ou profissionais vizinhos ao local receberiam múltiplos pushes se as vagas fossem despachadas isoladamente.
- **Comportamento Atual:** A primeira vaga despachada gera a notificação imediata (`vaga`). As vagas seguintes para o mesmo profissional entram na janela de retenção do teto (`notificacao_id is null` em `public.despacho`) e são liberadas em até 30 minutos agrupadas sob o tipo `vagas_agrupadas`.
- **Oportunidade de Otimização:** Criar um tipo de notificação específico `escala_publicada` para eventos de grande porte, informando no push: *"Novo evento em [Local] com várias vagas abertas"*, consolidando o interesse do profissional em um único clique sem saturar a cota diária de pushes.

### 4.3 Lock Contention em `public.posicao`
- **Mitigação:** Como as posições são geradas via `insert ... select ... from generate_series(1, posicoes)`, a inserção é set-based pura, evitando laços procedurais lentos e minimizando a duração das travas de tabela.

---

## 5. Especificação no Contrato OpenAPI

No contrato OpenAPI (`contrato/openapi.yaml`), a operação nasce no namespace de `Vagas`:

```yaml
/rpc/publicar_escala:
  post:
    tags: [Vaga e posições]
    operationId: publicarEscala
    summary: Publicar escala de evento em lote
    description: |
      Publica uma escala com múltiplas vagas e funções vinculadas a um evento em operação
      estritamente atômica (RF19, US06). Falha em qualquer item reverte a operação por completo.
      Idempotente pela chave da escala.
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: '#/components/schemas/NovaEscala'
    responses:
      '200':
        description: Escala e vagas publicadas com sucesso.
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/ResultadoEscala'
      '401':
        $ref: '#/components/responses/NaoAutenticado'
      '403':
        $ref: '#/components/responses/SemPermissao'
      '422':
        $ref: '#/components/responses/RegraRecusou'
```

---

## 6. Plano de Migração e Entrega (Fases)

1. **Fase 1 (Banco de Dados e RPCs):**
   - Migração DDL enriquecendo `public.evento` com colunas de estado, auditoria e índice de idempotência.
   - Criação da RPC `public.publicar_escala` e funções de leitura `public.painel_escala`.
   - Suíte de testes pgTAP cobrindo casos de sucesso, recusas parciais (rollback atômico), idempotência de reenvio e proteção contra injeção de texto livre inválido.
2. **Fase 2 (Contrato OpenAPI e Modelos):**
   - Submissão de PR no repositório `FrilaApp/frila-docs` adicionando os schemas `NovaEscala` e `ResultadoEscala`.
   - Atualização do espelho `contrato/openapi.yaml` e bump de versão para `0.3.0` (ou `0.2.42` compatível).
3. **Fase 3 (Integração Web e App):**
   - Disponibilização na interface web para contratação em lote por produtoras.

---

## 7. Questões em Aberto para Decisão do Dono (Registradas em DECISOES.md)

1. **Idempotência de itens da escala:** A `chave_cliente` do evento é suficiente para deduzir deterministicamente a idempotência das vagas filhas, ou cada vaga do array deve exigir uma chave própria gerada pelo cliente?
   - *Recomendação:* A chave da escala deve governar tudo; as vagas herdam `vaga.chave_cliente = uuid_generate_v5(chave_escala, funcao_id::text)`.
2. **Push de Notificação: Avulso vs Agrupado de Evento:** A publicação de escala deve disparar notificações individuais por vaga (apoiando-se no agrupamento de 30 min da RN23) ou deve emitir um push consolidado de evento (`escala_evento`)?
   - *Recomendação:* Na v1.2 inicial, apoiar-se no motor de despacho existente com RN23; na v1.3 avaliar template dedicado de evento.
3. **Teto Máximo por Escala:** Fixar limite em 10 vagas e 100 posições por chamada para evitar sobrecarga de transação e limites de memória no webhook do `pg_net`.
