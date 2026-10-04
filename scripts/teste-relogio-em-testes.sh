#!/usr/bin/env bash
# Autoteste do portão `relogio-em-testes.sh` contra casos conhecidos de sucesso e falha.
#
# Portão com furo aprova calado: este autoteste prova que o portão pega as bombas-relógio
# reais que quebraram a CI em 02/10 (teste 250) e em 04/10 (teste 280), extraídas diretamente
# do histórico do Git, bem como casos sintéticos de chamada sem congelamento ou com
# congelamento tardio.
#
# Uso:  ./scripts/teste-relogio-em-testes.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PORTAO="$PWD/scripts/relogio-em-testes.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

caso() {
  local nome="$1" esperado="$2" frase="$3" arquivo="$4"
  casos=$((casos + 1))

  local saida codigo
  set +e
  saida=$("$PORTAO" "$arquivo" 2>&1)
  codigo=$?
  set -e

  if [ "$codigo" = "$esperado" ] && printf '%s\n' "$saida" | grep -qF "$frase"; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperava saída $esperado com \"$frase\", veio $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Portão: prevenção de bomba-relógio em testes pgTAP"

# ── 1. Casos históricos reais extraídos do Git ──────────────────────────────────
#
# O teste 250 original antes do commit 18197c3 (PR #132) criava vagas para 02/10 às 18h
# e chamava candidatar() antes do primeiro set_config('frila.agora').
git show 18197c3~1:supabase/tests/250_turnos_nao_verificados_e_reconciliacao.sql > "$TMP/hist_250.sql"
caso "reprova o teste 250 original (bomba-relógio de 02/10 extraída do git)" 1 \
  "Chamada sensível ao relógio (candidatar) na linha 176" \
  "$TMP/hist_250.sql"

# O teste 280 original antes do commit 3604bea (PR #141) criava vagas para 03/10 às 18h
# e chamava candidatar() antes do primeiro set_config('frila.agora').
git show 3604bea~1:supabase/tests/280_fechamento_turno_vaga.sql > "$TMP/hist_280.sql"
caso "reprova o teste 280 original (bomba-relógio de 04/10 extraída do git)" 1 \
  "Chamada sensível ao relógio (vagas_abertas) na linha 123" \
  "$TMP/hist_280.sql"

# ── 2. Casos sintéticos de falha ───────────────────────────────────────────────

# Falha: data absoluta em vaga e chamada de relógio sem NUNCA congelar frila.agora
cat << 'SQL' > "$TMP/falha_sem_congelamento.sql"
begin;
select plan(1);
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em)
values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        '2026-11-10 18:00:00-03', '2026-11-10 23:00:00-03');
select public.candidatar('b6000000-0000-4000-8000-000000000011');
select finish();
rollback;
SQL
caso "reprova teste com data absoluta e candidatar sem nunca congelar relógio" 1 \
  "frila.agora NUNCA é congelado no arquivo" \
  "$TMP/falha_sem_congelamento.sql"

# Falha: format($$ select public.candidatar... $$) antes de set_config
cat << 'SQL' > "$TMP/falha_candidatar_tardio.sql"
begin;
select plan(1);
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em)
values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        '2026-12-01 18:00:00-03', '2026-12-01 23:00:00-03');
select lives_ok(format($$ select public.candidatar(%L) $$, 'b6000000-0000-4000-8000-000000000011'));
select set_config('frila.agora', '2026-11-30 12:00:00-03', true);
select finish();
rollback;
SQL
caso "reprova format($$ select candidatar $$) antes de set_config" 1 \
  "DEPOIS da chamada" \
  "$TMP/falha_candidatar_tardio.sql"

# ── 3. Casos de sucesso ─────────────────────────────────────────────────────────

# Sucesso: teste 250 atual da árvore
caso "aprova o teste 250 atual (com frila.agora congelado antes da vaga)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "supabase/tests/250_turnos_nao_verificados_e_reconciliacao.sql"

# Sucesso: teste 280 atual da árvore
caso "aprova o teste 280 atual (com frila.agora congelado no topo do arquivo)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "supabase/tests/280_fechamento_turno_vaga.sql"

# Sucesso: congelamento prévio antes de inserir e chamar
cat << 'SQL' > "$TMP/sucesso_congelado_no_topo.sql"
begin;
select plan(1);
select set_config('frila.agora', '2026-11-01 12:00:00-03', true);
insert into public.vaga (id, estabelecimento_id, funcao_id, inicio_em, fim_em)
values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
        '2026-11-02 18:00:00-03', '2026-11-02 23:00:00-03');
select public.candidatar('b6000000-0000-4000-8000-000000000011');
select finish();
rollback;
SQL
caso "aprova teste com congelamento prévio de frila.agora" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "$TMP/sucesso_congelado_no_topo.sql"

# Sucesso: teste que usa apenas datas relativas dinâmicas sem datas fixas de vaga
cat << 'SQL' > "$TMP/sucesso_datas_relativas.sql"
begin;
select plan(1);
create temp table quando as
  select (privado.agora() + interval '3 days') as inicio,
         (privado.agora() + interval '3 days 6 hours') as fim;
select throws_ok(
  format($$ select public.candidatar(%L) $$, gen_random_uuid()),
  'PGRST');
select finish();
rollback;
SQL
caso "aprova teste com horários puramente relativos (privado.agora + interval)" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "$TMP/sucesso_datas_relativas.sql"

# Sucesso: datas absolutas apenas em dados de usuário (termos_versao / nascimento)
cat << 'SQL' > "$TMP/sucesso_apenas_usuario.sql"
begin;
select plan(1);
select public.criar_conta('contratante','Dona do Bar','+5561999990201','1980-01-01','2026-09-22');
select finish();
rollback;
SQL
caso "aprova teste com datas absolutas restritas a nascimento e termos_versao" 0 \
  "Todos os 1 testes pgTAP estão imunes a bombas-relógio de relógio." \
  "$TMP/sucesso_apenas_usuario.sql"

# ── 4. Casos limite: pasta vazia ou inexistente (regra de portão: sai 2) ───────
mkdir -p "$TMP/pasta_vazia"
caso "rejeita pasta sem nenhum teste sql (sai 2, não mediu)" 2 \
  "nada a conferir, e isso não é verde" \
  "$TMP/pasta_vazia"

caso "rejeita pasta inexistente (sai 2, não mediu)" 2 \
  "nada a conferir, e isso não é verde" \
  "$TMP/pasta_que_nao_existe"

echo
if [ "$falhas" -gt 0 ]; then
  echo "$falhas de $casos casos falharam."
  exit 1
fi

echo "Todos os $casos casos do autoteste passaram."
exit 0
