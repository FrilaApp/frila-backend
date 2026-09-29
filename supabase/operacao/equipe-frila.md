# Procedimento Operacional: Equipe Frila

Este documento padroniza a rotina operacional da Equipe Frila no atendimento a suporte, denúncias, contestações de suspensão, revisão de despacho e solicitações de direitos dos titulares (LGPD).

Requisitos e diretrizes: **D01, D02, D03, RN13, RF25, RF26, RF27, UC14, UC15, UC17 e Diretriz 1.2 da App Store**.

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
| **Suporte geral e dúvidas** | **Até 5 dias úteis** | UC14 |

---

## 2. Triagem e Consulta de Chamados Pendentes

Os operadores devem executar o script `consultar-ocorrencias.sql` via console ou executar a query no painel seguro do Supabase:

```bash
psql -f supabase/operacao/consultar-ocorrencias.sql
```

A consulta classifica por prioridade, destacando chamados com prazo crítico de 24h (Diretriz 1.2) antes dos demais prazos regulamentares de 5 dias úteis.

> 🔒 **Sigilo e LGPD (RN15):** Os relatos dos usuários contêm dados pessoais e confidenciais. É expressamente vedado compartilhar prints ou textos de relatos fora do ambiente operacional seguro.

---

## 3. Critérios de Classificação de Denúncias

Toda denúncia registrada deve ser avaliada sob três critérios objetivos:

### 3.1. Denúncia Grave (Suspensão Imediata - RN13)
- **Hipóteses:**
  - Assédio moral, sexual ou discriminação (raça, gênero, orientação, religião).
  - Agressão física ou ameaça à integridade física no turno.
  - Fraude financeira, extorsão ou cobrança indevida por fora da plataforma.
  - Documentação falsa ou falsidade ideológica cadastral.
- **Ação:**
  - Confirmada a veracidade preliminar com as partes ou mediante comprovantes (mensagens, fotos, áudios), executar `suspender-conta.sql`.
  - O script suspende o usuário (`estado = 'suspensa'`), cancela turnos futuros e grava a ocorrência.

### 3.2. Denúncia de Conteúdo (Moderação em 24h - Diretriz 1.2)
- **Hipóteses:**
  - Vaga contendo termo ofensivo que escapou ao filtro, dados de contato explícitos na descrição, ou exigências discriminatórias.
- **Ação:**
  - Executar `moderar-conteudo.sql` com ação `ocultar`.
  - A vaga **não é cancelada** (decisão de 29/09, contrato 0.2.23): sai da vitrine, do despacho e dos avisos de vaga, não recebe candidatura nova, a casa não escolhe candidato nem a republica (`422 vaga_oculta`) e vê a vaga como "oculta pela Equipe" no painel. Confirmados seguem confirmados e candidaturas pendentes seguem pendentes. O autor é orientado por e-mail. **Não suspender sumariamente** se for a primeira infração leve de texto (RN13).
  - Corrigido o conteúdo, executar `moderar-conteudo.sql` com ação `reexibir`. Reexibir **só vale para a vaga que a Equipe ocultou** (senão `422 campo_invalido`, `details: vaga_nao_ocultada`) e não muda o estado: vaga que a casa cancelou continua cancelada.

### 3.3. Denúncia Improcedente ou Desentendimento Leve
- **Hipóteses:**
  - Divergência simples sobre execução de tarefa no turno, reclamação de atraso isolado (já tratado pelo motor de avaliação e comparecimento).
- **Ação:**
  - Registrar arquivamento na ocorrência e responder às partes orientando o uso das avaliações e suporte mútuo.

---

## 4. Execução dos Scripts Operacionais

Todos os scripts operacionais utilizam transações atômicas e gravam ocorrências auditáveis em `public.ocorrencia`. **Nunca altere diretamente as tabelas por UPDATE sem registro de ocorrência.**

Todo script exige `operador_id`: o id em `public.usuario` da conta do membro da Equipe Frila que executa. Ele é o autor da ocorrência, nunca o alvo. Assim o motivo de uma suspensão não some quando a conta suspensa é excluída (a retenção apaga o relato das ocorrências de autoria da conta excluída), e a exportação de dados do alvo não lhe atribui o texto interno da equipe. A conta do operador precisa estar ativa e não pode ser a do alvo.

### 4.1. Suspender Conta
```bash
psql -v usuario_id="<uuid-do-usuario>" \
     -v motivo="Denúncia grave confirmada: assédio verbal no turno do dia 28/09." \
     -v operador_id="<uuid-do-operador>" \
     -f supabase/operacao/suspender-conta.sql
```

### 4.2. Reativar Conta (Após Julgamento de Contestação)
```bash
psql -v usuario_id="<uuid-do-usuario>" \
     -v justificativa="Contestação aceita: comprovado que o profissional esteve no local e não houve recusa dolosa." \
     -v operador_id="<uuid-do-operador>" \
     -f supabase/operacao/reativar-conta.sql
```

### 4.3. Moderação de Conteúdo (Ocultar / Reexibir)
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

---

## 5. Modelos Oficiais de Resposta por E-mail

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
