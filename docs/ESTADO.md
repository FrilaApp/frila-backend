# Estado do backend — 10/10/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

**A `develop` é o tronco e está 382 commits à frente do `main`, que não se move desde
28/09.** O `main` continua inteiramente contido na `develop` (`git log
origin/develop..origin/main` sai vazio) e parado em `c190836`. A `develop` possui **102 migrações**
e **100 arquivos de pgTAP** (com **2.723 asserções** verdes, 100% PASS).

Os números abaixo foram consolidados e remedidos em 10/10, com a `develop` em `f73020b` — conferidos
diretamente com a execução das ferramentas do repositório e da CI.

| | | Comando |
|---|---|---|
| Commits à frente do `main` | **382** | `git rev-list --count origin/main..origin/develop` |
| Migrações na `develop` | **102** | `git ls-tree -r --name-only origin/develop -- supabase/migrations \| grep -c '\.sql$'` |
| pgTAP | **100 arquivos, 2.723 asserções**, verde | `Files=100, Tests=2723 … Result: PASS`, medido na CI e com `supabase test db` |
| Portão `contrato-responde.sh` | **151 recusas vigiadas e alcançadas**, verde | 151 de 151 vigiados e alcançados (100% de cobertura; 16 isentas, 0 não vigiadas de 167 declaradas), 46 de 50 respostas 200 validadas, 37 de 37 coleções |
| Testes em Deno das Edge Functions | **178** na suíte, verde | `ok \| 178 passed \| 0 failed`, medido com `deno test --allow-all --no-check` |
| Edge Functions | **9** | `git ls-tree -d --name-only origin/develop:supabase/functions \| wc -l` |
| Testes unitários em `exportar-turnos` | **31**, verde | `deno test supabase/functions/exportar-turnos/index_test.ts` |
| Scripts em `scripts/` | **38** arquivos `.sh` | `git ls-tree -r --name-only origin/develop -- scripts \| grep -c '\.sh$'` — 41 arquivos no total, incluindo `.py` e `.sql` |
| Contrato espelhado | **0.2.41** | `sed -n 's/^  version: *//p' contrato/openapi.yaml` |

Um aviso sobre a contagem de pgTAP: `supabase/tests/*.sql` tem **99** arquivos de teste de regras,
e o `prove` conta **100** porque alcança também `supabase/tests/carga/gerar_df.sql`, que é gerador
de carga e não teste de regra. O número da CI, e o da tabela, é **100 arquivos e 2.723 testes**.

> ## 🟢 O espelho do contrato está em dia (0.2.41) e alinhado ao original
>
> O contrato **0.2.41** está em vigor na raiz de `develop` e alinhado ao `FrilaApp/frila-docs · api/openapi.yaml`.
> Ele consolida o modo de seleção com menos de 24h em urgência (0.2.38), a remoção de 403 não documentado
> em rotas sem barreira de perfil (0.2.39), o suporte por e-mail a partir do turno (RPC `abrir_suporte` / Opção C,
> 0.2.40, PR #169 e operação P6 no PR #171) e a republicação de posições restantes (RPC `republicar_posicoes_restantes`,
> 0.2.41, PR #170).
>
> A `develop` recebeu o espelho idêntico (`31d91467aac0369669c73c251993eafa65528e4964f4051242be10594b3f27ce`)
> e todas as implementações, migrações e testes correspondentes (#161, #169, #170 e #171).
> O portão `./scripts/contrato-em-dia.sh` confirma integridade com sha256 exato.
>
> | | Versão | sha256 | bytes |
> |---|---|---|---|
> | espelho, `contrato/openapi.yaml` na `develop` | **0.2.41** | `31d91467aac0369669c73c251993eafa65528e4964f4051242be10594b3f27ce` | 243 887 |
> | original, `FrilaApp/frila-docs · api/openapi.yaml` | **0.2.41** | `31d91467aac0369669c73c251993eafa65528e4964f4051242be10594b3f27ce` | 243 887 |

> ## 🟢 Instabilidades de concorrência em `Corridas do ciclo` sanadas na raiz
>
> As falhas registradas na CI em rodadas de concorrência foram investigadas e resolvidas:
>
> 1. **Cenário 9 (`excluir_conta` x `candidatar` deadlock `40P01`):** Resolvido no PR **#101**
>    (cartão `CPD2c74A`). A causa era inversão de ordem de travas trancando o usuário antes da vaga;
>    a correção tranca a vaga antes do usuário, zerando os impasses (0 de 50).
> 2. **Cenário 3 (agendador do teto e despachos concorrentes):** Resolvido no PR **#134**
>    (`test(corrida): robustece temporização e transações do cenário 3 do teto`). Ampliadas as margens
>    de temporização para absorver o jitter de vCPU nos runners do GitHub Actions e isoladas as transações
>    do agendador por profissional livre.
> 3. **Bloqueio em `perfil_publico` (cartão `1aGJPQK2`):** Implementado no PR **#104** com
>    a migração `20261001140000_perfil_publico_bloqueio.sql` e teste `550_perfil_publico_bloqueio.sql`.
> 4. **Cenário 11 (republicação de posições restantes concorrente):** Validado no PR **#170**
>    com `scripts/corrida-republicar-posicoes.sh` garantindo unicidade na reabertura sob concorrência.

---

## Onde cada coisa parou

### Entregas Recentes e Marcos Consolidados (até 10/10)

O repositório ultrapassou **150 PRs mergeados**, com cobertura integral do contrato, novas RPCs e endurecimento da esteira:

1. **Lotes 6 a 10 de Recusas Críticas e Endurecimento do Portão (#157, #159, #163, #164, #165, #167):**
   Expansão completa das recusas críticas no `contrato-responde.sh`, saltando de 81 para 151 pares vigiados e alcançados, cobrindo 100% dos pares possíveis do banco (com 16 isenções técnicas justificadas em `contrato_responde.py` e 0 não vigiados). O portão passou a falhar estritamente na CI caso surjam novas recusas sem cobertura ou sem isenção justificada. Acompanhado pelas suítes pgTAP `490` a `494`.
2. **PR #161 (Modo Seleção em Urgência · merge em 07/10):**
   Publicação de vagas e reabertura com menos de 24h para o início do turno são forçadas para o modo urgência (`D4=C`, `D5=A`), recusando seleção manual com `422 modo_indisponivel`. Migração `20261007110000_modo_selecao_reabertura_urgencia.sql`.
3. **PR #169 (Suporte por e-mail a partir do turno / Contrato 0.2.40 · merge em 09/10):**
   Implementação da RPC `abrir_suporte` (Opção C, cartão `vN1yH4d3`, RF23, UC14), permitindo ao contratante ou profissional abrir chamado com categoria predefinida e sem texto livre (LGPD/RN15). Retorna `protocolo` (UUID) e `protocolo_curto` (8 caracteres hexadecimais em maiúsculas). Migrações `20261008100000_categoria_suporte_e_origem_ocorrencia.sql` e `20261008110000_abrir_suporte.sql`. Suíte pgTAP `620_abrir_suporte.sql` (26 testes) e par vigiado `abrirSuporte:422`.
4. **PR #170 (Republicar Posições Restantes / Contrato 0.2.41 · merge em 10/10):**
   Implementação da RPC `republicar_posicoes_restantes` (cartão `D1-C`), permitindo ao contratante reabrir posições remanescentes de vaga fechada sem candidatos em seleção, clonando a vaga em modo urgência com rastreabilidade `republicada_de_id` e exibição consolidada no painel. Migrações `20261009100000_vaga_republicada_de_e_republicacao_da_selecao.sql` e `20261009110000_republicar_posicoes_restantes_e_painel.sql`. Suíte pgTAP `630_republicar_posicoes_restantes.sql` (55 testes), corrida 11 (`corrida-republicar-posicoes.sh`) e pares vigiados `republicarPosicoesRestantes:409/422`.
5. **PR #171 (Operação do Suporte por E-mail P6 · merge em 10/10):**
   Ajuste operacional de `consultar-ocorrencias.sql` com join interno no autor e exibição de protocolo curto de 8 caracteres; criação do script `fechar-chamado-sem-email.sql` para encerramento manual com resultado `sem_email_recebido` após o prazo regulamentar de 5 dias úteis (D16, SU-RN10); e documentação completa de procedimentos e expurgo seguro LGPD na caixa `suporte@frila.app` em `supabase/operacao/equipe-frila.md` (D9, SU-RN11).

### A fila de PRs aberta em 10/10

Medida com `gh pr list --state open` em 10/10:

| PR | Ramo | Título / Escopo |
|---|---|---|
| **#168** | `docs/estado-08-10` | `docs(estado): fotografia de 08/10, contrato 0.2.38, 111 de 111 recusas` (obsoleto; superado pela consolidação de 10/10) |

---

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · **102** migrações na `develop`, **47** no `main` (em 10/10) |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` · SMTP próprio ativo (`smtp.gmail.com:465`, código de 6 dígitos) |
| `frila-prod` | `hbjkkcenbudiezmamiak` · `sa-east-1` · criado em 24/09, **vazio**: aguarda esteira de deploy por tag |

**Desde 29/09 o `frila-dev` manda e-mail por SMTP próprio** (PR #81):
- Envio: `smtp.gmail.com:465`, conta `frilaverificacao@gmail.com`, remetente "Frila".
- Conteúdo: código de seis dígitos (`{{ .Token }}`).
- Validade: 15 minutos.

---

## O contrato em detalhes

Versão vigente: **0.2.41**, espelhada em `contrato/openapi.yaml` e **em dia com o original**,
conferido em 10/10 com o portão: *"Espelho em dia com FrilaApp/frila-docs"*.

Histórico das versões recentes integradas no backend:

| Versão | O que trouxe | Backend |
|---|---|---|
| **0.2.28** | bloqueio esconde perfil público com 404 | #103, #104 |
| **0.2.29** | `meu_estabelecimento` para membros do estabelecimento | #125 |
| **0.2.30** | `vinculo_id` do aparelho no push e registro de dispositivo | #129 |
| **0.2.31** | turno cancelado, avaliação dada e cancelamento no painel | #131 |
| **0.2.32** | cancelamento no turno e `turno_id` na candidatura | #130 |
| **0.2.33** | as sete coleções de `MeusDados` com campos conformes | #99, #135 |
| **0.2.34** | alinhamentos de coleções e portão de coleções exercitadas | #140 |
| **0.2.35** | reenvio idempotente de `cancelar_posicao` e `cancelar_vaga` | #149 |
| **0.2.36** | Opção B em situação da conta / suspensão (`409 contestacao_ja_aberta`) | #153 |
| **0.2.37** | Opção B em revisão de despacho (`409`) e janela de 30 dias na exportação (`422`) | #155 |
| **0.2.38** | modo seleção da v1.1 com menos de 24h forçado em urgência (`422 modo_indisponivel`) | #161, #162 |
| **0.2.39** | remoção de status 403 não documentado em operações sem barreira de perfil | #166 |
| **0.2.40** | suporte por e-mail a partir do turno (RPC `abrir_suporte` / Opção C, RF23, UC14) | #169, #171 |
| **0.2.41** | republicação de posições restantes (RPC `republicar_posicoes_restantes`, D1-C) | #170 |

---

## O que existe no banco

Medido no banco de desenvolvimento com a `develop` em `f73020b`:

- **22 tabelas** em `public`:
  ```
  avaliacao · bloqueio · candidatura · despacho · disponibilidade · dispositivo
  entrada_demonstracao · equipe_confianca · estabelecimento · evento · evento_app
  funcao · membro_estabelecimento · notificacao · ocorrencia · pedido_de_exclusao
  posicao · profissional · profissional_funcao · turno · usuario · vaga
  ```
- **102 migrações** aplicadas sequencialmente sem colisão.
- RLS ativado em todas as tabelas; escrita exclusivamente através de funções `security definer`.
- **44 RPCs expostas a `authenticated`** (+ 1 pública `configuracao_do_app`):
  ```
  conta        criar_conta · minha_conta · situacao_da_conta · contestar_suspensao
  perfil       criar_perfil_profissional · meu_perfil_profissional · atualizar_perfil_profissional
  casa         cadastrar_estabelecimento · painel_estabelecimento · meus_estabelecimentos · meu_estabelecimento
  equipe       equipe_de_confianca · incluir_na_equipe · remover_da_equipe
  vaga         publicar_vaga · republicar_vaga · vagas_abertas · detalhe_vaga · cancelar_vaga · republicar_posicoes_restantes
  seleção      candidatos_da_vaga · escolher_candidato · retirar_candidatura
  turno        candidatar · minhas_candidaturas · meus_turnos · contato_do_turno · cancelar_posicao · avisar_a_caminho
  presença     fazer_checkin · fazer_checkout · confirmar_checkin_manual
  reputação    avaliar · perfil_publico
  push/disp    registrar_dispositivo · remover_dispositivo · criterios_de_notificacao
  moderação    denunciar · bloquear
  telemetria   registrar_evento
  despacho     pedir_revisao_despacho · reabrir_por_atraso
  suporte      abrir_suporte
  app          configuracao_do_app (pública para anon)
  ```
- **Treze jobs ativos em `pg_cron`**:
  `alertar_atrasos`, `alertar_fim_sem_checkout`, `alertar_vagas_vazias`, `enviar_lembretes_turno`,
  `fechar_selecoes`, `fechar_turnos_e_vagas`, `liberar_teto`, `limpar_dispositivos_inativos`,
  `processar_fila_email`, `reconciliar_reputacao_diaria`, `reprocessar_despacho`,
  `retencao_e_limpeza_diaria`, `verificar_saude`.

> ### ⚠️ A armadilha: `frila.agendador_secret`
> O gatilho de `pgmq.q_despacho` exige `frila.agendador_secret` configurado no banco antes de qualquer
> RPC que enfileire uma vaga. Na CI e em testes locais, configure o segredo efêmero logo após o `supabase start`.

---

## Os portões

Medição consolidada da bateria em 10/10 com a `develop` em `f73020b`:

| Comando | O que garante | Medida em 10/10 |
|---|---|---|
| `supabase test db` | pgTAP | **100** arquivos, **2.723** asserções verdes (100% PASS) |
| `./scripts/contrato-responde.sh` | respostas casam com o contrato | **46 de 50** respostas 200 validadas, **151 de 151** recusas vigiadas e alcançadas, **37 de 37** coleções exercitadas |
| `deno test --allow-all --no-check` | Edge Functions em Deno | **178** testes verdes (0 falhas), incluindo 31 em `exportar-turnos` |
| `./scripts/teste-contrato-promete.sh` | autoteste da direção contrato-à-frente | 9 de 9 casos verdes |
| `./scripts/teste-contrato-responde.sh` | autoteste de schemas do contrato | 14 de 14 casos verdes |
| `./scripts/teste-contrato-acompanha.sh` | PR que altera `public` acompanha contrato | 19 de 19 casos verdes |
| `./scripts/relogio-em-testes.sh` | imunidade contra bombas-relógio de relógio | **99** arquivos pgTAP imunizados |
| `./scripts/migracoes-sem-colisao.sh` | carimbos de migração únicos | **102** carimbos distintos sem colisão |
| `./scripts/migracoes-imutaveis.sh` | migrações passadas não foram alteradas | verde |
| `./scripts/planos-com-carga.sh` | caminho quente sob volume sintético do DF | verde na CI (p95 elegíveis 27 ms, vagas 28 ms) |

### O portão do contrato, medido em 10/10

Medido na `develop` em `f73020b`, com `supabase db reset` aplicado e `frila.agendador_secret`
configurado antes da execução, por `./scripts/contrato-responde.sh` — **exit code 0**:

| | Medida em 10/10 | Linha da saída do portão |
|---|---|---|
| respostas 200 validadas com corpo real | **46 de 50** | `Validadas com corpo real:               46` |
| pares (operação, status) de recusa declarados no contrato | **167** | `declarados no contrato: 167` |
| pares vigiados e alcançados | **151 de 151** | `vigiados e alcançados:  151 de 151` |
| pares isentos, com motivo documentado | **16** | `isentos, com motivo:    16` |
| pares ainda não vigiados | **0** | `ainda não vigiados:     0` |
| coleções exercitadas com itens | **37 de 37**, 0 vazias | `exercitadas com itens:     37 de 37` |

A conta fecha perfeitamente: **151 vigiados + 16 isentos + 0 não vigiados = 167 declarados** (100% de cobertura).

As quatro operações com resposta 200 fora do alcance do portão, com o motivo documentado na própria ferramenta:
`confirmarCodigo` e `renovarSessao` (a `Sessao` é emitida pelo Supabase Auth, não por código deste repositório),
`entrarDemonstracao` (a Edge Function repassa a `Sessao` do Auth) e `listarFuncoes` (leitura de tabela direta pelo PostgREST).

Os 16 pares isentos documentados em `ISENTAS` em `scripts/contrato_responde.py`:
- **Supabase Auth (4):** `entrarDemonstracao:429`, `pedirCodigo:429`, `confirmarCodigo:401`, `renovarSessao:401`.
- **PostgREST (1):** `listarFuncoes:401`.
- **Edge Functions (11):** `entrarDemonstracao:404`, `exportarMeusDados:401/404/405`, `exportarTurnos:401/403/405/422`, `excluirConta:401/405/422` (testadas pela suíte Deno na CI).

---

## O que foi aprendido, e custa caro reaprender

- **O banco não nasce vazio, e dois cartões podem escolher o mesmo dado:** Teste novo conta com os cenários por ID do cenário, nunca pela tabela inteira.
- **A CI roda a suíte duas vezes:** Scripts que gravam de verdade (`ciclo-completo.sh`) exigem isolamento para não quebrar a execução subsequente de mutação.
- **Suíte verde não diz o que ela protege:** Testes precisam de asserções positivas e negativas em cada política e restrição.
- **Uma recusa tem três eixos:** `sqlstate`, `code` e status HTTP.
- **Rótulo de volatilidade mentiroso passa despercebido:** `plpgsql_check` e linter garantem que funções que chamam `erro` sejam marcadas como VOLATILE.
- **Dois branches podem escolher a mesma hora redonda:** `scripts/migracoes-sem-colisao.sh` evita colisão de migrações antes do merge.
- **Recusa contratual sem teste vira débito acumulado:** o portão `contrato-responde.sh` agora bloqueia a CI se qualquer novo par de erro for adicionado ao OpenAPI sem teste ou justificativa explícita.

---

## Divergências registradas

Colunas do esquema com funções de negócio específicas que complementam a Modelagem de Banco:

| Coluna | Por quê |
|---|---|
| `vaga.publicado_por` | um estabelecimento tem vários membros, e RF04 pergunta quem publicou |
| `usuario.demonstracao` | conta de revisão da App Store; as duas populações dividem o banco sem se enxergar |
| `turno.checkin_recebido_em` | `checkin_em` é a hora do toque; sem as duas, registro offline vira indistinguível |
| `turno.checkout_recebido_em` | o mesmo, do outro lado |
| `posicao.reaberta_por_atraso_de` | `reabrir_por_atraso` (e8XpOZJN): a posição nova sabe de qual falta nasceu; aceita candidato depois do início até 1 h antes do fim |
| `vaga.rodada_despacho` | rodada de despacho (9DbPXis7): 1 na publicação, incrementada a cada `reabrir_por_atraso` |
| `despacho.rodada` | unicidade do despacho por `(vaga_id, profissional_id, rodada)` |
| `notificacao.rodada` | marca de envio de vaga por rodada para não suprimir push da rodada nova |
| `turno.a_caminho_em` | aviso "estou a caminho" (h53CJVP7, contrato 0.2.25) |
| `vaga.republicada_de_id` | rastreabilidade da republicação de posições restantes (cartão D1-C, contrato 0.2.41) |
| `posicao.republicada_de_posicao_id` | rastreabilidade da posição de origem clonada na republicação |

E alinhamentos consolidados de negócio:
- **Suporte por e-mail a partir do turno (Opção C, contrato 0.2.40, PR #169 e P6 no PR #171):** Chamados abertos via RPC `abrir_suporte` gravam ocorrência com `tipo = 'suporte'`, `origem = 'app'`, `turno_id`, categoria e sem texto livre (`relato` nulo, LGPD/RN15). A fila de operação (`consultar-ocorrencias.sql`) expõe `protocolo_curto` (8 hexadecimais), `origem`, `turno_id` e prazo legal de 5 dias úteis. Chamados sem envio de e-mail pelo usuário são encerrados manualmente pela Equipe via `fechar-chamado-sem-email.sql` com `resultado = 'sem_email_recebido'` (D16, SU-RN10). E-mails tratados são expurgados da caixa `suporte@frila.app` e lixeira conforme diretriz de retenção da LGPD (D9, SU-RN11).
- **Republicação de posições restantes (D1-C, contrato 0.2.41, PR #170):** Permite ao contratante reabrir posições restantes de vaga fechada sem candidatos em seleção ativa. Cria nova vaga em modo urgência com posições clonadas, mantendo o histórico na vaga original.
- **Avaliação:** Um voto por lado do turno (`unique (turno_id, alvo_tipo)` e `unique (turno_id, autor_id)`). Reenvio do mesmo valor recebe 200; valor divergente recebe `409 avaliacao_ja_registrada`.
- **Filtro de Bloqueio em `perfil_publico`:** Totalmente implementado e protegido com 404 em caso de bloqueio bidirecional (PR #104, teste 550).
- **Check-out fora da janela:** Recusado com `422 fora_da_janela`. O alerta cron `alertar_fim_sem_checkout` monitora turnos encerrados sem check-out.
- **Apenas quatro operações sem RPC própria nem Edge Function:** `pedirCodigo` (`/otp`), `confirmarCodigo` (`/verify`) e `renovarSessao` (`/token`), que são endpoints nativos do Supabase Auth, e `listarFuncoes` (`/funcao`), que é leitura direta por PostgREST. `entrarDemonstracao` possui Edge Function própria em `supabase/functions/entrar-demonstracao/index.ts`. Todas as 46 operações com corpo 200 ao alcance do portão possuem RPC dedicada no banco.

---

## Pendências fora do código

1. **Credenciais para Deploy Remoto:** Execução no ambiente remoto `frila-dev` e `frila-prod` depende de `SUPABASE_ACCESS_TOKEN` válido configurado no ambiente.
2. **Revisão da Júlia:** Revisão da lista de termos bloqueados do filtro de texto ofensivo (`ggEzge6h`).
3. **Publicação da Bancada:** Push de notas no repositório `FrilaApp/Bancada` requer autenticação local.

---

## Por onde continuar

1. **Homologação e Deploy no `frila-dev`:** Com a `develop` consolidada em 10/10 (contrato 0.2.41, 102 migrações, suporte e republicação), sincronizar as migrações no projeto remoto `jcobftbhbqdikratzizz`.
2. **Frontend e Clientes Mobile:** As novas funcionalidades (suporte por e-mail a partir do turno, encerramento de chamado e republicação de posições restantes em modo urgência) estão com contratos 0.2.41 e backends 100% disponíveis para consumo.
3. **Fechamento do PR #168:** O PR #168 de 08/10 está obsoleto perante a consolidação em 10/10 e pode ser fechado sem merge.

