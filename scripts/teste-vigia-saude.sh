#!/usr/bin/env bash
# scripts/teste-vigia-saude.sh
# Testes do vigia da função `saude` (scripts/vigia_saude.py; cartão bB0tV5R8).
# Sem rede externa: um servidor local faz de `saude` e de webhook do Slack. Dado sintético.
#
# Execução:
#   ./scripts/teste-vigia-saude.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ALVO="scripts/vigia_saude.py"

falhas=0
ok()    { printf '  ✓ %s\n' "$1"; }
falha() { printf '  ✗ %s\n' "$1" >&2; falhas=$((falhas+1)); }

TMP="$(mktemp -d)"
MOCK_PID=""
# shellcheck disable=SC2329
finalizar() {
  if [ -n "$MOCK_PID" ]; then kill "$MOCK_PID" 2>/dev/null || true; wait "$MOCK_PID" 2>/dev/null || true; fi
  rm -rf "$TMP"
}
trap finalizar EXIT

echo "=== Testes do vigia da saude (bB0tV5R8) ==="

# ─────────────────────────────────────────────────────────────────────────────
# Servidor de mentira: /saude responde o que o arquivo de roteiro mandar (uma linha por chamada,
# a última se repete); /slack só registra o que recebeu.
# Linhas do roteiro: "200 ok", "200 semok", "200 texto", "503 atrasado", "503 degradado", "dormir".
# ─────────────────────────────────────────────────────────────────────────────
cat >"$TMP/mock.py" <<'PY'
import json, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

roteiro_path, slack_log, porta_path = sys.argv[1:4]
trava = threading.Lock()
contador = {"n": 0}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        with trava:
            linhas = [l.strip() for l in open(roteiro_path, encoding="utf-8") if l.strip()]
            i = min(contador["n"], len(linhas) - 1)
            contador["n"] += 1
        passo = linhas[i]
        if passo == "dormir":
            time.sleep(5)
            return
        codigo, tipo = passo.split()
        corpo = {
            "ok": {"ok": True, "status": "ok"},
            "semok": {"ok": False},
            "atrasado": {"ok": False, "status": "atrasado"},
            "degradado": {"ok": False, "status": "degradado"},
        }.get(tipo)
        dados = b"pagina de erro" if tipo == "texto" else json.dumps(corpo).encode()
        self.send_response(int(codigo))
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(dados)

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        corpo = self.rfile.read(n).decode("utf-8")
        with open(slack_log, "a", encoding="utf-8") as f:
            try:
                corpo = json.dumps(json.loads(corpo), ensure_ascii=False)
            except Exception:
                pass
            f.write(corpo.replace("\n", " ") + "\n")
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
open(porta_path, "w").write(str(srv.server_port))
srv.serve_forever()
PY

: >"$TMP/roteiro"
: >"$TMP/slack.log"
python3 "$TMP/mock.py" "$TMP/roteiro" "$TMP/slack.log" "$TMP/porta" &
MOCK_PID=$!
for _ in $(seq 1 50); do [ -s "$TMP/porta" ] && break; sleep 0.1; done
PORTA="$(cat "$TMP/porta" 2>/dev/null || true)"
if [ -z "$PORTA" ]; then
  echo "✗ servidor de mentira não subiu" >&2
  exit 1
fi
URL="http://127.0.0.1:${PORTA}/saude"
SLACK="http://127.0.0.1:${PORTA}/slack"

roteiro() { printf '%s\n' "$@" >"$TMP/roteiro"; }
limpar_slack() { : >"$TMP/slack.log"; }
n_slack() { wc -l <"$TMP/slack.log" | tr -d ' '; }

# Histórico no formato da API do Actions. Uso: historico <arquivo> "<minutos atrás>:<success|failure|cancelled>" ...
# (o primeiro é o mais novo). "Agora" é 2026-11-23T12:00:00Z.
AGORA="2026-11-23T12:00:00Z"
historico() {
  local arq="$1"; shift
  python3 - "$arq" "$@" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
agora = datetime(2026, 11, 23, 12, 0, 0, tzinfo=timezone.utc)
runs = []
for i, item in enumerate(sys.argv[2:], start=1):
    minutos, conclusao = item.split(":")
    runs.append({
        "id": 1000 + i,
        "conclusion": conclusao,
        "created_at": (agora - timedelta(minutes=float(minutos))).strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
json.dump({"workflow_runs": runs}, open(sys.argv[1], "w"))
PY
}

# Roda o vigia sem esperar 60 s. Variáveis: HIST (arquivo de histórico), DRY=1 para ensaio.
rodar() {
  local extra=()
  [ -n "${HIST:-}" ] && extra+=(--historico-json "$HIST" --agora "$AGORA" --run-id 999)
  [ "${DRY:-0}" = "1" ] && extra+=(--dry-run)
  env -u SLACK_ALERTAS_WEBHOOK SLACK_WEBHOOK_URL="$SLACK" URL_SAUDE="${URL_TESTE-$URL}" \
    python3 "$ALVO" --permitir-http --espera-confirmacao 0 --timeout 1 "${extra[@]}" \
    >"$TMP/saida" 2>"$TMP/erro"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "▸ 1. Saúde boa e execução anterior boa: sai 0 e não avisa"
roteiro "200 ok"
historico "$TMP/h1" "10:success" "20:success"
HIST="$TMP/h1" rodar; cod=$?
[ "$cod" -eq 0 ] && ok "saída 0" || falha "esperava 0, veio $cod"
[ "$(n_slack)" -eq 0 ] && ok "nenhum aviso ao Slack" || falha "avisou sem motivo"

echo "▸ 2. Piscada: 1ª tentativa 503, 2ª 200 ok: não conta como queda"
roteiro "503 atrasado" "200 ok"
limpar_slack
HIST="$TMP/h1" rodar; cod=$?
[ "$cod" -eq 0 ] && ok "saída 0 (confirmação deu certo)" || falha "esperava 0, veio $cod"
[ "$(n_slack)" -eq 0 ] && ok "sem aviso na piscada" || falha "avisou numa piscada"

echo "▸ 3. Duas falhas seguidas (503 atrasado) com execução anterior boa: 1º aviso, sai 1"
roteiro "503 atrasado"
limpar_slack
HIST="$TMP/h1" rodar; cod=$?
[ "$cod" -eq 1 ] && ok "saída 1 (execução vermelha registra o estado)" || falha "esperava 1, veio $cod"
[ "$(n_slack)" -eq 1 ] && ok "um aviso ao Slack" || falha "esperava 1 aviso, veio $(n_slack)"
grep -q "não responde" "$TMP/slack.log" && ok "título do 1º aviso" || falha "título ausente: $(cat "$TMP/slack.log")"
grep -q "HTTP 503 (status: atrasado)" "$TMP/slack.log" && ok "motivo com HTTP e status" || falha "motivo ausente"

echo "▸ 4. Queda contínua de 30 min: silêncio (nada de aviso a cada 10 min)"
historico "$TMP/h4" "10:failure" "20:failure" "30:failure" "40:success"
limpar_slack
HIST="$TMP/h4" rodar; cod=$?
[ "$cod" -eq 1 ] && ok "continua vermelho (saída 1)" || falha "esperava 1, veio $cod"
[ "$(n_slack)" -eq 0 ] && ok "sem aviso repetido" || falha "repetiu aviso: $(cat "$TMP/slack.log")"

echo "▸ 5. Queda que completa 1 h: um lembrete (só na virada da hora)"
historico "$TMP/h5" "10:failure" "20:failure" "30:failure" "40:failure" "50:failure" "60:failure" "70:success"
limpar_slack
HIST="$TMP/h5" rodar; cod=$?
[ "$(n_slack)" -eq 1 ] && ok "um lembrete" || falha "esperava 1 lembrete, veio $(n_slack)"
grep -q "continua sem responder" "$TMP/slack.log" && ok "texto de lembrete" || falha "texto de lembrete ausente"
# 10 min depois, na rodada seguinte, não repete:
historico "$TMP/h5b" "10:failure" "20:failure" "30:failure" "40:failure" "50:failure" "60:failure" "70:failure" "80:success"
limpar_slack
HIST="$TMP/h5b" rodar
[ "$(n_slack)" -eq 0 ] && ok "rodada seguinte ao lembrete fica calada" || falha "lembrete repetido"

echo "▸ 6. Volta ao normal depois da queda: um aviso verde, sai 0"
roteiro "200 ok"
historico "$TMP/h6" "10:failure" "20:failure" "30:success"
limpar_slack
HIST="$TMP/h6" rodar; cod=$?
[ "$cod" -eq 0 ] && ok "saída 0" || falha "esperava 0, veio $cod"
[ "$(n_slack)" -eq 1 ] && grep -q "voltou ao normal" "$TMP/slack.log" && ok "aviso de volta ao normal" || falha "aviso de volta ausente: $(cat "$TMP/slack.log")"

echo "▸ 7. Execuções canceladas no histórico não contam como queda nem como boa"
roteiro "503 degradado"
historico "$TMP/h7" "10:cancelled" "20:success"
limpar_slack
HIST="$TMP/h7" rodar
[ "$(n_slack)" -eq 1 ] && ok "cancelada é ignorada: vale a boa anterior, 1º aviso" || falha "esperava 1 aviso, veio $(n_slack)"

echo "▸ 8. Vigia atrasado: última execução há 60 min (> 45 min) avisa"
roteiro "200 ok"
historico "$TMP/h8" "60:success"
limpar_slack
HIST="$TMP/h8" rodar; cod=$?
[ "$cod" -eq 0 ] && ok "saída 0 (a saúde está boa)" || falha "esperava 0, veio $cod"
[ "$(n_slack)" -eq 1 ] && grep -q "ficou sem rodar" "$TMP/slack.log" && ok "aviso de vigia atrasado" || falha "aviso de atraso ausente"
historico "$TMP/h8b" "10:success"
limpar_slack
HIST="$TMP/h8b" rodar
[ "$(n_slack)" -eq 0 ] && ok "10 min não é atraso" || falha "avisou atraso à toa"

echo "▸ 9. Sem histórico (primeira execução): saúde boa não avisa; fora avisa"
historico "$TMP/h9"
limpar_slack
HIST="$TMP/h9" rodar
[ "$(n_slack)" -eq 0 ] && ok "primeira execução boa: calada" || falha "avisou na primeira execução boa"
roteiro "503 atrasado"
HIST="$TMP/h9" rodar
[ "$(n_slack)" -eq 1 ] && ok "primeira execução fora: 1º aviso" || falha "esperava 1 aviso"

echo "▸ 10. Corpo inesperado conta como fora: 200 sem ok, 200 que não é JSON, 503 sem status, timeout"
for passo in "200 semok" "200 texto" "503 texto" "dormir"; do
  roteiro "$passo"
  limpar_slack
  HIST="$TMP/h1" rodar; cod=$?
  if [ "$cod" -eq 1 ] && [ "$(n_slack)" -eq 1 ]; then ok "'$passo': fora e avisou"; else falha "'$passo': saída $cod, avisos $(n_slack)"; fi
done
grep -q "sem resposta em 1 s" "$TMP/slack.log" && ok "timeout descrito na mensagem" || falha "mensagem de timeout ausente: $(cat "$TMP/slack.log")"

echo "▸ 11. Servidor que não existe (erro de rede): fora e avisa"
limpar_slack
URL_TESTE="http://127.0.0.1:9/saude" HIST="$TMP/h1" rodar; cod=$?
[ "$cod" -eq 1 ] && [ "$(n_slack)" -eq 1 ] && ok "erro de rede vira aviso" || falha "saída $cod, avisos $(n_slack)"

echo "▸ 12. Variável da URL ausente ou sem https: fora, com motivo claro, sem chamar a rede"
limpar_slack
URL_TESTE="" HIST="$TMP/h1" rodar; cod=$?
[ "$cod" -eq 1 ] && grep -q "FRILA_PROD_URL_SAUDE" "$TMP/slack.log" && ok "variável ausente avisa pelo Slack" || falha "saída $cod: $(cat "$TMP/slack.log")"
# sem --permitir-http, http:// é recusado
limpar_slack
env SLACK_WEBHOOK_URL="$SLACK" URL_SAUDE="$URL" python3 "$ALVO" --espera-confirmacao 0 --historico-json "$TMP/h1" --agora "$AGORA" --run-id 999 >/dev/null 2>&1; cod=$?
[ "$cod" -eq 1 ] && grep -q "https://" "$TMP/slack.log" && ok "http:// recusado em produção" || falha "http:// aceito"

echo "▸ 13. Falha do Slack ou do histórico nunca muda a saída"
roteiro "200 ok"
env SLACK_WEBHOOK_URL="http://127.0.0.1:9/slack" URL_SAUDE="$URL" python3 "$ALVO" --permitir-http --espera-confirmacao 0 --historico-json "$TMP/h6" --agora "$AGORA" --run-id 999 >/dev/null 2>&1; cod=$?
[ "$cod" -eq 0 ] && ok "Slack fora do ar: saúde boa ainda sai 0" || falha "esperava 0, veio $cod"
roteiro "503 atrasado"
limpar_slack
env GITHUB_TOKEN="" GH_TOKEN="" SLACK_WEBHOOK_URL="$SLACK" URL_SAUDE="$URL" python3 "$ALVO" --permitir-http --espera-confirmacao 0 >/dev/null 2>"$TMP/erro"; cod=$?
[ "$cod" -eq 1 ] && ok "sem histórico e saúde fora: sai 1" || falha "esperava 1, veio $cod"
[ "$(n_slack)" -eq 1 ] && ok "sem histórico, prefere um aviso a mais que silêncio" || falha "esperava 1 aviso"
grep -q "decidindo sem histórico" "$TMP/erro" && ok "avisa no log que não leu o histórico" || falha "aviso de histórico ausente"

echo "▸ 14. --dry-run imprime o aviso e não manda nada ao Slack"
roteiro "503 atrasado"
limpar_slack
DRY=1 HIST="$TMP/h1" rodar; cod=$?
[ "$cod" -eq 1 ] && ok "saída 1 mesmo em ensaio" || falha "esperava 1, veio $cod"
[ "$(n_slack)" -eq 0 ] && grep -q "DRY-RUN" "$TMP/saida" && ok "payload impresso e nada enviado" || falha "dry-run enviou ou não imprimiu"

echo "▸ 15. A URL e o webhook não vazam para o log nem para o Slack"
roteiro "503 atrasado"
limpar_slack
HIST="$TMP/h1" rodar
if grep -q "127.0.0.1:${PORTA}" "$TMP/saida" "$TMP/erro" "$TMP/slack.log"; then falha "URL ou webhook apareceu na saída"; else ok "nenhum endereço na saída, no stderr nem no payload"; fi

echo "▸ 16. Conformidade do workflow: só schedule/dispatch, sem segredo novo, sem escrita"
WF=".github/workflows/vigia-saude.yml"
grep -q "cron: '\*/10 \* \* \* \*'" "$WF" && ok "agenda a cada 10 min" || falha "cron */10 ausente"
grep -q "workflow_dispatch" "$WF" && ok "tem workflow_dispatch" || falha "workflow_dispatch ausente"
if grep -E -q "^\s*(pull_request|pull_request_target|push|workflow_run):" "$WF"; then falha "gatilho que expõe segredo a PR"; else ok "sem pull_request/push/workflow_run"; fi
grep -q "contents: read" "$WF" && ok "permissions: contents: read" || falha "permissions ausente"
if grep -E -q "contents: write|actions: write|id-token" "$WF"; then falha "permissão de escrita no workflow"; else ok "sem permissão de escrita"; fi
outros="$(grep -o 'secrets\.[A-Z_]*' "$WF" | sort -u | tr '\n' ' ')"
[ "$outros" = "secrets.SLACK_WEBHOOK_URL " ] && ok "único secret: SLACK_WEBHOOK_URL" || falha "secrets usados: $outros"
grep -q "group: vigia-saude" "$WF" && grep -q "timeout-minutes:" "$WF" && ok "concurrency e timeout-minutes" || falha "concurrency/timeout ausentes"
if grep -rn "hooks.slack.com" "$ALVO" "$WF" 2>/dev/null; then falha "webhook hardcoded"; else ok "nenhum webhook hardcoded"; fi

echo "=========================================================="
if [ "$falhas" -eq 0 ]; then
  echo "✓ Todos os testes do vigia da saude passaram!"
  exit 0
else
  echo "✗ $falhas teste(s) falharam!" >&2
  exit 1
fi
