# D04 — Captcha da entrada: desligado por ora; quando ligar, Cloudflare Turnstile

**Estado:** aceita · **Cartão:** [`ohSt4dg2`](https://trello.com/c/ohSt4dg2) ·
**Decisão:** pré-aprovada pelo Cauê (pedido 16-28), pela recomendação da Forja e da Bússola
(`orquestracao/retornos/P-033-captcha-recomendacao.md`) · **Data:** 16/11/2026

**Captcha da entrada (decisão de 16/11/2026, pré-aprovada pelo Cauê, pela recomendação da Forja e da Bússola):** fica desligado no Prod. Ligar sem o widget nos apps tranca a entrada de todos. O abuso provável hoje é gastar o limite de e-mails do Auth (30 por hora, no projeto inteiro); ele fica coberto pelo alerta de uso da cota. Quando ligar: Cloudflare Turnstile, depois de os apps mandarem o token, com versão mínima dos apps e Política nova avisada aos cadastrados. Gatilhos para antecipar: cota de e-mail esgotada por pedidos sem entrada, contas falsas em série ou a web lançada.

## Como isso é conferido

`scripts/conferir-auth-remoto.sh` reprova se o captcha estiver ligado (`security_captcha_enabled`) ou se o
limite de e-mails por hora (`rate_limit_email_sent`) sair de 30. Os dois esperados mudam por variável
(`AUTH_CAPTCHA_ESPERADO=turnstile`, `AUTH_LIMITE_EMAILS_HORA`) no dia em que esta decisão mudar.
Medido no `frila-dev` em 16/11/2026 22h4x: `rate_limit_email_sent = 30`, captcha desligado,
`rate_limit_otp = 30`, `rate_limit_verify = 30`.
