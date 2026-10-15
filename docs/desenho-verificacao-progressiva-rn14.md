# Desenho Técnico: Verificação Progressiva de Identidade (RN14)

**Cartão Trello:** `GtWr3ZeJ` (v1.1 · Produto + Backend · Verificação progressiva de identidade (RN14): desenho)  
**História / Requisitos:** RN14, RN15 · RF02, RF03  
**Data:** 15/10/2026  
**Autor:** Faísca (Backend)  
**Status:** Desenho técnico de arquitetura para a v1.1/v1.2 (aguarda decisão do dono)

---

## 1. Princípio Fundamental de Produto (RN14)

A verificação de identidade no Frila **nunca é barreira de entrada** no cadastro inicial nem impeditivo para realizar o primeiro turno. O onboarding deve ser leve e imediato.

A exigência de documentos com foto e biometria facial só é acionada **progressivamente**, motivada por:
1. **Gatilhos de volume:** Profissional que completou um marco de turnos (ex: 5 turnos cumpridos com sucesso) ou movimentou volume financeiro relevante.
2. **Gatilhos de segurança/fraude:** Denúncia grave apurada (`public.denunciar`), contestação de presença, suspeita de falsidade ideológica ou criação de contas duplicadas.
3. **Solicitação voluntária:** Profissional que deseja obter o selo de "Identidade Verificada" para aumentar sua atratividade na disputa por vagas concorridas.

---

## 2. Modelo de Dados

### 2.1 Enum de Status de Verificação
```sql
create type public.status_verificacao as enum (
  'nao_exigida',  -- Estado padrão inicial (cadastro leve)
  'pendente',     -- Disparada por gatilho; usuário precisa enviar fotos
  'em_analise',   -- Mídia recebida e sob processamento
  'aprovada',     -- Identidade confirmada com sucesso (concede selo)
  'rejeitada'     -- Documento ilegível, inválido ou divergente
);
```

### 2.2 Tabela `privado.verificacao_identidade`
Armazenamento em esquema restrito (`privado`) para proteger dados de conformidade:
```sql
create table privado.verificacao_identidade (
  id                    uuid primary key default gen_random_uuid(),
  usuario_id            uuid not null references public.usuario(id) on delete cascade,
  status                public.status_verificacao not null default 'pendente',
  motivo                text not null, -- 'gatilho_5_turnos', 'apuracao_denuncia', 'solicitacao_voluntaria'
  documento_tipo        text check (documento_tipo in ('cnh', 'rg', 'cin')),
  documento_hash        text, -- Hash SHA-256 do documento para coibir contas duplicadas (sem guardar o número em texto puro)
  storage_path_frente   text, -- Caminho no bucket seguro Supabase Storage
  storage_path_verso    text,
  storage_path_selfie   text,
  biometria_score       numeric(5,2), -- Ex: 98.50% de confiança retornado pelo provedor
  provedor              text not null default 'manual', -- 'manual', 'unico', 'idwall', 'caf'
  provedor_id           text, -- Identificador da transação no provedor externo
  rejeicao_motivo       text,
  solicitado_em         timestamptz not null default privado.agora(),
  respondido_em         timestamptz,
  expira_em             timestamptz not null default (privado.agora() + interval '30 days')
);

create index idx_verificacao_usuario on privado.verificacao_identidade (usuario_id);
create index idx_verificacao_status on privado.verificacao_identidade (status) where status in ('pendente', 'em_analise');
```

### 2.3 Supabase Storage Bucket (`documentos-identidade`)
- **Bucket Privado:** `documentos-identidade` com acesso público desabilitado.
- **Políticas de Acesso:** Leitura e escrita exclusivas do backend (`service_role`). O app envia via URL assinada de upload de curta duração (15 minutos).

---

## 3. Fluxo Operacional e RPCs

### 3.1 `public.status_minha_verificacao()`
- Retorna o status atual do usuário autenticado (`status_verificacao`, `motivo`, `prazo_limite`).
- Permite ao cliente iOS exibir o banner informativo ou o selo no perfil público.

### 3.2 `public.iniciar_verificacao_identidade(p_documento_tipo text)`
- Gera URLs assinadas efêmeras de upload (`signedUploadUrl`) para envio seguro das 3 imagens (frente, verso e selfie).
- Cria registro em `privado.verificacao_identidade` em estado `em_analise`.

### 3.3 `privado.exigir_verificacao(p_usuario_id uuid, p_motivo text)`
- Invocada internamente após o fechamento do 5º turno cumprido ou por decisão de suporte/moderação.
- Envia notificação push e e-mail transacional alertando o profissional sobre a etapa de validação.

### 3.4 Webhook de Resolução (`privado.processar_retorno_verificacao`)
- Consome o retorno do provedor biométrico ou a decisão da moderação interna.
- Se aprovado: concede o status `aprovada` e atualiza a flag visual no perfil do profissional.
- Se rejeitado: registra o motivo neutro (ex: "foto desfocada", "documento vencido") e reabre prazo para novo envio.

---

## 4. Conformidade LGPD & RN15 (Minimização e Purga)

1. **Base Legal e Finalidade:**
   - Tratamento amparado estritamente no **Art. 11, II, "g" da LGPD** (Garantia da prevenção à fraude e à segurança do titular nos processos de identificação e autenticação).
2. **Minimização de Dados (RN15):**
   - O número de RG/CPF do documento nunca é exposto em APIs de listagem pública.
   - Logs técnicos de aplicação jamais registram URLs de imagens ou dados extraídos de OCR.
3. **Política de Descarte e Purga de Mídia:**
   - As imagens fotográficas armazenadas no Storage possuem ciclo de retenção curto: são **compulsoriamente eliminadas após 30 dias** da aprovação/rejeição através de job em `privado.higienizar_tabelas()`.
   - Após a purga da mídia, o banco preserva apenas os metadados de auditoria: data da validação, status, score biométrico e hash criptográfico unívoco para prevenção de reutilização de documentos falsos.

---

## 5. Análise de Custos e Provedores

| Opção | Custo Estimado | Complexidade | Veredito Recomendado |
|---|---|---|---|
| **A. Moderação Manual Interna** | R$ 0,00 direto (+ tempo equipe) | Baixa (Backoffice Supabase) | **Recomendada para o Piloto DF (v1.1)** |
| **B. Provedor Especializado (Unico / CAF / Idwall)** | R$ 1,50 a R$ 3,80 por consulta | Média (integração webhook) | **Recomendada para a v1.2 em escala** |
| **C. Validação em Lote por OCR puro** | R$ 0,30 por documento | Média (sem biometria viva) | Descartada (não previne falsidade ideológica) |

---

## 6. Riscos e Mitigações

1. **Fricção no Onboarding e Evasão:**
   - *Mitigação:* A verificação **nunca** bloqueia o primeiro turno. O usuário só é notificado após já ter vivenciado o valor da plataforma.
2. **Vazamento de Imagens Pessoais:**
   - *Mitigação:* Bucket 100% privado, sem acesso público, uploads via URLs assinadas de uso único e exclusão definitiva em 30 dias.
3. **Falsos Positivos de Fraude:**
   - *Mitigação:* Toda rejeição automática possui canal direto de contestação via `public.abrir_suporte` para reanálise humana.

---

## 7. Perguntas em Aberto para Decisão do Dono (Registradas em `DECISOES.md`)

1. **Critério exato para o gatilho automático:**
   - Exigir verificação após **5 turnos cumpridos**, após atingir **R$ 1.500,00** em diárias recebidas, ou manter puramente sob demanda de denúncias na v1.1?
   - *Recomendação:* No piloto DF (v1.1), acionar apenas sob denúncia ou suspeita de fraude com análise manual. Na v1.2, fixar gatilho automático aos 5 turnos.
2. **Selo Visual de Identidade Verificada:**
   - O app deve exibir uma insígnia visual ("Identidade Verificada") no perfil público do profissional para estimular a adesão voluntária?
   - *Recomendação:* Sim, incentiva a verificação orgânica sem gerar atrito coercitivo.
3. **Prazo de Bloqueio por Inércia:**
   - Se um usuário receber a solicitação obrigatória (por denúncia), quantos dias tem para enviar os documentos antes de ter a candidatura suspensa preventivamente?
   - *Recomendação:* 7 dias corridos.
