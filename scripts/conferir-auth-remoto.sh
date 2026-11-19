#!/usr/bin/env bash
# Confere a configuração remota de Auth do Supabase (site_url, OTP length, SMTP e templates).
#
# Aceita:
#   --fixture <arquivo.json>   para validação local/offline
#   <project_ref>              para consulta via Management API usando $SUPABASE_ACCESS_TOKEN
#
# Validações:
#   a) site_url: não pode conter 'localhost' ou '127.0.0.1'
#   b) mailer_otp_length: deve ser 6
#   c) SMTP próprio: smtp_host não pode ser vazio
#   d) mailer_templates_magic_link_content e mailer_templates_confirmation_content:
#      devem conter '{{ .Token }}' e NÃO podem conter 'ConfirmationURL'
#   e) rate_limit_email_sent (e-mails por hora, no projeto inteiro): tem de ser o valor
#      esperado, $AUTH_LIMITE_EMAILS_HORA (padrão 30). Mudou de propósito: mude o padrão aqui.
#   f) captcha: desligado (decisão de 16/11/2026, docs/decisoes/D04-captcha-da-entrada.md).
#      Com AUTH_CAPTCHA_ESPERADO=turnstile, tem de estar ligado e com o provedor turnstile.
#   Informativo (não reprova): smtp_port, o domínio do remetente e os limites por IP
#   (rate_limit_otp e rate_limit_verify).
#
# Em caso de falha de qualquer validação, imprime o motivo em português, aponta para
# supabase/operacao/configurar-smtp-auth.md e sai com exit 1.
#
# NUNCA imprime tokens, senhas ou o corpo completo dos templates. Imprime apenas o
# veredito por campo.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Se o token não estiver no ambiente, carrega do .env se existir
if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ] && [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

if [ $# -eq 0 ]; then
  echo "Uso: $0 --fixture <arquivo.json>" >&2
  echo "     $0 <project_ref>" >&2
  exit 1
fi

TMP=""
trap 'if [ -n "$TMP" ] && [ -f "$TMP" ]; then rm -f "$TMP"; fi' EXIT

ARQUIVO_JSON=""

if [ "$1" = "--fixture" ]; then
  if [ -z "${2:-}" ]; then
    echo "Erro: caminho do arquivo não informado para --fixture." >&2
    exit 1
  fi
  FIXTURE="$2"
  if [ ! -f "$FIXTURE" ]; then
    echo "Erro: arquivo fixture não encontrado: $FIXTURE" >&2
    exit 1
  fi
  ARQUIVO_JSON="$FIXTURE"
else
  REF="$1"
  if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
    echo "Erro: SUPABASE_ACCESS_TOKEN não definido no ambiente ou no .env." >&2
    exit 1
  fi
  URL="https://api.supabase.com/v1/projects/${REF}/config/auth"
  TMP=$(mktemp)
  if ! curl -sS -f --max-time 30 \
    -H "Authorization: Bearer ${SUPABASE_ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -o "$TMP" \
    "$URL"; then
    echo "Erro: falha ao consultar a Management API do Supabase para o projeto '$REF'." >&2
    echo "Verifique se o token de acesso possui permissão e se a referência do projeto está correta." >&2
    exit 1
  fi
  ARQUIVO_JSON="$TMP"
fi

# Validação do JSON com Python3
AUTH_LIMITE_EMAILS_HORA="${AUTH_LIMITE_EMAILS_HORA:-30}" AUTH_CAPTCHA_ESPERADO="${AUTH_CAPTCHA_ESPERADO:-desligado}" \
  python3 - "$ARQUIVO_JSON" <<'PY'
import json
import os
import sys

caminho = sys.argv[1]
try:
    with open(caminho, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception as e:
    print(f"Erro: JSON inválido ou resposta malformada ({e}).", file=sys.stderr)
    sys.exit(1)

erros = []
vereditos = []

# a) site_url: não pode conter 'localhost' ou '127.0.0.1'
site_url = data.get("site_url")
if not site_url or not isinstance(site_url, str):
    erros.append("site_url ausente ou vazio")
    vereditos.append("  ✗ site_url: ausente ou vazio")
elif "localhost" in site_url.lower() or "127.0.0.1" in site_url:
    erros.append("site_url contém 'localhost' ou '127.0.0.1'")
    vereditos.append("  ✗ site_url: contém 'localhost' ou '127.0.0.1'")
else:
    vereditos.append("  ✓ site_url: válido (sem localhost nem 127.0.0.1)")

# b) mailer_otp_length: deve ser 6
otp_len = data.get("mailer_otp_length")
try:
    if int(otp_len) == 6:
        vereditos.append("  ✓ mailer_otp_length: válido (6 dígitos)")
    else:
        erros.append(f"mailer_otp_length deve ser 6 (encontrado: {otp_len})")
        vereditos.append(f"  ✗ mailer_otp_length: inválido (deve ser 6, encontrado: {otp_len})")
except (TypeError, ValueError):
    erros.append(f"mailer_otp_length inválido ou ausente: {otp_len}")
    vereditos.append("  ✗ mailer_otp_length: inválido ou ausente")

# c) SMTP próprio: smtp_host não pode ser vazio
smtp_host = data.get("smtp_host")
if not smtp_host or not isinstance(smtp_host, str) or not smtp_host.strip():
    erros.append("smtp_host não pode ser vazio (SMTP próprio desligado ou não configurado)")
    vereditos.append("  ✗ smtp_host: vazio ou não configurado")
else:
    vereditos.append("  ✓ smtp_host: configurado (SMTP próprio ativo)")

# d) mailer_templates_magic_link_content e mailer_templates_confirmation_content:
#    devem conter '{{ .Token }}' e NÃO podem conter 'ConfirmationURL'
def validar_template(chave, nome_amigavel):
    conteudo = data.get(chave)
    if not conteudo or not isinstance(conteudo, str):
        erros.append(f"{chave} está vazio ou ausente")
        vereditos.append(f"  ✗ {nome_amigavel}: vazio ou ausente")
        return

    falhas_tpl = []
    if "{{ .Token }}" not in conteudo:
        falhas_tpl.append("não contém '{{ .Token }}'")
    if "ConfirmationURL" in conteudo:
        falhas_tpl.append("contém 'ConfirmationURL'")

    if falhas_tpl:
        motivo = " e ".join(falhas_tpl)
        erros.append(f"{chave}: {motivo}")
        vereditos.append(f"  ✗ {nome_amigavel}: {motivo}")
    else:
        vereditos.append(f"  ✓ {nome_amigavel}: contém '{{{{ .Token }}}}' e não contém 'ConfirmationURL'")

validar_template("mailer_templates_confirmation_content", "modelo de confirmação (mailer_templates_confirmation_content)")
validar_template("mailer_templates_magic_link_content", "modelo de link mágico (mailer_templates_magic_link_content)")

# e) limite de e-mails por hora do Auth (o projeto inteiro divide a mesma cota)
limite_esperado = os.environ.get("AUTH_LIMITE_EMAILS_HORA", "30")
limite = data.get("rate_limit_email_sent")
if isinstance(limite, bool) or not isinstance(limite, int):
    erros.append(f"rate_limit_email_sent ausente ou não inteiro: {limite!r}")
    vereditos.append("  ✗ rate_limit_email_sent: ausente ou não inteiro")
elif str(limite) != limite_esperado:
    erros.append(f"rate_limit_email_sent = {limite} por hora (esperado {limite_esperado})")
    vereditos.append(f"  ✗ rate_limit_email_sent: {limite} por hora (esperado {limite_esperado})")
else:
    vereditos.append(f"  ✓ rate_limit_email_sent: {limite} por hora (o esperado)")

# f) captcha da entrada
captcha_esperado = os.environ.get("AUTH_CAPTCHA_ESPERADO", "desligado")
captcha_ligado = data.get("security_captcha_enabled")
provedor = data.get("security_captcha_provider")
if captcha_esperado == "desligado":
    if captcha_ligado is False:
        vereditos.append("  ✓ captcha: desligado (o esperado; decisão de 16/11/2026)")
    else:
        erros.append(f"captcha deveria estar desligado (security_captcha_enabled = {captcha_ligado!r})")
        vereditos.append(f"  ✗ captcha: security_captcha_enabled = {captcha_ligado!r} (esperado desligado)")
elif captcha_ligado is True and provedor == captcha_esperado:
    vereditos.append(f"  ✓ captcha: ligado com {provedor} (o esperado)")
else:
    erros.append(f"captcha deveria estar ligado com {captcha_esperado} (ligado = {captcha_ligado!r}, provedor = {provedor!r})")
    vereditos.append(f"  ✗ captcha: ligado = {captcha_ligado!r}, provedor = {provedor!r} (esperado {captcha_esperado})")

# Informativo, sem reprovar e sem segredo
remetente = data.get("smtp_admin_email")
dominio = remetente.split("@", 1)[1] if isinstance(remetente, str) and "@" in remetente else None
vereditos.append(f"  · smtp_port: {data.get('smtp_port')!r}; domínio do remetente: {dominio!r}")
vereditos.append(f"  · limites por IP: rate_limit_otp = {data.get('rate_limit_otp')!r}, rate_limit_verify = {data.get('rate_limit_verify')!r}")

# Imprime vereditos por campo (NUNCA tokens, senhas ou corpo completo)
print("Conferência de Auth remoto:")
for v in vereditos:
    print(v)

if erros:
    print("\nFalha na conferência de Auth remoto:")
    for err in erros:
        print(f"  - {err}")
    print("\nConsulte o runbook para correção: supabase/operacao/configurar-smtp-auth.md")
    sys.exit(1)
else:
    print("\nConfiguração de Auth remoto válida.")
    sys.exit(0)
PY
