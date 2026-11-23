# Vigia da saúde no Cloudflare

Worker gratuito, JavaScript ESM sem dependências. Referência: `scripts/vigia_saude.py`.
Um Cron Trigger (`*/5 * * * *`, UTC) consulta `URL_SAUDE`: só HTTP 200 com `ok: true`
é saudável. Falhou? Espera 60 s e confirma. Timeout de rede: 20 s por chamada;
corpos limitados a 64 KiB. O handler HTTP público responde somente `200 ok`;
ele não executa a sonda nem prova que o cron está funcionando.

O binding `ESTADO_VIGIA` aponta para um único namespace KV, com uma chave `estado`:
última execução, início da queda, último aviso e etiqueta do teste. Uma única escrita
por execução reúne tudo. Primeiro alerta, lembrete após uma hora, recuperação com
duração e aviso quando a execução anterior tiver mais de 15 min. Somente `status`
curto e validado da saúde entra no aviso. URLs, tokens e corpos crus não vão ao log.

Slack usa `chat.postMessage`, canal em `SLACK_CANAL`, secret `SLACK_BOT_TOKEN` lido
somente do ambiente. HTTP diferente de 200 ou JSON sem `ok: true` gera log genérico,
com o campo `error` apenas se curto e validado. Falha de envio não derruba o cron;
o estado avança mesmo assim, sem tentar reenviar a cada execução.
**Ressalva para o PR:** o token do bot tem escopo maior que um webhook dedicado;
trocar por webhook dedicado fica como melhoria. Nunca imprimir nem versionar o token.

## Validar e preparar (sem publicar)

Na raiz do repositório: `node --test vigia-cloudflare/teste/vigia.test.js` (o arquivo explícito: a CI usa o Node padrão do runner, que não aceita pasta como argumento).
Na pasta `vigia-cloudflare/`:
`/Users/cauecarneiro/Documents/Projetos/Frila/orquestracao/scripts/wrangler-frila deploy --dry-run`.
O `package.json` só declara ESM; não há instalação de pacotes.

## Ligar, provar e desligar (líder, após a mescla e autorização)

Use sempre o wrapper `orquestracao/scripts/wrangler-frila` da raiz do Frila,
executando os comandos abaixo em `vigia-cloudflare/`. Não usar login global.

1. Confirmar Workers Free na conta Frila. Criar o namespace com
   `wrangler-frila kv namespace create ESTADO_VIGIA` e substituir o ID marcador
   em `wrangler.jsonc` pelo ID retornado. O marcador não é namespace existente.
2. Cadastrar `SLACK_BOT_TOKEN` com `wrangler-frila secret put SLACK_BOT_TOKEN`,
   usando entrada segura, sem imprimir/gravar o valor em arquivos. O bot deve
   estar no canal configurado, com permissão `chat:write`.
3. Definir `AVISO_TESTE` com etiqueta nova (letras, números, `_` e `-`, até 64 caracteres),
   por exemplo `teste-1`; executar `wrangler-frila deploy`. A etiqueta gera uma
   tentativa de aviso `TESTE: ` e fica no KV para não repetir. Seu conteúdo não é enviado.
4. Provar com `wrangler-frila tail`: ver execução **agendada**, além do aviso de teste
   no canal; o plano do brief pede duas execuções. Aguardar a propagação do cron
   ([até 15 min](https://developers.cloudflare.com/workers/configuration/cron-triggers/)).
   Depois esvaziar `AVISO_TESTE` e publicar novamente. Reutilizar a última etiqueta não reenvia.
5. Para suspender só o cron, deixar `triggers.crons: []` e publicar; para religar,
   restaurar o cron e publicar. Para remover o Worker: `wrangler-frila delete`.
   Preservar o namespace e seu estado; ao religar pode haver aviso de atraso.

## Custo e limites

Inferência: 24 × 60 ÷ 5 = **288 execuções/dia**, uma leitura e uma escrita KV cada:
288 leituras e 288 escritas/dia, inclusive durante queda, lembrete e teste.
Isso usa 28,8% das 1.000 escritas/dia gratuitas; a cota de KV é compartilhada pela conta.
Sem Durable Objects, Queues ou recurso pago. Fontes:
[KV gratuito e limites](https://developers.cloudflare.com/kv/platform/limits/),
[Workers Free](https://developers.cloudflare.com/workers/platform/pricing/).
Workers Free limita CPU a 10 ms por invocação; espera/rede não exigem CPU contínua.
O dry-run não mede CPU em produção: conferir no deploy. Se exigir plano pago, parar.

KV tem [consistência eventual](https://developers.cloudflare.com/kv/concepts/how-kv-works/):
não há garantia de entrega única sob concorrência ou leitura antiga entre regiões.
Manter somente um cron e evitar disparos manuais simultâneos. Perda do KV reinicia a
deduplicação. Falha no KV gera log fixo; a próxima execução pode avisar o atraso.
O vigia só percebe atraso **quando volta a rodar**; não detecta o próprio sumiço total.
O Actions permanece como segundo olhar, sem garantia de pontualidade (runbook, seção 6).
