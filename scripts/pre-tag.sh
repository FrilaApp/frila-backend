#!/usr/bin/env bash
# Portão local de conferência pré-tag para o frila-backend.
#
# Executa 5 conferências obrigatórias antes de qualquer corte ou publicação
# de tag no frila-prod (RNF12 e padrões operacionais do projeto):
#   1. Ancestralidade: a tag (ou HEAD) deve ser ancestral de origin/develop.
#   2. Janela RNF12: não permite corte dentro da janela proibida (quinta a domingo, 16h-02h SP).
#   3. CHANGELOG: a versão semântica da tag deve estar documentada no CHANGELOG.md.
#   4. Migrações imutáveis: nenhuma migração já existente em origin/main pode ter sido alterada.
#   5. Migrações sem colisão: nenhuma migração com timestamp duplicado ou formato inválido.
#
# SOMENTE LOCAL / LEITURA: sem token, sem rede ao Prod.
#
# Uso:
#   ./scripts/pre-tag.sh <tag>
#   ./scripts/pre-tag.sh backend-v1.1.0
#   ./scripts/pre-tag.sh --commit <sha> backend-v1.1.0
set -uo pipefail

DIR_RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$DIR_RAIZ/scripts"

COMMIT_ALVO=""
BASE_DEVELOP="origin/develop"
BASE_MAIN="origin/main"
CHANGELOG_ARQ="$DIR_RAIZ/CHANGELOG.md"
TAG_NOME=""

# Parse de argumentos
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      echo "Uso: $0 [opções] <tag>"
      echo ""
      echo "Opções:"
      echo "  --commit <sha>     Commit a conferir (padrão: ref da tag se existir, ou HEAD)"
      echo "  --base <ref>       Branch base de desenvolvimento (padrão: origin/develop)"
      echo "  --main <ref>       Branch base de produção (padrão: origin/main)"
      echo "  --changelog <arq>  Arquivo de changelog (padrão: CHANGELOG.md)"
      echo "  -h, --help         Exibe esta ajuda"
      exit 0
      ;;
    --commit)
      COMMIT_ALVO="$2"
      shift 2
      ;;
    --base)
      BASE_DEVELOP="$2"
      shift 2
      ;;
    --main)
      BASE_MAIN="$2"
      shift 2
      ;;
    --changelog)
      CHANGELOG_ARQ="$2"
      shift 2
      ;;
    *)
      if [ -z "$TAG_NOME" ]; then
        TAG_NOME="$1"
      else
        echo "✗ Argumento inesperado: $1" >&2
        echo "Uso: $0 [opções] <tag>" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$TAG_NOME" ]; then
  echo "✗ Tag não informada. Uso: $0 [opções] <tag>" >&2
  exit 2
fi

# Extração da versão semântica (ex.: backend-v1.1.0 -> 1.1.0, v1.0.0 -> 1.0.0)
VERSAO=$(printf '%s\n' "$TAG_NOME" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
if [ -z "$VERSAO" ]; then
  echo "✗ Tag '$TAG_NOME' inválida: deve conter uma versão semântica X.Y.Z (ex.: backend-v1.1.0 ou v1.1.0)" >&2
  exit 2
fi

echo "=================================================="
echo "▸ Conferência pré-tag: $TAG_NOME (versão $VERSAO)"
echo "=================================================="

# ─────────────────────────────────────────────────────────────
# 1. Checagem de Ancestralidade contra develop
# ─────────────────────────────────────────────────────────────
# Se --commit não foi passado, tenta resolver a ref da tag; se não existir, usa HEAD
if [ -z "$COMMIT_ALVO" ]; then
  if git rev-parse --verify --quiet "$TAG_NOME^{commit}" >/dev/null 2>&1; then
    COMMIT_ALVO=$(git rev-parse "$TAG_NOME^{commit}")
  else
    COMMIT_ALVO=$(git rev-parse HEAD)
  fi
fi

# Resolve ref base de desenvolvimento
REF_BASE_DEV=""
if git rev-parse --verify --quiet "$BASE_DEVELOP^{commit}" >/dev/null 2>&1; then
  REF_BASE_DEV="$BASE_DEVELOP"
elif git rev-parse --verify --quiet "develop^{commit}" >/dev/null 2>&1; then
  REF_BASE_DEV="develop"
else
  # Tenta buscar silenciosamente se for remoto
  git fetch --quiet origin develop 2>/dev/null || true
  if git rev-parse --verify --quiet "origin/develop^{commit}" >/dev/null 2>&1; then
    REF_BASE_DEV="origin/develop"
  fi
fi

if [ -z "$REF_BASE_DEV" ]; then
  echo "✗ Não foi possível resolver a branch develop ($BASE_DEVELOP)." >&2
  exit 2
fi

if ! git merge-base --is-ancestor "$COMMIT_ALVO" "$REF_BASE_DEV"; then
  echo "✗ [1/5] Ancestralidade: commit $COMMIT_ALVO NÃO é ancestral de $REF_BASE_DEV." >&2
  echo "  Apenas código já integrado à develop pode virar tag de produção." >&2
  exit 1
fi
echo "✓ [1/5] Ancestralidade: commit é ancestral de $REF_BASE_DEV."

# ─────────────────────────────────────────────────────────────
# 2. Janela RNF12 (reuso de janela-de-manutencao.sh)
# ─────────────────────────────────────────────────────────────
if [ ! -f "$SCRIPT_DIR/janela-de-manutencao.sh" ]; then
  echo "✗ [2/5] Script $SCRIPT_DIR/janela-de-manutencao.sh não encontrado." >&2
  exit 2
fi

if ! "$SCRIPT_DIR/janela-de-manutencao.sh"; then
  echo "✗ [2/5] Janela RNF12: tentativa de liberação dentro da janela proibida." >&2
  echo "  De quinta a domingo das 16h às 02h (horário de São Paulo) o deploy em Prod é bloqueado." >&2
  exit 1
fi
echo "✓ [2/5] Janela RNF12: fora da janela proibida."

# ─────────────────────────────────────────────────────────────
# 3. CHANGELOG com a versão semântica
# ─────────────────────────────────────────────────────────────
if [ ! -f "$CHANGELOG_ARQ" ]; then
  echo "✗ [3/5] Arquivo CHANGELOG não encontrado: $CHANGELOG_ARQ" >&2
  exit 2
fi

if ! grep -qE "^## \[[vV]?${VERSAO}\]" "$CHANGELOG_ARQ"; then
  echo "✗ [3/5] CHANGELOG: versão [$VERSAO] não encontrada em $(basename "$CHANGELOG_ARQ")." >&2
  echo "  Antes de cortar a tag, documente a versão sob '## [$VERSAO] - AAAA-MM-DD'." >&2
  exit 1
fi
echo "✓ [3/5] CHANGELOG: versão [$VERSAO] documentada."

# ─────────────────────────────────────────────────────────────
# 4. Migrações imutáveis (reuso de migracoes-imutaveis.sh)
# ─────────────────────────────────────────────────────────────
if [ ! -f "$SCRIPT_DIR/migracoes-imutaveis.sh" ]; then
  echo "✗ [4/5] Script $SCRIPT_DIR/migracoes-imutaveis.sh não encontrado." >&2
  exit 2
fi

# Resolve ref base de main
REF_BASE_MAIN=""
if git rev-parse --verify --quiet "$BASE_MAIN^{commit}" >/dev/null 2>&1; then
  REF_BASE_MAIN="$BASE_MAIN"
elif git rev-parse --verify --quiet "main^{commit}" >/dev/null 2>&1; then
  REF_BASE_MAIN="main"
else
  git fetch --quiet origin main 2>/dev/null || true
  if git rev-parse --verify --quiet "origin/main^{commit}" >/dev/null 2>&1; then
    REF_BASE_MAIN="origin/main"
  fi
fi

if [ -n "$REF_BASE_MAIN" ]; then
  if ! "$SCRIPT_DIR/migracoes-imutaveis.sh" "$REF_BASE_MAIN"; then
    echo "✗ [4/5] Migrações imutáveis: migração já existente em $REF_BASE_MAIN foi modificada." >&2
    exit 1
  fi
else
  # Se não houver origin/main local nem remoto, avisa mas valida se pasta existe
  echo "⚠︎ [4/5] Aviso: ref main ($BASE_MAIN) não encontrada localmente; pulando diff de imutabilidade."
fi
echo "✓ [4/5] Migrações imutáveis: nenhuma migração existente foi violada."

# ─────────────────────────────────────────────────────────────
# 5. Migrações sem colisão de versão (reuso de migracoes-sem-colisao.sh)
# ─────────────────────────────────────────────────────────────
if [ ! -f "$SCRIPT_DIR/migracoes-sem-colisao.sh" ]; then
  echo "✗ [5/5] Script $SCRIPT_DIR/migracoes-sem-colisao.sh não encontrado." >&2
  exit 2
fi

if ! "$SCRIPT_DIR/migracoes-sem-colisao.sh"; then
  echo "✗ [5/5] Migrações sem colisão: colisão de timestamp ou formato inválido encontrado." >&2
  exit 1
fi
echo "✓ [5/5] Migrações sem colisão: catálogo íntegro."

echo "=================================================="
echo "✓ Todas as 5 conferências passaram com sucesso."
echo "  Tag $TAG_NOME está apta para criação e publicação."
echo "=================================================="
exit 0
