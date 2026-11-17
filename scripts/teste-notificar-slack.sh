#!/usr/bin/env bash
# scripts/teste-notificar-slack.sh
# Suíte de validação automatizada para os scripts de notificação do time no Slack.
# Cartões zYC0uhH2 e bB0tV5R8.
#
# Execução:
#   ./scripts/teste-notificar-slack.sh

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

ALVO_PY="scripts/notificar_slack.py"
ALVO_SH="scripts/notificar-slack.sh"

falhas=0
ok()    { printf '  ✓ %s\n' "$1"; }
falha() { printf '  ✗ %s\n' "$1" >&2; falhas=$((falhas+1)); }

TMP="$(mktemp -d)"
MOCK_LOG="$TMP/mock_requests.log"
MOCK_PID_FILE="$TMP/mock.pid"
MOCK_PORT_FILE="$TMP/mock.port"

# shellcheck disable=SC2329
finalizar() {
  if [ -f "$MOCK_PID_FILE" ]; then
    kill "$(cat "$MOCK_PID_FILE")" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap finalizar EXIT

echo "=== Testes do Notificador do Slack (zYC0uhH2 / bB0tV5R8) ==="

# ─────────────────────────────────────────────────────────────────────────────
# 1. Comportamento com segredo ausente (Graceful degradation)
# ─────────────────────────────────────────────────────────────────────────────
echo "▸ 1. Segredo ausente sem --strict: exibe warning no stderr e encerra 0"
saida_err="$TMP/err1"
saida_out="$TMP/out1"
env -u SLACK_WEBHOOK_URL -u SLACK_ALERTAS_WEBHOOK \
  python3 "$ALVO_PY" --tipo ci_falha --branch develop >"$saida_out" 2>"$saida_err"
cod=$?
if [ "$cod" -eq 0 ]; then
  ok "código de saída é 0 (não quebra pipeline)"
else
  falha "esperava 0, veio $cod"
fi

if grep -q "::warning::SLACK_WEBHOOK_URL não configurado" "$saida_err"; then
  ok "aviso amigável emitido no stderr"
else
  falha "aviso esperado ausente no stderr: $(cat "$saida_err")"
fi

echo "▸ 2. Segredo ausente com --strict: encerra com código 1"
env -u SLACK_WEBHOOK_URL -u SLACK_ALERTAS_WEBHOOK \
  python3 "$ALVO_PY" --tipo ci_falha --branch develop --strict >/dev/null 2>&1
cod=$?
if [ "$cod" -eq 1 ]; then
  ok "código de saída é 1 com --strict"
else
  falha "esperava 1, veio $cod"
fi

echo "▸ 3. Invocação via invólucro shell ./scripts/notificar-slack.sh com segredo ausente"
env -u SLACK_WEBHOOK_URL -u SLACK_ALERTAS_WEBHOOK \
  "$ALVO_SH" --tipo backup_sucesso >"$saida_out" 2>"$saida_err"
cod=$?
if [ "$cod" -eq 0 ]; then
  ok "invólucro shell encerra 0"
else
  falha "esperava 0 no invólucro shell, veio $cod"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Modo --dry-run
# ─────────────────────────────────────────────────────────────────────────────
echo "▸ 4. --dry-run gera JSON formatado e sai 0 sem tocar rede"
saida_dry="$TMP/dry"
python3 "$ALVO_PY" --tipo backup_sucesso --dry-run >"$saida_dry" 2>&1
cod=$?
if [ "$cod" -eq 0 ]; then
  ok "dry-run encerra 0"
else
  falha "esperava 0, veio $cod"
fi

if grep -q "Backup Diário do frila-prod Concluído" "$saida_dry"; then
  ok "título correto presente no dry-run"
else
  falha "título não encontrado"
fi

if grep -q "🟢" "$saida_dry"; then
  ok "ícone de sucesso presente no dry-run"
else
  falha "ícone verde ausente"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. Servidor Mock Local para Testes com Rede Real
# ─────────────────────────────────────────────────────────────────────────────
echo "▸ 5. Iniciando servidor HTTP mock local para validar chamadas e payloads..."
python3 - <<'PY' "$MOCK_LOG" "$MOCK_PORT_FILE" "$MOCK_PID_FILE" &
import sys, os, json
from http.server import HTTPServer, BaseHTTPRequestHandler

log_path = sys.argv[1]
port_file = sys.argv[2]
pid_file = sys.argv[3]

class MockSlackHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        try:
            data = json.loads(body)
        except Exception:
            data = {"raw": body}

        with open(log_path, "a", encoding="utf-8") as f:
            f.write(json.dumps({
                "path": self.path,
                "headers": dict(self.headers),
                "payload": data
            }, ensure_ascii=False) + "\n")

        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, format, *args):
        pass

server = HTTPServer(("127.0.0.1", 0), MockSlackHandler)
port = server.server_port

with open(port_file, "w") as f:
    f.write(str(port))
with open(pid_file, "w") as f:
    f.write(str(os.getpid()))

server.serve_forever()
PY

for _ in {1..50}; do
  if [ -s "$MOCK_PORT_FILE" ]; then
    break
  fi
  sleep 0.1
done

MOCK_PORT="$(cat "$MOCK_PORT_FILE")"
MOCK_URL="http://127.0.0.1:${MOCK_PORT}/services/T000/B000/XXXX"

echo "  ✓ Mock HTTP ativo em 127.0.0.1:${MOCK_PORT}"

limpar_mock_log() {
  : > "$MOCK_LOG"
}

obter_ultimo_payload() {
  tail -n 1 "$MOCK_LOG"
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Validação dos Casos de Eventos workflow_run
# ─────────────────────────────────────────────────────────────────────────────
echo "▸ 6. workflow_run: CI falha na branch develop -> notifica com link do run"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --evento-workflow-run \
  --workflow-nome "CI" \
  --conclusao "failure" \
  --branch "refs/heads/develop" \
  --sha "3f4f41b12345678" \
  --url "https://github.com/FrilaApp/frila-backend/actions/runs/123456" >/dev/null 2>&1
cod=$?
if [ "$cod" -eq 0 ]; then
  ok "código 0"
else
  falha "esperava 0, veio $cod"
fi

ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "CI Quebrou: develop"; then
  ok "título CI develop correto"
else
  falha "payload inesperado: $ultimo"
fi

if echo "$ultimo" | grep -q "actions/runs/123456"; then
  ok "link do run presente"
else
  falha "link ausente"
fi

if echo "$ultimo" | grep -q "🔴"; then
  ok "ícone de falha correto"
else
  falha "ícone ausente"
fi

echo "▸ 7. workflow_run: CI falha em branch de teste (teste-ci-falha) -> notifica"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --evento-workflow-run \
  --workflow-nome "CI" \
  --conclusao "failure" \
  --branch "refs/heads/teste-ci-falha" \
  --sha "999888777" \
  --url "https://github.com/FrilaApp/frila-backend/actions/runs/777" >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "CI Quebrou: teste-ci-falha"; then
  ok "título em branch de teste correto"
else
  falha "payload: $ultimo"
fi

echo "▸ 8. workflow_run: CI sucesso na develop -> silencioso (não envia)"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --evento-workflow-run \
  --workflow-nome "CI" \
  --conclusao "success" \
  --branch "refs/heads/develop" >/dev/null 2>&1
if [ ! -s "$MOCK_LOG" ]; then
  ok "nenhuma notificação enviada no sucesso da CI"
else
  falha "mensagem enviada indevidamente!"
fi

echo "▸ 9. workflow_run: Entrega falha -> notifica"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --evento-workflow-run \
  --workflow-nome "Entrega" \
  --conclusao "failure" \
  --branch "refs/heads/develop" \
  --sha "abcdef1234" \
  --url "https://github.com/FrilaApp/frila-backend/actions/runs/888" >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "Falha na Entrega"; then
  ok "título falha na entrega correto"
else
  falha "payload: $ultimo"
fi

echo "▸ 10. workflow_run: Entrega sucesso com tag backend-v1.2.0 -> notifica tag aplicada em Prod"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --evento-workflow-run \
  --workflow-nome "Entrega" \
  --conclusao "success" \
  --branch "refs/tags/backend-v1.2.0" \
  --sha "1234567" >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "Tag Aplicada em Produção: backend-v1.2.0"; then
  ok "tag aplicada notificada"
else
  falha "payload: $ultimo"
fi

if echo "$ultimo" | grep -q "🟢"; then
  ok "ícone de sucesso presente"
else
  falha "ícone verde ausente"
fi

echo "▸ 11. workflow_run: Entrega sucesso em develop simples -> silencioso"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --evento-workflow-run \
  --workflow-nome "Entrega" \
  --conclusao "success" \
  --branch "refs/heads/develop" >/dev/null 2>&1
if [ ! -s "$MOCK_LOG" ]; then
  ok "entrega em dev com sucesso é silenciosa"
else
  falha "mensagem enviada indevidamente"
fi

echo "▸ 12. workflow_run: Backup diário do frila-prod sucesso -> envia resumo diário"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --evento-workflow-run \
  --workflow-nome "Backup diário do frila-prod" \
  --conclusao "success" \
  --url "https://github.com/FrilaApp/frila-backend/actions/runs/backup-123" >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "Backup Diário do frila-prod Concluído"; then
  ok "resumo de backup enviado"
else
  falha "payload: $ultimo"
fi

if echo "$ultimo" | grep -q "🟢"; then
  ok "ícone de sucesso no backup"
else
  falha "ícone ausente"
fi

echo "▸ 13. workflow_run: Backup diário do frila-prod falha -> envia alerta"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --evento-workflow-run \
  --workflow-nome "Backup diário do frila-prod" \
  --conclusao "failure" \
  --url "https://github.com/FrilaApp/frila-backend/actions/runs/backup-999" >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "Falha no Backup Diário do frila-prod"; then
  ok "alerta de falha no backup enviado"
else
  falha "payload: $ultimo"
fi

if echo "$ultimo" | grep -q "🔴"; then
  ok "ícone de falha no backup"
else
  falha "ícone ausente"
fi

echo "▸ 14. workflow_run: Mantém o Prod vivo falha -> envia alerta de disponibilidade"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --evento-workflow-run \
  --workflow-nome "Mantém o Prod vivo" \
  --conclusao "failure" \
  --url "https://github.com/FrilaApp/frila-backend/actions/runs/vivo-1" >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "Prod Vivo Falhou"; then
  ok "alerta de Prod vivo enviado"
else
  falha "payload: $ultimo"
fi

echo "▸ 15. workflow_run: Mantém o Prod vivo sucesso -> silencioso"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --evento-workflow-run \
  --workflow-nome "Mantém o Prod vivo" \
  --conclusao "success" >/dev/null 2>&1
if [ ! -s "$MOCK_LOG" ]; then
  ok "prod vivo com sucesso é silencioso"
else
  falha "mensagem enviada indevidamente"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. Entrega: Tag aguardando aprovação manual
# ─────────────────────────────────────────────────────────────────────────────
echo "▸ 16. Tag aguardando aprovação manual (status aguardando)"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --tipo entrega \
  --status aguardando \
  --branch "backend-v1.3.0" \
  --url "https://github.com/FrilaApp/frila-backend/actions/runs/tag-1" >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "Tag Aguardando Aprovação: backend-v1.3.0"; then
  ok "alerta aguardando aprovação correto"
else
  falha "payload: $ultimo"
fi

if echo "$ultimo" | grep -q "🟡"; then
  ok "ícone amarelo de aprovação presente"
else
  falha "ícone ausente"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Alerta de Banco (pg_cron / saude) - Fase 2 da Bigorna (Cartão bB0tV5R8)
# ─────────────────────────────────────────────────────────────────────────────
echo "▸ 17. Alerta de banco: jobs pg_cron atrasados / inativos"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --tipo alerta_banco \
  --mensagem "Probe externo detectou reprocessar_despacho inativo há 620s (tolerância 300s)." \
  --ambiente prod >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "Jobs pg_cron Atrasados"; then
  ok "alerta do banco enviado"
else
  falha "payload: $ultimo"
fi

if echo "$ultimo" | grep -q "🔴"; then
  ok "ícone de erro no alerta do banco"
else
  falha "ícone ausente"
fi

echo "▸ 18. Alerta de banco: jobs pg_cron recuperados ('voltou')"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --tipo alerta_banco_recuperado \
  --mensagem "Probe externo confirmou reprocessar_despacho e verificar_saude ativos e com execução recente." \
  --ambiente prod >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "Jobs pg_cron Normalizados"; then
  ok "recuperação do banco notificada"
else
  falha "payload: $ultimo"
fi

if echo "$ultimo" | grep -q "🟢"; then
  ok "ícone verde de retorno"
else
  falha "ícone ausente"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. Detecção de Backup Ausente (>30h)
# ─────────────────────────────────────────────────────────────────────────────
echo "▸ 19. Checar backup 30h: último sucesso há 5 horas -> silencioso"
limpar_mock_log
JSON_5H="$(python3 -c '
from datetime import datetime, timezone, timedelta
import json
dt = (datetime.now(timezone.utc) - timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps([{"createdAt": dt, "url": "https://actions/run/1"}]))
')"
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --checar-backup-30h \
  --json-input "$JSON_5H" >/dev/null 2>&1
if [ ! -s "$MOCK_LOG" ]; then
  ok "backup recente não gera alarme"
else
  falha "alarme disparado indevidamente"
fi

echo "▸ 20. Checar backup 30h: último sucesso há 35 horas -> dispara alerta ausente"
limpar_mock_log
JSON_35H="$(python3 -c '
from datetime import datetime, timezone, timedelta
import json
dt = (datetime.now(timezone.utc) - timedelta(hours=35)).strftime("%Y-%m-%dT%H:%M:%SZ")
print(json.dumps([{"createdAt": dt, "url": "https://actions/run/2"}]))
')"
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --checar-backup-30h \
  --json-input "$JSON_35H" >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "Backup do frila-prod ausente há 35."; then
  ok "alerta de backup ausente disparado"
else
  falha "payload: $ultimo"
fi

if echo "$ultimo" | grep -q "⚠️"; then
  ok "ícone de alerta presente"
else
  falha "ícone ausente"
fi

echo "▸ 21. Checar backup 30h: sem nenhuma execução com sucesso encontrada -> dispara alerta"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --checar-backup-30h \
  --json-input "[]" >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -q "Nenhum backup recente encontrado"; then
  ok "alerta de backup nunca executado"
else
  falha "payload: $ultimo"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. Auditoria de Segredos e Verificação de PII
# ─────────────────────────────────────────────────────────────────────────────
echo "▸ 22. Conformidade do Scanner: 'hooks.slack.com' só aparece onde permitido (não hardcoded)"
if grep -rn "hooks.slack.com" "$ALVO_PY" "$ALVO_SH" 2>/dev/null; then
  falha "URL de webhook hardcoded encontrada nos scripts!"
else
  ok "nenhuma URL de webhook hardcoded nos scripts de notificação"
fi

echo "▸ 23. Zero PII: payloads não carregam nomes pessoais, CPFs ou e-mails"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" "$ALVO_SH" \
  --tipo ci_falha --branch develop --sha "3f4f41b" >/dev/null 2>&1
ultimo="$(obter_ultimo_payload)"
if echo "$ultimo" | grep -E -q "([a-zA-Z0-9_.-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|[0-9]{3}\.[0-9]{3}\.[0-9]{3}-[0-9]{2})"; then
  falha "Dado pessoal detectado no payload!"
else
  ok "payload estritamente operacional e isento de PII (RN15)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 9. Aviso manual (workflow_dispatch acao=aviso)
# ─────────────────────────────────────────────────────────────────────────────
WORKFLOW_YML=".github/workflows/notifica-slack.yml"
# Linha do passo "Publicar o aviso": é ela que o GitHub executa, com MENSAGEM no ambiente.
COMANDO_AVISO="$(grep -F -e '--tipo aviso_manual' "$WORKFLOW_YML" | sed 's/^ *//')"

texto_enviado() {
  python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).read().splitlines()[-1])["payload"]["blocks"][1]["text"]["text"], end="")' "$MOCK_LOG"
}

echo "▸ 24. Aviso manual: o passo do workflow recebe o texto só por variável de ambiente"
# shellcheck disable=SC2016
if [ -n "$COMANDO_AVISO" ] && ! printf '%s' "$COMANDO_AVISO" | grep -q '\${{'; then
  ok "comando do workflow não interpola expressão do GitHub: $COMANDO_AVISO"
else
  falha "comando do passo ausente ou com \${{ }} no run: '$COMANDO_AVISO'"
fi

echo "▸ 25. Aviso manual: aspas, crase, \$(...) e quebra de linha chegam como texto e nada executa"
limpar_mock_log
rm -f "$TMP"/pwn*
# shellcheck disable=SC2016
MENSAGEM_PERIGOSA='PRs "530" e '"'532'"' `touch '"$TMP"'/pwn1` $(touch '"$TMP"'/pwn2) ${HOME}; touch '"$TMP"'/pwn3
segunda linha \ "fim"'
env SLACK_WEBHOOK_URL="$MOCK_URL" MENSAGEM="$MENSAGEM_PERIGOSA" bash -c "$COMANDO_AVISO" >/dev/null 2>&1
cod=$?
if [ "$cod" -eq 0 ]; then ok "código 0"; else falha "esperava 0, veio $cod"; fi
if ls "$TMP"/pwn* >/dev/null 2>&1; then
  falha "comando embutido na mensagem foi executado: $(ls "$TMP"/pwn*)"
else
  ok "nenhum comando embutido na mensagem foi executado"
fi
if [ "$(texto_enviado)" = "$MENSAGEM_PERIGOSA" ]; then
  ok "texto chegou ao Slack idêntico ao digitado (JSON escapado)"
else
  falha "texto divergente: $(texto_enviado)"
fi

echo "▸ 26. Aviso manual: mensagem que começa com -- é texto, não opção do script"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" MENSAGEM="--dry-run" bash -c "$COMANDO_AVISO" >/dev/null 2>&1
cod=$?
if [ "$cod" -eq 0 ] && [ "$(texto_enviado)" = "--dry-run" ]; then
  ok "texto com -- foi enviado como mensagem"
else
  falha "código $cod, texto: $(texto_enviado)"
fi

echo "▸ 27. Aviso manual: limite de 1000 caracteres"
limpar_mock_log
MENSAGEM_LONGA="$(python3 -c 'print("a" * 2500, end="")')"
env SLACK_WEBHOOK_URL="$MOCK_URL" MENSAGEM="$MENSAGEM_LONGA" bash -c "$COMANDO_AVISO" >/dev/null 2>&1
tamanho="$(texto_enviado | python3 -c 'import sys; print(len(sys.stdin.read()))')"
if [ "$tamanho" -eq 1000 ]; then
  ok "texto truncado em 1000 caracteres"
else
  falha "esperava 1000, veio $tamanho"
fi

echo "▸ 28. Aviso manual: mensagem vazia falha e não envia nada"
limpar_mock_log
env SLACK_WEBHOOK_URL="$MOCK_URL" MENSAGEM="   " bash -c "$COMANDO_AVISO" >/dev/null 2>&1
cod=$?
if [ "$cod" -ne 0 ] && [ ! -s "$MOCK_LOG" ]; then
  ok "código $cod e nenhuma requisição enviada"
else
  falha "código $cod, log: $(cat "$MOCK_LOG")"
fi

echo "▸ 29. Aviso manual: segredo ausente mantém o comportamento atual (warning, código 0)"
env -u SLACK_WEBHOOK_URL -u SLACK_ALERTAS_WEBHOOK MENSAGEM="teste" bash -c "$COMANDO_AVISO" >"$TMP/out29" 2>"$TMP/err29"
cod=$?
if [ "$cod" -eq 0 ] && grep -q "::warning::SLACK_WEBHOOK_URL não configurado" "$TMP/err29"; then
  ok "warning no stderr e código 0"
else
  falha "código $cod, stderr: $(cat "$TMP/err29")"
fi

echo "=========================================================="
if [ "$falhas" -eq 0 ]; then
  echo "✓ Todos os testes do Notificador do Slack passaram com sucesso!"
  exit 0
else
  echo "✗ $falhas teste(s) falharam!" >&2
  exit 1
fi
