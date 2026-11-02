#!/usr/bin/env bash
# Autoteste automatizado do script `scripts/comparar-migracoes.sh`.
#
# REGRA FUNDAMENTAL: 100% LOCAL, SEM REDE, SEM TOKEN.
# Exercita todos os cenários com listas sintéticas, o catálogo real da main e develop, e casos de borda.
#
# Uso:
#   ./scripts/teste-comparar-migracoes.sh
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DIR_RAIZ="$PWD"
PORTAO="$DIR_RAIZ/scripts/comparar-migracoes.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ── Fixture: Criação de Repositório Git Sintético e Isolado ─────
# O autoteste não depende de branches ou da contagem flutuante do repositório remoto real.
# Cria um repositório git local em $TMP/repo_sintetico com:
#   - origin/main: 119 migrações base da v1.0.0
#   - origin/develop: 123 migrações canônicas (119 base + 4 pendentes da release)
REPO_SINTETICO="$TMP/repo_sintetico"
mkdir -p "$REPO_SINTETICO/supabase/migrations"
cd "$REPO_SINTETICO" || exit 1
git init -q

# 119 migrações da base (todas as migrações até 20261020180000, exceto as 4 da release)
for f in "$DIR_RAIZ"/supabase/migrations/*.sql; do
  b=$(basename "$f")
  ts="${b:0:14}"
  if [ "$ts" -le "20261020180000" ]; then
    case "$ts" in
      20261018050000|20261020100000|20261020150000|20261020180000)
        ;;
      *)
        touch "supabase/migrations/$b"
        ;;
    esac
  fi
done

git add supabase/migrations
git -c user.name="Teste" -c user.email="teste@frila.app" commit -q -m "Base 119 migracoes (origin/main)"
COMMIT_BASE=$(git rev-parse HEAD)

# 4 migrações pendentes adicionadas para compor a develop (total 123)
for f in "$DIR_RAIZ"/supabase/migrations/*.sql; do
  b=$(basename "$f")
  ts="${b:0:14}"
  case "$ts" in
    20261018050000|20261020100000|20261020150000|20261020180000)
      touch "supabase/migrations/$b"
      ;;
  esac
done

git add supabase/migrations
git -c user.name="Teste" -c user.email="teste@frila.app" commit -q -m "Develop 123 migracoes (origin/develop)"
COMMIT_DEV=$(git rev-parse HEAD)

git update-ref refs/remotes/origin/main "$COMMIT_BASE"
git update-ref refs/remotes/origin/develop "$COMMIT_DEV"

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

conferir "flag --base sem argumento sai com código 2" \
  2 "Parâmetro --base informado sem referência" \
  "$PORTAO" --base

conferir "flag --pendentes-esperadas sem valor sai com código 2" \
  2 "Parâmetro --pendentes-esperadas informado sem valor" \
  "$PORTAO" --pendentes-esperadas

conferir "flag --pendentes-esperadas com valor não numérico sai com código 2" \
  2 "--pendentes-esperadas deve ser um número inteiro" \
  "$PORTAO" --pendentes-esperadas abc "$TMP/dummy.txt"

conferir "arquivo inexistente sai com código 2" \
  2 "não encontrado" \
  "$PORTAO" "$TMP/arquivo_que_nao_existe.txt"

# ── 2. Arquivo vazio ou sem versões ────────────────────────────
touch "$TMP/vazio.txt"
conferir "arquivo vazio reprova com código 1" \
  1 "BLOQUEIO TOTAL — CATÁLOGO VAZIO" \
  "$PORTAO" "$TMP/vazio.txt"

cat << 'INTERN' > "$TMP/texto_sem_numeros.txt"
versao
inserted_at
coluna_qualquer
(0 rows)
INTERN
conferir "arquivo sem nenhuma versão numérica reprova com código 1" \
  1 "BLOQUEIO TOTAL — CATÁLOGO VAZIO" \
  "$PORTAO" "$TMP/texto_sem_numeros.txt"

# ── Extração das listas canônicas da main e develop ────────────
git ls-tree -r --name-only origin/main:supabase/migrations 2>/dev/null \
  | sed -En 's/^([0-9]{14})_.*/\1/p' | sort -u > "$TMP/todas_main.txt"

git ls-tree -r --name-only origin/develop:supabase/migrations 2>/dev/null \
  | sed -En 's/^([0-9]{14})_.*/\1/p' | sort -u > "$TMP/todas_develop.txt"

total_main=$(wc -l < "$TMP/todas_main.txt" | tr -d ' ')
total_dev=$(wc -l < "$TMP/todas_develop.txt" | tr -d ' ')

# ── 3. Cenário REAL: Prod = origin/main (develop menos as 4 pendentes) ──
# No estado real, o Prod possui as 119 migrações da main.
# develop possui 123 migrações (incluindo 20261018050000 que tem timestamp anterior a migrações da main).
cp "$TMP/todas_main.txt" "$TMP/prod_real_119.txt"

conferir "estado real (develop menos as 4) com 4 esperadas => exit 0 (CATÁLOGO DE MIGRAÇÕES OK)" \
  0 "CATÁLOGO DE MIGRAÇÕES OK (só esta conferência; falta agendador_secret, janela e aprovação)" \
  "$PORTAO" --pendentes-esperadas 4 "$TMP/prod_real_119.txt"

conferir "estado real sem flag reprova com exit 1 pedindo --pendentes-esperadas 4" \
  1 "informe explicitamente '--pendentes-esperadas 4'" \
  "$PORTAO" "$TMP/prod_real_119.txt"

conferir "estado real com 5 esperadas => exit 1 (DIVERGÊNCIA NAS PENDÊNCIAS ESPERADAS)" \
  1 "DIVERGÊNCIA NAS PENDÊNCIAS ESPERADAS" \
  "$PORTAO" --pendentes-esperadas 5 "$TMP/prod_real_119.txt"

conferir "estado real lista exatamente as 4 pendências reais da develop" \
  0 "4 pendências para a tag aplicar" \
  "$PORTAO" --pendentes-esperadas 4 "$TMP/prod_real_119.txt"

conferir "estado real identifica 20261018050000 como pendência sem acusar falso buraco no meio" \
  0 "20261018050000" \
  "$PORTAO" --pendentes-esperadas 4 "$TMP/prod_real_119.txt"

# ── 4. Casos de Catálogo Incompleto da Base (1 versão e 60 versões) ────
head -n 1 "$TMP/todas_main.txt" > "$TMP/prod_1_versao.txt"
conferir "Prod com 1 versão da main reprova com exit 1 (CATÁLOGO INCOMPLETO EM RELAÇÃO À BASE)" \
  1 "BLOQUEIO TOTAL — CATÁLOGO INCOMPLETO EM RELAÇÃO À BASE" \
  "$PORTAO" "$TMP/prod_1_versao.txt"

conferir "Prod com 1 versão da main e --pendentes-esperadas 4 reprova com exit 1" \
  1 "BLOQUEIO TOTAL — CATÁLOGO INCOMPLETO EM RELAÇÃO À BASE" \
  "$PORTAO" --pendentes-esperadas 4 "$TMP/prod_1_versao.txt"

head -n 60 "$TMP/todas_main.txt" > "$TMP/prod_60_versoes.txt"
conferir "Prod com 60 versões da main reprova com exit 1 (CATÁLOGO INCOMPLETO EM RELAÇÃO À BASE)" \
  1 "BLOQUEIO TOTAL — CATÁLOGO INCOMPLETO EM RELAÇÃO À BASE" \
  "$PORTAO" "$TMP/prod_60_versoes.txt"

conferir "Prod com 60 versões da main e --pendentes-esperadas 4 reprova com exit 1" \
  1 "BLOQUEIO TOTAL — CATÁLOGO INCOMPLETO EM RELAÇÃO À BASE" \
  "$PORTAO" --pendentes-esperadas 4 "$TMP/prod_60_versoes.txt"

# ── 5. Caso de Buraco no Meio de Versões DA MAIN ─────────────────
# Remove a versão da linha 50 da main
sed '50d' "$TMP/todas_main.txt" > "$TMP/prod_buraco_main.txt"
conferir "Prod com buraco no meio de versões DA MAIN reprova com exit 1 sem flag" \
  1 "BLOQUEIO TOTAL — BURACO NO MEIO DETECTADO NA BASE" \
  "$PORTAO" "$TMP/prod_buraco_main.txt"

conferir "Prod com buraco no meio de versões DA MAIN reprova com exit 1 mesmo com --pendentes-esperadas 5" \
  1 "BLOQUEIO TOTAL — BURACO NO MEIO DETECTADO NA BASE" \
  "$PORTAO" --pendentes-esperadas 5 "$TMP/prod_buraco_main.txt"

# ── 6. Cenário com Versão Fora da Develop (Anomalia) ─────────────
cp "$TMP/prod_real_119.txt" "$TMP/prod_anomalia.txt"
echo "99991231235959" >> "$TMP/prod_anomalia.txt"
sort "$TMP/prod_anomalia.txt" -o "$TMP/prod_anomalia.txt"

conferir "versão fora da develop acusa anomalia e reprova com exit 1" \
  1 "BLOQUEIO TOTAL — NÃO DISPARAR A TAG" \
  "$PORTAO" --pendentes-esperadas 4 "$TMP/prod_anomalia.txt"

conferir "versão fora da develop identifica o carimbo estranho no relatório" \
  1 "99991231235959" \
  "$PORTAO" --pendentes-esperadas 4 "$TMP/prod_anomalia.txt"

# ── 7. Cenário Específico da Migração Renomeada ─────────────────
# Caso real: 20261015160000 (nome de rascunho) x 20261020180000 (nome oficial no PR #185)
cp "$TMP/prod_real_119.txt" "$TMP/prod_renomeada.txt"
echo "20261015160000" >> "$TMP/prod_renomeada.txt"
sort "$TMP/prod_renomeada.txt" -o "$TMP/prod_renomeada.txt"

conferir "migração renomeada fora da develop acusa anomalia (exit 1)" \
  1 "20261015160000" \
  "$PORTAO" --pendentes-esperadas 4 "$TMP/prod_renomeada.txt"

# ── 8. Cenário 100% atualizado (123 coincidentes com develop) ───
cp "$TMP/todas_develop.txt" "$TMP/prod_123.txt"
conferir "cenário 100% atualizado sem flag passa com exit 0" \
  0 "100% ATUALIZADO" \
  "$PORTAO" "$TMP/prod_123.txt"

conferir "cenário 100% atualizado com --pendentes-esperadas 0 passa com exit 0" \
  0 "100% ATUALIZADO" \
  "$PORTAO" --pendentes-esperadas 0 "$TMP/prod_123.txt"

conferir "cenário 100% atualizado com --pendentes-esperadas 4 reprova com exit 1 (divergência)" \
  1 "DIVERGÊNCIA NAS PENDÊNCIAS ESPERADAS" \
  "$PORTAO" --pendentes-esperadas 4 "$TMP/prod_123.txt"

# ── 9. Resiliência a formato de cópia do Supabase SQL Editor ───
cat << 'INTERN' > "$TMP/prod_sujo.txt"
versao | inserted_at
---------------------
"20260922150000" | 2026-09-22 15:00:00+00
"20260922150100" | 2026-09-22 15:01:00+00
"20260922150200" | 2026-09-22 15:02:00+00

(3 rows)
INTERN
conferir "resiliência: linhas com aspas, pipes e cabeçalhos são sanitizadas (3 encontradas)" \
  1 "3 versões encontradas" \
  "$PORTAO" "$TMP/prod_sujo.txt"

# ── 10. Suporte às flags --base e --commit explícitas ───────────
conferir "flags explícitas --base origin/main e --commit origin/develop com --pendentes-esperadas 4 passam com exit 0" \
  0 "Referência base (produção v1.0.0): origin/main" \
  "$PORTAO" --base origin/main --commit origin/develop --pendentes-esperadas 4 "$TMP/prod_real_119.txt"

echo
if [ "$falhas" -ne 0 ]; then
  echo "Total de falhas: $falhas de $casos casos." >&2
  exit 1
fi
echo "Todos os $casos casos passaram com sucesso (100% verde)."
exit 0
