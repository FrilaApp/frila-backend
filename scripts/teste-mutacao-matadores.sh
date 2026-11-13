#!/usr/bin/env bash
# Testa os matadores e o fallback da mutação (Mudança 2 da otimização de CI).
#
# Roda sem Postgres, com o supabase e o psql dublados.
#
# Casos cobertos (briefing trovão):
#   1. Mapa apontando para arquivo que não mata (cai na suíte inteira e ainda acerta).
#   2. Alvo fora do mapa (cai na suíte inteira e ainda acerta).
#   3. Arquivo do mapa que não existe (ignorado, cai na suíte inteira e acerta).
#   4. Candidato que falha sozinho na linha de base (descartado, cai na suíte inteira).
#   5. Alvo sem cobertura continua reprovando (exit 1).
#   6. Candidato que mata o alvo direto (não cai na suíte inteira).
#   7. Contraexemplo de Cauê: candidatos avaliados individualmente nos dois lados.
#   8. Modo completo avisa quando mapa de matadores está desatualizado.
#   9. Decisor com saída inesperada (!= 0 e != 10, ex: exit 1 de erro bash) emite aviso e roda por segurança.
#  10. Decisor com código 10 (pode pular) encerra a mutação sem executar suíte.
#
#   ./scripts/teste-mutacao-matadores.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PORTAO="$PWD/scripts/mutacao.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

executar_caso() {
  local nome="$1"
  local config_mapa="$2"         # Linha do mapa (ou vazio)
  local cria_arquivo_cand="$3"   # 1 cria supabase/tests/<cand>.sql, 0 não cria
  local cand_baseline_ok="$4"    # 1 se o candidato passa na linha de base individual
  local cand_mata_mutante="$5"   # 1 se o candidato falha quando mutado (mata o mutante)
  local suite_mata_mutante="$6"  # 1 se a suíte inteira falha quando mutada
  local codigo_esperado="$7"
  local texto_esperado="$8"
  local texto_proibido="${9:-}"

  casos=$((casos + 1))
  local dir="$TMP/caso$casos"
  mkdir -p "$dir/scripts" "$dir/bin" "$dir/supabase/tests"
  cp "$PORTAO" "$dir/scripts/mutacao.sh"

  if [ -n "$config_mapa" ]; then
    printf '%s\n' "$config_mapa" > "$dir/scripts/mutacao-matadores.tsv"
  fi

  if [ "$cria_arquivo_cand" -eq 1 ]; then
    touch "$dir/supabase/tests/cand_teste.sql"
  fi

  # Cria o estado do teste para o dublê de supabase
  cat > "$dir/estado.env" <<EOF
MUTANTE_DERRUBADO=0
CAND_BASELINE_OK=$cand_baseline_ok
CAND_MATA_MUTANTE=$cand_mata_mutante
SUITE_MATA_MUTANTE=$suite_mata_mutante
EOF

  # Dublê do psql: devolve alvo_teste e os alvos estruturais declarados
  cat > "$dir/bin/psql" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"contype in ('c','x')"* ]]; then
  echo "restrição|alvo_teste|alter table t drop constraint c|alter table t add constraint c check (true)"
  echo "restrição|usuario_id_perfil|alter table t drop constraint c|alter table t add constraint c check (true)"
  echo "restrição|avaliacao_turno_id_autor_id_key|alter table t drop constraint c|alter table t add constraint c check (true)"
  exit 0
fi
if [[ "$args" == *"select "* ]]; then
  exit 0
fi
# DDLs drop e restore
exit 0
EOF
  chmod +x "$dir/bin/psql"

  # Dublê do supabase:
  cat > "$dir/bin/supabase" <<'EOF'
#!/usr/bin/env bash
set -e
DIR_ESTADO="$(cd "$(dirname "$0")/.." && pwd)"
source "$DIR_ESTADO/estado.env"

# Chamada com argumento de arquivo(s): candidato
if [ $# -gt 2 ] && [ "$1" = "test" ] && [ "$2" = "db" ] && [ -n "${3:-}" ]; then
  if [ "$MUTANTE_DERRUBADO" -eq 0 ]; then
    # Linha de base individual do candidato
    if [ "$CAND_BASELINE_OK" -eq 1 ]; then
      echo "supabase/tests/cand_teste.sql .. ok"
      exit 0
    else
      echo "supabase/tests/cand_teste.sql .. Dubious"
      echo "Failed 1/1 subtests"
      exit 1
    fi
  else
    # Candidato rodando contra o mutante
    if [ "$CAND_MATA_MUTANTE" -eq 1 ]; then
      echo "/app/supabase/tests/cand_teste.sql .. Dubious, test returned 3"
      echo "Failed 1/1 subtests"
      exit 1
    else
      echo "/app/supabase/tests/cand_teste.sql .. ok"
      echo "All tests successful."
      exit 0
    fi
  fi
fi

# Chamada sem arquivos: linha de base inicial ou suíte inteira
if [ "$MUTANTE_DERRUBADO" -eq 0 ]; then
  # Linha de base inicial do portão: sempre verde neste suite
  echo "All tests successful."
  exit 0
else
  # Suíte inteira rodando contra o mutante
  if [ "$SUITE_MATA_MUTANTE" -eq 1 ]; then
    echo "/app/supabase/tests/999_suite_inteira.sql .. Dubious, test returned 3"
    echo "Failed 1/1 subtests"
    exit 1
  else
    echo "All tests successful."
    exit 0
  fi
fi
EOF
  chmod +x "$dir/bin/supabase"

  # Dublê de docker para interceptar queda do mutante e atualizar estado
  cat > "$dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
args="$*"
DIR_ESTADO="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$args" == *"drop constraint"* ]]; then
  sed -i '' 's/MUTANTE_DERRUBADO=0/MUTANTE_DERRUBADO=1/' "$DIR_ESTADO/estado.env" 2>/dev/null || \
  sed -i 's/MUTANTE_DERRUBADO=0/MUTANTE_DERRUBADO=1/' "$DIR_ESTADO/estado.env"
elif [[ "$args" == *"add constraint"* ]]; then
  sed -i '' 's/MUTANTE_DERRUBADO=1/MUTANTE_DERRUBADO=0/' "$DIR_ESTADO/estado.env" 2>/dev/null || \
  sed -i 's/MUTANTE_DERRUBADO=1/MUTANTE_DERRUBADO=0/' "$DIR_ESTADO/estado.env"
fi
exec psql "$@"
EOF
  chmod +x "$dir/bin/docker"

  local saida
  local codigo=0
  saida=$(
    cd "$dir"
    PATH="$dir/bin:$PATH" ./scripts/mutacao.sh --forcar alvo_teste 2>&1
  ) || codigo=$?

  local contem=1
  if [ -n "$texto_esperado" ] && ! printf '%s\n' "$saida" | grep -qF "$texto_esperado"; then
    contem=0
  fi

  local proibido_ok=1
  if [ -n "$texto_proibido" ] && printf '%s\n' "$saida" | grep -qF "$texto_proibido"; then
    proibido_ok=0
  fi

  if [ "$codigo" -eq "$codigo_esperado" ] && [ "$contem" -eq 1 ] && [ "$proibido_ok" -eq 1 ]; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperado exit $codigo_esperado contendo '$texto_esperado', veio exit $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Matadores da mutação: candidatos e fallback para a suíte inteira"

# 1. Candidato que não mata: cai na suíte inteira e acerta
executar_caso \
  "candidato não mata o mutante -> cai na suíte inteira e acerta" \
  "restrição	alvo_teste	cand_teste" \
  1 1 0 1 \
  0 "morreu ✓  (999_suite_inteira)"

# 2. Alvo fora do mapa: cai na suíte inteira e acerta
executar_caso \
  "alvo fora do mapa -> cai na suíte inteira e acerta" \
  "" \
  0 1 0 1 \
  0 "morreu ✓  (999_suite_inteira)"

# 3. Arquivo do mapa que não existe: cai na suíte inteira e acerta
executar_caso \
  "arquivo do candidato não existe no disco -> cai na suíte inteira e acerta" \
  "restrição	alvo_teste	cand_teste" \
  0 1 0 1 \
  0 "morreu ✓  (999_suite_inteira)"

# 4. Candidato que já falha na linha de base individual: descartado
executar_caso \
  "candidato falha sozinho na linha de base -> é descartado e cai na suíte inteira" \
  "restrição	alvo_teste	cand_teste" \
  1 0 1 1 \
  0 "morreu ✓  (999_suite_inteira)"

# 5. Alvo sem cobertura continua reprovando (exit 1)
executar_caso \
  "alvo sem cobertura -> sobrevive e reprova o portão (exit 1)" \
  "restrição	alvo_teste	cand_teste" \
  1 1 0 0 \
  1 "SOBREVIVEU — nenhum teste reclamou"

# 6. Candidato que mata o mutante: morre direto sem cair na suíte inteira
executar_caso \
  "candidato mata direto -> morreu sem cair na suíte inteira" \
  "restrição	alvo_teste	cand_teste" \
  1 1 1 0 \
  0 "morreu ✓  (cand_teste)" \
  "Alvos que caíram na suíte inteira"

# 7. Contraexemplo do Cauê: candidatos avaliados individualmente nos dois lados
testar_contraexemplo_caue() {
  local nome="contraexemplo do Cauê: 2 candidatos verdes sozinhos que falhariam juntos são avaliados individualmente (exit 1 SOBREVIVEU)"
  casos=$((casos + 1))
  local dir="$TMP/caso$casos"
  mkdir -p "$dir/scripts" "$dir/bin" "$dir/supabase/tests"
  cp "$PORTAO" "$dir/scripts/mutacao.sh"

  printf 'restrição\talvo_teste\tcand_a cand_b\n' > "$dir/scripts/mutacao-matadores.tsv"
  touch "$dir/supabase/tests/cand_a.sql" "$dir/supabase/tests/cand_b.sql"

  cat > "$dir/estado.env" <<EOF
MUTANTE_DERRUBADO=0
EOF

  cat > "$dir/bin/psql" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"contype in ('c','x')"* ]]; then
  echo "restrição|alvo_teste|alter table t drop constraint c|alter table t add constraint c check (true)"
  echo "restrição|usuario_id_perfil|alter table t drop constraint c|alter table t add constraint c check (true)"
  echo "restrição|avaliacao_turno_id_autor_id_key|alter table t drop constraint c|alter table t add constraint c check (true)"
  exit 0
fi
exit 0
EOF
  chmod +x "$dir/bin/psql"

  # Dublê de supabase: se receber múltiplos arquivos juntos (comportamento antigo com bug), falha.
  # Sozinho, cada candidato passa (não mata o mutante).
  cat > "$dir/bin/supabase" <<'EOF'
#!/usr/bin/env bash
set -e
DIR_ESTADO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$DIR_ESTADO/estado.env"

if [ $# -gt 2 ] && [ "$1" = "test" ] && [ "$2" = "db" ] && [ -n "${3:-}" ]; then
  if [ $# -gt 3 ]; then
    # Se múltiplos arquivos forem passados juntos (regressão), simula o contraexemplo:
    # a execução conjunta acusa falha atribuída a cand_a (o que faria o alvo parecer morto)
    echo "supabase/tests/cand_a.sql .. Dubious"
    echo "Failed 1/1 subtests"
    exit 1
  fi
  echo "$3 .. ok"
  exit 0
fi

if [ "$MUTANTE_DERRUBADO" -eq 0 ]; then
  echo "All tests successful."
  exit 0
else
  # Suíte inteira também não mata o mutante neste teste
  echo "All tests successful."
  exit 0
fi
EOF
  chmod +x "$dir/bin/supabase"

  cat > "$dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
args="$*"
DIR_ESTADO="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$args" == *"drop constraint"* ]]; then
  sed -i '' 's/MUTANTE_DERRUBADO=0/MUTANTE_DERRUBADO=1/' "$DIR_ESTADO/estado.env" 2>/dev/null || \
  sed -i 's/MUTANTE_DERRUBADO=0/MUTANTE_DERRUBADO=1/' "$DIR_ESTADO/estado.env"
elif [[ "$args" == *"add constraint"* ]]; then
  sed -i '' 's/MUTANTE_DERRUBADO=1/MUTANTE_DERRUBADO=0/' "$DIR_ESTADO/estado.env" 2>/dev/null || \
  sed -i 's/MUTANTE_DERRUBADO=1/MUTANTE_DERRUBADO=0/' "$DIR_ESTADO/estado.env"
fi
exec psql "$@"
EOF
  chmod +x "$dir/bin/docker"

  local saida
  local codigo=0
  saida=$(
    cd "$dir"
    PATH="$dir/bin:$PATH" ./scripts/mutacao.sh --forcar alvo_teste 2>&1
  ) || codigo=$?

  if [ "$codigo" -eq 1 ] && printf '%s\n' "$saida" | grep -qF "SOBREVIVEU — nenhum teste reclamou" && ! printf '%s\n' "$saida" | grep -qF "morreu ✓  (cand_a)"; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperado exit 1 contendo 'SOBREVIVEU', veio exit $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}
testar_contraexemplo_caue

# 8. Modo completo avisa quando mapa de matadores está desatualizado
testar_aviso_mapa_desatualizado_completo() {
  local nome="modo completo avisa quando mapa de matadores está desatualizado"
  casos=$((casos + 1))
  local dir="$TMP/caso$casos"
  mkdir -p "$dir/scripts" "$dir/bin" "$dir/supabase/tests"
  cp "$PORTAO" "$dir/scripts/mutacao.sh"

  printf 'restrição\talvo_teste\tcand_antigo\n' > "$dir/scripts/mutacao-matadores.tsv"
  touch "$dir/supabase/tests/cand_antigo.sql"

  cat > "$dir/estado.env" <<EOF
MUTANTE_DERRUBADO=0
EOF

  cat > "$dir/bin/psql" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"contype in ('c','x')"* ]]; then
  echo "restrição|alvo_teste|alter table t drop constraint c|alter table t add constraint c check (true)"
  echo "restrição|usuario_id_perfil|alter table t drop constraint c|alter table t add constraint c check (true)"
  echo "restrição|avaliacao_turno_id_autor_id_key|alter table t drop constraint c|alter table t add constraint c check (true)"
  exit 0
fi
exit 0
EOF
  chmod +x "$dir/bin/psql"

  cat > "$dir/bin/supabase" <<'EOF'
#!/usr/bin/env bash
set -e
DIR_ESTADO="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$DIR_ESTADO/estado.env"

if [ "$MUTANTE_DERRUBADO" -eq 0 ]; then
  echo "All tests successful."
  exit 0
else
  echo "/app/supabase/tests/999_novo_matador.sql .. Dubious, test returned 3"
  echo "Failed 1/1 subtests"
  exit 1
fi
EOF
  chmod +x "$dir/bin/supabase"

  cat > "$dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
args="$*"
DIR_ESTADO="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$args" == *"drop constraint"* ]]; then
  sed -i '' 's/MUTANTE_DERRUBADO=0/MUTANTE_DERRUBADO=1/' "$DIR_ESTADO/estado.env" 2>/dev/null || \
  sed -i 's/MUTANTE_DERRUBADO=0/MUTANTE_DERRUBADO=1/' "$DIR_ESTADO/estado.env"
elif [[ "$args" == *"add constraint"* ]]; then
  sed -i '' 's/MUTANTE_DERRUBADO=1/MUTANTE_DERRUBADO=0/' "$DIR_ESTADO/estado.env" 2>/dev/null || \
  sed -i 's/MUTANTE_DERRUBADO=1/MUTANTE_DERRUBADO=0/' "$DIR_ESTADO/estado.env"
fi
exec psql "$@"
EOF
  chmod +x "$dir/bin/docker"

  local saida
  local codigo=0
  saida=$(
    cd "$dir"
    PATH="$dir/bin:$PATH" ./scripts/mutacao.sh --completo --forcar alvo_teste 2>&1
  ) || codigo=$?

  if [ "$codigo" -eq 0 ] && printf '%s\n' "$saida" | grep -qF "AVISO: O mapa de matadores" && printf '%s\n' "$saida" | grep -qF "gravado (cand_antigo), mas morreu por (999_novo_matador)"; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperado aviso de mapa desatualizado, veio exit $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}
testar_aviso_mapa_desatualizado_completo

# 9. Decisor com saída inesperada (!= 0 e != 10, inclusive exit 1 de erro do bash) emite aviso e roda por segurança
testar_decisor_codigo_erro_roda_mutacao() {
  local nome="decisor com saída inesperada (exit 1 de erro do bash) emite aviso e roda mutação por segurança"
  casos=$((casos + 1))
  local dir="$TMP/caso$casos"
  mkdir -p "$dir/scripts" "$dir/bin" "$dir/supabase/tests"
  cp "$PORTAO" "$dir/scripts/mutacao.sh"

  cat > "$dir/scripts/deve-rodar-mutacao.sh" <<'EOF'
#!/usr/bin/env bash
echo "erro simulado no decisor (ex: set -u)" >&2
exit 1
EOF
  chmod +x "$dir/scripts/deve-rodar-mutacao.sh"

  cat > "$dir/estado.env" <<EOF
MUTANTE_DERRUBADO=0
EOF

  cat > "$dir/bin/psql" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$dir/bin/psql"

  cat > "$dir/bin/supabase" <<'EOF'
#!/usr/bin/env bash
set -e
echo "All tests successful."
exit 0
EOF
  chmod +x "$dir/bin/supabase"

  cat > "$dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
exec psql "$@"
EOF
  chmod +x "$dir/bin/docker"

  local saida
  local codigo=0
  saida=$(
    cd "$dir"
    PATH="$dir/bin:$PATH" ./scripts/mutacao.sh 2>&1
  ) || codigo=$?

  if printf '%s\n' "$saida" | grep -qF "Aviso: decisor de mutação retornou código inesperado (1). Rodando mutação por segurança."; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperado aviso de código inesperado, veio exit $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}
testar_decisor_codigo_erro_roda_mutacao

# 10. Decisor com saída 10 (pode pular) encerra a mutação imediatamente sem rodar
testar_decisor_codigo_10_pula_mutacao() {
  local nome="decisor com código 10 (pode pular) encerra a mutação sem executar suíte"
  casos=$((casos + 1))
  local dir="$TMP/caso$casos"
  mkdir -p "$dir/scripts" "$dir/bin" "$dir/supabase/tests"
  cp "$PORTAO" "$dir/scripts/mutacao.sh"

  cat > "$dir/scripts/deve-rodar-mutacao.sh" <<'EOF'
#!/usr/bin/env bash
echo "Mutação pulada: PR não altera arquivos relevantes para o banco ou para a mutação."
exit 10
EOF
  chmod +x "$dir/scripts/deve-rodar-mutacao.sh"

  # Se tentar chamar supabase ou docker/psql, falha alto
  cat > "$dir/bin/supabase" <<'EOF'
#!/usr/bin/env bash
echo "ERRO: supabase não deveria ser chamado quando o decisor pula!" >&2
exit 99
EOF
  chmod +x "$dir/bin/supabase"

  local saida
  local codigo=0
  saida=$(
    cd "$dir"
    PATH="$dir/bin:$PATH" ./scripts/mutacao.sh 2>&1
  ) || codigo=$?

  if [ "$codigo" -eq 0 ] && ! printf '%s\n' "$saida" | grep -qF "ERRO: supabase não deveria ser chamado" && ! printf '%s\n' "$saida" | grep -qF "Aviso: decisor"; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome — esperado exit 0 sem chamar supabase nem aviso, veio exit $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}
testar_decisor_codigo_10_pula_mutacao

echo
if [ "$falhas" -ne 0 ]; then
  echo "$falhas de $casos casos falharam."
  exit 1
fi
echo "Os $casos casos passaram."
