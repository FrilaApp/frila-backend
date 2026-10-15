# Proposta Técnica: Múltiplos Membros por Estabelecimento com Papéis

**Cartão Trello:** `JpKoxqWo` (v1.2 · Backend + Web + iOS · Múltiplos membros por estabelecimento com papéis)  
**História / Requisitos:** US24 · RF21 · RN15, RN25 · UC10  
**Data:** 15/10/2026 (Revisão 3 — saneamento das pendências apontadas na re-revisão do Claude Code #2)  
**Autor:** Faísca (Backend)  
**Status:** Proposta de arquitetura para a v1.2 (aguarda decisão do dono)

---

## 1. Contexto e Motivação

### 1.1 O Cenário de Negócio
No modelo atual do banco de dados (`supabase/migrations/20260922150200_estabelecimento.sql`), a entidade `public.estabelecimento` **não** possui coluna de proprietário único (`usuario_id`). A associação entre contas e estabelecimentos já é modelada em `public.membro_estabelecimento`, onde o usuário que cadastra a casa é vinculado automaticamente com `papel = 'administrador'` via RPC `public.cadastrar_estabelecimento`.

Na operação real de bares, restaurantes e buffets (especialmente em grandes eventos), gerentes de plantão, maîtres e coordenadores operacionais precisam publicar vagas, aprovar candidaturas e coordenar o check-in sem compartilhar a senha ou o aparelho do proprietário titular.

Esta proposta formaliza a evolução do modelo para suportar:
1. Três papéis hierárquicos: `proprietario`, `administrador` e `operador`.
2. Fluxo assíncrono e seguro de convite por e-mail com token temporário de uso único sem vazamento na fila `pgmq` ou no payload da API (RN15).
3. Salvaguardas estritas contra estabelecimentos órfãos, reaproveitando o código canônico `administrador_unico` (RF25) e ordem de travas contra deadlocks com `excluir_conta`.
4. Cumprimento estrito da RN25 (uma conta, um perfil) com recusa canônica 422 `perfil_incompativel`.

### 1.2 Matriz de Objetos: Existe Hoje × A Criar (Proposta v1.2)

| Objeto | Tipo | Estado | Descrição / Papel |
|---|---|:---:|---|
| `public.membro_estabelecimento` | Tabela | **Existe** | Tabela base de vínculos (`administrador`, `operador`). |
| `public.papel_membro` | Enum | **Existe** | Enum existente `('administrador', 'operador')`. |
| `privado.eh_administrador(uuid)` | Função | **Existe** | Função auxiliar de segurança. |
| `public.excluir_conta()` | RPC | **Existe** | Exclusão de conta com salvaguarda `administrador_unico`. |
| `public.papel_membro ('proprietario')` | Valor de Enum | **A criar** | Novo valor no enum via `alter type ... add value`. |
| `public.convite_membro` | Tabela | **A criar** | Tabela com hash de tokens e controle de expiração de convites. |
| `privado.token_convite_transitorio` | Tabela | **A criar** | Tabela efêmera transitória para envio sem vazamento na fila. |
| `public.convidar_membro(uuid, text, text)` | RPC | **A criar** | Criação de convite e enfileiramento de e-mail. |
| `public.aceitar_convite_membro(text)` | RPC | **A criar** | Validação do token, e-mail e perfil (RN25) e vinculação do membro. |
| `public.remover_membro(uuid, uuid)` | RPC | **A criar** | Remoção de membro com travas estritas e proteção de último gestor. |
| `public.transferir_propriedade(uuid, uuid)` | RPC | **A criar** | Transferência da titularidade legal entre membros. |
| `public.meus_membros(uuid)` | RPC | **A criar** | Listagem de membros e convites pendentes com minimização de dados. |
| `privado.consumir_token_convite(uuid)` | Função | **A criar** | Consumo seguro do token efêmero pela Edge Function `enviar-email`. |
| Handler `processarConviteMembro` | Edge Function | **A criar** | Lógica de montagem e despacho de e-mail na função `enviar-email`. |

---

## 2. Modelo de Dados e Evolução de Esquema

### 2.1 Evolução do Enum `public.papel_membro`
O enum `public.papel_membro` já existe no catálogo com os valores `('administrador', 'operador')`. A evolução adiciona o valor `proprietario`:

```sql
-- Migração 1: Adiciona valor ao enum existente
alter type public.papel_membro add value 'proprietario';
```

> **Nota de Arquitetura PostgreSQL:** No PostgreSQL, valores inseridos via `ALTER TYPE ... ADD VALUE` só podem ser referenciados em comandos DDL/DML em transações subsequentes. A criação de colunas com default ou migrações de dados que utilizem `'proprietario'` deve ocorrer em migração posterior.

### 2.2 Evolução da Tabela `public.membro_estabelecimento`
A tabela `public.membro_estabelecimento` já existe com as colunas essenciais:
- `id uuid primary key default gen_random_uuid()`
- `usuario_id uuid not null`
- `perfil public.perfil_conta not null check (perfil = 'contratante')`
- `estabelecimento_id uuid not null references public.estabelecimento(id)`
- `papel public.papel_membro not null`
- `criado_em timestamptz not null default now()`
- Unicidade: `unique (usuario_id, estabelecimento_id)`
- FK composta: `constraint so_conta_de_contratante foreign key (usuario_id, perfil) references public.usuario (id, perfil)`

A evolução adiciona colunas complementares de auditoria operacional:
```sql
alter table public.membro_estabelecimento
  add column if not exists adicionado_por uuid references public.usuario(id),
  add column if not exists atualizado_em timestamptz not null default privado.agora();
```

> **Heurística de Backfill Proposta (Migração de Dados Posterior):**  
> Para estabelecimentos pré-existentes, propõe-se que em migração posterior à inclusão do valor no enum (respeitando a restrição de transação do PostgreSQL), o administrador com registro mais antigo (`min(criado_em)`) seja promovido a `proprietario`:
```sql
update public.membro_estabelecimento me
   set papel = 'proprietario'
 where me.id in (
   select distinct on (estabelecimento_id) id
     from public.membro_estabelecimento
    where papel = 'administrador'
    order by estabelecimento_id, criado_em asc
 );
```

### 2.3 Tabela de Convites: `public.convite_membro` (Proposta — a criar)
Armazena convites pendentes e controle de ciclo de vida com expiração:
```sql
create table public.convite_membro (
  id                  uuid primary key default gen_random_uuid(),
  estabelecimento_id  uuid not null references public.estabelecimento(id) on delete cascade,
  email               extensions.citext not null,
  papel               public.papel_membro not null default 'operador'
                        check (papel in ('administrador', 'operador')),
  token_hash          text not null unique,
  criado_por          uuid not null references public.usuario(id),
  expira_em           timestamptz not null,
  aceito_em           timestamptz,
  cancelado_em        timestamptz,
  criado_em           timestamptz not null default privado.agora()
);

create index idx_convite_membro_token on public.convite_membro (token_hash)
  where aceito_em is null and cancelado_em is null;
create index idx_convite_membro_est on public.convite_membro (estabelecimento_id);
```

### 2.4 Tabela Transitória para Entrega de E-mail: `privado.token_convite_transitorio` (Proposta — a criar)
Para atender estritamente à RN15 e ao padrão do repositório (onde mensagens enfileiradas em `pgmq.q_email` carregam apenas o identificador da entidade, evitando retenção de segredos em texto puro em `pgmq.a_email`), os tokens em claro para despacho trafegam por tabela efêmera com expurgo diário:

```sql
create table privado.token_convite_transitorio (
  convite_id  uuid primary key references public.convite_membro(id) on delete cascade,
  token       text not null,
  expira_em   timestamptz not null default (privado.agora() + interval '1 hour')
);

revoke all on table privado.token_convite_transitorio from public, anon, authenticated;
grant select, delete on table privado.token_convite_transitorio to service_role;
```

---

## 3. Matriz de Permissões por Papel

| Ação Operacional / Funcionalidade | `proprietario` | `administrador` | `operador` |
|---|:---:|:---:|:---:|
| Publicar vaga / republicar vaga (`publicar_vaga`, `republicar_vaga`) | ✅ | ✅ | ✅ |
| Escolher candidatos no modo seleção (`escolher_candidato`) | ✅ | ✅ | ✅ |
| Visualizar candidatos da vaga (`candidatos_da_vaga`) | ✅ | ✅ | ✅ |
| Cancelar vaga / cancelar posição (`cancelar_vaga`, `cancelar_posicao`) | ✅ | ✅ | ✅ |
| Reabrir posição por atraso de check-in (`reabrir_por_atraso`) | ✅ | ✅ | ✅ |
| Gerenciar Equipe de Confiança (`incluir_na_equipe`, `remover_da_equipe`) | ✅ | ✅ | ❌ |
| Convidar novos membros para o estabelecimento (`convidar_membro`) | ✅ | ✅ | ❌ |
| Cancelar convites pendentes de membros | ✅ | ✅ | ❌ |
| Remover operadores da equipe (`remover_membro`) | ✅ | ✅ | ❌ |
| Remover administradores da equipe (`remover_membro`) | ✅ | ❌ (só a si mesmo se não único) | ❌ |
| Transferir propriedade do estabelecimento (`transferir_propriedade`) | ✅ | ❌ | ❌ |
| Alterar dados cadastrais do estabelecimento *(Futuro / Não implementado no MVP)* | ✅ | ✅ | ❌ |
| Excluir estabelecimento da plataforma *(Futuro / Não implementado no MVP)* | ✅ | ❌ | ❌ |

---

## 4. Novas RPCs e Comportamento (Proposta v1.2 — a criar)

### 4.1 `public.convidar_membro(estabelecimento_id uuid, email text, papel text) returns jsonb` (a criar)
- **Permissão:** `privado.eh_administrador(estabelecimento_id)` (abrange `proprietario` e `administrador`).
- **Validações:**
  1. Solicitante é `proprietario` ou `administrador` do estabelecimento.
  2. Teto de membros ativos: proposta de até 10 membros ativos somados aos convites pendentes (sujeito à decisão do dono do produto; ver DECISOES.md e §9). Se excedido, recusa com **422 `limite_membros_atingido`**.
  3. Papel requisitado restrito a `administrador` ou `operador` (ninguém pode convidar diretamente como `proprietario`). Recusa com **422 `papel_invalido`**.
  4. E-mail fornecido não pode ser de membro já ativo no estabelecimento. Se já for membro, recusa com **409 `membro_ja_cadastrado`**.
  5. Se já houver convite pendente para o mesmo e-mail no mesmo estabelecimento, invalida o convite anterior (`cancelado_em = privado.agora()`) e gera o novo.
- **Comportamento e Fluxo de Envio:**
  - Gera token criptográfico de 32 bytes (64 caracteres hexadecimais em memória).
  - Insere registro em `public.convite_membro` com `token_hash = digest(token, 'sha256')` e expiração de 7 dias (`privado.agora() + interval '7 days'`).
  - Insere o token em `privado.token_convite_transitorio` com validade de 1 hora.
  - Enfileira `{ "tipo": "convite_membro", "convite_id": v_convite.id }` em `pgmq.q_email`.
  - Retorna `jsonb` contendo `{ "convite_id": v_convite.id, "expira_em": v_convite.expira_em }`. Em conformidade estrita com a RN15 e segurança operacional, o token em claro **não** é devolvido no payload de resposta da RPC (prevenindo vazamento em logs de PostgREST, proxies reversos e clientes móveis); a entrega é efetuada exclusivamente por e-mail transacional ao destinatário.

### 4.2 `public.aceitar_convite_membro(token text) returns jsonb` (a criar)
- **Permissão:** Usuário autenticado (`authenticated`).
- **Validações:**
  1. Hash do token confere com convite pendente (`aceito_em is null and cancelado_em is null and expira_em > privado.agora()`). Se não encontrado ou expirado, recusa com **404 `convite_invalido`**.
  2. **RN25 (Uma conta, um perfil):** O usuário autenticado DEVE ter perfil `contratante` em `public.usuario`. Se a conta for de `profissional`, a RPC recusa determinística e canonicamente com **422 `perfil_incompativel`**.
  3. **Validação Estrita de E-mail (Segurança do Portador):** O e-mail cadastrado na conta contratante autenticada (`usuario.email`) deve ser **estritamente idêntico** ao e-mail registrado no convite (`convite.email`). Se diferir, recusa com **403 `email_incompativel`**, impedindo apropriação indevida de convites por terceiros.
- **Efeito:**
  - Adquire lock do estabelecimento via `select id from public.estabelecimento where id = v_convite.estabelecimento_id for update`.
  - Valida se o teto de 10 membros não foi atingido por corridas concorrentes.
  - Insere o vínculo em `public.membro_estabelecimento (usuario_id, perfil, estabelecimento_id, papel, adicionado_por)`.
  - Atualiza o convite: `aceito_em = privado.agora()`.
  - Expurga linha de `privado.token_convite_transitorio`.
  - Retorna `{ "estabelecimento_id": "...", "papel": "..." }`.

### 4.3 `public.remover_membro(estabelecimento_id uuid, usuario_id uuid) returns jsonb` (a criar)
- **Permissão:** `proprietario` ou `administrador`.
- **Regras de Travamento e Salvaguarda:**
  - Ordem estrita de travas (evitando deadlocks com `excluir_conta`): adquire lock do estabelecimento antes de inspecionar ou alterar os membros:
    ```sql
    perform 1 from public.estabelecimento where id = estabelecimento_id for update;
    ```
  - O `administrador` **não** pode remover o `proprietario` nem outro `administrador` (apenas a si próprio ou a `operador`). Recusa com **403 `sem_permissao`**.
  - O `proprietario` não pode remover a si mesmo se houver outros membros no estabelecimento (`count(*) > 1`), devendo transferir a titularidade antes (`transferir_propriedade`).
  - **Salvaguarda do Último Gestor:** Se a remoção for do próprio solicitante ou de outro membro e deixar o estabelecimento com zero membros com papel em `('proprietario', 'administrador')` enquanto ainda existirem outros membros na casa (`count(*) > 1`), recusa com o código canônico consagrado **409 `administrador_unico`** (RF25, alinhado à RPC `excluir_conta`).
- **Efeito:** Deleta o registro em `public.membro_estabelecimento`.

### 4.4 `public.transferir_propriedade(estabelecimento_id uuid, novo_proprietario_id uuid) returns jsonb` (a criar)
- **Permissão:** Exclusiva do atual `proprietario` do estabelecimento.
- **Validações e Efeito:**
  - Adquire lock do estabelecimento `for update`.
  - Valida se `novo_proprietario_id` é membro ativo do estabelecimento com perfil `contratante`.
  - Em transação atômica:
    - O novo membro recebe `papel = 'proprietario'`.
    - O antigo titular passa a ter `papel = 'administrador'`.

### 4.5 `public.meus_membros(estabelecimento_id uuid) returns jsonb` (a criar)
- **Permissão:** Qualquer membro ativo do estabelecimento (`privado.eh_membro(estabelecimento_id)`).
- **Minimização de Dados (RN15):**
  - Para `operador`: retorna lista de membros com `usuario_id`, `nome`, `papel` e `criado_em`. O campo `email` é retornado **nulo**, e a lista de convites pendentes não é exposta.
  - Para `administrador` e `proprietario`: retorna lista de membros com `email`, e lista de convites pendentes (`id`, `email`, `papel`, `criado_em`, `expira_em`).

---

## 5. Inventário de Impactos no Código Existente (`papel = 'administrador'`)

Atualmente, diversas migrações testam a igualdade literal `papel = 'administrador'`. Para a introdução segura do papel `proprietario`, cada ponto foi inventariado:

1. **`privado.eh_administrador(estab uuid)` (`supabase/migrations/20260922200000_auxiliares_e_relogio.sql:80-86`):**
   - Atualizar a verificação:
     ```sql
     select exists (select 1 from public.membro_estabelecimento m
                     where m.estabelecimento_id = estab
                       and m.usuario_id = auth.uid()
                       and m.papel in ('administrador', 'proprietario'))
     ```
   - Isso garante imediatamente que o `proprietario` tenha plenos poderes sobre a Equipe de Confiança (`incluir_na_equipe`, `remover_da_equipe` em `20260929210000_equipe_de_confianca.sql`) sem mexer em cada RPC.
2. **`public.excluir_conta` (`supabase/migrations/20261002090000_ordem_de_travas_excluir_conta.sql`):**
   - **Ordem de Travamento e Prevenção de Deadlocks:** Atualmente `excluir_conta` trava vagas e usuário, sem travar estabelecimentos. Para eliminar corridas onde dois administradores se removem simultaneamente ou um é removido enquanto exclui a conta (deixando a casa órfã), `excluir_conta` deve adotar a ordem canônica:
     1º `estabelecimento` (dos estabelecimentos do usuário, ordenados por `id for update`);
     2º `vaga` (ordenadas por `id for update`);
     3º `usuario` (`for update`).
     Compartilhando a trava em `estabelecimento ... for update` com `remover_membro`, `aceitar_convite_membro` e `transferir_propriedade`, garante-se serialização mútua estrita.
   - **Preservação da Condição de Membros Múltiplos (`count(*) > 1`):** A checagem de conflito só dispara quando o usuário for o único gestor remanescente **e houver outros membros na casa**:
     ```sql
     if exists (
       select 1
         from public.membro_estabelecimento m
        where m.usuario_id = v_uid
          and m.papel in ('proprietario', 'administrador')
          and (select count(*) from public.membro_estabelecimento x
                where x.estabelecimento_id = m.estabelecimento_id) > 1
          and (select count(*) from public.membro_estabelecimento x
                where x.estabelecimento_id = m.estabelecimento_id
                  and x.papel in ('proprietario', 'administrador')) = 1
     ) then
       perform public.erro(409, 'administrador_unico');
     end if;
     ```
   - **Proteção do Titular (`proprietario`):** Se o usuário a excluir for `proprietario` e houver outros membros no estabelecimento, a exclusão é igualmente impedida até que a titularidade seja voluntariamente transferida (`transferir_propriedade`) ou os demais membros removidos.
3. **`public.publicar_vaga` (`supabase/migrations/20260924160000_publicar_vaga.sql:52-62`):**
   - A escolha de fallback de responsável local deve priorizar o proprietário e administradores:
     ```sql
     order by (m.papel = 'proprietario') desc, (m.papel = 'administrador') desc, m.usuario_id
     ```
4. **`public.views_funil_piloto` (`supabase/migrations/20260930150000_views_funil_piloto.sql:230`):**
   - Ajustar filtro de membros gestores para `and me.papel in ('proprietario', 'administrador')`.

---

## 6. Integração com Fila de E-mail e Retenção LGPD

### 6.1 Despacho via Edge Function `enviar-email`
1. A RPC `convidar_membro` enfileira mensagem na fila `pgmq.q_email`:
   ```json
   {
     "tipo": "convite_membro",
     "convite_id": "00000000-0000-0000-0000-000000000000"
   }
   ```
2. A Edge Function `supabase/functions/enviar-email/index.ts` adiciona um handler específico `processarConviteMembro (a criar)`:
   - Executa RPC interna via `service_role` (`privado.consumir_token_convite(convite_id)` — a criar), que faz um `SELECT ... FOR UPDATE` em `privado.token_convite_transitorio` e apaga a linha imediatamente (`DELETE`), recuperando o token em memória.
   - Monta o modelo de e-mail com link de convite contendo o token como parâmetro de URL (`https://frila.app/convite?token=...`).
   - Dispara via servidor SMTP configurado no ambiente (`SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS` conforme `.env.exemplo`).
   - O segredo nunca fica persistido no histórico de mensagens arquivadas (`pgmq.a_email`).

### 6.2 Expurgos em `privado.higienizar_tabelas()`
A rotina de higienização existente (`supabase/migrations/20260929174512_emails_transacionais.sql:361`) é executada diariamente pela rotina de retenção (`executar_retencao_diaria`, invocada a cada 24 horas pela Edge Function `limpar-contas-orfas`).
Ela passa a realizar a limpeza periódica de convites antigos:
```sql
-- 4. Convites expirados ou cancelados com mais de 30 dias (a criar)
delete from public.convite_membro
 where (expira_em < privado.agora() - interval '30 days')
    or (cancelado_em is not null and cancelado_em < privado.agora() - interval '30 days');

-- 5. Tokens transitórios não consumidos com mais de 1 hora (a criar)
delete from privado.token_convite_transitorio
 where expira_em < privado.agora();
```
> **Nota de Retenção e WAL:** Como `higienizar_tabelas()` roda na rotina diária (a cada 24h), tokens não consumidos podem permanecer fisicamente na tabela transitória e nos registros de WAL/backup por até 24 horas após sua expiração de 1 hora.

---

## 7. Regras de Negócio e Rastreabilidade

1. **RN25 (Uma conta, um perfil):**
   - Contas de profissionais não podem acumular papéis em estabelecimentos. A barreira física é garantida pela FK composta `so_conta_de_contratante` na tabela `membro_estabelecimento`.
   - A RPC `aceitar_convite_membro` valida a barreira no início da execução e recusa com **422 `perfil_incompativel`**.
2. **Auditoria de Autoria Operacional:**
   - Na tabela `public.vaga`, a autoria é expressa pela coluna `publicado_por` (apontando para o `auth.uid()` do membro que executou a publicação).
   - Na tabela `public.ocorrencia`, a autoria é expressa por `autor_id`.
   - A tabela `public.candidatura` pertence estritamente ao profissional candidato (`profissional_id`) e não possui autor institucional.
   - Qualquer membro do estabelecimento (`proprietario`, `administrador` ou `operador`) que publicar vaga terá seu `auth.uid()` gravado em `vaga.publicado_por`, mantendo auditoria perene de quem abriu o turno.

---

## 8. Governança do Contrato OpenAPI

A inclusão dos novos endpoints segue a diretriz **contract-first** em `FrilaApp/frila-docs` (hoje na versão 0.2.41):
1. Novas operações:
   - `POST /rpc/convidar_membro` (tag `Estabelecimento`)
   - `POST /rpc/aceitar_convite_membro` (tag `Estabelecimento`)
   - `POST /rpc/remover_membro` (tag `Estabelecimento`)
   - `POST /rpc/transferir_propriedade` (tag `Estabelecimento`)
   - `GET /rpc/meus_membros` (tag `Estabelecimento`)
2. Erros canônicos adicionados ao contrato:
   - `403 sem_permissao`
   - `403 email_incompativel`
   - `404 convite_invalido`
   - `409 membro_ja_cadastrado`
   - `409 administrador_unico`
   - `422 perfil_incompativel`
   - `422 papel_invalido`
   - `422 limite_membros_atingido`
