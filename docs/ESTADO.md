# Estado do backend — 01/11/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`CLAUDE.md`](../CLAUDE.md); aqui fica o que muda.

---

## Em uma linha

**A `develop` é o tronco e está à frente do `main` por 71 commits.** O `main` recebeu o PR #308
(`release/backend-v1.0.0`) em 19/10/2026 (`8d19626`). A `develop` (ref `c25ef14` em 01/11/2026) possui
**123 migrações**, **198 arquivos pgTAP** no total em `supabase/tests` (197 de regras + 1 de carga em `gerar_df.sql`),
**10 Edge Functions** (9 expostas + `_compartilhado`), **279 testes em Deno** (verde) e **56 scripts** em `scripts/`.

Os números abaixo foram consolidados e remedidos em 01/11/2026 (commit de referência `c25ef14` na `develop`):

| | | Comando |
|---|---|---|
| Commits à frente do `main` | **71** (em 01/11, ref `c25ef14`) | `git rev-list --count origin/main..origin/develop` |
| Migrações na `develop` | **123** (veja `scripts/migracoes-sem-colisao.sh`, ref `c25ef14`) | `git ls-tree -r --name-only origin/develop -- supabase/migrations \| grep -c '\.sql$'` |
| pgTAP | **198 arquivos** (197 de regras + 1 de carga, ref `c25ef14`), verde | `find supabase/tests -name "*.sql"` / `supabase test db` |
| Portão `contrato-responde.sh` | **151 recusas vigiadas e alcançadas**, verde | 151 de 151 vigiados e alcançados (100% de cobertura; 16 isentas, 0 não vigiadas de 167 declaradas), 46 de 50 respostas 200 validadas, 37 de 37 coleções |
| Testes em Deno das Edge Functions | **279** na suíte da develop, verde | `ok \| 279 passed \| 0 failed`, medido com `deno test --allow-all --no-check` |
| Edge Functions | **10** (inclui `limpar-contas-orfas` e `_compartilhado`) | `git ls-tree -d --name-only origin/develop:supabase/functions \| wc -l` |
| Testes unitários em `exportar-turnos` | **44**, verde | `deno test supabase/functions/exportar-turnos/index_test.ts` |
| Scripts em `scripts/` | **56** arquivos `.sh` | `git ls-tree -r --name-only origin/develop -- scripts \| grep -c '\.sh$'` |
| Contrato espelhado | **0.2.46** (sincronizado com o canônico no docs via PR #342 / PR #364) | `sed -n 's/^  version: *//p' contrato/openapi.yaml` |

Um aviso sobre a contagem de pgTAP: `supabase/tests/*.sql` tem **197** arquivos de teste de regras,
e alcança **198** com `supabase/tests/carga/gerar_df.sql`, que é gerador de carga e não teste de regra.

> ## 🟢 O espelho do contrato está em 0.2.46 (alinhado com o canônico em frila-docs)
>
> O contrato espelhado localmente em `contrato/openapi.yaml` está na versão **0.2.46** (incorporado no PR #342 / commit `4ddc9e5`,
> trazendo push FCM data-only para Android e canais por tipo, RN15).
> O checksum SHA-256 está perfeitamente alinhado com `contrato/openapi.yaml.sha256`:
> `8aa49e0c39e87824a00b0d66b6f98846d92f8ce0866a000a12399933fec24e10`.
>
> | | Versão | Origem | SHA-256 |
> |---|---|---|---|
> | espelho, `contrato/openapi.yaml` na `develop` | **0.2.46** | `frila-backend` (commit `4ddc9e5`) | `8aa49e0c39e87824a00b0d66b6f98846d92f8ce0866a000a12399933fec24e10` |
> | canônico, `FrilaApp/frila-docs · api/openapi.yaml` | **0.2.46** | `frila-docs` (commit `760b0b4`) | `8aa49e0c39e87824a00b0d66b6f98846d92f8ce0866a000a12399933fec24e10` |

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
>    pelo Cenário 11 de `scripts/corrida-ciclo.sh`, garantindo que dois toques simultâneos de
>    `republicar_posicoes_restantes` com chaves diferentes resultem em apenas uma vaga republicada.

---

## Onde cada coisa parou

### Entregas Recentes e Marcos Consolidados (até 16/10)

O repositório conta com mais de 180 PRs mergeados (183 em 16/10, ref develop `7e011ea`; datas de merge abaixo em horário de Brasília / BRT), com cobertura integral do contrato, novas RPCs, propostas de escala da v1.1/v1.2 e consolidação do mapa pgTAP:

1. **Lotes 6 a 10 de Recusas Críticas e Endurecimento do Portão (#157, #159, #163, #164, #165, #167):**
   Expansão completa das recusas críticas no `contrato-responde.sh`, saltando de 81 para 151 pares vigiados e alcançados, cobrindo 100% dos pares possíveis do banco (com 16 isenções técnicas justificadas em `contrato_responde.py` e 0 não vigiados). O portão passou a falhar estritamente na CI caso surjam novas recusas sem cobertura ou sem isenção justificada. Acompanhado pelas suítes pgTAP `490` a `494`.
2. **PR #161 (Modo Seleção em Urgência · merge em 07/10):**
   Publicação de vagas e reabertura com menos de 24h para o início do turno são forçadas para o modo urgência (`D4=C`, `D5=A`), recusando seleção manual com `422 modo_indisponivel`. Migração `20261007110000_modo_selecao_reabertura_urgencia.sql`.
3. **PR #169 (Suporte por e-mail a partir do turno / Contrato 0.2.40 · merge em 09/10):**
   Implementação da RPC `abrir_suporte` (Opção C, cartão `vN1yH4d3`, RF23, UC14), permitindo ao contratante ou profissional abrir chamado com categoria predefinida e sem texto livre (LGPD/RN15). Retorna `protocolo` (UUID) e `protocolo_curto` (8 caracteres hexadecimais em maiúsculas). Migrações `20261008100000_categoria_suporte_e_origem_ocorrencia.sql` e `20261008110000_abrir_suporte.sql`. Suíte pgTAP `620_abrir_suporte.sql` (26 testes) e par vigiado `abrirSuporte:422`.
4. **PR #170 (Republicar Posições Restantes / Contrato 0.2.41 · merge em 10/10):**
   Implementação da RPC `republicar_posicoes_restantes(vaga_id, chave)` (cartão `D1-C`), permitindo ao contratante reabrir posições remanescentes de vaga fechada sem candidatos em seleção, clonando a vaga em modo urgência com rastreabilidade pela coluna `vaga.republicada_de` e exibição consolidada no painel. Migrações `20261009100000_vaga_republicada_de_e_republicacao_da_selecao.sql` e `20261009110000_republicar_posicoes_restantes_e_painel.sql`. Suíte pgTAP `630_republicar_posicoes_restantes.sql` (55 testes), Cenário 11 em `scripts/corrida-ciclo.sh` e pares vigiados `republicarPosicoesRestantes:401/403/404/422`.
5. **PR #171 (Operação do Suporte por E-mail P6 · merge em 10/10):**
   Ajuste operacional de `consultar-ocorrencias.sql` com join interno no autor e exibição de protocolo curto de 8 caracteres; criação do script `fechar-chamado-sem-email.sql` para encerramento manual com resultado `sem_email_recebido` após o prazo regulamentar de 5 dias úteis (D16, SU-RN10); e documentação completa de procedimentos e expurgo seguro LGPD na caixa `suporte@frilabr.com` em `supabase/operacao/equipe-frila.md` (D9, SU-RN11).
6. **PR #178 (Push com mutable-content no iOS / h6RoObK6 · merge em 14/10):**
   Envio de `"mutable-content": 1` em `apns.payload.aps` no payload APNs via FCM v1 no motor de despacho (`supabase/functions/despachar/index.ts` e testes Deno), permitindo à Notification Service Extension do iOS interceptar e tratar o aviso antes da exibição para validação de `vinculo_id` sem expor dados pessoais (RN15).
7. **PR #179 (Recusa de Contato e Link no Texto da Vaga J5 / pBXTS4vv · merge em 15/10):**
   Validação sintática em `privado.contem_contato_ou_link` integrada a `publicar_vaga`/`republicar_vaga` recusando telefones, e-mails e URLs em texto livre com `422 campo_invalido` (RN10, RN15). Migração `20261014160000_recusar_contato_e_link_texto_vaga.sql` e teste pgTAP `640_contato_e_link_texto_vaga.sql`.
8. **PR #180 e #196 (Robustez do Portão de Plano sob Carga / mhHuBOeG · merge em 15/10):**
   Correção de datas da carga sintética (`gerar_df.sql`) com datas relativas a `privado.agora()` para restaurar short-circuit e reduzir latência de 9.360 ms para 15.0 ms local (38.2 ms na CI); autoteste com 11 casos em `teste-planos-com-carga.sh` e aferição robusta com aquecimento prévio de buffers e critério do melhor de 3 baterias de 50 chamadas de `vagas_abertas` e 36 de `elegiveis` (#196).
9. **PR #181 (Fechamento de Vagas Expiradas sem Processo / D654gdGQ · merge em 15/10):**
   Correção em `privado.fechar_turnos_e_vagas()` para cancelar posições remanescentes que permaneceram em `estado = 'aberta'` após o término do turno (`fim_em <= privado.agora()`) e encerrar as vagas correspondentes (`estado = 'encerrada'`), eliminando resíduos perpétuos de vagas expiradas no índice GiST `vaga_ponto_publicada`. Migração `20261015100000_fechar_vagas_expiradas_sem_processo.sql` e teste pgTAP `650_fechamento_vaga_expirada_sem_processo.sql`.
10. **PR #182 (Atualização de Estado e Proposta do Vault · merge em 15/10):**
    Atualização de métricas e estado do backend em `docs/ESTADO.md` e formalização da proposta técnica em `docs/proposta-vault-agendador-secret.md` para migração do segredo `frila.agendador_secret` do GUC para o Supabase Vault, eliminando o erro de permissão 42501 no banco gerenciado.
11. **PR #183 (Otimização de Ciclo e Filtro de Despacho / Achados 2 e 3 · merge em 15/10):**
    Correção do laço de avaliação em `privado.fechar_turnos_e_vagas()` para evitar renotificação de `avaliacao_disponivel` com filtro de 7 dias e `not exists`, e filtro em `privado.verificar_saude()` para limitar a checagem de despachos retidos além do teto a vagas ativas e futuras (`publicada` com `inicio_em > agora`). Migração `20261015140000_correcao_ciclo_de_vida_achados_2_e_3.sql` e suíte pgTAP `660_ciclo_de_vida_achados.sql`.
12. **PR #184 (Segurança, Bloqueio Mútuo e Restrição de Privilégios · merge em 15/10):**
    Implementação da 107ª migração (`20261015150000_seguranca_bloqueio_e_privilegios.sql`), sanando os Achados 1 e 4 da Caçada de Segurança: bloqueio bidirecional entre contas com recusa imediata de candidaturas mútuas e revogação de privilégios de escrita indevidos concedidos a `anon`/`authenticated` em tabelas do catálogo. Teste pgTAP `670_seguranca_bloqueio_e_privilegios.sql`.
13. **PRs #186, #188 e #189 (Desenhos e Propostas de Arquitetura da v1.1/v1.2 · merge em 15/10):**
    Adição dos documentos de referência técnica para evolução do produto: `docs/proposta-escala-em-lote.md` (#186, cartão `6mi66YDp`), `docs/proposta-multiplos-membros.md` (#188, cartão `JpKoxqWo`) e `docs/desenho-verificacao-progressiva-rn14.md` (#189, cartão `GtWr3ZeJ`).
14. **PRs #192 e #194 (Endurecimento pgTAP e Mutantes · merge em 15/10):**
    Suítes `671_bloqueio_escolher_candidato_recusa_e_contato.sql` (#192) e `672_mutantes_sobreviventes_ciclo_e_texto.sql` (#194), eliminando mutantes sobreviventes nas rotinas de fechamento, moderação de texto e ciclo de vida.
15. **PRs #193 e #198 (Espelhos do Contrato 0.2.42 e 0.2.43 · merge em 15/10):**
    Integração dos contratos 0.2.42 (bloqueio de perfil no modo de seleção e alinhamento de corpo sem mudança de superfície em `privado.elegiveis`, #193) e 0.2.43 (liberação de relato sem filtro de termos ofensivos em contestação e denúncia, #198).
16. **PRs #195, #199 e #200 (Relatório de Carga 10x do DF e Medição de Triggers · merge em 15/10):**
    Elaboração de `docs/carga-10x.md` com análise de EXPLAIN sob volume de 1 milhão de profissionais e 200 mil vagas no DF (#195), registro documental da refutação empírica da recomendação 1 (#199) e medição de triggers sob carga 2x (#200) comprovando que ~80% a 88% do tempo do encerramento decorre de gatilhos por tupla (`audita_ciclo`, integridade referencial, expiração de candidaturas), fundamentando a decisão de não criar índices parciais no momento.
17. **PR #197 (Paridade Exaustiva de `privado.elegiveis` · merge em 15/10):**
    Teste pgTAP `680_elegiveis_paridade_e_comportamento.sql` validando a invariância de resultados e a refutação da reordenação da CTE de elegíveis sob carga.
18. **PR #201 (Proteção do Schema Privado · merge em 16/10):**
    Teste pgTAP `681_privilegios_tabelas_privado.sql` (320 linhas) comprovando a total ausência de privilégios de SELECT, INSERT, UPDATE e DELETE para o papel `authenticated` em todas as tabelas do schema `privado`.
19. **PR #202 (Ativação Automática de RLS por ensure_rls e public.rls_auto_enable · merge em 16/10):**
    Teste pgTAP `690_rls_auto_enable.sql` cobrindo a lacuna 1 do mapa pgTAP: validação de SECURITY DEFINER, ausência de EXECUTE para `anon`/`authenticated`, disparo do event trigger em `ddl_command_end` e ativação obrigatória de `relrowsecurity = true` em `CREATE TABLE` e `CREATE TABLE AS` sem afetar tabelas temporárias.

### Entregas Recentes e Marcos Consolidados (17/10 a 31/10)

1. **PR #308 (Release Backend v1.0.0 · merge em 19/10):**
   Sincronização e release v1.0.0 em `main` (`8d19626`), consolidando as primeiras 119 migrações e toda a infraestrutura base de produção.
2. **PR #339 (E-mail Operacional da Equipe Frila · merge em 31/10):**
   Unificação do endereço de contato operacional para `suporte@frilabr.com` e saneamento das referências documentais e operacionais.
3. **PR #342 (Espelho do Contrato 0.2.46 · merge em 31/10):**
   Espelhamento do contrato canônico 0.2.46 do `frila-docs` em `contrato/openapi.yaml` (SHA-256 `8aa49e0c39e87824a00b0d66b6f98846d92f8ce0866a000a12399933fec24e10`), cobrindo push FCM data-only para Android e canais por tipo (RN15).
4. **PR #350 (Expansão pgTAP para Funções Auxiliares do Schema Privado · merge em 31/10):**
   Novas suítes cobrindo preservação de dígito 9 na normalização alfanumérica, rejeição de documento cercado por espaços, máscara de valor em reais e validação de status HTTP 422 em campos obrigatórios.
5. **PR #351 (CI de Autenticação Remota · merge em 31/10):**
   Inclusão de `scripts/conferir-auth-remoto.sh` e testes automatizados para verificação das configurações de autenticação no Supabase.
6. **PR #364 (Atualização Factual de Métricas e Estado do Backend · merge em 31/10):**
   Atualização de métricas e documentação de alinhamento com base na ref `ca11a68`.

### A fila de PRs aberta em 01/11/2026 (madrugada)

Medida com `gh pr list --state open` em 01/11/2026 (22 PRs abertos no total):

- **Release e Sincronização:**
  - **PR #367** (`develop` -> `main` · Draft): Sincronização da develop com main (123 migrações, paridade Prod, 71 commits).
- **Infraestrutura, Observabilidade e Operação:**
  - **PR #368** (`feat/checagem-diaria-producao` · Draft): Script de checagem diária de produção de ~1 min com 7 checagens só de leitura e zero dados pessoais (Cartão 42).
  - **PR #359** (`feat/fumaca-prod-leitura` · Draft): Fumaça pós-deploy só de leitura (`scripts/fumaca-prod-leitura.sh`).
  - **PR #357** (`feat/script-pre-tag` · Draft): Portão pré-tag local (`scripts/pre-tag.sh`).
  - **PR #354** (`ci/auth-prod-sem-revisor` · Draft): Mover job de auth do prod para environment `frila-prod-leitura` sem revisor.
  - **PR #353** (`ci/backup-prod-diario` · Aberto): Adiciona workflow diário de backup lógico do `frila-prod` (#352).
  - **PR #371** (`sugestao/fix-p1-01-tar-portavel-backup-353` · Draft): Sugestão de portabilidade do empacotamento tar no Linux e macOS (P1-01 sobre #353).
  - **PR #372** (`sugestao/fix-p1-02-p1-03-token-e-zero-escrita-354` · Draft): Sugestão de escopo `auth_config_read` e teste fail-closed (P1-02, P1-03 sobre #354).
- **Banco de Dados e Negócio:**
  - **PR #369** (`feat/coordenadas-meus-turnos-cartao-72` · Draft): Coordenadas exatas do estabelecimento em `meus_turnos` respeitando RN06 e LGPD (Cartão 72).
  - **PR #365** (`feat/purga-notificacao-60-dias` · Draft): Purga periódica de notificações com mais de 60 dias (K-001).
  - **PR #366** (`fix/sanitizar-texto-vaga-exclusao` · Draft): Sanitizar texto livre de vagas na exclusão de conta (K-001).
  - **PR #361** (`feat/comparar-migracoes` · Draft): Adiciona `scripts/comparar-migracoes.sh` e autoteste.
  - **PR #360** (`feat/margem-termino-janela-rnf12` · Draft): Adiciona margem de término opcional na janela RNF12.
  - **PR #363** (`fix/desativar-cron-alter-job` · Draft): Usa `cron.alter_job` para desativar tarefas nos testes de corrida.
- **Qualidade, Segurança e Testes:**
  - **PR #370** (`test/auditoria-seguranca-banco-n039` · Draft): Auditoria de segurança do banco com testes novos de catálogo e RLS (N-039).
  - **PR #373** (`chore/shellcheck-scripts-qualidade` · Draft): Saneamento de shellcheck nos 56 scripts e portão opcional de CI (N-045 item 1).
  - **PR #374** (`test/edge-functions-lacunas-deno` · Draft): Cobertura de lacunas em Deno nas 10 Edge Functions (+30 testes, 309 total) (N-045 item 2).
- **Documentação e Governança:**
  - **PR #362** (`docs/links-e-referencias-quebradas` · Draft): Corrige links quebrados e referências a arquivos renomeados.
  - **PR #358** (`docs/template-migracao-corretiva-rollback` · Draft): Template de migração corretiva e rollback para a frente.
  - **PR #356** (`docs/atualiza-docs-ambiente-e-revisores` · Draft): Atualiza status de frila-prod e revisores do environment.
  - **PR #355** (`docs/changelog-1-1-0` · Draft): Prepara versão 1.1.0 no changelog.
  - **PR #329** (`docs/agents-md-unico` · Aberto): Regras do time num AGENTS.md único.

### A fila de PRs aberta em 16/10 (histórico)

Medida com `gh pr list --state open` em 16/10:

- **PR #185** (`chore/retencao-demonstracao-e-falhas` · Draft): Retenção de demonstração e limpeza de falhas [AGUARDA DECISÃO DO DONO].
- **PR #187** (`feat/vault-agendador-secret` · Draft): Implementação do segredo do agendador via Supabase Vault [AGUARDA DECISÃO DO DONO].
- **PRs da ronda noturna pgTAP e CI (#203 a #212):** PRs pequenos e focados cobrindo as lacunas do mapa pgTAP (#203 a #206, #208 a #210), sanitização de logs e tetos em Edge Functions (#207) e endurecimento de CI e dependências Deno (#211, #212).

---

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 · **123** migrações na `develop` (veja `scripts/migracoes-sem-colisao.sh`), **119** no `main` (em 31/10/2026) |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` · SMTP próprio ativo (`smtp.gmail.com:465`, código de 6 dígitos) · **Entrega bloqueada** por `frila.agendador_secret` (vide abaixo) |
| `frila-prod` | `hbjkkcenbudiezmamiak` · `sa-east-1` · criado em 24/09, **vazio**: aguarda esteira de deploy por tag |

**Desde 29/09 o `frila-dev` manda e-mail por SMTP próprio** (PR #81):
- Envio: `smtp.gmail.com:465`, conta `frilaverificacao@gmail.com`, remetente "Frila".
- Conteúdo: código de seis dígitos (`{{ .Token }}`).
- Validade: 15 minutos.

> ### ⚠️ Bloqueio da entrega contínua no `frila-dev`: `frila.agendador_secret`
>
> A aplicação das migrações e entrega no ambiente remoto `frila-dev` via `./scripts/aplicar-remoto.sh` está **bloqueada**.
>
> O script verifica previamente a existência de `frila.agendador_secret` em `pg_db_role_setting` antes de autorizar as migrações (para garantir que `publicar_vaga` não falhe no enfileiramento pós-commit). Porém, no Supabase hospedado, o usuário `postgres` não possui permissões de superusuário (`superuser`), e a tentativa de configurar parâmetros GUC em nível de banco via `ALTER DATABASE postgres SET frila.agendador_secret = ...` falha com:
> ```
> ERROR: 42501: permission denied to set parameter "frila.agendador_secret"
> ```
> Como consequência, as migrações não podem avançar no `frila-dev` enquanto o segredo depender de GUC.
>
> **Solução proposta:** Foi redigida a proposta técnica em [`docs/proposta-vault-agendador-secret.md`](proposta-vault-agendador-secret.md) para migrar a leitura do segredo compartilhado para a extensão nativa **Supabase Vault** (`vault.decrypted_secrets`), com fallback de compatibilidade para os testes locais. O item aguarda decisão/aprovação do dono (registrado em `DECISOES.md`).
> *(Nota de segurança: nenhum valor de segredo real é registrado em arquivos de documentação ou histórico).*

---

## O contrato em detalhes

Versão espelhada: **0.2.46** em `contrato/openapi.yaml` (sincronizada com o canônico em `FrilaApp/frila-docs · api/openapi.yaml` no PR #342 / commit `4ddc9e5`, SHA-256 `8aa49e0c39e87824a00b0d66b6f98846d92f8ce0866a000a12399933fec24e10`).

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
| **0.2.42** | bloqueio de perfil no modo de seleção e alinhamento de corpo sem mudança em `privado.elegiveis` | #193 |
| **0.2.43** | liberação de relato sem filtro de termos ofensivos em contestação e denúncia | #198 |
| **0.2.44** | documentação de recusas de presença em `fazer_checkin`, `confirmar_checkin_manual` e `fazer_checkout` (só texto) | #92 |
| **0.2.45** | adições compatíveis no cadastro (sinal_idade) e telemetria do titular (eventos_app em MeusDados) | #302, #304 |
| **0.2.46** | push FCM data-only para Android e canais por tipo (RN15) | #342 (mergeado em develop) |

---

## O que existe no banco

Medido no banco de desenvolvimento com a `develop` em `c25ef14`:

- **22 tabelas** em `public`:
  ```
  avaliacao · bloqueio · candidatura · despacho · disponibilidade · dispositivo
  entrada_demonstracao · equipe_confianca · estabelecimento · evento · evento_app
  funcao · membro_estabelecimento · notificacao · ocorrencia · pedido_de_exclusao
  posicao · profissional · profissional_funcao · turno · usuario · vaga
  ```
- **123 migrações** aplicadas sequencialmente sem colisão.
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

Medição consolidada da bateria em 01/11/2026 (ref `c25ef14` na `develop`, comparada a 16/10 ref `7e011ea`):

| Comando | O que garante | Medida em 16/10 (ref `7e011ea`) | Medida em 01/11 (ref `c25ef14`) |
|---|---|---|---|
| `supabase test db` | pgTAP | **108** arquivos de regras (109 no prove), **2.980** asserções verdes | **197** arquivos de regras (198 no total com `gerar_df.sql`), verde |
| `./scripts/contrato-responde.sh` | respostas casam com o contrato | **46 de 50** respostas 200, **151 de 151** vigiados, **37 de 37** coleções | **46 de 50** respostas 200 validadas, **151 de 151** recusas vigiadas e alcançadas, **37 de 37** coleções exercitadas |
| `deno test --allow-all --no-check` | Edge Functions em Deno | **179** testes verdes | **279** testes verdes (0 falhas; 44 em `exportar-turnos`) |
| `./scripts/teste-contrato-promete.sh` | autoteste da direção contrato-à-frente | 9 de 9 casos verdes | **9 de 9** casos verdes |
| `./scripts/teste-contrato-responde.sh` | autoteste de schemas do contrato | 14 de 14 casos verdes | **14 de 14** casos verdes |
| `./scripts/teste-contrato-acompanha.sh` | PR que altera `public` acompanha contrato | 19 de 19 casos verdes | **19 de 19** casos verdes |
| `./scripts/relogio-em-testes.sh` | imunidade contra bombas-relógio de relógio | **108** arquivos pgTAP imunizados | **197** arquivos pgTAP imunizados |
| `./scripts/migracoes-sem-colisao.sh` | carimbos de migração únicos | **123** carimbos distintos | **123** carimbos distintos sem colisão |
| `./scripts/migracoes-imutaveis.sh` | migrações passadas não foram alteradas | verde | verde |
| `./scripts/planos-com-carga.sh` | caminho quente sob volume sintético do DF (PR #180, #196) | verde na CI | verde na CI (aquecimento prévio, melhor de 3 baterias) |

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
| `usuario.sinal_idade`, `usuario.idade_aferida_por`, `usuario.idade_aferida_em` | prova de como a idade foi aferida no cadastro (ECA Digital, cartão LQlwDaYZ): só a faixa que o aparelho respondeu (`dezoito_ou_mais`, `recusou`, `indisponivel`), o método (`aparelho` ou `declaracao`) e o instante; nunca data ou identificador do aparelho (Decreto 12.880/2026, art. 24 §3º); não sai em `conta_em_json` |
| `turno.checkin_recebido_em` | `checkin_em` é a hora do toque; sem as duas, registro offline vira indistinguível |
| `turno.checkout_recebido_em` | o mesmo, do outro lado |
| `posicao.reaberta_por_atraso_de` | `reabrir_por_atraso` (e8XpOZJN): a posição nova sabe de qual falta nasceu; aceita candidato depois do início até 1 h antes do fim |
| `vaga.rodada_despacho` | rodada de despacho (9DbPXis7): 1 na publicação, incrementada a cada `reabrir_por_atraso` |
| `despacho.rodada` | unicidade do despacho por `(vaga_id, profissional_id, rodada)` |
| `notificacao.rodada` | marca de envio de vaga por rodada para não suprimir push da rodada nova |
| `turno.a_caminho_em` | aviso "estou a caminho" (h53CJVP7, contrato 0.2.25) |
| `vaga.republicada_de` | referência à vaga de origem na republicação de posições restantes (cartão D1-C, contrato 0.2.41) |

E alinhamentos consolidados de negócio:
- **Suporte por e-mail a partir do turno (Opção C, contrato 0.2.40, PR #169 e P6 no PR #171):** Chamados abertos via RPC `abrir_suporte` gravam ocorrência com `tipo = 'suporte'`, `origem = 'app'`, `turno_id`, categoria e sem texto livre (`relato` nulo, LGPD/RN15). A fila de operação (`consultar-ocorrencias.sql`) expõe `protocolo_curto` (8 hexadecimais), `origem`, `turno_id` e prazo legal de 5 dias úteis. Chamados sem envio de e-mail pelo usuário são encerrados manualmente pela Equipe via `fechar-chamado-sem-email.sql` com `resultado = 'sem_email_recebido'` (D16, SU-RN10). E-mails tratados são expurgados da caixa `suporte@frilabr.com` e lixeira conforme diretriz de retenção da LGPD (D9, SU-RN11).
- **Republicação de posições restantes (D1-C, contrato 0.2.41, PR #170):** Permite ao contratante reabrir posições restantes de vaga fechada sem candidatos em seleção ativa via RPC `republicar_posicoes_restantes(vaga_id, chave)`. Cria nova vaga em modo urgência com posições clonadas vinculadas por `vaga.republicada_de`, validando recusas `401` (`nao_autenticado`), `403` (`sem_permissao`), `404` (`nao_encontrado`) e `422` (`republicacao_indisponivel`), e mantendo o histórico na vaga original.
- **Avaliação:** Um voto por lado do turno (`unique (turno_id, alvo_tipo)` e `unique (turno_id, autor_id)`). Reenvio do mesmo valor recebe 200; valor divergente recebe `409 avaliacao_ja_registrada`.
- **Filtro de Bloqueio em `perfil_publico`:** Totalmente implementado e protegido com 404 em caso de bloqueio bidirecional (PR #104, teste 550).
- **Check-out fora da janela:** Recusado com `422 fora_da_janela`. O alerta cron `alertar_fim_sem_checkout` monitora turnos encerrados sem check-out.
- **Apenas quatro operações sem RPC própria nem Edge Function:** `pedirCodigo` (`/otp`), `confirmarCodigo` (`/verify`) e `renovarSessao` (`/token`), que são endpoints nativos do Supabase Auth, e `listarFuncoes` (`/funcao`), que é leitura direta por PostgREST. `entrarDemonstracao` possui Edge Function própria em `supabase/functions/entrar-demonstracao/index.ts`. Todas as 46 operações com corpo 200 ao alcance do portão possuem RPC dedicada no banco.
- **Avisos push mutáveis no iOS (h6RoObK6, contrato 0.2.30):** O payload APNs enviado via FCM inclui `"mutable-content": 1` em `apns.payload.aps` junto de `sound` e `badge`.
  Isso permite à Notification Service Extension do iOS interceptar e tratar o aviso antes da exibição para validação de `vinculo_id` sem expor dados pessoais (RN15).

---

## Pendências fora do código

1. **Desbloqueio de Deploy no `frila-dev` (Decisão do dono):** Aval da proposta técnica em [`docs/proposta-vault-agendador-secret.md`](proposta-vault-agendador-secret.md) para migração da leitura do segredo de GUC para Supabase Vault (`vault.decrypted_secrets`), resolvendo o erro 42501 no Postgres hospedado e liberando a execução do script `scripts/aplicar-remoto.sh` (registrado em `DECISOES.md`).
2. **Push com mutable-content no iOS (`h6RoObK6`):** O backend foi entregue e mergeado no PR #178 (`mutable-content: 1`). A conclusão depende da esteira de iOS (criação do target Notification Service Extension, App Group e aprovação de design para o texto neutro sem dados pessoais).
3. **Credenciais para Deploy Remoto:** Execução no ambiente remoto `frila-dev` e `frila-prod` depende de `SUPABASE_ACCESS_TOKEN` válido configurado no ambiente.
4. **Revisão da Júlia:** Revisão da lista de termos bloqueados do filtro de texto ofensivo (`ggEzge6h`).
5. **Publicação da Bancada:** Push de notas no repositório `FrilaApp/Bancada` requer autenticação local.

---

## Por onde continuar

1. **Homologação e Deploy no `frila-dev`:** Com a aprovação da proposta do Vault e o desbloqueio do erro 42501, aplicar as 123 migrações no projeto remoto `jcobftbhbqdikratzizz` via `scripts/aplicar-remoto.sh`.
2. **Frontend e Clientes Mobile:** As novas funcionalidades (recusa de dados de contato e links em texto livre no PR #179, fechamento automático de vagas expiradas no PR #181, e suporte a push mutável no PR #178) estão 100% disponíveis na `develop`.
3. **Backlog de Tarefas Backend sem Decisão do Dono:** Seguir com a execução contínua de tarefas que independem de decisões de negócio/infraestrutura externa.

