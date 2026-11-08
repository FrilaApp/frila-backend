# Página de cópia do código

Sirva `index.html` em `https://frilabr.com/codigo` por HTTPS antes de
ativar o botão do modelo de e-mail. A publicação e a configuração da rota
são feitas pelo responsável pelo site; este diretório entrega o arquivo estático.

O código continua visível e selecionável no e-mail. A página é uma conveniência:
lê apenas o fragmento `#123456`, que o navegador não envia na requisição HTTP.
Aceita somente seis dígitos ASCII, sem dependências, analytics ou chamadas de rede.
Usa Clipboard API e tenta `execCommand('copy')` se ela estiver indisponível ou negar
permissão; se ambos falharem, orienta a cópia manual.

Prova: `deno test supabase/templates/templates_test.ts`.
Os previews em `../previews/` usam somente o código sintético `123456`.
