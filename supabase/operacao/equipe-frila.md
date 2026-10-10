# Procedimento Operacional: Equipe Frila

Este documento padroniza a rotina operacional da Equipe Frila no atendimento a suporte, denúncias, contestações de suspensão, revisão de despacho e solicitações de direitos dos titulares (LGPD).

Requisitos e diretrizes: **D01 a D16, RN13, RN15, RF23, RF25, RF26, RF27, UC14, UC15, UC17, contrato 0.2.40 e Diretriz 1.2 da App Store**.

---

## 1. Rotina Diária e Prazos de Atendimento

A caixa oficial (`suporte@frila.app`) e a fila de ocorrências do banco de dados são monitoradas diariamente por membros designados da Equipe Frila.

| Tipo de Demanda | Prazo Máximo de Tratamento | SLA / Fundamento |
|---|---|---|
| **Denúncia de conteúdo (vagas)** | **Até 24 horas** | Diretriz 1.2 da App Store |
| **Denúncia entre partes (assédio, fraude, violência)** | **Até 5 dias úteis** | RN13 / RF26 / UC17 |
| **Contestação de suspensão** | **Até 5 dias úteis** | RN13 / UC15 |
| **Revisão de despacho ("Por que recebo vagas")** | **Até 5 dias úteis** | RF27 / LGPD art. 20 |
| **Solicitação de dados do titular (LGPD)** | **Até 5 dias úteis** | LGPD art. 18 / RF25 |
| **Suporte a partir do turno (via e-mail `suporte@frila.app`)** | **Até 5 dias úteis** | RF23 / UC14 / D1=C / Contrato 0.2.40 |
| **Suporte geral e dúvidas** | **Até 5 dias úteis** | UC14 |

---

## 2. Triagem e Consulta de Chamados Pendentes

Os operadores devem executar o script `consultar-ocorrencias.sql` via console ou executar a query no painel seguro do Supabase:

```bash
psql -f supabase/operacao/consultar-ocorrencias.sql
```

A consulta classifica por prioridade, destacando chamados com prazo crítico de 24h (Diretriz 1.2) antes dos demais prazos regulamentares de 5 dias úteis (suporte e LGPD).

Campos retornados na consulta:
- `ocorrencia_id`: identificador UUID único da ocorrência no banco.
- `protocolo_curto`: 8 primeiros caracteres hexadecimais em maiúsculas gerados a partir do UUID (`protocoloCurto(id)`), correspondente ao assunto do e-mail.
- `tipo`: tipo da ocorrência (`suporte`, `denuncia`, `contestacao_suspensao`, `revisao_despacho`, `cancelamento`).
- `origem`: canal de abertura (`app` para chamados abertos pelo aplicativo via RPC `abrir_suporte`, `operacao` para procedimentos internos da equipe, ou nulo para legadas).
- `motivo`: motivo ou categoria do chamado (para suporte: `endereco`, `atraso`, `conduta`, `seguranca`, `outro`).
- `turno_id`: UUID do turno vinculado ao chamado de suporte ou denúncia.
- `criada_em` e `prazo_limite`: data de abertura e SLA limite em dias úteis calculado por `privado.prazo_de_resposta`.
- `prioridade_sla`: classificação visual de prazo.
- `autor_nome`, `autor_telefone`, `autor_perfil`: dados cadastrais do autor obtidos por join interno (`usuario`).
- `relato`: texto livre da ocorrência (nulo para chamados de suporte, garantindo privacidade e LGPD).

Filtros úteis no console:
```bash
# Localizar chamado pelo protocolo curto (8 caracteres do assunto):
psql -c "select * from (...) where protocolo_curto = 'A1B2C3D4'"

# Filtrar exclusivamente a fila de suporte aberta pelo app:
psql -c "select * from (...) where tipo = 'suporte' and origem = 'app'"
```

> 🔒 **Sigilo e LGPD (RN15):** Os relatos dos usuários contêm dados pessoais e confidenciais. É expressamente vedado compartilhar prints ou textos de relatos fora do ambiente operacional seguro.

---

## 3. Suporte por E-mail a partir do Turno (`suporte@frila.app`)

O atendimento de suporte a partir de um turno opera segundo o modelo da **Opção C** (v1.1, D1 a D16, contrato 0.2.40): sem ingestão direta de e-mails pelo backend. O fluxo conecta o aplicativo móvel, o banco de dados e a caixa postal oficial.

### 3.1. Endereço Oficial
O endereço único e oficial de suporte da plataforma Frila é:
```
suporte@frila.app
```
(D2: unifica e substitui qualquer endereço anterior ou legado).

### 3.2. Fluxo do Usuário no Aplicativo (UC14, RF23)
1. No turno em andamento ou já realizado, o usuário toca em "Ajuda no turno" e seleciona uma categoria (`endereco`, `atraso`, `conduta`, `seguranca`, `outro`).
2. Se a categoria for `seguranca`, o aplicativo apresenta imediatamente os atalhos para discagem de emergência (190 e 180) antes de qualquer outra ação.
3. O app chama a RPC `public.abrir_suporte(turno_id, categoria, chave)`:
   - Exige sessão autenticada (`401`) e conta ativa (`403 conta_suspensa` se suspensa).
   - Valida que o chamador é parte legítima do turno (profissional confirmado ou membro do estabelecimento da vaga, devolvendo `404` idêntico para turno inexistente ou alheio).
   - Aplica teto de segurança de **5 chamados novos por conta por dia** no fuso de Brasília (`429 limite_excedido`).
   - Aplica idempotência estrita pela `chave`: reenvios com a mesma chave devolvem o protocolo já gerado sem consumir novo teto diário.
4. A RPC grava em `public.ocorrencia`: `tipo = 'suporte'`, `origem = 'app'`, `turno_id`, `motivo = categoria` e `relato = null`. **Nenhum texto livre é gravado no banco nem enfileirado na fila `email`** (RN15, SU-RN03, SU-RN08).
5. O app exibe o prazo regulamentar calculado (`prazo_resposta_ate`, até 5 dias úteis) e aciona o cliente de e-mail padrão do aparelho:
   - **Destinatário:** `suporte@frila.app`
   - **Assunto pré-preenchido:** `[Frila Suporte #<protocolo curto>]` (ex.: `[Frila Suporte #A1B2C3D4]`)
   - **Corpo pré-preenchido:** identificação do turno para contexto.
6. O usuário redige seu relato e envia o e-mail diretamente por seu provedor.

### 3.3. Rotina da Equipe Frila ao Tratar o Chamado
1. O operador monitora a caixa `suporte@frila.app` e executa periodicamente `consultar-ocorrencias.sql`.
2. Ao receber um e-mail com assunto `[Frila Suporte #<protocolo curto>]`, o operador busca a ocorrência na fila pelo `protocolo_curto`.
3. Em caso de eventual colisão teórica dos 8 hexadecimais, o operador utiliza o `turno_id` e os dados do usuário para desambiguação.
4. O operador analisa o caso consultando os dados do turno e da vaga no banco, redige a orientação e responde ao usuário pelo próprio e-mail corporativo.
5. Concluído o atendimento, o operador fecha a ocorrência no banco atualizando `resolvido_em` e `resultado`:
   ```sql
   update public.ocorrencia
      set resolvido_em = now(),
          resultado = 'Esclarecidas orientações de conduta e repasse de turno.'
    where id = '<ocorrencia_id>'
      and resolvido_em is null;
   ```

### 3.4. Chamado sem E-mail Recebido (D16, SU-RN10)
Se um usuário acionar "Ajuda no turno" no aplicativo (abrindo o chamado na fila), mas **nunca enviar o e-mail** (ou o e-mail não chegar) dentro do prazo regulamentar de 5 dias úteis (`prazo_limite` vencido em `consultar-ocorrencias.sql`):
- A Equipe Frila fecha o chamado manualmente executando o script dedicado `fechar-chamado-sem-email.sql` (seção 5.4).
- O encerramento grava formalmente `resultado = 'sem_email_recebido'` e `resolvido_em = now()`.

---

## 4. Critérios de Classificação de Denúncias

Toda denúncia registrada deve ser avaliada sob três critérios objetivos:

### 4.1. Denúncia Grave (Suspensão Imediata - RN13)
- **Hipóteses:**
  - Assédio moral, sexual ou discriminação (raça, gênero, orientação, religião).
  - Agressão física ou ameaça à integridade física no turno.
  - Fraude financeira, extorsão ou cobrança indevida por fora da plataforma.
  - Documentação falsa ou falsidade ideológica cadastral.
- **Ação:**
  - Confirmada a veracidade preliminar com as partes ou mediante comprovantes (mensagens, fotos, áudios), executar `suspender-conta.sql`.
  - O script suspende o usuário (`estado = 'suspensa'`), cancela turnos futuros e grava a ocorrência.

### 4.2. Denúncia de Conteúdo (Moderação em 24h - Diretriz 1.2)
- **Hipóteses:**
  - Vaga contendo termo ofensivo que escapou ao filtro, dados de contato explícitos na descrição, ou exigências discriminatórias.
- **Ação:**
  - Executar `moderar-conteudo.sql` com ação `ocultar`.
  - A vaga **não é cancelada** (decisão de 29/09, contrato 0.2.23): sai da vitrine, do despacho e dos avisos de vaga, não recebe candidatura nova, a casa não escolhe candidato nem a republica (`422 vaga_oculta`) e vê a vaga como "oculta pela Equipe" no painel. Confirmados seguem confirmados e candidaturas pendentes seguem pendentes. O autor é orientado por e-mail. **Não suspender sumariamente** se for a primeira infração leve de texto (RN13).
  - Corrigido o conteúdo, executar `moderar-conteudo.sql` com ação `reexibir`. Reexibir **só vale para a vaga que a Equipe ocultou** (senão `422 campo_invalido`, `details: vaga_nao_ocultada`) e não muda o estado: vaga que a casa cancelou continua cancelada.

### 4.3. Denúncia Improcedente ou Desentendimento Leve
- **Hipóteses:**
  - Divergência simples sobre execução de tarefa no turno, reclamação de atraso isolado (já tratado pelo motor de avaliação e comparecimento).
- **Ação:**
  - Registrar arquivamento na ocorrência e responder às partes orientando o uso das avaliações e suporte mútuo.

---

## 5. Execução dos Scripts Operacionais

Todos os scripts operacionais utilizam transações atômicas e gravam ocorrências auditáveis em `public.ocorrencia`. **Nunca altere diretamente as tabelas por UPDATE sem registro de ocorrência.**

Nos scripts de suspensão, reativação e moderação, exige-se `operador_id`: o id em `public.usuario` da conta do membro da Equipe Frila que executa. Ele é o autor da ocorrência, nunca o alvo. Assim o motivo de uma suspensão não some quando a conta suspensa é excluída (a retenção apaga o relato das ocorrências de autoria da conta excluída), e a exportação de dados do alvo não lhe atribui o texto interno da equipe. A conta do operador precisa estar ativa e não pode ser a do alvo.

### 5.1. Suspender Conta
```bash
psql -v usuario_id="<uuid-do-usuario>" \
     -v motivo="Denúncia grave confirmada: assédio verbal no turno do dia 28/09." \
     -v operador_id="<uuid-do-operador>" \
     -f supabase/operacao/suspender-conta.sql
```

### 5.2. Reativar Conta (Após Julgamento de Contestação)
```bash
psql -v usuario_id="<uuid-do-usuario>" \
     -v justificativa="Contestação aceita: comprovado que o profissional esteve no local e não houve recusa dolosa." \
     -v operador_id="<uuid-do-operador>" \
     -f supabase/operacao/reativar-conta.sql
```

### 5.3. Moderação de Conteúdo (Ocultar / Reexibir)
```bash
# Ocultar vaga denunciada
psql -v vaga_id="<uuid-da-vaga>" \
     -v acao="ocultar" \
     -v motivo="Observações contêm texto desrespeitoso aos candidatos." \
     -v operador_id="<uuid-do-operador>" \
     -f supabase/operacao/moderar-conteudo.sql

# Reexibir vaga corrigida
psql -v vaga_id="<uuid-da-vaga>" \
     -v acao="reexibir" \
     -v motivo="Vaga revisada e conteúdo regularizado pelo contratante." \
     -v operador_id="<uuid-do-operador>" \
     -f supabase/operacao/moderar-conteudo.sql
```

### 5.4. Fechar Chamado Manual sem E-mail Recebido (D16, SU-RN10)
Quando o prazo de 5 dias úteis do chamado de suporte expirar e nenhum e-mail tiver sido recebido na caixa postal:
```bash
# Pelo UUID da ocorrência:
psql -v ocorrencia_id="<uuid-da-ocorrencia>" \
     -f supabase/operacao/fechar-chamado-sem-email.sql

# Ou pelo protocolo curto (8 hexadecimais):
psql -v protocolo_curto="A1B2C3D4" \
     -f supabase/operacao/fechar-chamado-sem-email.sql

# Opcionalmente, especificando outro resultado:
psql -v ocorrencia_id="<uuid-da-ocorrencia>" \
     -v resultado="atendido_por_outro_canal" \
     -f supabase/operacao/fechar-chamado-sem-email.sql
```

---

## 6. Retenção de Dados e Prática de Apagar E-mails (LGPD)

O Frila opera sob o princípio da necessidade e minimização de dados (LGPD art. 6º, III; art. 18; RN15, RF25, D9, SU-RN11):

1. **Privacidade por Desenho (Privacy by Design):**
   - O banco de dados do Frila **não armazena o corpo dos e-mails de suporte, nem textos livres ou anexos**.
   - Na tabela `public.ocorrencia`, residem exclusivamente dados estruturados: categoria (`motivo`), identificador do turno (`turno_id`), autor (`autor_id`), origem (`app`), datas de SLA e resultado objetivo. O campo `relato` é mantido nulo.
2. **Prática Obrigatória de Expulgo na Caixa de E-mail (D9, SU-RN11):**
   - O texto livre e eventuais anexos (comprovantes, mensagens, fotos) permanecem estritamente na caixa `suporte@frila.app`.
   - **Ao concluir e fechar o chamado no banco:** O operador responsável deve **apagar o e-mail e o histórico da conversa da caixa postal**, esvaziando inclusive a pasta de Itens Excluídos / Lixeira. O histórico auditável da tratativa permanece preservado no banco através do registro da ocorrência com `resolvido_em` e `resultado`.
   - É expressamente vedado manter acervo de e-mails antigos arquivados na caixa de entrada sem justificativa legal ativa.
3. **Direito do Titular à Exclusão de Conta (RF25, LGPD art. 18, VI):**
   - Quando um usuário solicita exclusão de conta via app (`excluir_conta`), o banco executa a anonimização cadastral imediata e aplica a rotina de retenção de até 15 dias.
   - Como a caixa de e-mail é externa ao banco de dados, a Equipe Frila deve verificar periodicamente e purgar em definitivo da caixa `suporte@frila.app` qualquer mensagem ou histórico vinculado à conta excluída ou aos seus protocolos.
4. **Segurança Operacional:**
   - O acesso à caixa `suporte@frila.app` é restrito a operadores autorizados, com autenticação em dois fatores (2FA/MFA) habilitada obrigatoriamente.
   - É terminantemente proibido encaminhar mensagens de suporte contendo relatos ou dados de usuários para e-mails pessoais.

---

## 7. Modelos Oficiais de Resposta por E-mail

Ao responder às partes, use exclusivamente os modelos abaixo adaptando os campos entre colchetes. Mantenha tom formal, transparente e acolhedor.

### Modelo A: Suspensão de Conta (Notificação ao Usuário Suspenso)
```
Assunto: [Frila] Notificação importante sobre sua conta

Olá, [Nome do Usuário].

Informamos que sua conta na plataforma Frila foi suspensa temporariamente com base nos Termos de Uso e nas Diretrizes da Comunidade (RN13).

Motivo do registro: [Descrição objetiva e sem termos acusatórios da ocorrência].

Turnos futuros que estavam confirmados foram cancelados para resguardar as partes envolvidas.

Caso você discorde desta decisão, é possível apresentar contestação formal em até 5 dias úteis respondendo a este e-mail ou diretamente pela tela do aplicativo, anexando eventuais esclarecimentos ou comprovantes.

Atenciosamente,
Equipe Frila
```

### Modelo B: Contestação Acolhida (Reativação de Conta)
```
Assunto: [Frila] Decisão sobre sua contestação: conta reativada

Olá, [Nome do Usuário].

A Equipe Frila analisou os esclarecimentos e comprovantes enviados referentes à contestação do protocolo [Protocolo/ID].

Concluímos pela reativação imediata da sua conta. Você já pode acessar o aplicativo e participar das oportunidades normalmente.

Agradecemos a colaboração e contamos com você para manter nossa comunidade segura.

Atenciosamente,
Equipe Frila
```

### Modelo C: Moderação de Vaga (Diretriz 1.2)
```
Assunto: [Frila] Aviso sobre vaga publicada

Olá, [Nome do Contratante].

Identificamos que a vaga "[Função] - [Local]" publicada recentemente continha termos ou instruções em desacordo com as Diretrizes da Comunidade (Diretriz 1.2 da App Store).

Para manter a conformidade do ambiente, a vaga foi cancelada e os candidatos notificados.

Você pode cadastrar uma nova vaga a qualquer momento observando o padrão de comunicação e as orientações do aplicativo.

Atenciosamente,
Equipe Frila
```

### Modelo D: Atendimento a Solicitação de Dados Pessoais (LGPD art. 18 / RF25)
```
Assunto: [Frila] Resposta à sua solicitação de dados (LGPD)

Olá, [Nome do Titular].

Em atendimento à sua solicitação registrada sob o protocolo [Protocolo/ID], em conformidade com o artigo 18 da Lei Geral de Proteção de Dados (Lei nº 13.709/2018), disponibilizamos o extrato de dados cadastrais e histórico de turnos vinculados ao seu CPF/Telefone.

Informamos que seus dados são mantidos com base nas finalidades contratuais e nos prazos regulamentares da nossa Política de Privacidade. Caso deseje a exclusão definitiva, você também pode solicitar diretamente pelo menu "Configurações > Excluir Conta" do aplicativo.

Permanecemos à disposição para eventuais dúvidas.

Atenciosamente,
Encarregado de Dados (DPO) / Equipe Frila
```

### Modelo E: Resposta a Suporte de Turno (`suporte@frila.app`)
```
Assunto: Re: [Frila Suporte #[Protocolo Curto]]

Olá, [Nome do Usuário].

Recebemos seu pedido de suporte referente ao turno [Data/Função] sob o protocolo #[Protocolo Curto].

[Esclarecimento objetivo ou providência adotada pela Equipe Frila em relação à categoria reportada: endereço, atraso, conduta, segurança ou dúvidas gerais].

Ressaltamos que os registros operacionais do turno foram atualizados conforme as diretrizes da plataforma. Se precisar de novos esclarecimentos, basta responder a este e-mail mantendo o protocolo no assunto.

Atenciosamente,
Equipe Frila
suporte@frila.app
```
