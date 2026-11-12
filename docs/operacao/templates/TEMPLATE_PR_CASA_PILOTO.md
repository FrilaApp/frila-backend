<!-- Modelo obrigatório de descrição para PR de inclusão de casa piloto no check-in por código -->
## Resumo
Inclusão do estabelecimento piloto no check-in por código (RN46) via migração linear forward-only.

- **Estabelecimento**: [Nome Fantasia / Razão Social da Sociedade]
- **UUID**: `00000000-0000-0000-0000-000000000000`
- **Sócio Responsável**: João Paulo (`@jotape12-Dev`) ou Cauê (`@cauecarneiro`)

---

## Declaração de Conformidade Jurídica e LGPD (Passo Obrigatório)

> [!IMPORTANT]
> A distinção entre PJ societária e MEI NÃO sai dos dígitos do CNPJ (ambos possuem 14 dígitos). O autor do PR deve emitir e conferir o Cartão CNPJ na Receita Federal antes de submeter.

### Checklist do Autor (preenchimento obrigatório antes de abrir o PR)
- [ ] **Cartão CNPJ emitido e conferido na Receita Federal**:
  - CNPJ: `XX.XXX.XXX/0001-XX` (14 dígitos)
  - **Campo "Código e Descrição da Natureza Jurídica"**: [Preencher aqui, ex.: 206-2 - Sociedade Empresária Limitada]
  - **Não é MEI**: Confirmado que a Natureza Jurídica NÃO é `213-5 Empresário (Individual)` com opção de SIMEI.
- [ ] **Pré-requisito legal cumprido**: Bloco H da Política de Privacidade v1.1 publicado formalmente em `frilabr.com/privacidade`.
- [ ] **Alinhamento com a casa**: Gerente instruído sobre a mecânica de exibição do código de 6 dígitos aos profissionais.
- [ ] **Confirmação do Sócio Responsável**: Declarado que a casa foi inspecionada e autorizada para o piloto.

---

## Checklist do Revisor Independente (Bigorna / Sócios)
- [ ] **Conferência da Natureza Jurídica**: O revisor conferiu a Natureza Jurídica da casa na base pública da Receita Federal / Redesim, atestando que se trata de sociedade e NÃO de MEI ou pessoa física.
- [ ] **UUID**: Confere estritamente com `public.estabelecimento`.
- [ ] **DDL**: Segue fielmente o template `template_ligar_casa_checkin_codigo.sql`.
- [ ] **Privacidade de Código**: Nenhum dado de pessoa física real ou documento pessoal vazado em mensagens de commit ou artefatos do repositório.
