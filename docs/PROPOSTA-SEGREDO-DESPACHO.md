# Proposta de Desenho: Autenticação Segura de Disparos Assíncronos via HMAC Efêmero e Segregação de Chaves

**Data:** 21/10/2026  
**Autora:** Faísca (Backend / Edge Functions / pgTAP)  
**Status:** Desenho Técnico Arquitetural (Aguardando Aprovação da Rainha Marika)  
**Contexto:** Pós-PR #187 (Vault em produção/develop) e pós-PR #284 (fechado após prova empírica de ineficácia de `REVOKE` na CI)

---

## 1. Motivação e Diagnóstico do Risco

### 1.1 O Ponto Frágil Atual
Hoje, os webhooks assíncronos disparados no pós-commit via `pg_net` (`privado.disparar_despacho` e `privado.disparar_email`) enviam um segredo estático nos cabeçalhos HTTP:
```text
Authorization: Bearer <segredo>
x-agendador-secret: <segredo>
```
Mesmo após a migração para o Supabase Vault (PR #187, `supabase/migrations/20261018200000_vault_agendador_secret.sql`), onde o segredo é lido de `vault.decrypted_secrets`, ele é montado em texto plano nos cabeçalhos HTTP passados para `net.http_post(...)`.

Como a extensão `pg_net` enfileira a requisição na tabela `net.http_request_queue` (coluna `headers jsonb`) e registra a resposta em `net._http_response`, esse segredo estático fica persistido em texto claro em tabelas do banco de dados.

### 1.2 Por que REVOKE não Resolve (Evidência da CI Run 39075930776 / PR #284)
Tentou-se revogar as concessões do schema `net` para `anon`, `authenticated` e `PUBLIC` via migração SQL no PR #284 (`fix/seguranca-revogar-grants-pg-net`). A execução oficial na esteira de CI (**GitHub Actions Run 39075930776**) e testes locais reproduzidos comprovaram a impossibilidade dessa via na arquitetura Supabase:
1. No contêiner oficial do Supabase CLI e no Supabase hospedado, a role que executa migrações (`postgres`) possui `rolsuper = false`.
2. A extensão `pg_net` e o schema `net` pertencem ao superusuário `supabase_admin` (`rolsuper = true`).
3. No PostgreSQL, papéis sem atributo de superusuário **não têm autoridade para revogar privilégios concedidos por superusuários** sobre objetos dos quais não são proprietários. O banco emite sucessivos avisos `WARNING (01006): no privileges could be revoked for "net"` e mantém todas as permissões intactas.
4. O teste pgTAP 741 falhou em 10 das 12 asserções na CI, confirmando empiricamente que `REVOKE` via migração é inócuo.

### 1.3 Concentração de Risco: Segredo Único
Historicamente, o mesmo `agendador_secret` foi reutilizado por múltiplas Edge Functions (`despachar`, `enviar-email`, `enviar-push`, `limpar-contas-orfas`). Um eventual vazamento na fila do `pg_net` expõe não apenas o despacho, mas todo o subsistema de automação assíncrona da aplicação.

### 1.4 Fronteira do Modelo de Ameaças
- **O que esta proposta protege:** Protege contra atacantes ou clientes com acesso de leitura à fila `net.http_request_queue` ou `net._http_response` (ex.: consultas acidentais, vazamento de logs de fila ou eventuais desconfigurações). O leitor da fila vê apenas assinaturas efêmeras que expiram em segundos.
- **O que a proposta NÃO protege:** Qualquer sessão com capacidade de ler diretamente os segredos no Vault (`vault.decrypted_secrets`) ou GUCs como superusuário/administrador continua capaz de obter a chave e forjar assinaturas. Essa fronteira é de competência do controle de acesso ao Vault e ao banco de dados.

---

## 2. A Solução Arquitetural: HMAC Efêmero + Segregação por Função

Em vez de enviar o segredo compartilhado estático no cabeçalho HTTP, adota-se o padrão da indústria de webhooks (similar a Stripe, GitHub e Slack):
1. **Segregação por Função:** Cada Edge Function possui seu segredo específico (`despacho_secret`, `email_secret`), armazenado no Supabase Vault (`vault.decrypted_secrets`).
2. **Tokens HMAC-SHA256 Assinados de Curta Duração (120 s):** Os cabeçalhos HTTP carregam apenas um *timestamp*, um *nonce* e a assinatura hexadecimal `v1=<hash>`.
3. **Zero Exposição de Segredo na Fila:** Nenhum segredo trafega em cabeçalhos ou é gravado em `net.http_request_queue`.
4. **Anti-Replay Baseado em Janela Temporal:** Validação rigorosa na Edge Function com tolerância de 120 s (suficiente para absorver a latência do worker do `pg_net` com folga ~100x, conforme comprovado pelo protótipo).

---

## 3. Resultados Empíricos do Protótipo (Item 13)

Um protótipo ponta a ponta foi executado e documentado (`NOTA-PROTOTIPO-HMAC.md`), comprovando a viabilidade técnica:

1. **Fidelidade de Bytes Wire-to-Deno (100%):**
   - O corpo recebido no Deno via `await req.text()` coincidiu de forma 100% idêntica com o texto assinado no PostgreSQL via `convert_to(..., 'UTF8')`.
   - Não houve mutação, alteração de quebras de linha ou corrupção de caracteres especiais/acentos.
2. **Latência Medida do pg_net:**
   - Medições reais em bateria de disparos locais: `[ 521 ms, 1290 ms, 779 ms, 1037 ms, 268 ms ]`.
   - Latência média: **779 ms** | Máxima observada: **1290 ms** (~1,3 s).
   - Uma janela de tolerância de **120 segundos** absorve com margem superior a 90x a latência típica do background worker, oferecendo proteção anti-replay firme sem risco de falsos positivos.
3. **Mapeamento Efetivo de Chamadores via pg_net:**
   - Auditoria completa no repositório confirmou que apenas **`despachar`** e **`enviar-email`** são disparadas via `net.http_post` no banco de dados.
   - `enviar-push` e `limpar-contas-orfas` **não** possuem chamadas `net.http_post` no SQL do produto; são orquestradas por executores externos. Logo, o escopo de emissão de HMAC no PostgreSQL restringe-se a `despachar` e `enviar-email`.

---

## 4. Especificação do Protocolo de Assinatura

### 4.1 Cabeçalhos da Requisição
A requisição HTTP gerada pelo PostgreSQL conterá:
- `Content-Type`: `application/json`
- `x-frila-timestamp`: Timestamp UNIX em segundos (`extract(epoch from privado.agora())::bigint::text`)
- `x-frila-nonce`: Identificador único aleatório (`gen_random_uuid()::text`)
- `x-frila-assinatura`: Assinatura HMAC hexadecimal com prefixo de versão: `v1=<hex_hmac_sha256>`

### 4.2 Formato da Base de Assinatura (*Canonical String*)
A base assinada concatena estritamente:
```text
base_assinatura = timestamp || "." || nonce || "." || corpo_json_compacto
```

> [!IMPORTANT]
> **Codificação UTF-8 Estrita com `convert_to`:**
> O PostgreSQL deve utilizar obrigatoriamente `convert_to(v_base, 'UTF8')` e `convert_to(p_segredo, 'UTF8')`. O uso de `::bytea` direto é proibido porque interpreta barras invertidas como sequências de escape do catálogo, corrompendo payloads com aspas ou sequências Unicode.

---

## 5. Desenho da Implementação

### 5.1 Função de Assinatura no Banco de Dados (`privado.assinar_webhook_pg_net`)

```sql
create or replace function privado.assinar_webhook_pg_net(
  p_segredo text,
  p_corpo jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_timestamp text := extract(epoch from privado.agora())::bigint::text;
  v_nonce     text := gen_random_uuid()::text;
  v_corpo_txt text := coalesce(p_corpo::text, '{}');
  v_base      text := v_timestamp || '.' || v_nonce || '.' || v_corpo_txt;
  v_hmac      text;
begin
  if p_segredo is null or p_segredo = '' then
    raise exception 'Segredo ausente para assinatura HMAC de webhook';
  end if;

  v_hmac := encode(
    extensions.hmac(
      convert_to(v_base, 'UTF8'),
      convert_to(p_segredo, 'UTF8'),
      'sha256'
    ),
    'hex'
  );

  return jsonb_build_object(
    'Content-Type',       'application/json',
    'x-frila-timestamp',  v_timestamp,
    'x-frila-nonce',      v_nonce,
    'x-frila-assinatura', 'v1=' || v_hmac
  );
end;
$$;

revoke execute on function privado.assinar_webhook_pg_net(text, jsonb) from public, anon, authenticated;
```

### 5.2 Integração com `privado.disparar_despacho` e Vault
Em `privado.disparar_despacho`:
```sql
  -- Prioridade: Vault (despacho_secret -> agendador_secret) -> GUC (frila.despacho_secret -> frila.agendador_secret)
  v_secret := coalesce(
    (select decrypted_secret from vault.decrypted_secrets where name = 'despacho_secret' limit 1),
    (select decrypted_secret from vault.decrypted_secrets where name = 'agendador_secret' limit 1),
    nullif(current_setting('frila.despacho_secret', true), ''),
    nullif(current_setting('frila.agendador_secret', true), '')
  );

  v_headers := privado.assinar_webhook_pg_net(
    p_segredo => v_secret,
    p_corpo   => v_body
  );

  v_req_id := net.http_post(
    url                  => v_url,
    headers              => v_headers,
    body                 => v_body,
    timeout_milliseconds => 5000
  );
```

Procedimento análogo para `privado.disparar_email` utilizando `email_secret`.

### 5.3 Módulo de Verificação na Edge Function (Deno / TypeScript)
Arquivo compartilhado `supabase/functions/_compartilhado/auth_webhook.ts`:

```ts
import { timingSafeEqual } from "node:crypto";

export async function validarWebhookHmac(
  req: Request,
  rawBody: string,
  secret: string,
  janelaToleranciaSegundos = 120
): Promise<boolean> {
  const timestampStr = req.headers.get("x-frila-timestamp");
  const nonce = req.headers.get("x-frila-nonce");
  const assinaturaHeader = req.headers.get("x-frila-assinatura");

  if (!timestampStr || !nonce || !assinaturaHeader) {
    return false;
  }

  // 1. Validação Temporal Anti-Replay
  const timestamp = parseInt(timestampStr, 10);
  if (isNaN(timestamp)) return false;

  const agora = Math.floor(Date.now() / 1000);
  if (Math.abs(agora - timestamp) > janelaToleranciaSegundos) {
    return false;
  }

  // 2. Extração do hash
  const match = assinaturaHeader.match(/^v1=([a-f0-9]{64})$/i);
  if (!match) return false;
  const signatureEsperadaHex = match[1].toLowerCase();

  // 3. Cálculo do HMAC-SHA256
  const canonical = `${timestampStr}.${nonce}.${rawBody}`;
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signatureBuffer = await crypto.subtle.sign("HMAC", key, enc.encode(canonical));
  const signatureCalculadaHex = Array.from(new Uint8Array(signatureBuffer))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  // 4. Comparação em Tempo Constante (Prevenção contra Timing Attacks)
  return timingSafeEqual(
    enc.encode(signatureCalculadaHex),
    enc.encode(signatureEsperadaHex)
  );
}
```

---

## 6. Mapeamento de Segredos e Variáveis

| Função | Canal | Segredo no Vault / GUC | Variável na Edge Function |
|---|---|---|---|
| `despachar` | `pg_net` (`privado.disparar_despacho`) | `despacho_secret` | `DESPACHO_SECRET` |
| `enviar-email` | `pg_net` (`privado.disparar_email`) | `email_secret` | `EMAIL_SECRET` |
| `enviar-push` | Runner agendado externo | N/A (não chamado por `pg_net`) | `PUSH_SECRET` |
| `limpar-contas-orfas` | Cron HTTP externo | N/A (não chamado por `pg_net`) | `LIMPEZA_SECRET` |

---

## 7. Estratégia de Transição Sem Downtime (Zero Downtime)

A migração divide-se em 3 etapas desacopladas:

1. **Fase 1 (Suporte Duplo nas Edge Functions):**
   - Atualizar `despachar` e `enviar-email` para aceitarem:
     - Assinatura HMAC válida via `validarWebhookHmac` com o segredo específico da função; **OU**
     - Autenticação legada via `Authorization: Bearer` / `x-agendador-secret`.
   - Deploy das Edge Functions sem tocar no banco de dados.

2. **Fase 2 (Ativação da Assinatura no Banco de Dados):**
   - Cadastrar `despacho_secret` e `email_secret` no Vault.
   - Aplicar a migração que introduz `privado.assinar_webhook_pg_net` e atualiza `privado.disparar_despacho` e `privado.disparar_email`.
   - A partir deste momento, todos os disparos em `net.http_request_queue` deixam de carregar segredos em texto plano.

3. **Fase 3 (Depreciação e Corte do Acesso Legado):**
   - Remover a rota de fallback estática das Edge Functions `despachar` e `enviar-email`.
   - Rotacionar e invalidar o segredo `agendador_secret` legado.

---

## 8. Verificação e Critérios de Aceite

1. **pgTAP:**
   - Teste unitário de `privado.assinar_webhook_pg_net` validando cabeçalhos gerados, formato de timestamp, presença de nonce e formato `v1=<64_hex>`.
   - Teste de integração de `privado.disparar_despacho` verificando que a requisição enfileirada no `net.http_request_queue` não contém `Authorization` nem `x-agendador-secret`.
2. **Deno Tests:**
   - Casos de sucesso com payload JSON normal e caracteres UTF-8 acentuados.
   - Rejeição de timestamp expirado (> 120 s no passado ou no futuro).
   - Rejeição de assinatura adulterada ou calculada com chave diferente.
   - Rejeição de payload adulterado (mutação de corpo).
3. **Compatibilidade com o Produto:**
   - Testes de ciclo completo e corrida de despacho (`scripts/ciclo-completo.sh`, `scripts/corrida-ciclo.sh`) permanecem 100% verdes.
