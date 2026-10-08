# Estado do backend — 08/10/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

**A `develop` é o tronco e está 368 commits à frente do `main`, que não se move desde
28/09.** O `main` continua inteiramente contido na `develop` (`git log
origin/develop..origin/main` sai vazio) e parado em `c190836`. A `develop` possui **98 migrações**
e **92 arquivos de pgTAP** (com **2.536 asserções** verdes, 100% PASS).

Os números abaixo foram consolidados e remedidos em 06/10, com a `develop` em `c1b838e` — conferidos
diretamente com a execução das ferramentas do repositório. As linhas do portão `contrato-responde.sh`
e do contrato espelhado foram remedidas em 08/10, com a `develop` em `f6525a8`; as demais seguem de
06/10, porque ninguém as rodou hoje.

| | | Comando |
|---|---|---|
| Commits à frente do `main` | **368** | `git rev-list --count origin/main..origin/develop` |
| Migrações na `develop` | **98** | `git ls-tree -r --name-only origin/develop -- supabase/migrations \| grep -c '\.sql$'` |
| pgTAP | **92 arquivos, 2.536 asserções**, verde | `Files=92, Tests=2536 … Result: PASS`, medido com `supabase test db` |
| Portão `contrato-responde.sh` (08/10, `f6525a8`) | **111 recusas vigiadas**, verde | 111 de 111 vigiados e alcançados, 44 de 48 respostas 200, 36 de 36 coleções, exit code 0 — `./scripts/contrato-responde.sh` |
| Testes em Deno das Edge Functions | **171** (178 na suíte), verde | `ok \| 178 passed \| 0 failed`, medido com `deno test --allow-all --no-check` |
| Edge Functions | **9** | `git ls-tree -d --name-only origin/develop:supabase/functions \| wc -l` |
| Testes unitários em `exportar-turnos` | **31**, verde | `deno test supabase/functions/exportar-turnos/index_test.ts` |
| Scripts em `scripts/` | **38** arquivos `.sh` | `git ls-tree -r --name-only origin/develop -- scripts \| grep -c '\.sh$'` — 40 arquivos no total, incluindo `.py` e `.sql` |
| Contrato espelhado (08/10, `f6525a8`) | **0.2.38** | `git show f6525a8:contrato/openapi.yaml \| sed -n 's/^  version: *//p'` |

Um aviso sobre a contagem de pgTAP: `supabase/tests/*.sql` tem **91** arquivos de teste de regras,
e o `prove` conta **92** porque alcança também `supabase/tests/carga/gerar_df.sql`, que é gerador
de carga e não teste de regra. O número da CI, e o da tabela, é **92 arquivos e 2.536 testes**.

> **Aviso de defasagem, medido em 08/10 depois das medições desta fotografia:** a `develop` avançou de
> `f6525a8` para `5497442` (PRs #163, #164, #165, #166 e #167 mergeados) e o espelho do contrato já
> está em **0.2.39** (sha256 `e81204d60084740df799d60c619e9df6608c2084a2ae6fcbcbaac5a24e228af3`).
> Os números do portão e a projeção de lotes neste documento valem para `f6525a8`, não para o topo da
> `develop`, e precisam de nova execução. MEDIDO com `git rev-parse --short origin/develop`,
> `git log --oneline f6525a8..origin/develop` e `git show origin/develop:contrato/openapi.yaml.sha256`.

> ## 🟡 O espelho do contrato está em 0.2.38; o alinhamento da 0.2.38 não foi conferido
>
> O contrato **0.2.38** está em vigor na raiz de `develop` desde o PR **#162** (commit `58f3be9`).
> Ele fecha o contrato do modo seleção para o iOS da v1.1 (cartão `d3A1WjG3`): **nenhuma operação
> nova** e nenhuma removida, apenas campo e enum — `Candidato.da_equipe`, o aviso `selecao_lembrete`
> e os textos dos avisos. Até a 0.2.37, o espelho consolidava a revisão de despacho (Opção B em
> `pedirRevisaoDespacho` / RF27), a janela de até 30 dias na exportação de turnos (cartão `pd7zOS5P`),
> o cancelamento idempotente (0.2.35) e a contestação de suspensão (Opção B, 0.2.36), com as
> implementações, migrações e testes correspondentes (#149, #150, #153, #154, #155 e #156).
>
> **O alinhamento da 0.2.38 com o original em `FrilaApp/frila-docs · api/openapi.yaml` NÃO FOI
> CONFERIDO.** O sha256 do espelho foi medido; o do original, não, e `./scripts/contrato-em-dia.sh`
> não foi executado para a 0.2.38. A última versão com alinhamento conferido é a **0.2.37**, em 06/10.
>
> | | Versão | sha256 | bytes |
> |---|---|---|---|
> | espelho, `contrato/openapi.yaml` na `develop` | **0.2.38** | `3873ea18920329430b6be80666138e45da19d3cf4fd63154654f1f75d74231eb` | 233 031 |
> | original, `FrilaApp/frila-docs · api/openapi.yaml` | 0.2.38 | **não conferido** | **não conferido** |
> | último alinhamento conferido, em 06/10 | 0.2.37 | `e190ab1f294cc72e1f557834c5f6ed6e2fe9980ec31d55460b80976e3287f786` | 228 491 |
>
> Comandos: versão e bytes do espelho com `git show 58f3be9:contrato/openapi.yaml`; sha256 com
> `git show 58f3be9:contrato/openapi.yaml | shasum -a 256`, idêntico ao gravado em
> `contrato/openapi.yaml.sha256`; conjunto de operações entre 0.2.37 (`d21106c`) e 0.2.38 inalterado,
> por comparação dos `operationId` dos dois blobs.

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

---

## Onde cada coisa parou

### Entregas Recentes e Marcos Consolidados (até 06/10)

O repositório ultrapassou **140 PRs mergeados**, com forte aceleração na cobertura de regras e segurança:

1. **PR #81 (SMTP frila-dev / Cauê · merge em 06/10):**
   Registra o SMTP próprio do `frila-dev` e o código no lugar do link mágico (`c0c5607`). Desbloqueia a validação de entrada sem depender de link de confirmação no app.
2. **PR #149 (Cancelamento Idempotente 0.2.35 · merge em 05/10):**
   Implementa reenvio idempotente de `cancelar_posicao` e `cancelar_vaga` (cartão `pVvubZJy`), sincronizando o contrato 0.2.35. Evita erros espúrios em retentativas de rede pelo app.
3. **PR #150 (Lote 3 de Recusas Críticas · merge em 05/10):**
   Adiciona 15 recusas críticas do contrato vigiadas pelo `contrato-responde.sh` com asserção estrita de `code` e suíte pgTAP `487_recusas_criticas_contrato_lote3.sql`.
4. **PR #153 (Opção B em Situação da Conta 0.2.36 · merge em 06/10):**
   Ciclo de vida da contestação de suspensão no app (decisão de produto de 05/10/2026 sobre a opção B do cartão `yoV2Ak4j`). No app só cabe 1 contestação por suspensão; reenvio recebe `409 contestacao_ja_aberta` mesmo após resposta. Recurso posterior exclusivamente por e-mail. Acompanha suíte pgTAP `604_situacao_da_conta_contestacao_respondida.sql`.
5. **PR #154 (Lote 4 de Recusas Críticas · merge em 06/10):**
   Mais 15 recusas críticas com asserção de `code`, elevando a cobertura para 66 pares vigiados no `contrato-responde.sh` e suíte pgTAP `488_recusas_criticas_contrato_lote4.sql`.
6. **PR #155 (Opção B na Revisão de Despacho e Janela de 30 dias na Exportação 0.2.37 · merge em 06/10):**
   - **Opção B em `pedir_revisao_despacho` (RF27, 0.2.37):** Trava de unicidade no app recusando reenvio com `409 contestacao_ja_aberta` caso já exista ocorrência de `revisao_despacho` para o autor (em análise ou já respondida). Recurso posterior exclusivamente por e-mail. Migração `20261006160000_revisao_despacho_opcao_b.sql` e suíte pgTAP `605_revisao_despacho_opcao_b.sql`.
   - **Edge Function `exportar-turnos` (pd7zOS5P, 0.2.37):** Parâmetros `de` e `ate` tornam-se opcionais com padrão dos últimos 15 dias quando omitidos. Parâmetro `formato` estritamente obrigatório (`422 campo_obrigatorio`). Janela regulamentar máxima permitida de até 30 dias: recusa intervalo > 30 dias com `422 intervalo_maximo_excedido`. 31 testes unitários Deno passando.
   - Sincronização do Contrato 0.2.37 e sha256 (`e190ab1f…`).
7. **PR #156 (Lote 5 de Recusas Críticas · merge em 06/10):**
   Expande a cobertura de recusas vigiadas de 66 para 81 pares no portão `contrato-responde.sh`, incluindo `pedirRevisaoDespacho:409`, `avaliar:422`, `criteriosDeNotificacao:403/404`, `meusEstabelecimentos:403`, `registrarDispositivo:422`, etc. Acompanha fixtures em `contrato-respostas.sql` e nova suíte pgTAP `489_recusas_criticas_contrato_lote5.sql` (15/15 testes).

### A fila de PRs aberta em 06/10

Medida com `gh pr list --state open` em 06/10:

| PR | Ramo | Título / Escopo |
|---|---|---|
| **#157** | `feat/lote6-recusas-contrato` | `feat(contrato): vigia lote 6 com 15 recusas criticas` (em andamento pelo Time A) |

---

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · **98** migrações na `develop`, **47** no `main` (em 06/10) |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` · SMTP próprio ativo (`smtp.gmail.com:465`, código de 6 dígitos) |
| `frila-prod` | `hbjkkcenbudiezmamiak` · `sa-east-1` · criado em 24/09, **vazio**: aguarda esteira de deploy por tag |

**Desde 29/09 o `frila-dev` manda e-mail por SMTP próprio** (PR #81):
- Envio: `smtp.gmail.com:465`, conta `frilaverificacao@gmail.com`, remetente "Frila".
- Conteúdo: código de seis dígitos (`{{ .Token }}`).
- Validade: 15 minutos.

---

## O contrato em detalhes

Versão vigente em 08/10, com a `develop` em `f6525a8`: **0.2.38**, espelhada em
`contrato/openapi.yaml` desde o PR #162 (`58f3be9`) — medida com
`git show f6525a8:contrato/openapi.yaml | sed -n 's/^  version: *//p'`. **O alinhamento da 0.2.38 com
o original não foi conferido**; o último conferido com o portão *"Espelho em dia com
FrilaApp/frila-docs"* é o da 0.2.37, em 06/10.

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
| **0.2.38** | modo seleção da v1.1: nenhuma operação nova, só campo e enum — `Candidato.da_equipe`, o aviso `selecao_lembrete` e os textos dos avisos | #162 (espelho; alinhamento com o original não conferido) |

---

## O que existe no banco

Medido no banco de desenvolvimento com a `develop` em `c1b838e`:

- **22 tabelas** em `public`:
  ```
  avaliacao · bloqueio · candidatura · despacho · disponibilidade · dispositivo
  entrada_demonstracao · equipe_confianca · estabelecimento · evento · evento_app
  funcao · membro_estabelecimento · notificacao · ocorrencia · pedido_de_exclusao
  posicao · profissional · profissional_funcao · turno · usuario · vaga
  ```
- **98 migrações** aplicadas sequencialmente sem colisão.
- RLS ativado em todas as tabelas; escrita exclusivamente através de funções `security definer`.
- **42 RPCs expostas a `authenticated`**:
  ```
  conta        criar_conta · minha_conta · situacao_da_conta · contestar_suspensao
  perfil       criar_perfil_profissional · meu_perfil_profissional · atualizar_perfil_profissional
  casa         cadastrar_estabelecimento · painel_estabelecimento · meus_estabelecimentos · meu_estabelecimento
  equipe       equipe_de_confianca · incluir_na_equipe · remover_da_equipe
  vaga         publicar_vaga · republicar_vaga · vagas_abertas · detalhe_vaga · cancelar_vaga
  seleção      candidatos_da_vaga · escolher_candidato · retirar_candidatura
  turno        candidatar · minhas_candidaturas · meus_turnos · contato_do_turno · cancelar_posicao · avisar_a_caminho
  presença     fazer_checkin · fazer_checkout · confirmar_checkin_manual
  reputação    avaliar · perfil_publico
  push/disp    registrar_dispositivo · remover_dispositivo · criterios_de_notificacao
  moderação    denunciar · bloquear
  telemetria   registrar_evento
  despacho     pedir_revisao_despacho · reabrir_por_atraso
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

Medição consolidada da bateria em 06/10 com a `develop` em `c1b838e`. A linha do
`contrato-responde.sh` foi remedida em 08/10 com a `develop` em `f6525a8`; as outras seguem de 06/10,
porque ninguém as rodou hoje:

| Comando | O que garante | Medida — 06/10, salvo onde a data estiver dita |
|---|---|---|
| `supabase test db` | pgTAP | **92** arquivos, **2.536** asserções verdes (100% PASS) |
| `./scripts/contrato-responde.sh` | respostas casam com o contrato | 08/10: **44 de 48** respostas 200 validadas, **111 de 111** recusas vigiadas e alcançadas, **36 de 36** coleções exercitadas, exit code **0** |
| `deno test --allow-all --no-check` | Edge Functions em Deno | **178** testes verdes (0 falhas), incluindo 31 em `exportar-turnos` |
| `./scripts/teste-contrato-promete.sh` | autoteste da direção contrato-à-frente | 9 de 9 casos verdes |
| `./scripts/teste-contrato-responde.sh` | autoteste de schemas do contrato | 12 de 12 casos verdes |
| `./scripts/teste-contrato-acompanha.sh` | PR que altera `public` acompanha contrato | 19 de 19 casos verdes |
| `./scripts/relogio-em-testes.sh` | imunidade contra bombas-relógio de relógio | **91** arquivos pgTAP imunizados |
| `./scripts/migracoes-sem-colisao.sh` | carimbos de migração únicos | **97** carimbos distintos sem colisão |
| `./scripts/migracoes-imutaveis.sh` | migrações passadas não foram alteradas | verde |
| `./scripts/planos-com-carga.sh` | caminho quente sob volume sintético do DF | verde na CI (p95 elegíveis 27 ms, vagas 28 ms) |

### O portão do contrato, remedido em 08/10

Medido na `develop` em `f6525a8`, com `supabase db reset` aplicado e `frila.agendador_secret`
configurado antes da execução, por `./scripts/contrato-responde.sh` — **exit code 0**:

| | Medida em 08/10 | Linha da saída do portão |
|---|---|---|
| respostas 200 validadas com corpo real | **44 de 48** | `Validadas com corpo real:               44` |
| pares (operação, status) de recusa declarados no contrato | **160** | `declarados no contrato: 160` |
| pares vigiados e alcançados | **111 de 111** | `vigiados e alcançados:  111 de 111` |
| pares isentos, com motivo | **3** | `isentos, com motivo:    3` |
| pares ainda não vigiados | **46** | `ainda não vigiados:     46` |
| coleções exercitadas com itens | **36 de 36**, 0 vazias | `exercitadas com itens:     36 de 36` |

A conta fecha: 111 vigiados + 3 isentos + 46 não vigiados = 160 declarados.

As quatro operações com resposta 200 fora do alcance do portão, com o motivo na própria saída:
`confirmarCodigo` e `renovarSessao` (a `Sessao` é emitida pelo Supabase Auth, não por código deste
repositório), `entrarDemonstracao` (a Edge Function só repassa a `Sessao` do Auth) e `listarFuncoes`
(o corpo é do PostgREST, não de função nossa).

**Projeção, e é DEDUÇÃO, não medição:** depois do merge do PR **#163** (lote 8, 15 pares) sobram
**31** pares não vigiados, o que fecha em três lotes — 15, 15 e 1. A dedução assume que o #163 não
mexe no conjunto declarado pelo contrato: o diff de nomes de arquivo da branch do #163 contra
`f6525a8` não lista `contrato/openapi.yaml`, e o PR não foi revisado. Veja também o aviso de
defasagem no topo: na `develop` em `5497442` esta projeção já não vale.

---

## O que foi aprendido, e custa caro reaprender

- **O banco não nasce vazio, e dois cartões podem escolher o mesmo dado:** Teste novo conta com os cenários por ID do cenário, nunca pela tabela inteira.
- **A CI roda a suíte duas vezes:** Scripts que gravam de verdade (`ciclo-completo.sh`) exigem isolamento para não quebrar a execução subsequente de mutação.
- **Suíte verde não diz o que ela protege:** Testes precisam de asserções positivas e negativas em cada política e restrição.
- **Uma recusa tem três eixos:** `sqlstate`, `code` e status HTTP.
- **Rótulo de volatilidade mentiroso passa despercebido:** `plpgsql_check` e linter garantem que funções que chamam `erro` sejam marcadas como VOLATILE.
- **Dois branches podem escolher a mesma hora redonda:** `scripts/migracoes-sem-colisao.sh` evita colisão de migrações antes do merge.

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

E alinhamentos consolidados de negócio:
- **Avaliação:** Um voto por lado do turno (`unique (turno_id, alvo_tipo)` e `unique (turno_id, autor_id)`). Reenvio do mesmo valor recebe 200; valor divergente recebe `409 avaliacao_ja_registrada`.
- **Filtro de Bloqueio em `perfil_publico`:** Totalmente implementado e protegido com 404 em caso de bloqueio bidirecional (PR #104, teste 550).
- **Check-out fora da janela:** Recusado com `422 fora_da_janela`. O alerta cron `alertar_fim_sem_checkout` monitora turnos encerrados sem check-out.
- **Apenas quatro operações sem RPC própria nem Edge Function:** `pedirCodigo` (`/otp`),
  `confirmarCodigo` (`/verify`) e `renovarSessao` (`/token`), que são endpoints nativos do Supabase
  Auth, e `listarFuncoes` (`/funcao`), que é leitura direta por PostgREST — tabela `public.funcao` em
  `supabase/migrations/20260922150300_catalogo_e_disponibilidade.sql:8` e política `funcao_leitura` em
  `supabase/migrations/20260922200100_politicas_de_leitura.sql:37`. `entrarDemonstracao` **não** entra
  nesta lista, ao contrário do que este documento afirmava até 06/10: ela tem Edge Function em
  `supabase/functions/entrar-demonstracao/index.ts`. O número quatro sempre esteve certo; a lista
  nominal estava errada em um item, e o erro é anterior à 0.2.38. Medido em 08/10 na `develop` em
  `f6525a8`, com os `paths` lidos de `git show f6525a8:contrato/openapi.yaml` e a Edge Function
  conferida com `git ls-tree --name-only origin/develop supabase/functions/entrar-demonstracao/`.
  Todas as 44 operações com corpo 200 ao alcance do portão possuem RPC dedicada no banco.

---

## Pendências fora do código

1. **Credenciais para Deploy Remoto:** Execução no ambiente remoto `frila-dev` e `frila-prod` depende de `SUPABASE_ACCESS_TOKEN` válido configurado no ambiente.
2. **Revisão da Júlia:** Revisão da lista de termos bloqueados do filtro de texto ofensivo (`ggEzge6h`).
3. **Publicação da Bancada:** Push de notas no repositório `FrilaApp/Bancada` requer autenticação local.

---

## Por onde continuar

1. **Acompanhar a conclusão do Lote 6 (PR #157):** Finalização da expansão das recusas críticas pelo Time A e revisão cruzada independente pelo Time B.
2. **Homologação e Deploy no `frila-dev`:** Com a `develop` avançada e o SMTP próprio funcional, sincronizar as migrações no projeto remoto `jcobftbhbqdikratzizz`.
3. **Frontend e Clientes Mobile:** As telas de contestação (suspensão e revisão de despacho com Opção B) e a tela de exportação de turnos (com janela regulamentar de 30 dias) estão com contratos espelhados até a **0.2.38** e backends 100% disponíveis.

