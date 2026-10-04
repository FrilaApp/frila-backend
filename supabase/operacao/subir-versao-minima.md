# Subir a versão mínima do app

Quando um build publicado tem defeito grave e precisa sair de circulação. Abaixo da
`versao_minima`, o app troca todas as telas pela tela de atualização e leva à loja.
Sem rede, ele abre normalmente: o bloqueio vale na próxima abertura com rede.

A configuração mora na tabela `privado.configuracao_app`, uma linha por plataforma, e é lida
sem sessão por `GET /rest/v1/rpc/configuracao_do_app?plataforma=ios` (contrato 0.2.16+).

---

## 1. Antes de Alterar

1. **A versão nova já está na loja e aprovada.** Subir a mínima antes disso bloqueia
   todo mundo sem ter para onde encaminhar o usuário.
2. **A versão é a de build** (`MARKETING_VERSION` do `iOS/project.yml` no
   `frila-frontend`), composta exclusivamente por números e pontos: `1.2.10`, nunca `v1.2.10`.
   O banco recusa formatos inválidos e rejeita `versao_recomendada` abaixo de `versao_minima`.
3. **Mensagem opcional:** Se `mensagem` for `null`, o app exibe o texto padrão de bloqueio.
   Preencher apenas quando for necessário orientar o usuário sobre o motivo específico do bloqueio.

---

## 2. Operação de Emergência (Sem Migração e Sem Janela Proibida RNF12)

Em caso de defeito crítico em produção (ex.: vazamento de dados, falha grave de integridade,
crash generalizado no lançamento), **a contenção deve ser imediata**. Não se deve aguardar
a abertura de branch, revisão de PR e execução da esteira de CI (~35 minutos).

### Por que é isento da Janela Proibida RNF12?
- A regra **RNF12** e o script `scripts/janela-de-manutencao.sh` proíbem a aplicação de
  **migrações estruturais DDL** de quinta a domingo, das 16h às 02h (horário de pico do food service),
  para prevenir bloqueios de catálogo e riscos de indisponibilidade.
- Alterar a versão mínima em `privado.configuracao_app` é uma operação **DML pontual de 1 linha**
  (`UPDATE`), com execução em fração de milissegundo, sem lock estrutural e sem impacto na retrocompatibilidade.
- Portanto, a contenção emergencial de um app com defeito grave via DML é **isenta da restrição de horário da RNF12**
  e pode ser executada a qualquer momento.

### Quem altera e segurança da tabela
- A tabela `privado.configuracao_app` possui Row Level Security (RLS) habilitado sem políticas e
  permissões revogadas para `public`, `anon` e `authenticated`.
- Apenas operadores com papel administrativo (**`postgres`**, **`service_role`** ou DBA autorizado)
  possuem privilégio para alterar os registros.

### Comando SQL de atualização
Mesmo no comando direto, o banco continua aplicando todas as restrições `CHECK` de integridade
(`versao_minima_formato`, `versao_recomendada_formato`, `recomendada_nao_abaixo_da_minima`,
`url_da_loja_https` e `mensagem_nao_vazia`):

```sql
update privado.configuracao_app
   set versao_minima      = '1.0.1',
       versao_recomendada = '1.0.1',
       mensagem           = null,      -- null usa o texto padrão do app
       atualizado_em      = now()
 where plataforma = 'ios';
```

---

## 3. Procedimento de Execução por Ambiente

### No ambiente local (desenvolvimento / teste)
Via container local do Postgres:
```bash
docker exec -i supabase_db_frila-backend psql -U postgres -d postgres -c \
  "UPDATE privado.configuracao_app SET versao_minima = '1.0.1', versao_recomendada = '1.0.1', atualizado_em = now() WHERE plataforma = 'ios';"
```

### No ambiente remoto (`frila-dev` e `frila-prod`)
Pelo operador de infraestrutura / DBA, conectando diretamente com credencial administrativa
(`postgres` / pooler de produção) ou executando o SQL via CLI administrativa:
```bash
# Exemplo via psql conectado ao banco remoto:
psql "$PROD_DB_URL" -c \
  "UPDATE privado.configuracao_app SET versao_minima = '1.0.1', versao_recomendada = '1.0.1', atualizado_em = now() WHERE plataforma = 'ios';"
```

### Conferência imediata por HTTP
Após o comando, consulte a RPC como cliente anônimo (chave pública, sem sessão). O PostgREST não
faz cache e a resposta reflete a nova versão imediatamente:
```bash
curl -s "https://<project-ref>.supabase.co/rest/v1/rpc/configuracao_do_app?plataforma=ios" \
  -H "apikey: $SUPABASE_ANON_KEY"
```

A resposta esperada é HTTP 200:
```json
{
  "plataforma": "ios",
  "versao_minima": "1.0.1",
  "versao_recomendada": "1.0.1",
  "url_da_loja": "https://apps.apple.com/app/id6815311991",
  "mensagem": null
}
```

---

## 4. Fase 2: Conciliação Pós-Incidente no Repositório

Após conter a crise em produção:
1. **Registrar no histórico do repositório:** Em horário regular, abra um PR contra a `develop`
   com uma migração registrando o novo patamar de versão (ex.: `202610..._versao_minima_ios_1_0_1.sql`).
2. **Garantia para novos ambientes:** Isso assegura que novos ambientes de teste e reinicializações
   com `supabase db reset` inicializem já com o piso de versão atualizado, evitando regressões locais.

---

## 5. Voltar Atrás

Caso a atualização obrigatória precise ser afrouxada ou desfeita:
- Execute novo `UPDATE` administrativo reduzindo a `versao_minima` para o patamar anterior.
- Respeite a regra de que `versao_recomendada` nunca pode ser inferior à `versao_minima`.

---

## 6. Android e Web

Atualmente respondem `404 nao_encontrado` porque não possuem lojas publicadas no piloto.
Quando os aplicativos dessas plataformas forem disponibilizados, as linhas correspondentes
devem ser inseridas em `privado.configuracao_app` com a respectiva `url_da_loja`.
