#!/usr/bin/env bash
# Autoteste do script de auditoria de segredos e dependências.
#
# Valida rigorosamente que o portão `scripts/auditoria-segredos-e-dependencias.sh`:
#   1. Detecta credenciais, chaves privadas, segredos e tokens na árvore e no git;
#   2. NUNCA expõe o valor real de nenhum segredo no relatório ou terminal (redação segura);
#   3. Distingue com precisão fixtures legítimas e mocks de segredos expostos reais;
#   4. Identifica dependências sem pin em Deno e GitHub Actions sem commit SHA;
#   5. Respeita as opções de escopo e os códigos de saída esperados.
#
# Uso:
#   ./scripts/teste-auditoria-segredos-e-dependencias.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PORTAO="$PWD/scripts/auditoria-segredos-e-dependencias.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

conferir() {
  local desc="$1" esperado="$2" frase="$3"; shift 3
  local saida codigo
  saida=$("$@" 2>&1); codigo=$?
  casos=$((casos + 1))
  if [ "$codigo" = "$esperado" ] && printf '%s' "$saida" | grep -qF -- "$frase"; then
    echo "  ✓ $desc"
  else
    echo "  ✗ $desc: saiu $codigo (esperado $esperado), frase esperada: '$frase'"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Teste da auditoria de segredos e dependências"

# Caso 1: Ajuda
conferir "caso 1: --ajuda exibe instruções e sai com 0" \
  0 "Varredura auditável de segredos e dependências" \
  "$PORTAO" --ajuda

# Caso 2: Repositório mínimo limpo
dir_limpo="$TMP/repo_limpo"
mkdir -p "$dir_limpo/scripts"
cp "$PORTAO" "$dir_limpo/scripts/"
(
  cd "$dir_limpo" || exit 1
  git init -q
  git config user.email "teste@frilabr.com"
  git config user.name "Testador"
  echo "# Teste" > README.md
  git add README.md scripts/
  git commit -q -m "init"
)
conferir "caso 2: repositório limpo passa com status CONFORME" \
  0 "CONFORME: Nenhum segredo exposto detectado" \
  "$dir_limpo/scripts/auditoria-segredos-e-dependencias.sh" --relatorio "$dir_limpo/docs/relatorio.md"

# Caso 3: Detecção de segredo em arquivo com garantia de não vazamento
dir_segredo="$TMP/repo_segredo"
mkdir -p "$dir_segredo/scripts" "$dir_segredo/src"
cp "$PORTAO" "$dir_segredo/scripts/"
SEGREDO_SINTETICO="re_sintetico_1234567890abcdef12345678"
cat << EOF > "$dir_segredo/src/provedor.ts"
export const resendKey = "${SEGREDO_SINTETICO}";
EOF
(
  cd "$dir_segredo" || exit 1
  git init -q
  git config user.email "teste@frilabr.com"
  git config user.name "Testador"
  git add .
  git commit -q -m "feat: provedor de email"
)

saida_segredo=$("$dir_segredo/scripts/auditoria-segredos-e-dependencias.sh" --relatorio "$dir_segredo/docs/relatorio.md" 2>&1 || true)
casos=$((casos + 1))
if printf '%s' "$saida_segredo" | grep -q "Segredo em arquivo: src/provedor.ts"; then
  echo "  ✓ caso 3.1: segredo sintético detectado em arquivo"
else
  echo "  ✗ caso 3.1: segredo sintético não foi detectado em src/provedor.ts"
  falhas=$((falhas + 1))
fi

casos=$((casos + 1))
# Prova crítica: o segredo bruto 1234567890abcdef JAMAIS pode aparecer no relatório nem na saída
if grep -q "1234567890abcdef" "$dir_segredo/docs/relatorio.md" || printf '%s' "$saida_segredo" | grep -q "1234567890abcdef"; then
  echo "  ✗ caso 3.2: VAZAMENTO DETECTADO! O segredo bruto apareceu no relatório ou terminal"
  falhas=$((falhas + 1))
else
  echo "  ✓ caso 3.2: segredo mascarado com sucesso (zero vazamento no relatório e console)"
fi

# Caso 4: Detecção de segredo no histórico Git
dir_hist="$TMP/repo_hist"
mkdir -p "$dir_hist/scripts" "$dir_hist/config"
cp "$PORTAO" "$dir_hist/scripts/"
(
  cd "$dir_hist" || exit 1
  git init -q
  git config user.email "teste@frilabr.com"
  git config user.name "Testador"
  echo "AWS_KEY=AKIAIOSFODNN7EXAMPLE" > config/aws.env
  git add config/aws.env
  git commit -q -m "feat: adiciona aws env"
  rm config/aws.env
  git add config/aws.env
  git commit -q -m "fix: remove aws env vazado"
  git add scripts/
  git commit -q -m "chore: scripts"
)

saida_hist=$("$dir_hist/scripts/auditoria-segredos-e-dependencias.sh" --relatorio "$dir_hist/docs/relatorio.md" 2>&1 || true)
casos=$((casos + 1))
if printf '%s' "$saida_hist" | grep -q "Segredo no histórico:"; then
  echo "  ✓ caso 4.1: segredo no histórico git detectado"
else
  echo "  ✗ caso 4.1: segredo histórico não detectado"
  falhas=$((falhas + 1))
fi

casos=$((casos + 1))
if grep -q "IOSFODNN7EXAMPLE" "$dir_hist/docs/relatorio.md" || printf '%s' "$saida_hist" | grep -q "IOSFODNN7EXAMPLE"; then
  echo "  ✗ caso 4.2: VAZAMENTO HISTÓRICO! Chave apareceu em texto claro"
  falhas=$((falhas + 1))
else
  echo "  ✓ caso 4.2: segredo histórico mascarado sem vazamento"
fi

# Caso 5: Fixtures sintéticas em testes são classificadas como LEGÍTIMO
dir_fixture="$TMP/repo_fixture"
mkdir -p "$dir_fixture/scripts" "$dir_fixture/supabase/functions/auth"
cp "$PORTAO" "$dir_fixture/scripts/"
echo '{"version":"3"}' > "$dir_fixture/deno.lock"
cat << 'EOF' > "$dir_fixture/supabase/functions/auth/index_test.ts"
Deno.test("mock auth", () => {
  const privateKey = "-----BEGIN PRIVATE KEY-----\nMOCKTESTKEY\n-----END PRIVATE KEY-----";
  const token = "mock-access-token-12345";
});
EOF
(
  cd "$dir_fixture" || exit 1
  git init -q
  git config user.email "teste@frilabr.com"
  git config user.name "Testador"
  git add .
  git commit -q -m "test: mock unitario"
)
conferir "caso 5: fixture de teste sintética é classificada como legítima" \
  0 "CONFORME: Nenhum segredo exposto detectado" \
  "$dir_fixture/scripts/auditoria-segredos-e-dependencias.sh" --relatorio "$dir_fixture/docs/relatorio.md"

# Caso 6: Deno com dependência sem versão fixada
dir_deno="$TMP/repo_deno"
mkdir -p "$dir_deno/scripts" "$dir_deno/supabase/functions/exportar"
cp "$PORTAO" "$dir_deno/scripts/"
cat << 'EOF' > "$dir_deno/supabase/functions/exportar/index.ts"
import lodash from "npm:lodash";
EOF
(
  cd "$dir_deno" || exit 1
  git init -q
  git config user.email "teste@frilabr.com"
  git config user.name "Testador"
  git add .
  git commit -q -m "feat: sem pin"
)
conferir "caso 6: alerta para módulo Deno sem versão fixada" \
  0 "Dependência Deno sem versão fixada: npm:lodash" \
  "$dir_deno/scripts/auditoria-segredos-e-dependencias.sh" --relatorio "$dir_deno/docs/relatorio.md"

# Caso 7: GitHub Action sem commit SHA imutável
dir_gh="$TMP/repo_gh"
mkdir -p "$dir_gh/scripts" "$dir_gh/.github/workflows"
cp "$PORTAO" "$dir_gh/scripts/"
cat << 'EOF' > "$dir_gh/.github/workflows/ci.yml"
name: CI
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
EOF
(
  cd "$dir_gh" || exit 1
  git init -q
  git config user.email "teste@frilabr.com"
  git config user.name "Testador"
  git add .
  git commit -q -m "ci: checkout tag"
)
conferir "caso 7: alerta para GitHub Action sem commit SHA imutável" \
  0 "não utiliza commit SHA imutável" \
  "$dir_gh/scripts/auditoria-segredos-e-dependencias.sh" --relatorio "$dir_gh/docs/relatorio.md"

# Caso 8: Opção --apenas-segredos omite seção de dependências
rel_segredos="$TMP/rel_segredos.md"
"$dir_limpo/scripts/auditoria-segredos-e-dependencias.sh" --apenas-segredos --relatorio "$rel_segredos" >/dev/null 2>&1
casos=$((casos + 1))
if grep -q "Varredura de Credenciais, Chaves e Segredos" "$rel_segredos" && ! grep -q "Inventário e Auditoria de Dependências" "$rel_segredos"; then
  echo "  ✓ caso 8: --apenas-segredos isola escopo com sucesso"
else
  echo "  ✗ caso 8: falha ao isolar --apenas-segredos"
  falhas=$((falhas + 1))
fi

# Caso 9: Opção --apenas-dependencias omite seção de segredos
rel_deps="$TMP/rel_deps.md"
"$dir_limpo/scripts/auditoria-segredos-e-dependencias.sh" --apenas-dependencias --relatorio "$rel_deps" >/dev/null 2>&1
casos=$((casos + 1))
if grep -q "Inventário e Auditoria de Dependências" "$rel_deps" && ! grep -q "Varredura de Credenciais, Chaves e Segredos" "$rel_deps"; then
  echo "  ✓ caso 9: --apenas-dependencias isola escopo com sucesso"
else
  echo "  ✗ caso 9: falha ao isolar --apenas-dependencias"
  falhas=$((falhas + 1))
fi

# Caso 10: Flag --falhar-se-encontrar-segredo sai com 1 quando há segredo não legítimo
conferir "caso 10: --falhar-se-encontrar-segredo reprova com exit 1" \
  1 "Segredo em arquivo: src/provedor.ts" \
  "$dir_segredo/scripts/auditoria-segredos-e-dependencias.sh" --falhar-se-encontrar-segredo --relatorio "$dir_segredo/docs/rel.md"

# Caso 11 (Sonda 1 do Lince): Token em arquivo de teste fora da allowlist gera ALERTA
dir_sonda1="$TMP/repo_sonda1"
mkdir -p "$dir_sonda1/scripts" "$dir_sonda1/supabase/functions/auth"
cp "$PORTAO" "$dir_sonda1/scripts/"
tok_sonda1=$(printf '%s%s' "sbp_" "1234567890abcdef1234567890abcdef12345678")
cat << EOF > "$dir_sonda1/supabase/functions/auth/index_test.ts"
Deno.test("sonda", () => {
  const token = "${tok_sonda1}";
});
EOF
(
  cd "$dir_sonda1" || exit 1
  git init -q
  git config user.email "teste@frilabr.com"
  git config user.name "Testador"
  git add .
  git commit -q -m "test: sonda token fora da allowlist"
)
conferir "caso 11 (sonda 1): token sbp desconhecido em teste gera ALERTA e sai com 1" \
  1 "Segredo em arquivo: supabase/functions/auth/index_test.ts" \
  "$dir_sonda1/scripts/auditoria-segredos-e-dependencias.sh" --falhar-se-encontrar-segredo --relatorio "$dir_sonda1/docs/rel.md"

# Caso 12 (Sonda 2 do Lince): Mistura de fixture e arquivo de produção no mesmo commit
dir_sonda2="$TMP/repo_sonda2"
mkdir -p "$dir_sonda2/scripts" "$dir_sonda2/a/fixtures" "$dir_sonda2/z"
cp "$PORTAO" "$dir_sonda2/scripts/"
tok_sonda2_mock=$(printf '%s%s' "re_" "mock_1234567890abcdef12345678")
tok_sonda2_prod=$(printf '%s%s' "re_" "prod_1234567890abcdef12345678")
cat << EOF > "$dir_sonda2/a/fixtures/seed.ts"
export const mockSecret = "${tok_sonda2_mock}";
EOF
cat << EOF > "$dir_sonda2/z/prod.ts"
export const prodSecret = "${tok_sonda2_prod}";
EOF
(
  cd "$dir_sonda2" || exit 1
  git init -q
  git config user.email "teste@frilabr.com"
  git config user.name "Testador"
  git add .
  git commit -q -m "feat: commit misturando fixture e producao"
  rm "$dir_sonda2/z/prod.ts"
  git add "$dir_sonda2/z/prod.ts"
  git commit -q -m "fix: remove segredo em producao"
)
conferir "caso 12 (sonda 2): segredo no historico em z/prod.ts e detectado e sai com 1" \
  1 "Segredo no histórico: commit" \
  "$dir_sonda2/scripts/auditoria-segredos-e-dependencias.sh" --falhar-se-encontrar-segredo --relatorio "$dir_sonda2/docs/rel.md"

# Caso 13 (Sonda 3 do Lince): Falha ao ler histórico Git gera status INCOMPLETO e exit 2
dir_sonda3="$TMP/repo_sonda3"
mkdir -p "$dir_sonda3/scripts" "$dir_sonda3/bin"
cp "$PORTAO" "$dir_sonda3/scripts/"
(
  cd "$dir_sonda3" || exit 1
  git init -q
  git config user.email "teste@frilabr.com"
  git config user.name "Testador"
  echo "vazio" > README.md
  git add README.md
  git commit -q -m "init"
)
cat << 'EOF' > "$dir_sonda3/bin/git"
#!/usr/bin/env bash
if [ "$1" = "log" ]; then
  echo "fatal: git log error 128" >&2
  exit 128
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$dir_sonda3/bin/git"

conferir "caso 13 (sonda 3): falha de git log sai com exit 2 e status INCOMPLETO" \
  2 "INCOMPLETO" \
  env PATH="$dir_sonda3/bin:$PATH" "$dir_sonda3/scripts/auditoria-segredos-e-dependencias.sh" --falhar-se-encontrar-segredo --relatorio "$dir_sonda3/docs/rel.md"

# Caso 14 (Sonda 4 do Lince): jsr:@scope sem versao, npm:lodash@~ e lockfile corrompido
dir_sonda4="$TMP/repo_sonda4"
mkdir -p "$dir_sonda4/scripts" "$dir_sonda4/supabase/functions/sonda"
cp "$PORTAO" "$dir_sonda4/scripts/"
echo "texto corrompido nao json" > "$dir_sonda4/deno.lock"
cat << 'EOF' > "$dir_sonda4/supabase/functions/sonda/index.ts"
import { pkg } from "jsr:@scope/pkg";
import lodash from "npm:lodash@~4.17.0";
EOF
(
  cd "$dir_sonda4" || exit 1
  git init -q
  git config user.email "teste@frilabr.com"
  git config user.name "Testador"
  git add .
  git commit -q -m "feat: dependencias flutuantes"
)
saida_sonda4=$("$dir_sonda4/scripts/auditoria-segredos-e-dependencias.sh" --relatorio "$dir_sonda4/docs/rel.md" 2>&1 || true)
casos=$((casos + 1))
if printf '%s' "$saida_sonda4" | grep -q "Dependência Deno sem versão fixada: jsr:@scope/pkg" && \
   printf '%s' "$saida_sonda4" | grep -q "Dependência Deno sem versão fixada: npm:lodash@~4.17.0" && \
   printf '%s' "$saida_sonda4" | grep -q "Arquivo deno.lock corrompido"; then
  echo "  ✓ caso 14 (sonda 4): detectados especificadores flutuantes e lockfile corrompido"
else
  echo "  ✗ caso 14 (sonda 4): falha ao auditar especificadores flutuantes / lockfile"
  falhas=$((falhas + 1))
fi

echo
if [ "$falhas" -eq 0 ]; then
  echo "✓ Todos os $casos testes passaram."
  exit 0
else
  echo "✗ $falhas de $casos testes falharam."
  exit 1
fi
