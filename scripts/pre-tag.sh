#!/usr/bin/env bash
# Portão local de conferência pré-tag para o frila-backend.
#
# Executa 5 conferências obrigatórias antes de qualquer corte ou publicação
# de tag no frila-prod (RNF12 e padrões operacionais do projeto):
#   1. Ancestralidade: a tag (ou commit alvo) DEVE ser ancestral de origin/develop (sem fallback para HEAD silencioso).
#   2. Janela RNF12: não permite corte dentro da janela proibida (quinta a domingo, 16h-02h SP).
#   3. CHANGELOG: a versão semântica da tag deve estar documentada no commit alvo (git show <commit>:CHANGELOG.md).
#   4. Migrações imutáveis: nenhuma migração já existente em origin/main pode ter sido alterada (sem falso verde).
#   5. Migrações sem colisão: nenhuma migração com timestamp duplicado ou formato inválido.
#
# SOMENTE LOCAL / LEITURA: sem token, sem rede ao Prod.
#
# Uso:
#   ./scripts/pre-tag.sh <tag>
#   ./scripts/pre-tag.sh --commit <sha> <tag>
set -uo pipefail

DIR_RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$DIR_RAIZ/scripts"

COMMIT_ALVO=""
BASE_DEVELOP="origin/develop"
BASE_MAIN="origin/main"
CHANGELOG_OVERRIDE=""
TAG_NOME=""

# Parse de argumentos
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      echo "Uso: $0 [opções] <tag>"
      echo ""
      echo "Opções:"
      echo "  --commit <sha>     Commit alvo a conferir (obrigatório se a tag ainda não existir no git)"
      echo "  --base <ref>       Branch base de desenvolvimento (padrão: origin/develop)"
      echo "  --main <ref>       Branch base de produção (padrão: origin/main)"
      echo "  --changelog <arq>  Arquivo de changelog alternativo (override para testes)"
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
      CHANGELOG_OVERRIDE="$2"
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

# Resolução do Commit Alvo (SEM fallback silencioso para HEAD)
if [ -z "$COMMIT_ALVO" ]; then
  if git rev-parse --verify --quiet "$TAG_NOME^{commit}" >/dev/null 2>&1; then
    COMMIT_ALVO=$(git rev-parse "$TAG_NOME^{commit}")
  else
    echo "✗ Tag '$TAG_NOME' não encontrada como ref git." >&2
    echo "  Especifique o commit com '--commit <sha>' ou crie a tag antes de conferir." >&2
    exit 2
  fi
else
  if ! git rev-parse --verify --quiet "$COMMIT_ALVO^{commit}" >/dev/null 2>&1; then
    echo "✗ Commit '$COMMIT_ALVO' informado em --commit é inválido ou inexistente." >&2
    exit 2
  fi
  COMMIT_ALVO=$(git rev-parse "$COMMIT_ALVO^{commit}")
fi

echo "=================================================="
echo "▸ Conferência pré-tag: $TAG_NOME (versão $VERSAO)"
echo "▸ Commit alvo: $COMMIT_ALVO"
echo "=================================================="

# ─────────────────────────────────────────────────────────────
# 1. Checagem de Ancestralidade estritamente contra origin/develop
# ─────────────────────────────────────────────────────────────
if ! git rev-parse --verify --quiet "$BASE_DEVELOP^{commit}" >/dev/null 2>&1; then
  # Tenta buscar silenciosamente do remoto se não estiver em cache
  git fetch --quiet origin "${BASE_DEVELOP#origin/}" 2>/dev/null || true
fi

if ! git rev-parse --verify --quiet "$BASE_DEVELOP^{commit}" >/dev/null 2>&1; then
  echo "✗ [1/5] Erro de configuração: branch base '$BASE_DEVELOP' não encontrada no git." >&2
  exit 2
fi

REF_BASE_DEV=$(git rev-parse "$BASE_DEVELOP^{commit}")

if ! git merge-base --is-ancestor "$COMMIT_ALVO" "$REF_BASE_DEV"; then
  echo "✗ [1/5] Ancestralidade: commit $COMMIT_ALVO NÃO é ancestral de $BASE_DEVELOP." >&2
  echo "  Apenas código já integrado à develop pode virar tag de produção." >&2
  exit 1
fi
echo "✓ [1/5] Ancestralidade: commit $COMMIT_ALVO é ancestral de $BASE_DEVELOP."

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
# 3. CHANGELOG com a versão semântica NO COMMIT ALVO
# ─────────────────────────────────────────────────────────────
CONTEUDO_CHANGELOG=""
if [ -n "$CHANGELOG_OVERRIDE" ]; then
  if [ ! -f "$CHANGELOG_OVERRIDE" ]; then
    echo "✗ [3/5] Arquivo CHANGELOG especificado não existe: $CHANGELOG_OVERRIDE" >&2
    exit 2
  fi
  CONTEUDO_CHANGELOG=$(cat "$CHANGELOG_OVERRIDE")
else
  # Lê o CHANGELOG.md exatamente como ele existe no commit alvo
  CONTEUDO_CHANGELOG=$(git show "$COMMIT_ALVO:CHANGELOG.md" 2>/dev/null || true)
  if [ -z "$CONTEUDO_CHANGELOG" ]; then
    echo "✗ [3/5] CHANGELOG: arquivo CHANGELOG.md não encontrado no commit $COMMIT_ALVO." >&2
    exit 1
  fi
fi

if ! printf '%s\n' "$CONTEUDO_CHANGELOG" | grep -qE "^## \[[vV]?${VERSAO}\]"; then
  echo "✗ [3/5] CHANGELOG: versão [$VERSAO] não encontrada no CHANGELOG do commit $COMMIT_ALVO." >&2
  echo "  Antes de cortar a tag, documente a versão sob '## [$VERSAO] - AAAA-MM-DD'." >&2
  exit 1
fi
echo "✓ [3/5] CHANGELOG: versão [$VERSAO] documentada no commit alvo."

# ─────────────────────────────────────────────────────────────
# 4. Migrações imutáveis contra origin/main (SEM FALSO VERDE)
# ─────────────────────────────────────────────────────────────
if ! git rev-parse --verify --quiet "$BASE_MAIN^{commit}" >/dev/null 2>&1; then
  git fetch --quiet origin "${BASE_MAIN#origin/}" 2>/dev/null || true
fi

if ! git rev-parse --verify --quiet "$BASE_MAIN^{commit}" >/dev/null 2>&1; then
  echo "✗ [4/5] Migrações imutáveis: ref '$BASE_MAIN' não encontrada no git. Impossível auditar imutabilidade." >&2
  exit 2
fi

REF_BASE_MAIN=$(git rev-parse "$BASE_MAIN^{commit}")

# Audita se o commit alvo modificou ou removeu alguma migração já existente em main
MIGRACOES_EDITADAS=$(git diff --name-only --diff-filter=MD "$REF_BASE_MAIN"...$COMMIT_ALVO -- supabase/migrations/ 2>/dev/null || true)

if [ -n "$MIGRACOES_EDITADAS" ]; then
  echo "✗ [4/5] Migrações imutáveis: migração já existente em $BASE_MAIN foi modificada ou removida no commit alvo:" >&2
  echo "$MIGRACOES_EDITADAS" | sed 's/^/    /' >&2
  echo "  Migração aplicada é imutável. Qualquer correção deve entrar como nova migração." >&2
  exit 1
fi
echo "✓ [4/5] Migrações imutáveis: nenhuma migração de $BASE_MAIN foi violada no commit alvo."

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
echo "  Commit $COMMIT_ALVO está apto para a tag $TAG_NOME."
echo "=================================================="
exit 0
