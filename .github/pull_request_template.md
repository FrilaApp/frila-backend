<!--
Quatro pessoas com Claude Code trabalham neste quadro ao mesmo tempo, e nenhuma
enxerga o que a outra está fazendo agora. Este PR é metade do sinal; a outra metade é
o cartão no Trello. PR sem cartão é trabalho que alguém pode estar refazendo.
-->

## Cartão

<!-- Link curto do Trello. Se não há cartão, diga por quê antes de continuar. -->

https://trello.com/c/

## O que muda, e por quê

<!--
O porquê primeiro, em uma ou duas frases. O "o quê" está no diff; o "porquê" some.
Se o cartão estava errado, diga aqui o que você corrigiu no cartão e por quê — não
conserte no código em silêncio.
-->

## A superfície da API mudou?

- [ ] **Não.** Nenhuma função do schema `public` foi criada, removida ou teve a
      assinatura alterada.
- [ ] **Sim**, e o contrato foi junto: `contrato/openapi.yaml` atualizado a partir de
      `FrilaApp/frila-docs`, `info.version` subiu e a soma foi regravada.

> O contrato é a fonte dos modelos do iOS, do Android e da web. Uma RPC que muda aqui e
> não muda lá deixa o cliente gerando o modelo antigo até a chamada falhar no aparelho
> de alguém. O job `O contrato acompanhou o código` reprova o PR que esquecer — mas o
> lugar de decidir é aqui, não na CI.
>
> Mudança **incompatível** não sobe versão: vira função nova (`publicar_vaga_v2`), e a
> antiga fica no ar enquanto houver app antigo na loja. A regra inteira está em
> `Documentos/API/README.md`, no repositório do Frila.

## Portões

Rode, olhe a saída, e só então marque. Ler o código não é medir.

- [ ] `supabase db reset` — as migrações aplicam do zero
- [ ] `supabase test db` — pgTAP verde, e **o número de asserções subiu** se a regra é nova
- [ ] `./scripts/mutacao.sh` — todas as regras cobertas, nenhuma sem cobertura
- [ ] `./scripts/ciclo-completo.sh` — o fluxo por HTTP, com status **e** código de erro
- [ ] `./scripts/lint-conhecido.sh` — sem achado novo
- [ ] `./scripts/advisor-conhecido.sh` — sem alerta além dos declarados

<!--
Se um portão não rodou, escreva que não rodou e por quê. Suíte verde não diz o que ela
protege: duas vezes os testes passaram inteiros sobre uma regra ausente, e quem achou
foi a mutação.
-->

## Migrações

- [ ] Nenhuma migração existente foi editada. Correção entrou como migração nova.
- [ ] Nenhuma mudança foi feita pelo painel do Supabase — o que não está em arquivo, o
      próximo ambiente não tem.

## O que ficou de fora

<!--
O que você viu e não fez, e por quê. Divergência entre o código e a Modelagem, decisão
que depende de outra pessoa, lacuna do modelo. Vale mais do que parece: é o que a
próxima sessão não vai redescobrir do zero.
-->
