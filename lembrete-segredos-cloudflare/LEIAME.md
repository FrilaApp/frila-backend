# Lembrete de vencimento de segredos (Cloudflare)

Worker gratuito, JavaScript ESM sem dependências, mesmo padrão da `vigia-cloudflare` (conta frila.org,
wrapper `orquestracao/scripts/wrangler-frila`). Um Cron Trigger por dia (`0 12 * * *`, 12:00 UTC = 09:00 em
Brasília). O Mac pode estar desligado. É só um **lembrete**: não renova nada e não guarda chave.

## O que ele guarda
Só DATAS e identificadores públicos, na var `SEGREDOS` do `wrangler.jsonc` (JSON, um item por segredo e
ambiente: `ambiente`, `segredo`, `vence_em` AAAA-MM-DD, `renovar` com o comando e `onde_colar`). Nenhuma chave,
`.p8` ou JWT (o teste reprova se aparecer). Team ID, Key ID e Services ID da Apple aparecem no JWT e na URL do
login: não são segredo. Secret do Worker: só `SLACK_BOT_TOKEN` (o mesmo bot `Frila Agentes` da vigia), lido do
ambiente e nunca versionado.

## Regra
Faltando mais de 14 dias: nada. De 14 dias até o dia do vencimento: 1 aviso por dia em `#alertas-prod`.
Depois de vencido: aviso diário de VENCIDO. Dias contados em dias de calendário UTC. O aviso traz o comando
de renovação e onde colar. Formato torto em `SEGREDOS`: não avisa e registra o motivo curto no log.

## Renovar o segredo Apple (rotina, depois do aviso)
1. `python3 -I ~/.config/frila/bin/apple-client-secret.py ~/.config/frila/apple-sign-in-AuthKey.p8 8B7F7G3Y2U 8G79ZNBJKR com.frila.org.app.web <saida> 180`
   (validade de 180 dias; Team ID, Key ID e Services ID como no `wrangler.jsonc`).
2. Colar o JWT novo em Supabase (`<ambiente>`) > Auth > Providers > Apple, pelo portal. Nada de token
   permanente do Supabase nem renovação automática (decisão do Cauê, 24/11/2026).
3. Atualizar `vence_em` no `wrangler.jsonc` (hoje + 180 dias, menos uma folga) e publicar:
   `orquestracao/scripts/wrangler-frila deploy`, na pasta `lembrete-segredos-cloudflare/`.
4. O Prod entra na lista (novo item em `SEGREDOS`) quando o Apple do Prod for configurado.

## Validar e preparar (sem publicar)
Na raiz do repositório: `node --test lembrete-segredos-cloudflare/teste/lembrete.test.js`.
Na pasta do Worker: `wrangler-frila deploy --dry-run`.

## Provar (líder, depois da autorização)
`AVISO_TESTE=teste-1` (etiqueta de letras, números, `_` e `-`) faz o próximo cron postar UM aviso marcado
`🧪 TESTE`, mesmo fora da janela. Para provar sem esperar até 12:00 UTC, publique com um cron temporário
(`*/5 * * * *`), confira o aviso no canal e o log (`wrangler-frila tail`), esvazie `AVISO_TESTE`, volte o cron
para `0 12 * * *` e publique de novo (o teste do repositório reprova se a etiqueta ou o cron ficarem errados).
Suspender: `triggers.crons: []` e publicar. Remover: `wrangler-frila delete`.
