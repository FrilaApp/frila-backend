#!/usr/bin/env bash
# Autoteste automatizado do script `scripts/comparar-migracoes.sh`.
#
# REGRA FUNDAMENTAL: 100% LOCAL, SEM REDE, SEM TOKEN.
# Exercita todos os cenários com listas sintéticas e casos de borda reais.
#
# Uso:
#   ./scripts/teste-comparar-migracoes.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PORTAO="$PWD/scripts/comparar-migracoes.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

conferir() { # conferir <descrição> <saída esperada> <frase esperada> <comando...>
  local desc="$1" esperado="$2" frase="$3"; shift 3
  local saida codigo
  saida=$("$@" 2>&1); codigo=$?
  casos=$((casos + 1))
  if [ "$codigo" = "$esperado" ] && printf '%s' "$saida" | grep -qF -- "$frase"; then
    echo "  ✓ $desc"
  else
    echo "  ✗ $desc: saiu $codigo (esperado $esperado), frase procurada \"$frase\""
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Teste automatizado de scripts/comparar-migracoes.sh"

# ── 1. Parâmetros inválidos ────────────────────────────────────
conferir "falta de parâmetros sai com código 2" \
  2 "Arquivo de versões do Prod não informado" \
  "$PORTAO"

conferir "flag --commit sem argumento sai com código 2" \
  2 "Parâmetro --commit informado sem referência" \
  "$PORTAO" --commit

conferir "arquivo inexistente sai com código 2" \
  2 "não encontrado" \
  "$PORTAO" "$TMP/arquivo_que_nao_existe.txt"

# ── 2. Arquivo vazio ou sem versões ────────────────────────────
touch "$TMP/vazio.txt"
conferir "arquivo vazio reprova com código 1" \
  1 "BLOQUEIO TOTAL — CATÁLOGO VAZIO" \
  "$PORTAO" "$TMP/vazio.txt"

cat << 'EOF' > "$TMP/texto_sem_numeros.txt"
versao
inserted_at
coluna_qualquer
(0 rows)
EOF
conferir "arquivo sem nenhuma versão numérica reprova com código 1" \
  1 "BLOQUEIO TOTAL — CATÁLOGO VAZIO" \
  "$PORTAO" "$TMP/texto_sem_numeros.txt"

# ── Extração da lista canônica da develop para os cenários ─────
git ls-tree -r --name-only origin/develop:supabase/migrations 2>/dev/null \
  | sed -En 's/^([0-9]{14})_.*/\1/p' | sort -u > "$TMP/todas_develop.txt"

total_dev=$(wc -l < "$TMP/todas_develop.txt" | tr -d ' ')

# ── 3. Cenário Ideal Go: 119 no Prod (faltam as 4 pendentes) ──
# As 4 últimas migrações pós-1.0.0
head -n 119 "$TMP/todas_develop.txt" > "$TMP/prod_ideal_119.txt"

conferir "cenário ideal com 119 versões no Prod passa com exit 0 (LIBERADO PARA A TAG)" \
  0 "LIBERADO PARA A TAG" \
  "$PORTAO" "$TMP/prod_ideal_119.txt"

conferir "cenário ideal lista exatamente as 4 pendências esperadas" \
  0 "4 pendências para a tag aplicar" \
  "$PORTAO" "$TMP/prod_ideal_119.txt"

# ── 3.1. Casos de Catálogo Incompleto (1 versão e 60 versões) ─
head -n 1 "$TMP/todas_develop.txt" > "$TMP/prod_1_versao.txt"
conferir "Prod com apenas 1 versão reprova com exit 1 (CATÁLOGO INCOMPLETO)" \
  1 "BLOQUEIO TOTAL — CATÁLOGO INCOMPLETO" \
  "$PORTAO" "$TMP/prod_1_versao.txt"

head -n 60 "$TMP/todas_develop.txt" > "$TMP/prod_60_versoes.txt"
conferir "Prod com 60 versões reprova com exit 1 (CATÁLOGO INCOMPLETO)" \
  1 "BLOQUEIO TOTAL — CATÁLOGO INCOMPLETO" \
  "$PORTAO" "$TMP/prod_60_versoes.txt"

# ── 3.2. Caso de Buraco no Meio (Lacuna na Sequência) ─────────
# Cria lista de 119 versões mas remove a versão da linha 50
sed '50d' "$TMP/prod_ideal_119.txt" > "$TMP/prod_buraco.txt"
conferir "Prod com buraco no meio (lacuna na sequência) reprova com exit 1" \
  1 "BLOQUEIO TOTAL — BURACO NO MEIO DETECTADO" \
  "$PORTAO" "$TMP/prod_buraco.txt"

# ── 4. Cenário 100% atualizado (123 coincidentes, 0 pendências) ─
cp "$TMP/todas_develop.txt" "$TMP/prod_123.txt"
conferir "cenário 100% atualizado passa com exit 0" \
  0 "100% ATUALIZADO" \
  "$PORTAO" "$TMP/prod_123.txt"

# ── 5. Cenário com Anomalia no Prod (versão desconhecida) ──────
cp "$TMP/prod_ideal_119.txt" "$TMP/prod_anomalia.txt"
echo "99991231235959" >> "$TMP/prod_anomalia.txt"
sort "$TMP/prod_anomalia.txt" -o "$TMP/prod_anomalia.txt"

conferir "carimbo desconhecido no Prod acusa anomalia e reprova com exit 1" \
  1 "BLOQUEIO TOTAL — NÃO DISPARAR A TAG" \
  "$PORTAO" "$TMP/prod_anomalia.txt"

conferir "anomalia identifica o carimbo estranho no relatório" \
  1 "99991231235959" \
  "$PORTAO" "$TMP/prod_anomalia.txt"

# ── 6. Cenário Específico da Migração Renomeada ─────────────────
# Caso real: 20261015160000 (nome de rascunho) x 20261020180000 (nome oficial no PR #185)
# Se o Prod foi aplicado com o nome antigo 20261015160000:
cp "$TMP/prod_ideal_119.txt" "$TMP/prod_renomeada.txt"
# Remove a versão 20261020180000 se estivesse presente e adiciona a versão antiga de rascunho
sed -i '' '/20261020180000/d' "$TMP/prod_renomeada.txt" 2>/dev/null || sed -i '/20261020180000/d' "$TMP/prod_renomeada.txt"
echo "20261015160000" >> "$TMP/prod_renomeada.txt"
sort "$TMP/prod_renomeada.txt" -o "$TMP/prod_renomeada.txt"

conferir "migração com timestamp renomeado (20261015160000) é detectada como anomalia (exit 1)" \
  1 "20261015160000" \
  "$PORTAO" "$TMP/prod_renomeada.txt"

conferir "migração renomeada também acusa pendência da versão oficial (20261020180000)" \
  1 "20261020180000" \
  "$PORTAO" "$TMP/prod_renomeada.txt"

# ── 7. Resiliência a formato de cópia do Supabase SQL Editor ───
cat << 'EOF' > "$TMP/prod_sujo.txt"
versao | inserted_at
---------------------
"20260922150000" | 2026-09-22 15:00:00+00
"20260922150100" | 2026-09-22 15:01:00+00
"20260922150200" | 2026-09-22 15:02:00+00

(3 rows)
EOF
conferir "resiliência: linhas com aspas, pipes e cabeçalhos são sanitizadas" \
  1 "3 versões encontradas" \
  "$PORTAO" "$TMP/prod_sujo.txt"

# ── 8. Suporte à flag --commit ─────────────────────────────────
conferir "flag --commit origin/develop processa catálogo corretamente" \
  0 "Referência do repositório: origin/develop" \
  "$PORTAO" --commit origin/develop "$TMP/prod_ideal_119.txt"

echo
if [ "$falhas" -ne 0 ]; then
  echo "Total de falhas: $falhas de $casos casos." >&2
  exit 1
fi
echo "Todos os $casos casos passaram com sucesso (100% verde)."
exit 0
