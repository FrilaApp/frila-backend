# Proposta Técnica: Múltiplos Membros por Estabelecimento com Papéis

**Cartão Trello:** `JpKoxqWo` (v1.2 · Backend + Web + iOS · Múltiplos membros por estabelecimento com papéis)  
**História / Requisitos:** US24 · RF21 · RN15, RN25 · UC10  
**Data:** 15/10/2026  
**Autor:** Faísca (Backend)  
**Status:** Proposta de arquitetura para a v1.2 (aguarda decisão do dono)

---

## 1. Contexto e Motivação

Atualmente, cada estabelecimento (`public.estabelecimento`) possui um único proprietário identificado por `usuario_id` (1:1). Na operação real de bares, restaurantes e buffets (especialmente em grandes eventos), gerentes de plantão, maîtres e coordenadores operacionais precisam publicar vagas, aprovar candidaturas e coordenar o check-in sem compartilhar a senha ou o aparelho do proprietário titular.

Esta proposta define o modelo de colaboração multi-usuário com segregação de papéis (`administrador` vs `operador`), fluxo de convites por e-mail com token criptográfico e conformidade rigorosa com a RN25 (perfil incompatível) e RN15 (privacidade de dados pessoais).

---

## 2. Modelo de Dados

### 2.1 Enum de Papéis
```sql
create type public.papel_membro as enum (
  'proprietario',    -- Titular cadastral legal do CNPJ/estabelecimento
  'administrador',   -- Pode gerenciar membros, faturamento e vagas
  'operador'         -- Pode publicar vagas, escolher candidatos e gerenciar turnos
);
```

### 2.2 Tabela `public.membro_estabelecimento`
Associação efetiva de usuários contratantes ao estabelecimento:
```sql
create table public.membro_estabelecimento (
  id                  uuid primary key default gen_random_uuid(),
  estabelecimento_id  uuid not null references public.estabelecimento(id) on delete cascade,
  usuario_id          uuid not null references public.usuario(id) on delete cascade,
  papel               public.papel_membro not null default 'operador',
  adicionado_por      uuid not null references public.usuario(id),
  criado_em           timestamptz not null default privado.agora(),
  atualizado_em       timestamptz not null default privado.agora(),
  constraint membro_estabelecimento_unicidade unique (estabelecimento_id, usuario_id)
);

create index idx_membro_estabelecimento_usuario on public.membro_estabelecimento (usuario_id);
create index idx_membro_estabelecimento_est on public.membro_estabelecimento (estabelecimento_id);
```

### 2.3 Tabela `public.convite_membro`
Controle de convites pendentes e tokens de aceite:
```sql
create table public.convite_membro (
  id                  uuid primary key default gen_random_uuid(),
  estabelecimento_id  uuid not null references public.estabelecimento(id) on delete cascade,
  email               citext not null,
  papel               public.papel_membro not null default 'operador',
  token_hash          text not null unique,
  criado_por          uuid not null references public.usuario(id),
  expira_em           timestamptz not null,
  aceito_em           timestamptz,
  cancelado_em        timestamptz,
  criado_em           timestamptz not null default privado.agora()
);

create index idx_convite_membro_token on public.convite_membro (token_hash) where aceito_em is null and cancelado_em is null;
create index idx_convite_membro_est on public.convite_membro (estabelecimento_id);
```

---

## 3. Novas RPCs

### 3.1 `public.convidar_membro(p_estabelecimento_id uuid, p_email text, p_papel text)`
- **Permissão:** Apenas `proprietario` ou `administrador` do estabelecimento.
- **Validações:**
  1. Estabelecimento ativo e solicitante com papel administrativo.
  2. E-mail válido e não pertencente a membro já ativo no estabelecimento.
  3. Papel requisitado restrito a `administrador` ou `operador` (ninguém pode convidar como `proprietario`).
- **Comportamento:**
  - Gera token criptográfico seguro de 32 bytes (armazenando apenas o hash SHA-256 no banco).
  - Define validade de 7 dias (`privado.agora() + interval '7 days'`).
  - Enfileira disparo de e-mail transacional via `pgmq.q_email` (Edge Function `enviar-email`, template `convite_membro`).
  - Retorna `{ "sucesso": true, "convite_id": "...", "expira_em": "..." }`.

### 3.2 `public.aceitar_convite_membro(p_token text)`
- **Permissão:** Usuário autenticado (`authenticated`).
- **Validações Críticas (RN25):**
  1. O usuário que está aceitando **deve** ter perfil `contratante`. Se `perfil = 'profissional'`, a RPC aborta com código HTTP 422 e erro canônico `perfil_incompativel` (RN25: "Conta de profissional não aceita convite de equipe").
  2. Valida hash do token, expiração e status pendente (`aceito_em is null and cancelado_em is null`).
  3. Se o e-mail do usuário autenticado diferir do e-mail do convite, exige confirmação explícita ou valida vinculação segura.
- **Efeito:**
  - Insere registro em `public.membro_estabelecimento`.
  - Marca `convite_membro.aceito_em = privado.agora()`.
  - Retorna `{ "estabelecimento_id": "...", "papel": "..." }`.

### 3.3 `public.remover_membro(p_estabelecimento_id uuid, p_usuario_id uuid)`
- **Permissão:** Apenas `proprietario` ou `administrador`. O `administrador` não pode remover o `proprietario`.
- **Salvaguardas de Último Administrador:**
  - Não é permitido que o único administrador/proprietário ativo se remova do estabelecimento, evitando estabelecimentos órfãos sem gestão.
- **Efeito:**
  - Remove o vínculo em `public.membro_estabelecimento`.
  - Revoga imediatamente o acesso em todas as views e RPCs protegidas por RLS.
  - Histórico de turnos cumpridos e vagas criadas por esse membro no passado permanece preservado integralmente.

### 3.4 `public.transferir_propriedade(p_estabelecimento_id uuid, p_novo_proprietario_id uuid)`
- **Permissão:** Exclusiva do atual `proprietario`.
- **Efeito:**
  - Transfere o papel de `proprietario` para outro membro ativo com perfil de contratante.
  - O antigo proprietário é rebaixado a `administrador`.

### 3.5 `public.meus_membros(p_estabelecimento_id uuid)`
- Retorna lista de membros ativos, papéis e convites pendentes para exibição nas telas de equipe (iOS e Web).

---

## 4. Regras de Negócio e LGPD

1. **RN25 (Segregação de Perfis):**
   - Profissionais não podem se tornar membros de estabelecimentos nem acumular papéis operacionais na mesma conta.
   - Tentativas de aceite por contas profissionais disparam recusa contratual determinística 422 `perfil_incompativel`.
2. **RN15 (Minimização e Dados Pessoais):**
   - O e-mail do convidado fica em `convite_membro` exclusivamente para envio e verificação. Após o aceite ou cancelamento/expiração, os dados entram na esteira de retenção/purga de `privado.higienizar_tabelas()`.
   - Nenhuma tabela de log técnico (`ocorrencia`, `falha_execucao`) pode armazenar o e-mail do convite.
3. **Auditoria de Ações Operacionais:**
   - As tabelas operacionais (`vaga`, `candidatura`, `ocorrencia`) já registram `criado_por` / `publicado_por` apontando para o `auth.uid()` do membro executor, mantendo a rastreabilidade exata de quem aprovou ou cancelou um turno.

---

## 5. Riscos e Mitigações

| Risco | Severidade | Mitigação |
|---|---|---|
| **Estabelecimento órfão (remoção de todos admins)** | Crítica | Trava lógica na RPC `remover_membro` impedindo remover a si próprio se for o último administrador/proprietário ativo. |
| **Ataque de enumeração de tokens de convite** | Média | Armazenamento do hash SHA-256 do token (não o valor em texto puro); expiração curta de 7 dias e invalidação pós-aceite. |
| **Quebra de RLS existente** | Alta | Migração de transição: atualizar as políticas de RLS de `vaga`, `posicao`, `candidatura` para verificar `exists (select 1 from public.membro_estabelecimento m where m.estabelecimento_id = ... and m.usuario_id = auth.uid())` mantendo retrocompatibilidade com `estabelecimento.usuario_id`. |

---

## 6. Perguntas em Aberto para o Dono (Registradas em `DECISOES.md`)

1. **Titularidade Legal vs Papel Operacional:**
   - O proprietário cadastral (titular do CNPJ) pode ser removido da gestão ou deve ter assento permanente irrevogável enquanto figurar no cadastro oficial?
   - *Recomendação:* O `proprietario` é imune a remoção por outros administradores e só transfere seu posto por ação voluntária própria.
2. **Teto de Membros por Estabelecimento:**
   - Deve haver um limite máximo de membros simultâneos (ex: 5 no plano gratuito, ilimitado em planos corporativos)?
   - *Recomendação:* Fixar teto inicial de 10 membros ativos por estabelecimento para evitar abusos na v1.2.
3. **Prazo de Expiração do Convite:**
   - 7 dias corridos com opção de reenvio manual?
   - *Recomendação:* 7 dias com botão de "Reenviar convite" no painel.
