# Procedimento operacional: SMTP próprio no Supabase Auth

Passo a passo operacional para configuração e homologação do SMTP próprio no Supabase Auth (cartão `XtZTlTIA`).

O envio embutido do Supabase entrega cerca de 2 e-mails por hora e apenas para endereços autorizados do time. Com o SMTP próprio, o limite sobe para a cota do provedor (~500 por dia no Gmail) e permite entregar o código de seis dígitos a qualquer pessoa, em qualquer provedor.

> ⚠️ **Atenção:** Nunca faça commit de senhas de aplicativo, tokens de acesso ou credenciais. A senha de aplicativo do Gmail para o ambiente de desenvolvimento fica guardada localmente em `~/.config/frila/smtp-gmail` com permissão restrita (`chmod 600`), fora de qualquer repositório.

---

## 1. Ordem obrigatória de configuração

> 🔴 **Regra do plano gratuito (Supabase):** No plano gratuito, o Supabase **recusa** alterar modelos de e-mail enquanto o projeto estiver usando o provedor embutido (*"Email template modification is not available for free tier projects using the default email provider"*).
>
> **A ordem é estrita: SMTP primeiro, modelo de e-mail depois.**

---

## 2. Passo a passo no painel do Supabase

### 2.1. Onde clicar para configurar o SMTP

1. Acesse o Supabase Dashboard no navegador: `https://supabase.com/dashboard/project/<PROJECT_REF>`.
   - Para o `frila-dev`, selecione o projeto correspondente (`jcobftbhbqdikratzizz`).
2. Na barra lateral esquerda, clique em **Authentication** (ícone de escudo/cadeado).
3. No submenu de navegação, clique em **SMTP Settings** (em algumas versões da interface, fica em **Configuration** > **SMTP Settings** ou dentro de **Providers** > **Email** > seção **SMTP Provider**).
4. Localize a opção **Enable Custom SMTP** e ative o botão/chave (*toggle* para a posição ativado/verde).

### 2.2. Campos do formulário e nomes exatos

Preencha os campos com os valores abaixo:

| Campo no Supabase | Valor a preencher | Observações |
|---|---|---|
| **Sender email** | `frilaverificacao@gmail.com` | Endereço da conta de envio (ou `@frila.app` quando houver domínio próprio) |
| **Sender name** | `Frila` | Nome de exibição que aparece para o usuário na caixa de entrada |
| **Host** | `smtp.gmail.com` | Servidor SMTP |
| **Port number** | `465` (ou `587`) | `465` com SSL/TLS implícito; se usar STARTTLS, selecione `587` |
| **Minimum interval between emails** | `60` | Intervalo mínimo em segundos entre envios para o mesmo endereço |
| **Username** | `frilaverificacao@gmail.com` | Usuário de autenticação SMTP |
| **Password** | *(senha de app)* | Senha de 16 caracteres gerada na Conta Google (armazenada em `~/.config/frila/smtp-gmail`) |

5. Clique em **Save changes** no rodapé do formulário.

---

## 3. Configuração do modelo de e-mail (Template OTP)

Somente **após** salvar o Custom SMTP com sucesso:

### 3.1. Onde clicar para configurar o modelo

1. No menu lateral esquerdo, em **Authentication**, clique em **Email Templates**.
2. Selecione a aba/cartão **Confirm signup** (ou **Magic Link**, utilizado para login sem senha/OTP).

### 3.2. Campos do modelo

1. **Subject** (Assunto):
   ```
   Seu código de entrada no Frila: {{ .Token }}
   ```
   *(ou `Seu código de entrada no Frila`)*

2. **Body** (Corpo do e-mail):
   - Copie o conteúdo exato do arquivo versionado [`supabase/templates/codigo-de-entrada.html`](../templates/codigo-de-entrada.html).
   - O corpo utiliza exclusivamente a tag `{{ .Token }}` para exibir o código de 6 dígitos.
   - **Nunca inclua** `{{ .ConfirmationURL }}` ou tags de link: o Frila opera exclusivamente com código digitado no app, evitando que links mágicos abram navegadores externos e quebrem o fluxo.

3. Clique em **Save changes**.

### 3.3. Validade e tamanho do OTP

1. No menu **Authentication**, acesse **URL Configuration** ou **Auth Settings** (ou via Management API).
2. Verifique os parâmetros:
   - **OTP expiry duration**: `900` segundos (15 minutos).
   - **OTP length**: `6` dígitos.

---

## 4. Roteiro de homologação de entregabilidade (Cartão XtZTlTIA)

Critérios de aceite do cartão:
- O código chega em **até 1 minuto** em Gmail, iCloud e Outlook de pessoas de fora do time.
- O e-mail cai diretamente na **caixa de entrada principal** (nunca em spam ou lixo eletrônico).
- Remetente legível ("Frila") e cabeçalhos com SPF e DKIM alinhados.

### 4.1. Como disparar o código de teste

Pelo terminal ou via HTTP (substitua `<PROJECT_REF>`, `<ANON_KEY>` e o endereço de destino):

```bash
curl -i -X POST 'https://<PROJECT_REF>.supabase.co/auth/v1/otp' \
  -H "apikey: <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"email":"teste-externo@gmail.com"}'
```

Ou diretamente pelo fluxo de entrada do aplicativo iOS.

### 4.2. Matriz de testes obrigatória

Realize o disparo para pelo menos 3 contas reais de provedores distintos:

1. **Gmail** (`...@gmail.com`)
2. **Apple iCloud** (`...@icloud.com` ou `...@me.com`)
3. **Microsoft Outlook / Hotmail** (`...@outlook.com` ou `...@hotmail.com`)

### 4.3. Checklist de validação por recebimento

Para cada um dos 3 provedores, cronometre e inspecione:

1. **Tempo de entrega:** O e-mail chegou em menos de 60 segundos?
2. **Localização:** Chegou na caixa de entrada principal? (Reprovado se cair em Spam/Lixo Eletrônico).
3. **Visualização:** O código de 6 dígitos aparece nítido e com fonte legível.
4. **Remetente:** Exibe "Frila" `<frilaverificacao@gmail.com>`.
5. **Inspeção de cabeçalhos (SPF / DKIM / DMARC):**
   - No Gmail: abra a mensagem > menu de três pontos > **Mostrar original**.
   - No Outlook: abra a mensagem > menu de três pontos > **Exibir detalhes da mensagem** ou **Exibir fonte da mensagem**.
   - No Apple Mail (macOS): menu **Visualizar** > **Mensagem** > **Todas as cabeçalheiras**.
   - Confira o relatório de autenticação:
     - `SPF: PASS` com IP de envio do Google.
     - `DKIM: PASS` assinado pelo Google (`d=gmail.com` ou domínio correspondente).
     - `DMARC: PASS`.

---

## 5. O que fica para o Cauê executar

1. **Painel do Supabase:**
   - Acessar o Dashboard do projeto e colar a senha de aplicativo em **SMTP Settings** (Password).
   - Salvar as configurações de SMTP.
   - Aplicar o HTML de `supabase/templates/codigo-de-entrada.html` no template de e-mail.
2. **Disparo e validação:**
   - Solicitar disparo para endereços de fora do time (Gmail, iCloud, Outlook) e atestar a entrega na caixa de entrada em até 1 minuto.
