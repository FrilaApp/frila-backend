## O quê e por quê

## Como testei

<!-- comando + resumo da saída; o que não rodou -->

## A API pública mudou?

- [ ] **Não.** Nenhuma função do schema `public` criada, removida ou com assinatura alterada.
- [ ] **Sim**, e o contrato foi junto: `contrato/openapi.yaml` atualizado a partir do `frila-documentacao` (versão e soma regravadas).

## Portões

- [ ] `supabase db reset` — as migrações aplicam do zero
- [ ] `supabase test db` — pgTAP verde
- [ ] `./scripts/mutacao.sh` — todas as regras cobertas
- [ ] `./scripts/ciclo-completo.sh` — fluxo por HTTP com status e código
- [ ] `./scripts/lint-conhecido.sh` — sem achado novo
- [ ] `./scripts/advisor-conhecido.sh` — sem alerta além dos declarados

## Migrações

- [ ] Nenhuma migração existente foi editada. Correção entrou como migração nova.
- [ ] Nenhuma mudança foi feita pelo painel do Supabase — o que não está em arquivo, o próximo ambiente não tem.
