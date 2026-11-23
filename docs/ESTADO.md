# Estado do backend — 23/11/2026

Onde o trabalho parou e o que a próxima sessão precisa saber. As regras duráveis estão
no [`AGENTS.md`](../AGENTS.md); aqui fica o que muda. O que o produto é hoje, e o que fica fora
da versão em andamento, está em
[`produto/AGORA.md`](https://github.com/FrilaApp/frila-documentacao/blob/main/produto/AGORA.md)
do `frila-documentacao`: este arquivo não repete esse escopo.

> **Como ler as datas deste arquivo.** Os números da seção "Em uma linha", da tabela de portões e do
> contrato foram remedidos em **23/11/2026** na `develop` em `e625e7e`, com o comando ao lado de cada
> um. Trecho que depende de banco, de ambiente remoto (`frila-dev`, `frila-prod`) ou de uma bateria
> que precisa de `supabase db reset` **não foi remedido** e leva a marca "não remedido em 23/11/2026",
> com a data e a ref da última medição quando o arquivo as tem. Número sem a marca vem de 01/11/2026
> (ref `c25ef14`) ou de data anterior, e vale como histórico, não como estado de hoje.
>
> **A `develop` pode andar depois da medição.** Os contadores abaixo valem para `e625e7e` (PR #589, mesclado em
> 23/11/2026). Rode os comandos da tabela para a ponta de hoje.

---

## Em uma linha

**A `develop` é o tronco; o `main` é o ESPELHO DO PROD (decisão do time, 23/11/2026).** A cada pacote aplicado no Prod,
abre-se um PR `prod/pacote-N` → `main` (merge commit, sem force), logo depois do Prod. O `main` está em `10fe6fc` (merge do
#597, 23/11/2026): a árvore do pacote 23 (`d80626e` = `7d1c57f` sem a migração `20261118100000`) mais o #582 (só testes)
e a remoção do pgTAP 890 e da corrida do #571. `supabase/migrations` e `supabase/functions` do `main` são idênticos ao `d80626e`
(`git diff` vazio, mostrado no #597). Medido com `git rev-list --left-right --count origin/main...origin/develop` em
23/11/2026: **7** commits só no `main` (os 3 merges de release antigos e os 4 do pacote 23) e **20** só na `develop`.
O último release anterior foi o PR #308 (`release/backend-v1.0.0`) em 19/10/2026 (`8d19626`); as tags `backend-v*` existentes
são `backend-v1.1.0` e `backend-v1.1.1`. Nenhuma tag `backend-v*` foi criada para o pacote 23 (entrou por roteiro).
A `develop` (ref `af6c9fd` em 23/11/2026, tudo conferido de novo nesse commit) possui **241 migrações** (o `main`, 236, as do Prod),
**306 arquivos pgTAP** em `supabase/tests` (304 de regras + 2 de carga em `carga/`: `gerar_df.sql` e `gerar_casa_pesada.sql`),
**13 Edge Functions** (14 diretórios com `_compartilhado`) e **94 scripts `.sh`** em `scripts/` (113 arquivos no total, `find scripts -type f`).
Os **563 testes em Deno** (verde, 3 ignorados) foram medidos em `e625e7e` e **não** foram remedidos depois das mesclas do #586 e do #587.

Os números abaixo foram remedidos em 23/11/2026 (commit de referência `e625e7e` na `develop`), exceto onde a
linha diz "não remedido em 23/11/2026":

| | | Comando |
|---|---|---|
| Commits à frente do `main` | **20** (em 23/11, ref `af6c9fd`, depois do #597: o `main` passou a espelhar o Prod; eram 225 antes do espelho, em `e625e7e`, 205 em 18/11 e 71 em 01/11) | `git rev-list --count origin/main..origin/develop` |
| Commits na `develop` desde `c25ef14` (01/11) | **266** (ref `af6c9fd`, 23/11) | `git rev-list --count c25ef14..origin/develop` |
| Migrações na `develop` | **241**, de `20260922150000` a `20261123150000` (veja `scripts/migracoes-sem-colisao.sh`) | `git ls-tree -r --name-only origin/develop -- supabase/migrations \| grep -c '\.sql$'` |
| Migrações no `main` | **236** (23/11, as do Prod; eram 130 até o #597) | `git ls-tree -r --name-only origin/main -- supabase/migrations \| grep -c '\.sql$'` |
| pgTAP | **306 arquivos** (304 de regras + 2 de carga), último `895_remover_upload_verificacao_identidade.sql`. Resultado de `supabase test db`: não remedido em 23/11/2026 (precisa do banco local da `develop`, compartilhado entre sessões; verde em 01/11 com 198 arquivos) | `find supabase/tests -name "*.sql" \| wc -l` |
| Portão `contrato-responde.sh` | **não remedido em 23/11/2026** (precisa de `supabase db reset`, que é do dono do banco local). Em 01/11: 151 de 151 recusas vigiadas e alcançadas, 46 de 50 respostas 200 validadas, 37 de 37 coleções. O que se mede sem banco (remedido em 23/11/2026, igual a 18/11): `VIGIADAS` tem **268** entradas, `ISENTAS` **24** e `PENDENTES` **2** em `scripts/contrato_responde.py` | `cd scripts && python3 -c "import contrato_responde as m; print(len(m.VIGIADAS), len(m.ISENTAS), len(m.PENDENTES))"` (precisa de `jsonschema`) |
| Testes em Deno das Edge Functions | **563** passaram, **0** falharam, **3** ignorados | `deno test --allow-all --no-check --lock=deno.lock --frozen supabase/functions/ supabase/templates/` |
| Edge Functions | **13** (14 diretórios, com `_compartilhado`): `despachar`, `entrar-demonstracao`, `enviar-email`, `enviar-midia`, `enviar-push`, `excluir-conta`, `exportar-meus-dados`, `exportar-turnos`, `expurgar-midias`, `ler-midia`, `limpar-contas-orfas`, `moderar-midia`, `saude` | `git ls-tree -d --name-only origin/develop:supabase/functions \| wc -l` |
| Testes unitários em `exportar-turnos` | **55**, verde | `deno test --allow-all --no-check --lock=deno.lock --frozen supabase/functions/exportar-turnos/index_test.ts` |
| Scripts em `scripts/` | **94** arquivos `.sh` (113 arquivos no total, `find scripts -type f`) | `git ls-tree -r --name-only origin/develop -- scripts \| grep -c '\.sh$'` |
| Contrato espelhado | **0.2.107**, byte a byte igual ao canônico do `frila-documentacao` (`api/openapi.yaml` na `main`, `87eeb69`, 23/11/2026) | `sed -n 's/^  version: *//p' contrato/openapi.yaml` |

Um aviso sobre a contagem de pgTAP: `supabase/tests/*.sql` tem **304** arquivos de teste de regras,
e alcança **306** com `supabase/tests/carga/gerar_df.sql` e `supabase/tests/carga/gerar_casa_pesada.sql`, que são geradores de carga e não testes de regra.

> ## 🟢 O espelho do contrato está em dia com o canônico (0.2.107)
>
> Medido em 23/11/2026: o contrato espelhado em `contrato/openapi.yaml` na `develop` está na versão
> **0.2.107** (`info.version`) e o arquivo é idêntico ao canônico do frila-documentacao
> (mesmo SHA-256; o espelho tem 512.461 bytes). Em 18/11/2026 o espelho estava na 0.2.105.
>
> | | Versão | Origem | SHA-256 |
> |---|---|---|---|
> | espelho, `contrato/openapi.yaml` na `develop` (`e625e7e`) | **0.2.107** | `frila-backend` | `17297b13eb2d656c159de57c6d0a61cf6491de32b50e7634d8b612932af21c0a` |
> | canônico, `FrilaApp/frila-documentacao · api/openapi.yaml` na `main` (`87eeb69`) | **0.2.107** | `frila-documentacao` | `17297b13eb2d656c159de57c6d0a61cf6491de32b50e7634d8b612932af21c0a` |
>
> Comandos: `shasum -a 256 contrato/openapi.yaml` e, para o canônico,
> `gh api repos/FrilaApp/frila-documentacao/contents/api/openapi.yaml -H 'Accept: application/vnd.github.raw' | shasum -a 256`.
> Em 23/11/2026 há um PR de espelho aberto, o #515 (Draft), cujo título cita o contrato 0.2.98, anterior à
> 0.2.107 que o espelho já tem. Os #513 (espelho 0.2.106) e #516 (espelho 0.2.107) foram mesclados em 23/11/2026
> (`gh pr view <n> --json state,mergedAt`).

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

> Os marcos abaixo vão até 01/11/2026 e **não foram reescritos em 23/11/2026**, salvo a lista de 18 a 23/11 mais
> abaixo. O que entrou na `develop` depois de 01/11 são 256 commits (`git log --oneline c25ef14..origin/develop`);
> o escopo do produto, no `produto/AGORA.md`.

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
    Atualização de métricas e estado do backend em `docs/ESTADO.md` e formalização da proposta técnica em `docs/historico/proposta-vault-agendador-secret.md` para migração do segredo `frila.agendador_secret` do GUC para o Supabase Vault, eliminando o erro de permissão 42501 no banco gerenciado.
11. **PR #183 (Otimização de Ciclo e Filtro de Despacho / Achados 2 e 3 · merge em 15/10):**
    Correção do laço de avaliação em `privado.fechar_turnos_e_vagas()` para evitar renotificação de `avaliacao_disponivel` com filtro de 7 dias e `not exists`, e filtro em `privado.verificar_saude()` para limitar a checagem de despachos retidos além do teto a vagas ativas e futuras (`publicada` com `inicio_em > agora`). Migração `20261015140000_correcao_ciclo_de_vida_achados_2_e_3.sql` e suíte pgTAP `660_ciclo_de_vida_achados.sql`.
12. **PR #184 (Segurança, Bloqueio Mútuo e Restrição de Privilégios · merge em 15/10):**
    Implementação da 107ª migração (`20261015150000_seguranca_bloqueio_e_privilegios.sql`), sanando os Achados 1 e 4 da Caçada de Segurança: bloqueio bidirecional entre contas com recusa imediata de candidaturas mútuas e revogação de privilégios de escrita indevidos concedidos a `anon`/`authenticated` em tabelas do catálogo. Teste pgTAP `670_seguranca_bloqueio_e_privilegios.sql`.
13. **PRs #186, #188 e #189 (Desenhos e Propostas de Arquitetura da v1.1/v1.2 · merge em 15/10):**
    Adição dos documentos de referência técnica para evolução do produto: `docs/historico/proposta-escala-em-lote.md` (#186, cartão `6mi66YDp`), `docs/historico/proposta-multiplos-membros.md` (#188, cartão `JpKoxqWo`) e `docs/desenho-verificacao-progressiva-rn14.md` (#189, cartão `GtWr3ZeJ`).
14. **PRs #192 e #194 (Endurecimento pgTAP e Mutantes · merge em 15/10):**
    Suítes `671_bloqueio_escolher_candidato_recusa_e_contato.sql` (#192) e `672_mutantes_sobreviventes_ciclo_e_texto.sql` (#194), eliminando mutantes sobreviventes nas rotinas de fechamento, moderação de texto e ciclo de vida.
15. **PRs #193 e #198 (Espelhos do Contrato 0.2.42 e 0.2.43 · merge em 15/10):**
    Integração dos contratos 0.2.42 (bloqueio de perfil no modo de seleção e alinhamento de corpo sem mudança de superfície em `privado.elegiveis`, #193) e 0.2.43 (liberação de relato sem filtro de termos ofensivos em contestação e denúncia, #198).
16. **PRs #195, #199 e #200 (Relatório de Carga 10x do DF e Medição de Triggers · merge em 15/10):**
    Elaboração de `docs/historico/carga-10x.md` com análise de EXPLAIN sob volume de 1 milhão de profissionais e 200 mil vagas no DF (#195), registro documental da refutação empírica da recomendação 1 (#199) e medição de triggers sob carga 2x (#200) comprovando que ~80% a 88% do tempo do encerramento decorre de gatilhos por tupla (`audita_ciclo`, integridade referencial, expiração de candidaturas), fundamentando a decisão de não criar índices parciais no momento.
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
   Espelhamento do contrato canônico 0.2.46 do `frila-documentacao` em `contrato/openapi.yaml` (SHA-256 `8aa49e0c39e87824a00b0d66b6f98846d92f8ce0866a000a12399933fec24e10`), cobrindo push FCM data-only para Android e canais por tipo (RN15).
4. **PR #350 (Expansão pgTAP para Funções Auxiliares do Schema Privado · merge em 31/10):**
   Novas suítes cobrindo preservação de dígito 9 na normalização alfanumérica, rejeição de documento cercado por espaços, máscara de valor em reais e validação de status HTTP 422 em campos obrigatórios.
5. **PR #351 (CI de Autenticação Remota · merge em 31/10):**
   Inclusão de `scripts/conferir-auth-remoto.sh` e testes automatizados para verificação das configurações de autenticação no Supabase.
6. **PR #364 (Atualização Factual de Métricas e Estado do Backend · merge em 31/10):**
   Atualização de métricas e documentação de alinhamento com base na ref `ca11a68`.

### De 18 a 23/11/2026

Estado de cada PR conferido com `gh pr view <n> --json state,mergedAt` em 23/11/2026 (datas de merge em horário de Brasília):

- **#573** (mesclado em 18/11): `cancelar_vaga` trava a vaga antes das posições abertas (issue #572, fechada em 18/11).
- **#574** (mesclado em 19/11): o ESTADO anterior, medido em `add668b`.
- **#571** (mesclado em 19/11): tokens de upload de uso único (RN14). **Removido da `develop` em 23/11** (B-091): a migração `20261123150000_remover_upload_verificacao_identidade.sql` desfaz a `20261118100000` (que fica no repositório, imutável), e o pgTAP 890, a corrida `corrida-token-upload-verificacao.sh`, o passo do `ci.yml` e as 5 linhas do mapa de mutação saíram. O Prod nunca recebeu a 20261118100000 (pacote 23, 23/11).
- **RN14 (verificação de identidade) saiu do produto em 19/11/2026** (decisão do Cauê, `produto/AGORA.md`). O **#578** (função receptora `enviar-documento-verificacao`, mesclado em 20/11) foi revertido pelo **#580** (mesclado em 20/11); a lista de Edge Functions de hoje não a tem (`git ls-tree -d --name-only origin/develop:supabase/functions`). O #571 foi removido da `develop` em 23/11 (B-091), como descrito acima.
- **#576** (mesclado em 20/11): cenário S6 e 2ª medição do `painel_estabelecimento`; o **#570** (mesclado em 23/11) acrescentou S1 e S2 com mais vagas, piso de cobertura e a 3ª medição. Detalhe em `docs/operacao/medir-painel-estabelecimento.md`.
- **#577** (mesclado em 20/11): aviso quando a cota mensal de moderação de mídia chega a 80%; corrigido pelo **#579** (mesclado em 20/11, entrega durável com lease e retentativa). Migrações `20261120100000` e `20261120200000`.
- **#588** (mesclado em 22/11): runbook do WAL e do slot; substitui o #462, que foi fechado.
- **#513** e **#516** (mesclados em 23/11): espelhos do contrato 0.2.106 e 0.2.107.
- **#589** (mesclado em 23/11): piso de R$ 50 e teto de R$ 2.000 no valor da diária (BE-02), migração `20261123100000`.
- **#586** e **#587** (mesclados em 23/11, 09h50): reaproveitam o pool de conexões Postgres em `saude` e `enviar-midia` (BE-01) e exigem o cabeçalho `x-agendador-secret` por padrão nas Edge Functions internas, sem aceitar `Authorization: Bearer` (BE-03). Revisados depois da mescla (`B-089`): aprovados, sem achado bloqueante.
- **#590** (mesclado em 23/11): o ESTADO anterior, medido em `e625e7e`.
- **#529** foi fechado sem merge; o #575 (mesclado em 19/11) o substituiu.
- **Pacote 23 aplicado no Prod em 23/11/2026, 11h52 (BRT)** (corte `7d1c57f`, #581; árvore aplicada `d80626e`, sem a `20261118100000` do #571): 4 migrações numa transação (`20261117100000` saúde operacional, `20261120100000` e `20261120200000` aviso de cota da moderação, `20261120300000` fallback do `disparar_email`); topo `20261117200000` → `20261120300000`, 232 → 236 versões; Edge Functions por nome: `moderar-midia` v9→v10, `saude` v17→v18, `enviar-email` v18→v19; `excluir-conta`, `exportar-meus-dados` e `exportar-turnos` ficaram fora (CORS, ver abaixo). Verificação, desvio antes e depois e fumaça verdes; `saude` responde 200 `status: saudavel`. Exceção aceita pelo O2: a CI do `7d1c57f` estava vermelha só nos pgTAP 747 e 871 (data fixa, corrigidos pelo #582, fora do corte). Provas: `orquestracao/retornos/B-084-pacote-23-prod-retorno.md`.
- **#594** (mesclado em 23/11, 13h29): o ESTADO com a fila de PRs. **#595** (mesclado em 23/11, 12h46): a migração `20261123150000_remover_upload_verificacao_identidade.sql` desfaz no banco a `20261118100000` (o #571; ver acima) e liberou as tags `backend-v*`: numa próxima tag, o `scripts/aplicar-remoto.sh` aplica a `20261118100000` (que o Prod não tem) e logo a `20261123150000`, que a desfaz. **#596** (mesclado em 23/11, 13h00): o vigia da `saude` do Prod no GitHub Actions, a cada 10 min, com aviso no Slack (`.github/workflows/vigia-saude.yml`, `docs/RunbookWalESlot.md` seção 6; o `schedule` roda na branch padrão, que é a `develop`). **#597** (mesclado em 23/11, 13h28, base `main`): o espelho do pacote 23.
- **CORS das 3 funções fora do pacote 23** (`excluir-conta`, `exportar-meus-dados`, `exportar-turnos`; #530): **sem necessidade até a web chamar do navegador.** A web chama as 3 só pelo Worker (`Web/app/servidor/conta/*`) e a CSP de `frilabr.com/app` (`connect-src 'self'` e Firebase) nem deixa o navegador falar com o Supabase; os apps nativos não usam CORS. `CORS_ORIGENS_PERMITIDAS` segue ausente no Prod. Prova: `orquestracao/retornos/B-095-cors-3-funcoes.md`.

### A fila de PRs aberta em 23/11/2026

Medida com `gh pr list --state open` em 23/11/2026 (depois da mescla do #586 e do #587): **6 PRs abertos**, todos Draft, e **4 issues abertas**
(`gh issue list --state open`). Em 18/11/2026 eram 9 PRs e 5 issues.

| PR | Autor | Branch | O quê |
|---|---|---|---|
| #515 | `jotape12-Dev` | `feat/historico-faltas` | histórico de faltas por tipo só para o titular (espelho 0.2.98) |
| #561 | `silvaaszx` | `feat/slack-aviso-manual` | ação `aviso` no workflow de avisos do Slack |
| #585 | `jotape12-Dev` | `fix/smtp-rejeitar-credencial-parcial` | `enviar-email` rejeita credencial SMTP parcial e relay remoto sem autenticação (DEF-02) |
| #591 | `jotape12-Dev` | `fix/disparar-email-sufixo-e-header-new01` | `disparar_email` troca só o sufixo `/despachar` e tira o `Authorization` redundante (NEW-01) |
| #592 | `jotape12-Dev` | `docs/ordem-canonica-travas-be07` | ordem canônica de travas e teste executável (BE-07) |
| #593 | `jotape12-Dev` | `feat/contrato-espelho-0.2.108-limites-diaria` | espelho do contrato 0.2.108, limites de valor da diária por posição (BE-02); a soma do `.sha256` não foi regravada e o `frila-documentacao#305` (0.2.108) segue em rascunho |

Issues abertas: #519 (`meus_dados` do contratante, nome curto da contraparte), #396 (contato fora do app, Fase 2),
#352 (infra do Prod, 4 entregas) e #297 (proteção ativa em `main` e `develop`). O estado de CI de cada PR não foi
remedido em 23/11/2026.

### A fila de PRs aberta em 01/11/2026 (histórico)

Eram 22 PRs abertos em 01/11/2026 (`gh pr list --state open`, #329, #353 a #363, #365 a #374). Remedidos em
18/11/2026 com `gh pr view <n> --json state`: **18 mesclados** (#353, #355 a #363, #365 a #370, #373 e #374;
o #367 é a sincronização `develop` -> `main`) e **4 fechados sem merge** (#329, #354, #371, #372).
**Nenhum segue aberto**: a lista de PRs de 01/11 não é mais fila de trabalho.

### A fila de PRs aberta em 16/10 (histórico)

Medida com `gh pr list --state open` em 16/10:

- **PR #185** (`chore/retencao-demonstracao-e-falhas` · Draft): Retenção de demonstração e limpeza de falhas [AGUARDA DECISÃO DO DONO].
- **PR #187** (`feat/vault-agendador-secret` · Draft): Implementação do segredo do agendador via Supabase Vault [AGUARDA DECISÃO DO DONO].
- **PRs da ronda noturna pgTAP e CI (#203 a #212):** PRs pequenos e focados cobrindo as lacunas do mapa pgTAP (#203 a #206, #208 a #210), sanitização de logs e tetos em Edge Functions (#207) e endurecimento de CI e dependências Deno (#211, #212).

---

## Ambientes

| | |
|---|---|
| local | `supabase start` · Postgres 17 (`major_version = 17` em `supabase/config.toml`) · **241** migrações na `develop` (veja `scripts/migracoes-sem-colisao.sh`), **236** no `main` (23/11/2026, as do Prod) |
| `frila-dev` | `jcobftbhbqdikratzizz` · `sa-east-1` · **não remedido em 23/11/2026.** Em 01/11: SMTP próprio ativo (`smtp.gmail.com:465`, código de 6 dígitos) e entrega bloqueada por `frila.agendador_secret` (vide abaixo, onde o repositório hoje contradiz o bloqueio) |
| `frila-prod` | `hbjkkcenbudiezmamiak` · `sa-east-1` · criado em 24/09, **em uso** · **não remedido em 23/11/2026.** Pacote 23 aplicado em **23/11/2026** (seção abaixo); último estado completo medido neste arquivo: pacote v1.1 aplicado em **08/11/2026** (topo `20261107370000`, 11 Edge Functions; detalhe abaixo). O `produto/AGORA.md` (frila-documentacao) registra pacotes posteriores no Prod, entre eles os pacotes 14 e 15 de 17/11/2026; esses não foram medidos contra o Prod por esta atualização · entrega só pela tag `backend-v*` (workflow Entrega) ou por roteiro combinado (`AGENTS.md`) |

### O `frila-prod` em 23/11/2026 (medido logo após o pacote 23)

Medido pelos scripts do roteiro do pacote 23 (somente leitura depois da aplicação; saídas em `orquestracao/lancamento-1-1/pacote-23/prod-7d1c57f/`):
**236 versões** em `supabase_migrations.schema_migrations`, topo `20261120300000`, as 4 do pacote gravadas pela mesma transação (um `xmin`);
**sem** a `20261118100000` (nem a tabela `privado.upload_verificacao_identidade`, nem a função `privado.consumir_token_upload_verificacao`);
Edge Functions: `moderar-midia` v10, `saude` v18, `enviar-email` v19 (publicadas às 14:53 UTC), `excluir-conta` v15, `exportar-meus-dados` v16, `exportar-turnos` v15;
fila de e-mail vazia e zero falha do `pg_net` nos últimos 15 min (antes e depois do deploy); `GET /functions/v1/saude` → `{"ok":true,"status":"saudavel"}`.
O resto do Prod (jobs, segredos, tabelas) **não foi remedido** em 23/11/2026; vale a seção abaixo, de 08/11/2026.

### O `frila-prod` em 08/11/2026 (medido logo após o pacote v1.1; não remedido em 23/11/2026)

**Tudo nesta seção, a tabela e as listas incluídas, descreve o `frila-prod` em 08/11/2026 e não foi remedido em
23/11/2026.** Os verbos no presente abaixo valem para aquela data, não para hoje.

Pacote v1.1 = `develop` em `e8516b51` (#425), **14 migrações** de `20261105150000` a
`20261107370000`, aplicadas entre 09:15 e 09:20 (horário de São Paulo) pelo roteiro aprovado
(uma transação por arquivo, conexão direta, `lock_timeout` 2 s e `statement_timeout` 10 s
conferidos em cada uma). Backup lógico cifrado gerado imediatamente antes, e a recuperação
foi ensaiada em contêiner isolado.

| O quê | Estado |
|---|---|
| Histórico de migrações | **151** versões, topo `20261107370000`. Em 08/11, as 4 migrações de 08/11 da `develop` (`20261108010000` a `20261108040000`, #426 a #430) **não** estavam no Prod: eram o pacote 2 |
| Chaves de recurso | Em 08/11: `foto_de_perfil` = false, `chamada_direta` = false, `perfil_rico` = false (`configuracao_do_app('ios')`). O `produto/AGORA.md` registra as três ligadas no Prod para o iOS 1.2.0 desde 13 e 14/11/2026; não medido contra o Prod por esta atualização |
| Moderação de mídia | Em 08/11: `MODERACAO_PROVEDOR=local`, `MODERACAO_TETO_MENSAL=5000`; nenhum segredo da Azure. `local` autoaprova e só serve com `foto_de_perfil` desligada |
| Edge Functions | `despachar` v7, `entrar-demonstracao` v7, `enviar-email` v7, `enviar-push` v9, `excluir-conta` v7, `exportar-meus-dados` v8, `exportar-turnos` v7, `expurgar-midias` v1, `limpar-contas-orfas` v7, `moderar-midia` v1, `saude` v8 |
| Publicadas do SHA `e8516b51` | `moderar-midia`, `expurgar-midias`, `exportar-meus-dados`, `saude` (antes do DDL) e `enviar-push` (depois da `20261107370000`, que cria `dispositivo.versao_app`). As demais são de 04/11 a 05/11 |
| Jobs novos no `pg_cron` | `limpar_contas_orfas_diaria`, `expurgar_midias_diaria`, `expurgar_midias_horario`, `processar_fila_moderacao_midia`, `expirar_chamadas_diretas`, `lembrar_chamadas_diretas`: ativos, usuário `postgres`, sem falha nos primeiros 10 min |
| Vault | Presentes: `agendador_secret`, `edge_function_url`, `email_function_url`, `push_function_url`, `limpar_contas_function_url`, `expurgar_midias_function_url`, `moderar_midia_function_url` (as 4 últimas criadas em 08/11) |
| Vault, **ausentes** | Em 08/11: `documento_pepper`, `storage_url`, `storage_jwt_secret`. Nenhuma GUC `frila.*`. Sem efeito naquela data: 0 verificações de identidade em toda a história e o app não chamava as RPCs da RN14. Ligar `foto_de_perfil` ou adotar a RN14 no app exigia os três antes |

O que custou caro descobrir na aplicação:
- Em 08/11, a URL de conexão guardada para o Prod era a do **pooler de sessão**, que ignora `PGOPTIONS`. Limite por sessão só vale na conexão direta (`db.<ref>.supabase.co:5432`).
- `supabase functions deploy` a partir de worktree em `/private/tmp` falha no empacotador Docker; use `--use-api`.
- `supabase secrets set` sobe a versão de todas as funções sem mudar o código (`updated_at` intacto).

**Histórico: em 29/09 o `frila-dev` passou a mandar e-mail por SMTP próprio** (PR #81). Os itens abaixo são o que o
PR configurou naquela data; o estado atual do `frila-dev` **não foi remedido em 23/11/2026**:
- Envio: `smtp.gmail.com:465`, conta `frilaverificacao@gmail.com`, remetente "Frila".
- Conteúdo: código de seis dígitos (`{{ .Token }}`).
- Validade: 15 minutos.

> ### ⚠️ Bloqueio da entrega contínua no `frila-dev`: `frila.agendador_secret` (descrição de 01/11; o repositório hoje a contradiz em parte)
>
> **Medido em 23/11/2026 no repositório (releitura do arquivo, sem mudança desde 18/11):** `scripts/aplicar-remoto.sh:135-148` aceita o segredo no Supabase Vault
> (`vault.decrypted_secrets`) **ou** em `frila.agendador_secret`, e as migrações já leem o Vault com fallback
> ao GUC (por exemplo `20261104140200_disparar_push_agendador.sql:33-34`). O `DECISOES.md` citado abaixo
> não existe na árvore (`ls DECISOES.md docs/DECISOES.md`). Dedução da leitura do código (não medida contra o
> ambiente): se o `frila-dev` ainda está parado, a causa não é mais a leitura por GUC. **O estado do
> `frila-dev` não foi remedido em 23/11/2026.**
>
> Texto de 01/11, mantido como histórico: a aplicação das migrações e entrega no ambiente remoto `frila-dev` via `./scripts/aplicar-remoto.sh` está **bloqueada**.
>
> O script verifica previamente a existência de `frila.agendador_secret` em `pg_db_role_setting` antes de autorizar as migrações (para garantir que `publicar_vaga` não falhe no enfileiramento pós-commit). Porém, no Supabase hospedado, o usuário `postgres` não possui permissões de superusuário (`superuser`), e a tentativa de configurar parâmetros GUC em nível de banco via `ALTER DATABASE postgres SET frila.agendador_secret = ...` falha com:
> ```
> ERROR: 42501: permission denied to set parameter "frila.agendador_secret"
> ```
> Como consequência, as migrações não podem avançar no `frila-dev` enquanto o segredo depender de GUC.
>
> **Solução proposta:** Foi redigida a proposta técnica em [`docs/historico/proposta-vault-agendador-secret.md`](historico/proposta-vault-agendador-secret.md) para migrar a leitura do segredo compartilhado para a extensão nativa **Supabase Vault** (`vault.decrypted_secrets`), com fallback de compatibilidade para os testes locais. O item aguarda decisão/aprovação do dono (registrado em `DECISOES.md`).
> *(Nota de segurança: nenhum valor de segredo real é registrado em arquivos de documentação ou histórico).*

---

## O contrato em detalhes

Versão espelhada: **0.2.107** em `contrato/openapi.yaml`, igual ao canônico em `FrilaApp/frila-documentacao · api/openapi.yaml` na `main` (`87eeb69`, 23/11/2026; SHA-256 `17297b13eb2d656c159de57c6d0a61cf6491de32b50e7634d8b612932af21c0a`). Medido em 23/11/2026; veja o quadro acima para os comandos.

Histórico das versões integradas no backend até a 0.2.46 (**as versões 0.2.47 a 0.2.107 não foram detalhadas aqui**; 80 commits tocam `contrato/openapi.yaml`, `git log --oneline origin/develop -- contrato/openapi.yaml | wc -l`):

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

Medido no banco de desenvolvimento com a `develop` em `c25ef14` (01/11/2026). **Esta seção não foi remedida em
23/11/2026** (as listas de tabelas, RPCs e jobs precisam de um banco local na `develop` atual): a `develop` tem hoje
241 migrações, então tabelas, RPCs e jobs novos não aparecem abaixo.

- **22 tabelas** em `public`:
  ```
  avaliacao · bloqueio · candidatura · despacho · disponibilidade · dispositivo
  entrada_demonstracao · equipe_confianca · estabelecimento · evento · evento_app
  funcao · membro_estabelecimento · notificacao · ocorrencia · pedido_de_exclusao
  posicao · profissional · profissional_funcao · turno · usuario · vaga
  ```
- **123 migrações** aplicadas sequencialmente sem colisão em 01/11/2026 (em 23/11/2026 são **241**, sem colisão: `./scripts/migracoes-sem-colisao.sh`).
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

> ### ⚠️ A armadilha: `agendador_secret`
> O gatilho de `pgmq.q_despacho` exige o segredo do agendador no banco antes de qualquer RPC que enfileire
> uma vaga. As migrações o leem do Vault (`vault.decrypted_secrets`, `agendador_secret`) com fallback ao
> `frila.agendador_secret` (por exemplo `20261104140200_disparar_push_agendador.sql:33-34`). Na CI e em
> testes locais, configure o segredo efêmero logo após o `supabase start` (`.github/workflows/ci.yml:58-70`,
> passo "Configurar segredo efêmero do agendador").

---

## Os portões

Medição da bateria em 23/11/2026 (ref `e625e7e` na `develop`), ao lado das de 16/10 (ref `7e011ea`) e 01/11
(ref `c25ef14`). Linha que diz "não remedido em 23/11/2026" precisa de `supabase db reset` ou de banco local, e o
banco local é compartilhado entre sessões; nessa linha vale a última medida, com a data.

| Comando | O que garante | Medida em 16/10 (ref `7e011ea`) | Medida em 01/11 (ref `c25ef14`) | Medida em 23/11 (ref `e625e7e`) |
|---|---|---|---|---|
| `supabase test db` | pgTAP | **108** arquivos de regras (109 no prove), **2.980** asserções verdes | **197** arquivos de regras (198 no total com `gerar_df.sql`), verde | **304** arquivos de regras (306 com os 2 geradores de `carga/`). Resultado: **não remedido em 23/11/2026** |
| `./scripts/contrato-responde.sh` | respostas casam com o contrato | **46 de 50** respostas 200, **151 de 151** vigiados, **37 de 37** coleções | **46 de 50** respostas 200 validadas, **151 de 151** recusas vigiadas e alcançadas, **37 de 37** coleções exercitadas | **não remedido em 23/11/2026** (precisa de `supabase db reset`) |
| `deno test --allow-all --no-check --lock=deno.lock --frozen supabase/functions/ supabase/templates/` | Edge Functions em Deno | **179** testes verdes | **279** testes verdes (0 falhas; 44 em `exportar-turnos`) | **563** passaram, **0** falharam, **3** ignorados (55 em `exportar-turnos`) |
| `./scripts/teste-contrato-promete.sh` | autoteste da direção contrato-à-frente | 9 de 9 casos verdes | **9 de 9** casos verdes | **9 de 9** casos verdes (precisa de `jsonschema` no Python) |
| `./scripts/teste-contrato-responde.sh` | autoteste de schemas do contrato | 14 de 14 casos verdes | **14 de 14** casos verdes | **14 de 14** casos verdes (precisa de `jsonschema` no Python) |
| `./scripts/teste-contrato-acompanha.sh` | PR que altera `public` acompanha contrato | 19 de 19 casos verdes | **19 de 19** casos verdes | **19 de 19** casos verdes |
| `./scripts/relogio-em-testes.sh` | imunidade contra bombas-relógio de relógio | **108** arquivos pgTAP imunizados | **197** arquivos pgTAP imunizados | **304** arquivos pgTAP imunizados |
| `./scripts/migracoes-sem-colisao.sh` | carimbos de migração únicos | **123** carimbos distintos | **123** carimbos distintos sem colisão | **241** carimbos distintos sem colisão |
| `./scripts/migracoes-imutaveis.sh` | migrações passadas não foram alteradas | verde | verde | verde (`Nenhuma migração existente foi tocada.`) |
| `./scripts/planos-com-carga.sh` | caminho quente sob volume sintético do DF (PR #180, #196) | verde na CI | verde na CI (aquecimento prévio, melhor de 3 baterias) | **não remedido em 23/11/2026** |

### O portão do contrato, medido em 10/10 (não remedido em 23/11/2026)

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

Em 23/11/2026 o módulo `scripts/contrato_responde.py` declara **268** entradas em `VIGIADAS`, **24** em `ISENTAS`
e **2** em `PENDENTES` (contagem estática, igual à de 18/11; a saída do portão com esses números **não foi remedida**). As listas
abaixo e a conta acima são de 10/10 e já não descrevem o módulo.

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
| `privado.anulacao_falta` | anulação operacional de falta pelo admin (decisão JP 15/11, RN12): auditoria, operador e rastreabilidade no schema privado para evitar vazamento aos clientes |
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
- **Operações do contrato que não são RPC (remedido em 23/11/2026 no `contrato/openapi.yaml` 0.2.107, mesmos números de 18/11, lendo `paths` com PyYAML: `python3 -c "import yaml; p=yaml.safe_load(open('contrato/openapi.yaml'))['paths']; print(len(p), sum(not k.startswith('/rpc/') for k in p))"` dá `89 11`):** o contrato tem **89** operações em 89 caminhos: **78** em `/rpc/*` e **11** fora dele. Dessas 11, três são endpoints nativos do Supabase Auth (`/otp`, `/verify`, `/token`: `pedirCodigo`, `confirmarCodigo`, `renovarSessao`), três são leitura direta de tabela por PostgREST (`/funcao`, `/regiao_administrativa`, `/especialidade`) e cinco são Edge Functions (`/exportar-turnos`, `/exportar-meus-dados`, `/ler-midia`, `/entrar-demonstracao`, `/excluir-conta`). Em 01/11 esta nota dizia "apenas quatro" operações sem RPC nem Edge Function (as três do Auth e `/funcao`); hoje são seis, porque `/regiao_administrativa` e `/especialidade` também são leitura direta. Se cada uma das 78 RPCs tem função no banco: não remedido em 23/11/2026.
- **Avisos push mutáveis no iOS (h6RoObK6, contrato 0.2.30):** O payload APNs enviado via FCM inclui `"mutable-content": 1` em `apns.payload.aps` junto de `sound` e `badge`.
  Isso permite à Notification Service Extension do iOS interceptar e tratar o aviso antes da exibição para validação de `vinculo_id` sem expor dados pessoais (RN15).

---

## Pendências fora do código

Itens de 01/11 e 08/11, conferidos contra o repositório em 18/11/2026 e **não reconferidos em 23/11/2026**, salvo o item 5. O que depende de ambiente remoto, de
loja, de pessoa ou de decisão fora do repositório **não foi remedido em 23/11/2026**.

1. **Desbloqueio de deploy no `frila-dev`:** o texto de 01/11 pedia o aval da proposta do Vault
   (`docs/historico/proposta-vault-agendador-secret.md`). No repositório, `scripts/aplicar-remoto.sh` e as migrações
   já leem o Vault com fallback ao GUC (veja "Ambientes"). Estado do `frila-dev` e se o aval saiu: não remedido
   em 23/11/2026. O `DECISOES.md` citado em 01/11 continua sem existir na árvore (`ls DECISOES.md docs/DECISOES.md`, 23/11/2026).
2. **Push com mutable-content no iOS (`h6RoObK6`):** o backend foi entregue e mesclado no PR #178 (`mutable-content: 1`).
   A conclusão depende da esteira de iOS (target Notification Service Extension, App Group e aprovação de design para o
   texto neutro sem dados pessoais). Não remedido em 23/11/2026.
3. **Credenciais para deploy remoto:** o ambiente remoto `frila-dev` e `frila-prod` depende de `SUPABASE_ACCESS_TOKEN`
   válido no ambiente. Não remedido em 23/11/2026.
4. **Revisão da Júlia:** revisão da lista de termos bloqueados do filtro de texto ofensivo (`ggEzge6h`). Não remedido
   em 23/11/2026.
5. **Segredos do Vault no `frila-prod` (08/11):** criar `documento_pepper` (uma vez, com cópia no cofre: girar invalida a
   deduplicação da RN14) e `storage_url`; antes de `storage_jwt_secret`, medir no Prod o `alg` do token que o Storage
   emite (o formato foi medido só no local). Era pré-requisito de ligar `foto_de_perfil` e de adotar a RN14 no app.
   **A RN14 saiu do produto em 19/11/2026** (decisão do Cauê, `produto/AGORA.md`; função receptora do #578 revertida no #580),
   então "adotar a RN14 no app" deixou de ser motivo para este item; o `documento_pepper` só importa se a decisão mudar.
   O Vault do Prod **não foi remedido em 23/11/2026**: o `produto/AGORA.md` descreve a chave `foto_de_perfil` ligada no Prod
   em 14/11/2026, o que muda o pré-requisito restante; confira o Vault do Prod antes de agir sobre este item.

---

## Por onde continuar

1. **O que o produto pede agora:** `produto/AGORA.md` e `produto/modulos/` no `frila-documentacao`. Este arquivo
   deixou de listar o escopo.
2. **O que está em voo no backend:** a fila de 6 PRs abertos e as 4 issues abertas de 23/11/2026, na seção "Onde cada
   coisa parou". `gh pr list --state open` e `gh issue list --state open` dão a lista de hoje.
3. **Antes de escrever um contrato novo ou uma migração:** `git fetch`, parta de `origin/develop` (241 migrações,
   contrato 0.2.107 em 23/11/2026), rode `./scripts/migracoes-sem-colisao.sh` e procure o `create or replace function <nome>`
   na `develop` e nos PRs abertos (`AGENTS.md`).
4. **Ambientes remotos (`frila-dev`, `frila-prod`):** não remedidos em 23/11/2026. Meça antes de afirmar o estado
   (`scripts/desvio.sh <project_ref>`, `AGENTS.md`).
