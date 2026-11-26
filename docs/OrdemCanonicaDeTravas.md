# Ordem Canônica de Travas no PostgreSQL (BE-07 — Portão V1)

Este documento consolida a **ordem canônica de aquisição de travas de linha** (`FOR UPDATE` / `FOR NO KEY UPDATE`) no backend do Frila, acompanhada pelo teste executável de catálogo [`supabase/tests/896_ordem_canonica_travas_be07.sql`](../supabase/tests/896_ordem_canonica_travas_be07.sql) (que roda em toda CI via `supabase test db`).

> **Escopo:** portão preparatório para a V1 (Pagamentos). Este documento **não** implementa Pagamentos; ele fixa a regra vigente e define como novas entidades financeiras devem se encaixar sem reintroduzir deadlocks (`40P01`).

---

## 1. Hierarquia canônica de travas

Sempre que uma transação precisar travar mais de uma entidade do núcleo de vagas/turnos/chamadas, a aquisição de travas deve seguir esta ordem global:

```text
1. estabelecimento   (quando serializa cota/operação da casa — ex.: chamar_profissional, publicar_a_partir_da_chamada)
2. vaga              (sempre em ORDER BY id; FOR NO KEY UPDATE ou FOR UPDATE)
3. posicao | chamada (sempre em ORDER BY id; FOR UPDATE)
4. turno             (quando houver trava explícita de turno)
5. usuario | profissional (sempre em ORDER BY id; FOR UPDATE / FOR KEY SHARE via FK)
```

### Exceção documentada (`chamar_profissional`)
Em `public.chamar_profissional` (`20261117080000_chamar_trava_a_vaga.sql`, vigente em `20261125160000_piso_teto_da_diaria_so_aviso_b124.sql`), quando `vaga_id IS NOT NULL`, a função trava `estabelecimento` → `profissional` (para atomicidade da cota global de 5 chamadas abertas entre casas distintas, CD-C14) → `vaga` (relida `FOR UPDATE`, B-040). Nenhuma outra função trava `vaga` antes de `profissional`, portanto não há ciclo com essa ordem.

### Regra de pré-trava para `UPDATE` multi-linha
Qualquer `UPDATE` que altere múltiplas linhas de `public.vaga`, `public.posicao` ou `public.chamada` **não** pode confiar na ordem física ou de hash do plano do PostgreSQL. Antes do `UPDATE`, a transação deve executar um `PERFORM 1 FROM ... ORDER BY id FOR NO KEY UPDATE` (ou `FOR UPDATE`) cobrindo exatamente o conjunto de linhas que será modificado, no mesmo modo de trava (ver `#562`, `#565`, `#572`).

---

## 2. Inventário das funções críticas auditadas

| Função | Ordem de travas vigente | Migração de referência | Teste de corrida / catálogo |
|---|---|---|---|
| `privado.excluir_conta(uuid)` | `vaga (ORDER BY id)` → `chamada (ORDER BY id)` → `usuario (FOR UPDATE)` | `20261117010000_ordem_de_travas_exclusao_x_aceite.sql` (#522) | `scripts/corrida-chamada.sh`, `896` |
| `public.chamar_profissional(...)` | `estabelecimento` → `profissional` → `vaga` (quando `vaga_id IS NOT NULL`) | `20261117080000_chamar_trava_a_vaga.sql` (#543) | `scripts/corrida-chamada.sh`, `880`, `896` |
| `privado.expirar_chamadas()` | `vaga (ORDER BY id, FOR NO KEY UPDATE)` → `chamada (ORDER BY id, FOR UPDATE OF c)` | `20261117170000_expirar_chamadas_ordem_de_travas.sql` (#562) | `scripts/corrida-chamada.sh` (14–24), `887`, `896` |
| `privado.lembrar_chamadas()` | `chamada (ORDER BY id, FOR UPDATE OF c)` | `20261117170000_expirar_chamadas_ordem_de_travas.sql` (#562) | `scripts/corrida-chamada.sh`, `887`, `896` |
| `public.publicar_a_partir_da_chamada(...)` | `estabelecimento` → `vaga (ORDER BY id)` → `chamada (ORDER BY id)` | `20261117190000_residuos_ordem_de_travas.sql` (#565) | `scripts/corrida-chamada.sh` (26), `887`, `889`, `896` |
| `privado.fechar_turnos_e_vagas()` | Pré-trava `vaga (ORDER BY id, FOR NO KEY UPDATE)` antes de `UPDATE posicao` e `UPDATE vaga` | `20261117190000_residuos_ordem_de_travas.sql` (#565) | `scripts/corrida-chamada.sh` (25), `889`, `896` |
| `privado.limpar_contas_anonimizadas(int)` | Pré-trava `vaga (ORDER BY id, FOR NO KEY UPDATE)` antes de `UPDATE vaga` | `20261117190000_residuos_ordem_de_travas.sql` (#565) | `scripts/corrida-chamada.sh` (27), `889`, `896` |
| `public.cancelar_vaga(...)` | `vaga (FOR NO KEY UPDATE)` antes de cancelar `posicao` aberta | `20261117200000_cancelar_vaga_ordem_de_travas.sql` (#572) | `scripts/corrida-chamada.sh` (28–30), `890`, `896` |

---

## 3. Portão para a V1 (Pagamentos)

Antes de introduzir novas tabelas ou RPCs financeiras na V1 (ex.: cobranças, escrow, carteira/ledger, repasses, conciliação de webhooks):

1. **Nunca inverter a hierarquia existente:** se uma transação financeira tocar entidades do ciclo de turno (`vaga`, `posicao`, `turno`) **e** entidades financeiras, as travas do ciclo de turno vêm **antes** das entidades financeiras (ou em transação separada via fila/outbox, evitando manter trava de `vaga`/`posicao` durante chamadas externas).
2. **Ordem interna entre entidades financeiras:** definir e registrar aqui a ordem fixa entre as tabelas novas (sempre com `ORDER BY id` para lotes) antes da primeira migração de escrita.
3. **Nenhuma chamada de rede (`pg_net`/API externa) dentro de trava de linha:** travas `FOR UPDATE` / `FOR NO KEY UPDATE` devem cobrir apenas mutações locais rápidas no Postgres.
4. **Atualização obrigatória do teste executável:** toda nova função `SECURITY DEFINER` ou cron que adquira travas explícitas sobre mais de uma tabela (ou `UPDATE` multi-linha concorrente) deve adicionar sua asserção em [`supabase/tests/896_ordem_canonica_travas_be07.sql`](../supabase/tests/896_ordem_canonica_travas_be07.sql) e, quando houver corrida real entre duas sessões, um cenário em `scripts/corrida-*.sh`.
