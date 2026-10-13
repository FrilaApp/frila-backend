# Cartão J5: Recusar telefone, e-mail e link no texto livre da vaga

Este arquivo contém o texto pronto e estruturado do cartão da decisão **J5** (decorrente da revisão da lista de termos bloqueados, cartão `ggEzge6h`, plano **P8**), pronto para abertura no quadro do Trello pela coordenação ou equipe.

---

## Dados do Cartão para o Trello

- **Título:** Recusar telefone, e-mail e link no texto livre da vaga
- **Lista sugerida:** Backlog / V1.1 (ou Sprint em planejamento)
- **Etiquetas:** Backend, Regra de Negócio, RN10
- **Referência:** Decisão J5 de `requisitos/revisao-lista-termos-bloqueados.md` (PR #87 do `frila-docs`)

---

## Descrição do Cartão

### Por quê
A regra de negócio **RN10** estabelece que dados de contato entre contratante e profissional só devem ser liberados após a confirmação da vaga/turno (acessíveis exclusivamente pela RPC `contato_do_turno`).

A inserção de números de telefone, endereços de e-mail ou links externos diretamente no texto livre da vaga burla essa regra de proteção e privacidade. Não se trata de uma lista estática de palavras ofensivas, mas sim de validação de padrões sintáticos (dígitos de telefone, endereços com `@` e links web).

---

### Escopo Técnico

Conferir os campos de texto livre da vaga (`local`, `responsavel_local`, `traje` e `observacoes` em `publicar_vaga` e `republicar_vaga`, além do nome do estabelecimento se aplicável) contra padrões que indiquem:

1. **Telefone / WhatsApp:** sequências de 8 ou mais dígitos (mesmo com espaços, pontos, barras e hífens intermediários).
2. **E-mail:** padrões contendo `@` seguido de domínio.
3. **Links / URLs:** ocorrências de `http://`, `https://`, `www.` e domínios comuns de topo.

Caso identificado algum padrão, a operação deve recusar a requisição com o código padrão de contrato:
- Status HTTP: `422 Unprocessable Entity`
- Código de erro: `campo_invalido`
- Detalhes: nome do campo específico em `details` (ex: `{"code": "campo_invalido", "message": "...", "details": "observacoes"}`).

---

### Cuidados e Falsos Positivos Conhecidos

A validação de dígitos e pontuações pode colidir com textos perfeitamente legítimos de vagas. **É obrigatório escrever e aprovar a suíte de casos de teste de falsos positivos antes da implementação no banco de dados**, garantindo que passem sem recusa:

- **Valores monetários:** `"R$ 1.200,00"`, `"150 reais"`, `"diária de R$ 80,00"`.
- **CEP:** `"CEP 70000-000"`.
- **Endereços com numeração:** `"Quadra 102 Bloco B Lote 4"`, `"Rua 3, nº 145, sala 204"`.
- **Horários e períodos:** `"das 14:00 às 22:00"`, `"turno de 8 horas"`.
- **Datas:** `"15/10/2026"`, `"dia 20 de outubro"`.

---

### Critérios de Aceite e Privacidade (LGPD / RN15)

1. A recusa **não deve gravar o texto digitado em log nem em tabela de ocorrência** (em estrito cumprimento da regra **RN15** de proteção de dados pessoais).
2. A suíte de testes (pgTAP) deve cobrir casos positivos (rejeição com `422 campo_invalido`) e todos os casos de falso positivo legítimos listados acima.
3. Decisão a levar ao João Paulo / time de produto antes do fechamento: avaliar se o padrão de validação de contato também deve barrar o termo `"WhatsApp"` / `"Zap"` escrito por extenso no texto da vaga.
