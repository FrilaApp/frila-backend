# Runbook: rollback de Edge Function

Como voltar uma Edge Function do `frila-prod` para uma versão anterior do código depois que um deploy a quebrou. O rollback de **migração** é outro assunto: `docs/RUNBOOK-INCIDENTES.md` (seção 6) e `docs/RunbookHotfixERollback.md` (seção 4).

Convenção (a mesma de `docs/RunbookRotacaoDeSegredos.md`): **MEDIDO** é o que foi lido de uma execução real (com data e fonte); **LIDO** é texto do repositório; **DEDUZIDO** é raciocínio sobre o código; **EXECUTADO** marca o SQL rodado em banco local descartável, com data e base; **NAO EXECUTAVEL AQUI** marca o que depende de Prod ou de credencial; **A DEFINIR (Caue)** é fato que só o Cauê sabe. **Nunca se executou um rollback de função em Prod.** Todo comando abaixo é proposta a confirmar.

**Execução do SQL (25/11/2026).** Os 3 blocos SQL deste documento foram executados em 25/11/2026 num Postgres local descartável (`supabase db start` sobre a `develop` em `6225a77`: migrações do zero, `seed.sql` e `cenarios.sql`), cada um dentro de `begin read only`; os 3 rodam sem erro. **Não executável fora do Prod:** os comandos de CLI (`supabase functions list`, `supabase functions deploy`), que exigem credencial de Prod, e o conteúdo real de `privado.falha_execucao` e `net._http_response`.

---

## 1. Sintoma

- Logo depois de uma entrega para o Prod (tag `backend-v*` ou publicação manual), uma função passa a responder 5xx, 401 inesperado ou comportamento errado.
- Alerta por e-mail `falha_execucao_edge_function` (`privado.falha_execucao` com linha nos últimos 15 minutos) ou `pgnet_resposta_recusada` / `pgnet_falha_transporte` (`supabase/migrations/20261108110000_lgpd_registro_acessos_borda.sql`).
- A função `saude` deixa de responder 200: o workflow `mantem-prod-vivo.yml` falha.

Quais funções existem (LIDO, `supabase/functions/`): `despachar`, `entrar-demonstracao`, `enviar-email`, `enviar-midia`, `enviar-push`, `excluir-conta`, `exportar-meus-dados`, `exportar-turnos`, `expurgar-midias`, `ler-midia`, `limpar-contas-orfas`, `moderar-midia`, `saude`.

**O que o repositório não faz por você:**

- O workflow de Entrega não desfaz publicação (`docs/RunbookHotfixERollback.md`, seção 2, último item).
- `scripts/desvio.sh` compara só o banco (tabelas, funções SQL, políticas, jobs). **Não compara Edge Functions**: MEDIDO em 16/11/2026, zero linhas com "edge", "functions deploy" ou "functions/v1" em `scripts/desvio.sh` e `scripts/desvio.sql`. Nada no repositório prova que o código publicado no Prod é o da tag.
- Se o Supabase guarda versões anteriores de função para voltar com um comando: **não encontrado**. Buscado em `entrega.yml`, `scripts/`, `docs/` e na página de deploy da documentação do Supabase (<https://supabase.com/docs/guides/functions/deploy>, lida em 16/11/2026), que não trata de versões nem de rollback. O caminho abaixo é, portanto, **republicar o código antigo** como uma versão nova.

---

## 2. Diagnóstico (somente leitura)

**2.1 Qual função e qual versão está no Prod.**
Comando de CLI, leitura. NAO EXECUTAVEL AQUI: precisa de credencial de Prod. DEDUZIDO que a saída traz nome, versão e data de atualização, como o retrato de `docs/ESTADO.md` ("`despachar` v7, `enviar-push` v9..." em 08/11/2026).

```bash
supabase functions list --project-ref hbjkkcenbudiezmamiak
```

Compare a data de atualização da função com a hora em que os erros começaram.

**2.2 Qual commit está publicado.** O repositório não guarda esse vínculo (ver seção 1). Pontos conhecidos, todos LIDOS ou MEDIDOS:

| Ponto | Commit | Fonte |
|---|---|---|
| Tag `backend-v1.1.0` (04/11/2026) | `61ed48f` | MEDIDO: `gh api repos/FrilaApp/frila-backend/tags`, 16/11/2026 |
| Tag `backend-v1.1.1` (05/11/2026) | `e14a8d2` | idem |
| Pacote v1.1 manual (08/11/2026) | `e8516b51` | `docs/ESTADO.md`, seção "O `frila-prod` em 08/11/2026" (publicou `moderar-midia`, `expurgar-midias`, `exportar-meus-dados`, `saude` e `enviar-push`; as demais funções são de 04 a 05/11) |
| Qualquer publicação depois de 08/11/2026 | NAO MEDIDO | sem acesso ao Prod |

Para achar o último commit **bom** de uma função: `git log --oneline -- supabase/functions/<nome>`, e escolha o commit anterior à mudança suspeita. Confirme com quem fez a publicação, ou pelo histórico do PR, que aquele commit foi mesmo o que esteve no ar com a função saudável.

**2.3 O banco ainda é compatível com o código antigo?** A função antiga precisa funcionar com o schema atual do Prod. Veja o que o banco do Prod já tem aplicado:

EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; `topo` = `20261125120000` e `total` = 248 no banco local (o Prod tem 246, `docs/ESTADO.md`). Tabela criada em `scripts/aplicar-remoto.sh:71-73` e lida em `:76-78`.

```sql
select max(version) as topo,
       count(*) as total
  from supabase_migrations.schema_migrations;
```

Depois, no repositório, liste o que mudou no código da função e nas migrações entre o commit bom e o atual: `git diff <commit-bom>..<commit-atual> --stat -- supabase/functions/<nome> supabase/migrations`. Se a versão nova da função depende de coluna ou RPC criada por uma migração **já aplicada**, a versão antiga costuma ignorar a coluna nova e seguir funcionando (DEDUZIDO); o contrário (código antigo esperando coluna que a migração removeu) quebra. Migração destrutiva em duas fases (`AGENTS.md`) existe para evitar justamente isso.

**2.4 Confirmação de que foi a função e não o banco.** Falhas registradas e respostas HTTP, sem dado pessoal.

EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 0 linhas, por falta de dado. Tabela em `20260930230000_monitoramento_e_alertas.sql:20-28`. `net._http_response` não guarda a URL chamada (mistura as funções).

```sql
select origem,
       codigo,
       date_trunc('hour', criada_em) as hora,
       count(*) as total
  from privado.falha_execucao
 where criada_em > now() - interval '24 hours'
 group by origem, codigo, date_trunc('hour', criada_em)
 order by hora desc, total desc;
```

EXECUTADO em 25/11/2026 (banco local, `develop` em `6225a77`): roda; 0 linhas, por falta de dado.

```sql
select status_code,
       count(*) as total,
       max(created) as ultima
  from net._http_response
 where created > now() - interval '1 hour'
 group by status_code
 order by status_code nulls first;
```

Os logs da função, por nome: `supabase functions logs <nome> --project-ref hbjkkcenbudiezmamiak`.

---

## 3. Mitigação

Escolha o caminho pela urgência. Em qualquer um, **não** rode `supabase secrets set` no meio do incidente: ele re-publica todas as funções (`docs/ESTADO.md`) e embaralha o diagnóstico.

### 3.1 Caminho canônico: revert na `develop` e tag nova

Use quando a função quebrada não derruba o produto inteiro.

1. Branch a partir da `develop`, `git revert <commit-ruim>` (ou restaure os arquivos da função do commit bom), PR para `develop` (`docs/RunbookHotfixERollback.md`, seção 3, passos 3 a 8). Teste Deno da função (`deno test --allow-all --no-check`) antes.
2. A CI leva cerca de 24 min (MEDIDO em 16/11/2026, 37 runs completos e verdes: mediana 24,4 min, p90 27,4, máximo 103,9).
3. **Antes de criar a tag, liste o que a Entrega aplicaria em Prod:** `./scripts/aplicar-remoto.sh hbjkkcenbudiezmamiak --seco` (`docs/RunbookHotfixERollback.md`, seção 4, passo 7). A tag publica **todas** as migrações pendentes **e todas** as funções do commit marcado (`entrega.yml`, passos "Migrações e semente" e "Edge Functions"). Se o Prod está atrás da `develop` (pacotes ainda não aplicados), a tag aplicaria esses pacotes junto. Isso transforma um rollback de função em um deploy grande. Se `--seco` listar migração que você não quer aplicar agora, **não use este caminho**: vá para 3.2.
4. Tag `backend-vX.Y.Z` no commit mesclado, aprovação no Environment `frila-prod` (`docs/RunbookHotfixERollback.md`, seções 1 e 3).
5. Duração do job de Prod depois da aprovação: MEDIDO nas duas tags existentes, **2,1 min** (`backend-v1.1.0`, run `41826751600`) e **1,7 min** (`backend-v1.1.1`, run `42059164212`), das quais o passo "Edge Functions" levou **16 s** e **12 s**. Tempo total do rollback por este caminho: DEDUZIDO, de 30 a 40 min (CI + aprovação + ~2 min), mais a espera pela aprovação, que pode levar horas (`entrega.yml`, comentário sobre a janela).

### 3.2 Caminho de emergência: republicar a função antiga à mão

Use quando a função quebrada para o produto agora (despacho, push, exclusão de conta) ou quando o caminho 3.1 arrastaria migrações.

Proposta, a confirmar; nunca executada em Prod. **Escrita em Prod: só humano autorizado, a pedido do dono** (`AGENTS.md`). O repositório já registra que esse caminho existe e o que ele não cobre: não passa pela janela, nem pela checagem da tag na `develop` (`docs/RunbookHotfixERollback.md`, seção 5, passo 5).

1. Worktree limpo no commit bom, **fora de `/private/tmp`** se possível: `git fetch origin --tags && git worktree add ../rollback-funcao <commit-bom>`. (`docs/ESTADO.md`: publicar a partir de `/private/tmp` falha no empacotador Docker e pede `--use-api`.)
2. No worktree, confira que o bloco `[functions.<nome>]` de `supabase/config.toml` (por exemplo `verify_jwt`) é o que você quer no Prod. A configuração antiga viaja com o commit antigo; se `verify_jwt` mudou entre os dois commits, a função antiga sobe com a configuração antiga (DEDUZIDO).
3. Publique **uma função por nome** (sem nome, o comando publica todas):

   ```bash
   # ESCRITA em Prod. NAO EXECUTAVEL AQUI: escreve e precisa de credencial de Prod. Token em variável de ambiente, nunca na linha de comando.
   SUPABASE_ACCESS_TOKEN="$TOKEN_DO_OPERADOR" \
     supabase functions deploy <nome> --project-ref hbjkkcenbudiezmamiak --use-api
   ```

   A versão do CLI usada pela Entrega é a `2.121.0` (`entrega.yml`, `supabase/setup-cli`); use a mesma.
4. Confirme: `supabase functions list --project-ref hbjkkcenbudiezmamiak` (a versão **sobe**: rollback gera versão nova, não reutiliza a velha, DEDUZIDO), diagnóstico 2.4 depois de alguns minutos, e a checagem diária (`scripts/checagem-diaria.sh`, humano).
5. Duração: o passo "Edge Functions" da Entrega publicou **todas** as funções em 12 a 16 s (MEDIDO, duas tags). Uma função só, à mão: NAO MEDIDO.
6. **Feche a lacuna no repositório no mesmo dia.** Rollback manual deixa o Prod diferente da `develop`. Abra o PR de revert (passo 1 do caminho 3.1). **Sem ele, a próxima tag publica de novo a versão quebrada.** O desvio não avisa (seção 1).
7. Registre no PR: função, commit bom, hora, resultado do diagnóstico 2.4.

### 3.3 O que **não** fazer

- Não editar migração aplicada para "consertar" a função (`scripts/migracoes-imutaveis.sh` reprova na CI).
- Não apagar a função no painel e recriar: perde-se a configuração e não se prova o que foi publicado. Nada pelo painel (`AGENTS.md`, "Banco e migrações").
- Não publicar a função a partir de um commit que não esteja na `develop` sem registrar o SHA.

---

## 4. Quem age

- **Quem fez a entrega que quebrou** abre o PR de revert e conduz o caminho 3.1. Os sócios têm comando total e quem leva o hotfix responde por ele (`docs/RunbookHotfixERollback.md`, seção 1).
- **Quem republica à mão em Prod:** sócio com `SUPABASE_ACCESS_TOKEN` válido. **A DEFINIR (Caue)**: quem, hoje, tem esse token e acesso de Owner ao projeto `frila-prod`.
- **Agente de IA:** prepara o revert, o teste e o texto; **não** publica em Prod, não empurra tag e não aprova (`AGENTS.md`; `docs/RunbookHotfixERollback.md`, seção 1).

## 5. Quem decide

- Declarar rollback e escolher entre 3.1 e 3.2: o sócio que lidera o incidente, com aval do Cauê para o caminho manual em Prod (**A DEFINIR (Caue)**: confirmar esta regra).
- Aprovar o job de Prod no GitHub: um dos 4 revisores do Environment `frila-prod`, que não seja quem abriu o PR (`docs/RunbookHotfixERollback.md`, seção 1).
- Avisar usuários sobre indisponibilidade: **A DEFINIR (Caue)**.
