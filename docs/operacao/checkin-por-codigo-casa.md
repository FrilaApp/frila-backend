# Roteiro Operacional: Ligar e Desligar o Check-in por Código numa Casa (RN46)

- **Objetivo**: Padronizar e automatizar a ativação, desativação e auditoria da chave `checkin_por_codigo` por estabelecimento piloto, eliminando comandos SQL manuais em Produção.
- **Ferramenta**: `scripts/checkin-por-codigo-casa.sh`
- **Tabelas envolvidas**: `privado.recurso`, `privado.recurso_versao_minima`, `privado.recurso_estabelecimento`.

---

## 1. Pré-Requisitos Mandatórios

Antes de ligar o check-in por código para qualquer casa em Produção, os seguintes itens devem estar 100% cumpridos:

1. **Backend no Prod**: Tag `backend-v1.2.0` (ou posterior) aplicada no ambiente `frila-prod`, contendo a pilha de migrações do check-in por código até a Etapa 1 (`20261111210000_checkin_semiautomatico_etapa1.sql`).
2. **App iOS Publicado**: Build 1.2.0 aprovado no App Store Review e instalado nos aparelhos dos gerentes da casa e dos profissionais escalados.
3. **Política de Privacidade e ROPA Publicados**: PRs `frila-docs#212` e `frila-frontend#735` aprovados e mesclados pelos sócios, conforme exigência de conformidade LGPD.
4. **Alinhamento com a Casa**: Casa piloto informada, com gerente ciente de que deve exibir o código de 6 dígitos na chegada dos profissionais.
5. **Janela de Operação**: Ligar preferencialmente **FORA de turnos em andamento** (intervalo entre o fim do turno anterior e o início do próximo).

---

## 2. Passo a Passo de Execução

### Passo 1: Verificar o estado atual da casa (somente leitura)
Obtenha o UUID do estabelecimento em `public.estabelecimento`:
```bash
DATABASE_URL="postgres://..." ./scripts/checkin-por-codigo-casa.sh estado <estabelecimento_id>
```
*Saída esperada:*
```text
Estabelecimento: Nome da Casa (<estabelecimento_id>)
Alvo: db.frila.app:5432/postgres (DATABASE_URL)
  Estado consolidado: INATIVO (fluxo legado em vigor para esta casa)
    • Chave global (privado.recurso):                  desligada (false)
    • Versão mínima iOS (privado.recurso_versao_minima): ausente
    • Casa no piloto (privado.recurso_estabelecimento):  não cadastrada (false)
```

### Passo 2: Simular a ativação (modo seco)
Confira o plano de execução sem alterar o banco de dados:
```bash
DATABASE_URL="postgres://..." ./scripts/checkin-por-codigo-casa.sh ligar <estabelecimento_id> --seco
```

### Passo 3: Ativar o check-in por código
Execute a ativação. O script solicitará confirmação interativa:
```bash
DATABASE_URL="postgres://..." ./scripts/checkin-por-codigo-casa.sh ligar <estabelecimento_id>
```
*Para automações ou testes CI, passe `--sim` para dispensar a confirmação.*

O script realiza atômica e idempotentemente:
1. `privado.recurso`: define `checkin_por_codigo = true`.
2. `privado.recurso_versao_minima`: registra versão mínima `1.2.0` para iOS.
3. `privado.recurso_estabelecimento`: insere o UUID da casa.

---

## 3. Como Conferir que Deu Certo

### A. Conferência no Banco de Dados
Execute o comando de leitura:
```bash
DATABASE_URL="postgres://..." ./scripts/checkin-por-codigo-casa.sh estado <estabelecimento_id>
```
*Saída esperada:*
```text
  Estado consolidado: ATIVO (check-in por código em vigor para esta casa)
    • Chave global (privado.recurso):                  ligada (true)
    • Versão mínima iOS (privado.recurso_versao_minima): 1.2.0
    • Casa no piloto (privado.recurso_estabelecimento):  cadastrada (true)
```

### B. Conferência Operacional no App
1. **No App do Gerente (Contratante)**:
   - Abra a tela do turno do dia.
   - O painel exibe: *"Aguardando o profissional chegar no local"*.
2. **No App do Profissional**:
   - Ao tocar em "Fazer check-in" a $\le 50\text{ m}$ da casa, o check-in registra como `manual`/`pendente` com `codigo_disponivel = true`.
   - O app profissional abre a tela com os 6 dígitos para inserção.
3. **Validação do Código**:
   - A casa clica em gerar código e informa os 6 dígitos ao profissional.
   - O profissional digita o código a $\le 50\text{ m}$.
   - O turno avança para `verificado` (tipo: `codigo`).

---

## 4. Comportamento com Turnos em Andamento

| Momento da Mudança | O que acontece com o turno | Ação recomendada |
|---|---|---|
| **Antes do check-in** (`checkin_em is null`) | Ao chegar, o profissional já cai no novo fluxo: presença fica `pendente` e exige código de 6 dígitos. | Sem impacto adverso. |
| **Check-in já feito e pendente** (sem código gerado) | Se a chave ligar: a casa poderá gerar código normalmente após o próximo toque de aproximação do profissional. Se desligar: a geração é bloqueada (403); casa confirma via botão manual. | Seguir com confirmação manual se necessário. |
| **Código já gerado na tela da casa** (pendente de validação) | **Se a chave for DESLIGADA neste instante**: `validar_codigo_checkin` falha com `403 recurso_desligado`. O código gerado é invalidado na hora. | **Evitar desligar com código na tela.** Se ocorrer, a casa deve usar a confirmação manual (`confirmar_checkin_manual`). |
| **Turno já verificado** (`verificacao = 'verificado'`) | Registro é imutável. Ligar ou desligar a chave não altera em nada o comparecimento já consolidado. | Sem impacto. |

> **Regra de Operação:** Sempre ligar ou desligar a chave **FORA de turnos em andamento**, preferencialmente no início da manhã ou antes da abertura das vagas do dia.

---

## 5. Como Desfazer (Rollback / Desativação Imediata)

Se houver qualquer instabilidade no piloto ou necessidade de retorno ao fluxo legado:

```bash
DATABASE_URL="postgres://..." ./scripts/checkin-por-codigo-casa.sh desligar <estabelecimento_id>
```

**Efeitos imediatos da desativação:**
1. A casa é removida de `privado.recurso_estabelecimento`.
2. A função `privado.recurso_ligado_para('checkin_por_codigo', id)` passa a responder `false` imediatamente.
3. Novos check-ins na casa voltam ao fluxo legado: toques a $\le 200\text{ m}$ verificam automaticamente por GPS na hora (`geolocalizado`, `verificado`).
4. Turnos pendentes anteriores podem ser concluídos normalmente pela casa via `confirmar_checkin_manual`.
