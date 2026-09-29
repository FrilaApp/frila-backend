#!/usr/bin/env bash
# Testa a linha de base de `mutacao.sh`: quando a suíte está vermelha, o portão tem de
# **nomear** o teste vermelho, e não só dizer que está vermelho.
#
# Roda sem Postgres. O `supabase` é dublado por um script no PATH que devolve saída de
# verdade — colada do run 36593222476 da CI, em 29/09 — e sai 1. Isso basta: com a linha de
# base vermelha, `mutacao.sh` sai antes de encostar no `docker`.
#
# O caso 2 é o que justifica o ramo da cauda crua. Suíte que morre antes de rodar teste
# algum não tem nome para extrair, e foi exatamente a situação em que "SUÍTE JÁ VERMELHA"
# sozinho não dizia nada.
#
#   ./scripts/teste-mutacao-linha-de-base.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

PORTAO="$PWD/scripts/mutacao.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

falhas=0
casos=0

# Saída real de `supabase test db` com dois arquivos vermelhos: o bloco `Dubious` de cada um
# e o `Test Summary Report` do fim, que é de onde os nomes saem.
saida_vermelha() {
  cat <<'SAIDA'
/home/runner/work/frila-backend/frila-backend/supabase/tests/350_regiao_administrativa.sql ................... ok
psql:/home/runner/work/frila-backend/frila-backend/supabase/tests/360_denunciar_e_bloquear.sql:344: ERROR:  Configuração frila.agendador_secret ausente no banco de dados
CONTEXT:  PL/pgSQL function privado.disparar_email() line 11 at RAISE
/home/runner/work/frila-backend/frila-backend/supabase/tests/360_denunciar_e_bloquear.sql ....................
Dubious, test returned 3 (wstat 768, 0x300)
Failed 29/66 subtests
/home/runner/work/frila-backend/frila-backend/supabase/tests/420_excluir_conta_recolhe_confirmadas.sql ....... ok
/home/runner/work/frila-backend/frila-backend/supabase/tests/430_emails_transacionais.sql ....................
Dubious, test returned 3 (wstat 768, 0x300)
Failed 9/57 subtests
/home/runner/work/frila-backend/frila-backend/supabase/tests/carga/gerar_df.sql .............................. ok

Test Summary Report
-------------------
/home/runner/work/frila-backend/frila-backend/supabase/tests/360_denunciar_e_bloquear.sql                  (Wstat: 768 (exited 3) Tests: 37 Failed: 0)
  Non-zero exit status: 3
  Parse errors: Bad plan.  You planned 66 tests but ran 37.
/home/runner/work/frila-backend/frila-backend/supabase/tests/430_emails_transacionais.sql                  (Wstat: 768 (exited 3) Tests: 48 Failed: 0)
  Non-zero exit status: 3
  Parse errors: Bad plan.  You planned 57 tests but ran 48.
Files=52, Tests=1425,  5 wallclock secs ( 0.22 usr  0.11 sys +  0.49 cusr  0.29 csys =  1.11 CPU)
Result: FAIL
SAIDA
}

# Suíte que não chegou a rodar: nenhum nome a extrair.
saida_morta() {
  cat <<'SAIDA'
failed to connect to postgres: failed to connect to `host=127.0.0.1 user=postgres database=postgres`:
  dial error (dial tcp 127.0.0.1:54322: connect: connection refused)
Try rerunning the command with --debug to troubleshoot the error.
SAIDA
}

# caso <nome> <qual saída> <frase> [ausente]
#
# Com `ausente` no quarto argumento, o caso exige que a frase **não** apareça. Isso também
# passa pelo `mutacao.sh` de verdade: uma asserção que refizesse o `sed` aqui dentro estaria
# medindo uma cópia da lógica, e sobreviveria a qualquer mutação do portão.
caso() {
  local nome="$1" qual="$2" frase="$3" modo="${4:-presente}"
  local dir="$TMP/caso$casos"
  casos=$((casos + 1))
  mkdir -p "$dir/scripts" "$dir/bin"
  cp "$PORTAO" "$dir/scripts/"

  # O dublê: devolve a saída pedida e sai 1, como `supabase test db` faz com a suíte
  # vermelha. `mutacao.sh` sai na linha de base e nunca chama o `docker`.
  {
    echo '#!/usr/bin/env bash'
    declare -f "$qual"
    echo "$qual"
    echo 'exit 1'
  } > "$dir/bin/supabase"
  chmod +x "$dir/bin/supabase"

  local saida codigo
  saida=$(cd "$dir" && PATH="$dir/bin:$PATH" ./scripts/mutacao.sh 2>&1)
  codigo=$?

  local achou=1
  printf '%s\n' "$saida" | grep -qF "$frase" || achou=0
  local esperado=1
  [ "$modo" = ausente ] && esperado=0

  if [ "$codigo" = 1 ] && [ "$achou" = "$esperado" ]; then
    echo "  ✓ $nome"
  else
    local comose="com"; [ "$modo" = ausente ] && comose="SEM"
    echo "  ✗ $nome — esperava saída 1 $comose \"$frase\", veio $codigo:"
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhas=$((falhas + 1))
  fi
}

echo "▸ Portão: a linha de base da mutação nomeia o vermelho"

caso "suíte vermelha ainda reprova" saida_vermelha "SUÍTE JÁ VERMELHA"

# O motivo do PR: sem estes dois, o portão sabe que está vermelho e não diz onde.
caso "nomeia o primeiro teste vermelho" saida_vermelha "360_denunciar_e_bloquear"
caso "nomeia o segundo teste vermelho" saida_vermelha "430_emails_transacionais"

# O que passou não pode ser nomeado junto: uma lista que inclui os verdes manda consertar o
# que não está quebrado. Dois verdes, porque a saída real os traz de formas diferentes — um
# antes do bloco `Dubious`, outro depois.
caso "teste verde antes do vermelho não é nomeado" saida_vermelha \
  "350_regiao_administrativa" ausente

caso "teste verde depois do vermelho não é nomeado" saida_vermelha \
  "420_excluir_conta_recolhe_confirmadas" ausente

# Suíte que morreu antes de rodar: sem nome, o portão mostra a cauda crua em vez de calar.
caso "sem nome extraível, avisa que a suíte pode não ter rodado" saida_morta \
  "a suíte pode ter morrido antes de"
caso "sem nome extraível, mostra a cauda crua" saida_morta \
  "connection refused"

echo
if [ "$falhas" -ne 0 ]; then
  echo "$falhas de $casos casos falharam."
  exit 1
fi
echo "Os $casos casos passaram."
