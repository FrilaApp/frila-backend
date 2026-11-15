#!/usr/bin/env bash
# Monitoramento e projeção de limite de armazenamento do backup do frila-prod.
#
# Contexto e RNF12:
# O backup diário envia dumps cifrados (.tar.age) para storage compatível com S3
# (Cloudflare R2 ou Backblaze B2, ambos com cota gratuita de 10 GB).
# Como a credencial S3 do GitHub Actions possui privilégio mínimo Write-Only (somente PutObject),
# não é possível listar o bucket via ListObjects para medir o volume total armazenado.
#
# Este script avalia o tamanho do dump recém-gerado, calcula a projeção acumulada
# multiplicando pela retenção (BACKUP_KEEP, padrão 14 dias), compara com a cota
# (BACKUP_LIMITE_GB, padrão 10 GB) e emite alertas no GitHub Actions:
#   - < 50%: Informativo, exit 0 (status seguro).
#   - >= 50% e < 80%: ::warning::, exit 0 (alerta preventivo de consumo).
#   - >= 80%: ::error::, exit 1 (falha proposital do job para alertar vigia/equipe).
#
# Uso:
#   ./scripts/verifica-limite-backup.sh <arquivo|diretorio|tamanho_bytes> [backup_keep] [limite_gb]
#
# Exemplos:
#   ./scripts/verifica-limite-backup.sh "$BACKUP_DIR"
#   ./scripts/verifica-limite-backup.sh /caminho/frila-backup-20261104.tar.age 14 10
#   ./scripts/verifica-limite-backup.sh 38797312 14 10

set -Eeuo pipefail

ALVO="${1:?uso: verifica-limite-backup.sh <arquivo|diretorio|tamanho_bytes> [backup_keep] [limite_gb]}"
KEEP_ARG="${2:-}"
LIMITE_ARG="${3:-}"

# 1. Resolução do alvo (arquivo, diretório ou número direto de bytes)
TAMANHO_BYTES=0
NOME_ALVO=""

if [[ -f "$ALVO" ]]; then
  TAMANHO_BYTES=$(wc -c < "$ALVO" | tr -d '[:space:]')
  NOME_ALVO=$(basename "$ALVO")
elif [[ -d "$ALVO" ]]; then
  ARQ_ENCONTRADO=$(find "$ALVO" -maxdepth 1 \( -name "frila-backup-*.tar.age" -o -name "*.tar.age" -o -name "*.dump.age" \) -type f | head -n 1)
  if [[ -z "$ARQ_ENCONTRADO" || ! -f "$ARQ_ENCONTRADO" ]]; then
    echo "ERRO: Nenhum arquivo de backup cifrado (.tar.age) encontrado no diretório '$ALVO'." >&2
    exit 2
  fi
  TAMANHO_BYTES=$(wc -c < "$ARQ_ENCONTRADO" | tr -d '[:space:]')
  NOME_ALVO=$(basename "$ARQ_ENCONTRADO")
elif [[ "$ALVO" =~ ^[0-9]+$ ]]; then
  TAMANHO_BYTES="$ALVO"
  NOME_ALVO="tamanho_manual"
else
  echo "ERRO: Alvo inválido '$ALVO'. Forneça um caminho de arquivo existente, diretório com backup, ou tamanho em bytes." >&2
  exit 2
fi

if [[ "$TAMANHO_BYTES" -le 0 ]]; then
  echo "ERRO: Tamanho do dump inválido ou arquivo vazio ($TAMANHO_BYTES bytes)." >&2
  exit 2
fi

# 2. Resolução do parâmetro de retenção (BACKUP_KEEP)
KEEP="${KEEP_ARG:-${BACKUP_KEEP:-14}}"
if [[ ! "$KEEP" =~ ^[0-9]+$ ]] || [[ "$KEEP" -le 0 ]]; then
  echo "ERRO: Quantidade de retenção inválida '$KEEP'. Deve ser um número inteiro positivo." >&2
  exit 2
fi

# 3. Resolução da cota limite em GB (BACKUP_LIMITE_GB)
LIMITE_GB="${LIMITE_ARG:-${BACKUP_LIMITE_GB:-10}}"
if [[ ! "$LIMITE_GB" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "ERRO: Limite de armazenamento inválido '$LIMITE_GB'. Deve ser um número positivo em GB." >&2
  exit 2
fi

if awk -v lim="$LIMITE_GB" 'BEGIN { exit (lim > 0 ? 0 : 1) }'; then
  : # Limite válido
else
  echo "ERRO: Limite de armazenamento deve ser maior que zero (recebido '$LIMITE_GB')." >&2
  exit 2
fi

# 4. Cálculo de projeção, percentuais e formatação via awk (padrão 1 GB = 10^9 bytes)
IFS=$'\t' read -r DUMP_HUMANO PROJ_BYTES PROJ_HUMANO LIMITE_BYTES LIMITE_HUMANO PORCENTAGEM STATUS_CODIGO STATUS_NOME < <(
  awk -v b="$TAMANHO_BYTES" -v k="$KEEP" -v g="$LIMITE_GB" '
  function humano(bytes) {
    if (bytes < 1000) return sprintf("%d B", bytes);
    if (bytes < 1000000) return sprintf("%.1f KB", bytes / 1000);
    if (bytes < 1000000000) return sprintf("%.1f MB", bytes / 1000000);
    return sprintf("%.2f GB", bytes / 1000000000);
  }
  BEGIN {
    proj = b * k;
    lim = g * 1000000000;
    pct = (proj / lim) * 100;

    # 0 = OK (< 50%), 1 = AVISO (50% a < 80%), 2 = CRITICO (>= 80%)
    if (pct < 50.0) {
      status_cod = 0;
      status_nome = "OK";
    } else if (pct < 80.0) {
      status_cod = 1;
      status_nome = "AVISO";
    } else {
      status_cod = 2;
      status_nome = "CRITICO";
    }

    printf "%s\t%d\t%s\t%d\t%s\t%.2f\t%d\t%s\n", humano(b), proj, humano(proj), lim, humano(lim), pct, status_cod, status_nome;
  }'
)

# 5. Emissão de relatório legível na saída padrão
echo "=== Monitoramento de Armazenamento do Backup (Storage R2 / B2) ==="
echo "Alvo avaliado:              $NOME_ALVO"
echo "Tamanho do dump enviado:    $DUMP_HUMANO ($TAMANHO_BYTES bytes)"
echo "Retenção configurada:       $KEEP backups (BACKUP_KEEP)"
echo "Projeção total no bucket:   $PROJ_HUMANO ($PROJ_BYTES bytes)"
echo "Limite de armazenamento:    $LIMITE_HUMANO ($LIMITE_BYTES bytes, BACKUP_LIMITE_GB=$LIMITE_GB)"
echo "Consumo projetado da cota:  ${PORCENTAGEM}%"
echo "Status do armazenamento:    $STATUS_NOME"
echo "=================================================================="

# 6. Registro no GitHub Step Summary (se disponível)
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  STATUS_LABEL="✓ Seguro (< 50% da cota)"
  if [[ "$STATUS_CODIGO" -eq 1 ]]; then
    STATUS_LABEL="⚠️ Alerta: Projeção atingiu ${PORCENTAGEM}% (>= 50% da cota)"
  elif [[ "$STATUS_CODIGO" -eq 2 ]]; then
    STATUS_LABEL="🚨 Falha Crítica: Projeção atingiu ${PORCENTAGEM}% (>= 80% da cota)"
  fi

  {
    echo "### Monitoramento de Limite de Armazenamento do Backup (Storage R2 / B2)"
    echo
    echo "| Métrica | Valor |"
    echo "|---|---|"
    echo "| Arquivo avaliado | \`$NOME_ALVO\` |"
    echo "| Tamanho do dump enviado | $DUMP_HUMANO (\`$TAMANHO_BYTES\` bytes) |"
    echo "| Retenção (BACKUP_KEEP) | $KEEP backups |"
    echo "| Projeção acumulada no storage | $PROJ_HUMANO (\`$PROJ_BYTES\` bytes) |"
    echo "| Limite configurado (BACKUP_LIMITE_GB) | $LIMITE_HUMANO (\`$LIMITE_BYTES\` bytes) |"
    echo "| Consumo projetado da cota | **${PORCENTAGEM}%** |"
    echo "| Veredito | $STATUS_LABEL |"
    echo
  } >> "$GITHUB_STEP_SUMMARY" || true
fi

# 7. Tratamento de limites, anotações de Actions e saída de código
if [[ "$STATUS_CODIGO" -eq 1 ]]; then
  echo "::warning::Projeção de armazenamento do backup (${PORCENTAGEM}% de ${LIMITE_HUMANO}) atingiu o limiar de alerta (>= 50%). Avalie aumentar cota ou reduzir retenção."
  exit 0
elif [[ "$STATUS_CODIGO" -eq 2 ]]; then
  echo "::error::Projeção de armazenamento do backup (${PORCENTAGEM}% de ${LIMITE_HUMANO}) atingiu o limiar crítico (>= 80%). Risco de esgotar a cota gratuita do storage."
  exit 1
fi

echo "✓ Projeção de armazenamento de backup dentro do limite de segurança (< 50%)."
exit 0
