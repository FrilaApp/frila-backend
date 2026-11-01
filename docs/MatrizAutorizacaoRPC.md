# Matriz de Autorização: Papel × RPC

Fonte de verdade e especificação formal da matriz de controle de acesso e autorização das **44 RPCs públicas** do Frila, implementadas no schema `public` e expostas no contrato da API (`contrato/openapi.yaml`).

Esta matriz é comprovada de ponta a ponta pela suíte automatizada pgTAP em [`supabase/tests/786_matriz_autorizacao_papeis_rpc.sql`](../supabase/tests/786_matriz_autorizacao_papeis_rpc.sql) (180 asserções verdes, incluindo testes anti-regressão e mutação de falso positivo).

---

## 1. Princípios e Camadas de Autorização

A autorização no Frila segue o princípio do menor privilégio e opera em defesa em profundidade através de quatro barreiras sucessivas no banco de dados:

```
[ Requisição ]
      │
      ▼
1. Privilégio PostgreSQL (GRANT EXECUTE) ──► Bloqueia anon em 43 RPCs (SQLSTATE 42501)
      │
      ▼
2. Autenticação de Sessão (auth.uid())    ──► Exige JWT válido (401 nao_autenticado)
      │
      ▼
3. Perfil de Conta (privado.exigir_perfil) ──► profissional vs contratante (403 perfil_incompativel)
      │
      ▼
4. Escopo do Recurso (privado.eh_membro)   ──► dono vs terceiro (403 sem_permissao / 404 nao_encontrado)
      │
      ▼
[ Execução da Regra de Negócio ]
```

### 1.1 Os Quatro Papéis Avaliados

1. **`anon` (Anônimo):** Requisições sem token de usuário, identificadas apenas pela chave pública (`anon`).
   - **Regra:** Privilégio `EXECUTE` universalmente revogado do schema `public`, com **uma única exceção contratual**: `public.configuracao_do_app(text)`, necessária para que versões obsoletas do app detectem a obrigatoriedade de atualização antes do login. Todas as outras 43 RPCs são rejeitadas imediatamente no nível do catálogo do PostgreSQL com erro `42501 (insufficient_privilege)`.
2. **`profissional`:** Usuário autenticado com perfil `'profissional'` em `public.usuario` e perfil correspondente em `public.profissional`.
   - Pode executar rotinas do ciclo do trabalhador (candidaturas, check-in, avaliações como profissional, dados do perfil).
   - Ao tentar executar rotinas exclusivas de contratante, recebe `403 perfil_incompativel`.
3. **`outro contratante`:** Usuário autenticado com perfil `'contratante'`, porém sem vínculo de membro ou administração com o estabelecimento ou vaga em questão.
   - Pode cadastrar estabelecimentos e gerenciar os seus próprios estabelecimentos.
   - Ao tentar operar recursos alheios (publicar vaga em outro local, gerenciar equipe alheia, escolher candidatos em vagas alheias), recebe `403 sem_permissao` ou `404 nao_encontrado` (para evitar vazamento de existência de dados sensíveis).
   - Ao tentar executar rotinas exclusivas de profissional, recebe `403 perfil_incompativel`.
4. **`dono`:** Usuário autenticado com perfil `'contratante'`, proprietário ou membro administrador (`papel = 'administrador'`) do estabelecimento responsável pela vaga, posição ou turno.
   - Possui autorização total para publicar, cancelar, selecionar candidatos, confirmar presença e avaliar o profissional naquele recurso.

---

## 2. Matriz Consolidada: Papel × RPC (44 Rotinas)

Legenda de respostas na matriz:
- **`200 OK`**: Autorizado. Requisição executada com sucesso ou validada pela lógica de negócio interna.
- **`401`**: Não autenticado (`nao_autenticado`).
- **`403 PI`**: Perfil incompatível (`403 perfil_incompativel`).
- **`403 SP`**: Sem permissão no recurso / não é membro (`403 sem_permissao`).
- **`404 NE`**: Recurso inexistente ou inacessível a terceiros (`404 nao_encontrado`).
- **`42501`**: Privilégio negado no catálogo PostgreSQL (`permission denied for function`).

| # | RPC Pública | `anon` | `profissional` | `outro contratante` | `dono` | Barreira Principal de Autorização |
|---|---|:---:|:---:|:---:|:---:|---|
| 1 | `configuracao_do_app` | `200 OK` | `200 OK` | `200 OK` | `200 OK` | Pública; única com grant a `anon` |
| 2 | `criar_conta` | `42501` | `200 OK` | `200 OK` | `200 OK` | Exige sessão JWT válida |
| 3 | `minha_conta` | `42501` | `200 OK` | `200 OK` | `200 OK` | Exige sessão JWT; lê conta do chamador |
| 4 | `situacao_da_conta` | `42501` | `200 OK` | `200 OK` | `200 OK` | Exige sessão JWT; lê status da conta |
| 5 | `contestar_suspensao` | `42501` | `200 OK` | `200 OK` | `200 OK` | Ambas as contas (se suspensas) |
| 6 | `registrar_dispositivo` | `42501` | `200 OK` | `200 OK` | `200 OK` | Ambas as contas autenticadas |
| 7 | `remover_dispositivo` | `42501` | `200 OK` | `200 OK` | `200 OK` | Ambas as contas autenticadas |
| 8 | `registrar_evento` | `42501` | `200 OK` | `200 OK` | `200 OK` | Ambas as contas autenticadas |
| 9 | `perfil_publico` | `42501` | `200 OK` | `200 OK` | `200 OK` | Leitura aberta para autenticados sem bloqueio |
| 10 | `bloquear` | `42501` | `200 OK` | `200 OK` | `200 OK` | Profissional bloqueia est; Contratante bloqueia prof |
| 11 | `denunciar` | `42501` | `200 OK` | `200 OK` | `200 OK` | Profissional denuncia est; Contratante denuncia prof |
| 12 | `criar_perfil_profissional` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` |
| 13 | `meu_perfil_profissional` | `42501` | `200 OK` | `404 NE` | `404 NE` | Busca registro em `public.profissional` |
| 14 | `atualizar_perfil_profissional` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` |
| 15 | `criterios_de_notificacao` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` |
| 16 | `pedir_revisao_despacho` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` |
| 17 | `vagas_abertas` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` |
| 18 | `detalhe_vaga` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` |
| 19 | `candidatar` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` |
| 20 | `retirar_candidatura` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` + dono da candidatura |
| 21 | `minhas_candidaturas` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` |
| 22 | `avisar_a_caminho` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` + alocado no turno |
| 23 | `fazer_checkin` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` + alocado no turno |
| 24 | `fazer_checkout` | `42501` | `200 OK` | `403 PI` | `403 PI` | `privado.exigir_perfil('profissional')` + alocado no turno |
| 25 | `cadastrar_estabelecimento` | `42501` | `403 PI` | `200 OK` | `200 OK` | `privado.exigir_perfil('contratante')` |
| 26 | `meus_estabelecimentos` | `42501` | `403 PI` | `200 OK` | `200 OK` | `privado.exigir_perfil('contratante')` |
| 27 | `publicar_vaga` | `42501` | `403 PI` | `403 SP` | `200 OK` | `privado.exigir_perfil('contratante')` + membro do est |
| 28 | `cancelar_vaga` | `42501` | `403 PI` | `404 NE` | `200 OK` | `privado.exigir_perfil('contratante')` + membro do est |
| 29 | `republicar_vaga` | `42501` | `403 PI` | `403 SP` | `200 OK` | `privado.exigir_perfil('contratante')` + membro do est |
| 30 | `republicar_posicoes_restantes` | `42501` | `403 PI` | `403 SP` | `200 OK` | `privado.exigir_perfil('contratante')` + membro do est |
| 31 | `candidatos_da_vaga` | `42501` | `403 PI` | `403 SP` | `200 OK` | `privado.exigir_perfil('contratante')` + membro do est |
| 32 | `escolher_candidato` | `42501` | `403 PI` | `403 SP` | `200 OK` | `privado.exigir_perfil('contratante')` + membro do est |
| 33 | `reabrir_por_atraso` | `42501` | `403 PI` | `403 SP` | `200 OK` | `privado.exigir_perfil('contratante')` + membro do est |
| 34 | `incluir_na_equipe` | `42501` | `403 PI` | `403 SP` | `200 OK` | `privado.exigir_perfil('contratante')` + admin do est |
| 35 | `remover_da_equipe` | `42501` | `403 PI` | `403 SP` | `200 OK` | `privado.exigir_perfil('contratante')` + admin do est |
| 36 | `meu_estabelecimento` | `42501` | `403 SP` | `403 SP` | `200 OK` | `membro_estabelecimento` (admin ou operador) |
| 37 | `painel_estabelecimento` | `42501` | `403 SP` | `403 SP` | `200 OK` | `privado.eh_membro(estabelecimento_id)` |
| 38 | `equipe_de_confianca` | `42501` | `403 SP` | `403 SP` | `200 OK` | `privado.eh_membro(estabelecimento_id)` |
| 39 | `confirmar_checkin_manual` | `42501` | `403 SP` | `403 SP` | `200 OK` | `privado.eh_membro(estabelecimento_id)` da vaga do turno |
| 40 | `meus_turnos` (com `estabelecimento_id`) | `42501` | `403 SP` | `403 SP` | `200 OK` | Com `estabelecimento_id`: `privado.eh_membro` |
| 41 | `contato_do_turno` | `42501` | `200 OK` | `404 NE` | `200 OK` | Profissional do turno OU membro do estabelecimento |
| 42 | `avaliar` | `42501` | `200 OK` | `403 SP` | `200 OK` | Profissional do turno OU membro do estabelecimento |
| 43 | `cancelar_posicao` | `42501` | `200 OK` | `404 NE` | `200 OK` | Profissional da posicao OU membro do estabelecimento |
| 44 | `abrir_suporte` | `42501` | `200 OK` | `404 NE` | `200 OK` | Profissional do turno OU membro do estabelecimento |

---

## 3. Análise Detalhada dos Grupos de RPCs

### 3.1 Rotinas Globais e de Identidade (11 RPCs)
- **`configuracao_do_app`**: Exposta abertamente ao papel `anon`. Permite que qualquer cliente consulte versões suportadas e URLs de download antes da autenticação.
- **`minha_conta`, `situacao_da_conta`, `registrar_dispositivo`, `remover_dispositivo`, `registrar_evento`**: Acessíveis por qualquer usuário autenticado (`profissional` ou `contratante`). Operam sobre os dados do próprio `auth.uid()`.
- **`bloquear`, `denunciar`**: Bidirecionais. O profissional bloqueia/denuncia estabelecimentos; o contratante bloqueia/denuncia profissionais. Alvos cruzados inválidos geram `422 campo_invalido`.
- **`perfil_publico`**: Aberto a qualquer usuário autenticado, contanto que não exista bloqueio mútuo (`404 nao_encontrado`).

### 3.2 Rotinas do Perfil Profissional (13 RPCs)
- Protegidas por `privado.exigir_perfil('profissional')`.
- Qualquer chamada por contas com perfil `contratante` (inclusive o dono do estabelecimento onde a vaga existe) é sumariamente rejeitada com erro `403 perfil_incompativel`.
- Escopo de propriedade:
  - `retirar_candidatura`: Apenas o profissional que submeteu a candidatura pode cancelá-la.
  - `fazer_checkin`, `fazer_checkout`, `avisar_a_caminho`: Exigem que a posição esteja confirmada para o `profissional_id` correspondente ao chamador.

### 3.3 Rotinas do Perfil Contratante (11 RPCs)
- Protegidas por `privado.exigir_perfil('contratante')`.
- Qualquer chamada por contas com perfil `profissional` recebe `403 perfil_incompativel`.
- Escopo de estabelecimento:
  - `cadastrar_estabelecimento` e `meus_estabelecimentos`: Operam globalmente na conta do contratante (um contratante pode ter múltiplos estabelecimentos).
  - `publicar_vaga`, `republicar_vaga`, `republicar_posicoes_restantes`, `candidatos_da_vaga`, `escolher_candidato`, `reabrir_por_atraso`: Exigem que o contratante seja membro do estabelecimento (`privado.eh_membro`). Terceiros recebem `403 sem_permissao`.
  - `cancelar_vaga`: Responde `404 nao_encontrado` a contratantes não membros, resguardando a privacidade da existência da vaga.
  - `incluir_na_equipe`, `remover_da_equipe`: Exigem que o membro possua papel de `administrador` (`privado.eh_administrador`). Operadores e terceiros recebem `403 sem_permissao`.

### 3.4 Rotinas Restritas a Membros do Estabelecimento (4 RPCs)
- `meu_estabelecimento`, `painel_estabelecimento`, `equipe_de_confianca`, `confirmar_checkin_manual`:
  - Não dependem apenas do perfil estático, mas da presença do `usuario_id` na tabela `public.membro_estabelecimento`.
  - Usuários do perfil profissional ou outros contratantes não autorizados recebem `403 sem_permissao`.
  - Em `confirmar_checkin_manual`: O profissional do próprio turno que tentar confirmar seu check-in manual recebe `403 sem_permissao`, pois a presença só pode ser atestada pela casa (RF20).

### 3.5 Rotinas Mistas / Turno e Posição (5 RPCs)
- `meus_turnos`:
  - Se invocado com `estabelecimento_id`: restrito a membros daquele estabelecimento (`403 sem_permissao` para outros contratantes e profissionais não membros).
  - Se invocado sem `estabelecimento_id`: retorna os turnos do profissional autenticado; para contratantes, retorna array vazio `[]` de forma idempotente.
- `contato_do_turno`, `avaliar`, `cancelar_posicao`, `abrir_suporte`:
  - Participação bilateral: acessíveis tanto pelo profissional participante quanto pelos membros do estabelecimento contratante.
  - Para terceiros (`outro contratante` alheio): `contato_do_turno`, `cancelar_posicao` e `abrir_suporte` retornam `404 nao_encontrado` para preservar o sigilo das partes; `avaliar` retorna `403 sem_permissao`.

---

## 4. Prova Automatizada e Reprodutibilidade

A integridade desta matriz é comprovada pelo teste pgTAP:

```bash
# Obter a vaga do banco local pela fila
/Users/cauecarneiro/Documents/Projetos/Frila/orquestracao/scripts/fila.sh pegar banco Martelo

# Executar a suite da matriz de autorizacao
supabase test db supabase/tests/786_matriz_autorizacao_papeis_rpc.sql

# Liberar a vaga da fila
/Users/cauecarneiro/Documents/Projetos/Frila/orquestracao/scripts/fila.sh soltar banco Martelo
```

### 4.1 Isolamento Transacional e Classificador Rigoroso Anti-Falso-Positivo
Para testar chamadas com mutação de estado (como `cancelar_vaga` ou `cancelar_posicao`) sem invalidar os testes subsequentes do mesmo turno/posição dentro de uma única transação, o teste implementa o motor `pg_temp.testar_autorizacao`.

O motor força um rollback pontual via exceção interna `SUCES` em cada chamada autorizada bem-sucedida, assegurando que o estado dos dados permaneça imaculado durante todas as 182 asserções.

Além disso, o classificador do motor valida estritamente a autorização através do envelope oficial PostgREST/PostgreSQL:
- **`AUTORIZADO`**: Exige execução bem-sucedida no caminho permitido (capturada exclusivamente por interceptação de exceção interna `SUCES`).
- **Leitura de Diagnósticos Estrita**: O status HTTP real é extraído de `PG_EXCEPTION_DETAIL` (`GET STACKED DIAGNOSTICS ... PG_EXCEPTION_DETAIL`) conforme o contrato da função `public.erro(status, codigo, motivo)`.
- **`401_NAO_AUTENTICADO`**: Qualquer exceção com status HTTP 401 no `DETAIL` ou código `nao_autenticado` é classificada como recusa de autenticação, sobrepondo qualquer código de regra de negócio.
- **`REGRA:<codigo>`**: Para cenários onde o usuário possui autorização plena mas atinge uma validação de negócio intrínseca à fixture (ex.: `conta_existente`, `sem_suspensao_ativa`, `perfil_ja_existe`, `a_caminho_fora_da_janela`), o teste valida nominalmente o código e exige que o status HTTP seja de negócio (rejeitando sumariamente 401 ou 403).
- **Prova de Morte de Mutante**: O arquivo inclui autotestes de mutação na Seção 6 com o envelope real de `public.erro`, comprovando que tanto erros 401 diretos quanto regras de negócio alteradas artificialmente para emitir status 401 provocam falha imediata dos testes (derrubando 3/3 asserções).
