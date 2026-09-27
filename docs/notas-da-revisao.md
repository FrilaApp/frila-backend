# Notas da revisão da App Store

Cartão [`7gpPBgTH`](https://trello.com/c/7gpPBgTH), critério 4. Diretrizes 2.1 e 4.2.

O texto abaixo é o que vai no campo **App Review Information → Notes** do App Store
Connect, nas duas versões: a portuguesa para o time, a inglesa para o revisor. Quando o
fluxo mudar, as duas mudam juntas — uma delas envelhecendo em silêncio é pior que não
existir.

**O que não entra neste arquivo:** o código fixo de entrada. Ele vive no segredo
`DEMONSTRACAO_CODIGO` do `frila-dev` e do `frila-prod`, e no campo de senha do App Store
Connect. Um código de revisão num arquivo versionado é um código publicado.

---

## Português

**Contas de demonstração**

O Frila entra por código de seis dígitos enviado ao e-mail, e o revisor não tem acesso a
essas caixas de entrada. As duas contas abaixo entram com um código fixo, informado no
campo de senha ao lado de cada e-mail nesta mesma tela.

| E-mail | Perfil | O que ela é |
|---|---|---|
| `revisao-contratante@frila.app` | Contratante | Administradora do estabelecimento "Bar da Revisão" |
| `revisao-profissional@frila.app` | Profissional | Funções de garçom e bartender |

São duas contas porque cada conta do Frila tem um perfil só, para sempre: quem se cadastra
como profissional não publica vaga, e quem se cadastra como contratante não se candidata.
Testar os dois lados exige as duas.

Na tela de entrada, digite o e-mail, toque em continuar e informe o código fixo no lugar do
código que normalmente chegaria por e-mail. São dez tentativas a cada dez minutos por
endereço.

**O serviço opera apenas no Distrito Federal, no Brasil**

O Frila conecta estabelecimentos e profissionais para turnos avulsos em Brasília e no
entorno. A busca de vagas é por proximidade, e uma conta em qualquer outra região veria uma
lista vazia. As duas contas de demonstração já vêm com um estabelecimento, uma vaga aberta e
um turno confirmado, para que nenhuma tela apareça sem conteúdo.

**O que já está pronto em cada conta**

- Uma vaga aberta de garçom, com valor, refeição e transporte inclusos
- Um turno já confirmado, onde o contato da contraparte está liberado
- A conta de contratante pode publicar uma vaga nova a qualquer momento

**Registro de presença fora do local**

O check-in é geolocalizado quando o aparelho está a até 200 metros do estabelecimento.
Fora desse raio — que é o caso de quem revisa de outro país — o app registra um check-in
**manual**, que fica pendente até a casa confirmar. O caminho completo, com as duas contas:

1. Na conta profissional, abra o turno confirmado e toque em registrar chegada. O registro
   entra como manual e pendente.
2. Saia e entre na conta do contratante, abra o mesmo turno e confirme a presença. O turno
   passa a verificado.
3. De volta na conta profissional, registre a saída.

Isso é comportamento de produto, e não uma exceção criada para a revisão: é o mesmo
caminho de um turno cujo aparelho está sem GPS.

**As contas de demonstração vivem isoladas**

Uma vaga publicada pela conta de demonstração não aparece para nenhum profissional real e
não gera notificação para ninguém. O contrário também vale: as contas de demonstração não
enxergam vagas reais. As duas populações dividem o mesmo banco e não se cruzam.

**O que o aplicativo não faz, por decisão**

- **Não processa pagamento.** O Frila registra o valor acordado do turno; o pagamento
  acontece fora do aplicativo, direto entre as partes. Não há compra, assinatura nem
  carteira.
- **Não tem chat.** Depois da confirmação do turno, o aplicativo libera o telefone da
  contraparte por tempo limitado, e a conversa segue por fora.
- **Não vende posição na lista.** A ordem das vagas e o envio de avisos não podem ser
  comprados.

**Contato**

Qualquer dúvida durante a revisão, o endereço de contato desta submissão responde em até um
dia útil.

---

## English

**Demo accounts**

Frila signs users in with a six-digit code sent by email, and the reviewer has no access to
those inboxes. The two accounts below sign in with a fixed code, provided in the password
field next to each email on this screen.

| Email | Profile | What it is |
|---|---|---|
| `revisao-contratante@frila.app` | Business | Administrator of the venue "Bar da Revisão" |
| `revisao-profissional@frila.app` | Worker | Waiter and bartender roles |

There are two accounts because each Frila account has exactly one profile, permanently:
a worker account cannot post a shift, and a business account cannot apply to one. Testing
both sides requires both accounts.

On the sign-in screen, enter the email, tap continue, and type the fixed code where the
emailed code would normally go. Ten attempts per address every ten minutes.

**The service operates only in the Federal District of Brazil**

Frila connects venues and workers for single shifts in Brasília and its surroundings. Shift
search is proximity-based, and an account anywhere else would see an empty list. Both demo
accounts come preloaded with a venue, an open shift and a confirmed shift, so no screen
appears without content.

**What is already set up in each account**

- An open waiter shift, with pay, meal and transport included
- A shift already confirmed, where the counterpart's contact details are released
- The business account can post a new shift at any time

**Attendance check-in from outside the venue**

Check-in is geolocated when the device is within 200 metres of the venue. Outside that
radius — which is the case when reviewing from another country — the app records a
**manual** check-in, which stays pending until the venue confirms it. The full path, using
both accounts:

1. In the worker account, open the confirmed shift and tap to record arrival. It is
   recorded as manual and pending.
2. Sign out, sign in to the business account, open the same shift and confirm attendance.
   The shift becomes verified.
3. Back in the worker account, record the departure.

This is normal product behaviour, not an exception built for review: it is the same path a
shift takes when the device has no GPS signal.

**The demo accounts are isolated**

A shift posted by a demo account is not visible to any real worker and triggers no
notifications. The reverse also holds: demo accounts do not see real shifts. Both
populations share the same database and never meet.

**What the app deliberately does not do**

- **No payment processing.** Frila records the agreed rate for a shift; payment happens
  outside the app, directly between the parties. There is no purchase, subscription or
  wallet.
- **No chat.** Once a shift is confirmed, the app releases the counterpart's phone number
  for a limited time, and the conversation continues outside the app.
- **No paid placement.** Neither the ordering of shifts nor the sending of alerts can be
  purchased.

**Contact**

For anything that comes up during review, the contact address on this submission replies
within one business day.

---

## O que falta, e não é backend

O cartão pede que o vídeo do ciclo seja gravado com o build 0.4. O vídeo e o preenchimento
do App Store Connect são do lado iOS do cartão; este arquivo é o texto que vai no campo. Os
nomes de botão e de tela citados no passo a passo do check-in são descritivos — quem
preencher o campo no App Store Connect deve trocá-los pelos rótulos reais do build.

## Duas coisas medidas que quem submeter precisa saber

**A data da vaga semeada é relativa ao momento do seed.** O `seed.sql` cria a vaga aberta em
`privado.agora() + 5 days` e o turno confirmado em `+ 2 days`. Medido em 25/09: o
`vagas_abertas` filtra por `estado = 'publicada'` e **não** por data futura, então a vaga
continua na lista depois de vencer e a tela nunca nasce vazia — a diretriz 4.2 está coberta
de qualquer jeito. O que muda é a aparência: se o seed rodar muito antes da submissão, o
revisor vê uma vaga com data no passado. O ideal é rodar o seed no `frila-prod` na semana da
submissão.

**O check-in fora da janela depende da migração `20260925230000_janela_da_demonstracao`.** A
janela do registro de presença abre 60 minutos antes do início do turno, e o turno semeado
envelhece. Sem essa migração aplicada no ambiente, o passo a passo do check-in acima responde
`422 fora_da_janela` e o revisor não alcança o meio do ciclo. Conferir antes de submeter:
`./scripts/demonstracao.sh` mede exatamente esse caminho por HTTP.
