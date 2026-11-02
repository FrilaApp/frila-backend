# Auditoria de Idempotência, Tratamento de Erros e Resiliência das RPCs Públicas

Este documento apresenta a auditoria técnica exaustiva do catálogo de **44 RPCs públicas** do Frila Backend (API v0.2.46, schema `public`), detalhando o padrão de tratamento de exceções PostgREST, o envelope padronizado de erro, as garantias de idempotência sob chamadas repetidas ou falhas de rede e as proteções contra corridas concorrentes (race conditions).

Complementa a matriz formal de autorização e controle de acesso descrita em [`docs/MatrizAutorizacaoRPC.md`](./MatrizAutorizacaoRPC.md).

---

## 1. Padrão Arquitetural de Tratamento de Erros

No Frila, a totalidade das regras de negócio de escrita é executada em funções PostgreSQL com privilégio `SECURITY DEFINER` e `SET search_path = ''`. O cliente HTTP se comunica via PostgREST na rota `POST /rest/v1/rpc/<nome_da_rpc>` (ou `GET` para consultas de leitura).

### 1.1 O Envelope PostgREST Canônico

Para garantir que o PostgREST traduza adequadamente as exceções de negócio em códigos de status HTTP corretos (4xx), as rotinas utilizam a convenção de interceptação via SQLSTATE `'PGRST'`:

```sql
raise sqlstate 'PGRST' using
  message = json_build_object(
    'code', codigo,            -- Código estável em snake_case (ex: 'vaga_encerrada')
    'message', codigo,         -- Texto técnico para fins de log estruturado (nunca vai à UI)
    'details', motivo,         -- Motivo complementar estável (ex: 'turno_sobreposto')
    'hint', null
  )::text,
  detail = json_build_object(
    'status', status,          -- Status HTTP canônico (ex: 401, 403, 404, 409, 422)
    'headers', json_build_object() -- OBRIGATÓRIO: sem esta chave o PostgREST emite 500 PGRST121
  )::text;
```

> [!IMPORTANT]
> A presença da chave `'headers', json_build_object()` no campo `detail` é um requisito estrito da arquitetura. Sem ela, o PostgREST não consegue montar os cabeçalhos de resposta HTTP e aborta com erro interno `500 PGRST121`, mascarando recusas legítimas de regra de negócio como falhas de infraestrutura.

### 1.2 Catálogo Padronizado de Códigos HTTP de Recusa

| HTTP Status | Semântica Arquitetural | Códigos Canônicos de Negócio (`code`) |
|---|---|---|
| **401 Unauthorized** | Falha de autenticação ou sessão inválida | `nao_autenticado`, `PGRST301` |
| **403 Forbidden** | Autenticado, mas sem papel ou permissão no recurso | `sem_permissao`, `contato_expirado` |
| **404 Not Found** | Recurso inexistente ou isolamento de privacidade | `nao_encontrado` |
| **409 Conflict** | Conflito de estado ou duplicidade cadastral | `candidatura_indisponivel`, `avaliacao_ja_registrada`, `conta_existente`, `documento_ja_cadastrado`, `administrador_unico`, `perfil_ja_existe`, `contestacao_ja_aberta` |
| **422 Unprocessable Entity** | Violação de regra de negócio ou formato inválido | `campo_obrigatorio`, `campo_invalido`, `intervalo_maximo_excedido`, `menor_de_idade`, `perfil_incompativel`, `selecao_sem_antecedencia`, `republicacao_indisponivel`, `vaga_oculta`, `horario_invalido`, `inelegivel`, `avaliacao_indisponivel`, `fora_da_janela`, `a_caminho_fora_da_janela`, `registro_no_futuro`, `reabertura_antes_da_tolerancia`, `sem_suspensao_ativa` |
| **429 Too Many Requests** | Excesso de chamadas na janela | `limite_excedido` |

---

## 2. Princípios e Mecanismos de Idempotência

Em aplicações móveis (iOS e Android), quedas temporárias de rede móvel (3G/4G/5G ou Wi-Fi instável) frequentemente causam desconexão após o commit da transação no banco de dados, mas antes que a resposta HTTP 200/201 seja entregue ao aplicativo.

O cliente, ao reenviar a requisição com backoff exponencial ou ação do usuário, **nunca pode duplicar dados, debitar cotas repetidas ou receber erro 500**.

O Frila adota três estratégias de idempotência:

1. **Idempotência por Chave Natural (Sem campo adicional):**  
   Aplicada onde o par de entidades possui unicidade intrínseca garantida pelo modelo relacional.
   - *Exemplo 1 (`candidatar`):* Unicidade no par `(vaga_id, profissional_id)`. Se o profissional reenviar, a função detecta o registro prévio e devolve a confirmação com o mesmo status sem criar nova candidatura.
   - *Exemplo 2 (`avaliar`):* Unicidade no par `(turno_id, autor_lado)`. Retentativas com as mesmas respostas devolvem `200 OK` idempotente; respostas divergentes são recusadas com `409 avaliacao_ja_registrada`.
   - *Exemplo 3 (`cadastrar_estabelecimento`):* Unicidade no documento limpo (`cpf` ou `cnpj`). O reenvio do mesmo documento pelo mesmo administrador devolve o registro existente com `200 OK`.

2. **Idempotência por Chave de Aplicação (`chave` UUID):**  
   Aplicada onde a ação pode ser legitimamente repetida no tempo (ex.: publicar duas vagas com o mesmo cargo no mesmo dia), exigindo um identificador único de intenção gerado no cliente.
   - *Exemplo 1 (`publicar_vaga`):* Recebe `p_chave uuid`. A tabela armazena a chave com índice de unicidade por estabelecimento. Reenvios devolvem a vaga já gravada sem debitar novas vagas ou duplicar posições.
   - *Exemplo 2 (`denunciar`):* Recebe `chave_idempotencia uuid`. O reenvio devolve o mesmo `Protocolo` e a mesma data `criado_em`.
   - *Exemplo 3 (`republicar_posicoes_restantes`):* Recebe `chave uuid`. Reenvios devolvem a vaga republicada original.

3. **Idempotência de Estado Terminal (Operações de Ciclo de Vida):**  
   - *Exemplo 1 (`excluir_conta`):* Se a conta já tiver sido anonimizada por chamada anterior, devolve resposta compatível com sucesso (`202 Accepted`) sem erro.
   - *Exemplo 2 (`remover_dispositivo`):* Se o token já foi desvinculado ou nunca existiu, responde `{ "removido": false }` com `200 OK`.

---

## 3. Matriz Consolidada de Idempotência e Tratamento de Erros (44 RPCs)

| # | RPC Pública | Tipo | Mecanismo de Idempotência | Resposta no Reenvio Idêntico | Mitigação de Concorrência |
|---|---|:---:|---|---|---|
| 1 | `configuracao_do_app` | Leitura | Leitura pura (imutável por versão) | Mesma configuração JSON | Operação somente-leitura |
| 2 | `criar_conta` | Escrita | Chave natural (`auth.uid()`) | Devolve `200 OK` ou `409 conta_existente` | Unique constraint em `usuario.id` |
| 3 | `minha_conta` | Leitura | Leitura pura (`auth.uid()`) | Dados do titular autenticado | Somente-leitura |
| 4 | `situacao_da_conta` | Leitura | Leitura pura (`auth.uid()`) | Estado de suspensão/bloqueio atual | Somente-leitura |
| 5 | `contestar_suspensao` | Escrita | Chave natural (`usuario_id`, `suspensao_em_vigor`) | `409 contestacao_ja_aberta` | Lock transacional na linha da suspensão |
| 6 | `registrar_dispositivo` | Escrita | Chave natural (`token_fcm`) | Devolve `{ plataforma, atualizado_em }` | `ON CONFLICT (token) DO UPDATE` |
| 7 | `remover_dispositivo` | Escrita | Chave natural (`token_fcm`) | Devolve `{ "removido": false }` | Exclusão atômica (`DELETE ... WHERE`) |
| 8 | `registrar_evento` | Escrita | Chave do app (`evento_id` UUID) | `200 OK` (ignora reenvio duplicado) | `ON CONFLICT (evento_id) DO NOTHING` |
| 9 | `perfil_publico` | Leitura | Leitura pura (`alvo_tipo`, `alvo_id`) | Dados públicos agregados da entidade | RLS e projeção restrita |
| 10 | `minhas_notificacoes` | Leitura | Leitura pura (`usuario_id`, paginação) | Lista de notificações ordenadas | Somente-leitura |
| 11 | `marcar_notificacao_lida` | Escrita | Chave natural (`notificacao_id`, `usuario_id`) | `200 OK` (mantém `lida_em` original) | `UPDATE ... WHERE lida_em IS NULL` |
| 12 | `criar_perfil_profissional`| Escrita | Chave natural (`usuario_id`) | `409 perfil_ja_existe` | Unique constraint em `profissional.usuario_id` |
| 13 | `meu_perfil_profissional` | Leitura | Leitura pura (`auth.uid()`) | Perfil profissional completo | Somente-leitura |
| 14 | `atualizar_perfil_profissional` | Escrita | Estado (`auth.uid()`) | Devolve perfil atualizado | `UPDATE` atômico na linha do titular |
| 15 | `atualizar_grade_semanal` | Escrita | Estado (`auth.uid()`) | Substitui grade (idempotência por estado final)| Transação atômica (`DELETE + INSERT`) |
| 16 | `vagas_abertas` | Leitura | Leitura pura (filtro geográfico/função) | Lista de vagas abertas visíveis | RLS + filtro de elegibilidade |
| 17 | `detalhes_da_vaga` | Leitura | Leitura pura (`vaga_id`) | Detalhes e status da vaga | RLS |
| 18 | `candidatar` | Escrita | Chave natural (`vaga_id`, `profissional_id`) | Devolve candidatura existente (`200 OK`) | `ON CONFLICT (vaga_id, profissional_id)` |
| 19 | `cancelar_candidatura` | Escrita | Chave natural (`vaga_id`, `profissional_id`) | Devolve confirmação (`200 OK`) | Transação condicional ao estado |
| 20 | `confirmar_candidatura` | Escrita | Transição de estado para confirmado | Devolve turno confirmado (`200 OK`) | `FOR UPDATE` na posição |
| 21 | `minhas_candidaturas` | Leitura | Leitura pura (`profissional_id`) | Lista de candidaturas ativas | Somente-leitura |
| 22 | `avisar_a_caminho` | Escrita | Chave natural (`turno_id`) | Devolve registro existente (`200 OK`) | `COALESCE` preserva primeiro instante |
| 23 | `checkin` | Escrita | Chave natural (`turno_id`) | Devolve confirmação existente (`200 OK`) | `FOR UPDATE` e validação de janela |
| 24 | `checkout` | Escrita | Chave natural (`turno_id`) | Devolve confirmação existente (`200 OK`) | Validação estrita de checkin prévio |
| 25 | `cadastrar_estabelecimento` | Escrita | Chave natural (`documento` limpo) | Devolve estabelecimento já cadastrado | `ON CONFLICT (documento)` |
| 26 | `meu_estabelecimento` | Leitura | Leitura pura (`estabelecimento_id`) | Dados do estabelecimento | Validação de vínculo de membro |
| 27 | `atualizar_estabelecimento`| Escrita | Estado (`estabelecimento_id`) | Devolve registro atualizado | Validação de administrador |
| 28 | `publicar_vaga` | Escrita | Chave de aplicação (`p_chave` UUID) | Devolve vaga já criada sem duplicar | Unique index em `(estabelecimento_id, chave)`|
| 29 | `republicar_vaga` | Escrita | Chave de aplicação (`p_chave` UUID) | Devolve vaga republicada sem duplicar | Unique index na chave |
| 30 | `republicar_posicoes_restantes` | Escrita | Chave de aplicação (`p_chave` UUID) | Devolve nova vaga parcial gerada | `FOR UPDATE` na vaga original |
| 31 | `cancelar_vaga` | Escrita | Estado terminal (`vaga_id`) | Devolve cancelamento confirmado (`200 OK`) | `UPDATE ... WHERE status != 'cancelada'` |
| 32 | `cancelar_posicao` | Escrita | Estado terminal (`posicao_id`) | Devolve cancelamento confirmado (`200 OK`) | `FOR UPDATE` na posição |
| 33 | `candidatos_da_vaga` | Leitura | Leitura pura (`vaga_id`) | Lista de candidatos com score | Somente-leitura |
| 34 | `escolher_candidato` | Escrita | Transição de estado da posição | Devolve posição confirmada | `SELECT ... FOR UPDATE` prevenindo corrida |
| 35 | `reabrir_por_atraso` | Escrita | Chave natural (`turno_id`) | Devolve vaga reaberta | `FOR UPDATE` no turno em atraso |
| 36 | `confirmar_checkin_manual` | Escrita | Chave natural (`turno_id`) | Devolve presença confirmada (`200 OK`) | Validação de membro do estabelecimento |
| 37 | `meus_turnos` | Leitura | Leitura pura (`profissional` ou `membro`) | Lista de turnos | Somente-leitura |
| 38 | `contato_do_turno` | Leitura | Leitura com janela temporal de 7 dias | Dados de contato da contraparte | Verificação de participação no turno |
| 39 | `avaliar` | Escrita | Chave natural (`turno_id`, `autor_lado`) | Devolve avaliação gravada (`200 OK`) | Conflito se notas divergirem |
| 40 | `painel_estabelecimento` | Leitura | Leitura analítica agregada | Métricas operacionais do estabelecimento | Somente-leitura |
| 41 | `equipe_de_confianca` | Leitura | Leitura pura (`estabelecimento_id`) | Lista de profissionais da equipe | Validação de membro |
| 42 | `incluir_na_equipe` | Escrita | Chave natural (`estabelecimento_id`, `prof_id`) | Devolve membro da equipe (`200 OK`) | `ON CONFLICT DO NOTHING` |
| 43 | `remover_da_equipe` | Escrita | Chave natural (`estabelecimento_id`, `prof_id`) | Devolve sucesso (`200 OK`) | `DELETE ... WHERE` idempotente |
| 44 | `abrir_suporte` | Escrita | Chave de aplicação (`chave_idempotencia`) | Devolve protocolo do ticket aberto | Verificação de duplicidade de protocolo |

---

## 4. Conclusão e Conformidade

A arquitetura do Frila Backend assegura que:
1. **Zero Efeito Colateral em Retentativas:** Todas as operações críticas de publicação, pagamento de posições e candidaturas são rigorosamente idempotentes via chaves naturais ou UUIDs fornecidos pelos apps móveis.
2. **Isolamento de Corridas:** Cenários de concorrência com alta contenção (múltiplos candidatos disputando a última vaga, múltiplos membros confirmando presença simultaneamente ou retentativas pós-timeout) são blindados por cláusulas `FOR UPDATE` e restrições atômicas de unicidade.
3. **Consistência Contratual:** Todas as 44 rotinas aderem estritamente ao esquema de erro e aos códigos de retorno estipulados no OpenAPI (`contrato/openapi.yaml`), garantindo que tanto o cliente iOS (Swift) quanto o Android (Kotlin) tratem exceções de forma padronizada e sem surpresas.
