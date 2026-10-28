# Regra da Bancada: todo trabalho chega lá no mesmo dia

> Para humanos **e para as IAs de cada integrante** (Claude, Gemini, Copilot, qualquer agente que
> faça commit, abra ou mergeie PR neste repositório). Leia antes de encerrar uma tarefa.

## O que é e por que importa

A **Bancada** (`FrilaApp/Bancada`, vault em `doc-harness/`) é o diário de bordo do projeto. Ela publica o
site **https://bancada-buu.pages.dev**, que é **a única coisa que os mentores leem**. Eles não têm
acesso ao GitHub. O que não está na Bancada, para eles, não aconteceu.

Os commits deste repositório **não chegam lá sozinhos**: o hook do vault só vê commits do próprio vault.
Se ninguém levar, a Bancada para no tempo. Já aconteceu: o site ficou sem publicar de 21/10 a 28/10.

## A regra

1. **Todo PR mergeado, e todo PR aberto que valha registro, vira fato na Bancada no mesmo dia.**
   Não deixe para "o fim da semana" nem para outra pessoa. Quem mergeou registra.
2. **IA que mergeia ou conclui uma tarefa registra antes de dizer "pronto".** Registrar faz parte de
   terminar.
3. **Fato primeiro, narrativa depois.** Fato entra em `05 - Registros/` só pelo `registrar-fato.sh`.
   A nota do dia (`02 - Atualizações Diárias/`) só tem bullet que tenha fato correspondente.

## Como registrar

Clone o `FrilaApp/Bancada` ao lado deste repositório e crie uma branch a partir de `origin/main`.

```bash
cd Bancada/doc-harness
# fato de outro repositório, com a data, a hora e o autor de lá (horário local)
scripts/registrar-fato.sh externo AAAA-MM-DD HH:MM <autor-github> merge \
  "[<repo>#<n>](https://github.com/FrilaApp/<repo>/pull/<n>) — <título do PR>"
scripts/registrar-fato.sh externo AAAA-MM-DD HH:MM <autor-github> pr \
  "[<repo>#<n>](https://github.com/FrilaApp/<repo>/pull/<n>) — <título> (aberto)"
```

Tipos em uso: `merge` e `pr`. No backend, `./scripts/bancada-sync.sh` faz isso para os commits do dia.

Depois, abra um **PR na Bancada** com o fato e, se quiser, os bullets na nota do dia. Espere o check
**Site / publicar** ficar verde antes de mergear.

## O que nunca fazer

- **Nunca edite `05 - Registros/` à mão.** Só o `registrar-fato.sh`.
- **Nunca mergeie na Bancada com o Site vermelho.** Se o Site quebrar, avise o grupo e corrija a causa.
  A proteção da `main` deles **não é imposta pelo GitHub** (plano gratuito): a regra vale por acordo.
- **Nunca ponha frontmatter nas notas listadas em `doc-harness/.bancada-nao-publicar` para "passar o
  portão".** Foi assim que as notas jurídicas foram publicadas por engano em 28/10. Essa lista só muda
  com autorização do dono.
- **Nunca cite conteúdo jurídico, segredos, tokens ou detalhes de repositório privado** em texto da Bancada.
- Nota nova precisa de frontmatter e de um `tipo` válido (ver `doc-harness/CLAUDE.md`).

## Se não conseguir registrar

Diga isso ao humano na resposta final ("não registrei na Bancada porque …"). **Não pule em silêncio.**
