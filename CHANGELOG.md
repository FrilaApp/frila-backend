# Changelog

Todas as alterações notáveis neste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e este projeto adere ao [Versionamento Semântico](https://semver.org/lang/pt-BR/).

## [Não lançado]

### Adicionado
- **Suíte de paridade exaustiva de `privado.elegiveis` (RNF11, RNF12):**
  - Teste pgTAP `supabase/tests/680_elegiveis_recorte_antes_do_join.sql` comprovando a equivalência estrita de elegíveis (10/10 asserções cobrindo 100% das vagas cadastradas, fixtures de demonstração e `excluir_conta`).
  - Documentação técnica e comprovação experimental refutando a Recomendação 1 do relatório #195: a reordenação interna da CTE sofre *subquery pull-up* pelo planejador PostgreSQL, gerando plano físico idêntico ao canônico, enquanto a extração de `usuario` para a consulta externa dispara varredura sequencial em `disponibilidade` e `usuario`.

### Modificado
- **Espelho do contrato 0.2.43 do frila-docs (PR frila-docs#89):**
  - Alinhamento da documentação de `contestarSuspensao` e `pedirRevisaoDespacho`: o relato das contestações não passa pelo filtro de termos da diretriz 1.2 (decisão J1=B, migração `20261013110000`).
  - Atualização dos arquivos `contrato/openapi.yaml` e `contrato/openapi.yaml.sha256`.
- **Espelho do contrato 0.2.42 do frila-docs (PR frila-docs#88):**
  - Documentação do comportamento de bloqueio mútuo no modo seleção para `candidatosDaVaga` (ocultação de profissionais bloqueados) e `escolherCandidato` (recusa `403 sem_permissao` sem `details` indistinguível de inexistente e com precedência sobre `409`).
  - Atualização dos arquivos `contrato/openapi.yaml` e `contrato/openapi.yaml.sha256`.

### Documentação
- **Relatório de desempenho e planos sob carga em escala 10x do DF (RNF11, RNF12):**
  - Aferição do comportamento sob volume de 1,3 milhão de usuários, 1 milhão de profissionais, 200 mil vagas e 2 milhões de disponibilidades no DF.
  - Parametrização dinâmica do gerador de carga (`supabase/tests/carga/gerar_df.sql` via `frila.carga_escala`) e do portão (`scripts/planos-com-carga.sh --escala <N>`), preservando o padrão 1x da CI.
  - Mapeamento detalhado de planos `EXPLAIN (ANALYZE, BUFFERS)` e identificação de gargalos de escalabilidade em `privado.elegiveis` (varredura de 1,3M de linhas em `usuario`), `public.vagas_abertas` (filtro de data pós-GiST) e `privado.fechar_turnos_e_vagas` (ausência de índices em `fim_em` para posições e vagas expiradas).
  - Recomendações técnicas documentadas em `docs/carga-10x.md` para futuros PRs dedicados de otimização e índices com pgTAP.

### Testes
- **Robustez estatística do portão de caminho quente sob carga (`scripts/planos-com-carga.sh`):**
  - Implementado aquecimento prévio robusto (2 voltas em `privado.elegiveis` e 10 chamadas de `public.vagas_abertas`) descartando transientes de cache e povoando buffers do índice espacial.
  - Ampliação da amostragem (50 chamadas de `vagas_abertas` e 36 de `elegiveis` por bateria) e julgamento pelo melhor resultado entre 3 baterias consecutivas (mínimo independente de mediana e p95), eliminando a vulnerabilidade amostral do p95 de 25 chamadas.
  - Mantida reprovação categórica se houver varredura sequencial (`Seq Scan`) em tabelas grandes ou regressão acima dos tetos.
  - O autoteste `scripts/teste-planos-com-carga.sh` afere regras sobre saídas sintéticas (11/11); mutação real verificada com `MUTAR=cte` (reprova) e `MUTAR=indice` (sai 0, recaindo na chave única).
- **Follow-up de bloqueio mútuo e recusas indistinguíveis no modo seleção (RF26, RN10, RN19, PR #184):**
  - Prova estrita de equivalência entre tentativa de escolher candidatura inexistente e candidatura de profissional com bloqueio mútuo ativo: ambas retornam `403 sem_permissao` com payloads de erro indistinguíveis, nos dois sentidos de bloqueio (profissional bloqueia casa e casa bloqueia profissional), preservando o sigilo sem vazar a existência do bloqueio.
  - Validação do fluxo legítimo no modo seleção: confirmação com sucesso, geração de `turno_id`, retorno do contato do profissional em `escolher_candidato` e retorno do contato do estabelecimento ao profissional confirmado em `contato_do_turno`.
  - Suíte pgTAP `671_bloqueio_escolher_candidato_recusa_e_contato.sql` (9 asserções).

### Segurança
- **Bloqueio mútuo no modo seleção e concessão mínima de privilégios (Auditoria 15/10/2026, Achados 1 a 4, RF26, RN10, RN15, LGPD):**
  - **Achado 1 (Alta):** Filtro de bloqueio mútuo (`not privado.bloqueado_com_estabelecimento(...)`) adicionado a `public.candidatos_da_vaga` e validação em `public.escolher_candidato`. Candidatos com bloqueio mútuo não aparecem para o contratante e tentativas de confirmação são recusadas com `403 sem_permissao` (resposta idêntica a candidatura inexistente ou de outra casa, sem vazar a existência do bloqueio), impedindo vazamento de contatos telefônicos de profissionais com bloqueio mútuo com o contratante ou estabelecimento.
  - **Achado 2 (Média):** Adicionado bloco de configuração `[functions.enviar-push]` em `supabase/config.toml` com `verify_jwt = false`, alinhando o gateway do Supabase Edge Runtime à autenticação interna da Edge Function via `AGENDADOR_SECRET` (`x-agendador-secret` ou `Bearer <AGENDADOR_SECRET>`) e prevenindo rejeição indevida com 401 Unauthorized em produção/homologação.
  - **Achado 3 (Baixa):** Revogada permissão de `EXECUTE` em `privado.taxa_aceite_notificacoes_7d()` para `authenticated` e `anon`, mantendo concessão estrita para `service_role`.
  - **Achado 4 (Baixa):** Revogado `ALL` em `public.pedido_de_exclusao` explicitamente de `public`, alinhando o DDL à documentação de privilégios da tabela.
  - Migração `20261015150000_seguranca_bloqueio_e_privilegios.sql` e suíte pgTAP `670_seguranca_bloqueio_e_privilegios.sql` (7 asserções cobrindo bloqueio nos dois sentidos, ocultação na listagem, recusa em escolher_candidato e privilégios de função e tabela).

### Corrigido
- **Otimização do laço de avaliacao_disponivel em fechar_turnos_e_vagas (Achado 2):**
  - Adicionado filtro com `not exists` em `public.notificacao` (tipo `'avaliacao_disponivel'`) e janela retroativa de 7 dias na consulta de turnos cumpridos e verificados em `privado.fechar_turnos_e_vagas()`.
  - Elimina a varredura e renotificação O(N) de todo o histórico da plataforma a cada 5 minutos, mantendo estrita idempotência e zero overhead acumulativo.
  - Aferido pelo portão de caminho quente sob carga do DF (`scripts/planos-com-carga.sh`), com latências de 13.9 ms e 15.2 ms, bem abaixo dos tetos.
- **Filtro de vagas ativas no alarme de despachos travados de verificar_saude (Achado 3):**
  - Ajuste na contagem de despachos retidos sob a regra do teto (RN23) em `privado.verificar_saude()`, adicionando join com `public.vaga` para considerar apenas vagas que continuam com `estado = 'publicada'` e no futuro (`inicio_em > agora`).
  - Previne falso positivo perpétuo de infraestrutura (`despacho_esperando_alem_do_teto`) quando vagas são canceladas, encerradas, preenchidas ou iniciadas naturalmente antes do fim da janela do teto, preservando a imutabilidade estrita da tabela `public.despacho`.
  - Migração `20261015140000_correcao_ciclo_de_vida_achados_2_e_3.sql` e suíte pgTAP `660_ciclo_de_vida_achados.sql` (5 asserções cobrindo Achados 1, 2 e 3).
- **Encerramento de vagas publicadas e cancelamento de posições abertas após fim_em (D654gdGQ):**
  - Correção na rotina `privado.fechar_turnos_e_vagas()` para cancelar posições remanescentes que permaneceram em `estado = 'aberta'` após o término do turno (`fim_em <= privado.agora()`) e encerrar as vagas correspondentes (`estado = 'encerrada'`).
  - Previne acúmulo perpétuo de vagas expiradas com `estado = 'publicada'` no índice espacial GiST (`vaga_ponto_publicada`), eliminando degradação progressiva de latência na busca geográfica de `public.vagas_abertas()`.
  - Migração `20261015100000_fechar_vagas_expiradas_sem_processo.sql` e suíte pgTAP `650_fechamento_vaga_expirada_sem_processo.sql` (12 asserções cobrindo vaga sem confirmações, vaga com confirmação parcial e sobras abertas, vagas futuras intocadas e idempotência).

### Adicionado
- **Cobertura de testes pgTAP para mutantes sobreviventes (MUTACAO-15-10.md):**
  - **Mutante 4 (RN23, RNF13):** Prova que `privado.liberar_teto_do_profissional` não renotifica despachos represados quando a vaga foi cancelada no intervalo, mantendo `notificacao_id` nulo de forma imutável e sem disparar falso alerta de `despacho_esperando_alem_do_teto` em `privado.verificar_saude()`.
  - **Mutante 5 (RN07, #181):** Prova que a janela retroativa de 7 dias em `privado.fechar_turnos_e_vagas()` emite notificação `avaliacao_disponivel` para turnos concluídos recentemente (ex.: 5 dias) e conclui como cumpridas sem emitir avaliações obsoletas para turnos concluídos além da janela regulamentar de 7 dias (ex.: 8 dias).
  - **Mutante 6 (RN10, #179, J5):** Prova a detecção de telefones camuflados por combinações de separadores variados (barras, hífens, pontos, parênteses) em `privado.contem_contato_ou_link` e integração com `public.publicar_vaga`, garantindo recusa com `422 campo_invalido` (`details: observacoes`) sem afetar expressões legítimas de horários, datas e valores.
  - Suíte pgTAP `672_mutantes_sobreviventes_ciclo_e_texto.sql` com 12 asserções cobrindo os três cenários.
- **Recusa de telefone, e-mail e link no texto livre da vaga (J5, pBXTS4vv, RN10):**
  - Validação em `privado.contem_contato_ou_link` integrada a `privado.exigir_texto_aceitavel` recusando telefones (8+ dígitos mesmo com separadores ou camuflagem por hífens/espaços/pontos, ex: `61-98-7654321`, `61-9-8765-4321`, `61 98 7654 321`, `61.98.7654.321`), e-mails (@ + domínio) e links/URLs (`http://`, `https://`, `www.`, domínios com TLDs comuns e encurtadores `wa.me`, `bit.ly`, `t.me`, `linktr.ee`) nos campos de texto livre (`local`, `responsavel_local`, `traje`, `observacoes` em `publicar_vaga`/`republicar_vaga` e `nome`/`endereco` em `cadastrar_estabelecimento`) com `422 campo_invalido` e nome do campo em `details`.
  - Tratamento de falsos positivos legítimos com máscaras estritas: datas de calendário válidas (dia 01-31, mês 01-12, anos 19xx/20xx ou 2 dígitos com barra), horários (como `18h30`, `18h às 22h`, `14:00 às 22:00`, `18:30 às 23:30`), valores monetários (`R$ 1.200,00`, `150 reais`), CEPs com e sem formatação, numeração de endereços de Brasília e UUIDs de sistema.
  - Limitação conhecida documentada: números digitados por extenso ("seis um nove oito...") estão fora do escopo desta validação sintática via expressões regulares (demandariam moderação semântica/LLM).
  - Em conformidade com RN15 e LGPD, dados de contato ou links rejeitados não são gravados em logs nem em `public.ocorrencia`.
  - Migração `20261014160000_recusar_contato_e_link_texto_vaga.sql` e suíte pgTAP `640_contato_e_link_texto_vaga.sql` (74 asserções cobrindo casos positivos, negativos, camuflagens de contato, falsos positivos legítimos, idempotência, republicação e ausência de rastro).
- **Republicação de posições restantes em urgência (D1-C, contrato 0.2.41, PR #170):**
  - RPC `public.republicar_posicoes_restantes(vaga_id, chave)` permitindo ao contratante reabrir posições não preenchidas ou canceladas de vaga fechada sem candidatos em seleção ativa. Cria nova vaga em modo urgência com posições clonadas, mantendo rastreabilidade via `vaga.republicada_de`.
  - Migrações `20261009100000_vaga_republicada_de_e_republicacao_da_selecao.sql` e `20261009110000_republicar_posicoes_restantes_e_painel.sql`.
  - Suíte pgTAP `630_republicar_posicoes_restantes.sql` (55 asserções), teste de concorrência Cenário 11 em `scripts/corrida-ciclo.sh` e recusas contratuais vigiadas `401` (`nao_autenticado`), `403` (`sem_permissao`), `404` (`nao_encontrado`) e `422` (`republicacao_indisponivel`).
- **Suporte por e-mail a partir do turno (Opção C, contrato 0.2.40, RF23, UC14, PR #169):**
  - RPC `public.abrir_suporte(turno_id, motivo)` para abertura de chamados vinculados ao turno com tipo `'suporte'`, `origem = 'app'`, categoria predefinida e sem texto livre (`relato` nulo, LGPD/RN15), gerando `protocolo` (UUID) e `protocolo_curto` (8 caracteres hexadecimais em maiúsculas).
  - Migrações `20261008100000_categoria_suporte_e_origem_ocorrencia.sql` e `20261008110000_abrir_suporte.sql`.
  - Suíte pgTAP `620_abrir_suporte.sql` (26 asserções) e recusa contratual vigiada `abrirSuporte:422` (`motivo_obrigatorio`).
- **Operação do suporte por e-mail a partir do turno (P6, contrato 0.2.40, PR #171):**
  - Ajuste do script operacional `consultar-ocorrencias.sql` para exibir `protocolo_curto` (8 hexadecimais em maiúsculas), `origem`, categoria (`motivo`) e `turno_id`, mantendo join interno em `usuario` autor.
  - Script operacional `fechar-chamado-sem-email.sql` para fechamento manual pela Equipe Frila com resultado `sem_email_recebido` após expiração do prazo regulamentar de 5 dias úteis (D16, SU-RN10).
  - Atualização do manual de procedimentos em `supabase/operacao/equipe-frila.md` documentando o fluxo completo com endereço oficial `suporte@frila.app`, SLA de 5 dias úteis, busca por protocolo curto, critérios de encerramento manual e política rigorosa de retenção e expurgo de e-mails em conformidade com a LGPD (D9, SU-RN11).
- **Modo de seleção e reposição dentro de 24h (D4=C, D5=A, contrato 0.2.38, PR #161):**
  - Publicação de novas vagas e reabertura de posições com menos de 24h para o início forçadas para o modo urgência, recusando seleção manual com `422 modo_indisponivel`.
  - Migração `20261007110000_modo_selecao_reabertura_urgencia.sql`.
- **Revisão de Despacho (Opção B) e Exportação de Turnos (contrato 0.2.37, PR #155):**
  - Trava de unicidade no app em `pedir_revisao_despacho` recusando reenvio com `409 contestacao_ja_aberta`. Migração `20261006160000_revisao_despacho_opcao_b.sql` e suíte pgTAP `605_revisao_despacho_opcao_b.sql`.
  - Edge Function `exportar-turnos` com janela máxima regulamentar de 30 dias (`422 intervalo_maximo_excedido`) e parâmetros opcionais `de`/`ate`.
- **Contestação de Suspensão com Opção B (contrato 0.2.36, PR #153):**
  - Unicidade da contestação de suspensão no app com `409 contestacao_ja_aberta`. Migração `20261005190000_situacao_da_conta_contestacao_respondida.sql` e suíte pgTAP `604_situacao_da_conta_contestacao_respondida.sql`.
- **Cancelamento Idempotente (contrato 0.2.35, PR #149):**
  - Resposta 200 idempotente para reenvios de `cancelar_posicao` e `cancelar_vaga`. Migração `20261005090000_cancelamento_idempotente.sql` e suíte pgTAP `603_cancelamento_idempotente_reenvio.sql`.
- **Endurecimento do Portão do Contrato e Cobertura Integral de Recusas (PRs #150, #154, #156, #157, #159, #163, #164, #165, #167):**
  - Expansão dos Lotes 3 a 10 de recusas críticas no `contrato-responde.sh`, alcançando 100% de cobertura das 167 recusas declaradas pelo contrato OpenAPI (151 vigiadas e alcançadas no banco, 16 isentas com justificativa documentada em `ISENTAS` e 0 não vigiadas).
  - Suítes pgTAP `487` a `494` e garantia de bloqueio na CI caso novos pares de recusa sejam adicionados sem teste ou justificativa explícita.
  - Autotestes do portão expandidos para 14 casos verdes (`teste-contrato-responde.sh`).

### Alterado
- **Remoção de status 403 não documentado (contrato 0.2.39, PR #166):**
  - Limpeza de declarações de 403 em operações sem restrição de papel ou perfil.
- Correções das versões 1.0.x decorrentes dos testes do TestFlight e feedback do piloto no DF (cartão `RzllRo3o`).

## [1.0.0] - 2026-10-04

Versão base do backend para o lançamento do MVP e início do piloto no Distrito Federal (DF), consolidada a partir do tronco `develop`.

### Contrato OpenAPI (`contrato/openapi.yaml`)
- **Alinhamento e espelhamento oficial (0.2.0 → 0.2.34):**
  - Espelho integral e sincronizado com `FrilaApp/frila-docs · api/openapi.yaml`, validado por portão automatizado contra divergência via SHA-256 (`contrato-em-dia.sh`).
  - **0.2.2**: Estruturação inicial do contrato, autenticação por código no e-mail, criação de conta com perfil e portão de contrato (PRs #7 e #15).
  - **0.2.5**: Modo seleção recusado na v1.0 com `campo_invalido` (`details: modo`).
  - **0.2.7**: Vaga preenchida recusa candidatura com `posicao_ja_preenchida`.
  - **0.2.8**: Inclusão de `meus_turnos` no ciclo por HTTP.
  - **0.2.11**: Posição cancelada não retorna para aberta (criação de nova posição na vaga).
  - **0.2.12**: Avaliação por lado do turno (`unique (turno_id, alvo_tipo)`) e catálogo de recusa `409 avaliacao_ja_registrada`.
  - **0.2.13**: RPC `republicar_vaga` para reutilização ágil de vagas frequentes sem duplicar digitação.
  - **0.2.15**: Portão de validação de corpo JSON Schema de cada RPC contra o contrato OpenAPI (PR #29).
  - **0.2.16 e 0.2.17**: RPC `configuracao_do_app` (leitura sem sessão para versão mínima) e catálogo formal de notificações.
  - **0.2.18**: Operação `excluir_conta` (resposta 202 com anonimização imediata e recusa 401 para contas encerradas).
  - **0.2.19**: Alerta de atraso aos 15 min, RPC `reabrir_por_atraso` e candidatura em posição reaberta até 1 h antes do fim do turno (PR #49).
  - **0.2.20**: Atributo `regiao_administrativa` em estabelecimento e vaga, interpolado nas notificações push (PR #54).
  - **0.2.21**: RPCs de moderação `denunciar` e `bloquear` com validação de formato e recusa 422 (PR #57 e #65).
  - **0.2.22 a 0.2.24**: Alinhamento de recusas e esquemas de erros, painel de métricas do piloto (PR #84) e modo seleção (PR #82).
  - **0.2.25**: Sinalização de deslocamento "Estou a caminho" (`avisar_a_caminho`, `a_caminho_em` no turno e painel, PR #85).
  - **0.2.26 e 0.2.27**: Registro de dispositivo (422) e moderação de texto denunciado em vagas (PR #88, #91 e #92).
  - **0.2.28**: Bloqueio bidirecional esconde perfil público com resposta `404 nao_encontrado` (PR #103 e #104).
  - **0.2.29**: RPC `meu_estabelecimento` para consulta de contexto por membros vinculados (PR #125).
  - **0.2.30**: Identificador `vinculo_id` do aparelho no push e registro de dispositivo (PR #129).
  - **0.2.31**: Turno cancelado, avaliação concedida e cancelamento exposto no painel do contratante (PR #131).
  - **0.2.32**: Cancelamento no turno e amarração de `turno_id` na candidatura (PR #130).
  - **0.2.33**: Sete coleções completas em `MeusDados` (`privado.meus_dados`, PR #99 e #135) para cumprimento integral da LGPD.
  - **0.2.34**: Documentação formal de status codes adicionais (409 em `contestar_suspensao`) e sincronização estrita (PR #140).

### Banco de Dados e Migrações (`supabase/migrations/`)
- **93 migrações imutáveis:**
  - Histórico linear de 93 arquivos DDL versionados cronologicamente, com integridade garantida por portões de não colisão e imutabilidade.
- **Estrutura de Schemas e Tabelas:**
  - **Schema `public` (22 tabelas):**
    `avaliacao`, `bloqueio`, `candidatura`, `despacho`, `disponibilidade`, `dispositivo`, `entrada_demonstracao`, `equipe_confianca`, `estabelecimento`, `evento`, `evento_app`, `funcao`, `membro_estabelecimento`, `notificacao`, `ocorrencia`, `pedido_de_exclusao`, `posicao`, `profissional`, `profissional_funcao`, `turno`, `usuario`, `vaga`.
  - **Schema `privado`:** 127 funções auxiliares `security definer`, catálogo e lógica de domínio blindados contra acesso externo, e controle de ambiente (`privado.ambiente`).
  - **Schema `requisicao`:** Função `requisicao.conferir_limite()` vinculada a `pgrst.db_pre_request` no papel `authenticator`, impondo teto estrito de 60 escritas por minuto por usuário autenticado.
  - **Schema `metrica`:** Views analíticas de acompanhamento do piloto (`funil_geral`, `funil_por_estabelecimento`, `funil_por_dia`) com isolamento automático de contas de teste e da equipe (`privado.conta_equipe`).
- **Políticas e Regras de Segurança:**
  - 21 políticas de leitura (RLS) em `public`; nenhuma política de escrita direta (toda mutação ocorre exclusivamente através de RPCs controladas).
  - Mais de 107 restrições `CHECK`, 1 restrição de exclusão temporal/espacial (RN21) e restrições de unicidade.
  - Hardening de permissões: revogação de privilégios excessivos da role `authenticated` sobre tabelas internas em `public` (PR #118 e #121).
- **Regras de Negócio e Integridade Temporal:**
  - Implementação das regras RN01 a RN25 (incluindo RN07 avaliação, RN10 privacidade e omissão de identificadores sensíveis, RN12 regras de cancelamento, RN15 filtragem de payload push, RN19 concorrência de vagas, RN23 controle de teto de despacho e RN25 unicidade de perfil).
  - Centralização temporal em `privado.agora()` em todas as funções e validações de prazo, garantindo determinismo em testes e operações.
  - Isolamento de dados de demonstração da App Store (`revisao-contratante` e `revisao-profissional`) no `supabase/seed.sql` com regras de janela estendida (`20260925230000_janela_da_demonstracao.sql`).

### Superfície de API e RPCs (42 Autenticadas + 1 Anônima)
- **Conta e Perfil:**
  - `criar_conta`, `minha_conta`, `situacao_da_conta`, `contestar_suspensao`.
  - `criar_perfil_profissional`, `meu_perfil_profissional`, `atualizar_perfil_profissional`.
- **Contratante e Estabelecimento:**
  - `cadastrar_estabelecimento`, `painel_estabelecimento`, `meus_estabelecimentos`, `meu_estabelecimento`.
- **Equipe de Confiança:**
  - `equipe_de_confianca`, `incluir_na_equipe`, `remover_da_equipe`.
- **Vagas e Seleção:**
  - `publicar_vaga`, `republicar_vaga`, `vagas_abertas`, `detalhe_vaga`, `cancelar_vaga`.
  - `candidatos_da_vaga`, `escolher_candidato`, `retirar_candidatura`.
- **Turnos e Presença:**
  - `candidatar`, `minhas_candidaturas`, `meus_turnos`, `contato_do_turno`, `cancelar_posicao`, `avisar_a_caminho`.
  - `fazer_checkin`, `fazer_checkout`, `confirmar_checkin_manual`.
- **Reputação e Moderação:**
  - `avaliar`, `perfil_publico`.
  - `denunciar`, `bloquear`.
- **Dispositivos e Telemetria:**
  - `registrar_dispositivo`, `remover_dispositivo`, `criterios_de_notificacao`.
  - `registrar_evento`.
- **Despacho:**
  - `pedir_revisao_despacho`, `reabrir_por_atraso`.
- **Pública (sem sessão):**
  - `configuracao_do_app` (exceção controlada para consulta de versão mínima por clientes não autenticados).

### Edge Functions e Processamento em Segundo Plano
- **9 Edge Functions (Deno):**
  - `despachar`: motor de despacho e notificação de vagas.
  - `enviar-push`: despacho de mensagens FCM com sanitização estrita de payload (RN15/RN10).
  - `enviar-email`: processamento de mensagens transacionais.
  - `excluir-conta` e `limpeza-contas-orfas`: anonimização imediata e expurgo de contas conforme LGPD.
  - `exportar-turnos`, `exportar-turnos-csv`, `exportar-turnos-pdf`: geração e exportação de relatórios de turnos.
  - `entrar-demonstracao`: porta de autenticação restrita para revisão da App Store.
- **13 Rotinas Agendadas (`pg_cron`):**
  - `alertar_atrasos` (`* * * * *`)
  - `alertar_fim_sem_checkout` (`*/5 * * * *`)
  - `alertar_vagas_vazias` (`*/5 * * * *`)
  - `enviar_lembretes_turno` (`*/5 * * * *`)
  - `fechar_selecoes` (`* * * * *`)
  - `fechar_turnos_e_vagas` (`*/5 * * * *`)
  - `liberar_teto` (`* * * * *`)
  - `limpar_dispositivos_inativos` (`17 6 * * *`)
  - `processar_fila_email` (`* * * * *`)
  - `reconciliar_reputacao_diaria` (`0 6 * * *`)
  - `reprocessar_despacho` (`* * * * *`)
  - `retencao_e_limpeza_diaria` (`30 6 * * *`)
  - `verificar_saude` (`*/5 * * * *`)
- **Filas de Mensageria (`pgmq`):**
  - `pgmq.q_despacho`: fila durável de oportunidades e cancelamentos de vagas.
  - `email`: fila durável de e-mails transacionais.

### Portões de Qualidade e CI/CD (`.github/workflows/ci.yml`)
- **Esteira de 14 portões automatizados em 6 jobs paralelos:**
  1. `Migrações sem colisão de versão` (`scripts/migracoes-sem-colisao.sh`): bloqueia colisões de identificador de versão entre PRs simultâneos.
  2. `Migrações imutáveis` (`scripts/migracoes-imutaveis.sh`): impede alterações retroativas em migrações já consolidadas na base.
  3. `pgTAP` (`supabase test db`): suíte relacional abrangendo 83 arquivos de teste e 2362 asserções.
  4. `Corridas e concorrência` (`scripts/corrida-*.sh`):
     - Candidatura concorrente da RN19 (20 conexões simultâneas).
     - Cadastro concorrente de estabelecimento pelo mesmo titular.
     - 10 cenários de concorrência em 50 rodadas cada (reabertura x check-in, cancelamento x candidatura, despacho x teto).
  5. `Ciclo completo HTTP` (`scripts/ciclo-completo.sh`): smoke test e2e de ponta a ponta validando status HTTP e envelopes de erro.
  6. `Contas de demonstração HTTP` (`scripts/demonstracao.sh`): verificação do fluxo e credenciais de revisão da App Store por HTTP.
  7. `Mutação de regras de banco` (`scripts/mutacao.sh`): teste de mutação derrubando individualmente `CHECK`, triggers, políticas e restrições de unicidade (PR #128) para garantir que testes falhem na ausência da regra.
  8. `Lint PL/pgSQL` (`scripts/lint-conhecido.sh`): análise com `plpgsql_check` e rastreamento de achados conhecidos.
  9. `Relógio do produto` (`scripts/relogio-do-produto.sh`): inspeção estática no `pg_proc` assegurando ausência de chamadas a `now()`.
  10. `Contrato acompanha o código` (`scripts/contrato-acompanha-o-codigo.sh`): vincula mudanças em `public` a atualizações no contrato OpenAPI ou marcação formal de corpo sem mudança de superfície (PR #136).
  11. `Contrato em dia` (`scripts/contrato-em-dia.sh`): garantia de paridade SHA-256 entre o espelho local e o repositório de documentação.
  12. `Contrato responde e auditoria de coleções` (`scripts/contrato-responde.sh`): validação de payloads reais de 44 RPCs contra o schema OpenAPI, exigindo 100% de preenchimento das 36 coleções auditadas (PR #140).
  13. `Testes em Deno` (`supabase/functions`): 171 testes unitários e de integração das Edge Functions (PR #78).
  14. `Plano do caminho quente sob volume do DF` (`scripts/planos-com-carga.sh`): carga sintética (100k profissionais, 30k contratantes, 20k vagas) exigindo zero `Seq Scan` e p95 < 400ms em elegíveis e < 600ms em vagas abertas (PR #67).

### Infraestrutura, Backup e Segurança
- **Ensaio de Restauração de Backup (RNF12, PR #119 e #120):**
  - Automação de dump lógico (`scripts/ensaio-restauracao.sh`) com criptografia AES-256 e validação exata de contagem de linhas e pgTAP em banco restaurado. Workflow agendado em `.github/workflows/ensaio-backup.yml`.
- **Janela de Manutenção Protegida (RNF12, PR #89):**
  - Bloqueio automático de migrações nos horários de pico operacional do food service (quinta a domingo das 16h às 02h) via `scripts/janela-de-manutencao.sh` e testes em `scripts/teste-entrega.sh`.
- **Mitigação de Impasses Concorrentes:**
  - Resolução definitiva de deadlock `40P01` entre `excluir_conta` e `candidatar` através de ordenação canônica de travas (PR #101).
  - Robustecimento de margens de temporização e isolamento de transações no agendador do teto (PR #134).
