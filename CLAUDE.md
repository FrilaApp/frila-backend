# frila-backend — como se trabalha aqui

Backend do **Frila**: plataforma de contratação por turno avulso, começando pelo
Distrito Federal. O ciclo que este repositório existe para fechar é
`publicar → notificar → candidatar → confirmar → executar → avaliar`.

Trabalhamos em **português-BR**, inclusive commits, nomes de função e colunas.

---

## Quatro Claudes no mesmo quadro

Este projeto é tocado por quatro pessoas com Claude Code ao lado, ao mesmo tempo:

| Pessoa | GitHub | Trello | Frente principal |
|---|---|---|---|
| Matheus Silva | `silvaaszx` | `matheussilva95408964` | Backend e iOS |
| Cauê Carneiro | `cauecarneiro` | `cauecarneiroc` | Backend e infra |
| João Paulo (Jotapê) | `jotape12-Dev` | `joaopauloalbuquerque7` | iOS e backend |
| Fabrício Tosta | `fbtostadev` | `fabriciotosta3` | Design |

Júlia Clovandi (`JuhClovandi` / `juliavasconcelos82`) é a PO: produto, pesquisa e
jurídico. Não codifica, mas decide o que trava o código.

**Consequência prática:** nenhum de nós enxerga o que o outro está fazendo agora. O
único lugar que sabe é o **quadro do Trello**. Por isso a primeira coisa que qualquer
Claude faz numa sessão é ler o quadro, e a última é devolver o cartão ao quadro. Código
escrito sem cartão em "Em andamento" é código que dois de nós escrevemos duas vezes.

---

## A fonte da verdade

Nada aqui é inventado. Cada decisão tem um documento por trás, e quando o código
discordar do documento, **o documento ganha** — ou o documento muda primeiro.

| O quê | Onde |
|---|---|
| **Contrato da API** | `contrato/openapi.yaml` — espelho de `BlendOps/Frila · Documentos/API/openapi.yaml`. Nome de campo, código de erro e status HTTP saem daqui |
| **Modelagem de Banco** | vault `BlendOps/Bancada · doc-harness/07 - Arquitetura/Modelagem de Banco de Dados.md` — o DDL, as 19 políticas de RLS, a definição canônica da taxa de comparecimento |
| **Decisões técnicas** | mesmo vault, `Pendências Técnicas Para Codar.md` — D1 a D13 |
| **Escopo e sprints** | `BlendOps/Frila · Documentos/MD/05-ESCOPO-DO-MVP.md` |
| **Requisitos (RN, RF, RNF, UC)** | `BlendOps/Frila · Documentos/Diagramas:Documentos/Frila_Documento_de_Requisitos.docx` |
| **O quadro** | https://trello.com/b/0eyqvbRJ/frila — 221 cartões, 60 com etiqueta Backend |

> O cartão `S0 · Infra · Criar o projeto no Supabase` diz que o código mora em
> `Frila/supabase/`. **Mudou:** o backend vive neste repositório. O contrato continua
> nascendo no repositório do Frila e é espelhado aqui; divergência entre os dois quebra
> a CI.

---

## O pipeline

Um cartão por vez, do quadro ao merge, sem pular etapa.

```
1. Ler o quadro          frila-task-auditor varre; escolhe o próximo cartão
                         Backend cuja dependência já está Concluída
2. Reivindicar           atribui você mesmo ao cartão · move para "Em andamento"
3. Codar                 frila-coder: branch, pgTAP vermelho, implementa, verde
4. Abrir PR              cita o cartão pelo link curto · move para "Revisão"
5. Revisar               frila-reviewer: checklist do cartão + contrato + RLS + CI
6. Mergear               aprovado → merge → marca a checklist → move para "Concluído"
7. Registrar             no fim do dia, scripts/bancada-sync.sh leva o dia ao vault
```

**Regras que valem para todo mundo:**

- No máximo **dois cartões em andamento** por pessoa. É regra do quadro, não estilo.
- Mover para "Em andamento" **antes** de escrever a primeira linha. O quadro é o
  único sinal que os outros três têm.
- Um cartão = um branch = um PR. Nome do branch: `s1/candidatar` (sprint + assunto).
- O PR não fecha o cartão. Quem fecha é a checklist marcada por quem **revisou**.
- Se o cartão estava errado, não conserte no código em silêncio: conserte o cartão,
  comente o porquê, e siga.

### Cortesia entre os quatro

Antes de assumir um cartão cujo **Responsável sugerido** é outra pessoa, comente no
cartão dizendo que vai pegar. O campo é sugestão, não reserva — mas silêncio nele custa
retrabalho.

---

## Os agentes

Vivem em `agents/`, versionados, e são copiados para `.claude/agents/`. Rodam igual
nas quatro máquinas.

| Agente | Use quando |
|---|---|
| `frila-task-auditor` | Início de sessão, e antes de criar cartão novo. Varre o quadro: duplicata, cartão sem checklist, dependência quebrada, cartão que o código já cumpriu |
| `frila-task-creator` | Surgiu trabalho que o quadro não cobre. Cria o cartão no formato do quadro, sem repetir os 221 que já existem |
| `frila-investigator` | Antes de afirmar qualquer coisa sobre o banco ou a API. **Mede** — `psql`, `supabase test db`, `curl` — em vez de deduzir de nome de coluna |
| `frila-coder` | Implementar um cartão. TDD com pgTAP: o teste falha primeiro |
| `frila-reviewer` | Revisar um PR contra a checklist do cartão, o contrato e as políticas de RLS |

---

## Regras do código

Nove regras de negócio moram **no banco**, não na aplicação. Três clientes nativos
(iOS, Android, web) chamam o mesmo backend; o banco é o único lugar onde a regra vale
uma vez só.

| Regra | Onde vive |
|---|---|
| RN19 — uma posição nunca confirmada para dois profissionais | `UPDATE` condicional dentro da RPC + `CHECK` de coerência |
| RN21 — nenhum profissional com dois turnos sobrepostos | `EXCLUDE USING gist` em `posicao` |
| RN18 — dinheiro em centavos inteiros, tempo em UTC | `bigint` e `timestamptz` |
| RN20 — só maiores de 18 | `CHECK` sobre `nascimento` |
| RN25 — uma conta, um perfil, para sempre | trigger + chave estrangeira composta `(id, perfil)` |
| RN02 — vaga incompleta não existe | `NOT NULL` nas colunas obrigatórias |
| RN24 — modo seleção só com mais de 24 h | `CHECK` em `vaga` |
| RN22 — geolocalizado vale até 200 m; manual só conta confirmado | `CHECK verificacao_coerente` |
| RN07 — avaliação binária, após o fim, com presença verificada | `UNIQUE (turno_id, autor_id)` + trigger |

### Como se escreve uma RPC

Toda função de escrita segue o mesmo molde, sem exceção:

```sql
create or replace function public.nome_da_funcao(...)
returns ... language plpgsql
security definer set search_path = ''   -- sempre nome qualificado
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then perform public.erro(401, 'nao_autenticado'); end if;
  perform privado.exigir_perfil('profissional');   -- quando a ação é de um perfil só
  ...
end $$;
```

- **Erro sempre pelo auxiliar `public.erro(status, codigo, motivo)`.** O `code` é
  estável em `snake_case` e o cliente compara sem traduzir. A lista está no contrato.
- **Nenhuma tabela tem política de escrita.** Os apps não fazem `insert`; chamam a RPC.
- **Idempotência**: onde há chave natural (candidatura por vaga e profissional,
  check-in por turno, avaliação por turno e autor, bloqueio por par), ela basta.
  `publicar_vaga` e `denunciar` recebem `chave` gerada pelo app.
- **Mudança incompatível vira função nova** (`publicar_vaga_v2`). A antiga fica no ar
  enquanto houver app antigo na loja.

### Migrações

- Arquivo datado em `supabase/migrations/`, **imutável depois de aplicado**. Correção
  entra como migração nova.
- Nunca altere o esquema pelo painel do Supabase: o que não está em arquivo, o próximo
  ambiente não tem.
- Mudança destrutiva em duas fases: adiciona e escreve nos dois, depois remove. RNF12
  proíbe manutenção de quinta a domingo, das 16h às 2h.
- `seed.sql` tem só o catálogo de funções. Dado de teste vive em `supabase/tests/`.

### Testes

- **pgTAP** (`supabase test db`) para regra, constraint e política. Um teste por
  `CHECK`, com o nome da regra.
- **pgbench** para corrida. pgTAP roda numa sessão só e não testa concorrência — RN19
  precisa de 20 conexões simultâneas.
- **Teste de contrato** na CI: resposta de cada RPC casa com o schema do
  `contrato/openapi.yaml`.
- Nenhum PR entra com teste vermelho. Se o teste é difícil de escrever, o desenho está
  errado.

---

## O que este backend não faz

Ausência por decisão, não por lacuna. Não crie tabela para nada disto:

| Ausente | Por quê |
|---|---|
| `pagamento`, `carteira`, `repasse` | RN09: o Frila registra o valor, não custodia dinheiro |
| `mensagem`, `conversa` | RN10 libera WhatsApp após a confirmação. Chat é superfície sem problema resolvido |
| `nota`, `comentario` | RN07 proíbe média de 1 a 5 e comentário aberto |
| `comissao`, `desconto` | RN01: o valor anunciado é o valor integral do profissional |
| coluna de patrocínio, prioridade ou impulsionamento | RN06: notificação e ordem da lista não podem ser compradas. O jeito de garantir é não haver onde guardar |
| tabela de posições sucessivas do profissional | Rastreamento contínuo está no escopo não contemplado. O check-in guarda a **distância** medida no toque, nunca a coordenada |

---

## LGPD, que aqui é estrutura

- **Exclusão é anonimização** (RF25). Turno e avaliação sobrevivem porque pertencem
  também à contraparte.
- **Dado pessoal não entra em log** (RN15). Isso proíbe o trigger de auditoria que copia
  a linha inteira de `usuario`. `ocorrencia` guarda referência e motivo, nunca cópia.
- **O contato tem prazo.** Telefone e WhatsApp saem só pela RPC `contato_do_turno`, que
  confere confirmação, os 7 dias e o bloqueio.
- Cada tabela e coluna sensível leva `comment on` dizendo a finalidade.

---

## A ponte com a Bancada

O vault `BlendOps/Bancada · doc-harness/` publica em **https://bancada-buu.pages.dev**,
e é onde os mentores acompanham o processo. Os commits daqui **não** chegam lá sozinhos:
o hook do vault só registra commits do próprio repositório.

No fim de cada dia de trabalho, `scripts/bancada-sync.sh`:

```bash
./scripts/bancada-sync.sh                     # os commits de hoje
./scripts/bancada-sync.sh 2026-09-22          # os de outro dia
./scripts/bancada-sync.sh --seco              # mostra o que faria
./scripts/bancada-sync.sh --fato <tipo> <descrição…>
```

1. Leva os commits do dia para `05 - Registros/`, pela forma `externo` do
   `registrar-fato.sh` — a única porta de escrita do log, protegida por hook —, com a
   data, a hora e o autor **do commit**. Um dia de trabalho recuperado depois não pode
   aterrissar no dia em que a ponte rodou.
2. `--fato` leva o que foi medido e não é commit: um PR aberto, um portão que reprovou,
   um número que vai importar depois. Esse carimba o agora, que é quando de fato
   aconteceu.
3. Cria a nota diária em `02 - Atualizações Diárias/` a partir do modelo, com as seções
   fixas, e lista os fatos do dia na saída.

**Ela não escreve a narrativa.** A regra de ouro do vault é que fato e narrativa são
camadas separadas, e que nenhum bullet pode existir sem um fato por trás. Um script que
virasse assunto de commit em prosa estaria inventando a camada de cima a partir da de
baixo — que é exatamente o que a regra proíbe. A narrativa é escrita por quem trabalhou,
a partir da lista que a ponte imprime.

O vault fica em `../doc-harness`; `BANCADA_DIR` no `.env` sobrepõe. Se os hooks de lá
não estiverem instalados, nada é registrado e ninguém avisa — aconteceu entre 10/09 e
23/09. O conserto é `./scripts/bootstrap.sh`, dentro do vault.

O `push` do vault exige Touch ID. É deliberado: nada sai de lá sem alguém presente.
Nunca use `SKIP_BIOMETRICS=1`.

---

## Antes de dizer que está pronto

Rode, olhe a saída, e só então afirme:

```bash
supabase db reset          # migrações aplicam do zero
supabase test db           # pgTAP verde
./scripts/ciclo-completo.sh  # criar_conta → publicar → candidatar → check-in → avaliar
```

Ler o código não é medir. Se você não rodou, diga que não rodou.
