# Runbook: `enviar-push` com erro e push parado

O push é o canal que leva a vaga ao profissional. Este runbook cobre o caso em que o aviso não sai, sai atrasado ou falha em série, e como separar "o backend não enviou" de "o backend enviou e o aparelho não mostrou".

Convenção (a mesma de `docs/RunbookRotacaoDeSegredos.md`): **LIDO** é texto do repositório com `arquivo:linha`; **DEDUZIDO** é raciocínio sobre o código; **NAO EXECUTADO: sem banco local** marca cada SQL (escritos a partir das migrações, nunca rodados); **A DEFINIR (Caue)** é fato que só o Cauê sabe.

---

## 1. Sintoma

Qualquer um destes:

- Profissional diz que não recebe aviso de vaga, de chamada direta ou de lembrete de turno.
- Chega e-mail de alerta da fila `email` com um destes códigos (`supabase/migrations/20261108110000_lgpd_registro_acessos_borda.sql`, função `privado.verificar_saude`): `notificacao_push_falhou` (notificação em `falhou` na última hora), `fcm_configuracao_suspeita` (motivo `NOT_FOUND` nos últimos 15 min), `falha_execucao_edge_function`, `pgnet_falha_transporte`, `pgnet_resposta_recusada`, `job_cron_falhou`. O alerta sai no máximo uma vez por hora por tipo (`20260930230000_monitoramento_e_alertas.sql:101-143`).
- Checagem diária (`scripts/checagem-diaria.sh`) amarela ou vermelha em notificações.
- A fila de notificações `pendente` só cresce.

**Armadilha de leitura:** o alerta de e-mail depende do próprio `pg_cron`, do `pg_net` e do SMTP (`docs/RUNBOOK-INCIDENTES.md`, seção 2). Se esses caírem, o alerta pode não chegar. Ausência de e-mail de alerta **não** prova que o push está bom. Não há monitor externo que chame a `saude` em intervalo curto (buscado em `.github/workflows/` e `scripts/`: só `mantem-prod-vivo.yml`, uma vez por dia). Desde `25f475a` (#514) a `saude` mede também a idade dos jobs `reprocessar_despacho` e `verificar_saude`; **não** mede `processar_fila_push`, então push parado por job de push parado continua sem alerta nem probe.

### Como o push funciona (LIDO)

1. Uma linha entra em `public.notificacao` com `estado_entrega = 'pendente'` (enum `pendente`, `enviada`, `entregue`, `falhou`: `20260922150500_despacho_turno_ocorrencia.sql:3`).
2. O gatilho `trg_notificacao_disparar_push` (por comando, não por linha) chama `privado.disparar_push()` (`20261104140200_disparar_push_agendador.sql`). O job `processar_fila_push` (`* * * * *`) chama a mesma função a cada minuto.
3. `disparar_push()` só faz o POST se houver notificação `pendente` elegível. A URL vem, nesta ordem, do segredo `push_function_url` do Vault, da GUC `frila.push_function_url`, de `edge_function_url` trocando `/despachar` por `/enviar-push`, e por último do endereço local. O segredo vem do Vault (`agendador_secret`) com fallback na GUC. Sem segredo, a função só emite `WARNING` e retorna; a notificação fica `pendente` até o segredo voltar.
4. A Edge Function `enviar-push` autentica o `x-agendador-secret`, pega a conta de serviço (`FCM_SERVICE_ACCOUNT` ou `FIREBASE_SERVICE_ACCOUNT`), troca por token OAuth do Google, lê os aparelhos da conta em `public.dispositivo` e envia pelo FCM HTTP v1 (`supabase/functions/enviar-push/index.ts`, `fcm.ts`).
5. Resultado gravado em `public.notificacao`:
   - HTTP 200 do FCM: `estado_entrega = 'enviada'`, `aceita_em` preenchido. **`enviada` quer dizer "o FCM aceitou", não "o aparelho mostrou"** (`20260926020000_registro_dispositivo_e_push.sql:117`).
   - Erro passageiro: continua `pendente`, com `proxima_tentativa_em` em backoff de 10 s × 2^(tentativa−1), e vira `falhou` ao chegar a 5 tentativas (`index.ts:152-159`, `20260926020000...sql:149-165`).
   - `UNREGISTERED`, 404 ou 410 do FCM: remove o token do aparelho (`public.dispositivo`) e grava falha.
   - Motivos de falha permanente gravados em `motivo_falha`: `vaga_ou_turno_ja_iniciado`, `sem_dispositivo` (conta sem aparelho registrado), `versao_nao_suportada` (aviso `chamada_*` para versão do app abaixo do mínimo), `UNREGISTERED`, `NOT_FOUND` (configuração do FCM errada), `falha_envio` ou o texto do erro devolvido pelo FCM (qualquer outra falha permanente), e `erro_transitorio: <detalhe>` enquanto há tentativa (`index.ts:1074-1077`).

---

## 2. Diagnóstico (somente leitura)

Todos os SQL abaixo: **NAO EXECUTADO: sem banco local**. Rode em sessão com `default_transaction_read_only = on`. Nenhum devolve token de aparelho, `payload` nem identificador de usuário (RN15).

**2.1 Como estão as notificações das últimas 24 horas.**
NAO EXECUTADO: sem banco local. Colunas de `public.notificacao`: `20260922150500_despacho_turno_ocorrencia.sql:26-34`, `20260925233000_notificacao_para_qualquer_conta.sql:21-27`.

```sql
select estado_entrega,
       count(*) as total,
       min(enviada_em) as mais_antiga,
       max(enviada_em) as mais_recente
  from public.notificacao
 where enviada_em > now() - interval '24 hours'
 group by estado_entrega
 order by estado_entrega;
```

Leitura: muito `pendente` e pouco `enviada` aponta para o caminho **banco para função** (causa A abaixo). Muito `falhou` aponta para o caminho **função para FCM** ou para o aparelho (causas B e C).

**2.2 Há notificação pendente elegível parada, e há quanto tempo?**
NAO EXECUTADO: sem banco local. A condição de "elegível" é a de `privado.disparar_push()` (`20261104140200_disparar_push_agendador.sql:40-43`).

```sql
select count(*) as pendentes_elegiveis,
       min(enviada_em) as mais_antiga,
       now() - min(enviada_em) as idade_da_mais_antiga
  from public.notificacao
 where estado_entrega = 'pendente'
   and (proxima_tentativa_em is null or proxima_tentativa_em <= now());
```

Com o job ativo e a função sã, a idade da mais antiga fica em segundos. Passando de 15 minutos há problema real.

**2.3 Por que as falhas falharam (agrupado por motivo, sem dado pessoal).**
NAO EXECUTADO: sem banco local.

```sql
select left(coalesce(motivo_falha, '(sem motivo)'), 80) as motivo,
       count(*) as total,
       max(enviada_em) as ultima
  from public.notificacao
 where estado_entrega = 'falhou'
   and enviada_em > now() - interval '24 hours'
 group by 1
 order by total desc
 limit 20;
```

**2.4 O job do agendador existe, está ativo e rodou?**
NAO EXECUTADO: sem banco local. Mesmo padrão de `docs/RUNBOOK-INCIDENTES.md`, seção 2, itens 3 e 4.

```sql
select jobid, jobname, schedule, active
  from cron.job
 where jobname = 'processar_fila_push';
```

```sql
select runid, status, return_message, start_time, end_time
  from cron.job_run_details
 where jobid = (select jobid from cron.job where jobname = 'processar_fila_push')
 order by start_time desc
 limit 10;
```

Esperado: 1 linha, `active = true`, execuções a cada minuto. Zero linha ou `active = false`: o job foi removido ou desligado. O alerta existente `job_cron_falhou` só vê execução com status `failed` nos últimos 15 minutos; **job que simplesmente não roda não gera alerta** (`20261108110000...sql:575-586`).

**2.5 O banco está conseguindo chamar a função? (respostas HTTP da última hora).**
NAO EXECUTADO: sem banco local. `net._http_response` não guarda a URL chamada: esta consulta mistura `enviar-push`, `enviar-email` e `despachar`. Use-a para ver o padrão (muito 401, 5xx ou nulo), e confirme a função nos logs (seção 3).

```sql
select status_code,
       count(*) as total,
       max(created) as ultima
  from net._http_response
 where created > now() - interval '1 hour'
 group by status_code
 order by status_code nulls first;
```

`401` = segredo desencontrado (ver `docs/RunbookRotacaoDeSegredos.md`, seção 3.1). `500` = a função recebeu e falhou (por exemplo `fcm_service_account_nao_configurada` ou `falha_oauth_google`). `status_code` nulo com `error_msg` = nem chegou (rede, URL errada, projeto pausado).

**2.6 Os segredos e as URLs do Vault existem? (nomes, nunca valores).**
NAO EXECUTADO: sem banco local. As colunas `updated_at` de `vault.secrets` vêm da extensão e não das migrações: confirmar na primeira execução.

```sql
select s.name,
       (d.decrypted_secret is not null and d.decrypted_secret <> '') as preenchido
  from vault.secrets s
  join vault.decrypted_secrets d on d.id = s.id
 where s.name in ('agendador_secret', 'push_function_url', 'edge_function_url')
 order by s.name;
```

Esperado no Prod, segundo `docs/ESTADO.md` (08/11/2026): as três presentes. Depois dessa data: NAO MEDIDO.

**2.7 A função registrou falha própria? (tabela sem dado pessoal).**
NAO EXECUTADO: sem banco local. Tabela em `20260930230000_monitoramento_e_alertas.sql:20-28`.

```sql
select origem,
       codigo,
       count(*) as total,
       max(criada_em) as ultima
  from privado.falha_execucao
 where criada_em > now() - interval '24 hours'
 group by origem, codigo
 order by ultima desc;
```

**2.8 Há aparelho registrado? Quão frescos estão os tokens?**
NAO EXECUTADO: sem banco local. `public.dispositivo`: `20260922150500_despacho_turno_ocorrencia.sql:14-20`, `20261107370000_contratacao_direta_b5c_b5d_b5e_e_exportacao.sql:26` (`versao_app`).

```sql
select plataforma,
       count(*) as aparelhos,
       max(atualizado_em) as ultimo_registro
  from public.dispositivo
 group by plataforma
 order by plataforma;
```

### Árvore de decisão

| O que o diagnóstico mostra | Causa provável | Onde agir |
|---|---|---|
| **A.** `pendente` acumulando, quase nenhum `falhou`; 2.4 sem job ativo, ou 2.5 com 401 ou status nulo, ou 2.6 sem nome | A chamada do banco não chega à função | Reativar o job (`docs/RUNBOOK-INCIDENTES.md`, seção 3, mitigação 1); segredo desencontrado: `docs/RunbookRotacaoDeSegredos.md` 3.1; projeto pausado: `docs/RunbookSupabaseIndisponivel.md` |
| **B1.** `falhou` com `NOT_FOUND` | Projeto ou credencial FCM trocados errado | `docs/RunbookRotacaoDeSegredos.md` 3.3 |
| **B2.** 2.5 com 500 e logs da função com `falha_oauth_google` ou `fcm_service_account_nao_configurada` | Conta de serviço ausente, expirada ou apagada | idem 3.3 |
| **B3.** `falhou` com `erro_transitorio: ...` repetido | FCM com instabilidade ou rede da função | Esperar e medir; ver status do Google. A tentativa é automática (5 vezes) |
| **B4.** `falhou` com `UNREGISTERED`, `sem_dispositivo` | Normal: app desinstalado ou sem permissão | Nenhuma. Só preocupa se for a maioria |
| **B5.** `falhou` com `vaga_ou_turno_ja_iniciado` ou `versao_nao_suportada` | Regra de produto funcionando | Nenhuma |
| **C.** 2.1 mostra `enviada` e o usuário não vê o aviso | O backend entregou ao FCM; falha está no FCM-para-aparelho (permissão de notificação, chave APNs no Firebase, token velho) | Fora do backend. **A DEFINIR (Caue)**: quem tem acesso ao console do Firebase e à chave APNs |
| **D.** Tudo verde em 2.1 a 2.8 e o relato persiste | Relato isolado | Pedir ao profissional a versão do app e confirmar a linha em `dispositivo` pela conta (consulta por `usuario_id` é do operador, em Prod, fora deste documento) |

---

## 3. Mitigação

Do menos para o mais invasivo. Cada passo que escreve em Prod é de humano autorizado (`docs/ChecagemDiariaProd.md`, seção 1; `AGENTS.md`: "Mexer no Prod sem o sócio dono pedir" é proibido).

1. **Leia os logs da função** (leitura): `supabase functions logs enviar-push --project-ref <ref>` (padrão já usado em `docs/RUNBOOK-INCIDENTES.md`, seção 2). Retenção e acesso aos logs no painel: NAO MEDIDO.
2. **Confira que os segredos existem por nome**: `supabase secrets list --project-ref <ref>` (DEDUZIDO que o comando só lista nomes e resumos, não valores; confirmar na primeira execução). Procure `AGENDADOR_SECRET` e `FCM_SERVICE_ACCOUNT`.
3. **Corrija a causa** pela linha da árvore de decisão (reativar job, rotacionar segredo, restaurar projeto).
4. **Se o defeito foi introduzido por deploy de função**, volte a função: `docs/RunbookRollbackEdgeFunction.md`.
5. **Não faça rotação de segredo no meio do incidente sem necessidade**: `supabase secrets set` re-publica todas as funções (`docs/ESTADO.md`).
6. **Depois da correção**, as notificações `pendente` com tentativas restantes são reenviadas sozinhas pelo job de um minuto. Notificações já em `falhou` **não voltam sozinhas**. Não existe rotina de reenvio em lote no repositório (buscado em `scripts/`, `supabase/operacao/` e `supabase/migrations/`). Reenviar aviso de vaga velho tem pouco valor: a função recusa o que já passou do início da vaga ou do turno (`vaga_ou_turno_ja_iniciado`, `index.ts:834-840`). Recomendação (DEDUZIDO): não reenviar em lote; o profissional vê a vaga ao abrir o app. A decisão de reenviar é do Cauê.
7. **Registre**: hora de início e fim, causa, quantas notificações afetadas (resultado de 2.1), e o que foi mudado, sem valor de segredo.

Alvos de latência que o produto declara: push p95 ≤ 60 s e despacho p95 ≤ 30 s (RNF02 e RNF03). Esses números **não foram medidos em Prod** (`docs/PainelDoPiloto.md`, seção 3, "O que NÃO foi medido localmente"); este runbook não os usa para decidir se há incidente.

---

## 4. Quem age

- **Diagnóstico e correção técnica:** sócio de plantão (`docs/RunbookPlantao.md`) com acesso ao `frila-prod`. Consultas de leitura em Prod são de humano.
- **Agente de IA:** pode ler este runbook, propor correção e abrir PR. Não conecta em Prod (`docs/ChecagemDiariaProd.md`, seção 1).
- **Console do Firebase e chave APNs:** **A DEFINIR (Caue)**: quem tem acesso.

## 5. Quem decide

- Reativar job, rotacionar segredo, voltar função em Prod: Cauê, ou o sócio que ele delegar. **A DEFINIR (Caue)**: a regra de delegação.
- Reenvio em lote de notificações `falhou`: Cauê.
- Comunicar usuários sobre atraso de aviso: **A DEFINIR (Caue)**. Não há canal de status para usuários (buscado em `docs/`, `supabase/operacao/`).
