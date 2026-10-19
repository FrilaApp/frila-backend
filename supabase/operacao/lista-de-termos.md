# Governança e Atualização da Lista de Termos Bloqueados

Este documento estabelece o processo operacional, as regras técnicas e a rotina de governança para atualização da lista de termos bloqueados do Frila (`privado.termo_bloqueado`), em cumprimento à **Diretriz 1.2 da App Store** (conteúdo gerado pelo usuário), às regras **RN10, RN15, RF26**, às decisões **J1 a J6** e ao plano de produto documentado em `requisitos/revisao-lista-termos-bloqueados.md`.

---

## 1. Princípios e Arquitetura do Filtro

1. **Dado de produto:** A lista de termos bloqueados é gerida como dado de produto e governada estritamente por código versionado no repositório `frila-backend`. Nenhuma alteração é feita diretamente à mão nas bases de dados.
2. **Princípio cardeal — termos de identidade nunca entram:** É terminantemente proibido cadastrar termos que designem identidade de gênero, orientação sexual, raça, etnia, religião, origem geográfica ou características corporais. As pessoas usam termos de identidade para se autodescreverem legitimamente em perfis e anúncios profissionais.
3. **Casamento por palavra inteira:** O mecanismo (`privado.texto_aceitavel`, em `supabase/migrations/20260923200000_filtro_de_texto_ofensivo.sql`) compara palavras normalizadas cercadas por espaços (`like '% termo %'`). O filtro não busca variações intencionalmente burladas (como substituição por símbolos ou espaçamento excessivo), evitando penalizar cadastros legítimos com falsos positivos. Ofensas contextuais e grafias disfarçadas são tratadas pelo canal de denúncia, bloqueio e moderação em até 24h pela Equipe Frila (RF26 e Diretriz 1.2).
4. **Reserva de linguagem neste manual:** Por diretriz de conformidade e respeito aos operadores, este documento não reproduz termos ofensivos, referenciando exclusivamente as categorias formais e exemplos neutros de testes.

---

## 2. Onde o Filtro Atua no Banco de Dados

O filtro é acionado por chamadas internas a `privado.texto_aceitavel` e `privado.exigir_texto_aceitavel`:

- **Campos filtrados (conteúdo lido por outros usuários):**
  - Nome no cadastro de conta (`public.criar_conta`).
  - Nome e endereço no estabelecimento (`public.cadastrar_estabelecimento`).
  - `local`, `regiao_administrativa`, `responsavel_local`, `traje` e `observacoes` em vagas (`public.publicar_vaga` e `public.republicar_vaga`).
  - `motivo` nos cancelamentos (`public.cancelar_posicao` e `public.cancelar_vaga`).
- **Campos isentos do filtro:**
  - `relato` na denúncia (`public.denunciar`): a vítima precisa reportar textualmente o ocorrido sem ter a denúncia travada.
  - `relato` em contestações de suspensão e revisão de despacho (decisão J1): textos lidos exclusivamente pela Equipe Frila via chave de serviço ou pelo próprio autor (`ocorrencia_leitura`), nos quais a parte relata fatos e citações.
- **Resposta em caso de violação:**
  - O banco de dados recusa a operação com o erro de contrato `422 Unprocessable Entity`, código `campo_invalido` e o nome do campo reprovado indicado em `details`.

---

## 3. Como Propor Alterações na Lista (Processo J6)

Toda e qualquer inclusão, alteração ou exclusão de termo deve tramitar por Pull Request no repositório `frila-backend`, cumprindo rigorosamente os quatro requisitos abaixo:

### 3.1 Justificativa Factual Obrigatória
O PR deve registrar explicitamente o caso de negócio que motivou a mudança:
- Denúncia de conteúdo reincidente analisada e acolhida pela Equipe Frila.
- Falso positivo reportado por usuário legítimo impedido de publicar ou se cadastrar.
- Parecer ou exigência da assessoria jurídica.

### 3.2 Exclusão Obrigatória com `DELETE` Explícito (Fator Upsert do Seed)
A tabela `privado.termo_bloqueado` é populada a partir do arquivo `supabase/seed.sql` através de:
```sql
insert into privado.termo_bloqueado (termo, categoria) values
  ...
on conflict (termo) do update set categoria = excluded.categoria;
```
Por ser um comando `insert ... on conflict do update`, **apenas remover uma linha da lista de inserção não apaga o termo de bancos já semeados**.

Portanto, **toda remoção de termo exige obrigatoriamente um comando SQL `delete` antes do bloco de inserção no `supabase/seed.sql`**, conforme exemplo estrutural:
```sql
delete from privado.termo_bloqueado where termo in ('termo_a_remover_1', 'termo_a_remover_2');
```
Sem esse `delete`, instâncias já inicializadas localmente ou nos ambientes remotos continuam bloqueando o termo.

### 3.3 Testes Automatizados no pgTAP
O PR deve atualizar o arquivo de testes de regressão `supabase/tests/100_filtro_de_texto.sql`:
- **Casos que devem passar (falsos positivos protegidos):** Nomes próprios, profissões ("acompanhante de idosos"), topônimos ("Chapada dos Veadeiros"), ingredientes ou termos profissionais ("frango criado solto", "uniforme com macacão").
- **Casos que devem ser recusados:** Comprovar a recusa nos grupos e categorias pertinentes.
- **Falsos positivos conhecidos e aceitos:** Quando um termo com potencial colateral técnico for mantido conscientemente pelo time por proteger contra ofensas graves, ele deve ser testado como recusado contendo a asserção explícita `'FALSO POSITIVO CONHECIDO E ACEITO'`.

### 3.4 Avaliação Jurídica
Termos pertencentes a categorias de discriminação, discurso de ódio ou exigências discriminatórias em contratação devem ter aprovação prévia do setor jurídico antes da aprovação do PR.

---

## 4. Como as Alterações Chegam aos Ambientes Remotos

A entrega e atualização contínua nos ambientes remotos (`frila-dev` e `frila-prod`) ocorre por meio do script de automação operacional:

```bash
./scripts/aplicar-remoto.sh <project_ref>
```

Funcionamento verificado no código (`scripts/aplicar-remoto.sh`):
1. O script aplica sequencialmente migrações pendentes em `supabase/migrations/` e registra em `supabase_migrations.schema_migrations`.
2. Em seguida (linhas 101-102), o script executa integralmente o arquivo `supabase/seed.sql` na base remota via Supabase Management API:
   ```bash
   echo "▸ Semente do catálogo"
   rodar "$(cat supabase/seed.sql)" >/dev/null && echo "  ✓"
   ```
3. Graças ao `delete` explícito posicionado no início do bloco de termos no `seed.sql`, qualquer termo revogado é removido imediatamente da tabela remota, sendo seguido pelo upsert dos termos mantidos e novos.

---

## 5. Ciclo de Revisão Periódica e Métricas Pós-Piloto

1. **Revisão Trimestral:**
   A cada trimestre, a Equipe Frila e a equipe de produto realizam uma sessão de alinhamento com base no relatório de denúncias de conteúdo e nos chamados de suporte do período, identificando novas expressões recorrentes ou falsos positivos a corrigir.
2. **Métricas pós-piloto sem violação de privacidade (RN15):**
   Após a conclusão do piloto no Distrito Federal, a equipe de engenharia pode consolidar métricas de volume de erros `422 campo_invalido` gerados por endpoint/campo. **É estritamente vedado registrar ou armazenar o conteúdo do texto rejeitado** nos logs ou tabelas analíticas, preservando integralmente os dados pessoais dos usuários.

---

## 6. Responsabilidades

- **Equipe de Produto:** Avaliação e proposição de termos com base nas ocorrências do aplicativo.
- **Engenharia / Backend:** Implementação dos PRs no `seed.sql`, elaboração dos testes no pgTAP e execução do pipeline de homologação e deploy.
- **Jurídico:** Homologação prévia de termos relacionados a infrações legais, discriminação e regras de anúncio de vagas.
