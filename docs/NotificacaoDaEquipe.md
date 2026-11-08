# Notificação da Equipe por E-mail

Guia de uso do aviso por e-mail para os sócios: `scripts/notificar-equipe.sh` e a lógica
em `scripts/notificar_equipe.py`.

Existe para que um passo de automação (entrega contínua, checagem diária, purga,
monitoramento) possa avisar Cauê, Jotapê e Fabrício sem que ninguém decore endereço nem
cole senha em linha de comando.

> **Não confundir com o e-mail de produto.** A Edge Function `enviar-email`
> (`supabase/functions/enviar-email/`) continua sendo o caminho do e-mail que o usuário
> recebe: código de entrada, protocolo de denúncia, contestação. Este script é ferramenta
> de operação, roda na máquina de quem opera e nunca no runtime do app. Os dois leem as
> mesmas variáveis de SMTP de propósito: dois nomes para o mesmo endereço custaria um
> e-mail que não sai porque a variável certa tem o nome do outro arquivo.

---

## 1. Uso

```bash
# Aviso para os três sócios
./scripts/notificar-equipe.sh --assunto "Entrega no frila-dev" --corpo "develop em c293dfc"

# Ensaio: imprime o que faria e não envia nada
./scripts/notificar-equipe.sh --assunto "Entrega" --corpo "corpo" --dry-run

# Destinatário específico (substitui o padrão)
./scripts/notificar-equipe.sh --assunto "Só para o Cauê" --corpo "corpo" \
  --para cauecarneiroc@gmail.com

# Lista, por vírgula ou por repetição de --para
./scripts/notificar-equipe.sh --assunto "A" --corpo "B" \
  --para "cauecarneiroc@gmail.com,fbtostadev@gmail.com"
```

| Opção | Obrigatória | O que faz |
|---|---|---|
| `--assunto` | sim | Assunto do e-mail. Quebra de linha é recusada (injeção de cabeçalho) |
| `--corpo` | sim | Corpo em texto puro |
| `--para` | não | Substitui os destinatários padrão. Aceita vírgula e repetição |
| `--dry-run` | não | Imprime assunto, remetente, destinatários e tamanho do corpo; não envia |

**Destinatários padrão:** `cauecarneiroc@gmail.com`,
`joaopauloalbuquerque606@gmail.com`, `fbtostadev@gmail.com`. Júlia (PO) não entra por
padrão: aviso de pipeline não é decisão de produto; quando for para ela, passe `--para`.

---

## 2. Contrato de saída

O pipeline depende destes códigos, e eles são a parte do script que a suíte de testes
trava:

| Código | Quando | Por quê |
|---:|---|---|
| `0` | E-mail enviado | — |
| `0` | `--dry-run` | Ensaio não envia e não reprova nada |
| `0` | Sem credencial de SMTP no ambiente | Um aviso que não sai não pode derrubar a entrega que ele ia anunciar. Imprime quem receberia e como configurar |
| `1` | Erro de uso: falta `--assunto` ou `--corpo`, destinatário inválido, quebra de linha em cabeçalho | Erro de quem chamou, não do ambiente |
| `2` | Falha de SMTP **com** credencial presente | Aí há o que consertar, e o silêncio custaria mais que a falha |

O `2` é a única saída de erro de envio. Se o script sai `0` dizendo "SMTP não
configurado", o problema é `.env`, não rede.

---

## 3. Variáveis de ambiente

Lidas do ambiente. O invólucro `notificar-equipe.sh` carrega o `.env` da raiz do
repositório (`set -a; source .env`) e o `.py` nunca abre o arquivo — o que facilita
chamar o `.py` direto num ambiente controlado, como a suíte de testes faz.

| Variável | Padrão | Observação |
|---|---|---|
| `SMTP_HOST` | — | Vazio desliga o envio (saída `0`, nada enviado) |
| `SMTP_PORT` | `587` | `465` usa TLS implícito; `587` e `25` sobem por STARTTLS |
| `SMTP_USER` | — | Opcional: sem usuário e senha, não há `login` |
| `SMTP_PASS` | — | Nunca aparece em log, nem em mensagem de erro |
| `SMTP_SENDER` | `verificacao@frilabr.com` | Remetente. Endereço inválido desliga o envio |
| `SMTP_TLS` | `1` | `0` desliga TLS e STARTTLS, para apontar o Mailpit local |

As mesmas variáveis já estão no `.env.example` da raiz, seção
"SMTP do código de entrada". Não há variável nova para configurar.

Para ensaiar o envio de verdade sem tocar em caixa de ninguém, suba o Mailpit local e
aponte `SMTP_HOST=localhost`, `SMTP_PORT=1025`, `SMTP_TLS=0`.

---

## 4. Segurança

- **Injeção de cabeçalho é recusada.** `\r` e `\n` em destinatário ou assunto saem `1`.
  Sem isso, quem controla o texto do aviso controlaria o `Bcc`. A `enviar-email` faz a
  mesma recusa do lado do produto.
- **Credencial não entra em log.** A mensagem de falha carrega host, porta e o erro do
  `smtplib`, nunca `SMTP_PASS`.
- **Nada de dado pessoal no corpo.** Aviso de pipeline fala de commit, branch, migração e
  número de teste. Nome, telefone, CPF ou e-mail de usuário do app não entram: o aviso vai
  para três caixas de Gmail, que não são ambiente de dado pessoal (LGPD, coleta mínima).

---

## 5. Testes

```bash
./scripts/teste-notificar-equipe.sh
```

19 verificações, sem rede e sem credencial: todo caso força `SMTP_HOST` vazio no ambiente
do processo filho e chama o `.py` direto, não o invólucro. Uma suíte que mandasse e-mail
de verdade para os três sócios a cada rodada ninguém rodaria duas vezes.

Cobre: `--dry-run` sai `0` e lista os três padrões; falta de `--assunto`, de `--corpo` e de
argumento nenhum saem `1` com a linha de uso; sem SMTP o envio real sai `0` e explica;
`--para` substitui o padrão; quebra de linha em destinatário e em assunto sai `1`.

O portão estático dos scripts é o de sempre: `./scripts/auditar-scripts-backend.sh`
(+x, `set -u`, `/tmp` com `mktemp`, nada de segredo embutido, `rm -rf` protegido e
ShellCheck quando instalado).

---

## 6. Integração com o Trello

O aviso por e-mail **não substitui o quadro**, e a ordem importa: o quadro é o registro,
o e-mail é o empurrão. Quem lê o e-mail e não acha o cartão não tem o que fazer com o
aviso.

1. O cartão recebe o fato por `./scripts/trello.sh comentar <shortLink> "<texto>"` —
   hash do commit, número de teste, link do PR.
2. Só então o e-mail sai, citando o link curto do cartão e o do PR:

```bash
CARTAO=dke9K3yV
./scripts/trello.sh comentar "$CARTAO" "[MEDIDO] PR aberto: $URL_PR"
./scripts/notificar-equipe.sh \
  --assunto "Backend · PR aberto no cartão $CARTAO" \
  --corpo "$(printf 'PR: %s\nCartão: https://trello.com/c/%s\n' "$URL_PR" "$CARTAO")"
```

Num passo de CI ou de entrega, deixe o aviso **no fim** do job e nunca com `set -e`
dependendo dele: por contrato ele sai `0` quando não tem credencial, mas um `2` de SMTP
fora do ar não deve reprovar uma entrega que já aconteceu. Se o job precisar do resultado,
trate o código explicitamente:

```bash
./scripts/notificar-equipe.sh --assunto "..." --corpo "..." || \
  echo "aviso não saiu (código $?); a entrega não depende disso" >&2
```

---

## 7. O que este script não faz

- Não manda anexo, HTML nem imagem: só texto puro.
- Não tem fila nem repetição. Falha de SMTP sai `2` e acabou; quem precisa de garantia de
  entrega usa a `enviar-email`, que tem o provedor e o registro do lado do produto.
- Não lê o quadro. Quem decide o que o aviso diz é o script que o chama.
