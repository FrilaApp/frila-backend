#!/usr/bin/env bash
# A ponte diária não pode anunciar "nenhum fato novo" quando uma das duas pernas
# (recuperação de commits, chamada do Trello) falhou de verdade. Falha silenciosa
# aqui é o buraco que o próprio PR da ponte automática foi feito pra fechar.
#
# Dubla as duas pernas (`bancada-recuperar.sh` e `bancada-trello.sh`) com stubs cujo
# código de saída é controlado por variável de ambiente, e roda o orquestrador real
# (`bancada-ponte-diaria.sh`, sem cópia nem edição) contra um projeto e um vault de
# mentira. Nenhum fato é escrito em nenhum dos casos — o que varia é só o exit code
# das pernas, que é exatamente o que o achado do portão ANBU apontou como engolido.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO="$PWD"

falhas=0
ok()    { printf '  ✓ %s\n' "$1"; }
falha() { printf '  ✗ %s\n' "$1" >&2; falhas=$((falhas+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Vault de mentira: só precisa existir e parecer vivo para o achar_vault. ──────
VAULT="$TMP/vault"
mkdir -p "$VAULT/05 - Registros" "$VAULT/scripts"
printf '#!/usr/bin/env bash\ntrue\n' > "$VAULT/scripts/registrar-fato.sh"
chmod +x "$VAULT/scripts/registrar-fato.sh"

# ── Projeto de mentira: o orquestrador real, as duas pernas dubladas. ────────────
PROJ="$TMP/proj"
mkdir -p "$PROJ/scripts"
cp "$REPO/scripts/bancada-ponte-diaria.sh" "$PROJ/scripts/"
cp "$REPO/scripts/bancada_trello.py" "$PROJ/scripts/"
chmod +x "$PROJ/scripts/bancada-ponte-diaria.sh"

cat > "$PROJ/scripts/bancada-recuperar.sh" <<'STUB'
#!/usr/bin/env bash
echo "  (stub recuperar) $*"
exit "${FAKE_RECUPERAR_EXIT:-0}"
STUB
cat > "$PROJ/scripts/bancada-trello.sh" <<'STUB'
#!/usr/bin/env bash
echo "  (stub trello) $*"
exit "${FAKE_TRELLO_EXIT:-0}"
STUB
chmod +x "$PROJ/scripts/bancada-recuperar.sh" "$PROJ/scripts/bancada-trello.sh"

fatos() { grep -rh '^- `' "$1/05 - Registros" 2>/dev/null | grep -c . || true; }

rodar() { # rodar <exit_recuperar> <exit_trello> -> escreve saida em $TMP/saida.txt, devolve exit code
  FAKE_RECUPERAR_EXIT="$1" FAKE_TRELLO_EXIT="$2" BANCADA_DIR="$VAULT" BANCADA_AUTOR=Matheus \
    "$PROJ/scripts/bancada-ponte-diaria.sh" >"$TMP/saida.txt" 2>&1
  echo $?
}

# ── 1. Caminho feliz: as duas pernas rodam sem erro, sem fato novo de verdade ────
cod=$(rodar 0 0)
if [ "$cod" = "0" ]; then
  ok "caminho feliz: exit 0"
else
  falha "caminho feliz: esperava exit 0, saiu $cod"
fi
if grep -q "Nenhum fato novo" "$TMP/saida.txt"; then
  ok "caminho feliz: anuncia 'Nenhum fato novo'"
else
  falha "caminho feliz: não anunciou 'Nenhum fato novo'"
fi
if [ "$(fatos "$VAULT")" = "0" ]; then
  ok "caminho feliz: nenhum fato foi escrito no vault"
else
  falha "caminho feliz: escreveu fato no vault, e não devia"
fi

# ── 2. Perna 1 (recuperação) falha de verdade ────────────────────────────────────
cod=$(rodar 1 0)
if [ "$cod" != "0" ]; then
  ok "perna 1 falha: exit não-zero ($cod)"
else
  falha "perna 1 falha: saiu 0, deveria propagar o erro"
fi
if grep -q "Nenhum fato novo" "$TMP/saida.txt"; then
  falha "perna 1 falha: anunciou 'Nenhum fato novo' escondendo o erro"
else
  ok "perna 1 falha: não anunciou 'Nenhum fato novo'"
fi
if grep -q "recuperação de commits" "$TMP/saida.txt"; then
  ok "perna 1 falha: aponta qual perna falhou"
else
  falha "perna 1 falha: não identificou a perna que falhou"
fi

# ── 3. Perna 2 (Trello) falha de verdade ─────────────────────────────────────────
cod=$(rodar 0 1)
if [ "$cod" != "0" ]; then
  ok "perna 2 falha: exit não-zero ($cod)"
else
  falha "perna 2 falha: saiu 0, deveria propagar o erro"
fi
if grep -q "Nenhum fato novo" "$TMP/saida.txt"; then
  falha "perna 2 falha: anunciou 'Nenhum fato novo' escondendo o erro"
else
  ok "perna 2 falha: não anunciou 'Nenhum fato novo'"
fi
if grep -q "quadro do Trello" "$TMP/saida.txt"; then
  ok "perna 2 falha: aponta qual perna falhou"
else
  falha "perna 2 falha: não identificou a perna que falhou"
fi

# ── 4. As duas pernas falham: continua rodando a segunda e reporta as duas ──────
cod=$(rodar 1 1)
if [ "$cod" != "0" ]; then
  ok "duas pernas falham: exit não-zero ($cod)"
else
  falha "duas pernas falham: saiu 0"
fi
if grep -q "recuperação de commits" "$TMP/saida.txt" && grep -q "quadro do Trello" "$TMP/saida.txt"; then
  ok "duas pernas falham: reporta as duas, não só a primeira"
else
  falha "duas pernas falham: não reportou as duas falhas"
fi

echo
if [ "$falhas" -eq 0 ]; then
  echo "✓ ponte diária: todos os casos verdes"
  exit 0
fi
echo "✗ ponte diária: $falhas caso(s) vermelho(s)" >&2
exit 1
