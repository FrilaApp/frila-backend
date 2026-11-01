#!/usr/bin/env bash
# O laço de recuperação registra o dia certo, filtra por autor e não duplica.
#
# Usa o histórico de verdade deste repositório — é o que o laço lê — mas escreve num vault
# temporário, apontado por `BANCADA_DIR`. O acervo de ninguém é tocado.
#
# A data do caso é fixa de propósito: 2026-10-01 tem commit de três pessoas, então serve
# para provar que o filtro filtra. Se o histórico for reescrito a ponto de a data esvaziar,
# o teste diz isso em vez de passar calado.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

DIA=2026-10-01
falhas=0
ok()    { printf '  ✓ %s\n' "$1"; }
falha() { printf '  ✗ %s\n' "$1" >&2; falhas=$((falhas+1)); }

vault_vivo="$(python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "scripts"))
from bancada_trello import achar_vault
print(achar_vault(None, os.getcwd()))
PY
)" || { echo "✗ não achei o vault vivo para copiar os scripts" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

novo_vault() { # novo_vault <caminho>
  local v="$1"
  mkdir -p "$v/scripts" "$v/05 - Registros" "$v/02 - Atualizações Diárias"
  cp "$vault_vivo/scripts/registrar-fato.sh" "$vault_vivo/scripts/lib.sh" "$v/scripts/"
  chmod +x "$v/scripts/registrar-fato.sh"
  cp "$vault_vivo/02 - Atualizações Diárias/Template - Atualização Diária.md" \
     "$v/02 - Atualizações Diárias/"
}

fatos() { grep -rh '^- `' "$1/05 - Registros" 2>/dev/null | grep -c . || true; }

# O `bancada-sync.sh` trata hora, autor e assunto iguais no mesmo dia como o mesmo
# trabalho (`mesmo_trabalho`), porque é o que um rebase ou um cherry-pick preserva. Então
# o esperado não é a contagem de commits: é a de triplas distintas. Medido em 2026-10-01:
# 46 commits viram 44 fatos, e 16 do Matheus viram 15, porque `chore: __pycache__ fora do
# git` aparece duas vezes às 10:35.
commits_do_dia() { # commits_do_dia [autor]
  git log --branches --no-merges --format='%aI%x09%an%x09%s' \
    | awk -F '\t' -v dia="$DIA" -v autor="${1:-}" \
        'substr($1,1,10)==dia && (autor=="" || index(tolower($2), tolower(autor))>0) \
         { print substr($1,12,5) "\t" $2 "\t" $3 }' \
    | sort -u | grep -c . || true
}

esperado_matheus=$(commits_do_dia Matheus)
esperado_todos=$(commits_do_dia)
if [ "$esperado_matheus" -eq 0 ] || [ "$esperado_todos" -le "$esperado_matheus" ]; then
  echo "✗ o caso precisa de $DIA com commit do Matheus e de outra pessoa;" >&2
  echo "  medido agora: $esperado_matheus do Matheus, $esperado_todos no total" >&2
  exit 1
fi
echo "  caso: $DIA tem $esperado_todos trabalhos distintos, $esperado_matheus do Matheus"

# ── 1. Com filtro de autor ────────────────────────────────────────────────────
V1="$TMP/um/doc-harness"; novo_vault "$V1"
BANCADA_DIR="$V1" ./scripts/bancada-recuperar.sh --desde "$DIA" --ate "$DIA" --autor Matheus >/dev/null 2>&1
n1=$(fatos "$V1")
if [ "$n1" = "$esperado_matheus" ]; then
  ok "registrou os $n1 commits do Matheus em $DIA"
else
  falha "esperava $esperado_matheus fatos, registrou $n1"
fi
de_outros=$(grep -rh '^- `' "$V1/05 - Registros" | grep -vc 'Matheus Silva' || true)
[ "$de_outros" = "0" ] \
  && ok "nenhum fato de outra pessoa entrou com --autor Matheus" \
  || falha "$de_outros fato(s) de outra pessoa entraram apesar do filtro"

# ── 2. Segunda passagem: zero duplicata ───────────────────────────────────────
BANCADA_DIR="$V1" ./scripts/bancada-recuperar.sh --desde "$DIA" --ate "$DIA" --autor Matheus >/dev/null 2>&1
n2=$(fatos "$V1")
[ "$n2" = "$n1" ] \
  && ok "segunda passagem no mesmo dia: 0 fato novo ($n2 continua $n1)" \
  || falha "a segunda passagem mudou o log: $n1 → $n2"

# ── 3. Sem filtro, entra o time todo ──────────────────────────────────────────
V2="$TMP/dois/doc-harness"; novo_vault "$V2"
BANCADA_DIR="$V2" ./scripts/bancada-recuperar.sh --desde "$DIA" --ate "$DIA" >/dev/null 2>&1
n3=$(fatos "$V2")
if [ "$n3" -gt "$n1" ]; then
  ok "sem --autor entram $n3 fatos, contra $n1 com o filtro"
else
  falha "sem filtro deveria registrar mais que $n1, registrou $n3"
fi

# ── 4. O fato cai no arquivo do dia, não no de hoje ───────────────────────────
arq="$V1/05 - Registros/${DIA:0:4}/${DIA:5:2}/$DIA.md"
[ -f "$arq" ] \
  && ok "o fato foi para o arquivo de $DIA" \
  || falha "não há arquivo de fatos para $DIA em $V1"
hoje="$V1/05 - Registros/$(date +%Y)/$(date +%m)/$(date +%Y-%m-%d).md"
[ ! -f "$hoje" ] \
  && ok "nada foi lançado no dia de hoje" \
  || falha "o laço lançou fato no dia de hoje: $hoje"

# ── 5. Data inválida é recusada ───────────────────────────────────────────────
if BANCADA_DIR="$V1" ./scripts/bancada-recuperar.sh --desde 01-10-2026 >/dev/null 2>&1; then
  falha "aceitou data em formato inesperado"
else
  ok "recusa data fora de AAAA-MM-DD"
fi

echo
if [ "$falhas" -eq 0 ]; then
  echo "✓ laço de recuperação: todos os casos verdes"
  exit 0
fi
echo "✗ laço de recuperação: $falhas caso(s) vermelho(s)" >&2
exit 1
