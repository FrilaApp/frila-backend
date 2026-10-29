#!/usr/bin/env bash
# Testa a conferência de Auth remoto contra as fixtures offline.
#
# Cobre os quatro cenários previstos:
#   1. bom: configuração correta e completa (exit 0)
#   2. site_url_localhost: presença de localhost (exit 1)
#   3. modelo_com_link: template contendo ConfirmationURL (exit 1)
#   4. smtp_desligado: smtp_host vazio (exit 1)
#
# Uso:
#   ./scripts/teste-conferir-auth-remoto.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

falhas=0
casos=0

conferir() { # conferir <descrição> <saída esperada> <frase esperada> <comando...>
  local desc="$1" esperado="$2" frase="$3"; shift 3
  local saida codigo
  saida=$("$@" 2>&1); codigo=$?
  casos=$((casos+1))
  if [ "$codigo" = "$esperado" ] && printf '%s' "$saida" | grep -qF -- "$frase"; then
    echo "  ✓ $desc"
  else
    echo "  ✗ $desc: saiu $codigo (esperado $esperado)"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas+1))
  fi
}

echo "▸ Teste da conferência de Auth remoto"

conferir "cenário bom: configuração completa e válida passa com exit 0" \
  0 "Configuração de Auth remoto válida." \
  ./scripts/conferir-auth-remoto.sh --fixture scripts/fixtures/auth_bom.json

conferir "cenário site_url_localhost: reprova localhost e aponta runbook com exit 1" \
  1 "site_url: contém 'localhost' ou '127.0.0.1'" \
  ./scripts/conferir-auth-remoto.sh --fixture scripts/fixtures/auth_site_url_localhost.json

conferir "cenário modelo_com_link: reprova ConfirmationURL e aponta runbook com exit 1" \
  1 "contém 'ConfirmationURL'" \
  ./scripts/conferir-auth-remoto.sh --fixture scripts/fixtures/auth_modelo_com_link.json

conferir "cenário smtp_desligado: reprova smtp_host vazio e aponta runbook com exit 1" \
  1 "smtp_host: vazio ou não configurado" \
  ./scripts/conferir-auth-remoto.sh --fixture scripts/fixtures/auth_smtp_desligado.json

# Confere também que aponta para o runbook em caso de reprovação
conferir "aponta para supabase/operacao/configurar-smtp-auth.md na falha" \
  1 "supabase/operacao/configurar-smtp-auth.md" \
  ./scripts/conferir-auth-remoto.sh --fixture scripts/fixtures/auth_smtp_desligado.json

if [ "$falhas" -gt 0 ]; then
  echo "Total de falhas: $falhas de $casos casos." >&2
  exit 1
fi

echo "Todos os $casos casos passaram."
exit 0
