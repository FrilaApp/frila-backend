# Roteiro Operacional: Habilitação e Desativação do Check-in por Código por Casa (RN46)

- **Princípio Arquitetural**: Conforme governança do projeto, regras da Bússola (08/11), LGPD (art. 6º, III) e documentação de modelagem (`banco-de-dados/Modelagem de Banco de Dados.md` § 661), **estabelecimentos entram e saem do piloto POR MIGRAÇÃO** (processo auditável via PR, revisão, CI e esteira automatizada), **nunca por SQL manual direto em Produção**.
- **Separação Rígida de Decisões**:
  1. **Versão mínima do app (`privado.recurso_versao_minima`)**: Decisão global de produto. Entra em migração única e separada quando o build 1.2.0 estiver aprovado na App Store e o Bloco H publicado.
  2. **Habilitação de estabelecimento (`privado.recurso_estabelecimento`)**: Decisão operacional individual. Entra uma casa por vez, sem misturar ou reescrever a versão mínima global do aplicativo.
- **Restrição de Tipo Jurídico**: Apenas casas **Pessoa Jurídica (não MEI)** com CNPJ societário ou **casas de teste da equipe** podem entrar por migração. Casas de pessoa física ou MEI são vedadas de inclusão no repositório público (seus dados qualificam como dados pessoais, exigindo nova análise de balanceamento LGPD).
- **Isolamento Comprovado**: O pacote de Prod é entregue com a chave global ligada (`privado.recurso.ligado = true`) e a lista de casas vazia (`privado.recurso_estabelecimento` vazio). O teste pgTAP `supabase/tests/850_piloto_chave_casa_migracao.sql` comprova que com a lista vazia **nada muda para ninguém** (o fluxo legado permanece 100% ativo).

---

## 1. Pré-Requisitos Mandatórios

Antes de abrir o PR da migração que habilita a primeira casa piloto em Produção:

1. **Publicação Prévia do Bloco H da Política**: O Bloco H da Política de Privacidade v1.1 (descrevendo a mecânica de check-in semiautomático por código, descarte de sinais de GPS e ausência de auto-verificação) deve ser publicado no site oficial (`frilabr.com/privacidade`) **ANTES** da primeira casa entrar e antes da inserção da linha de versão mínima do app.
2. **Conferência da Natureza Jurídica no Cartão CNPJ (Passo Obrigatório e Assinado)**:
   > [!WARNING]
   > O MEI (Microempreendedor Individual) possui CNPJ com 14 dígitos numéricos, idêntico ao de uma sociedade empresária. A validação de formato no SQL apenas garante que o documento tem 14 dígitos e **NÃO separa MEI**.
   - O autor do PR deve obrigatoriamente emitir e verificar o **Cartão CNPJ** da casa na Receita Federal (ou consulta Redesim).
   - **Campo a conferir**: `Código e Descrição da Natureza Jurídica`.
   - **Regra de aceite**: Deve ser sociedade empresarial (ex.: `206-2 Sociedade Empresária Limitada`, `205-4 Sociedade Anônima Fechada`, etc.) ou casa de teste própria da equipe.
   - **Regra de recusa**: Se a Natureza Jurídica for `213-5 Empresário (Individual)` com opção de MEI (SIMEI), a casa **NÃO pode entrar no piloto** (seus dados qualificam como dados de pessoa física, exigindo nova análise de balanceamento da LGPD).
   - O sócio responsável (`@jotape12-Dev` ou `@cauecarneiro`) deve atestar e assinar formalmente esta conferência no corpo do PR.
3. **Pacote no Prod Aplicado**: A tag `backend-v1.2.0` (ou posterior) deve estar aplicada em Produção, contendo as migrações da Etapa 1 (`20261111210000`) e a chave global `checkin_por_codigo` ligada em `privado.recurso`.
4. **App iOS Homologado**: Build 1.2.0 aprovado no App Store Review e instalado nos aparelhos da gerência da casa piloto e dos profissionais confirmados para os turnos.
5. **Elegibilidade da Casa Piloto**: A casa escolhida deve ter cadastro ativo em `public.estabelecimento`, comprovar natureza societária conforme o item 2 e estar ciente da dinâmica de exibição do código de 6 dígitos.
6. **Janela Operacional**: O deploy da migração deve ser agendado preferencialmente **FORA de turnos em andamento** (intervalo entre o fim do turno anterior e o início do próximo).

---

## 2. Modelos de Migração: Quando Usar Cada Um

### A. Versão Mínima Global do App (Uso Único Global)
Quando o app 1.2.0 for liberado na loja e o Bloco H publicado, aplique a migração baseada em [docs/operacao/templates/template_versao_minima_checkin_codigo.sql](templates/template_versao_minima_checkin_codigo.sql):
```bash
supabase migration new versao_minima_checkin_codigo
```
Esta migração registra `1.2.0` em `privado.recurso_versao_minima` para iOS, permitindo que `public.configuracao_do_app` entregue a flag `checkin_por_codigo = true` para os aparelhos atualizados. **Não deve ser reaplicada a cada casa.**

### B. Habilitação de Casa Piloto (Uso Individual por Estabelecimento)
Para cada casa piloto que for ingressar no programa:

1. **Criar a migração a partir do template**:
   Copie o template [docs/operacao/templates/template_ligar_casa_checkin_codigo.sql](templates/template_ligar_casa_checkin_codigo.sql) para `supabase/migrations/`:
   ```bash
   # Nome padrão: timestamp UTC + piloto_checkin_codigo_casa_<identificador>
   supabase migration new piloto_checkin_codigo_casa_<identificador>
   ```
2. **Preencher o UUID da casa**:
   A migração valida automaticamente em tempo de execução:
   - Existência da casa em `public.estabelecimento`.
   - Sintaxe e formato do documento (CNPJ com 14 dígitos numéricos).
   - Inserção atômica em `privado.recurso_estabelecimento` (sem tocar na versão mínima).

3. **Validar nos autotestes locais**:
   ```bash
   supabase test db supabase/tests/850_piloto_chave_casa_migracao.sql
   ./scripts/checkin-por-codigo-casa.sh estado <uuid_da_casa>
   ```

4. **Submeter PR na `develop` utilizando o modelo obrigatório**:
   - Abra o PR na base `develop` preenchendo obrigatoriamente o modelo [docs/operacao/templates/TEMPLATE_PR_CASA_PILOTO.md](templates/TEMPLATE_PR_CASA_PILOTO.md).
   - O autor preenche e assina o checklist confirmando a consulta do Cartão CNPJ na Receita Federal e a Natureza Jurídica (não MEI).
   - O revisor independente (Bigorna / Sócios) confere o checklist e revalida a Natureza Jurídica na base pública da Receita Federal.
   - CI verde obrigatória em todos os jobs.
   - Após aprovação, a esteira `entrega.yml` aplica a migração automaticamente via `scripts/aplicar-remoto.sh`.

---

## 3. Como Conferir que Deu Certo

### A. Conferência no Banco de Dados
Utilize o script de leitura para auditar o estado consolidado (somente leitura, seguro para rodar com `DATABASE_URL`):
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

### B. Conferência Operacional em Campo
1. **Gerente (Contratante)**: Abre a tela do turno no iOS 1.2 e observa o card *"Aguardando o profissional chegar no local"*.
2. **Profissional**: Ao tocar em "Fazer check-in" a $\le 50\text{ m}$ da casa, o check-in registra `manual`/`pendente`, liberando `codigo_disponivel = true` e abrindo o teclado numérico de 6 dígitos.
3. **Validação**: Gerente exibe o código gerado; profissional digita no app a $\le 50\text{ m}$; presença confirmada na hora como `verificado` (tipo: `codigo`).

---

## 4. Comportamento com Turnos em Andamento

| Momento da Migração | Efeito no Turno | Procedimento Operacional |
|---|---|---|
| **Antes do check-in** | O profissional já cai no fluxo novo na chegada (presença fica `pendente` e exige código). | Sem impacto adverso. |
| **Check-in já registrado e pendente** | A casa poderá gerar o código normalmente após novo toque de aproximação do profissional. | Caso haja pressa, a casa usa a confirmação manual. |
| **Código já gerado na tela da casa** | **Se a casa for desativada neste instante**: `validar_codigo_checkin` recusa com `403 recurso_desligado`. | A casa confirma a presença manualmente via `confirmar_checkin_manual`. |
| **Turno já verificado** | Presença já consolidada é imutável. | Zero impacto. |

---

## 5. Procedimento de Rollback / Desativação (Desligar Casa)

Caso seja necessário desativar a casa do piloto:

1. **Nunca editar o passado ou remover a migração anterior.**
2. Crie uma **migração corretiva forward-only** baseada no template [docs/operacao/templates/template_desligar_casa_checkin_codigo.sql](templates/template_desligar_casa_checkin_codigo.sql):
   ```sql
   delete from privado.recurso_estabelecimento
    where chave = 'checkin_por_codigo'
      and estabelecimento_id = '<uuid_da_casa>'::uuid;
   ```
3. Submeta o PR para a esteira oficial. Ao aplicar:
   - A casa volta imediatamente ao fluxo legado (geolocalizado automático $\le 200\text{ m}$).
   - Tentativas de gerar ou validar código passam a responder `403 recurso_desligado`.
   - Turnos pendentes anteriores podem ser finalizados normalmente pela casa via `confirmar_checkin_manual`.

---

## 6. Ferramental de Diagnóstico e Auditoria (Somente Leitura)

O script [scripts/checkin-por-codigo-casa.sh](../../scripts/checkin-por-codigo-casa.sh) permanece versionado no repositório como ferramenta de diagnóstico e auditoria estritamente de **leitura** para todos os ambientes (`local`, `dev` e `prod`):
- `checkin-por-codigo-casa.sh estado <uuid>`: Inspeciona e consolida o estado das tabelas `privado.recurso`, `privado.recurso_versao_minima`, `privado.recurso_estabelecimento` e o retorno de `privado.recurso_ligado_para`.
- **Escrita vedada no script**: O script recusa os subcomandos `ligar` e `desligar`. Todas as alterações de estado ocorrem exclusivamente via migrações versionadas com PR, revisão de código e aprovação em CI.
