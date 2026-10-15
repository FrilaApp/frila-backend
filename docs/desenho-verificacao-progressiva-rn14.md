# Desenho Técnico: Verificação Progressiva de Identidade (RN14)

**Cartão Trello:** `GtWr3ZeJ` (v1.1 · Produto + Backend · Verificação progressiva de identidade (RN14): desenho)  
**História / Requisitos:** RN14, RN15 · RF02, RF03, RF25 · LGPD (Art. 5º, II; Art. 11, I e II, "g"; Art. 38)  
**Data:** 15/10/2026 (Revisão 2 — saneamento das pendências apontadas pelo Claude Code #2)  
**Autor:** Faísca (Backend)  
**Status:** Desenho técnico de arquitetura para a v1.1/v1.2 (aguarda decisão do dono)

---

## 1. Princípio Fundamental de Produto e Bases Legais da LGPD

### 1.1 O Princípio da RN14 (Onboarding sem Barreiras)
A verificação de identidade no Frila **nunca é barreira de entrada** no cadastro inicial nem pré-requisito para disputar e realizar o primeiro turno. O onboarding inicial de profissionais e contratantes deve permanecer leve, ágil e focado na verificação de posse do telefone (OTP) e aceite dos termos.

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

---

## 2. Modelo de Dados

### 2.1 Enum de Status de Verificação
```sql
create type public.status_verificacao as enum (
  'nao_exigida',  -- Estado padrão inicial (cadastro leve sem atrito)
  'pendente',     -- Exigência disparada; aguarda envio das mídias pelo usuário
  'em_analise',   -- Mídias enviadas; aguardando decisão do provedor/moderação
  'aprovada',     -- Identidade confirmada; concede o selo visual
  'rejeitada'     -- Documento ilegível, divergente ou vencido
);
```

### 2.2 Tabela `privado.verificacao_identidade`
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

### 3.1 Provisionamento do Supabase Storage
Atualmente, o projeto `frila-backend` opera sem buckets de Storage (como explicitado em `exportar_meus_dados`). Para a RN14, é provisionado:
- **Bucket Privado:** `documentos-identidade` com acesso público (`public = false`) completamente desabilitado.
- **Upload via URLs Assinadas:** O backend gera URLs efêmeras via `supabase.storage.from('documentos-identidade').createSignedUploadUrl(path)` com validade máxima de 30 minutos a 1 hora.
- **Acesso:** Leitura permitida exclusivamente para o backend (`service_role`). Nenhum usuário possui permissão direta de leitura (`select`) via RLS no Storage.

### 3.2 Purga Real de Arquivos via Edge Function
Diferente das tabelas do Postgres gerenciadas via SQL por `privado.higienizar_tabelas()`, arquivos do Storage só podem ser excluídos de forma confiável através da API REST do Supabase Storage (`service_role`).

O expurgo segue o padrão consolidado da Edge Function `limpar-contas-orfas` (rotina diária de retenção):
1. **Passo Diário na Edge Function de Retenção:**
   - Invoca a RPC interna `privado.listar_verificacoes_para_expurgo()`, que busca registros onde `expurgo_midia_em <= privado.agora()` e com caminhos de arquivo não nulos.
   - Para cada lote, executa `storage.from('documentos-identidade').remove([storage_path_frente, storage_path_verso, storage_path_selfie])`.
   - Após a confirmação formal da deleção pela API do Storage, a função invoca `privado.confirmar_expurgo_verificacao(id)`, que limpa as colunas `storage_path_*` e o `biometria_score` no banco de dados.
2. **Definição dos Prazos de Expurgo:**
   - **Caso Concluído (`aprovada` ou `rejeitada`):** `expurgo_midia_em = respondido_em + interval '30 days'`.
   - **Caso Expirado por Inércia (`pendente` sem envio):** O pedido expira em `prazo_envio_ate` (7 dias). Caso tenha havido upload parcial de alguma imagem, a purga é agendada para 24 horas após a expiração.

### 3.3 Tratamento de Exclusão de Conta (RF25 / LGPD)
O Frila utiliza anonimização de conta em duas etapas: exclusão lógica imediata e purga física em 15 dias (`privado.limpar_contas_anonimizadas(15)`).
- Como as contas não sofrem `DELETE` imediato (permanecem em `anonimizado_em`), o `ON DELETE CASCADE` relacional não é suficiente.
- A função `privado.limpar_contas_anonimizadas` passa a marcar `expurgo_midia_em = privado.agora()` para os registros vinculados ao usuário anonimizado, garantindo que suas fotos sejam destruídas na próxima execução da esteira diária e que o registro relacional tenha seu `documento_hmac` limpo.

---

## 4. Deduplicação Criptográfica Segura (HMAC vs SHA-256)

O armazenamento do SHA-256 puro do número do documento foi identificado como falha de segurança: como CPFs possuem apenas 11 dígitos numéricos e RGs são igualmente curtos, um atacante com acesso ao banco poderia recuperar os números de todos os documentos em minutos via tabelas arco-íris ou força bruta em GPU.

**Solução Adotada:**
- O número do documento é normalizado (apenas dígitos).
- O hash é calculado através de **HMAC-SHA256** utilizando um segredo de servidor (*pepper*) de alta entropia armazenado no Supabase Vault (`vault.decrypted_secrets`):
  ```sql
  v_hmac := extensions.hmac(v_documento_limpo, v_pepper_secreto, 'sha256');
  ```
- O valor resultante (`documento_hmac`) permite detecção exata de contas duplicadas sem que ninguém (mesmo com dump do banco) consiga reverter o número do documento original.

---

## 5. Fluxo Operacional e RPCs

### 5.1 `public.status_minha_verificacao() returns jsonb`
- **Permissão:** Usuário autenticado (`authenticated`).
- **Retorno:** `{ "status": text, "motivo": text, "prazo_envio_ate": timestamptz, "selo_ativo": boolean }`.
- Não expõe caminhos de bucket, scores biométricos nem dados criptográficos internos.

### 5.2 `public.iniciar_verificacao_identidade(documento_tipo text) returns jsonb`
- **Permissão:** Usuário autenticado (`authenticated`).
- **Validações:**
  - Usuário não pode ter verificação já `aprovada` nem `em_analise`.
  - Tipo de documento válido (`cnh`, `rg`, `cin`).
- **Efeito:**
  - Gera paths únicos e não enumeráveis no Storage: `{usuario_id}/{uuid_verificacao}/{tipo_foto}.jpg`.
  - Gera as 3 URLs assinadas de upload com validade de 30 minutos.
  - Cria registro em `privado.verificacao_identidade` com status `'pendente'`.
  - Retorna as URLs de upload ao cliente móvel.

### 5.3 `public.confirmar_envio_verificacao(verificacao_id uuid) returns jsonb`
- Invocada pelo app após concluir os 3 uploads HTTP no Storage.
- Altera o status de `'pendente'` para `'em_analise'` e notifica o provedor/equipe.

### 5.4 Suspensão Preventiva por Inércia
Caso o usuário receba uma solicitação obrigatória (motivo `apuracao_denuncia`) e não conclua o envio das mídias até `prazo_envio_ate` (7 dias corridos):
- O sistema executa a suspensão preventiva padrão da conta (`usuario.estado = 'suspensa'`).
- O usuário perde temporariamente o direito de se candidatar ou publicar vagas, mas preserva acesso ao aplicativo para recorrer via `public.contestar_suspensao` ou abrir chamado na Equipe Frila via `public.abrir_suporte` (sem inventar estados de exceção fora da arquitetura).

---

## 6. Análise de Custos e Provedores de Mercado

| Abordagem | Custo Estimado | Requisitos de Infraestrutura | Veredito |
|---|---|---|---|
| **A. Moderação Manual Interna** | Custo de equipe operacional + R$ 0,05/GB Storage | Exige desenvolvimento de ferramenta de revisão com autenticação de dois fatores, perfil restrito e trilha de auditoria de visualização (RN15). | **Recomendada para o Piloto DF (v1.1)** sob demanda estrita de denúncias. |
| **B. Provedor Especializado (Unico / CAF / Idwall)** | R$ 1,50 a R$ 3,80 por transação biométrica com liveness | Integração via Webhook seguro (Edge Function Deno). Enquadramento como Operador LGPD. | **Recomendada a partir da v1.2** para expansão de escala e selo voluntário. |
| **C. OCR Automatizado sem Biometria Viva** | R$ 0,30 a R$ 0,60 por documento | Extrai dados textuais mas não comprova vivacidade nem autoria da selfie. | Descartada por ineficácia contra falsidade ideológica. |

*Nota: Os custos acima constituem estimativas preliminares baseadas em tabelas de referência de mercado de provedores de identidade digital no Brasil para faixas iniciais de consumo (1.000 a 5.000 validações/mês).*

---

## 7. Questões em Aberto para Decisão do Dono (Registradas em `DECISOES.md`)

1. **Exibição do Selo de Verificação:** Autorizar a inclusão visual do badge "Identidade Verificada" no perfil público de profissionais e no painel do contratante para contas aprovadas voluntariamente?
   - *Recomendação:* Sim, estimula a autorregulação voluntária e aumenta a taxa de conversão sem gerar atrito obrigatório.
2. **Definição do Provedor para a v1.2:** Seleção comercial entre Unico e CAF para homologação de contrato e elaboração do RIPD compartilhado.
