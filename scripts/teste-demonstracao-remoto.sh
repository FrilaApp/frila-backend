#!/usr/bin/env bash
# Prova que `demonstracao-remoto.sh` recusa subir a demonstração sem uma janela
# DEMONSTRACAO_ATIVA_ATE válida e futura, e que essa janela chega de verdade ao
# `supabase secrets set` (cartão `5boVdM0t`).
#
# Não faz chamada de rede: usa `source` para reaproveitar as funções puras, isoladas do
# `main` (que é quem faz as chamadas reais de Management API e PostgREST).
#
# Achado do portão ANBU no PR #310: a primeira versão deste teste só chamava
# `validar_segredos_demonstracao`, e uma mutação que apagava a linha do
# `supabase secrets set` que passa DEMONSTRACAO_ATIVA_ATE continuava passando — o teste
# não protegia a correção que ele dizia proteger. Por isso o caso
# "grava DEMONSTRACAO_ATIVA_ATE no secrets set" dubla `supabase` como função de shell
# (o bash resolve função antes do binário do PATH) e lê o que `gravar_segredos_demonstracao`
# de fato passou para ela.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Futuro calculado, não data fixa: um "2030-01-01" vira passado um dia e o teste some
# sem ningém notar. +5 anos a partir de agora, sempre fresco.
FUTURO=$(python3 -c "
import datetime
agora = datetime.datetime.now(datetime.timezone.utc)
print((agora.replace(microsecond=0) + datetime.timedelta(days=365*5)).isoformat().replace('+00:00', 'Z'))
")
PASSADO="2020-01-01T00:00:00Z"
FUTURO_SEM_FUSO=$(python3 -c "
import datetime
agora = datetime.datetime.now(datetime.timezone.utc)
print((agora.replace(microsecond=0) + datetime.timedelta(days=365*5)).strftime('%Y-%m-%dT%H:%M:%S'))
")

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
cat > "$tmp/sem_ativa_ate.env" <<EOF
DEMONSTRACAO_EMAILS=revisao-contratante@frila.app,revisao-profissional@frila.app
DEMONSTRACAO_CODIGO=codigo-de-teste-valido
EOF
assert_recusa "sem DEMONSTRACAO_ATIVA_ATE" "$tmp/sem_ativa_ate.env"

# ── Caso 2: DEMONSTRACAO_ATIVA_ATE no passado — janela já vencida, mesmo fail-closed.
cat > "$tmp/ativa_ate_passado.env" <<EOF
DEMONSTRACAO_EMAILS=revisao-contratante@frila.app,revisao-profissional@frila.app
DEMONSTRACAO_CODIGO=codigo-de-teste-valido
DEMONSTRACAO_ATIVA_ATE=$PASSADO
EOF
assert_recusa "DEMONSTRACAO_ATIVA_ATE no passado" "$tmp/ativa_ate_passado.env"

# ── Caso 3: DEMONSTRACAO_ATIVA_ATE sem fuso explícito — ambíguo, a Edge Function também recusa.
cat > "$tmp/ativa_ate_sem_fuso.env" <<EOF
DEMONSTRACAO_EMAILS=revisao-contratante@frila.app,revisao-profissional@frila.app
DEMONSTRACAO_CODIGO=codigo-de-teste-valido
DEMONSTRACAO_ATIVA_ATE=$FUTURO_SEM_FUSO
EOF
assert_recusa "DEMONSTRACAO_ATIVA_ATE sem fuso" "$tmp/ativa_ate_sem_fuso.env"

# ── Caso 4: tudo válido, com DEMONSTRACAO_ATIVA_ATE futura e com fuso — deve aceitar.
cat > "$tmp/valido.env" <<EOF
DEMONSTRACAO_EMAILS=revisao-contratante@frila.app,revisao-profissional@frila.app
DEMONSTRACAO_CODIGO=codigo-de-teste-valido
DEMONSTRACAO_ATIVA_ATE=$FUTURO
EOF
assert_aceita "segredos completos e válidos" "$tmp/valido.env"

# ── Caso 5: o segredo que chega até o `supabase secrets set` de verdade, não só o que
# passa pela validação. Dubla `supabase` como função de shell — bash resolve função
# antes do binário no PATH — e lê o que `gravar_segredos_demonstracao` mandou para ela.
# Mutar a linha que passa DEMONSTRACAO_ATIVA_ATE em `gravar_segredos_demonstracao`
# precisa derrubar este caso; se não derrubar, o teste é decorativo (achado do ANBU).
captura="$tmp/supabase_argv.txt"
: > "$captura"
(
  supabase() { printf '%s\n' "$@" >> "$captura"; }
  source scripts/demonstracao-remoto.sh
  gravar_segredos_demonstracao "$tmp/valido.env" "projeto-fake" >/dev/null 2>&1
)
if grep -q '^DEMONSTRACAO_ATIVA_ATE=' "$captura"; then
  echo "  ✓ gravar_segredos_demonstracao passa DEMONSTRACAO_ATIVA_ATE pro supabase secrets set"
else
  echo "  ✗ gravar_segredos_demonstracao NÃO passou DEMONSTRACAO_ATIVA_ATE pro supabase secrets set"
  falhas=$((falhas + 1))
fi
if grep -q '^DEMONSTRACAO_EMAILS=' "$captura" && grep -q '^DEMONSTRACAO_CODIGO=' "$captura"; then
  echo "  ✓ gravar_segredos_demonstracao continua passando EMAILS e CODIGO"
else
  echo "  ✗ gravar_segredos_demonstracao deixou de passar EMAILS ou CODIGO"
  falhas=$((falhas + 1))
fi
if grep -q -- '--project-ref' "$captura" && grep -q 'projeto-fake' "$captura"; then
  echo "  ✓ gravar_segredos_demonstracao passa --project-ref"
else
  echo "  ✗ gravar_segredos_demonstracao não passou --project-ref corretamente"
  falhas=$((falhas + 1))
fi

if [ "$falhas" -gt 0 ]; then
  echo "FALHOU: $falhas caso(s)" >&2
  exit 1
fi
echo "OK: janela exigida/validada, e DEMONSTRACAO_ATIVA_ATE chega até o supabase secrets set"
