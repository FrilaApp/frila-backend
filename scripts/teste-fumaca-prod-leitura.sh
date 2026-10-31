#!/usr/bin/env bash
# Autoteste automatizado do script `scripts/fumaca-prod-leitura.sh`.
#
# Utiliza um servidor HTTP local simulado em Python para exercitar
# todos os cenários sem qualquer dependência externa ou de rede.
#
# Casos testados:
#   1. Ausência de URL informada (exit 2)
#   2. Servidor saudável respondendo com conformidade estrita de leitura (exit 0)
#   3. Probe de saúde falhando / HTTP 503 (exit 1)
#   4. Edge Function falhando / código inesperado (exit 1)
#   5. Garantia de que nenhum método POST ou mutante foi disparado
#
# Uso:
#   ./scripts/teste-fumaca-prod-leitura.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PORTAO="$PWD/scripts/fumaca-prod-leitura.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

echo "▸ Teste automatizado de scripts/fumaca-prod-leitura.sh"

# ── 1. Parâmetros inválidos ────────────────────────────────────
conferir "falta de URL sai com código 2" \
  2 "URL não informada" \
  "$PORTAO"

# ── 2. Servidor Mock em Python ─────────────────────────────────
# Inicia um servidor HTTP em porta aleatória para simular o gateway
PORTA_FILE="$TMP/porta.txt"
LOG_REQUISICOES="$TMP/requisicoes.log"

python3 - <<PY >/dev/null 2>&1 &
import sys, http.server, socketserver, json

class MockHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        with open("$LOG_REQUISICOES", "a") as f:
            f.write(f"{self.command} {self.path}\n")

    def do_HEAD(self):
        if self.path == "/functions/v1/saude":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()

    def do_GET(self):
        auth = self.headers.get("apikey") or self.headers.get("Authorization")
        if self.path == "/functions/v1/saude":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true,"status":"saudavel"}')
        elif self.path in [
            "/functions/v1/despachar",
            "/functions/v1/enviar-email",
            "/functions/v1/enviar-push",
            "/functions/v1/limpar-contas-orfas",
            "/functions/v1/excluir-conta",
            "/functions/v1/exportar-meus-dados",
            "/functions/v1/exportar-turnos"
        ]:
            self.send_response(405)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"erro":"metodo_nao_permitido"}')
        elif self.path == "/functions/v1/entrar-demonstracao":
            self.send_response(404)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"code":"nao_encontrado"}')
        elif self.path == "/rest/v1/":
            if not auth:
                self.send_response(401)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"message":"Unauthorized"}')
            else:
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"swagger":"2.0"}')
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        # NUNCA deve receber POST
        self.send_response(500)
        self.end_headers()
        self.wfile.write(b'{"erro":"violacao_metodo_mutante"}')

with socketserver.TCPServer(("127.0.0.1", 0), MockHandler) as httpd:
    porta = httpd.server_address[1]
    with open("$PORTA_FILE", "w") as f:
        f.write(str(porta))
    httpd.serve_forever()
PY

PID_MOCK=$!
trap 'kill $PID_MOCK 2>/dev/null || true; wait $PID_MOCK 2>/dev/null || true; rm -rf "$TMP"' EXIT

# Aguarda subida do servidor mock
for i in $(seq 1 30); do
  if [ -f "$PORTA_FILE" ]; then break; fi
  sleep 0.1
done

if [ ! -f "$PORTA_FILE" ]; then
  echo "✗ Falha ao iniciar servidor mock local." >&2
  exit 1
fi

PORTA=$(cat "$PORTA_FILE")
URL_MOCK="http://127.0.0.1:$PORTA"

# ── 3. Caminho feliz com servidor mock ─────────────────────────
conferir "caminho feliz contra servidor mock passa com exit 0" \
  0 "Suíte de fumaça de leitura passou" \
  "$PORTAO" "$URL_MOCK" "chave-anon-teste"

# ── 4. Garantia estrita de zero POSTs ──────────────────────────
if grep -q "POST" "$LOG_REQUISICOES" 2>/dev/null; then
  echo "  ✗ Violação grave: o script disparou método POST!" >&2
  grep "POST" "$LOG_REQUISICOES" | sed 's/^/      /'
  falhas=$((falhas + 1))
else
  echo "  ✓ Garantia comprovada: nenhum método POST foi disparado (apenas GET e HEAD)"
  casos=$((casos + 1))
fi

# ── 5. Simulação de falha de saúde ─────────────────────────────
# Inicia servidor que responde 503 na rota /functions/v1/saude
PORTA_FAIL_FILE="$TMP/porta_fail.txt"
python3 - <<PY >/dev/null 2>&1 &
import http.server, socketserver

class FailHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(503)
        self.end_headers()
        self.wfile.write(b'{"ok":false,"erro":"banco_indisponivel"}')
    def do_HEAD(self):
        self.send_response(503)
        self.end_headers()

with socketserver.TCPServer(("127.0.0.1", 0), FailHandler) as httpd:
    with open("$PORTA_FAIL_FILE", "w") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
PID_FAIL=$!
trap 'kill $PID_MOCK $PID_FAIL 2>/dev/null || true; wait $PID_MOCK $PID_FAIL 2>/dev/null || true; rm -rf "$TMP"' EXIT

for i in $(seq 1 30); do
  if [ -f "$PORTA_FAIL_FILE" ]; then break; fi
  sleep 0.1
done

PORTA_FAIL=$(cat "$PORTA_FAIL_FILE")
conferir "saúde retornando 503 reprova com exit 1" \
  1 "Suíte de fumaça de leitura falhou" \
  "$PORTAO" "http://127.0.0.1:$PORTA_FAIL" "chave-anon-teste"

echo
if [ "$falhas" -ne 0 ]; then
  echo "Total de falhas: $falhas de $casos casos." >&2
  exit 1
fi
echo "Todos os $casos casos passaram."
exit 0
