# Subir a versão mínima do app

Quando um build publicado tem defeito grave e precisa sair de circulação. Abaixo da
`versao_minima`, o app troca todas as telas pela tela de atualização e leva à loja.
Sem rede, ele abre normalmente: o bloqueio vale na próxima abertura com rede.

A configuração mora em `privado.configuracao_app`, uma linha por plataforma, e é lida
sem sessão por `GET /rest/v1/rpc/configuracao_do_app?plataforma=ios`.

## Antes

1. **A versão nova já está na loja e aprovada.** Subir a mínima antes disso bloqueia
   todo mundo sem ter para onde mandar.
2. **A versão é a de build** (`MARKETING_VERSION` do `iOS/project.yml` no
   `frila-frontend`), só números e pontos: `1.2.10`, nunca `v1.2.10`. O banco recusa o
   formato errado, e recusa `versao_recomendada` abaixo de `versao_minima`.
3. **Fora da janela de pico** (RNF12): nada de quinta a domingo, das 16h às 2h, salvo o
   próprio defeito grave que motivou a subida.

## A mudança é uma migração

Nunca pelo painel do Supabase: o que não está em arquivo, o próximo ambiente não tem, e
ninguém sabe depois quem bloqueou qual versão e por quê.

```bash
git checkout -b s<N>/versao-minima-<versao>
supabase migration new versao_minima_ios_<versao_com_underscore>
```

```sql
-- Tira de circulação o build <antigo>: <o defeito, em uma linha, com o link do cartão>.
update privado.configuracao_app
   set versao_minima      = '1.2.10',
       versao_recomendada = '1.2.10',
       mensagem           = null,      -- null usa o texto padrão do app
       atualizado_em      = now()
 where plataforma = 'ios';
```

`mensagem` só quando o texto padrão não basta. Ela vai para a tela como está: frase
curta, sem jargão, sem culpar quem usa.

`versao_recomendada` sozinha, sem mexer na mínima, é o aviso dispensável: aparece uma
vez por versão e não bloqueia ninguém.

## Conferir no local

```bash
supabase db reset && supabase test db
curl -s "http://127.0.0.1:54321/rest/v1/rpc/configuracao_do_app?plataforma=ios" \
  -H "apikey: $ANON_KEY"
```

## Aplicar

Pelo PR, como qualquer migração, e depois no remoto:

```bash
./scripts/aplicar-remoto.sh <project_ref> --seco   # mostra o que vai aplicar
./scripts/aplicar-remoto.sh <project_ref>
```

E conferir no remoto com a chave publicável do ambiente, sem token de usuário. A
resposta tem de trazer a versão nova.

## Voltar atrás

Outra migração, com a versão anterior. A que subiu não se edita: já foi aplicada.

## Android e web

Ainda não têm linha: a função responde `404 nao_encontrado` para eles. A linha entra por
migração quando o app tiver loja — `insert`, com a URL de verdade.
