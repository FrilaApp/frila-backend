#!/usr/bin/env bash
# Compara as versões de migrações registradas no Prod contra as migrações da branch develop.
#
# REGRA FUNDAMENTAL: SÓ LEITURA, 100% LOCAL, SEM REDE, SEM TOKEN.
# Transforma as instruções manuais do passo 2 de diagnostico-prod-leia-me.md em script auditado.
#
# Uso:
#   ./scripts/comparar-migracoes.sh <arquivo-com-versoes-do-prod>
#   ./scripts/comparar-migracoes.sh --pendentes-esperadas <N> <arquivo-com-versoes-do-prod>
#   ./scripts/comparar-migracoes.sh --commit <ref> [--pendentes-esperadas <N>] <arquivo-com-versoes-do-prod>
#
# Códigos de Saída:
#   0: Catálogo íntegro como prefixo contínuo da develop (com pendências esperadas confirmadas via --pendentes-esperadas N ou 100% atualizado)
#   1: Catálogo com divergência, anomalias no Prod, catálogo vazio, buraco no meio ou pendências não confirmadas
#   2: Erro de uso (parâmetro ausente, arquivo inexistente ou referência inválida)
set -uo pipefail

REF="${FRILA_REF:-origin/develop}"
PENDENTES_ESPERADAS=""
ARQUIVO_PROD=""

while [ $# -gt 0 ]; do
  case "$1" in
    --commit)
      if [ -z "${2:-}" ]; then
        echo "✗ Erro: Parâmetro --commit informado sem referência." >&2
        echo "Uso: $0 [--commit <ref>] [--pendentes-esperadas <N>] <arquivo-com-versoes-do-prod>" >&2
        exit 2
      fi
      REF="$2"
      shift 2
      ;;
    --pendentes-esperadas)
      if [ -z "${2:-}" ]; then
        echo "✗ Erro: Parâmetro --pendentes-esperadas informado sem valor." >&2
        echo "Uso: $0 [--commit <ref>] [--pendentes-esperadas <N>] <arquivo-com-versoes-do-prod>" >&2
        exit 2
      fi
      PENDENTES_ESPERADAS="$2"
      shift 2
      ;;
    --pendentes-esperadas=*)
      PENDENTES_ESPERADAS="${1#*=}"
      shift
      ;;
    -*)
      echo "✗ Erro: Opção desconhecida: $1" >&2
      echo "Uso: $0 [--commit <ref>] [--pendentes-esperadas <N>] <arquivo-com-versoes-do-prod>" >&2
      exit 2
      ;;
    *)
      if [ -n "$ARQUIVO_PROD" ]; then
        echo "✗ Erro: Mais de um arquivo informado: '$ARQUIVO_PROD' e '$1'." >&2
        exit 2
      fi
      ARQUIVO_PROD="$1"
      shift
      ;;
  esac
done

if [ -z "$ARQUIVO_PROD" ]; then
  echo "✗ Erro: Arquivo de versões do Prod não informado." >&2
  echo "Uso: $0 [--commit <ref>] [--pendentes-esperadas <N>] <arquivo-com-versoes-do-prod>" >&2
  echo "Exemplo: $0 --pendentes-esperadas 4 /tmp/prod_versoes.txt" >&2
  exit 2
fi

if [ -n "$PENDENTES_ESPERADAS" ]; then
  if ! [[ "$PENDENTES_ESPERADAS" =~ ^[0-9]+$ ]]; then
    echo "✗ Erro: --pendentes-esperadas deve ser um número inteiro maior ou igual a zero (recebido: '$PENDENTES_ESPERADAS')." >&2
    exit 2
  fi
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
if [ -n "$PENDENTES_ESPERADAS" ]; then
  echo "Pendências esperadas pelo operador: $PENDENTES_ESPERADAS"
fi
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

# 5. Análise de prefixo contínuo e detecção de buracos
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
elif [ "$buracos_no_meio" -gt 0 ] || ! cmp -s "$tmp_prod" <(head -n "$total_prod" "$tmp_dev"); then
  echo "✗ VEREDITO: BLOQUEIO TOTAL — BURACO NO MEIO DETECTADO (exit 1)"
  echo "Motivo: O catálogo do Prod não é um prefixo contínuo da develop ($buracos_no_meio migração(ões) pendente(s) antes da versão $maior_prod)."
  echo "Ação necessária: O histórico de migrações está descontínuo. Não aplique deploys automáticos sem sincronizar a sequência."
  exit 1
elif [ "$total_faltam" -eq 0 ]; then
  if [ -n "$PENDENTES_ESPERADAS" ] && [ "$PENDENTES_ESPERADAS" -ne 0 ]; then
    echo "✗ VEREDITO: BLOQUEIO — DIVERGÊNCIA NAS PENDÊNCIAS ESPERADAS (exit 1)"
    echo "Motivo: O operador informou --pendentes-esperadas $PENDENTES_ESPERADAS, mas o Prod já possui todas as $total_dev migrações (0 pendências)."
    echo "Ação necessária: Averigue o ambiente informado antes de prosseguir."
    exit 1
  fi
  echo "✓ VEREDITO: 100% ATUALIZADO (exit 0)"
  echo "Diagnóstico: O ambiente já possui todas as $total_dev migrações da develop aplicadas."
  exit 0
elif [ -z "$PENDENTES_ESPERADAS" ]; then
  echo "✗ VEREDITO: BLOQUEIO — PENDÊNCIAS NÃO CONFIRMADAS (exit 1)"
  echo "Motivo: Há $total_faltam migrações na develop que faltam no Prod."
  echo "Ação necessária: Para liberar com pendências conhecidas, informe explicitamente '--pendentes-esperadas $total_faltam'."
  exit 1
elif [ "$PENDENTES_ESPERADAS" -ne "$total_faltam" ]; then
  echo "✗ VEREDITO: BLOQUEIO — DIVERGÊNCIA NAS PENDÊNCIAS ESPERADAS (exit 1)"
  echo "Motivo: O operador esperava $PENDENTES_ESPERADAS pendência(s), mas foram encontradas $total_faltam pendência(s) real(is)."
  echo "Ação necessária: Averigue as migrações pendentes antes de prosseguir."
  exit 1
else
  echo "✓ VEREDITO: CATÁLOGO DE MIGRAÇÕES OK (só esta conferência; falta agendador_secret, janela e aprovação) (exit 0)"
  echo "Diagnóstico: Catálogo íntegro como prefixo contínuo da develop."
  echo "O Prod possui $total_coincidentes migrações coincidentes; o deploy aplicará as $total_faltam pendentes esperadas."
  exit 0
fi
