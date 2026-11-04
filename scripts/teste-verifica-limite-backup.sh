#!/usr/bin/env bash
# Teste automatizado de monitoramento e projeção de limite de armazenamento de backup.
# Scripts sob teste: scripts/verifica-limite-backup.sh
#
# Casos validados:
#   1. Projeção abaixo de 50% (< 50%) - Caso nominal seguro (exit 0).
#   2. Projeção na faixa de alerta (50% a < 80%) - Emite ::warning:: (exit 0).
#   3. Projeção crítica (>= 80%) - Emite ::error:: e falha propositalmente (exit 1).
#   4. Limiares de borda exatos (50.00% e 80.00%).
#   5. Limite ausente assume 10 GB por padrão.
#   6. Entrada como arquivo real (.tar.age).
#   7. Entrada como diretório de backup (BACKUP_DIR com .tar.age).
#   8. Entradas inválidas (falha fechada com exit 2).
#   9. Resiliência sem GITHUB_STEP_SUMMARY.
#   10. Suporte a limite com casas decimais (ex: 0.5 GB).

set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/verifica-limite-backup.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "ERRO: Script '$SCRIPT' não encontrado ou não executável." >&2
  exit 1
fi

DIR_TEMP=""
# shellcheck disable=SC2329
limpar() {
  local codigo=$?
  if [[ -n "$DIR_TEMP" && -d "$DIR_TEMP" ]]; then
    rm -rf -- "$DIR_TEMP" 2>/dev/null || true
  fi
  exit "$codigo"
}
trap limpar EXIT INT TERM

DIR_TEMP=$(mktemp -d)

casos=0
passou() {
  echo "  ✓ $1"
  casos=$((casos + 1))
}

falhar() {
  echo "  ✗ FALHA: $1" >&2
  exit 1
}

echo "=== Suíte de Testes: Monitoramento de Limite de Backup (scripts/verifica-limite-backup.sh) ==="

# -----------------------------------------------------------------------------
echo "▸ 1. Projeção abaixo de 50% (caso nominal seguro: ~37 MB, keep 14, limite 10 GB)"
# -----------------------------------------------------------------------------
resumo="$DIR_TEMP/resumo_1.md"
saida=$(GITHUB_STEP_SUMMARY="$resumo" "$SCRIPT" 38797312 14 10)
codigo=$?
[[ "$codigo" -eq 0 ]] || falhar "Caso 1 deveria sair com código 0, saiu $codigo"
[[ "$saida" == *"5.43%"* ]] || falhar "Caso 1 não calculou 5.43% corretamente"
[[ "$saida" == *"Status do armazenamento:    OK"* ]] || falhar "Caso 1 não emitiu status OK"
[[ "$saida" != *"::warning::"* ]] || falhar "Caso 1 emitiu warning indevido"
[[ "$saida" != *"::error::"* ]] || falhar "Caso 1 emitiu error indevido"
grep -q "✓ Seguro (< 50% da cota)" "$resumo" || falhar "Step Summary do Caso 1 não registrou status seguro"
passou "Caso nominal seguro opera com código 0 e sem avisos"

# -----------------------------------------------------------------------------
echo "▸ 2. Projeção na faixa de alerta (>= 50% e < 80%: 400 MB x 14 = 5.6 GB de 10 GB = 56.00%)"
# -----------------------------------------------------------------------------
resumo="$DIR_TEMP/resumo_2.md"
saida=$(GITHUB_STEP_SUMMARY="$resumo" "$SCRIPT" 400000000 14 10)
codigo=$?
[[ "$codigo" -eq 0 ]] || falhar "Caso 2 deveria sair com código 0 (aviso), saiu $codigo"
[[ "$saida" == *"56.00%"* ]] || falhar "Caso 2 não calculou 56.00%"
[[ "$saida" == *"::warning::"* ]] || falhar "Caso 2 não emitiu anotação ::warning::"
[[ "$saida" != *"::error::"* ]] || falhar "Caso 2 emitiu erro indevido"
grep -q "⚠️ Alerta" "$resumo" || falhar "Step Summary do Caso 2 não registrou alerta"
passou "Faixa de 50% a < 80% emite ::warning:: com código 0"

# -----------------------------------------------------------------------------
echo "▸ 3. Projeção crítica (>= 80%: 600 MB x 14 = 8.4 GB de 10 GB = 84.00%)"
# -----------------------------------------------------------------------------
resumo="$DIR_TEMP/resumo_3.md"
set +e
saida=$(GITHUB_STEP_SUMMARY="$resumo" "$SCRIPT" 600000000 14 10 2>&1)
codigo=$?
set -e
[[ "$codigo" -eq 1 ]] || falhar "Caso 3 deveria falhar com código 1, saiu $codigo"
[[ "$saida" == *"84.00%"* ]] || falhar "Caso 3 não calculou 84.00%"
[[ "$saida" == *"::error::"* ]] || falhar "Caso 3 não emitiu anotação ::error::"
grep -q "🚨 Falha Crítica" "$resumo" || falhar "Step Summary do Caso 3 não registrou falha crítica"
passou "Faixa >= 80% emite ::error:: e falha o job com código 1"

# -----------------------------------------------------------------------------
echo "▸ 4. Teste de borda exata: 50.00% e 80.00%"
# -----------------------------------------------------------------------------
# 50.00%: 500 MB * 10 backups = 5.0 GB de 10 GB
saida_50=$("$SCRIPT" 500000000 10 10)
[[ "$saida_50" == *"50.00%"* ]] || falhar "Borda 50% não calculou 50.00%"
[[ "$saida_50" == *"::warning::"* ]] || falhar "Borda 50% não emitiu warning"

# 80.00%: 800 MB * 10 backups = 8.0 GB de 10 GB
set +e
saida_80=$("$SCRIPT" 800000000 10 10 2>&1)
cod_80=$?
set -e
[[ "$cod_80" -eq 1 ]] || falhar "Borda 80% deveria falhar com código 1, saiu $cod_80"
[[ "$saida_80" == *"80.00%"* ]] || falhar "Borda 80% não calculou 80.00%"
[[ "$saida_80" == *"::error::"* ]] || falhar "Borda 80% não emitiu error"
passou "Limiares exatos de 50.00% e 80.00% acionam as guardas corretas"

# -----------------------------------------------------------------------------
echo "▸ 5. Limite ausente utiliza 10 GB por padrão"
# -----------------------------------------------------------------------------
saida_padrao=$(
  unset BACKUP_LIMITE_GB
  "$SCRIPT" 38797312 14
)
[[ "$saida_padrao" == *"BACKUP_LIMITE_GB=10"* ]] || falhar "Limite ausente não usou 10 GB"
[[ "$saida_padrao" == *"10.00 GB"* ]] || falhar "Limite ausente não formatou 10.00 GB"
passou "Ausência do parâmetro e da variável de ambiente adota 10 GB"

# -----------------------------------------------------------------------------
echo "▸ 6. Entrada como arquivo real (.tar.age)"
# -----------------------------------------------------------------------------
arq_teste="$DIR_TEMP/frila-backup-teste.tar.age"
# Cria arquivo com exatamente 1.000.000 bytes
dd if=/dev/zero of="$arq_teste" bs=1000 count=1000 2>/dev/null
saida_arq=$("$SCRIPT" "$arq_teste" 14 10)
[[ "$saida_arq" == *"frila-backup-teste.tar.age"* ]] || falhar "Não identificou o nome do arquivo"
[[ "$saida_arq" == *"1000000 bytes"* ]] || falhar "Não mediu 1000000 bytes do arquivo"
[[ "$saida_arq" == *"0.14%"* ]] || falhar "Cálculo do arquivo real divergiu de 0.14%"
passou "Entrada como arquivo .tar.age processada com sucesso"

# -----------------------------------------------------------------------------
echo "▸ 7. Entrada como diretório de backup (BACKUP_DIR)"
# -----------------------------------------------------------------------------
pasta_teste="$DIR_TEMP/pasta_backup"
mkdir -p "$pasta_teste"
arq_na_pasta="$pasta_teste/frila-backup-20261104-070000.tar.age"
dd if=/dev/zero of="$arq_na_pasta" bs=1000 count=2000 2>/dev/null
saida_pasta=$("$SCRIPT" "$pasta_teste" 14 10)
[[ "$saida_pasta" == *"frila-backup-20261104-070000.tar.age"* ]] || falhar "Não encontrou arquivo na pasta"
[[ "$saida_pasta" == *"2000000 bytes"* ]] || falhar "Não mediu 2000000 bytes da pasta"
[[ "$saida_pasta" == *"0.28%"* ]] || falhar "Cálculo da pasta divergiu de 0.28%"
passou "Entrada como diretório BACKUP_DIR localiza e avalia o pacote .tar.age"

# -----------------------------------------------------------------------------
echo "▸ 8. Entradas inválidas (falha fechada com código 2)"
# -----------------------------------------------------------------------------
# 8.1 Arquivo inexistente
set +e
msg_inv1=$("$SCRIPT" "$DIR_TEMP/arquivo_que_nao_existe.tar.age" 2>&1)
cod_inv1=$?
set -e
[[ "$cod_inv1" -eq 2 ]] || falhar "Arquivo inexistente deveria sair 2, saiu $cod_inv1"
[[ "$msg_inv1" == *"ERRO: Alvo inválido"* ]] || falhar "Mensagem de arquivo inexistente incorreta"

# 8.2 Pasta sem backup
pasta_vazia="$DIR_TEMP/pasta_vazia"
mkdir -p "$pasta_vazia"
set +e
msg_inv2=$("$SCRIPT" "$pasta_vazia" 2>&1)
cod_inv2=$?
set -e
[[ "$cod_inv2" -eq 2 ]] || falhar "Pasta vazia deveria sair 2, saiu $cod_inv2"
[[ "$msg_inv2" == *"Nenhum arquivo de backup cifrado"* ]] || falhar "Mensagem de pasta vazia incorreta"

# 8.3 Retenção não numérica ou <= 0
set +e
msg_inv3=$("$SCRIPT" 100000 0 10 2>&1)
cod_inv3=$?
msg_inv4=$("$SCRIPT" 100000 "quatorze" 10 2>&1)
cod_inv4=$?
set -e
[[ "$cod_inv3" -eq 2 ]] || falhar "Retenção 0 deveria sair 2, saiu $cod_inv3"
[[ "$msg_inv3" == *"Quantidade de retenção inválida"* ]] || falhar "Mensagem de retenção 0 incorreta"
[[ "$cod_inv4" -eq 2 ]] || falhar "Retenção texto deveria sair 2, saiu $cod_inv4"
[[ "$msg_inv4" == *"Quantidade de retenção inválida"* ]] || falhar "Mensagem de retenção texto incorreta"

# 8.4 Limite não numérico ou <= 0
set +e
msg_inv5=$("$SCRIPT" 100000 14 -5 2>&1)
cod_inv5=$?
msg_inv6=$("$SCRIPT" 100000 14 "dez_gb" 2>&1)
cod_inv6=$?
msg_inv7=$("$SCRIPT" 100000 14 0 2>&1)
cod_inv7=$?
set -e
[[ "$cod_inv5" -eq 2 ]] || falhar "Limite negativo deveria sair 2, saiu $cod_inv5"
[[ "$msg_inv5" == *"Limite de armazenamento inválido"* ]] || falhar "Mensagem de limite negativo incorreta"
[[ "$cod_inv6" -eq 2 ]] || falhar "Limite texto deveria sair 2, saiu $cod_inv6"
[[ "$msg_inv6" == *"Limite de armazenamento inválido"* ]] || falhar "Mensagem de limite texto incorreta"
[[ "$cod_inv7" -eq 2 ]] || falhar "Limite zero deveria sair 2, saiu $cod_inv7"
[[ "$msg_inv7" == *"Limite de armazenamento deve ser maior que zero"* ]] || falhar "Mensagem de limite zero incorreta"

# 8.5 Arquivo vazio (0 bytes)
arq_vazio="$DIR_TEMP/vazio.tar.age"
touch "$arq_vazio"
set +e
msg_inv8=$("$SCRIPT" "$arq_vazio" 2>&1)
cod_inv8=$?
set -e
[[ "$cod_inv8" -eq 2 ]] || falhar "Arquivo vazio deveria sair 2, saiu $cod_inv8"
[[ "$msg_inv8" == *"arquivo vazio"* ]] || falhar "Mensagem de arquivo vazio incorreta"

passou "Todas as 8 variações de entrada inválida falharam fechadas com código 2"

# -----------------------------------------------------------------------------
echo "▸ 9. Resiliência sem GITHUB_STEP_SUMMARY"
# -----------------------------------------------------------------------------
saida_sem_summary=$(
  unset GITHUB_STEP_SUMMARY
  "$SCRIPT" 38797312 14 10
)
[[ "$saida_sem_summary" == *"5.43%"* ]] || falhar "Falhou execução sem GITHUB_STEP_SUMMARY"
passou "Execução sem GITHUB_STEP_SUMMARY concluída sem erros"

# -----------------------------------------------------------------------------
echo "▸ 10. Suporte a limites com casas decimais (ex: 0.5 GB = 500 MB)"
# -----------------------------------------------------------------------------
# 38.797.312 * 14 = 543.162.368 bytes (~543.2 MB)
# Com limite de 0.5 GB (500 MB), a projeção é > 100% -> crítico (exit 1)
set +e
saida_frac=$("$SCRIPT" 38797312 14 0.5 2>&1)
cod_frac=$?
set -e
[[ "$cod_frac" -eq 1 ]] || falhar "Limite de 0.5 GB deveria falhar com 1, saiu $cod_frac"
[[ "$saida_frac" == *"108.63%"* ]] || falhar "Cálculo com limite decimal 0.5 GB incorreto"
passou "Limite configurado com número decimal processado com precisão"

echo
echo "✓ Todos os $casos casos de teste passaram com sucesso (100% verde)."
exit 0
