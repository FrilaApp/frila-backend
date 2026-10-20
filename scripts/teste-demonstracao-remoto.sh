#!/usr/bin/env bash
# Prova que `demonstracao-remoto.sh` recusa subir a demonstração sem uma janela
# DEMONSTRACAO_ATIVA_ATE válida e futura, e aceita gravar DEMONSTRACAO_ATIVA_ATE como
# terceiro segredo (cartão `5boVdM0t`).
#
# Não faz chamada de rede: usa `source` para reaproveitar `validar_segredos_demonstracao`
# isolada do `main`, que é quem faz as chamadas reais de Management API e PostgREST.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

falhas=0

assert_recusa() {
  local nome="$1" arquivo="$2"
  if ( source scripts/demonstracao-remoto.sh; validar_segredos_demonstracao "$arquivo" ) >/dev/null 2>&1; then
    echo "  ✗ $nome: deveria ter recusado e aceitou"
    falhas=$((falhas + 1))
  else
    echo "  ✓ $nome: recusado"
  fi
}

assert_aceita() {
  local nome="$1" arquivo="$2"
  if ( source scripts/demonstracao-remoto.sh; validar_segredos_demonstracao "$arquivo" ) >/dev/null 2>&1; then
    echo "  ✓ $nome: aceito"
  else
    echo "  ✗ $nome: deveria ter aceitado e recusou"
    falhas=$((falhas + 1))
  fi
}

# ── Caso 1: sem DEMONSTRACAO_ATIVA_ATE (o estado real do frila-dev em 20/10/2026,
# porque este script nunca a gravava) — é exatamente o que apaga a porta em silêncio.
cat > "$tmp/sem_ativa_ate.env" <<'EOF'
DEMONSTRACAO_EMAILS=revisao-contratante@frila.app,revisao-profissional@frila.app
DEMONSTRACAO_CODIGO=codigo-de-teste-valido
EOF
assert_recusa "sem DEMONSTRACAO_ATIVA_ATE" "$tmp/sem_ativa_ate.env"

# ── Caso 2: DEMONSTRACAO_ATIVA_ATE no passado — janela já vencida, mesmo fail-closed.
cat > "$tmp/ativa_ate_passado.env" <<'EOF'
DEMONSTRACAO_EMAILS=revisao-contratante@frila.app,revisao-profissional@frila.app
DEMONSTRACAO_CODIGO=codigo-de-teste-valido
DEMONSTRACAO_ATIVA_ATE=2020-01-01T00:00:00Z
EOF
assert_recusa "DEMONSTRACAO_ATIVA_ATE no passado" "$tmp/ativa_ate_passado.env"

# ── Caso 3: DEMONSTRACAO_ATIVA_ATE sem fuso explícito — ambíguo, a Edge Function também recusa.
cat > "$tmp/ativa_ate_sem_fuso.env" <<'EOF'
DEMONSTRACAO_EMAILS=revisao-contratante@frila.app,revisao-profissional@frila.app
DEMONSTRACAO_CODIGO=codigo-de-teste-valido
DEMONSTRACAO_ATIVA_ATE=2030-01-01T00:00:00
EOF
assert_recusa "DEMONSTRACAO_ATIVA_ATE sem fuso" "$tmp/ativa_ate_sem_fuso.env"

# ── Caso 4: tudo válido, com DEMONSTRACAO_ATIVA_ATE futura e com fuso — deve aceitar.
cat > "$tmp/valido.env" <<'EOF'
DEMONSTRACAO_EMAILS=revisao-contratante@frila.app,revisao-profissional@frila.app
DEMONSTRACAO_CODIGO=codigo-de-teste-valido
DEMONSTRACAO_ATIVA_ATE=2030-01-01T00:00:00Z
EOF
assert_aceita "segredos completos e válidos" "$tmp/valido.env"

if [ "$falhas" -gt 0 ]; then
  echo "FALHOU: $falhas caso(s)" >&2
  exit 1
fi
echo "OK: validar_segredos_demonstracao exige DEMONSTRACAO_ATIVA_ATE válida e futura"
