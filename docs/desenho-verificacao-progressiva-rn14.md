# Desenho Técnico: Verificação Progressiva de Identidade (RN14)

**Cartão Trello:** `GtWr3ZeJ` (v1.1 · Produto + Backend · Verificação progressiva de identidade (RN14): desenho)  
**História / Requisitos:** RN14, RN15 · RF02, RF03, RF22, RF25 · LGPD (Art. 5º, II; Art. 11, I e II, "g"; Art. 38)  
**Data:** 15/10/2026 (Revisão 3 — saneamento das pendências apontadas na re-revisão do Claude Code #2)  
**Autor:** Faísca (Backend)  
**Status:** Desenho técnico de arquitetura para a v1.1/v1.2 (aguarda decisão do dono)

---

## 1. Princípio Fundamental de Produto e Bases Legais da LGPD

### 1.1 O Princípio da RN14 (Onboarding sem Barreiras)
A verificação de identidade no Frila **nunca é barreira de entrada** no cadastro inicial nem pré-requisito para disputar e realizar o primeiro turno. O onboarding inicial de profissionais e contratantes deve permanecer leve, ágil e focado na autenticação ágil por código no e-mail (sem SMS/OTP no cadastro) e aceite dos termos.

A exigência de envio de documento oficial com foto e biometria facial só é acionada **progressivamente**, motivada por:
1. **Gatilhos de segurança e integridade (Prevenção à Fraude):** Denúncia grave apurada via `public.denunciar`, contestação justificada de presença no local (RN22), suspeita de falsidade ideológica ou criação de contas duplicadas com o mesmo titular.
2. **Solicitação voluntária (Consentimento):** Profissional que deseja obter o selo visual de "Identidade Verificada" para aumentar sua atratividade e confiança perante os estabelecimentos contratantes.

### 1.2 Enquadramento Legal e Dados Pessoais Sensíveis (LGPD)
Documentos oficiais de identificação (RG, CNH, CIN), selfies e dados de biometria facial constituem **dados pessoais sensíveis** (Art. 5º, II da Lei nº 13.709/2018 - LGPD). O tratamento é estruturado com bases legais segregadas por finalidade:

- **Gatilho de Segurança / Fraude:** Amparado no **Art. 11, II, "g" da LGPD** (*Garantia da prevenção à fraude e à segurança do titular, nos processos de identificação e autenticação de cadastros em sistemas eletrônicos*).
- **Selo Voluntário:** Amparado no **Art. 11, I da LGPD** (*Consentimento do titular, de forma específica e destacada, para finalidades determinadas*). O app exibe termo explícito detalhando o processamento biométrico temporário e os benefícios da chancela no perfil.
- **Gatilhos de Volume Descartados na v1.1:** A imposição coercitiva por volume financeiro (ex.: R$ 1.500) ou número de turnos (ex.: 5 turnos) sem suspeita concreta de fraude não atende ao princípio da estrita necessidade (Art. 6º, III da LGPD) e violaria a premissa de produto da RN14. Portanto, fica descartada para o piloto DF.
- **Governança e Salvaguardas:**
  - Elaboração de Relatório de Impacto à Proteção de Dados Pessoais (RIPD, Art. 38 da LGPD) prévio ao início do processamento biométrico em produção.
  - O provedor externo de verificação contratado atua na condição de **Operador** de dados (exigindo *Data Processing Agreement* com cláusulas estritas de confidencialidade, descarte e vedação de reaproveitamento de dados).

### 1.3 Matriz de Objetos: Existe Hoje × A Criar (Proposta v1.1/v1.2)

| Objeto | Tipo | Estado | Descrição |
|---|---|:---:|---|
| `public.denunciar` | RPC | **Existe** | Registro de denúncias graves no app. |
| `public.contestar_suspensao` | RPC | **Existe** | Contestação de suspensão no app. |
| `public.abrir_suporte` | RPC | **Existe** | Abertura de chamado de suporte pelo turno. |
| `privado.higienizar_tabelas` | Função | **Existe** | Rotina de higienização de dados e expurgo. |
| `limpar-contas-orfas` | Edge Function | **Existe** | Rotina diária de retenção que aciona a esteira. |
| `public.status_verificacao` | Enum | **A criar** | Enum com os 5 status do ciclo de vida da verificação. |
| `privado.verificacao_identidade` | Tabela | **A criar** | Tabela interna com HMAC e rastreabilidade de mídias. |
| Bucket `documentos-identidade` | Storage | **A criar** | Bucket privado para uploads assinados efêmeros. |
| `privado.exigir_verificacao(uuid, text, int)` | Função | **A criar** | Função de serviço para moderação acionar a exigência formal. |
| `public.status_minha_verificacao()` | RPC | **A criar** | Consulta de status de verificação pelo próprio titular. |
| `public.iniciar_verificacao_identidade(text)` | RPC | **A criar** | Início do fluxo voluntário ou em resposta à exigência. |
| `public.confirmar_envio_verificacao(uuid)` | RPC | **A criar** | Confirmação pós-upload das 3 mídias. |
| `privado.listar_verificacoes_para_expurgo()` | Função | **A criar** | Listagem de mídias para deleção no Storage pela Edge Function. |
| `privado.confirmar_expurgo_verificacao(uuid)` | Função | **A criar** | Confirmação pós-deleção no Storage. |

---

## 2. Modelo de Dados

### 2.1 Enum de Status de Verificação (Proposta — a criar)
```sql
create type public.status_verificacao as enum (
  'nao_exigida',  -- Estado padrão inicial (cadastro leve sem atrito)
  'pendente',     -- Exigência disparada; aguarda envio das mídias pelo usuário
  'em_analise',   -- Mídias enviadas; aguardando decisão do provedor/moderação
  'aprovada',     -- Identidade confirmada; concede o selo visual
  'rejeitada'     -- Documento ilegível, divergente ou vencido
);
```

### 2.2 Tabela `privado.verificacao_identidade` (Proposta — a criar)
Armazenada em esquema interno (`privado`), isolada do PostgREST público e acessível exclusivamente via funções seguras ou pela `service_role`:

```sql
create table privado.verificacao_identidade (
  id                    uuid primary key default gen_random_uuid(),
  usuario_id            uuid not null references public.usuario(id),
  status                public.status_verificacao not null default 'pendente',
  motivo                text not null, -- 'apuracao_denuncia', 'solicitacao_voluntaria'
  documento_tipo        text check (documento_tipo in ('cnh', 'rg', 'cin')),
  documento_hmac        text, -- HMAC-SHA256 com pepper de servidor (impede reversão por força bruta em CPFs de 11 dígitos)
  storage_path_frente   text, -- Caminho no bucket privado do Supabase Storage
  storage_path_verso    text,
  storage_path_selfie   text,
  biometria_score       numeric(5,2), -- Ex: 98.50% retornado pelo provedor (efêmero, purgado aos 30 dias)
  provedor              text not null default 'manual', -- 'manual', 'unico', 'caf', 'idwall'
  provedor_id           text, -- Identificador da transação no provedor externo
  rejeicao_motivo       text,
  solicitado_em         timestamptz not null default privado.agora(),
  enviado_em            timestamptz,
  prazo_envio_ate       timestamptz not null default (privado.agora() + interval '7 days'),
  respondido_em         timestamptz,
  expurgo_midia_em      timestamptz
);

create index idx_verificacao_usuario on privado.verificacao_identidade (usuario_id);
create index idx_verificacao_status on privado.verificacao_identidade (status)
  where status in ('pendente', 'em_analise');
create index idx_verificacao_expurgo on privado.verificacao_identidade (expurgo_midia_em)
  where storage_path_frente is not null;
```

---

## 3. Infraestrutura de Mídia e Ciclo de Retenção

### 3.1 Provisionamento do Supabase Storage (Proposta — a criar)
Atualmente, o projeto `frila-backend` opera sem buckets de Storage (como explicitado em `exportar_meus_dados`). Para a RN14, propõe-se:
- **Bucket Privado:** `documentos-identidade` com acesso público (`public = false`) completamente desabilitado.
- **Upload via URLs Assinadas:** O backend gera URLs efêmeras via `supabase.storage.from('documentos-identidade').createSignedUploadUrl(path)` com validade padrão do Supabase de 2 horas. O controle de validade de negócio é garantido no banco pela RPC `confirmar_envio_verificacao`, que só aceita a confirmação se o pedido estiver dentro do `prazo_envio_ate`.
- **Acesso:** Leitura permitida exclusivamente para o backend (`service_role`). Nenhum usuário possui permissão direta de leitura (`select`) via RLS no Storage.

### 3.2 Purga Real de Arquivos via Edge Function
Diferente das tabelas do Postgres gerenciadas via SQL por `privado.higienizar_tabelas()`, arquivos do Storage só podem ser excluídos de forma confiável através da API REST do Supabase Storage (`service_role`).

O expurgo segue o padrão consolidado da Edge Function `limpar-contas-orfas` (rotina diária de retenção):
1. **Passo Diário na Edge Function de Retenção:**
   - Invoca a RPC interna `privado.listar_verificacoes_para_expurgo()` (a criar), que busca registros onde `expurgo_midia_em <= privado.agora()` e com caminhos de arquivo não nulos.
   - Para cada lote, executa `storage.from('documentos-identidade').remove([storage_path_frente, storage_path_verso, storage_path_selfie])`.
   - Após a confirmação formal da deleção pela API do Storage, a função invoca `privado.confirmar_expurgo_verificacao(id)` (a criar), que limpa as colunas `storage_path_*` e o `biometria_score` no banco de dados.
2. **Definição dos Prazos de Expurgo:**
   - **Caso Concluído (`aprovada` ou `rejeitada`):** `expurgo_midia_em = respondido_em + interval '30 days'`.
   - **Caso Expirado por Inércia (`pendente` sem envio):** O pedido expira em `prazo_envio_ate` (7 dias). Caso tenha havido upload parcial de alguma imagem, a purga é agendada para 24 horas após a expiração.
   - **Caso em Análise (`em_analise`):** SLA de moderação operacional de até 5 dias úteis. Para evitar retenção perpétua de fotos caso um pedido seja esquecido pela moderação, adota-se teto máximo de segurança de **15 dias corridos após o envio** (`expurgo_midia_em = enviado_em + interval '15 days'`), agendando o expurgo compulsório das mídias em conformidade com o princípio da necessidade (Art. 6º, III da LGPD) e alertando a equipe de moderação.

### 3.3 Tratamento de Exclusão de Conta, Retenção do HMAC e Delimitações (RF25 / LGPD)
O Frila utiliza anonimização de conta em duas etapas: exclusão lógica imediata e purga física em 15 dias (`privado.limpar_contas_anonimizadas(15)`).
- Como as contas não sofrem `DELETE` imediato (permanecem em `anonimizado_em`), o `ON DELETE CASCADE` relacional não é suficiente.
- A função `privado.limpar_contas_anonimizadas` passa a marcar `expurgo_midia_em = privado.agora()` para os registros vinculados ao usuário anonimizado, garantindo que suas fotos sejam destruídas na próxima execução da esteira diária.
- **Retenção do `documento_hmac`:** O `documento_hmac` de contas aprovadas é mantido no registro relacional mesmo após a destruição da mídia com amparo no Art. 11, II, "g" da LGPD (prevenção à fraude e segurança do ecossistema), impedindo que um mesmo documento seja reutilizado para criar contas duplicadas ou contornar banimentos. Em caso de exclusão voluntária da conta (RF25), o HMAC é conservado pelo prazo prescricional de 5 anos para eventual defesa em disputas legais/administrativas, sendo expurgado ao término desse período.
- **Exportação de Dados (`exportar_meus_dados` / RF22):** O histórico relacional de auditoria (`status`, `documento_tipo`, `solicitado_em`, `respondido_em`) integra o JSON de exportação da conta. Mídias temporárias (já expurgadas ou efêmeras) e o hash interno `documento_hmac` não são exportados por consistirem em controles internos de segurança da plataforma.
- **Documento do Estabelecimento:** O comentário de `cadastrar_estabelecimento` (migração `20260924004937`) referente a documentos do titular da casa fica expressamente fora do escopo desta especificação, devendo ser tratado na v1.2 junto à governança de PJ e múltiplos membros.

---

## 4. Deduplicação Criptográfica Segura: Solução Proposta (HMAC vs SHA-256)

O armazenamento do SHA-256 puro do número do documento foi identificado como falha de segurança: como CPFs possuem apenas 11 dígitos numéricos e RGs são igualmente curtos, um atacante com acesso ao banco poderia recuperar os números de todos os documentos em minutos via tabelas arco-íris ou força bruta em GPU.

**Solução Proposta (a criar via migração):**
- O número do documento é normalizado (apenas dígitos).
- O hash é calculado através de **HMAC-SHA256** utilizando um segredo de servidor (*pepper*) de alta entropia armazenado no Supabase Vault (`vault.decrypted_secrets`, conforme padrão proposto no PR #187) ou chave gerenciada de ambiente:
  ```sql
  v_hmac := extensions.hmac(v_documento_limpo, v_pepper_secreto, 'sha256');
  ```
- O valor resultante (`documento_hmac`) permite detecção exata de contas duplicadas sem que ninguém (mesmo com dump do banco) consiga reverter o número do documento original.

---

## 5. Fluxo Operacional e RPCs (Proposta — a criar)

### 5.1 `public.status_minha_verificacao() returns jsonb` (a criar)
- **Permissão:** Usuário autenticado (`authenticated`).
- **Retorno:** `{ "status": text, "motivo": text, "prazo_envio_ate": timestamptz, "selo_ativo": boolean }`.
- Não expõe caminhos de bucket, scores biométricos nem dados criptográficos internos.

### 5.2 `public.iniciar_verificacao_identidade(documento_tipo text) returns jsonb` (a criar)
- **Permissão:** Usuário autenticado (`authenticated`).
- **Validações:**
  - Usuário não pode ter verificação já `aprovada` nem `em_analise`.
  - Tipo de documento válido (`cnh`, `rg`, `cin`).
- **Efeito:**
  - Gera paths únicos e não enumeráveis no Storage: `{usuario_id}/{uuid_verificacao}/{tipo_foto}.jpg`.
  - Gera as 3 URLs assinadas de upload com validade de 2 horas (padrão Supabase Storage).
  - Cria ou atualiza registro em `privado.verificacao_identidade` com status `'pendente'`.
  - Retorna as URLs de upload ao cliente móvel.

### 5.3 `public.confirmar_envio_verificacao(verificacao_id uuid) returns jsonb` (a criar)
- Invocada pelo app após concluir os 3 uploads HTTP no Storage.
- Valida se `prazo_envio_ate > privado.agora()`.
- Altera o status de `'pendente'` para `'em_analise'`, registra `enviado_em = privado.agora()` e agenda `expurgo_midia_em = privado.agora() + interval '15 days'` como salvaguarda preventiva. Notifica a moderação.

### 5.4 Origem da Exigência Formal por Denúncia e Suspensão Preventiva por Inércia
A exigência formal de verificação por suspeita/denúncia não é iniciada pelo próprio usuário, mas pela moderação da plataforma:
1. **`privado.exigir_verificacao(usuario_id uuid, motivo text, prazo_dias int default 7) returns uuid` (Proposta — a criar):**
   - Invocada via `service_role` ou painel interno após apuração de denúncia grave em `public.denunciar`.
   - Insere registro em `privado.verificacao_identidade` com `status = 'pendente'`, `motivo = 'apuracao_denuncia'` e `prazo_envio_ate = privado.agora() + (prazo_dias || ' days')::interval`.
   - Emite notificação ao usuário (`verificacao_exigida`) e e-mail transacional informando sobre o prazo regulamentar para envio das mídias.
2. **Suspensão Preventiva por Inércia:**
   - Caso o usuário receba uma solicitação obrigatória (motivo `apuracao_denuncia`) e não conclua o envio das mídias até `prazo_envio_ate` (7 dias corridos):
   - A rotina de retenção diária detecta o pedido pendente expirado e executa a suspensão preventiva padrão da conta (`usuario.estado = 'suspensa'`).
   - O usuário perde temporariamente o direito de se candidatar ou publicar vagas, mas preserva acesso ao aplicativo para recorrer via `public.contestar_suspensao` ou abrir chamado na Equipe Frila via `public.abrir_suporte` (reaproveitando integralmente os fluxos existentes).

---

## 6. Análise de Custos e Provedores de Mercado

| Abordagem | Custo Estimado | Requisitos de Infraestrutura | Veredito |
|---|---|---|---|
| **A. Moderação Manual Interna** | Custo de equipe operacional + Storage (~US$ 0,021/GB, ref. Supabase Pricing) | Exige desenvolvimento de ferramenta de revisão com autenticação de dois fatores, perfil restrito e trilha de auditoria de visualização (RN15). | **Recomendada para o Piloto DF (v1.1)** sob demanda estrita de denúncias. |
| **B. Provedor Especializado (Unico / CAF / Idwall)** | R$ 1,50 a R$ 3,80 por transação biométrica com liveness (estimativa de mercado) | Integração via Webhook seguro (Edge Function Deno). Enquadramento como Operador LGPD. | **Recomendada a partir da v1.2** para expansão de escala e selo voluntário. |
| **C. OCR Automatizado sem Biometria Viva** | R$ 0,30 a R$ 0,60 por documento (estimativa de mercado) | Extrai dados textuais mas não comprova vivacidade nem autoria da selfie. | Descartada por ineficácia contra falsidade ideológica. |

*Nota: Os custos acima constituem estimativas preliminares baseadas em tabelas de referência de mercado de provedores de identidade digital no Brasil para faixas iniciais de consumo (1.000 a 5.000 validações/mês).*

---

## 7. Questões em Aberto para Decisão do Dono (Registradas em `DECISOES.md`)

1. **Exibição do Selo de Verificação:** Autorizar a inclusão visual do badge "Identidade Verificada" no perfil público de profissionais e no painel do contratante para contas aprovadas voluntariamente?
   - *Recomendação:* Sim, estimula a autorregulação voluntária e aumenta a taxa de conversão sem gerar atrito obrigatório.
2. **Definição do Provedor para a v1.2:** Seleção comercial entre Unico e CAF para homologação de contrato e elaboração do RIPD compartilhado.
