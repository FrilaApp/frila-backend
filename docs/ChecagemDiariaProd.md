# Guia Operacional · Checagem Diária de Produção e Plantão do Piloto

Documentação e procedimentos do script de inspeção operacional diária do backend Frila.

Cartão: `42` (S4 · Infra · Monitoramento de produção e plantão do piloto).

---

## 1. Visão Geral e Princípios

O script `scripts/checagem-diaria.sh` foi desenvolvido para fornecer ao operador humano de plantão (Cauê Carneiro / Equipe Operacional) um diagnóstico completo do estado do banco de produção em **menos de 10 minutos** durante a operação do piloto.

### Princípios de Segurança e Operação
1. **100% Só Leitura (Zero Mutação):** Todas as consultas são executadas sob `SET default_transaction_read_only = on;`. O script é estritamente não-invasivo e bloqueia qualquer tentativa de escrita no banco de dados.
2. **Zero Segredos no Repositório:** Nenhuma credencial ou URL sensível é versionada no repositório. O acesso a bancos remotos é configurado via variáveis de ambiente efêmeras na sessão do terminal (`DATABASE_URL`).
3. **Operação em Produção é Exclusivamente Humana:** O script em produção deve ser executado exclusivamente por humanos autorizados. Nenhuma ferramenta de IA ou rotina autônoma não-supervisionada tem autorização de conectar em produção.
4. **Veredito Visual Semafórico:** A saída culmina em um semáforo objetivo (🟢 **VERDE**, 🟡 **AMARELO** ou 🔴 **VERMELHO**) acompanhado de ações corretivas imediatas.

---

## 2. Como Executar

### 2.1 Em Produção (Operador Humano)
No ambiente do plantonista, forneça a string de conexão direta do PostgreSQL do projeto Supabase de produção (ou pooler de transação):

```bash
# Execução direta via DATABASE_URL
DATABASE_URL="postgres://postgres.[ref]:[senha]@[host]:5432/postgres?sslmode=require" ./scripts/checagem-diaria.sh
```

Ou usando as variáveis canônicas do PostgreSQL:
```bash
export PGHOST="aws-0-sa-east-1.pooler.supabase.com"
export PGPORT="5432"
export PGDATABASE="postgres"
export PGUSER="postgres.[ref]"
export PGPASSWORD="[senha]"

./scripts/checagem-diaria.sh
```

### 2.2 Em Banco Local de Desenvolvimento / Testes
O script detecta automaticamente o container Docker local do Supabase (`supabase_db_frila-backend`). Se estiver usando a orquestração do time, respeite a fila:

```bash
# Obter trava de recurso do banco local
/Users/cauecarneiro/Documents/Projetos/Frila/orquestracao/scripts/fila.sh pegar banco <seu-nome>

# Rodar a checagem diária local
./scripts/checagem-diaria.sh

# Liberar trava ao terminar
/Users/cauecarneiro/Documents/Projetos/Frila/orquestracao/scripts/fila.sh soltar banco <seu-nome>
```

---

## 3. Roteiro de Inspeção (~10 Minutos)

O script executa 7 blocos estruturados de checagem:

### Bloco 1 · Saúde Geral e Agendador do Sistema (pg_cron / RNF12)
- **O que verifica:**
  - Status dos **13 jobs cadastrados no pg_cron** (`cron.job`). Todos devem estar com `active = true`.
  - Histórico de execuções nas últimas 24h (`cron.job_run_details`). Identifica jobs com `status != 'succeeded'`.
  - Alertas emitidos em `privado.alerta_emitido` nas últimas 24h (ex: transporte pgnet, filas retidas).
- **Tempo de leitura:** 1 minuto.
- **Critério de Alerta:**
  - 🔴 Jobs inativos ou falhas registradas no cron.

### Bloco 2 · Fila de Despacho e Notificações Push (pgmq / FCM)
- **O que verifica:**
  - Mensagens pendentes na fila `pgmq.q_despacho`.
  - Notificações push (`public.notificacao`) das últimas 24h agrupadas por status (`entregue`, `falhou`, `pendente`).
  - Notificações retidas em estado `pendente` há mais de 10 minutos (indica gargalo na Edge Function de push).
  - Despachos confirmados sem notificação vinculada.
- **Tempo de leitura:** 1 minuto.
- **Critério de Alerta:**
  - 🟡 Notificações pendentes há > 10 min.
  - 🔴 Despachos travados sem notificação.

### Bloco 3 · Falhas de Execução Interna (`privado.falha_execucao`)
- **O que verifica:**
  - Ocorrências capturadas pelo bloco `EXCEPTION` das funções centrais (`despachar_vaga`, `notificar`, `confirmar_presenca`, etc.) nas últimas 24h.
- **Tempo de leitura:** 30 segundos.
- **Critério de Alerta:**
  - 🔴 Qualquer falha interna registrada requer abertura de chamado e inspeção de logs.

### Bloco 4 · Moderação de Conteúdo e Suporte (Diretriz 1.2 App Store / RN13)
- **O que verifica:**
  - Denúncias não analisadas em `privado.moderacao_pendente`.
  - Prazo limite estrito de **24 horas** imposto pela Apple (Diretriz 1.2 da App Store).
  - Chamados abertos de suporte, revisão de despacho e cancelamento em `privado.ocorrencia`.
- **Tempo de leitura:** 1 minuto.
- **Critério de Alerta:**
  - 🟡 Denúncias pendentes com menos de 12h.
  - 🔴 Denúncias pendentes com **mais de 12h** (risco iminente de estourar SLA de 24h) ou já vencidas (> 24h).

### Bloco 5 · E-mails Transacionais (pgmq / Resend)
- **O que verifica:**
  - Mensagens pendentes na fila `pgmq.q_email`.
  - Idade da mensagem mais antiga na fila.
  - Erros operacionais de envio de e-mail registrados em `privado.ocorrencia`.
- **Tempo de leitura:** 1 minuto.
- **Critério de Alerta:**
  - 🟡 Mensagens na fila há > 5 minutos.
  - 🔴 Mensagens na fila há > 15 minutos ou erros repetidos de transporte.

### Bloco 6 · Turnos e Presenças do Piloto (Operação Real)
- **O que verifica:**
  - Turnos em andamento com status `confirmada` dentro da janela de horário prevista.
  - Turnos anômalos sem check-out que já ultrapassaram a tolerância de 24 horas (`fim_em + interval '24 hours' < now()`).
  - Turnos abandonados há mais de 7 dias (`fim_em + interval '7 days' < now()`) pendentes de expurgo/sanitização legal.
  - Vagas e textos sob intervenção de moderação (`vaga.oculta = true`, `privado.texto_da_vaga_ocultado`).
- **Tempo de leitura:** 1 minuto.
- **Critério de Alerta:**
  - 🟡 Turnos sem check-out entre 24h e 7 dias.
  - 🔴 Turnos abandonados há mais de 7 dias ainda retendo dados pessoais sensíveis.

### Bloco 7 · Recursos e Volume do Banco de Dados
- **O que verifica:**
  - Tamanho em disco do banco de dados (`pg_database_size`).
  - Contagem total de usuários ativos, estabelecimentos e vagas cadastradas.
- **Tempo de leitura:** 30 segundos.

---

## 4. Matriz de Decisão e Planos de Ação (Vereditos)

| Veredito | Código de Saída | Significado | Ação Imediata do Plantonista |
| :--- | :---: | :--- | :--- |
| 🟢 **VERDE** | `0` | Operação normal e estável. | Nenhuma ação corretiva. Registrar checagem no log de plantão. |
| 🟡 **AMARELO** | `1` | Atenção operacional. Riscos potenciais identificados. | 1. Verificar volume de denúncias e tratar pendências.<br>2. Observar latência dos workers de Edge Function.<br>3. Monitorar turnos abertos. |
| 🔴 **VERMELHO** | `1` | Incidente em curso ou risco regulatório imediato. | **ACIONAMENTO IMEDIATO:**<br>1. Se pg_cron inativo: reativar jobs e consultar `docs/RUNBOOK-INCIDENTES.md`.<br>2. Se denúncia > 12h: executar `./scripts/moderar.sh pendentes 24` e analisar denúncia.<br>3. Se fila de despacho/e-mail travada: reiniciar Edge Functions de consumo no Supabase Dashboard.<br>4. Se falhas internas: inspecionar `privado.falha_execucao`. |

---

## 5. Teste Automatizado do Script

O script possui suíte de testes de validação contínua em `scripts/teste-checagem-diaria.sh`, que garante:
1. Execução padrão íntegra com emissão de todas as 8 seções obrigatórias.
2. Garantia inviolável de que mutações de escrita são rejeitadas em tempo de execução (`read-only`).
3. Resiliência fail-closed com exit code `2` quando a conexão ao banco falha.

Para rodar a suíte localmente:
```bash
/Users/cauecarneiro/Documents/Projetos/Frila/orquestracao/scripts/fila.sh pegar banco <seu-nome>
./scripts/teste-checagem-diaria.sh
/Users/cauecarneiro/Documents/Projetos/Frila/orquestracao/scripts/fila.sh soltar banco <seu-nome>
```
