#!/usr/bin/env bash
# A ponte do quadro não duplica fato, e respeita etiqueta e autor.
#
# Roda sem rede e sem credencial: a entrada vem de uma fixture no mesmo formato que a API
# do Trello devolve (`BANCADA_TRELLO_FIXTURE`). Um teste que chamasse a API de verdade
# mediria o quadro de hoje, que muda, em vez de medir a ponte.
#
# O vault também é de mentira: uma pasta temporária com os scripts do vault vivo e um
# `05 - Registros/` vazio. Assim o teste exercita a porta de escrita de verdade
# (`registrar-fato.sh`) sem tocar no acervo de ninguém.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

falhas=0
ok()    { printf '  ✓ %s\n' "$1"; }
falha() { printf '  ✗ %s\n' "$1" >&2; falhas=$((falhas+1)); }

# ── O vault de mentira ────────────────────────────────────────────────────────
vault_vivo="$(python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "scripts"))
from bancada_trello import achar_vault
print(achar_vault(None, os.getcwd()))
PY
)" || { echo "✗ não achei o vault vivo para copiar os scripts" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
VAULT="$TMP/doc-harness"
mkdir -p "$VAULT/scripts" "$VAULT/05 - Registros" "$VAULT/02 - Atualizações Diárias"
cp "$vault_vivo/scripts/registrar-fato.sh" "$vault_vivo/scripts/lib.sh" "$VAULT/scripts/"
chmod +x "$VAULT/scripts/registrar-fato.sh"
cp "$vault_vivo/02 - Atualizações Diárias/Template - Atualização Diária.md" \
   "$VAULT/02 - Atualizações Diárias/" 2>/dev/null || true

FIXTURE="$TMP/quadro.json"
cat > "$FIXTURE" <<'JSON'
{
  "cards": [
    {"shortLink": "aaa11111", "name": "S2 · Backend · Cartão de teste da ponte",
     "idList": "L1", "labels": [{"name": "Backend"}, {"name": "Sprint 2"}]},
    {"shortLink": "bbb22222", "name": "S2 · iOS · Cartão que não é de Backend",
     "idList": "L1", "labels": [{"name": "iOS"}]},
    {"shortLink": "ccc33333", "name": "S0 · Backend · Cartão já registrado à mão",
     "idList": "L2", "labels": [{"name": "Backend"}]}
  ],
  "actions": [
    {"id": "acao0001", "type": "updateCard", "date": "2026-10-15T13:10:00.000Z",
     "memberCreator": {"username": "matheussilva95408964", "fullName": "Matheus Silva"},
     "data": {"card": {"shortLink": "aaa11111", "name": "S2 · Backend · Cartão de teste da ponte"},
              "listBefore": {"name": "Em andamento"}, "listAfter": {"name": "Revisão"}}},
    {"id": "acao0002", "type": "commentCard", "date": "2026-10-15T14:20:00.000Z",
     "memberCreator": {"username": "cauecarneiroc", "fullName": "Cauê Carneiro"},
     "data": {"card": {"shortLink": "aaa11111"}, "text": "PR aberto: https://example.invalid/pr/1"}},
    {"id": "acao0003", "type": "updateCard", "date": "2026-10-15T15:30:00.000Z",
     "memberCreator": {"username": "joaopauloalbuquerque7", "fullName": "João Paulo"},
     "data": {"card": {"shortLink": "bbb22222", "name": "S2 · iOS · Cartão que não é de Backend"},
              "listBefore": {"name": "Em andamento"}, "listAfter": {"name": "Concluído 🎉"}}},
    {"id": "acao0004", "type": "updateCard", "date": "2026-10-15T16:40:00.000Z",
     "memberCreator": {"username": "cauecarneiroc", "fullName": "Cauê Carneiro"},
     "data": {"card": {"shortLink": "ccc33333", "name": "S0 · Backend · Cartão já registrado à mão"},
              "listBefore": {"name": "Revisão"}, "listAfter": {"name": "Concluído 🎉"}}}
  ]
}
JSON

# A linha que uma pessoa escreveu antes desta ponte existir, no formato antigo: cita o
# cartão e o destino, e não tem id de ação. A segunda guarda da ponte tem de reconhecê-la.
"$VAULT/scripts/registrar-fato.sh" externo 2026-10-15 16:40 "Cauê Carneiro" entrega \
  "cartao ccc33333 movido para Concluido no quadro: S0 · Backend · Cartão já registrado à mão" \
  >/dev/null

fatos() { grep -rh '^- `' "$VAULT/05 - Registros" 2>/dev/null | grep -c . || true; }
com_id() { grep -rh "trello:$1" "$VAULT/05 - Registros" 2>/dev/null | grep -c . || true; }

ponte() {
  BANCADA_TRELLO_FIXTURE="$FIXTURE" python3 scripts/bancada_trello.py \
    --vault "$VAULT" --desde 2026-10-15 --ate 2026-10-15 --sem-t25 "$@"
}

antes=$(fatos)
[ "$antes" = "1" ] || falha "o vault de teste devia começar com 1 fato (o escrito à mão), tem $antes"

# ── 1. Primeira passagem ──────────────────────────────────────────────────────
saida=$(ponte 2>&1) || falha "primeira passagem saiu diferente de 0"
depois=$(fatos)
if [ "$depois" = "3" ]; then
  ok "primeira passagem: 2 fatos novos (1 movimento + 1 comentário de Backend)"
else
  falha "esperava 3 fatos depois da primeira passagem, tem $depois"
  printf '%s\n' "$saida" | sed 's/^/      /'
fi

[ "$(com_id acao0001)" = "1" ] || falha "o movimento do cartão de Backend não foi registrado"
[ "$(com_id acao0002)" = "1" ] || falha "o comentário do cartão de Backend não foi registrado"
[ "$(com_id acao0003)" = "0" ] || falha "registrou cartão sem etiqueta Backend sem --todas-etiquetas"
[ "$(com_id acao0004)" = "0" ] || falha "duplicou o movimento que já estava registrado à mão"
ok "a guarda do registro antigo (sem id de ação) pulou acao0004"

# ── 2. Segunda passagem: zero duplicata ───────────────────────────────────────
saida2=$(ponte 2>&1) || falha "segunda passagem saiu diferente de 0"
depois2=$(fatos)
if [ "$depois2" = "$depois" ]; then
  ok "segunda passagem no mesmo intervalo: 0 fato novo ($depois2 continua $depois)"
else
  falha "a segunda passagem mudou o log: $depois → $depois2"
  printf '%s\n' "$saida2" | sed 's/^/      /'
fi
printf '%s\n' "$saida2" | grep -q "0 fato(s) novo(s), 3 já registrado(s)" \
  && ok "a saída diz 0 novos e 3 já registrados (o cartão de iOS nem entra: é filtrado pela etiqueta)" \
  || falha "a saída da segunda passagem não confirma os 3 já registrados"

for id in acao0001 acao0002; do
  n=$(com_id "$id")
  [ "$n" = "1" ] || falha "$id aparece $n vezes no log depois de duas passagens"
done
ok "cada id de ação aparece exatamente uma vez"

# ── 3. Etiqueta e autor ───────────────────────────────────────────────────────
ponte --todas-etiquetas >/dev/null 2>&1
[ "$(com_id acao0003)" = "1" ] \
  && ok "--todas-etiquetas registra o cartão de iOS" \
  || falha "--todas-etiquetas não registrou o cartão de iOS"

TMP2="$TMP/segundo"; VAULT2="$TMP2/doc-harness"
mkdir -p "$VAULT2/scripts" "$VAULT2/05 - Registros"
cp "$vault_vivo/scripts/registrar-fato.sh" "$vault_vivo/scripts/lib.sh" "$VAULT2/scripts/"
chmod +x "$VAULT2/scripts/registrar-fato.sh"
BANCADA_TRELLO_FIXTURE="$FIXTURE" python3 scripts/bancada_trello.py \
  --vault "$VAULT2" --desde 2026-10-15 --ate 2026-10-15 --sem-t25 \
  --todas-etiquetas --autor "Cauê" >/dev/null 2>&1
so_caue=$(grep -rh '^- `' "$VAULT2/05 - Registros" | grep -c . || true)
sem_caue=$(grep -rh '^- `' "$VAULT2/05 - Registros" | grep -vc 'Cauê Carneiro' || true)
if [ "$so_caue" = "2" ] && [ "$sem_caue" = "0" ]; then
  ok "--autor Cauê registra só as 2 ações dele"
else
  falha "--autor trouxe $so_caue fatos, $sem_caue de outra pessoa"
fi

# ── 4. Intervalo fora do fato ─────────────────────────────────────────────────
TMP3="$TMP/terceiro"; VAULT3="$TMP3/doc-harness"
mkdir -p "$VAULT3/scripts" "$VAULT3/05 - Registros"
cp "$vault_vivo/scripts/registrar-fato.sh" "$vault_vivo/scripts/lib.sh" "$VAULT3/scripts/"
chmod +x "$VAULT3/scripts/registrar-fato.sh"
BANCADA_TRELLO_FIXTURE="$FIXTURE" python3 scripts/bancada_trello.py \
  --vault "$VAULT3" --desde 2026-10-01 --ate 2026-10-02 --sem-t25 --todas-etiquetas >/dev/null 2>&1
n3=$(grep -rh '^- `' "$VAULT3/05 - Registros" 2>/dev/null | grep -c . || true)
[ "$n3" = "0" ] \
  && ok "intervalo sem ação nenhuma não escreve fato" \
  || falha "intervalo vazio escreveu $n3 fato(s)"

# ── 5. A hora é a do fuso do quadro, não a do UTC ─────────────────────────────
grep -rh "trello:acao0001" "$VAULT/05 - Registros" | grep -q '^- `10:10`' \
  && ok "13:10Z entra no log como 10:10, no fuso do quadro" \
  || falha "a hora registrada não foi convertida para o fuso do quadro"

echo
if [ "$falhas" -eq 0 ]; then
  echo "✓ ponte do quadro: todos os casos verdes"
  exit 0
fi
echo "✗ ponte do quadro: $falhas caso(s) vermelho(s)" >&2
exit 1
