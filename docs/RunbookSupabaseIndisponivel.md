# Runbook: Supabase pausado ou indisponível

O backend inteiro do Frila (banco, Auth, Edge Functions, `pg_cron`, Vault) roda em dois projetos Supabase em `sa-east-1`: `frila-dev` (`jcobftbhbqdikratzizz`) e `frila-prod` (`hbjkkcenbudiezmamiak`) (`docs/ESTADO.md`, seção "Ambientes"). Este runbook cobre dois casos diferentes, que se distinguem na seção 2:

- **Pausa:** o projeto foi pausado por inatividade ou por decisão de alguém.
- **Indisponibilidade:** o projeto ou a região do fornecedor está fora do ar.

Convenção (a mesma de `docs/RunbookRotacaoDeSegredos.md`): **MEDIDO** é o que foi lido de uma execução real, com data e fonte; **LIDO** é texto do repositório; **DEDUZIDO** é raciocínio; **NAO EXECUTADO: sem banco local** marca cada SQL; **A DEFINIR (Caue)** é fato que só o Cauê sabe.

---

## 1. Sintoma

- O app não carrega vagas, não entra, não recebe aviso: todas as chamadas à API falham ao mesmo tempo.
- O workflow `Mantém o Prod vivo` (`.github/workflows/mantem-prod-vivo.yml`) fica vermelho. O próprio arquivo diz: "Se o projeto estiver pausado, só Owner ou Admin o reativa no painel do Supabase", e "um job vermelho aqui quer dizer que o Prod não respondeu 200: abra o projeto no painel antes de supor pausa".
- Os passos de Entrega, backup ou conferência de Auth falham ao falar com a API do Supabase.
- O e-mail de alerta **não chega**, mesmo com o problema evidente. É esperado: o alerta nasce dentro do banco (`pg_cron`, `pgmq`, `pg_net`) e sai por uma Edge Function (`docs/RUNBOOK-INCIDENTES.md`, seção 2). Se o banco caiu, o vigia caiu junto. Não há monitor externo que chame a `saude` em intervalo curto (buscado em `.github/workflows/` e `scripts/`, 16/11/2026: o único chamador agendado é o GET diário de `mantem-prod-vivo.yml`). Desde `731824c` (#512) o repositório tem aviso no Slack para a falha desse workflow (`.github/workflows/notifica-slack.yml`, mensagem "Prod Vivo Falhou"), mas ele só sai se o segredo `SLACK_WEBHOOK_URL` existir, e **MEDIDO em 16/11/2026** que a listagem de secrets do repositório não o inclui (só `FRILA_DOCS_TOKEN`); sem o segredo o script sai 0 em silêncio. Quem percebe primeiro hoje é o usuário ou o GitHub Actions.

### O que o repositório diz sobre pausa (LIDO)

- Os dois projetos rodam no **plano gratuito** segundo `README.md` (seção "Limites do plano gratuito do Supabase"): pausa depois de 1 semana sem uso, nenhum backup automático, cotas mensais somadas na organização (um laço no despacho do `frila-dev` consome a cota do `frila-prod`), dois projetos ativos por organização.
- **O plano atual do `frila-prod` é NAO MEDIDO.** O texto do README é de antes do pacote v1.1; ninguém conferiu o painel. **A DEFINIR (Caue)**: qual é o plano de cada projeto hoje, copiado do painel, com data. Isso muda o risco desta página inteira: em plano pago o projeto não pausa por inatividade (a documentação do fornecedor diz que projetos pagos não podem ser pausados: <https://supabase.com/docs/guides/platform/upgrading>, lida em 16/11/2026).
- `mantem-prod-vivo.yml` faz um GET por dia na função `saude` (cron `0 12 * * *`, 09:00 BRT) para o projeto não ficar uma semana sem uso. Que isso evite mesmo a pausa só se prova esperando mais de sete dias; que o Supabase conte esse GET como "uso": **não encontrado** (`docs/RunbookHotfixERollback.md`, seção 7).
- O workflow de Prod só roda a partir da branch padrão do repositório, que é a `develop` (`mantem-prod-vivo.yml`, comentário final do cabeçalho; branch padrão MEDIDA pelo relatório do mapa em 16/11/2026).
- Execuções recentes de `mantem-prod-vivo`: 18 de 19 `success` (uma falha em 29/10, anterior à criação da variável `FRILA_PROD_URL_SAUDE`), segundo o relatório do mapa de 16/11/2026, não reconferido por mim.

---

## 2. Diagnóstico (somente leitura)

### 2.1 De fora para dentro (sem credencial)

O endereço da função `saude` do Prod é público e está na variável de repositório `FRILA_PROD_URL_SAUDE` (forma: `https://<ref>.supabase.co/functions/v1/saude`; `mantem-prod-vivo.yml`). A função responde (`supabase/functions/saude/index.ts`, cabeçalho): `200` com `{"ok": true, "status": "saudavel", ...}` quando o banco responde **e** os jobs `reprocessar_despacho` e `verificar_saude` estão ativos com último sucesso dentro da tolerância (300 s e 900 s, padrão de `privado.consultar_saude_cron`, que devolve também `despacho_idade_segundos` e `vigia_idade_segundos`); `503` com `status: "atrasado"` quando o banco responde mas um desses jobs está inativo, sem sucesso registrado ou atrasado; `503` com `status: "indisponivel"` quando o banco não responde; `405` para POST; `HEAD` devolve 200 ou 503 sem corpo. Essa versão da função e a migração `20261116130000_probe_saude_cron.sql` vêm de `25f475a` (#514). **NAO MEDIDO:** se já estão no `frila-prod`. Uma função `saude` antiga devolve só `200` ou `503 indisponivel`, sem os campos de idade.

```bash
# Leitura. NAO EXECUTADO. Sem credencial, sem corpo, sem dado pessoal.
curl -sS --max-time 20 -o /dev/null -w '%{http_code}\n' "https://hbjkkcenbudiezmamiak.supabase.co/functions/v1/saude"
```

| Resposta | Leitura (DEDUZIDO) | Próximo passo |
|---|---|---|
| `200` | O projeto vive. O problema é outro (função específica, migração, push): `docs/RunbookPushParado.md`, `docs/RunbookRollbackEdgeFunction.md` | Fora deste runbook |
| `503` `indisponivel` | A plataforma de funções responde, o **banco não**. Pode ser banco sobrecarregado, em manutenção ou conexões esgotadas | 2.2 e 3.2 |
| `503` `atrasado` | O banco responde, mas `reprocessar_despacho` ou `verificar_saude` está inativo ou sem rodar. **Não é pausa nem queda**, embora o aviso do Slack para `Mantém o Prod vivo` diga "o banco pode estar pausado ou instável" (texto genérico de `notificar_slack.py`) | 2.3 (consulta de jobs) e `docs/RUNBOOK-INCIDENTES.md`, seção 3 |
| Timeout, erro de conexão, `5xx` do gateway | Projeto pausado, ou plataforma fora do ar | 2.2 |

### 2.2 Painel e página de status (leitura)

1. Abra o projeto no painel (`https://supabase.com/dashboard/project/hbjkkcenbudiezmamiak`). Pausado: o painel mostra o estado e o botão de restauração. **A DEFINIR (Caue)**: quem tem acesso de Owner/Admin hoje.
2. Página de status do fornecedor: <https://status.supabase.com>. **Não lida por esta revisão** (nenhuma consulta foi feita a essa página); confirme a URL e o escopo da região `sa-east-1` na hora.
3. Restauração de projeto pausado: a documentação do fornecedor diz que há uma janela de **1 ano** para restaurar pelo Studio, "a single button click", e que o projeto sobe na última versão menor do Postgres (<https://supabase.com/docs/guides/platform/upgrading>, lida em 16/11/2026). **Quanto tempo a restauração leva: NAO MEDIDO** (a página não dá número).

### 2.3 Depois que voltar (leitura, com credencial de humano)

Todos os SQL abaixo: **NAO EXECUTADO: sem banco local**. Rode em sessão `default_transaction_read_only = on`. Sem dado pessoal (RN15).

**A janela em que o banco ficou sem rodar jobs.** O job `processar_fila_email` roda a cada minuto (`docs/RUNBOOK-INCIDENTES.md`, seção 2, item 2), então uma hora sem ~60 execuções delimita o buraco.
NAO EXECUTADO: sem banco local.

```sql
select date_trunc('hour', d.start_time) as hora,
       count(*) as execucoes
  from cron.job_run_details d
 where d.jobid = (select jobid from cron.job where jobname = 'processar_fila_email')
   and d.start_time > now() - interval '72 hours'
 group by 1
 order by 1 desc;
```

**O que o probe de saúde enxerga (a mesma função que a `saude` chama).** Só leitura, sem dado pessoal. Só existe depois que a migração `20261116130000` estiver aplicada: **NAO MEDIDO** no Prod.
NAO EXECUTADO: sem banco local. Colunas de `privado.consultar_saude_cron()`: `20261116130000_probe_saude_cron.sql`.

```sql
select saudavel,
       status,
       despacho_idade_segundos,
       vigia_idade_segundos,
       despacho_ativo,
       vigia_ativo
  from privado.consultar_saude_cron();
```

**Os jobs do `pg_cron` voltaram? Quando cada um rodou pela última vez.** O número esperado de jobs não está fixo aqui: o pgTAP `supabase/tests/390_agendamentos_do_pg_cron.sql` lista 26 nomes conhecidos na `develop` em `a55aab0` (contagem por `awk`, 16/11/2026), e `scripts/checagem-diaria.sh` conta de forma dinâmica (`SELECT count(*) FROM cron.job`). O "13" que havia em `docs/ChecagemDiariaProd.md` foi corrigido nesta mesma entrega. Compare com `scripts/desvio.sh <ref>` (que confere os jobs do `pg_cron`: `README.md`, parágrafo "Desvio."; precisa de banco local, humano).
NAO EXECUTADO: sem banco local.

```sql
select j.jobname,
       j.active,
       j.schedule,
       max(d.start_time) as ultima_execucao,
       max(d.start_time) filter (where d.status = 'failed') as ultima_falha
  from cron.job j
  left join cron.job_run_details d on d.jobid = j.jobid
 group by j.jobname, j.active, j.schedule
 order by ultima_execucao nulls first, j.jobname;
```

Job `active = false` ou sem execução recente é o achado. Nota: o alerta existente `job_cron_falhou` não vê job que **nunca roda** (`20261108110000_lgpd_registro_acessos_borda.sql:575-586`).

**Filas acumuladas durante a queda.**
NAO EXECUTADO: sem banco local. Tabelas `pgmq.q_despacho` e `pgmq.q_email` como em `docs/RUNBOOK-INCIDENTES.md`, seções 1 e 2.

```sql
select 'despacho' as fila, count(*) as total, min(enqueued_at) as mais_antiga from pgmq.q_despacho
union all
select 'email' as fila, count(*) as total, min(enqueued_at) as mais_antiga from pgmq.q_email;
```

**Notificações presas.** Mesmo SQL da seção 2.1 de `docs/RunbookPushParado.md`.

**Vagas que deveriam ter fechado durante a queda.** O job `fechar_turnos_e_vagas` (a cada 5 minutos, `docs/RUNBOOK-INCIDENTES.md`, seção 3) fecha o que expirou; este número deve cair a zero depois que ele rodar.
NAO EXECUTADO: sem banco local. Colunas `estado` e `inicio_em` de `public.vaga`: lidas em `privado.verificar_saude`, `20261108110000_lgpd_registro_acessos_borda.sql` (bloco 5).

```sql
select count(*) as vagas_publicadas_ja_iniciadas
  from public.vaga
 where estado = 'publicada'
   and inicio_em < now();
```

---

## 3. Mitigação

### 3.1 Projeto pausado

1. Owner ou Admin restaura pelo painel (seção 2.2). Ninguém mais consegue (`mantem-prod-vivo.yml`).
2. Quando voltar, rode a seção 2.3 inteira. Compare a lista de jobs com `scripts/desvio.sh` e rode `scripts/checagem-diaria.sh` (humano).
3. Notificações `pendente` pré-queda: o push recusa o que já passou do início da vaga ou do turno (`vaga_ou_turno_ja_iniciado`); o resto é reenviado pelo job de um minuto. O despacho e o e-mail retomam pelas filas `pgmq` (DEDUZIDO; NAO MEDIDO depois de queda real).
4. Para o projeto não pausar de novo: confira se o cron de `mantem-prod-vivo` está rodando e verde. Se o plano for pago, a pausa por inatividade deixa de se aplicar (seção 1; confirmar com o painel).

### 3.2 Banco sem responder (503 da `saude`) ou projeto fora do ar

1. **Não mude nada às cegas.** Sem acesso ao banco, não há SQL a rodar. Confirme a página de status do fornecedor.
2. Se for fora do ar do fornecedor: espere e acompanhe; abra chamado no suporte do fornecedor pelo painel. Em plano gratuito o suporte é de comunidade (relatório do mapa, `https://supabase.com/pricing`, 16/11/2026, não reconferido por mim). **A DEFINIR (Caue)**: plano, e logo, nível de suporte.
3. Se persistir por horas ou o projeto estiver corrompido, o caminho é restaurar o **backup lógico** em projeto novo: `docs/BackupDoProd.md`, seção "Decifrar e restaurar em destino descartável". Fatos do backup (MEDIDOS em 16/11/2026 com `gh api` em `backup-prod.yml`): 13 execuções agendadas, 12 com sucesso e 1 falha; o job começa entre **6,8 e 10,3 h depois** do horário `0 7 * * *` UTC. Logo o backup mais novo pode ter até ~34 h (DEDUZIDO: 24 h do intervalo + 10,3 h de atraso). **RPO e RTO não estão declarados em nenhum arquivo do repositório** (relatório do mapa; busca por RPO/RTO). **A DEFINIR (Caue)**: RPO e RTO aceitos.
4. **Restaurar em projeto novo muda o endereço.** Tudo que aponta para o projeto antigo precisa mudar. Lista (LIDA no repositório; o impacto no app é DEDUZIDO e NAO MEDIDO):
   - `REF` no `entrega.yml` (hoje `hbjkkcenbudiezmamiak`), e `SUPABASE_ACCESS_TOKEN` do Environment;
   - segredos das Edge Functions (`docs/RunbookRotacaoDeSegredos.md`, seção 2) e segredos do Vault (`agendador_secret`, `edge_function_url`, `push_function_url`, `email_function_url`, `limpar_contas_function_url`, `expurgar_midias_function_url`, `moderar_midia_function_url`; `docs/ESTADO.md`);
   - variável de repositório `FRILA_PROD_URL_SAUDE` e `BACKUP_DB_URL`;
   - URL do projeto dentro do app iOS: **NAO MEDIDO** (código do app está fora deste repositório). **A DEFINIR (Caue)**: se uma mudança de URL exige novo build na loja e quanto tempo isso leva.
5. Não há região alternativa nem plano de contingência escrito para falha de região (buscado em `docs/`). Decisão de arquitetura: **A DEFINIR (Caue)**.

### 3.3 Comunicação

- **Para usuários:** não existe canal de status (buscado em `docs/` e `supabase/operacao/`). **A DEFINIR (Caue)**: onde e quem avisa.
- **Para os sócios:** o canal e a pessoa de plantão estão em `docs/RunbookPlantao.md`. O aviso por e-mail (`scripts/notificar-equipe.sh`, `docs/NotificacaoDaEquipe.md`) usa SMTP e roda na máquina de quem opera; funciona com o Supabase fora do ar, porque não depende do banco. O aviso por Slack (`notifica-slack.yml`, #512) também não depende do banco, mas só sai com o segredo `SLACK_WEBHOOK_URL`, ausente em 16/11/2026 (seção 1).

---

## 4. Quem age

- **Restaurar projeto pausado:** Owner ou Admin do projeto no Supabase. **A DEFINIR (Caue)**: quem.
- **Diagnóstico e verificação depois de voltar:** sócio de plantão, com credencial de leitura em Prod. Operação em Prod é de humano (`docs/ChecagemDiariaProd.md`, seção 1).
- **Restauração de backup:** quem tem a chave privada `age`. **A DEFINIR (Caue)**: quem guarda a chave e se são pelo menos duas pessoas (o relatório do mapa registra que isso não está medido).
- **Agente de IA:** não conecta em Prod e não restaura nada.

## 5. Quem decide

- Declarar incidente, restaurar backup em projeto novo, trocar o endereço do app: Cauê. **A DEFINIR (Caue)**: delegação quando ele estiver indisponível.
- Assinar plano pago (muda risco de pausa, backup nativo e suporte): Cauê (**A DEFINIR (Caue)**: ele é o dono da organização no Supabase).
- Avisar usuários e fazer comunicação pública: **A DEFINIR (Caue)**.
