# Roteiro Operacional: Habilitação e Desativação da Chave Global de Check-in por Código (RN22, RN46, Contrato 0.2.78)

- **Princípio Arquitetural e Decisão de Escopo**: Conforme decisão de produto aprovada em 12/11/2026 e formalizada no contrato OpenAPI 0.2.78 (`frila-docs#235`), o check-in por código passa a valer para **todos os estabelecimentos** do Frila de forma unificada.
- **Fim da Lista de Casas**: A tabela `privado.recurso_estabelecimento` deixou de ser lida a partir da migração `20261112230000_checkin_codigo_vale_para_todos.sql` (PR `frila-backend#488`). A função `privado.recurso_ligado_para('checkin_por_codigo', ...)` reflete diretamente o estado da chave global `checkin_por_codigo` em `privado.recurso`. Não há pilotos locais, casas âncoras ou listas manuais por estabelecimento.
- **Governança Estrita**: Intervenções na chave ocorrem exclusivamente por migrações auditadas (com PR, revisão e CI) ou via procedimentos operacionais rastreados, nunca por intervenção direta manual e silenciosa em banco.

---

## 1. Pré-Requisitos Mandatórios para Ativação em Produção

Antes de a chave global do check-in por código ser ativada em Produção, os seguintes três requisitos devem estar integralmente cumpridos:

1. **Pacote no Prod Aplicado**: O pacote de backend deve estar aplicado em Produção contendo:
   - A migração `20261112230000_checkin_codigo_vale_para_todos.sql` (PR `#488`, contrato 0.2.78), que conecta a checagem global e define a versão mínima do app;
   - A migração `20261112220000_lembrete_casa_fim_turno.sql` (PR `#489`, contrato 0.2.77) de lembretes à casa.
2. **Publicação Prévia da Política v1.1 com Bloco H**: A Política de Privacidade v1.1 contendo o **Bloco H** (descrevendo o mecanismo de check-in semiautomático por código, descarte imediato dos sinais de localização e ausência de auto-verificação) deve ser publicada previamente pelo Cauê no site oficial (`frilabr.com/privacidade`) **ANTES** do pacote ser ligado no ambiente de Produção.
3. **Versão Mínima do iOS**: A linha de versão mínima (`ios` `1.2.0` em `privado.recurso_versao_minima`) somente passa a vigorar operacionalmente quando o build **1.2.0** do app iOS estiver formalmente aprovado no App Store Review e disponível para os usuários na loja.

---

## 2. Regra da Janela Operacional

> [!IMPORTANT]
> Qualquer alteração do estado da chave (`ligado = true` ou `ligado = false`) em Produção deve ocorrer **obrigatoriamente FORA de turnos em andamento** (intervalo de calmaria operacional, preferencialmente na madrugada entre 02:00 e 05:00 UTC ou em janela sem turnos ativos).

Essa janela evita que um profissional em processo de chegada no local transicione de regra de validação enquanto o app exibe a tela de check-in.

---

## 3. Comportamento e Efeito nos Aplicativos

Com a chave global ligada (`checkin_por_codigo = true`) e a versão mínima iOS em `1.2.0`:

### A. Aplicativos Legados (iOS 1.0, 1.1 e Android)
- `public.configuracao_do_app` devolve `recursos.checkin_por_codigo = false` para essas versões.
- **Chegada do profissional**: Ao tocar em "Fazer check-in", mesmo estando a $\le 200\text{ m}$ do local com GPS válido, o sistema **não** faz auto-verificação. A presença registra como `manual` com `verificacao = 'pendente'` e `codigo_exigido = true`.
- **Ação da casa**: O gerente/responsável visualiza a chegada pendente na tela do turno e confirma a presença manualmente utilizando o botão **"Confirmar presença"** (`confirmar_checkin_manual`).
- Não é exibido teclado numérico de código para o profissional.

### B. Aplicativo iOS 1.2.0+
- `public.configuracao_do_app` devolve `recursos.checkin_por_codigo = true`.
- **Chegada do profissional**: Ao tocar em "Fazer check-in" a $\le 50\text{ m}$, o check-in registra `manual`/`pendente`, liberando `codigo_disponivel = true` e abrindo o teclado numérico de 6 dígitos.
- **Ação da casa**: A tela do turno da casa exibe o código de 6 dígitos gerado.
- **Confirmação**: O profissional digita o código a $\le 50\text{ m}$; a presença é confirmada na hora como `verificado` (tipo: `codigo`).

---

## 4. Auditoria de Estado (Script Somente Leitura)

Para inspecionar o estado consolidado da chave no banco (seguro para execução com `DATABASE_URL`, credenciais nunca são impressas):

```bash
# Consulta o estado global consolidado:
./scripts/checkin-por-codigo-casa.sh estado

# Consulta opcional para um estabelecimento específico:
./scripts/checkin-por-codigo-casa.sh estado <estabelecimento_id>
```

*Saída esperada (com a chave ligada):*
```text
  Estado consolidado: ATIVO (check-in por código em vigor para todos os estabelecimentos)
    • Chave global (privado.recurso):                  ligada (true)
    • Versão mínima iOS (privado.recurso_versao_minima): 1.2.0
    • Abrangência:                                     todos os estabelecimentos (contrato 0.2.78, sem lista)
```

---

## 5. Procedimento de Contingência (Desligar a Chave)

Se houver necessidade de desativar o check-in por código em Produção e retornar imediatamente ao fluxo clássico (geolocalizado automático $\le 200\text{ m}$):

1. **Executar em janela de calmaria (fora de turnos)**:
   ```sql
   update privado.recurso set ligado = false where chave = 'checkin_por_codigo';
   delete from privado.recurso_versao_minima where recurso = 'checkin_por_codigo' and plataforma = 'ios';
   ```
2. **Efeito imediato do desligamento**:
   - `configuracao_do_app` passa a entregar `checkin_por_codigo = false` para todas as plataformas e versões.
   - Chamadas a `gerar_codigo_checkin` e `validar_codigo_checkin` respondem `403 sem_permissao` (`recurso_desligado`).
   - Novos toques em "Fazer check-in" a $\le 200\text{ m}$ voltam a ser confirmados automaticamente no momento da chegada como `verificado` (tipo: `geolocalizado`).
   - Turnos já verificados anteriormente não sofrem alteração.
   - Caso haja check-in pendente registrado antes do desligamento, a casa realiza a confirmação manual via `confirmar_checkin_manual`.

---

## 6. Matriz de Impacto Operacional em Turnos Concorrentes

| Cenário no Momento da Virada | Comportamento do Sistema | Orientação Operacional |
|---|---|---|
| **Antes do check-in** | O profissional já cai nas regras do novo estado ao registrar chegada. | Nenhuma ação necessária. |
| **Check-in já registrado e pendente** | Presença segue pendente. Se a chave estiver ligada, pode usar código (se iOS 1.2+) ou confirmação manual. Se desligada, usa confirmação manual. | Casa toca em "Confirmar presença". |
| **Código gerado na tela da casa e chave desligada** | `validar_codigo_checkin` recusa com `403 recurso_desligado`. | Casa confirma manualmente via botão. |
| **Turno já verificado** | Presença consolidada é definitiva e imutável. | Zero impacto. |
