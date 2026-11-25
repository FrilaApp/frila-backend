#!/usr/bin/env bash
# Testa o `--fatia K/N` do mutacao.sh (B-117).
#
# A rodada completa roda a suíte inteira por alvo e levava ~21 h em série: nunca coube nas
# 6 h do job da CI. Ela passou a rodar em N fatias, uma por job. Dividir só é seguro se a
# divisão não perde nem repete alvo, e se o veredito de cada fatia continua o de hoje:
# mutante vivo reprova a fatia onde está. Roda sem Postgres e sem rede, com dublês.
#
# Casos cobertos:
#   1. As N fatias, juntas, medem cada alvo exatamente uma vez (N = 1, 3, 4 e 12, com
#      N maior que o total, que deixa fatias vazias).
#   2. O tamanho das fatias difere em no máximo 1 (revezamento, não pedaço contíguo).
#   3. Um mutante vivo reprova a fatia onde está, e só ela.
#   4. A lista `estruturais` desatualizada reprova TODA fatia (confere a lista inteira).
#   5. Argumento inválido (0/3, 4/3, 1/0, texto, falta de valor) sai 1 sem mutar nada.
#   6. `--fatia` com `--regravar-mapa` sai 1 (regravaria o mapa com 1/N dele).
#   7. A matrix da CI lista exatamente as fatias 1..N de MUTACAO_FATIAS=N, o passo da
#      mutação usa as duas, e o job tem `timeout-minutes` e `fail-fast: false`.
#
#   ./scripts/teste-mutacao-fatias.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PORTAO="$PWD/scripts/mutacao.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

# Nove restrições: as sete de comportamento, mais as duas declaradas estruturais no portão.
TODOS="alfa bravo charlie delta eco foxtrote golfe usuario_id_perfil avaliacao_turno_id_autor_id_key"

montar_dubles() {
  local dir="$1" vivo="$2" omitir_estrutural="${3:-0}"
  mkdir -p "$dir/scripts" "$dir/bin" "$dir/supabase/tests"
  cp "$PORTAO" "$dir/scripts/mutacao.sh"
  echo "MUTADO=" > "$dir/estado.env"

  cat > "$dir/bin/psql" <<EOF
#!/usr/bin/env bash
args="\$*"
if [[ "\$args" == *"contype in ('c','x')"* ]]; then
  for n in $TODOS; do
    if [ "$omitir_estrutural" = 1 ] && [ "\$n" = usuario_id_perfil ]; then continue; fi
    echo "restrição|\$n|alter table t drop constraint \$n|alter table t add constraint \$n check (true)"
  done
  exit 0
fi
exit 0
EOF
  chmod +x "$dir/bin/psql"

  # O estado do mutante vive em arquivo: o docker dublê o grava ao ver o drop e o apaga no add.
  cat > "$dir/bin/docker" <<'EOF'
#!/usr/bin/env bash
args="$*"
DIR_ESTADO="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$args" =~ drop\ constraint\ ([a-z_]+) ]]; then
  echo "MUTADO=${BASH_REMATCH[1]}" > "$DIR_ESTADO/estado.env"
elif [[ "$args" == *"add constraint"* ]]; then
  echo "MUTADO=" > "$DIR_ESTADO/estado.env"
fi
exec psql "$@"
EOF
  chmod +x "$dir/bin/docker"

  cat > "$dir/bin/supabase" <<EOF
#!/usr/bin/env bash
DIR_ESTADO="\$(cd "\$(dirname "\$0")/.." && pwd)"
source "\$DIR_ESTADO/estado.env"
if [ -z "\$MUTADO" ] || [ "\$MUTADO" = "$vivo" ]; then
  echo "All tests successful."
  exit 0
fi
echo "/app/supabase/tests/999_suite_inteira.sql .. Dubious, test returned 3"
echo "Failed 1/1 subtests"
exit 1
EOF
  chmod +x "$dir/bin/supabase"
}

# Roda o portão no diretório; devolve o código em $codigo e a saída em $saida.
rodar() {
  local dir="$1"
  shift
  codigo=0
  saida=$(cd "$dir" && PATH="$dir/bin:$PATH" ./scripts/mutacao.sh "$@" 2>&1) || codigo=$?
}

registrar() {
  local nome="$1" ok="$2" detalhe="${3:-}"
  casos=$((casos + 1))
  if [ "$ok" -eq 1 ]; then
    echo "  ✓ $nome"
  else
    echo "  ✗ $nome"
    [ -n "$detalhe" ] && printf '%s\n' "$detalhe" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

# Nomes medidos numa saída, um por linha (as linhas por alvo começam com o tipo).
medidos() { printf '%s\n' "$1" | sed -n 's/^  restrição  *\([a-z_]*\) .*/\1/p'; }

echo "▸ Fatias da mutação: partição sem furo, veredito por fatia"

# shellcheck disable=SC2086 # a lista é separada por espaço de propósito
esperado=$(printf '%s\n' $TODOS | sort)

# 1 e 2. Partição exata e tamanhos equilibrados, para vários N.
for n in 1 3 4 12; do
  dir="$TMP/part$n"
  montar_dubles "$dir" ""
  juntos=""
  tamanhos=""
  saidas_ok=1
  for k in $(seq 1 "$n"); do
    rodar "$dir" --completo --fatia "$k/$n"
    [ "$codigo" -ne 0 ] && saidas_ok=0
    m=$(medidos "$saida")
    juntos+="$m"$'\n'
    tamanhos+="$(printf '%s' "$m" | grep -c . || true) "
  done
  obtido=$(printf '%s' "$juntos" | grep . | sort)
  if [ "$saidas_ok" -eq 1 ] && [ "$obtido" = "$esperado" ]; then
    registrar "N=$n: as fatias juntas medem cada alvo exatamente uma vez" 1
  else
    # shellcheck disable=SC2086,SC2116 # o echo sem aspas junta as linhas numa só para a mensagem
    registrar "N=$n: as fatias juntas medem cada alvo exatamente uma vez" 0 \
      "saídas ok=$saidas_ok; esperado: $(echo $esperado); obtido: $(echo $obtido)"
  fi
  min=999
  max=0
  for t in $tamanhos; do
    [ "$t" -lt "$min" ] && min=$t
    [ "$t" -gt "$max" ] && max=$t
  done
  # Com N maior que o total (12 > 9) há fatias vazias: o equilíbrio vale até o total.
  if [ $((max - min)) -le 1 ]; then
    registrar "N=$n: tamanhos das fatias ($tamanhos) diferem em no máximo 1" 1
  else
    registrar "N=$n: tamanhos das fatias ($tamanhos) diferem em no máximo 1" 0
  fi
done

# 3. Mutante vivo reprova só a fatia onde está.
dir="$TMP/vivo"
montar_dubles "$dir" "delta"
reprovadas=0
dona=""
for k in 1 2 3; do
  rodar "$dir" --completo --fatia "$k/3"
  if [ "$codigo" -ne 0 ]; then
    reprovadas=$((reprovadas + 1))
    printf '%s\n' "$saida" | grep -q "SOBREVIVEU" && dona="$k"
  fi
done
if [ "$reprovadas" -eq 1 ] && [ -n "$dona" ]; then
  registrar "mutante vivo reprova a fatia onde está (e só ela)" 1
else
  registrar "mutante vivo reprova a fatia onde está (e só ela)" 0 "reprovadas=$reprovadas dona=$dona"
fi

# 4. `estruturais` desatualizada reprova toda fatia: a conferência é contra a lista inteira.
dir="$TMP/estrutural"
montar_dubles "$dir" "" 1
todas_reprovam=1
for k in 1 2 3; do
  rodar "$dir" --completo --fatia "$k/3"
  if [ "$codigo" -eq 0 ] || ! printf '%s\n' "$saida" | grep -qF "usuario_id_perfil"; then
    todas_reprovam=0
  fi
done
if [ "$todas_reprovam" -eq 1 ]; then
  registrar "lista estruturais desatualizada reprova todas as fatias" 1
else
  registrar "lista estruturais desatualizada reprova todas as fatias" 0
fi

# 5. Argumento inválido sai 1 sem mutar nada.
dir="$TMP/invalido"
montar_dubles "$dir" ""
for arg in "0/3" "4/3" "1/0" "abc" "1-3" "-1/3" "01/3x"; do
  rodar "$dir" --completo --fatia "$arg"
  if [ "$codigo" -eq 1 ] && ! printf '%s\n' "$saida" | grep -q "Alvos montados"; then
    registrar "--fatia $arg é recusada antes de mutar" 1
  else
    registrar "--fatia $arg é recusada antes de mutar" 0 "exit $codigo: $saida"
  fi
done
rodar "$dir" --completo --fatia
if [ "$codigo" -eq 1 ]; then
  registrar "--fatia sem valor é recusada" 1
else
  registrar "--fatia sem valor é recusada" 0 "exit $codigo"
fi

# 6. Fatia não regrava o mapa.
rodar "$dir" --regravar-mapa --fatia 1/3
if [ "$codigo" -eq 1 ] && [ ! -f "$dir/scripts/mutacao-matadores.tsv" ]; then
  registrar "--fatia com --regravar-mapa é recusada e não escreve o mapa" 1
else
  registrar "--fatia com --regravar-mapa é recusada e não escreve o mapa" 0 "exit $codigo"
fi

# 7. A CI e o script concordam sobre quantas fatias existem.
CI=".github/workflows/ci.yml"
n_decl=$(sed -n 's/^ *MUTACAO_FATIAS: *\([0-9][0-9]*\) *$/\1/p' "$CI")
lista=$(sed -n 's/^ *fatia: *\[\(.*\)\] *$/\1/p' "$CI" | tr -d ' ')
esperada=$(seq 1 "${n_decl:-0}" | paste -sd, -)
if [ -n "$n_decl" ] && [ "$(printf '%s\n' "$n_decl" | grep -c .)" -eq 1 ] && [ "$lista" = "$esperada" ]; then
  registrar "a matrix da CI é exatamente 1..$n_decl (MUTACAO_FATIAS)" 1
else
  registrar "a matrix da CI é exatamente 1..N de MUTACAO_FATIAS" 0 "MUTACAO_FATIAS='$n_decl' matrix='$lista'"
fi
# shellcheck disable=SC2016 # o texto literal `$FATIA` é o que a CI contém
if grep -qF -- '--completo --fatia "$FATIA/$MUTACAO_FATIAS"' "$CI"; then
  registrar "o passo da CI chama mutacao.sh --completo --fatia K/N com as duas variáveis" 1
else
  registrar "o passo da CI chama mutacao.sh --completo --fatia K/N com as duas variáveis" 0
fi
bloco=$(sed -n '/^  mutacao-completa:/,/^  mutacao-completa-veredito:/p' "$CI")
if printf '%s\n' "$bloco" | grep -q 'timeout-minutes: *[0-9]' && printf '%s\n' "$bloco" | grep -q 'fail-fast: *false'; then
  registrar "o job das fatias tem timeout-minutes e fail-fast: false" 1
else
  registrar "o job das fatias tem timeout-minutes e fail-fast: false" 0
fi

echo
if [ "$falhas" -gt 0 ]; then
  echo "✗ $falhas de $casos casos falharam"
  exit 1
fi
echo "✓ $casos casos"
