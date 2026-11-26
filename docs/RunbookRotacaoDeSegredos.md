# Runbook: rotação de segredos

Como trocar cada segredo do backend do Frila sem derrubar o despacho, o push e o e-mail, e como conferir que a troca pegou. Este runbook não imprime nem guarda valor de segredo: todo valor aqui é sintético (`<novo-valor>`).

Convenção deste documento (a mesma do restante de `docs/`):

- **LIDO** é o que está no repositório, com `arquivo:linha`. É fato sobre o texto; o comportamento em Prod é dedução até alguém medir.
- **DEDUZIDO** é raciocínio sobre o código, sem execução.
- **EXECUTADO** marca o SQL de leitura rodado em 25/11/2026 em banco local descartável (ver "Execução do SQL"); **NAO EXECUTAVEL AQUI** marca o que depende de Prod ou de credencial, ou escreve (a rotação em si).
- **A DEFINIR (Caue)** é um fato que só o Cauê sabe.

**Execução do SQL (25/11/2026).** Os 4 SQL de leitura deste documento foram executados em 25/11/2026 num Postgres local descartável (`supabase db start` sobre a `develop` em `6225a77`: migrações do zero, `seed.sql` e `cenarios.sql`), cada um dentro de `begin read only`; os 4 rodam sem erro. O 5º bloco (a escrita `vault.update_secret`) **não foi executado**: escreve e é só de humano autorizado em Prod. **Não executável fora do Prod:** o conteúdo real do Vault e os comandos de CLI (`supabase secrets set`).

Regras que valem para todas as rotações (`AGENTS.md`, "Nunca" e "Segredos e dados pessoais"):

- Repositório público: valor de segredo nunca entra em commit, PR, log, issue nem prompt. O PR diz só o **nome** da variável.
- Mexer no Prod só a pedido do sócio dono. Operação em Prod é de humano autorizado (`docs/ChecagemDiariaProd.md`, seção 1).
- Se o segredo vazou: avisar os sócios e **trocar a chave antes** de limpar o histórico. Se o vazamento atingiu dado pessoal, abra também `docs/RunbookVazamentoDeDadosPessoais.md`.
- Gere o valor novo na própria máquina (`openssl rand -hex 32`) e passe-o por arquivo temporário com permissão `600`, apagado no fim. Não passe o valor como argumento de linha de comando: ele aparece em `ps` e no histórico do shell.

---

## 1. Sintoma

Quando abrir este runbook:

- Suspeita ou certeza de que um segredo foi exposto (commit, log, print, e-mail, máquina perdida, pessoa que saiu do time).
- Alerta ou erro que aponta para credencial: `nao_autorizado` (401) em Edge Function chamada pelo banco, `fcm_service_account_nao_configurada` ou `falha_oauth_google` no push, e-mail que não sai por autenticação SMTP recusada, `erro_configuracao` na moderação de mídia.
- Rotina periódica combinada pelos sócios. Periodicidade: **A DEFINIR (Caue)**.

Efeitos colaterais conhecidos (todos LIDOS no repositório):

- `agendador_secret` mora em **dois lugares que precisam ter o mesmo valor**: o Supabase Vault (lido pelas funções `privado.*` do banco) e a variável `AGENDADOR_SECRET` das Edge Functions. Trocar um sem o outro faz o banco chamar a função com segredo errado e receber 401. Fonte: `scripts/aplicar-remoto.sh:135-152` ("cadastre o segredo no Vault e em AGENDADOR_SECRET das Edge Functions") e `supabase/functions/_compartilhado/auth.ts` (comparação em tempo constante).
- `enviar-push` falha ao carregar o módulo se `AGENDADOR_SECRET` estiver vazio (`supabase/functions/enviar-push/index.ts:86-89`, `throw new Error`). Apagar a variável derruba a função inteira, não só a autenticação.
- `supabase secrets set` sobe uma versão nova de **todas** as funções sem mudar o código (`docs/ESTADO.md`, "O que custou caro descobrir na aplicação"). Não faça rotação durante um rollback de função (`docs/RunbookRollbackEdgeFunction.md`).

---

## 2. Diagnóstico (somente leitura)

Inventário. "Onde mora" é onde o valor é guardado; "quem usa" é o que quebra se o valor ficar errado.

| Segredo | Onde mora | Quem usa (LIDO) | Falha típica se errado |
|---|---|---|---|
| `agendador_secret` / `AGENDADOR_SECRET` | Vault do banco **e** variável das Edge Functions | funções `privado.disparar_*` (banco); `despachar`, `enviar-push`, `enviar-email`, `limpar-contas-orfas`, `expurgar-midias`, `moderar-midia` | 401 `nao_autorizado`; fila `pendente` cresce; alerta `pgnet_resposta_recusada` |
| `service_role` (`SUPABASE_SERVICE_ROLE_KEY`) | Fornecida pelo Supabase às Edge Functions; chave do projeto no painel | `enviar-push`, `excluir-conta`, `limpar-contas-orfas`, `moderar-midia`, `ler-midia`, `enviar-midia`, `expurgar-midias`, `entrar-demonstracao`; scripts `demonstracao*.sh` | 401/500 em função; exclusão de conta e mídia param |
| `FCM_SERVICE_ACCOUNT` (ou `FIREBASE_SERVICE_ACCOUNT`) | Variável das Edge Functions (JSON ou base64) | `enviar-push` (`index.ts:96-100`) | `fcm_service_account_nao_configurada` (500), `falha_oauth_google`, `NOT_FOUND` → alerta `fcm_configuracao_suspeita` |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASS`, `SMTP_TLS`, `SMTP_SENDER` | Variáveis das Edge Functions (e-mail transacional) | `enviar-email`; `scripts/notificar-equipe.sh` lê as mesmas variáveis | fila `pgmq.q_email` cresce (alerta `fila_email_antiga`) |
| SMTP do **Auth** (senha no painel) | Painel Supabase, Authentication, SMTP Settings | código de entrada de 6 dígitos (`supabase/operacao/configurar-smtp-auth.md`) | usuário não recebe o código de login |
| Moderação: `MODERACAO_PROVEDOR`, `MODERACAO_TETO_MENSAL`, `AZURE_CONTENT_SAFETY_KEY`, `AZURE_CONTENT_SAFETY_ENDPOINT` (e `OPENAI_API_KEY` se o provedor for esse) | Variáveis das Edge Functions | `moderar-midia` (`index.ts:466-486`, `:845-846`) | 500 `erro_configuracao`; **sem `MODERACAO_PROVEDOR` cai em `local`, que autoaprova** (`index.ts:468`) |
| `SUPABASE_ACCESS_TOKEN` | Secret dos Environments `frila-dev` e `frila-prod` no GitHub | `entrega.yml`, `confere-auth-remoto.yml` | Entrega e conferência falham: "Falta o secret SUPABASE_ACCESS_TOKEN" |
| `BACKUP_DB_URL`, `BACKUP_PUBLIC_KEY`, `BACKUP_S3_*` | Secrets do Environment `frila-backup` | `backup-prod.yml` | backup diário falha (ver `docs/BackupDoProd.md`) |
| `DEMONSTRACAO_CODIGO`, `DEMONSTRACAO_EMAILS` | Variáveis das Edge Functions | `entrar-demonstracao` | conta de demonstração (revisão da Apple) deixa de entrar |
| `documento_pepper` | Vault | RN14 (`docs/VerificacaoDeIdentidade.md`, seção 1) | **Não gire.** Girar invalida toda a deduplicação de documento, sem recálculo (`docs/ESTADO.md`, pendência 5). Decisão do Cauê |

Os SQL abaixo só leem. Rode em sessão com `default_transaction_read_only = on` (é o que `scripts/checagem-diaria.sh` faz).

**2.1 Os segredos do Vault existem e estão preenchidos? (só nomes e datas, nunca o valor).**
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 0 linhas, porque o Vault local não tem segredos (em Prod devolve uma linha por nome). `vault.decrypted_secrets` aparece em migrações do repositório (por exemplo `20261104140200_disparar_push_agendador.sql`); a coluna `updated_at` de `vault.secrets`, que vem da extensão, existe.

```sql
select s.name,
       (d.decrypted_secret is not null and d.decrypted_secret <> '') as preenchido,
       s.updated_at
  from vault.secrets s
  join vault.decrypted_secrets d on d.id = s.id
 order by s.name;
```

Esperado no Prod, segundo `docs/ESTADO.md` (08/11/2026): `agendador_secret`, `edge_function_url`, `email_function_url`, `push_function_url`, `limpar_contas_function_url`, `expurgar_midias_function_url`, `moderar_midia_function_url` presentes; `documento_pepper`, `storage_url`, `storage_jwt_secret` ausentes. Estado depois de 08/11: NAO MEDIDO.

**2.2 O banco está sendo recusado pelas funções? (sinal de segredo desencontrado).**
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 0 linhas, por falta de dado. Tabela `net._http_response` e as colunas usadas já aparecem em `docs/RUNBOOK-INCIDENTES.md`, seção 2.

```sql
select status_code,
       count(*) as total,
       min(created) as primeira,
       max(created) as ultima
  from net._http_response
 where created > now() - interval '1 hour'
 group by status_code
 order by status_code;
```

Muitos `401` na última hora, depois de uma rotação, quer dizer que Vault e variável da função não têm o mesmo valor.

**2.3 Há falha de execução registrada por função? (sem dado pessoal, RN15).**
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 0 linhas, por falta de dado. Tabela definida em `20260930230000_monitoramento_e_alertas.sql:20-28`.

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

**2.4 Notificações pendentes por causa de segredo errado.**
EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 0 linhas, por falta de dado. Colunas de `public.notificacao` em `20260922150500_despacho_turno_ocorrencia.sql:26-34` e `20260926020000_registro_dispositivo_e_push.sql:79-80`.

```sql
select estado_entrega,
       count(*) as total,
       min(enviada_em) as mais_antiga
  from public.notificacao
 where enviada_em > now() - interval '24 hours'
 group by estado_entrega
 order by estado_entrega;
```

---

## 3. Mitigação

Em todas as rotações, nesta ordem: **(1)** avise os sócios no canal de plantão (`docs/RunbookPlantao.md`); **(2)** faça a rotação fora do pico (a janela de pico da RNF12, quinta a domingo das 16h às 2h, está desligada hoje, mas segue sendo o horário de maior risco: `docs/RunbookHotfixERollback.md`, cabeçalho); **(3)** ensaie primeiro no `frila-dev` (`jcobftbhbqdikratzizz`) quando o tempo permitir; **(4)** depois rode o Diagnóstico da seção 2 e a checagem diária (`scripts/checagem-diaria.sh`); **(5)** registre no PR ou no cartão a hora, o nome do segredo e o resultado, nunca o valor.

### 3.1 `agendador_secret` (Vault e `AGENDADOR_SECRET`)

Passos (DEDUZIDO do código; nunca executado em Prod):

1. Gere `<novo-valor>` com `openssl rand -hex 32` e grave num arquivo `600` fora do repositório.
2. Suba a variável das Edge Functions: `supabase secrets set --env-file <arquivo> --project-ref <ref>`, com uma única linha `AGENDADOR_SECRET=<novo-valor>`. A partir daqui, as funções recusam o valor antigo.
3. **Logo em seguida** (janela de desencontro; alvo: menos de 1 minuto), atualize o Vault. Escrita em Prod, só humano autorizado:

   ```sql
   -- ESCRITA, não é diagnóstico. NAO EXECUTAVEL AQUI: escreve no Vault, e `:'novo_valor'` é variável do `psql` (`-v novo_valor=...`) que o bloco não define. A assinatura `vault.update_secret(secret_id, new_secret, new_name, ...)` foi conferida no banco local.
   -- Padrão de vault.update_secret igual ao de 20261103120000_vault_urls_edge_functions.sql:136.
   select vault.update_secret(
     (select id from vault.secrets where name = 'agendador_secret'),
     :'novo_valor',
     'agendador_secret'
   );
   ```

   Passe `novo_valor` ao `psql` lendo o arquivo (`\set novo_valor \`cat <arquivo>\``), não por `-v` com o valor na linha de comando.
4. Apague o arquivo temporário.
5. Confira: diagnósticos 2.1, 2.2 e 2.4. Esperado: `agendador_secret` preenchido, sem `401` novo depois da troca, notificações `pendente` sendo drenadas.

O que acontece na janela do passo 2 ao 3 (DEDUZIDO): chamadas `pg_net` do banco levam 401. O comentário de `20261104140200_disparar_push_agendador.sql` diz que a notificação "continua `pendente` e o minuto seguinte tenta de novo", e o job `processar_fila_push` roda a cada minuto. Para o despacho (`pgmq.q_despacho`) e o e-mail (`pgmq.q_email`), a hipótese é que a mensagem fica na fila e o job periódico reprocessa. **NAO MEDIDO**: se alguma mensagem se perde na janela. Ensaie no `frila-dev` e meça antes de confiar.

Se o passo 2 for feito e o 3 falhar: reponha o valor antigo na variável das funções (se você ainda o tem) ou conclua o passo 3. Não deixe `AGENDADOR_SECRET` vazio: `enviar-push` não carrega sem ele.

### 3.2 `service_role`

O procedimento oficial do fornecedor está em <https://supabase.com/docs/guides/security/rotate-leaked-api-keys> (página lida em 16/11/2026 por esta revisão). Resumo do que a página diz: corrigir a causa raiz primeiro; criar uma chave secreta nova em Settings, API Keys (ou pela Management API); trocar a chave comprometida em todo lugar que a usa; confirmar; só então desativar a chave antiga (para chave legada `service_role`, desativar as duas chaves legadas e revogar o JWT secret legado). A página avisa que apagar chave secreta não tem volta e que reativar a chave legada restaura a chave comprometida. Quanto às sessões de usuário, a página não diz se revogar o JWT secret as derruba.

O que é específico do Frila, por leitura do repositório (DEDUZIDO):

- Oito Edge Functions leem `SUPABASE_SERVICE_ROLE_KEY` (tabela da seção 2). A documentação do fornecedor diz que a variável legada continua existindo no runtime mas carrega a chave legada. **NAO MEDIDO**: o que `SUPABASE_SERVICE_ROLE_KEY` passa a conter depois da rotação no `frila-prod`. Ensaie no `frila-dev` e confirme chamando uma função que a use (por exemplo, um `enviar-push` com notificação sintética) antes de desativar a chave antiga no Prod.
- O app iOS usa a chave `anon`, não a `service_role` (DEDUZIDO; a documentação do fornecedor avisa que desativar a `service_role` legada desativa também a `anon` legada). **A DEFINIR (Caue)**: qual chave o app em produção embute e se trocar exige novo build na loja.
- Nenhum script do repositório guarda a chave; `scripts/demonstracao*.sh` leem de variável de ambiente.

### 3.3 `FCM_SERVICE_ACCOUNT`

1. No console do Firebase do projeto do Frila, gere uma nova chave para a conta de serviço usada no envio (Configurações do projeto, Contas de serviço). **A DEFINIR (Caue)**: qual projeto Firebase e quem tem acesso ao console.
2. Grave o JSON num arquivo `600` e suba: `supabase secrets set --env-file <arquivo> --project-ref <ref>` com a linha `FCM_SERVICE_ACCOUNT=<json-em-uma-linha-ou-base64>`. `carregarContaDeServico` aceita JSON ou base64 (`enviar-push/index.ts:96-111`).
3. Confira: crie ou aguarde uma notificação sintética e rode o diagnóstico 2.4; o motivo de falha `NOT_FOUND` indica projeto ou credencial trocada errada (alerta `fcm_configuracao_suspeita`, `20261017181500_alerta_configuracao_fcm_saude.sql`).
4. Só depois, no console do Firebase, **apague a chave antiga**. Apagar antes interrompe o push.
5. Apague o arquivo temporário.

Rotação não invalida os tokens de aparelho (`public.dispositivo.token_fcm`); eles pertencem ao app, não à conta de serviço (DEDUZIDO).

### 3.4 SMTP

Há duas superfícies, e a rotação das duas é independente:

- **E-mail transacional (Edge Function `enviar-email`)**: `SMTP_PASS` (e `SMTP_USER`, `SMTP_HOST` se o provedor mudar). Gere a credencial nova no provedor, suba com `supabase secrets set` (mesma forma do 3.1, passo 2), confira com o diagnóstico `pgmq.q_email` de `docs/RUNBOOK-INCIDENTES.md`, seção 2, e só então revogue a credencial antiga no provedor.
- **SMTP do Auth (código de entrada)**: senha no painel, Authentication, SMTP Settings (`supabase/operacao/configurar-smtp-auth.md`, seção 2). Troque a senha no provedor, salve no painel, dispare um código de teste pelo roteiro da seção 4 do mesmo documento.

O mesmo SMTP alimenta `scripts/notificar-equipe.sh` (`docs/NotificacaoDaEquipe.md`): quem opera esse script atualiza a variável local depois.

Qual provedor o Prod usa hoje: o texto de `configurar-smtp-auth.md` diz Resend em produção e Gmail em dev, e o cabeçalho de `supabase/functions/enviar-email/provedor.ts` ainda diz que o provedor não foi escolhido. **A DEFINIR (Caue)**.

### 3.5 Moderação de mídia

1. Gere a chave nova no provedor (Azure Content Safety, segundo `moderar-midia/index.ts:476-481`). **A DEFINIR (Caue)**: quem é dono da conta Azure.
2. `supabase secrets set` com `AZURE_CONTENT_SAFETY_KEY` (e `AZURE_CONTENT_SAFETY_ENDPOINT` se a região mudar).
3. **Não apague `MODERACAO_PROVEDOR` nem deixe a variável vazia.** Sem ela a função cai em `local`, que **aprova tudo** (`moderar-midia/index.ts:468`). Hoje não existe guarda em código contra foto ligada com moderador `local` (DEDUZIDO da leitura de `criarProvedor`, `:466-486`). Antes e depois da rotação, confirme que a chave de recurso `foto_de_perfil` está desligada ou que o provedor efetivo é o real.
4. Confira que uma imagem sintética é processada pelo provedor real e não pelo `local`. NAO MEDIDO: não há consulta pronta para isso; o provedor efetivo aparece no log da função (`supabase functions logs moderar-midia`).
5. Revogue a chave antiga no provedor.

### 3.6 Outros segredos (resumo)

- `SUPABASE_ACCESS_TOKEN`: gere novo token pessoal no painel do Supabase, atualize o secret em **cada** Environment do GitHub (`frila-dev` e `frila-prod`) e revogue o antigo. Quem faz precisa de acesso de administrador ao repositório. **Atenção**: o token tem poder de escrita sobre a infraestrutura (`docs/ambiente-frila-prod-leitura.md`, seção 1).
- `BACKUP_*`: ver `docs/BackupDoProd.md`, seção "Environment `frila-backup` e segredos necessários". A chave privada `age` **não** se gira como as demais: backups antigos só abrem com a chave privada que os cifrou.
- `DEMONSTRACAO_CODIGO`: `supabase secrets set`, e avise quem usa a conta de revisão da Apple.
- Segredo achado em commit: o scanner `scripts/auditoria-segredos-e-dependencias.sh` (`docs/AuditoriaSegredosEDependencias.md`) acha; a troca vem antes da limpeza de histórico.

---

## 4. Quem age

- **Executa a rotação:** um sócio com acesso ao painel do Supabase e às variáveis do projeto. **A DEFINIR (Caue)**: quem tem hoje acesso de Owner/Admin ao projeto `frila-prod` e ao Environment `frila-prod` do GitHub (4 revisores cadastrados, `docs/RunbookHotfixERollback.md`, seção 1).
- **Agente de IA:** pode preparar o texto e o diagnóstico; **não** executa nada em Prod e **não** recebe valor de segredo (`AGENTS.md`).
- **Quem confere depois:** outro sócio, com `scripts/checagem-diaria.sh` (humano, em Prod).

## 5. Quem decide

- Rotação por vazamento suspeito: qualquer sócio pode iniciar; o sócio que descobriu avisa os demais na hora e não espera consenso para **trocar a chave** (`AGENTS.md`: "troque a chave antes de limpar o histórico").
- Rotação de `service_role`, de `FCM_SERVICE_ACCOUNT` e de `SUPABASE_ACCESS_TOKEN` em Prod: Cauê (**A DEFINIR (Caue)**: confirmar que esta é a regra).
- Girar `documento_pepper`: Cauê, com consequência explícita (perde a deduplicação da RN14).
- Periodicidade de rotação preventiva: **A DEFINIR (Caue)**.
