# Proposta Arquitetural: Escala de Evento em Lote (v1.2)

**Cartão Trello:** `6mi66YDp` (v1.2 · Backend + Web · Escala de evento em lote)  
**História / Requisitos:** US06 (8 pt) · RF19 · RN02, RN10, RN18, RN19, RN21, RN23, RN24  
**Data:** 15/10/2026 (Revisão 3 — saneamento das pendências apontadas na re-revisão do Claude Code #2)  
**Autor:** Faísca (Backend / Antigravity)  
**Status:** Proposta técnica preliminar (aguarda deliberação do dono do produto)

---

## 1. Contexto e Motivação

### 1.1 O Cenário de Negócio (US06 / RF19)
Atualmente, no app móvel (iOS/Android), a publicação de vagas é desenhada para contratações pontuais ou de curto prazo (uma função por vez via `public.publicar_vaga`, mesmo que com múltiplas posições).

Produtoras de eventos, buffets e casas noturnas organizam escalas complexas para eventos de grande porte (formaturas, casamentos, festivais corporativos, feiras de negócios), frequentemente com semanas de antecedência. Uma escala típica mobiliza **entre 20 e 60 profissionais** divididos em **3 a 8 funções distintas** (por exemplo: 15 garçons, 8 barmans, 4 cozinheiros, 4 auxiliares de cozinha, 4 recepcionistas, 6 seguranças), muitas vezes com múltiplos turnos para a mesma função (ex.: garçom montagem/dia e garçom operação/noite).

Cadastrar cada vaga individualmente no smartphone:
1. Gera atrito operacional inaceitável para o contratante;
2. Fragmenta a visão de preenchimento do evento;
3. Gera uma cascata de notificações desordenadas aos profissionais;
4. Não oferece garantias atômicas (se o contratante desistir ou errar no meio do processo, a escala fica incompleta).

### 1.2 Objetivo
Projetar o suporte de backend e contrato de API para publicação e gestão atômica de escalas em lote vinculadas a um `evento`, com transacionalidade rígida, idempotência ponta a ponta sem colisão de chaves, reutilização estrita das funções de cancelamento consolidadas e respeito à capacidade do motor de despacho e agrupamento da RN23.

---

## 2. Modelo de Dados

### 2.1 Estrutura Existente
O banco de dados já possui a tabela `public.evento` e a chave estrangeira em `public.vaga` desde a migração inicial `supabase/migrations/20260922150400_vaga_e_posicao.sql`:

```sql
create table public.evento (
  id                 uuid primary key default gen_random_uuid(),
  estabelecimento_id uuid not null references public.estabelecimento(id),
  nome               text not null,
  data               date not null,
  local              text not null
);

-- Em public.vaga:
-- evento_id uuid references public.evento(id)
```

### 2.2 Evolução Incremental do Modelo (DDL Proposto)
O código atual do repositório não grava dados na tabela `public.evento` (confirmar no banco antes de aplicar; a DDL abaixo é idempotente e tolera dados legados). Para viabilizar a escala em lote, a tabela é enriquecida preservando convenções de autoria, integridade e georreferenciamento:

1. `chave_cliente uuid not null`: chave de idempotência da escala inteira (fornecida pelo cliente);
2. `publicado_por uuid not null references public.usuario(id)`: autoria alinhada à convenção `vaga.publicado_por`;
3. `criado_em timestamptz not null default privado.agora()`: relógio do produto;
4. `estado text not null default 'ativo' check (estado in ('ativo', 'cancelado', 'concluido'))`: ciclo de vida do evento;
5. `observacoes text`: observações operacionais da escala;
6. `local text not null`: endereço textual obrigatório do evento (preexistente na tabela; fornece o valor herdado por padrão pelas vagas filhas para satisfazer a restrição `vaga.local not null`);
7. `ponto extensions.geography(Point, 4326) not null`: coordenada geográfica obrigatória do evento na escala (fornece o ponto herdado por padrão pelas vagas filhas para satisfazer a restrição `vaga.ponto not null`);
8. `regiao_administrativa text`: região administrativa do evento, informada na criação ou herdada de `estabelecimento.regiao_administrativa` (conforme convenção estabelecida em `20260928230000_regiao_administrativa.sql`).

```sql
-- DDL incremental seguro para public.evento (tratando preexistência)
alter table public.evento
  add column if not exists chave_cliente uuid,
  add column if not exists publicado_por uuid references public.usuario(id),
  add column if not exists criado_em timestamptz not null default privado.agora(),
  add column if not exists estado text not null default 'ativo' check (estado in ('ativo', 'cancelado', 'concluido')),
  add column if not exists ponto extensions.geography(Point, 4326),
  add column if not exists regiao_administrativa text,
  add column if not exists observacoes text;

-- Garante preenchimento antes da restrição not null caso existam linhas legadas de teste
update public.evento set chave_cliente = gen_random_uuid() where chave_cliente is null;
alter table public.evento alter column chave_cliente set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'evento_estabelecimento_chave_cliente_uk'
  ) then
    alter table public.evento
      add constraint evento_estabelecimento_chave_cliente_uk
      unique (estabelecimento_id, chave_cliente);
  end if;
end $$;

create index if not exists evento_estabelecimento_data_idx
  on public.evento (estabelecimento_id, data desc);
```

---

## 3. RPCs Propostas

### 3.1 `public.publicar_escala(estabelecimento_id uuid, evento jsonb, vagas jsonb, chave uuid) returns jsonb`
Executa em **uma única transação atômica** a criação do `evento` e de todas as `vagas` e `posicoes` da escala.

#### Parâmetros Recebidos (Compatíveis com PostgREST):
- `estabelecimento_id`: UUID do estabelecimento contratante.
- `evento`: objeto JSON `{ nome: text, data: date, local: text, ponto: jsonb, observacoes?: text, regiao_administrativa?: text }`.
  - `local` e `ponto` são **obrigatórios** no objeto do evento. As vagas filhas herdam obrigatoriamente `local` e `ponto` do evento caso não informem valores específicos por posto/setor, garantindo conformidade com a restrição `not null` de `public.vaga(local, ponto)`.
- `vagas`: array JSON de itens de vaga. Cada item contém:
  - `chave_cliente`: UUID exclusivo daquela vaga (evitando colisão na restrição `unique (estabelecimento_id, chave_cliente)`);
  - `funcao_id`: UUID da função cadastrada no catálogo;
  - `inicio_em`: timestamp com timezone de início do turno;
  - `fim_em`: timestamp com timezone de término do turno;
  - `posicoes`: inteiro entre 1 e 50 (limite específico proposto para lote para proteção contra rajadas; sob decisão do dono, ver §6.2);
  - `valor_centavos`: valor total em centavos por profissional (RN18);
  - `inclui_refeicao`: booleano (RN02);
  - `inclui_transporte`: booleano (RN02);
  - `exige_material_proprio`: booleano (RN02);
  - `responsavel_local`: nome do contato no turno (RN02);
  - `modo`: `'urgencia'` ou `'selecao'`;
  - `local?`: texto opcional (se omitido, herda `evento.local`);
  - `ponto?`: jsonb opcional (se omitido, herda `evento.ponto`).
- `chave`: UUID da escala inteira para idempotência no nível do evento.

#### Regras de Negócio e Validações:
1. **Idempotência no Topo:**
   - Se já existir `public.evento` com `(estabelecimento_id, chave)`, a RPC recupera o evento e retorna o resumo das vagas já associadas, sem duplicar registros.
2. **Autorização e Estado da Conta:**
   - O autor autenticado (`auth.uid()`) deve pertencer ao estabelecimento (`privado.eh_membro(estabelecimento_id)`).
   - A conta do autor não pode estar suspensa (recusa canônica **403 `sem_permissao`** com `details: conta_suspensa`, conforme resposta contratual `ContaSuspensa`).
3. **Limites da Escala (Circuit Breaker contra Rajadas de Despacho):**
   - Mínimo de 1 vaga e máximo de **10 vagas** por escala.
   - Máximo de **100 posições consolidadas** no total da escala (e até 50 posições por vaga filha).
   - *Justificativa técnica real:* O comentário oficial da migração `supabase/migrations/20260922150400_vaga_e_posicao.sql` registra que o teto contratual de 200 posições por vaga existe para que um erro de digitação na publicação não gere duzentas mil posições e, com elas, duzentas mil notificações. Nesta proposta de escala em lote, onde múltiplas vagas são criadas simultaneamente, sugerem-se limites mais conservadores (10 vagas filhas, até 50 posições por vaga e máximo de 100 posições consolidadas por chamada) para conter o volume pontual de notificações e despachos gerados na publicação. Esses parâmetros são propostas preliminares submetidas à deliberação do dono do produto (§6.2).
4. **Validações das Vagas Filhas (Alinhadas a `publicar_vaga`):**
   - Função deve existir no catálogo (se inexistente, recusa **422 `campo_invalido`** com `details: funcao_id`, idêntica a `publicar_vaga`).
   - Horários coerentes: `fim_em > inicio_em` e `inicio_em > privado.agora()` (recusa 422 `horario_invalido`).
   - Se `modo = 'selecao'`, exige antecedência estrita maior que 24 horas (`inicio_em > privado.agora() + interval '24 hours'`, alinhado a `publicar_vaga` / **RN24** / recusa 422 `selecao_sem_antecedencia`).
   - Valor inteiro positivo em centavos (**RN18**).
   - Campos obrigatórios de acomodação presentes (**RN02**).
   - Higienização de texto livre (**RN10** / Diretriz 1.2): textos em `local`, `responsavel_local` e `observacoes` passam por `privado.contem_contato_ou_link` recusando telefones, e-mails e links com **422 `campo_invalido`**.
5. **Transacionalidade Tudo-ou-Nada:**
   - Se qualquer item do array falhar em qualquer validação, **toda a transação sofre rollback**. Nenhum evento órfão ou vaga parcial é persistida.

### 3.2 `public.painel_escala(evento_id uuid) returns jsonb`
Retorna visão agregada da escala:
- Metadados do evento (`id`, `nome`, `data`, `local`, `estado`, `publicado_por`);
- Agregações: `total_posicoes`, `confirmadas`, `em_selecao`, `abertas`, `canceladas`;
- Lista de vagas filhas vinculadas via `vaga.evento_id = evento_id`.

> **Aviso de Comportamento Conhecido (`republicar_vaga`):** Conforme documentado na migração `supabase/migrations/20260925180000_republicar_vaga.sql`, a RPC `republicar_vaga` clona uma vaga cancelada gerando nova chave de cliente e **não preserva** `evento_id` (vaga avulsa de urgência). Caso uma vaga da escala seja cancelada e posteriormente republicada de forma isolada, ela não fará mais parte do evento agrupado no `painel_escala`.

### 3.3 `public.cancelar_escala(evento_id uuid, motivo text) returns jsonb`
Executa o cancelamento coordenado de uma escala futura sem reinventar regras de negócio nem quebrar gatilhos de concorrência:

- **Mecanismo de Execução:**
  A RPC adquire lock no evento (`select id from public.evento where id = evento_id for update`) e transita `evento.estado = 'cancelado'`.
  Para cada vaga associada ao evento que não esteja encerrada, **invoca internamente a RPC existente `public.cancelar_vaga(vaga.id, motivo)`**.
- **Garantias Herdadas:**
  1. Cancela posições abertas;
  2. Cancela posições confirmadas cujo turno ainda não iniciou, com emissão de notificações de cancelamento aos profissionais já alocados (RF12 / RN12);
  3. Resolução automática de corridas com `candidatar`: herda o gatilho `vaga_cancelada_recolhe_confirmadas` da migração `supabase/migrations/20260929120000_cancelar_vaga_sem_corrida.sql`, garantindo que nenhuma candidatura em voo seja confirmada concorrentemente com o cancelamento da escala (RNF14).

---

## 4. Análise de Concorrência, RN21 e Regra do Teto (RN23)

### 4.1 Sobreposição de Turnos na Escala (RN21)
Numa escala de grande porte com múltiplos postos no mesmo horário, profissionais qualificados para mais de uma função (ex.: garçom e barman) podem visualizar e se candidatar a ambas:
- A restrição física `sem_turno_sobreposto` (`exclude using gist (profissional_id with =, tstzrange(inicio_em, fim_em, '[)') with &&)` em `public.posicao`) impede fisicamente que um mesmo profissional confirme dois turnos com sobreposição de horário.
- Se o profissional confirmar para barman, qualquer tentativa concorrente ou posterior de confirmação para garçom no mesmo intervalo será rejeitada pelo banco, mantendo a outra vaga da escala aberta para outros profissionais.

### 4.2 Impacto no Motor de Despacho e na Regra do Teto (RN23)
- **Como a RN23 atua:** A regra do teto impõe intervalo mínimo de 30 minutos (`privado.parametro_notificacao.teto_janela`) para notificações ao mesmo profissional, liberando exceção apenas para vagas com início em menos de 2 horas (`urgente_antecedencia`).
- **Comportamento em Lote:** A primeira vaga despachada pela escala gera notificação imediata do tipo `vaga`. As demais vagas da mesma escala para profissionais no mesmo raio entram em retenção (`notificacao_id is null` em `public.despacho`) e são liberadas pelo agendador em até 30 minutos consolidadas no push do tipo `vagas_agrupadas`.
- **Governança de Tipos de Notificação:** A proposta **não** cria tipos novos de push (como `escala_publicada` ou `escala_evento`) na v1.2, pois isso exigiria modificar o enum `public.tipo_notificacao` (16 tipos hoje), atualizar `privado.tipo_no_teto()` e alterar o contrato espelhado dos 3 clientes móveis. A escala apoia-se 100% no motor de agrupamento já homologado da RN23.

---

## 5. Especificação no Contrato OpenAPI

No contrato OpenAPI (`FrilaApp/frila-docs · api/openapi.yaml`, espelhado em `contrato/openapi.yaml`), a operação pertence à tag oficial **`Vagas`**:

```yaml
/rpc/publicar_escala:
  post:
    tags: [Vagas]
    operationId: publicarEscala
    summary: Publicar escala de evento em lote
    description: |
      Publica uma escala com múltiplas vagas vinculadas a um evento em operação
      atômica (RF19, US06). Falha em qualquer item reverte a transação por completo.
      Idempotente pela chave da escala e chaves individuais das vagas.
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
      '409':
        $ref: '#/components/responses/Conflito'
      '422':
        $ref: '#/components/responses/RegraRecusou'
```

---

## 6. Questões em Aberto para Decisão do Dono (Registradas em DECISOES.md)

1. **Geração de Chaves das Vagas Filhas:** O cliente móvel/web deve gerar os UUIDs de cada vaga filha no array, ou o backend deve calcular deterministicamente `uuid_generate_v5` a partir da chave do evento concatenada com o ID da função?
   - *Recomendação:* Exigir que o cliente envie `chave_cliente` explícita por vaga no array `vagas`, garantindo rastreabilidade e idempotência por item sem risco de colisões em turnos duplos.
2. **Teto de Posições e Vagas da Escala:** Fixar para a v1.2 os limites propostos de até 10 vagas por escala, até 50 posições por vaga e máximo de 100 posições consolidadas por chamada RPC (conforme alinhamento em `DECISOES.md`), avaliando ampliação na v1.3 conforme a telemetria do motor de despacho e volume de notificações.
