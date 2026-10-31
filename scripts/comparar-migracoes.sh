#!/usr/bin/env bash
# Compara as versões de migrações registradas no Prod contra as migrações da branch develop.
#
# REGRA FUNDAMENTAL: SÓ LEITURA, 100% LOCAL, SEM REDE, SEM TOKEN.
# Transforma as instruções manuais do passo 2 de diagnostico-prod-leia-me.md em script auditado.
#
# Uso:
#   ./scripts/comparar-migracoes.sh <arquivo-com-versoes-do-prod>
#   ./scripts/comparar-migracoes.sh --commit <ref> <arquivo-com-versoes-do-prod>
#
# Códigos de Saída:
#   0: Catálogo íntegro (liberado para a tag ou 100% atualizado, zero anomalias no Prod)
#   1: Catálogo com divergência, anomalias no Prod ou catálogo vazio
#   2: Erro de uso (parâmetro ausente, arquivo inexistente ou referência inválida)
set -uo pipefail

REF="${FRILA_REF:-origin/develop}"

if [ "${1:-}" = "--commit" ]; then
  if [ -z "${2:-}" ]; then
    echo "✗ Erro: Parâmetro --commit informado sem referência." >&2
    echo "Uso: $0 [--commit <ref>] <arquivo-com-versoes-do-prod>" >&2
    exit 2
  fi
  REF="$2"
  shift 2
fi

ARQUIVO_PROD="${1:-}"

if [ -z "$ARQUIVO_PROD" ]; then
  echo "✗ Erro: Arquivo de versões do Prod não informado." >&2
  echo "Uso: $0 [--commit <ref>] <arquivo-com-versoes-do-prod>" >&2
  echo "Exemplo: $0 /tmp/prod_versoes.txt" >&2
  exit 2
fi

if [ ! -f "$ARQUIVO_PROD" ]; then
  echo "✗ Erro: Arquivo '$ARQUIVO_PROD' não encontrado." >&2
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

tmp_dev="$TMP/develop_migrations.txt"
tmp_prod="$TMP/prod_versoes.txt"
tmp_coincidentes="$TMP/coincidentes.txt"
tmp_faltam="$TMP/faltam.txt"
tmp_anomalias="$TMP/anomalias.txt"

# 1. Carrega as versões canônicas da referência informada (ou fallback local)
if git rev-parse --verify "$REF^{commit}" >/dev/null 2>&1; then
  git ls-tree -r --name-only "$REF:supabase/migrations" 2>/dev/null \
    | sed -En 's/^([0-9]{14})_.*/\1/p' | sort -u > "$tmp_dev"
elif [ -d "supabase/migrations" ]; then
  # Fallback para diretório de trabalho se git ls-tree falhar
  ls -1 supabase/migrations | sed -En 's/^([0-9]{14})_.*/\1/p' | sort -u > "$tmp_dev"
else
  echo "✗ Erro: Não foi possível obter o catálogo de migrações na referência '$REF'." >&2
  exit 2
fi

total_dev=$(wc -l < "$tmp_dev" | tr -d ' ')

if [ "$total_dev" -eq 0 ]; then
  echo "✗ Erro: Nenhuma migração encontrada na referência '$REF:supabase/migrations'." >&2
  exit 2
fi

# 2. Higieniza e extrai as versões (14 dígitos) do arquivo do Prod
grep -oE '\b[0-9]{14}\b' "$ARQUIVO_PROD" | sort -u > "$tmp_prod" || true

total_prod=$(wc -l < "$tmp_prod" | tr -d ' ')

if [ "$total_prod" -eq 0 ]; then
  echo "=========================================================================="
  echo "RELATÓRIO DE COMPARAÇÃO DE MIGRAÇÕES (PROD vs DEVELOP)"
  echo "=========================================================================="
  echo "Referência do repositório: $REF ($total_dev migrações registradas)"
  echo "Arquivo informado do Prod: $ARQUIVO_PROD (0 versões válidas de 14 dígitos)"
  echo "=========================================================================="
  echo "✗ VEREDITO: BLOQUEIO TOTAL — CATÁLOGO VAZIO OU NÃO RECONHECIDO (exit 1)"
  echo "Motivo: O arquivo do Prod está vazio ou não contém carimbos numéricos válidos."
  echo "Ação necessária: Extraia a lista executando o Bloco 1 de diagnostico-prod.sql."
  exit 1
fi

# 3. Comparações direcionais via comm
comm -12 "$tmp_dev" "$tmp_prod" > "$tmp_coincidentes"
comm -23 "$tmp_dev" "$tmp_prod" > "$tmp_faltam"
comm -13 "$tmp_dev" "$tmp_prod" > "$tmp_anomalias"

total_coincidentes=$(wc -l < "$tmp_coincidentes" | tr -d ' ')
total_faltam=$(wc -l < "$tmp_faltam" | tr -d ' ')
total_anomalias=$(wc -l < "$tmp_anomalias" | tr -d ' ')

# 4. Exibição do relatório em PT-BR
echo "=========================================================================="
echo "RELATÓRIO DE COMPARAÇÃO DE MIGRAÇÕES (PROD vs DEVELOP)"
echo "=========================================================================="
echo "Referência do repositório: $REF ($total_dev migrações registradas)"
echo "Arquivo de versões do Prod: $ARQUIVO_PROD ($total_prod versões encontradas)"
echo "Total de versões coincidentes: $total_coincidentes"
echo ""

if [ "$total_faltam" -gt 0 ]; then
  echo "1. Migrações na develop que FALTAM no Prod ($total_faltam pendências para a tag aplicar):"
  sed 's/^/   -> /' "$tmp_faltam"
else
  echo "1. Migrações na develop que FALTAM no Prod: nenhuma (0 pendências)."
fi
echo ""

if [ "$total_anomalias" -gt 0 ]; then
  echo "2. [!] ANOMALIA: Migrações no Prod que NÃO EXISTEM na develop ($total_anomalias versões desconhecidas):"
  sed 's/^/   [!] /' "$tmp_anomalias"
  echo ""
  echo "   ATENÇÃO: Carimbos desconhecidos em produção indicam migrações renomeadas,"
  echo "   patches manuais aplicados por fora ou corrupção no catálogo de metadados."
else
  echo "2. Migrações no Prod que NÃO EXISTEM na develop: nenhuma (0 anomalias)."
fi
echo "=========================================================================="

# 5. Análise de prefixo contínuo, buraco no meio e limite de pendências
buracos_no_meio=0
maior_prod=$(tail -n 1 "$tmp_prod" || echo "00000000000000")

# Se alguma migração faltante for mais antiga que a maior já aplicada no Prod, há um buraco no meio
while read -r v_falta; do
  [ -z "$v_falta" ] && continue
  if [ "$v_falta" -lt "$maior_prod" ]; then
    buracos_no_meio=$((buracos_no_meio + 1))
  fi
done < "$tmp_faltam"

# 6. Veredito e código de saída
if [ "$total_anomalias" -gt 0 ]; then
  echo "✗ VEREDITO: BLOQUEIO TOTAL — NÃO DISPARAR A TAG (exit 1)"
  echo "Motivo: Foram encontradas $total_anomalias anomalias no catálogo do Prod."
  echo "Ação necessária: Investigar a origem desses carimbos antes de qualquer deploy automático."
  exit 1
elif [ "$total_coincidentes" -eq 0 ]; then
  echo "✗ VEREDITO: BLOQUEIO TOTAL — CATÁLOGO NÃO SINCRONIZADO (exit 1)"
  echo "Motivo: Nenhuma migração coincidente encontrada entre o Prod e a develop."
  echo "Ação necessária: O dono deve rodar reparo de metadados ('supabase migration repair --status applied')."
  exit 1
elif [ "$buracos_no_meio" -gt 0 ]; then
  echo "✗ VEREDITO: BLOQUEIO TOTAL — BURACO NO MEIO DETECTADO (exit 1)"
  echo "Motivo: Há $buracos_no_meio migração(ões) pendente(s) mais antiga(s) que a versão mais recente aplicada no Prod ($maior_prod)."
  echo "Ação necessária: O histórico de migrações está descontínuo. Não aplique deploys automáticos sem sincronizar a sequência."
  exit 1
elif [ "$total_coincidentes" -lt 119 ]; then
  echo "✗ VEREDITO: BLOQUEIO TOTAL — CATÁLOGO INCOMPLETO (exit 1)"
  echo "Motivo: O Prod possui apenas $total_coincidentes migração(ões) coincidente(s) (esperado mínimo de 119 da versão 1.0.0)."
  echo "Ação necessária: O catálogo do Prod está defasado ou não sincronizado ($total_faltam pendências). Execute o reparo de metadados."
  exit 1
elif [ "$total_coincidentes" -eq 119 ] && [ "$total_faltam" -eq 4 ]; then
  echo "✓ VEREDITO: LIBERADO PARA A TAG (exit 0)"
  echo "Diagnóstico: Catálogo íntegro e perfeitamente alinhado com a release."
  echo "O Prod possui as 119 migrações base da v1.0.0; o deploy aplicará as 4 pendentes esperadas."
  exit 0
elif [ "$total_faltam" -eq 0 ] && [ "$total_anomalias" -eq 0 ]; then
  echo "✓ VEREDITO: 100% ATUALIZADO (exit 0)"
  echo "Diagnóstico: O ambiente já possui todas as $total_dev migrações da develop aplicadas."
  exit 0
elif [ "$total_faltam" -gt 4 ]; then
  echo "✗ VEREDITO: BLOQUEIO TOTAL — LIMITE DE PENDÊNCIAS EXCEDIDO (exit 1)"
  echo "Motivo: Há $total_faltam migrações pendentes no Prod (máximo esperado para a tag é 4)."
  echo "Ação necessária: Investigue a defasagem da base antes de prosseguir."
  exit 1
else
  echo "✓ VEREDITO: LIBERADO (exit 0)"
  echo "Diagnóstico: $total_coincidentes coincidentes, $total_faltam pendentes, zero anomalias."
  exit 0
fi
