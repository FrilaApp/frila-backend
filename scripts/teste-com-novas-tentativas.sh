#!/usr/bin/env bash
# Teste de scripts/com-novas-tentativas.sh (bash puro, sem rede, sem espera de verdade).
#
# Casos:
#   1. Comando que passa de primeira: rc 0, 1 chamada, nenhuma espera.
#   2. Comando que falha 2x e passa na 3ª: rc 0, 3 chamadas, esperas 15 e 30.
#   3. Comando que sempre falha: rc != 0 só depois do teto (4 chamadas), esperas 15/30/60,
#      mensagem clara de que esgotou.
#   4. Teto e espera inicial configuráveis por variável.
#   5. O código de saída do último erro é preservado.
#   6. Sem comando: erro de uso (rc 2).
#
# A espera é injetável: COM_NOVAS_TENTATIVAS_DORMIR aponta para um programa que só registra o
# tempo pedido, então o teste roda em segundos.

set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/com-novas-tentativas.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "ERRO: '$SCRIPT' não existe ou não é executável." >&2
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

falhas=0
ok() { echo "  ✓ $1"; }
falha() { echo "  ✗ $1" >&2; falhas=$((falhas + 1)); }

confere() { # descrição esperado obtido
  if [[ "$2" == "$3" ]]; then ok "$1 (= $2)"; else falha "$1: esperado '$2', obtido '$3'"; fi
}

# Espera falsa: registra o argumento e volta na hora.
cat > "$DIR_TEMP/dormir" <<'SH'
#!/usr/bin/env bash
echo "$1" >> "$ESPERAS_ARQ"
SH
chmod +x "$DIR_TEMP/dormir"

# Comando de teste: conta as chamadas e falha nas N primeiras (FALHAR_ATE; 999 = sempre falha).
cat > "$DIR_TEMP/cmd" <<'SH'
#!/usr/bin/env bash
n=$(( $(cat "$CHAMADAS_ARQ" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$CHAMADAS_ARQ"
if (( n <= FALHAR_ATE )); then exit "${CODIGO_FALHA:-1}"; fi
exit 0
SH
chmod +x "$DIR_TEMP/cmd"

export CHAMADAS_ARQ="$DIR_TEMP/chamadas"
export ESPERAS_ARQ="$DIR_TEMP/esperas"
export COM_NOVAS_TENTATIVAS_DORMIR="$DIR_TEMP/dormir"

rodar() { # FALHAR_ATE [variáveis extras...]; guarda rc, saída, chamadas e esperas
  local falhar_ate="$1"; shift
  rm -f "$CHAMADAS_ARQ" "$ESPERAS_ARQ"
  : > "$ESPERAS_ARQ"
  set +e
  SAIDA=$(env FALHAR_ATE="$falhar_ate" "$@" "$SCRIPT" "$DIR_TEMP/cmd" 2>&1)
  RC=$?
  set -e
  CHAMADAS=$(cat "$CHAMADAS_ARQ" 2>/dev/null || echo 0)
  ESPERAS=$(paste -sd, "$ESPERAS_ARQ")
}

echo "▸ 1. Passa de primeira"
rodar 0
confere "rc" 0 "$RC"
confere "chamadas" 1 "$CHAMADAS"
confere "esperas" "" "$ESPERAS"

echo "▸ 2. Falha 2x e passa na 3ª"
rodar 2
confere "rc" 0 "$RC"
confere "chamadas" 3 "$CHAMADAS"
confere "esperas" "15,30" "$ESPERAS"

echo "▸ 3. Sempre falha: rc != 0 só depois do teto"
rodar 999
if [[ "$RC" -ne 0 ]]; then ok "rc != 0 (= $RC)"; else falha "rc deveria ser != 0"; fi
confere "chamadas" 4 "$CHAMADAS"
confere "esperas" "15,30,60" "$ESPERAS"
if grep -q "esgotou" <<<"$SAIDA"; then ok "mensagem diz que esgotou"; else falha "sem mensagem 'esgotou': $SAIDA"; fi

echo "▸ 4. Teto e espera inicial por variável"
rodar 999 COM_NOVAS_TENTATIVAS_MAX=2 COM_NOVAS_TENTATIVAS_ESPERA=5
confere "chamadas" 2 "$CHAMADAS"
confere "esperas" "5" "$ESPERAS"

echo "▸ 5. Preserva o código de saída do último erro"
rodar 999 CODIGO_FALHA=7
confere "rc" 7 "$RC"

echo "▸ 6. Sem comando: erro de uso"
set +e
"$SCRIPT" >/dev/null 2>&1
RC=$?
set -e
confere "rc" 2 "$RC"

echo
if [[ "$falhas" -gt 0 ]]; then
  echo "FALHOU: $falhas verificação(ões)." >&2
  exit 1
fi
echo "OK: com-novas-tentativas passou em todos os casos."
